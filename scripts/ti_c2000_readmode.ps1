#requires -Version 7.0
<#
ti_c2000_readmode.ps1 -- the two orthogonal dimensions (RUN mode x READ mode) and the
interlocks between them. Dot-source it in every entry point that touches the target:

    . "$PSScriptRoot\ti_c2000_readmode.ps1"

RUN MODE (how the program gets onto the target; -RunMode on ti_c2000_service.ps1):
  SingleStep (default) load ONCE (-Start -ConfirmLoad), keep the session alive, and
             every later read attaches to it. Day-to-day work lives here.
  Iterate    continuous: re-build + re-download every round until the data is right.
             Entered ONLY through ti_c2000_iterate.ps1 -UserApproved, never by
             passing -RunMode by hand. A marker in readout\iterate\active.json
             (with the owning pid) keeps everything else out while it runs.

READ MODE (how data comes back; -Mode on the two readers):
  ReadOnly  (default) never downloads. It attaches to the live session after proving
            four things; a failure refuses (exit 4) instead of quietly downloading:
              probe online   a JTAG probe is enumerated by Windows (-NoProbeCheck skips)
              session alive  state.json + ready.txt + pid
              same image     sha256(out) == state.outSha256
              from RAM       main / _c_int00 address below 0x080000 (C28x Flash base)
            "Cannot prove it from RAM" is a refusal, not a pass: a stale Flash image
            answering on the target would otherwise come back as fresh data. The only
            way past it is -AllowUnverified, which says so in the log.
  LoadRead  downloads once, runs, reads, exits. Needs -ConfirmLoad. -MaxLoads N
            repeats the cycle until -Expect passes.

INTERLOCKS (checked before any hardware work; a violation reports one FAILURE line
and one exit code, it never crashes):
  ReadOnly + -ConfirmLoad/-Build/-Standalone/-Expect/-MaxLoads>1 -> MUTUALLY_EXCLUSIVE exit 2
  LoadRead  without -ConfirmLoad                                 -> LOAD_NOT_CONFIRMED  exit 4
  ReadOnly  without a live session                                -> NO_SESSION           exit 4
  Iterate   without -UserApproved                                 -> ITERATE_NOT_APPROVED exit 4
  ReadOnly  while Iterate runs                                    -> READONLY_IN_ITERATE  exit 4
  LoadRead  while Iterate runs                                    -> MUTUALLY_EXCLUSIVE   exit 2
  any Start/Stop/Iterate while Iterate runs                       -> ITERATE_IN_PROGRESS  exit 4
  another script holds the target                                 -> TARGET_BUSY          exit 5

Exit codes: 0 OK | 1 failure | 2 environment/argument | 3 no probe
            4 refused before downloading | 5 target held elsewhere
#>

. (Join-Path $PSScriptRoot 'ti_c2000_loadcount.ps1')

$script:ReadModeNames = @('ReadOnly', 'LoadRead')
$script:RunModeNames = @('SingleStep', 'Iterate')
# every C28x part puts Flash at or above 0x080000 (28335: 0x300000, 2837x: 0x080000)
$script:C28xFlashBase = 0x080000

function Get-TargetLockPath {
    param([Parameter(Mandatory)][string]$ProjectPath)
    return (Join-Path (Join-Path $ProjectPath 'readout\.service') 'target.lock')
}

function Get-TargetLockInfo {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $p = Get-TargetLockPath -ProjectPath $ProjectPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $parts = (Get-Content -LiteralPath $p -Raw -Encoding utf8).Trim() -split '\|'
        return [ordered]@{ pid = [int]$parts[0]; mode = [string]$parts[1]; at = [string]$parts[2] }
    } catch { return [ordered]@{ pid = 0; mode = '?'; at = '?' } }
}

<#
one target operation at a time; a lock left by a dead process is taken over.

