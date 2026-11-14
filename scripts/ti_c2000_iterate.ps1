#requires -Version 7.0
<#
ti_c2000_iterate.ps1 -- RUN MODE = Iterate: the continuous mode. Re-build, re-download,
re-read, judge, and repeat until the data is right.

Ordinary work is SingleStep: ti_c2000_service.ps1 loads once and stays alive, and every
read attaches to that one session. This script is the exception, and it exists only for
the case the user asks for by name:

    "连续运行" / "反复编译下载直到数据对/实验现象成功"

So it refuses to start without -UserApproved. That switch is the user's yes: it covers
both "continuous" and the repeated downloads inside the loop, which is why this script
passes -ConfirmLoad to the service on every round.

ONE ROUND (nothing here is a private download path):
  1. ti_c2000_service.ps1 -Stop ......... release the previous round's session
  2. ti_c2000_service.ps1 -Start -Build -ConfirmLoad -RunMode Iterate
                                         the one place that loads -> LOAD #N goes up
  3. ti_c2000_run_read.ps1 -Mode ReadOnly
                                         attaches to the session that just started and
                                         proves RAM + sha + heartbeat; still no download
  4. Test-LoadExpectation on the last CSV row
     - all checks pass -> converged, RESULT: OK (exit 0)
     - otherwise       -> next round, up to -MaxLoads

INTERLOCKS (see ti_c2000_readmode.ps1):
  without -UserApproved                -> ITERATE_NOT_APPROVED exit 4
  another continuous run in progress   -> ITERATE_IN_PROGRESS   exit 4
  while this runs, ReadOnly / LoadRead / Start / Stop from outside
                                       -> READONLY_IN_ITERATE / MUTUALLY_EXCLUSIVE /
                                          ITERATE_IN_PROGRESS
  the loop's own children carry TI_C2000_ITERATE_CHILD=1, which lifts the MARKER
  check only - it is not an approval bypass (every child still passes -UserApproved
  explicitly, and Resolve-RunModeSpec never honours the flag)

Evidence: readout\iterate\active.json (marker + owning pid), readout\iterate\round-N\
(the session log, the CSV and the verdict of each round). A marker left by a dead
process is ignored, so a crash never locks the project for good.

Exit code: 0 OK | 1 failure (build failed / never converged) | 2 argument or environment
           3 no probe | 4 not approved | 5 target held elsewhere
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    # the user's yes to "run continuously, rebuild and download until the data is right"
    [switch]$UserApproved,
    [string[]]$Variables = @(),
    # name>=value / name<=value / name==value ... empty means "a successful read converges"
    [string[]]$Expect = @(),
    [int]$MaxLoads = 5,
    [int]$Rounds = 5,
    [int]$IntervalMs = 500,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    # continuous mode is about rebuilding as well; -NoBuild only re-downloads
    [switch]$NoBuild,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }
# child output is echoed once, and only the lines a caller must see
function Show-KeyLines($arr) {
    foreach ($l in $arr) {
        $s = [string]$l
        if ($s -match '^(FAILURE|REASON|HINT|LOAD|RUN MODE|SERVICE|EXPECT|JUDGE)') { Out2 $s }
    }
}
. (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')

if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) {
    Out2 'FAILURE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName

# ---- interlock: this IS the continuous mode, so it needs the user's yes --------
$runSpec = Resolve-RunModeSpec -RunMode 'Iterate' -ConfirmLoad -UserApproved:$UserApproved -MaxLoads $MaxLoads

$vars = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($vars.Count -eq 0) {
    Out2 'FAILURE: NEED_VARIABLES'; Out2 'RESULT: FAIL'
    Out2 'REASON: -Variables is what each round reads; without it a round can prove nothing'
    Out2 'HINT    : e.g. -Variables "gBufSeq,gErr" -Expect "gBufSeq>=3","gErr==0"'
    exit 2
}
$checks = @($Expect | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })

# nothing else may own the target, and no other iterate may be running
Assert-RunModeInterlock -ProjectPath $ProjectPath -What 'ti_c2000_iterate.ps1'

