#requires -Version 7.0
# =====================================================================
# ti_c2000_debug.ps1
#   Execution workflow only: build / load / run with TI C2000 in CCS.
#   There is deliberately no read mode here. A separately started read
#   session cannot prove it is looking at the RAM image this script just
#   loaded; reading belongs to ti_c2000_run_read.ps1 / ti_c2000_read_dma.ps1,
#   which keep one DSS session from load to read.
#
#   - auto-detects the CCS installation (registry / C:\ti / %USERPROFILE%\ti)
#   - detects the XDS probe and fails fast & clearly when the board is absent
#   - load/run through loadti.bat
#
#   Usage:
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -Build -Run
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -Build -LoadOnly
#     ... -CcsRoot D:\path\to\ccs         force a CCS installation
#   Exit code: 0 OK | 1 failure | 2 environment/toolchain problem | 3 no probe
# =====================================================================
param(
    [string]$ProjectPath = "",
    [string]$CcsRoot     = "",
    [string]$Ccxml       = "",
    [string]$OutFile     = "",
    [switch]$Build,
    [switch]$AllowCompilerFallback,
    [switch]$Run,
    [switch]$LoadOnly,
    [switch]$ProbeCheckOnly,
    [switch]$NoProbeCheck,
    [int]$TimeoutSec     = 180,
    [switch]$Quiet,
    [switch]$Background,
    [string]$LogFile     = "",
    [switch]$Detached
)
$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

# A stale caller may still pass -ReadOnly/-ReadVars/-ReadArray/-WaitFor. Under
# `pwsh -File` those do not fail binding; they land in $args. Say so explicitly
# instead of silently building or loading nothing.
if ($args.Count -gt 0) {
    Out2 'FAILURE: UNKNOWN_ARGUMENT'
    Out2 'RESULT: FAIL'
    Out2 ('REASON: unrecognized argument(s): ' + ($args -join ' ') + ' - the read-only switches were removed; read with ti_c2000_run_read.ps1 or ti_c2000_read_dma.ps1')
    exit 2
}
# Reject incompatible arguments before a background process, build or loader
# can start. This script never reads values back.
if ($ProbeCheckOnly -and ($Build -or $AllowCompilerFallback -or $Run -or $LoadOnly -or $NoProbeCheck)) {
    Out2 "FAILURE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -ProbeCheckOnly cannot build, access the target or skip the probe check"
    exit 2
}
if ($AllowCompilerFallback -and -not $Build) {
    Out2 "FAILURE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -AllowCompilerFallback only applies when -Build is specified"
    exit 2
}
if ($LoadOnly -and $Run) {
    Out2 "FAILURE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -LoadOnly cannot be combined with -Run"
    exit 2
} elseif (-not $Build -and -not $Run -and -not $LoadOnly -and -not $ProbeCheckOnly) {
    Out2 "FAILURE: ACTION_REQUIRED"
    Out2 "RESULT: FAIL"
    Out2 "REASON: choose -Build, -Run, -LoadOnly or -ProbeCheckOnly; no implicit action"
    exit 2
}

