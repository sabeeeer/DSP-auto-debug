#requires -Version 7.0
<#
ti_c2000_live_read.ps1 -- read a running target without touching it.

Attaches to the service started by ti_c2000_service.ps1 and asks it for values.
Nothing is reset, reloaded or halted here: the session that loaded the RAM image
is still open, the target is still running, so every read describes the same
program. That is the whole point -- a reader that reconnects and reloads makes
two consecutive reads describe two different runs.

Protocol (files in <project>\readout\.service):
  request  cmd.txt : "VARS a|b|c" | "ARRAY name|rows|cols" | "PING" | "STOP"
  response res.txt : HALTED 0|1, "V <name> <value>", "A <index> <value>",
                     "E <message>", then END

Verdict: heartbeat must advance across rounds, the frozen window must not change
while it is being copied, and the service must still hold the same .out (its
sha256 is stored when the session loaded it). The startup-window check of the
one-shot readers is NOT applied here: a long-running session legitimately has a
large tick value.

Exit code: 0 OK | 1 verdict/read failure | 2 environment/argument problem
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [string[]]$Variables = @(),
    [string]$ArrayName = '',
    [int]$Rows = 1,
    [int]$Columns = 1,
    [string]$FrozenFlag = 'gBufFull',
    [string]$FrozenValue = 'true',
    [string]$SeqVar = 'gBufSeq',
    [string]$HeartbeatExpr = 'gMsTick,gRunMs,usMainLoop',
    [int]$Rounds = 10,
    [int]$IntervalMs = 500,
    [int]$RequestTimeoutMs = 15000,
    [int]$ValueMin = [int]::MinValue,
    [int]$ValueMax = [int]::MaxValue,
    [switch]$NoHeartbeat,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) {
    Out2 'FAILURE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName
$names = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names.Count -eq 0 -and -not $ArrayName) {
    Out2 'FAILURE: NEED_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: pass -Variables or -ArrayName'; exit 2
}
if ($names.Count -gt 0 -and $ArrayName) {
    Out2 'FAILURE: AMBIGUOUS_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: use -Variables or -ArrayName, not both'; exit 2
}
if ($NoHeartbeat) { $HeartbeatExpr = '' }
$heartbeats = @($HeartbeatExpr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$svcDir = Join-Path $ProjectPath 'readout\.service'
$stateFile = Join-Path $svcDir 'state.json'
$readyFile = Join-Path $svcDir 'ready.txt'
$cmdFile = Join-Path $svcDir 'cmd.txt'
$resFile = Join-Path $svcDir 'res.txt'

function Get-ServiceState {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try { return (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json) } catch { return $null }
}

$state = Get-ServiceState
$alive = $false
if ($state -and (Test-Path -LiteralPath $readyFile)) {
    $alive = [bool](Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue)
}
if (-not $alive) {
    Out2 'FAILURE: NO_SERVICE'; Out2 'RESULT: FAIL'
    Out2 ('REASON: no running session for this project - start it once with: pwsh -File ti_c2000_service.ps1 -ProjectPath "{0}" -Start' -f $ProjectPath)
    exit 2
}
$svcPid = [int]$state.pid

# the session may still hold an image that was replaced on disk since it started
if (Test-Path -LiteralPath $state.out) {
    $nowSha = (Get-FileHash -LiteralPath $state.out -Algorithm SHA256).Hash
    if ($nowSha -ne $state.outSha256) {
        Out2 'FAILURE: STALE_SERVICE'; Out2 'RESULT: FAIL'
        Out2 ('REASON: {0} changed after the session loaded it - restart the service so a read cannot describe a stale image' -f (Split-Path -Leaf $state.out))
        exit 2
    }
}

function Send-Request([string]$Text, [int]$TimeoutMs) {
    if (Test-Path -LiteralPath $resFile) { Remove-Item -LiteralPath $resFile -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText($cmdFile, $Text, [Text.Encoding]::ASCII)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resFile) { return (Get-Content -LiteralPath $resFile -Raw) }
        if (-not (Get-Process -Id $svcPid -ErrorAction SilentlyContinue)) { return $null }
        Start-Sleep -Milliseconds 40
    }
    return $null
}
function ConvertFrom-Response([string]$raw) {
    $o = [ordered]@{ halted = $false; end = $false; vars = [ordered]@{}; arr = [ordered]@{}; errors = @() }
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^HALTED ([01])\s*$') { $o.halted = ($Matches[1] -eq '1') }
        elseif ($line -match '^V (\S+) (.*)$') { $o.vars[$Matches[1]] = $Matches[2].Trim() }
        elseif ($line -match '^A (\d+) (\S+)\s*$') { $o.arr[[int]$Matches[1]] = $Matches[2] }
        elseif ($line -match '^E (.*)$') { $o.errors += $Matches[1] }
        elseif ($line -match '^END\s*$') { $o.end = $true }
    }
    return $o
}
function Request([string]$Text) {
    $raw = Send-Request $Text $RequestTimeoutMs
    if ($null -eq $raw) {
        Out2 'FAILURE: SERVICE_TIMEOUT'; Out2 'RESULT: FAIL'
        Out2 ('REASON: no response within {0} ms - is the target still running? see {1}' -f $RequestTimeoutMs, (Join-Path $svcDir 'server.log'))
        exit 1
    }
    $r = ConvertFrom-Response $raw
    if (-not $r.end) {
        Out2 'FAILURE: SERVICE_PROTOCOL'; Out2 'RESULT: FAIL'
        Out2 'REASON: response had no END marker; restart the service'; exit 1
    }
    if ($r.halted) {
        Out2 'FAILURE: TARGET_HALTED_DURING_READ'; Out2 'RESULT: FAIL'
        Out2 'REASON: the target is halted, so its RAM is not a running state'; exit 1
    }
    if ($r.errors.Count -gt 0) {
        Out2 'FAILURE: VALUE_READ_FAILED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: ' + ($r.errors -join '; ')); exit 1
    }
    return $r
}