Returns an OBJECT, never a bare bool next to diagnostic output: a function that
Write-Output's four lines and then `return $false` hands the caller a five-element array,
and `if (-not (Enter-TargetLock ...))` evaluates that as "truthy" - so a busy target would
have been treated as acquired and two operations would have driven the same probe.
Measured 2026-11-14 by tests/test_state_chaos.ps1.
#>
function Enter-TargetLock {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Mode,
        [int]$WaitSeconds = 0
    )
    $dir = Join-Path $ProjectPath 'readout\.service'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Get-TargetLockPath -ProjectPath $ProjectPath
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (Test-Path -LiteralPath $path) {
        $info = Get-TargetLockInfo -ProjectPath $ProjectPath
        $holder = $null
        if ($info -and $info.pid -gt 0) { $holder = Get-Process -Id $info.pid -ErrorAction SilentlyContinue }
        if (-not $holder) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; break }
        if ((Get-Date) -ge $deadline) {
            return [ordered]@{
                ok      = $false
                message = @(
                    'FAILURE: TARGET_BUSY'
                    'RESULT: FAIL'
                    ("REASON: {0} (pid {1}) holds the target since {2}" -f $info.mode, $info.pid, $info.at)
                    'HINT    : one operation at a time - wait, or check that process'
                )
            }
        }
        Start-Sleep -Milliseconds 200
    }
    $text = '{0}|{1}|{2}' -f $PID, $Mode, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    try { [IO.File]::WriteAllText($path, $text, [Text.Encoding]::ASCII) } catch { }
    return [ordered]@{ ok = $true; message = @() }
}

