#requires -Version 7.0
<#
ti_c2000_iterate.ps1 -- RUN MODE 2: continuous (rebuild/reload/read until the data looks right).

RUN MODE 1 is the default everywhere else: load once, never reload, every read
attaches to the running session. That is what protects the target and keeps the
numbers describing one run. This script is the exception: it exists for the case
"数据不对就再编译下载一次，直到对为止" and therefore must be chosen explicitly.

Loop per round (MaxLoads times at most):
  1. stop any session (a load needs a fresh session)
  2. build (unless -NoBuild) + load + run            -> counts as download #N
  3. read the variables inside that session (no extra download)
  4. judge: read OK + every -Expect condition true
     all true  -> RESULT: OK, stop
     otherwise -> next round

Safety rails:
  - -UserApproved is mandatory; without it nothing is stopped, built or downloaded
  - MaxLoads defaults to 5 and is capped at 20
  - -Expect typo is a failure, never a silent pass
  - every round keeps its own copy in <project>\readout\iterate\round-N

Exit code: 0 converged | 1 did not converge / read failed | 2 argument problem
           3 no probe | 4 -UserApproved missing (nothing happened)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string[]]$Variables,
    # conditions like 'gBufSeq>=3' or 'gErr==0'; empty means "read OK is enough"
    [string[]]$Expect = @(),
    [int]$MaxLoads = 5,
    [int]$Rounds = 5,
    [int]$IntervalMs = 200,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    [string]$CorePattern = '.*C28xx(?:_CPU1)?$',
    [string]$HeartbeatExpr = 'gMsTick,gRunMs,usMainLoop',
    [switch]$NoBuild,
    # must be passed only after the user asked for continuous mode
    [switch]$UserApproved,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }
. (Join-Path $PSScriptRoot 'ti_c2000_loadcount.ps1')

if (-not $UserApproved) {
    Out2 'FAILURE: ITERATE_NOT_APPROVED'; Out2 'RESULT: FAIL'
    Out2 'REASON: continuous mode reloads the target repeatedly; it only runs after the user explicitly asked for it'
    Out2 'HINT    : single-step mode is the default - load once, then read without downloading'
    exit 4
}
if ($MaxLoads -lt 1 -or $MaxLoads -gt 20) {
    Out2 'FAILURE: BAD_MAX_LOADS'; Out2 'RESULT: FAIL'; Out2 'REASON: -MaxLoads must be 1..20'; exit 2
}
if ($Rounds -lt 2) { Out2 'FAILURE: BAD_ROUNDS'; Out2 'RESULT: FAIL'; Out2 'REASON: -Rounds must be at least 2'; exit 2 }
if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) {
    Out2 'FAILURE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName

$names = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names.Count -eq 0) { Out2 'FAILURE: NEED_VARIABLES'; Out2 'RESULT: FAIL'; Out2 'REASON: -Variables requires at least one name'; exit 2 }

$svc = Join-Path $PSScriptRoot 'ti_c2000_service.ps1'
$reader = Join-Path $PSScriptRoot 'ti_c2000_run_read.ps1'
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

$iterDir = Join-Path $ProjectPath 'readout\iterate'
New-Item -ItemType Directory -Path $iterDir -Force | Out-Null
$csvPath = Join-Path $ProjectPath 'readout\data\data.csv'
$verdictPath = Join-Path $ProjectPath 'readout\check\verdict.txt'

$startCount = [int](Get-LoadCount -ProjectPath $ProjectPath).count
$converged = $false
$lastReason = ''
$judged = 0