$dataDir = Join-Path $ProjectPath 'readout\data'
$checkDir = Join-Path $ProjectPath 'readout\check'
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
New-Item -ItemType Directory -Path $checkDir -Force | Out-Null
$utf8Bom = New-Object Text.UTF8Encoding($true)
$verdictScript = Join-Path $PSScriptRoot 'ti_c2000_check_read.ps1'
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

Info2 "PROJECT : $ProjectPath"
Info2 ('SERVICE : pid {0}, loaded {1}' -f $svcPid, $state.started)
Info2 'MODE    : ReadOnly attach - this process never downloads'
. (Join-Path $PSScriptRoot 'ti_c2000_loadcount.ps1')
$loadIdx = $state.loadIndex
if (-not $loadIdx) {
    $cn = Get-LoadCount -ProjectPath $ProjectPath
    if ($state.outSha256 -and $state.outSha256 -eq $cn.lastSha256) { $loadIdx = $cn.count }
}
Info2 ('LOAD    : #{0} (this session), reads never download' -f $(if ($loadIdx) { $loadIdx } else { '?' }))
Info2 ('OUT     : {0}' -f $state.out)

# ---------------------------------------------------------------- array ------
if ($ArrayName) {
    $total = $Rows * $Columns
    if ($FrozenFlag) {
        # a build without the freeze flag has nothing safe to copy; say so plainly
        # instead of failing with a generic symbol error
        $probeRaw = Send-Request ('VARS ' + $FrozenFlag) $RequestTimeoutMs
        if ($null -eq $probeRaw) {
            Out2 'FAILURE: SERVICE_TIMEOUT'; Out2 'RESULT: FAIL'
            Out2 ('REASON: no response within {0} ms - see {1}' -f $RequestTimeoutMs, (Join-Path $svcDir 'server.log')); exit 1
        }
        $probe = ConvertFrom-Response $probeRaw
        if ($probe.errors.Count -gt 0) {
            if (($probe.errors -join ';') -match 'identifier not found') {
                Out2 'FAILURE: NO_FROZEN_FLAG'; Out2 'RESULT: FAIL'
                Out2 ('REASON: this build has no {0} - the firmware never freezes a buffer, so there is no consistent window to copy' -f $FrozenFlag)
                exit 1
            }
            Out2 'FAILURE: VALUE_READ_FAILED'; Out2 'RESULT: FAIL'
            Out2 ('REASON: ' + ($probe.errors -join '; ')); exit 1
        }
    }
    $pre = Request (('VARS ' + $FrozenFlag + '|' + $SeqVar).Trim('|'))
    $arr = Request ('ARRAY ' + $ArrayName + '|' + $Rows + '|' + $Columns)
    $post = Request (('VARS ' + $FrozenFlag + '|' + $SeqVar).Trim('|'))

    $preFlag = [string]$pre.vars[$FrozenFlag]
    $postFlag = [string]$post.vars[$FrozenFlag]
    if ($FrozenFlag -and $preFlag -ne $postFlag) {
        Out2 'FAILURE: BUF_CHANGED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: {0} changed while copying ({1} -> {2})' -f $FrozenFlag, $preFlag, $postFlag); exit 1
    }
    if ($SeqVar) {
        $preSeq = [string]$pre.vars[$SeqVar]
        $postSeq = [string]$post.vars[$SeqVar]
        if ($preSeq -ne $postSeq) {
            Out2 'FAILURE: BUF_CHANGED'; Out2 'RESULT: FAIL'
            Out2 ('REASON: {0} changed while copying ({1} -> {2})' -f $SeqVar, $preSeq, $postSeq); exit 1
        }
    }
    if ($arr.arr.Count -ne $total) {
        Out2 'FAILURE: COUNT_MISMATCH'; Out2 'RESULT: FAIL'
        Out2 ('REASON: got {0} values, expected {1}' -f $arr.arr.Count, $total); exit 1
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('index,value')
    for ($i = 0; $i -lt $total; $i++) { $lines.Add(('{0},{1}' -f $i, $arr.arr[$i])) }
    $csvPath = Join-Path $dataDir 'array.csv'
    [IO.File]::WriteAllLines($csvPath, $lines, $utf8Bom)

    # anchor: the first element must read the same both ways while the buffer is frozen
    $anchor = Request ('VARS ' + $ArrayName + '[0]')
    $anchorVal = [string]$anchor.vars[($ArrayName + '[0]')]
    if ($anchorVal -match '^-?\d+$' -and ([int64]$arr.arr[0]) -ne ([int64]$anchorVal)) {
        Out2 'FAILURE: ARRAY_LAYOUT_MISMATCH'; Out2 'RESULT: FAIL'
        Out2 ('REASON: {0}[0] evaluate={1} readData={2}' -f $ArrayName, $anchorVal, $arr.arr[0]); exit 1
    }

    $mapLines = New-Object System.Collections.Generic.List[string]
    $mapLines.Add('role,name,first,last,delta,status')
    $mapLines.Add(('array,{0},,,,OK' -f $ArrayName))
    $mapLines.Add(('frozen,{0},{1},{2},,OK' -f $FrozenFlag, $preFlag, $postFlag))
    if ($SeqVar) { $mapLines.Add(('sequence,{0},{1},{2},,OK' -f $SeqVar, $pre.vars[$SeqVar], $post.vars[$SeqVar])) }
    [IO.File]::WriteAllLines((Join-Path $checkDir 'variables.csv'), $mapLines, $utf8Bom)

    $vout = & $pwshExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verdictScript,
        '-CsvPath', $csvPath, '-AllowNoHeartbeat') 2>&1
    $vcode = $LASTEXITCODE
    foreach ($l in $vout) { if ([string]$l -notmatch '^RESULT:') { Out2 ([string]$l) } }
    if ($vcode -ne 0) {
        Out2 'FAILURE: ARRAY_VERDICT_FAILED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: verdict on {0} failed' -f $csvPath); exit 1
    }
    $verdict = @(
        'result: OK', 'mode: live-service (no reload)', ('service_pid: ' + $svcPid),
        ('service_started: ' + $state.started), ('out: ' + $state.out), ('out_sha256: ' + $state.outSha256),
        ('array: {0} ({1}x{2}={3})' -f $ArrayName, $Rows, $Columns, $total),
        ('frozen: {0} = {1}' -f $FrozenFlag, $preFlag),
        ('data: ' + $csvPath)
    )
    [IO.File]::WriteAllLines((Join-Path $checkDir 'verdict.txt'), $verdict, $utf8Bom)
    Out2 ('DATA    : {0}' -f $csvPath)
    Out2 ('VERDICT : {0}' -f (Join-Path $checkDir 'verdict.txt'))
    Out2 ('VALUES  : {0}' -f $total)
    Out2 'RESULT: OK'
    exit 0
}