function Exit-TargetLock {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $path = Get-TargetLockPath -ProjectPath $ProjectPath
    try {
        $info = Get-TargetLockInfo -ProjectPath $ProjectPath
        if ($info -and $info.pid -eq $PID -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

<# session facts from disk; alive requires state + ready + no stopped marker + pid #>
function Get-LiveSessionInfo {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $svcDir = Join-Path $ProjectPath 'readout\.service'
    $stateFile = Join-Path $svcDir 'state.json'
    $readyFile = Join-Path $svcDir 'ready.txt'
    $stoppedFile = Join-Path $svcDir 'stopped.txt'
    $r = [ordered]@{ alive = $false; state = $null; reason = 'no session has ever been started for this project' }
    if (-not (Test-Path -LiteralPath $stateFile)) { return $r }
    if (Test-Path -LiteralPath $stoppedFile) { $r.reason = 'the session was stopped'; return $r }
    if (-not (Test-Path -LiteralPath $readyFile)) { $r.reason = 'session files exist but ready.txt is missing (starting or died)'; return $r }
    try { $r.state = Get-Content -LiteralPath $stateFile -Raw -Encoding utf8 | ConvertFrom-Json } catch { $r.reason = 'state.json is unreadable'; return $r }
    if (-not (Get-Process -Id ([int]$r.state.pid) -ErrorAction SilentlyContinue)) { $r.reason = 'the session process is gone'; return $r }
    $r.alive = $true
    $r.reason = ''
    return $r
}

<#
RUN MODE SIDE. "Is a continuous run in progress?" is answered from disk, because the
iterate loop stops and restarts the session between rounds: a marker with the owning
pid covers the gap, the live session's runMode covers the rest, and a marker left by a
dead process is ignored (never blocks a normal read for ever).
#>
function Get-IterateMarkerPath {
    param([Parameter(Mandatory)][string]$ProjectPath)
    return (Join-Path (Join-Path $ProjectPath 'readout\iterate') 'active.json')
}

function Get-IterateMarker {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $p = Get-IterateMarkerPath -ProjectPath $ProjectPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $m = $null
    try { $m = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json } catch { return $null }
    if (-not $m) { return $null }
    if (-not (Get-Process -Id ([int]$m.pid) -ErrorAction SilentlyContinue)) { return $null }
    return $m
}

function Set-IterateMarker {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [int]$Round = 1,
        [int]$MaxLoads = 1,
        [string[]]$Expect = @()
    )
    $p = Get-IterateMarkerPath -ProjectPath $ProjectPath
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $o = [ordered]@{
        mode     = 'Iterate'
        pid      = $PID
        round    = $Round
        maxLoads = $MaxLoads
        expect   = @($Expect)
        started  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    try { [IO.File]::WriteAllText($p, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) } catch { }
}

function Clear-IterateMarker {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $p = Get-IterateMarkerPath -ProjectPath $ProjectPath
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        $m = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json
        if ([int]$m.pid -ne $PID) { return }
    } catch { }
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
}

<# one summary of "which run mode owns this project right now" #>
function Get-RunModeInfo {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $r = [ordered]@{ mode = 'SingleStep'; active = $false; source = 'none'; pid = 0; round = 0; maxLoads = 0 }
    $m = Get-IterateMarker -ProjectPath $ProjectPath
    if ($m) {
        $r.mode = 'Iterate'; $r.active = $true; $r.source = 'iterate marker'
        $r.pid = [int]$m.pid; $r.round = [int]$m.round; $r.maxLoads = [int]$m.maxLoads
        return $r
    }
    $s = Get-LiveSessionInfo -ProjectPath $ProjectPath
    if ($s.alive) {
        $r.source = 'live session'
        $r.pid = [int]$s.state.pid
        if ($s.state.runMode -eq 'Iterate') {
            $r.mode = 'Iterate'; $r.active = $true
            if ($s.state.loadIndex) { $r.round = [int]$s.state.loadIndex }
        }
    }
    return $r
}

<# children spawned by the iterate loop must be able to work while the marker is up #>
function Test-IterateChild {
    return ($env:TI_C2000_ITERATE_CHILD -eq '1')
}

<#
Assert-RunModeInterlock -- the RUN mode side of the interlock. -ReadMode is empty for
control operations (Start/Stop/Iterate); pass ReadOnly/LoadRead from a reader so the
message names the real conflict.
#>
function Assert-RunModeInterlock {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$ReadMode = '',
        [string]$What = 'this operation'
    )
    if (Test-IterateChild) { return }
    $mi = Get-RunModeInfo -ProjectPath $ProjectPath
    if (-not $mi.active) { return }

    $who = ('continuous run in progress (pid {0}, round {1}/{2}, {3})' -f $mi.pid, $mi.round, $mi.maxLoads, $mi.source)
    if ($ReadMode -eq 'ReadOnly') {
        Write-Output 'FAILURE: READONLY_IN_ITERATE'
        Write-Output 'RESULT: FAIL'
        Write-Output ('REASON: ' + $who)
        Write-Output 'REASON: every round re-downloads and restarts the program, so an attached read would describe a run that is already gone'
        Write-Output 'HINT    : let ti_c2000_iterate.ps1 finish (it reads each round itself), or wait and read the session that it leaves behind'
        exit 4
    }
    if ($ReadMode -eq 'LoadRead') {
        Write-Output 'FAILURE: MUTUALLY_EXCLUSIVE'
        Write-Output 'RESULT: FAIL'
        Write-Output ('REASON: ' + $who)
        Write-Output 'REASON: the continuous run already owns the download loop - one downloader at a time'
        Write-Output 'HINT    : stop it (or wait for it to converge) before asking for a one-shot LoadRead'
        exit 2
    }
    Write-Output 'FAILURE: ITERATE_IN_PROGRESS'
    Write-Output 'RESULT: FAIL'
    Write-Output ('REASON: ' + $who)
    Write-Output ('REASON: ' + $What + ' would fight the running iterate loop over the same target')
    Write-Output 'HINT    : let ti_c2000_iterate.ps1 finish; it leaves the last round''s session in place'
    exit 4
}

<# validate -RunMode and its companions; returns the spec or exits with the right code #>
function Resolve-RunModeSpec {
    param(
        [string]$RunMode = 'SingleStep',
        [switch]$ConfirmLoad,
        [switch]$UserApproved,
        [int]$MaxLoads = 1
    )

    $norm = ([string]$RunMode).Trim()
    if (@($script:RunModeNames | Where-Object { $_ -eq $norm }).Count -eq 0) {
        Write-Output 'FAILURE: INVALID_RUN_MODE'
        Write-Output 'RESULT: FAIL'
        Write-Output ("REASON: -RunMode must be SingleStep or Iterate, got '{0}'" -f $norm)
        exit 2
    }
    if ($MaxLoads -lt 1 -or $MaxLoads -gt 20) {
        Write-Output 'FAILURE: INVALID_MAX_LOADS'
        Write-Output 'RESULT: FAIL'
        Write-Output 'REASON: -MaxLoads must be 1..20'
        exit 2
    }
    if ($norm -eq 'Iterate') {
        # continuous mode re-downloads on purpose; only a user asking for it may enter.
        # No env-var exemption here on purpose: the iterate loop already passes
        # -UserApproved explicitly to its children (ti_c2000_iterate.ps1), so honouring
        # TI_C2000_ITERATE_CHILD would only turn a marker into an approval bypass.
        if (-not $UserApproved) {
            Write-Output 'FAILURE: ITERATE_NOT_APPROVED'
            Write-Output 'RESULT: FAIL'
            Write-Output 'REASON: continuous mode compiles and downloads again every round - it only runs when the user asked for it'
            Write-Output 'HINT    : the user says "连续运行，反复编译下载直到数据对" first; then run ti_c2000_iterate.ps1 -UserApproved'
            Write-Output 'HINT    : for a plain read use -Mode ReadOnly; for one download use -Mode LoadRead -ConfirmLoad'
            exit 4
        }
        return [ordered]@{ mode = $norm; downloads = $true; continuous = $true; maxLoads = $MaxLoads }
    }
    return [ordered]@{ mode = $norm; downloads = [bool]$ConfirmLoad; continuous = $false; maxLoads = $MaxLoads }
}

<# validate -Mode and its companions; returns the spec or exits with the right code #>
function Resolve-ReadModeSpec {
    param(
        [string]$Mode = 'ReadOnly',
        [switch]$ConfirmLoad,
        [switch]$Build,
        [switch]$Standalone,
        [string[]]$Expect = @(),
        [int]$MaxLoads = 1,
        [switch]$NoProbeCheck,
        [switch]$AllowUnverified
    )

    $norm = ([string]$Mode).Trim()
    if (@($script:ReadModeNames | Where-Object { $_ -eq $norm }).Count -eq 0) {
        Write-Output 'FAILURE: INVALID_READ_MODE'
        Write-Output 'RESULT: FAIL'
        Write-Output ("REASON: -Mode must be ReadOnly or LoadRead, got '{0}'" -f $norm)
        exit 2
    }
    if ($MaxLoads -lt 1 -or $MaxLoads -gt 20) {
        Write-Output 'FAILURE: INVALID_MAX_LOADS'
        Write-Output 'RESULT: FAIL'
        Write-Output 'REASON: -MaxLoads must be 1..20'
        exit 2
    }
    if ($norm -eq 'ReadOnly') {
        $clash = @()
        if ($ConfirmLoad) { $clash += '-ConfirmLoad' }
        if ($Build) { $clash += '-Build' }
        if ($Standalone) { $clash += '-Standalone' }
        if (@($Expect).Count -gt 0) { $clash += '-Expect' }
        if ($MaxLoads -gt 1) { $clash += '-MaxLoads' }
        if ($clash.Count -gt 0) {
            Write-Output 'FAILURE: MUTUALLY_EXCLUSIVE'
            Write-Output 'RESULT: FAIL'
            Write-Output ('REASON: ReadOnly never downloads, so ' + ($clash -join ' / ') + ' cannot be combined with it')
            Write-Output 'HINT    : drop them for a plain read, or use -Mode LoadRead -ConfirmLoad to download first'
            exit 2
        }
    } elseif ($NoProbeCheck -or $AllowUnverified) {
        # both switches weaken a proof that only ReadOnly has to make; a download
        # needs the probe and writes the image itself, so they make no sense here
        $which = @()
        if ($NoProbeCheck) { $which += '-NoProbeCheck' }
        if ($AllowUnverified) { $which += '-AllowUnverified' }
        Write-Output 'FAILURE: MUTUALLY_EXCLUSIVE'
        Write-Output 'RESULT: FAIL'
        Write-Output ('REASON: ' + ($which -join ' / ') + ' only applies to -Mode ReadOnly')
        Write-Output 'HINT    : LoadRead checks the probe and loads the image itself - drop the switch'
        exit 2
    } elseif (-not $ConfirmLoad) {
        Write-Output 'FAILURE: LOAD_NOT_CONFIRMED'
        Write-Output 'RESULT: FAIL'
        Write-Output 'REASON: LoadRead writes the image and restarts the program; it only runs after the user said yes'
        Write-Output 'HINT    : ask "是否编译下载并运行？" first, then re-run with -Mode LoadRead -ConfirmLoad'
        Write-Output 'HINT    : -Mode ReadOnly (default) reads the running program and never downloads'
        exit 4
    }
    return [ordered]@{ mode = $norm; downloads = ($norm -eq 'LoadRead'); expect = @($Expect); maxLoads = $MaxLoads }
}

<# one VARS request straight against the session (caller must hold the lock) #>
function Get-SessionExpressions {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string[]]$Exprs,
        [int]$TimeoutMs = 6000
    )
    $svcDir = Join-Path $ProjectPath 'readout\.service'
    $cmdFile = Join-Path $svcDir 'cmd.txt'
    $resFile = Join-Path $svcDir 'res.txt'
    Remove-Item -LiteralPath $resFile -Force -ErrorAction SilentlyContinue
    try { [IO.File]::WriteAllText($cmdFile, 'VARS ' + ($Exprs -join '|'), [Text.Encoding]::ASCII) } catch { return $null }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resFile) { break }
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $resFile)) { return $null }
    try { return @(Get-Content -LiteralPath $resFile -Encoding utf8) } catch { return $null }
}