# ---------- 0. detached mode ----------
# A big application may need minutes before its registers settle; an IDE/agent
# command timeout would kill such a run. -Background relaunches this script
# detached, writes everything to a log and returns immediately.
if ($Background -and -not $Detached) {
    $log = if ($LogFile) { $LogFile } else { Join-Path $env:TEMP ("ti_c2000_debug_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')) }
    $errLog = "$log.err.txt"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'Background' -or $k -eq 'LogFile') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    $argList += '-Detached'
    # ★一律用 PowerShell 7 引擎：本脚本首行是 #requires -Version 7.0，
    #   所以 $PSHOME 就是 PS7 安装目录 ——用它启动后台实例，绝不退回 Windows PowerShell 5.1
    #   （退回 5.1 时子脚本会因为自己的 #requires 直接失败：ScriptRequiresUnmatchedPSVersion）。
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }   # 兜底走 PATH
    Start-Process -FilePath $pwshExe -ArgumentList $argList -WindowStyle Hidden `
                  -RedirectStandardOutput $log -RedirectStandardError $errLog | Out-Null
    Out2 "BACKGROUND: started detached, log = $log"
    Out2 "HINT    : poll with   Select-String -Path '$log' -Pattern 'RESULT|^VAR |ready|BACKGROUND'"
    exit 0
}

# ---------- locate project ----------
if (-not $ProjectPath) {
    $d = Get-Item -LiteralPath (Get-Location).Path
    while ($d) {
        if (Test-Path (Join-Path $d.FullName '.cproject')) { $ProjectPath = $d.FullName; break }
        $d = $d.Parent
    }
}
if (-not $ProjectPath -or -not (Test-Path -LiteralPath $ProjectPath -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $ProjectPath '.cproject') -PathType Leaf)) {
    Out2 "FAILURE: NO_PROJECT"
    Out2 "RESULT: FAIL"; Out2 "REASON: project (.cproject) not found"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName
$projName = Split-Path $ProjectPath -Leaf
if (Test-Path (Join-Path $ProjectPath '.project')) {
    try {
        [xml]$prj = Get-Content -LiteralPath (Join-Path $ProjectPath '.project') -Raw
        if ($prj.projectDescription.name) { $projName = $prj.projectDescription.name }
    } catch { }
}
Info2 "PROJECT : $ProjectPath"

# ---------- 1. detect CCS installations (newest first) ----------
function Get-CcsRoots {
    $list = New-Object System.Collections.ArrayList
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Texas Instruments' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p.Version -and $p.Location) {
            $loc = ([string]$p.Location).TrimEnd('\')
            foreach ($cand in @((Join-Path $loc 'ccs'), (Join-Path $loc ("ccs" + ($p.Version -split '\.')[0])))) {
                if (Test-Path (Join-Path $cand 'ccs_base')) {
                    [void]$list.Add([pscustomobject]@{ Path = (Get-Item -LiteralPath $cand).FullName; Version = [string]$p.Version })
                    break
                }
            }
        }
    }
    foreach ($g in @("$env:USERPROFILE\ti\ccs*", 'C:\ti\ccsv*', 'C:\ti\ccs*')) {
        foreach ($cand in @(Get-Item -Path $g -ErrorAction SilentlyContinue)) {
            if ((Test-Path (Join-Path $cand.FullName 'ccs_base')) -and $cand.Name -notmatch '^ccs_base') {
                if (-not ($list | Where-Object { $_.Path -eq $cand.FullName })) {
                    $ver = '6.0'; if ($cand.Name -match 'ccs(\d+)') { $ver = $Matches[1] + '.0' }
                    [void]$list.Add([pscustomobject]@{ Path = $cand.FullName; Version = $ver })
                }
            }
        }
    }
    return @($list | Sort-Object { [double](($_.Version -split '[^\d]')[0]) } -Descending)
}
$roots = @()
if ($CcsRoot -and (Test-Path (Join-Path $CcsRoot 'ccs_base'))) {
    $roots = @([pscustomobject]@{ Path = (Get-Item -LiteralPath $CcsRoot).FullName; Version = 'forced' })
} else {
    $roots = Get-CcsRoots
}
if ($roots.Count -eq 0) { Out2 "FAILURE: ENV_NO_CCS"; Out2 "RESULT: FAIL"; Out2 "REASON: no CCS installation found"; exit 2 }
$ccs = $roots[0]
Info2 "CCS     : $($ccs.Path)  (v$($ccs.Version))"

function Get-ConnectedProbes {
    $probePatterns = 'XDS|Texas Instruments.*(Debug|Emulat|Probe)|Debug Probe|Spectrum Digital|Blackhawk|SEGGER|J-Link|ICDI'
    $found = @()
    try {
        $found = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop 2>$null |
                   Where-Object { $_.Name -match $probePatterns })
    } catch { $found = @() }
    if ($found.Count -eq 0) {
        $xdsTool = Join-Path $ccs.Path 'ccs_base\common\uscif\xds100serial.exe'
        if (Test-Path -LiteralPath $xdsTool) {
            $xdsRows = @(& $xdsTool -l 2>$null | Where-Object { $_ -match '^[0-9a-fA-F]{4}/[0-9a-fA-F]{4}\s+XDS100' })
            foreach ($row in $xdsRows) { $found += [pscustomobject]@{ Name = $row.Trim() } }
        }
    }
    return @($found)
}

function Stop-NoProbe {
    Out2 "PROBE   : NOT FOUND"
    Out2 "FAILURE: NO_PROBE"
    Out2 "RESULT: FAIL"
    Out2 "REASON: no JTAG probe enumerated by Windows (checked: XDS*, Spectrum Digital, Blackhawk, SEGGER, Debug Probe)"
    Out2 "HINT    : connect the probe and target board, then ask the operator before retrying"
    exit 3
}

# A hardware run with -Build must stop here if its probe is absent. The
# compiler must not be invoked first and an agent must not retry until the
# operator confirms the physical connection. Build-only remains hardware-free.
if ($ProbeCheckOnly -or ($Build -and ($Run -or $LoadOnly) -and -not $NoProbeCheck)) {
    $preCcxml = $Ccxml
    if (-not $preCcxml) {
        $candidate = Get-ChildItem -Path (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue |
                     Select-Object -First 1
        if ($candidate) { $preCcxml = $candidate.FullName }
    }
    if (-not $preCcxml -or -not (Test-Path -LiteralPath $preCcxml)) {
        Out2 "FAILURE: NO_CCXML"
        Out2 "RESULT: FAIL"
        Out2 "REASON: no .ccxml target configuration found - pass -Ccxml <file>"
        exit 2
    }
    $preIsSim = $false
    try {
        [xml]$preConfig = Get-Content -LiteralPath $preCcxml -Raw
        $preEmu = $preConfig.SelectSingleNode('//configuration/instance[@desc]')
        if ($preEmu -and [string]$preEmu.desc -match 'simulator|tisim') { $preIsSim = $true }
    } catch { }
    if ($preIsSim) {
        Info2 "PROBE   : skipped (simulator target)"
    } else {
        $preProbes = @(Get-ConnectedProbes)
        if ($preProbes.Count -eq 0) { Stop-NoProbe }
        foreach ($item in $preProbes) { Info2 ("PROBE   : {0}" -f $item.Name) }
    }
    if ($ProbeCheckOnly) {
        Out2 "RESULT: OK"
        exit 0
    }
}

# ---------- 2. optional build (same toolchain family) ----------
if ($Build) {
    Info2 "STEP    : build"
    $buildScript = Join-Path $PSScriptRoot 'ti_c2000_build.ps1'
    $bargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript, '-ProjectPath', $ProjectPath, '-KeepLaunches')
    if ($CcsRoot) { $bargs += @('-CcsRoot', $CcsRoot) }
    if ($AllowCompilerFallback) { $bargs += '-AllowCompilerFallback' }
    if ($Run -or $LoadOnly) { $bargs += '-Stage' }
    # ★引擎统一：用 PowerShell 7（pwsh）跑子脚本，绝不退回 Windows PowerShell 5.1
    #   （退回 5.1 时 ti_c2000_build.ps1 会因自身 #requires -Version 7.0 直接失败）
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }   # 兜底走 PATH
    $bout = & $pwshExe @bargs 2>&1
    $bcode = $LASTEXITCODE
    # one RESULT line per invocation: the build reports BUILD, not RESULT
    if (-not $Quiet) { $bout | Where-Object { [string]$_ -notmatch '^RESULT:' } | Select-Object -Last 12 | ForEach-Object { Out2 $_ } }
    if ($bcode -eq 0) { Info2 'BUILD   : OK' }
    if ($bcode -ne 0 -or -not @($bout | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
        $bfail = @($bout | Where-Object { $_ -match '^FAILURE: ' }) | Select-Object -First 1
        if (-not $bfail) { $bfail = 'FAILURE: BUILD_FAILED' }
        Out2 $bfail
        Out2 "RESULT: FAIL"
        Out2 "REASON: build failed - debugger step aborted (see the build script output / its build.log)"
        exit 1
    }
    if (-not $Run -and -not $LoadOnly) {
        Out2 "NOTE    : build completed; no download or run requested"
        Out2 "RESULT: OK"
        exit 0
    }
}

# ---------- 3. resolve .out / .ccxml / tools ----------
if (-not $OutFile) { $OutFile = Join-Path $ProjectPath "Debug\$projName.out" }
if (-not (Test-Path -LiteralPath $OutFile)) {
    Out2 "FAILURE: NO_OUT_FILE"
    Out2 "RESULT: FAIL"; Out2 "REASON: $OutFile not found - run the build first (add -Build)"; exit 2
}
if (-not $Ccxml) {
    $c = Get-ChildItem -Path (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($c) { $Ccxml = $c.FullName }
}
if (-not $Ccxml -or -not (Test-Path -LiteralPath $Ccxml)) {
    Out2 "FAILURE: NO_CCXML"
    Out2 "RESULT: FAIL"; Out2 "REASON: no .ccxml target configuration found - pass -Ccxml <file>"; exit 2
}
# what device / emulator does this target configuration ask for?
$ccxmlEmu = ''; $ccxmlDev = ''; $isSim = $false
try {
    [xml]$cc = Get-Content -LiteralPath $Ccxml -Raw
    $n = $cc.SelectSingleNode("//configuration/instance[@desc]")
    if ($n) { $ccxmlEmu = [string]$n.desc }
    $n = $cc.SelectSingleNode("//platform/instance[@id]")
    if ($n) { $ccxmlDev = [string]$n.id }
} catch { }
if (-not $ccxmlEmu) { $ccxmlEmu = '<unknown>' }
if (-not $ccxmlDev) { $ccxmlDev = '<unknown>' }
if ($ccxmlEmu -match 'simulator|tisim') { $isSim = $true }
Info2 "TARGET  : $ccxmlDev  via  $ccxmlEmu$(if ($isSim) { '  [simulator]' })"

$loadti = Join-Path $ccs.Path 'ccs_base\scripting\examples\loadti\loadti.bat'
if (-not (Test-Path $loadti)) {
    foreach ($r in $roots) {
        $c = Join-Path $r.Path 'ccs_base\scripting\examples\loadti\loadti.bat'
        if (Test-Path $c) { $loadti = $c; break }
    }
}
if (-not (Test-Path -LiteralPath $loadti)) {
    Out2 "FAILURE: ENV_NO_LOADTI"; Out2 "RESULT: FAIL"; Out2 "REASON: loadti.bat not found under any CCS installation"; exit 2
}
Info2 "OUTCARD : $OutFile"
Info2 "CCXML   : $Ccxml"
Info2 "LOADTI  : $loadti"

# ---------- 4. probe / GUI pre-flight ----------
$probe = @()
if (-not $isSim -and -not $NoProbeCheck) {
    $probe = @(Get-ConnectedProbes)
}
if ($isSim) {
    Info2 "PROBE   : skipped (simulator target, no hardware needed)"
    $probe = @([pscustomobject]@{ Name = 'TI simulator' })
} elseif ($NoProbeCheck) {
    Info2 "PROBE   : check skipped by -NoProbeCheck"
} elseif ($probe.Count -eq 0) {
    Stop-NoProbe
} else {
    foreach ($p in $probe) { Info2 ("PROBE   : {0}" -f $p.Name) }
}
if (@(Get-Process ccstudio, ccstudio64, eclipsec -ErrorAction SilentlyContinue).Count -gt 0) {
    Info2 "WARN    : CCS GUI is running - close any active debug session if the JTAG turns out to be busy"
}

# ---------- 5. loadti path ----------
# -Build alone returned above, and ACTION_REQUIRED covers "no action at all".
# Reaching this point without an explicit download request must never turn
# into an implicit load (that used to download and halt the target silently).
if (-not $LoadOnly -and -not $Run) {
    Out2 "FAILURE: ACTION_REQUIRED"
    Out2 "RESULT: FAIL"
    Out2 "REASON: no download requested; add -Run or -LoadOnly, or use -Build alone"
    exit 2
}
$ltArgs = @("-c=$Ccxml")
if ($LoadOnly) { $ltArgs += '-l' }
else           { $ltArgs += @('-r', '-a') }
$ltArgs += "-t=$($TimeoutSec * 1000)"
$ltArgs += $OutFile
Info2 ("STEP    : loadti {0}" -f ($ltArgs -join ' '))
# PowerShell 7 can throw StandardOutputEncoding before a .bat starts. Use
# cmd.exe through ProcessStartInfo so paths containing spaces retain cmd's
# required quoting; PowerShell's native argument re-quoting is bypassed.
function Quote-CmdArgument([string]$value) {
    if ($value -match '["%\r\n]') { throw "unsupported character in loadti path or argument" }
    return '"' + $value + '"'
}
try {
    $command = (Quote-CmdArgument $loadti) + ' ' + (($ltArgs | ForEach-Object { Quote-CmdArgument $_ }) -join ' ')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    $start.Arguments = '/d /v:off /s /c "' + $command + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $waitMs = [int][Math]::Min(2147483647L, ([long]$TimeoutSec * 1000L + 30000L))
    $expired = -not $process.WaitForExit($waitMs)
    if ($expired) { $process.Kill($true); $process.WaitForExit() }
    $out = @((($stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()) -split '\r?\n') |
             Where-Object { $_ -ne '' })
    $code = $process.ExitCode
    $process.Dispose()
} catch {
    Out2 "FAILURE: LOADTI_LAUNCH_ERROR"
    Out2 "RESULT: FAIL"
    Out2 "REASON: loadti could not be started: $($_.Exception.Message)"
    exit 1
}
if (-not $Quiet) { $out | Select-Object -Last 25 | ForEach-Object { Out2 $_ } }
$bad    = @($out | Where-Object { $_ -match 'error|failed|cannot|aborted' })
$ldDone = @($out | Where-Object { $_ -match '\bDone\b' })
$runSeen = @($out | Where-Object { $_ -match '^Target running\.\.\.' })
if ($expired -or $code -ne 0 -or $bad.Count -gt 0 -or $ldDone.Count -eq 0 -or ($Run -and $runSeen.Count -eq 0)) {
    if ($expired) {
        Out2 "FAILURE: LOADTI_TIMEOUT"
        Out2 "REASON: loadti exceeded its $TimeoutSec s target timeout"
    } elseif ($code -ne 0 -or $bad.Count -gt 0) {
        Out2 "FAILURE: LOADTI_ERROR"
        Out2 "REASON: loadti exited with code $code or reported an error"
        $bad | Select-Object -First 3 | ForEach-Object { Out2 ("    " + $_) }
    } else {
        Out2 "FAILURE: LOADTI_INCOMPLETE"
        Out2 "REASON: loadti exited without the required Done and Target running markers"
    }
    Out2 "RESULT: FAIL"
    exit 1
}
if ($LoadOnly) { Out2 "NOTE    : program loaded and halted (no run requested)" }
elseif ($Run)  { Out2 "NOTE    : program started on target (async run)" }
Out2 "NOTE    : no values were read here; use ti_c2000_run_read.ps1 for a same-session read"
Out2 "RESULT: OK"
exit 0