# this loop re-downloads every round, so it is one of the places a stale copy would be
# most expensive: refuse to start while the project still holds one
Initialize-SkillRun -ProjectPath $ProjectPath -Script 'ti_c2000_iterate.ps1' -Mode 'Iterate' -Block -Quiet:$Quiet

$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
$svcScript = Join-Path $PSScriptRoot 'ti_c2000_service.ps1'
$readScript = Join-Path $PSScriptRoot 'ti_c2000_run_read.ps1'
foreach ($p in @($svcScript, $readScript)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Out2 'FAILURE: ENV_MISSING_SCRIPT'; Out2 'RESULT: FAIL'; Out2 "REASON: '$p' is missing from this skill installation"; exit 2
    }
}

$common = @('-ProjectPath', $ProjectPath)
if ($Ccxml) { $common += @('-Ccxml', $Ccxml) }
if ($OutFile) { $common += @('-OutFile', $OutFile) }
if ($CcsRoot) { $common += @('-CcsRoot', $CcsRoot) }

$iterDir = Join-Path $ProjectPath 'readout\iterate'
$dataCsv = Join-Path $ProjectPath 'readout\data\data.csv'
$startCount = [int](Get-LoadCount -ProjectPath $ProjectPath).count
$converged = $false
$hardFail = $false
$reason = 'no round ran'
$roundsRun = 0

function Get-LastCsvRow([string]$Path) {
    $h = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $h }
    try {
        $rows = @(Import-Csv -LiteralPath $Path -Encoding utf8)
        if ($rows.Count -eq 0) { return $h }
        foreach ($p in $rows[-1].PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
    } catch { }
    return $h
}

Info2 ('ITERATE : continuous run (max {0} downloads, {1} check(s), project {2})' -f $MaxLoads, $checks.Count, (Split-Path -Leaf $ProjectPath))
Info2 'RUN MODE: Iterate - this loop stops, rebuilds and re-downloads every round'
Info2 ('VARS    : ' + ($vars -join ', '))
if ($checks.Count -gt 0) { Info2 ('EXPECT  : ' + ($checks -join ' ; ')) }