<#
Assert-ProbeOnline -- ReadOnly still needs the probe. A session whose JTAG link died
keeps a live pid and a matching sha256, so "process alive" alone would happily report
numbers from a board that is no longer answering. Enumerating Windows devices takes
about a second and touches no target state.
#>
function Assert-ProbeOnline {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$DebugScript,
        [string]$CcsRoot = '',
        [switch]$Skip,
        [switch]$Quiet
    )
    if ($Skip) { return }
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $DebugScript, '-ProjectPath', $ProjectPath, '-ProbeCheckOnly')
    if ($CcsRoot) { $a += @('-CcsRoot', $CcsRoot) }
    $out = & $pwshExe @a 2>&1
    $code = $LASTEXITCODE
    $text = (@($out | ForEach-Object { [string]$_ }) -join "`n")
    if ($code -eq 0 -and $text -match 'RESULT: OK') {
        if (-not $Quiet) {
            foreach ($l in $out) { if ([string]$l -match '^PROBE') { Write-Output ([string]$l).TrimEnd() } }
        }
        return
    }
    # forward the child's diagnosis only (it knows which vendors it looked for);
    # the FAILURE/RESULT lines below are the single ones this call reports
    foreach ($l in $out) { if ([string]$l -match '^REASON') { Write-Output ([string]$l) } }
    if ($code -eq 3 -or $text -match 'NO_PROBE') {
        Write-Output 'FAILURE: NO_PROBE'
        Write-Output 'RESULT: FAIL'
        Write-Output 'REASON: no JTAG probe is enumerated by Windows, so the session this read would attach to cannot answer'
        Write-Output 'HINT    : connect the probe and the board (check the USB light), then read again'
        exit 3
    }
    Write-Output 'FAILURE: PROBE_CHECK_FAILED'
    Write-Output 'RESULT: FAIL'
    Write-Output 'REASON: probe pre-check did not return RESULT: OK'
    exit 2
}