# ------------------------------------------------------------- variables -----
# NOT $rounds: PowerShell variable names are case-insensitive, so that would
# collide with the -Rounds parameter and fail as an array-to-Int32 conversion.
$samples = @()
for ($r = 1; $r -le $Rounds; $r++) {
    $resp = Request ('VARS ' + ($names -join '|'))
    $now = Get-Date
    $uptime = ($now - (Get-Process -Id $svcPid).StartTime).TotalMilliseconds
    $samples += [ordered]@{ round = $r; hostMs = [int64]$uptime; hostTime = $now.ToString('HH:mm:ss.fff'); vars = $resp.vars }
    if ($r -lt $Rounds) { Start-Sleep -Milliseconds $IntervalMs }
}

# heartbeat must advance in the live session (no startup-window check: it can run for hours)
# a candidate the build does not define is normal - only a readable-but-frozen
# candidate is a failure, and at least one must be readable to claim liveness
$hbOk = $false
$hbFailed = @()
$hbChecked = @()
$mapLines = New-Object System.Collections.Generic.List[string]
$mapLines.Add('role,name,first,last,delta,status')
foreach ($hn in $heartbeats) {
    $vals = @($samples | ForEach-Object { $_.vars[$hn] })
    if ($vals.Count -eq 0 -or @($vals | Where-Object { $_ -eq $null -or $_ -eq '' }).Count -gt 0) {
        $mapLines.Add(('heartbeat,{0},,,,MISSING' -f $hn))
        Out2 ('CHECK heartbeat {0}: MISSING (not defined in this build)' -f $hn)
        continue
    }
    $hbChecked += $hn
    $bad = 0
    $candidateOk = $true
    for ($i = 1; $i -lt $vals.Count; $i++) {
        $prev = 0.0; $cur = 0.0
        $prevOk = [double]::TryParse([string]$vals[$i - 1], [ref]$prev)
        $curOk = [double]::TryParse([string]$vals[$i], [ref]$cur)
        if ($prevOk -and $curOk -and $cur -gt $prev) { $bad = 0; continue }
        $bad++
        Out2 ('CHECK heartbeat {0}: round {1} not increasing ({2} -> {3})' -f $hn, ($i + 1), $vals[$i - 1], $vals[$i])
        if ($bad -ge 2 -or $vals.Count -eq 2 -or -not $prevOk -or -not $curOk) { $candidateOk = $false }
    }
    $delta = 0
    $f = 0.0; $l = 0.0
    if ([double]::TryParse([string]$vals[0], [ref]$f) -and [double]::TryParse([string]$vals[-1], [ref]$l)) { $delta = $l - $f }
    if ($candidateOk) { $hbOk = $true } else { $hbFailed += $hn }
    $mapLines.Add(('heartbeat,{0},{1},{2},{3},{4}' -f $hn, $vals[0], $vals[-1], $delta, $(if ($candidateOk) { 'OK' } else { 'FAIL' })))
}
if ($hbChecked.Count -eq 0) { Out2 'CHECK heartbeat: no readable candidate, liveness unverified' }
foreach ($n in $names) { $mapLines.Add(('variable,{0},,,,' -f $n)) }
[IO.File]::WriteAllLines((Join-Path $checkDir 'variables.csv'), $mapLines, $utf8Bom)