# the marker keeps every other entry point out while the loop runs; children inherit
# the child flag so they may work underneath it
Set-IterateMarker -ProjectPath $ProjectPath -Round 0 -MaxLoads $MaxLoads -Expect $checks
$env:TI_C2000_ITERATE_CHILD = '1'
try {
    for ($i = 1; $i -le $MaxLoads; $i++) {
        $roundsRun = $i
        Set-IterateMarker -ProjectPath $ProjectPath -Round $i -MaxLoads $MaxLoads -Expect $checks
        $roundDir = Join-Path $iterDir ('round-' + $i)
        New-Item -ItemType Directory -Path $roundDir -Force | Out-Null
        $roundLog = Join-Path $roundDir 'round.log'
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add(('ROUND {0}/{1}  {2}' -f $i, $MaxLoads, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
        Info2 ('ROUND   : {0}/{1}  stop -> build -> download -> read -> judge' -f $i, $MaxLoads)

        # 1) release the previous round's session (no-op when nothing runs)
        $stopArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $svcScript) + $common + @('-Stop', '-Quiet')
        $stopOut = @(& $pwshExe @stopArgs 2>&1)
        $stopCode = $LASTEXITCODE
        foreach ($l in $stopOut) { $lines.Add('[stop] ' + [string]$l) }
        if ($stopCode -ne 0) {
            Show-KeyLines $stopOut
            $reason = ('round {0}: the previous session could not be stopped (exit {1})' -f $i, $stopCode)
            Out2 'FAILURE: ITERATE_ROUND_FAILED'; Out2 ('REASON: ' + $reason)
            $hardFail = $true
            break
        }

        # 2) download once - the only place that loads, still
        $startArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $svcScript) + $common +
                     @('-Start', '-ConfirmLoad', '-RunMode', 'Iterate', '-UserApproved')
        if (-not $NoBuild) { $startArgs += '-Build' }
        if (-not $Quiet) { $startArgs += '-Quiet' }
        $startOut = @(& $pwshExe @startArgs 2>&1)
        $startCode = $LASTEXITCODE
        foreach ($l in $startOut) { $lines.Add('[start] ' + [string]$l) }
        Show-KeyLines $startOut
        if ($startCode -ne 0) {
            # a build/link/load failure will not fix itself on the next round
            $reason = ('round {0}: download failed (exit {1})' -f $i, $startCode)
            Out2 'FAILURE: ITERATE_ROUND_FAILED'; Out2 ('REASON: ' + $reason)
            $hardFail = $true
            break
        }

        # 3) read the session that this round loaded - ReadOnly, never a download
        $readArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $readScript) + $common +
                    @('-Mode', 'ReadOnly', '-Variables', ($vars -join ','), '-Rounds', [string]$Rounds, '-IntervalMs', [string]$IntervalMs)
        if (-not $Quiet) { $readArgs += '-Quiet' }
        $readOut = @(& $pwshExe @readArgs 2>&1)
        $readCode = $LASTEXITCODE
        foreach ($l in $readOut) { $lines.Add('[read] ' + [string]$l) }
        if (Test-Path -LiteralPath $dataCsv) { Copy-Item -LiteralPath $dataCsv -Destination (Join-Path $roundDir 'data.csv') -Force }

        if ($readCode -ne 0) {
            Show-KeyLines $readOut
            $reason = ('round {0}: read failed (exit {1}) - data not usable' -f $i, $readCode)
            $lines.Add('VERDICT: read failed, next round')
            [IO.File]::WriteAllLines($roundLog, $lines, (New-Object Text.UTF8Encoding($false)))
            Info2 ('ROUND   : {0} data not usable, next round' -f $i)
            continue
        }

        if ($checks.Count -eq 0) {
            $converged = $true
            $lines.Add('VERDICT: read OK (no -Expect given)')
            [IO.File]::WriteAllLines($roundLog, $lines, (New-Object Text.UTF8Encoding($false)))
            Info2 ('ROUND   : {0} read OK - no -Expect given, converged' -f $i)
            break
        }

        $values = Get-LastCsvRow -Path $dataCsv
        $check = Test-LoadExpectation -Expect $checks -Values $values
        foreach ($c in $check.checks) {
            Out2 ('EXPECT  : ' + $c)
            $lines.Add('EXPECT  : ' + $c)
        }
        if ($check.ok) {
            $converged = $true
            $lines.Add('VERDICT: converged')
            [IO.File]::WriteAllLines($roundLog, $lines, (New-Object Text.UTF8Encoding($false)))
            Info2 ('ROUND   : {0} every check passed - converged, no more downloads' -f $i)
            break
        }
        $reason = ('round {0}: data did not match -Expect' -f $i)
        $lines.Add('VERDICT: not converged, next round')
        [IO.File]::WriteAllLines($roundLog, $lines, (New-Object Text.UTF8Encoding($false)))
        Info2 ('ROUND   : {0} not right yet, next round' -f $i)
    }
} finally {
    Remove-Item Env:TI_C2000_ITERATE_CHILD -ErrorAction SilentlyContinue
    Clear-IterateMarker -ProjectPath $ProjectPath
}

$endCount = [int](Get-LoadCount -ProjectPath $ProjectPath).count
Info2 ('LOADS   : #{0} -> #{1} ({2} download(s) in this run, every round kept in {3})' -f $startCount, $endCount, ($endCount - $startCount), $iterDir)

if ($converged) {
    Info2 'NOTE    : the last round''s session is still running - ReadOnly reads can attach to it'
    Out2 'RESULT: OK'
    exit 0
}
if ($hardFail) {
    # already reported as ITERATE_ROUND_FAILED: a build/load failure is not a near miss,
    # so it must not be dressed up as "never converged"
    Out2 'RESULT: FAIL'
    exit 1
}
Out2 'FAILURE: ITERATE_NOT_CONVERGED'
Out2 'RESULT: FAIL'
Out2 ('REASON: ' + $reason + (' (stopped after {0} of {1} downloads)' -f $roundsRun, $MaxLoads))
Out2 'HINT    : read the kept rounds to see what the data actually was; do not just raise -MaxLoads'
exit 1