<#
Test-RamImageEvidence -- the "is it RAM" criterion of ReadOnly mode. Program counters
and code live below Flash on C28x when the image was loaded into RAM by the debugger,
so the address of the entry symbols decides it. Unreadable symbols are NOT a pass:
"probably RAM" is exactly how a stale Flash image ends up reported as fresh data.
-AllowUnverified is the only way through, and it says so in the log.

The expression is the bare symbol name, not "&main": measured on F28379D + CCS 12.8,
`&main` fails with "cannot take address of rvalue" while `main` evaluates to the
function address (0x8A8D in the run below). `code_start` returns 0 on some builds and
is skipped, so it can never decide the verdict by itself.
#>
function Test-RamImageEvidence {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [switch]$AllowUnverified
    )

    $r = [ordered]@{ ok = $false; verified = $false; symbol = ''; address = ''; text = '' }
    $lines = Get-SessionExpressions -ProjectPath $ProjectPath -Exprs @('main', '_main', '_c_int00', 'code_start')
    if (-not $lines) {
        $r.text = 'RAM image UNVERIFIED (the session did not answer - probe offline or target halted)'
        if ($AllowUnverified) { $r.ok = $true; $r.text += ' - allowed by -AllowUnverified' }
        return $r
    }
    foreach ($line in $lines) {
        # &name and name both accepted: older builds answer "V &main 0x...", CCS 12.8
        # answers "V main 35469"; either way the value is the entry address
        $m = [regex]::Match([string]$line, '^V\s+&?(\w+)\s+(\S+)\s*$')
        if (-not $m.Success) { continue }
        $raw = $m.Groups[2].Value
        $addr = [int64]0
        $parsed = $false
        if ($raw -match '^0[xX]([0-9A-Fa-f]+)$') { $addr = [Convert]::ToInt64($Matches[1], 16); $parsed = $true }
        elseif ($raw -match '^(-?\d+)$') { $addr = [int64]$Matches[1]; $parsed = $true }
        if (-not $parsed -or $addr -le 0) { continue }
        $r.verified = $true
        $r.symbol = $m.Groups[1].Value
        $r.address = ('0x{0:X8}' -f $addr)
        if ($addr -lt $script:C28xFlashBase) {
            $r.ok = $true
            $r.text = ('running from RAM: {0} = {1} < 0x080000' -f $r.symbol, $r.address)
        } else {
            $r.ok = $false
            $r.text = ('NOT ours in RAM: {0} = {1} is in Flash (>= 0x080000)' -f $r.symbol, $r.address)
        }
        return $r
    }
    $r.text = 'RAM image UNVERIFIED (no entry symbol readable: main / _c_int00)'
    if ($AllowUnverified) { $r.ok = $true; $r.text += ' - allowed by -AllowUnverified' }
    return $r
}