$csv = New-Object System.Collections.Generic.List[string]
$csv.Add(('round,hostMs,hostTime,' + ($names -join ',')))
foreach ($row in $samples) {
    $vals = @($names | ForEach-Object { $row.vars[$_] })
    $csv.Add(('{0},{1},{2},{3}' -f $row.round, $row.hostMs, $row.hostTime, ($vals -join ',')))
}
$csvPath = Join-Path $dataDir 'data.csv'
[IO.File]::WriteAllLines($csvPath, $csv, $utf8Bom)

if ($heartbeats.Count -gt 0 -and $hbOk) { Out2 'HEARTBEAT: OK (all candidates increased)' }
elseif ($heartbeats.Count -gt 0) { Out2 'HEARTBEAT: FAIL' }

$vargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verdictScript,
    '-CsvPath', $csvPath, '-RangeVars', ($names -join ','))
if ($hbChecked.Count -gt 0) { $vargs += @('-HeartbeatVars', ($hbChecked -join ',')) } else { $vargs += '-AllowNoHeartbeat' }
if ($ValueMin -ne [int]::MinValue) { $vargs += @('-ValueMin', [string]$ValueMin) }
if ($ValueMax -ne [int]::MaxValue) { $vargs += @('-ValueMax', [string]$ValueMax) }
$vout = & $pwshExe @vargs 2>&1
$vcode = $LASTEXITCODE
# HEARTBEAT was already reported above; do not let the verdict repeat it
foreach ($l in $vout) { if ([string]$l -notmatch '^(RESULT|HEARTBEAT):') { Out2 ([string]$l) } }