for ($round = 1; $round -le $MaxLoads -and -not $converged; $round++) {
    Out2 ('ROUND   : {0}/{1}' -f $round, $MaxLoads)

    # 1) a load needs its own session
    $stopOut = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $svc -ProjectPath $ProjectPath -Stop 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $Quiet) {
        foreach ($l in $stopOut) { Out2 ([string]$l) }
    }

    # 2) build + load + run: this is the download that costs a flash cycle
    $sargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $svc,
        '-ProjectPath', $ProjectPath, '-Start', '-RunMode', 'Iterate', '-ConfirmLoad')
    if (-not $NoBuild) { $sargs += '-Build' }
    if ($Ccxml) { $sargs += @('-Ccxml', $Ccxml) }
    if ($OutFile) { $sargs += @('-OutFile', $OutFile) }
    if ($CcsRoot) { $sargs += @('-CcsRoot', $CcsRoot) }
    if ($CorePattern) { $sargs += @('-CorePattern', $CorePattern) }
    if ($Quiet) { $sargs += '-Quiet' }

    $sout = & $pwshExe @sargs 2>&1
    foreach ($l in $sout) { if ([string]$l -notmatch '^RESULT:') { Out2 ([string]$l) } }
    if ($LASTEXITCODE -ne 0) {
        $lastReason = 'load/build failed in round ' + $round
        Out2 ('ROUND {0} : LOAD FAILED - {1}' -f $round, $lastReason)
        # a probe or build problem will not fix itself by flashing again
        if ($LASTEXITCODE -eq 2 -or $LASTEXITCODE -eq 3 -or $LASTEXITCODE -eq 4) { break }
        continue
    }

    # 3) read inside the session that just loaded (no second download)
    $rargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $reader,
        '-ProjectPath', $ProjectPath, '-Variables', ($names -join ','),
        '-Rounds', [string]$Rounds, '-IntervalMs', [string]$IntervalMs, '-HeartbeatExpr', $HeartbeatExpr)
    if ($Ccxml) { $rargs += @('-Ccxml', $Ccxml) }
    if ($OutFile) { $rargs += @('-OutFile', $OutFile) }
    if ($CcsRoot) { $rargs += @('-CcsRoot', $CcsRoot) }
    if ($CorePattern) { $rargs += @('-CorePattern', $CorePattern) }
    if ($Quiet) { $rargs += '-Quiet' }
    $rout = & $pwshExe @rargs 2>&1
    $rcode = $LASTEXITCODE
    foreach ($l in $rout) { if ([string]$l -notmatch '^RESULT:') { Out2 ([string]$l) } }

    # 4) judge this round
    if ($rcode -ne 0) {
        $lastReason = 'read failed in round ' + $round
        Out2 ('ROUND {0} : READ FAILED - {1}' -f $round, $lastReason)
        continue
    }

    $values = @{}
    if (Test-Path -LiteralPath $csvPath) {
        try {
            $rows = @(Import-Csv -LiteralPath $csvPath -Encoding utf8)
            if ($rows.Count -gt 0) {
                $last = $rows[-1]
                foreach ($p in $last.PSObject.Properties) { $values[$p.Name] = [string]$p.Value }
            }
        } catch { }
    }

    $judged++
    $check = Test-LoadExpectation -Expect $Expect -Values $values
    foreach ($c in $check.checks) { Out2 ('EXPECT  : ' + $c) }
    if ($check.ok) {
        $converged = $true
        Info2 ('ROUND {0} : DATA OK' -f $round)
        break
    }
    $lastReason = 'expectations not met in round ' + $round
    Out2 ('ROUND {0} : DATA NOT RIGHT - reloading' -f $round)

    # keep the evidence of each attempt before the next round overwrites it
    $keep = Join-Path $iterDir ('round-' + $round)
    New-Item -ItemType Directory -Path $keep -Force | Out-Null
    foreach ($f in @($csvPath, $verdictPath)) {
        if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $keep (Split-Path -Leaf $f)) -Force }
    }
}

$endCount = [int](Get-LoadCount -ProjectPath $ProjectPath).count
$downloads = $endCount - $startCount
Info2 ('LOADS   : #{0}..#{1} ({2} download(s) in this run)' -f ($startCount + 1), $endCount, $downloads)
Info2 ('KEPT    : {0}' -f $iterDir)

if (-not $converged) {
    Out2 'FAILURE: ITERATE_NOT_CONVERGED'; Out2 'RESULT: FAIL'
    Out2 ('REASON: {0} - no round produced the expected data within {1} download(s)' -f $lastReason, $downloads)
    Out2 'HINT    : inspect rounds under readout\iterate, then decide whether the firmware or the expectation is wrong'
    exit 1
}
Out2 'RESULT: OK'
exit 0