<#
Invoke-LoadReadLoop -- -MaxLoads N of LoadRead: re-run this same reader once per
download, keep every attempt, stop as soon as -Expect passes. The child run is the
normal one-shot LoadRead, so there is still exactly one code path that loads.
#>
function Invoke-LoadReadLoop {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bound,
        [string[]]$Expect = @(),
        [int]$MaxLoads = 1,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$CsvPath,
        [string]$VerdictPath = '',
        [switch]$Quiet
    )

    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
    $iterDir = Join-Path $ProjectPath 'readout\loadread'
    New-Item -ItemType Directory -Path $iterDir -Force | Out-Null
    $start = [int](Get-LoadCount -ProjectPath $ProjectPath).count
    $converged = $false
    $reason = 'no attempt ran'
    $done = 0

    for ($i = 1; $i -le $MaxLoads; $i++) {
        Write-Output ('ATTEMPT : {0}/{1} (this one is download #{2})' -f $i, $MaxLoads, ($start + $i))
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
        foreach ($k in @($Bound.Keys)) {
            if ($k -eq 'MaxLoads') { continue }
            $v = $Bound[$k]
            if ($v -is [System.Management.Automation.SwitchParameter]) {
                if ($v.IsPresent) { $a += ('-' + $k) }
            } elseif ($v -is [array]) {
                $a += ('-' + $k); $a += (@($v) -join ',')
            } else {
                $a += ('-' + $k); $a += [string]$v
            }
        }
        $env:TI_C2000_LOADREAD_CHILD = '1'
        try { $out = & $pwshExe @a 2>&1; $code = $LASTEXITCODE } finally { Remove-Item Env:TI_C2000_LOADREAD_CHILD -ErrorAction SilentlyContinue }
        $done = $i
        foreach ($l in $out) { if ([string]$l -notmatch '^RESULT:') { Write-Output ([string]$l) } }

        $keep = Join-Path $iterDir ('attempt-' + $i)
        New-Item -ItemType Directory -Path $keep -Force | Out-Null
        foreach ($f in @($CsvPath, $VerdictPath)) {
            if ($f -and (Test-Path -LiteralPath $f)) { Copy-Item -LiteralPath $f -Destination (Join-Path $keep (Split-Path -Leaf $f)) -Force }
        }

        if ($code -ne 0) { $reason = ('attempt {0} failed (exit {1})' -f $i, $code); continue }
        if (@($Expect).Count -eq 0) { $converged = $true; break }

        $values = @{}
        if (Test-Path -LiteralPath $CsvPath) {
            try {
                $rows = @(Import-Csv -LiteralPath $CsvPath -Encoding utf8)
                if ($rows.Count -gt 0) {
                    foreach ($p in $rows[-1].PSObject.Properties) { $values[$p.Name] = [string]$p.Value }
                }
            } catch { }
        }
        $check = Test-LoadExpectation -Expect $Expect -Values $values
        foreach ($c in $check.checks) { Write-Output ('EXPECT  : ' + $c) }
        if ($check.ok) { $converged = $true; break }
        $reason = ('attempt {0} data did not match -Expect' -f $i)
    }

    Write-Output ('LOADS   : {0} download(s) in this loop, attempts kept in {1}' -f ($done), $iterDir)
    return [ordered]@{ converged = $converged; attempts = $done; reason = $reason }
}

<#
SKILL IDENTITY AND PROJECT HYGIENE -- the two things that make "the run went through
the skill" checkable instead of assumed.