$verdictResult = if ($vcode -eq 0 -and $hbOk) { 'OK' } else { 'FAIL' }
$verdict = @(
    ('result: ' + $verdictResult), 'mode: live-service (no reload)', ('service_pid: ' + $svcPid),
    ('service_started: ' + $state.started), ('out: ' + $state.out), ('out_sha256: ' + $state.outSha256),
    ('rounds: {0} x {1} ms' -f $Rounds, $IntervalMs), ('variables: ' + ($names -join ', ')),
    ('heartbeat: ' + $(if ($heartbeats.Count -eq 0) { 'SKIPPED' } elseif ($hbOk) { 'OK' } else { 'FAIL' })),
    ('data: ' + $csvPath)
)
[IO.File]::WriteAllLines((Join-Path $checkDir 'verdict.txt'), $verdict, $utf8Bom)

Out2 ('DATA    : {0}' -f $csvPath)
Out2 ('VERDICT : {0}' -f (Join-Path $checkDir 'verdict.txt'))
Out2 ('VALUES  : {0}' -f ($Rounds * $names.Count))

if (-not $hbOk) {
    Out2 'FAILURE: HEARTBEAT_FAIL'; Out2 'RESULT: FAIL'
    Out2 ('REASON: heartbeat did not advance in the live session (not increasing: ' + ($hbFailed -join ', ') + ')')
    exit 1
}
if ($vcode -ne 0) {
    Out2 'FAILURE: VERDICT_FAILED'; Out2 'RESULT: FAIL'
    Out2 ('REASON: verdict on {0} failed' -f $csvPath); exit 1
}
Out2 'RESULT: OK'
exit 0