A document can only ask an AI to use the skill; it cannot prove the run did. So every
entry point calls Initialize-SkillRun once, which
  1. refuses (or at least shouts) when the project still holds a copy of a skill
     script, because that copy is what actually executes,
  2. appends one line to <project>\readout\skill-runs.jsonl naming this script, this
     skill directory and its version, so check_project_entry.ps1 -MaxRunAgeMinutes can
     later prove the last operation came from the skill and not from somewhere else.

The version is the first 8 hex of sha256(SKILL.md): it changes when the skill changes,
so a stale copy of the skill is visible in the record.
#>
$script:SkillCopyNamePattern = '^ti_c2000_.*\.(ps1|js)$'
$script:SkillCopyExact = @('verify_on_target.ps1', 'dss_load_run_read.js', 'run_hold.js')

function Get-SkillIdentity {
    $skillRoot = Split-Path $PSScriptRoot -Parent
    $ver = 'unknown'
    $md = Join-Path $skillRoot 'SKILL.md'
    if (Test-Path -LiteralPath $md) {
        try {
            $h = (Get-FileHash -LiteralPath $md -Algorithm SHA256).Hash
            $ver = $h.Substring(0, 8).ToLower()
        } catch { }
    }
    return [ordered]@{ root = $skillRoot; version = $ver }
}

function Get-SkillScriptCopies {
    param([Parameter(Mandatory)][string]$ProjectPath)
    if (-not (Test-Path -LiteralPath $ProjectPath)) { return @() }
    return @(Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Include *.ps1, *.js -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        Where-Object { $_.Name -match $script:SkillCopyNamePattern -or $script:SkillCopyExact -contains $_.Name })
}

function Write-SkillRunRecord {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Script,
        [string]$Mode = '',
        [Parameter(Mandatory)]$Identity
    )
    $dir = Join-Path $ProjectPath 'readout'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'skill-runs.jsonl'
    $rec = [ordered]@{
        at      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        pid     = $PID
        script  = $Script
        mode    = $Mode
        skill   = $Identity.root
        version = $Identity.version
    }
    try {
        $line = ($rec | ConvertTo-Json -Compress)
        # keep the file bounded: rotate to the last 200 lines instead of growing forever
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt 120KB)) {
            $tail = @(Get-Content -LiteralPath $path -Encoding utf8 | Select-Object -Last 200)
            [IO.File]::WriteAllLines($path, $tail, (New-Object Text.UTF8Encoding($false)))
        }
        [IO.File]::AppendAllText($path, ($line + "`n"), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

<#
Initialize-SkillRun -- one call per entry point. -Block makes a project that still holds
a skill copy a hard refusal (used where the target is written: a download must not be
decided by stale logic); without it the run continues but says so.
#>
function Initialize-SkillRun {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$Script = '',
        [string]$Mode = '',
        [switch]$Block,
        [switch]$Quiet
    )
    if (-not $Script) { $Script = Split-Path -Leaf $PSCommandPath }
    $id = Get-SkillIdentity
    if (-not $Quiet) { Write-Output ('SKILL   : ti-c2000-ccs-auto@' + $id.version) }

    $copies = Get-SkillScriptCopies -ProjectPath $ProjectPath
    if ($copies.Count -gt 0) {
        if ($Block) {
            Write-Output 'FAILURE: PROJECT_NOT_CLEAN'
            Write-Output 'RESULT: FAIL'
            Write-Output ('REASON: {0} copy/copies of skill scripts sit inside the project, so the run may execute that copy instead of the skill' -f $copies.Count)
            foreach ($c in $copies | Select-Object -First 5) {
                Write-Output ('         ' + $c.FullName.Substring($ProjectPath.Length).TrimStart('\'))
            }
            Write-Output 'HINT    : delete them (they are superseded by this skill), then re-run'
            Write-Output ('HINT    : verify with check_project_entry.ps1 -ProjectPath ' + $ProjectPath)
            exit 2
        }
        Write-Output ('WARN    : {0} copy/copies of skill scripts in this project - reads may follow stale logic' -f $copies.Count)
        foreach ($c in $copies | Select-Object -First 3) {
            Write-Output ('WARN    :   ' + $c.FullName.Substring($ProjectPath.Length).TrimStart('\'))
        }
    }
    Write-SkillRunRecord -ProjectPath $ProjectPath -Script $Script -Mode $Mode -Identity $id
    # callers use the console lines; the object is kept here rather than returned so a
    # plain `Initialize-SkillRun ...` call passes the SKILL line straight through
    $script:LastSkillIdentity = $id
}