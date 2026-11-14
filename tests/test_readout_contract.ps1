#requires -Version 7.0
# Static contract checks for the two single-session readers. They lock in rules
# that were already broken twice by silent rewrites:
#   1. one fixed <project>\readout\ directory - no timestamp dirs, no mirror
#   2. exactly one success RESULT line; inner RESULT lines are filtered out
#   3. a failed read overwrites verdict.txt with result: FAIL and drops stale data
#   4. the separate read-only entry points stay deleted; debug.ps1 is execution only
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$problems = New-Object System.Collections.Generic.List[string]

function Get-ScriptText([string]$name) {
    $path = Join-Path (Join-Path $root 'scripts') $name
    if (-not (Test-Path -LiteralPath $path)) { throw "missing script: $path" }
    return (Get-Content -LiteralPath $path -Raw)
}
function Test-Contains([string]$text, [string]$pattern, [string]$what) {
    if ($text -notmatch $pattern) { $script:problems.Add("$what (missing: $pattern)") }
}
function Test-Absent([string]$text, [string]$pattern, [string]$what) {
    if ($text -cmatch $pattern) { $script:problems.Add("$what (found: $pattern)") }
}
function Get-Count([string]$text, [string]$literal) {
    return [regex]::Matches($text, [regex]::Escape($literal)).Count
}

$runRead = Get-ScriptText 'ti_c2000_run_read.ps1'
$readDma = Get-ScriptText 'ti_c2000_read_dma.ps1'

foreach ($pair in @(@('run_read', $runRead), @('read_dma', $readDma))) {
    $tag = $pair[0]
    $text = $pair[1]

    # 1. single fixed output directory
    Test-Contains $text "Join-Path \`$OutRoot 'readout'" "${tag}: fixed readout directory"
    Test-Absent $text 'readout_' "${tag}: no timestamped readout folder"
    Test-Absent $text 'mirror' "${tag}: no Tools/out mirror"

    # 2. one RESULT line per run
    $okCount = Get-Count $text "Out2 'RESULT: OK'"
    if ($okCount -ne 1) { $problems.Add("${tag}: expected exactly one success RESULT line, found $okCount") }
    $filterCount = ([regex]::Matches($text, '-notmatch ''[^'']*RESULT')).Count
    if ($filterCount -lt 2) { $problems.Add("${tag}: child/checker/diagnostic RESULT lines must be filtered, found $filterCount filters") }
    Test-Contains $text '\(RESULT' "${tag}: inner RESULT lines filtered from echoes"
}

# 3. failure must publish a FAIL verdict and clear stale data
Test-Contains $runRead 'function Publish-Readout' 'run_read: verdict publisher defined early'
Test-Contains $runRead 'function Clear-StaleReadout' 'run_read: stale-data cleaner defined'
Test-Contains $runRead "Publish-Readout 'FAIL'" 'run_read: failure path publishes FAIL'
$publishIndex = $runRead.IndexOf('function Publish-Readout')
$dssIndex = $runRead.IndexOf('session.memory.loadProgram')
if ($publishIndex -lt 0 -or $dssIndex -lt 0 -or $publishIndex -gt $dssIndex) {
    $problems.Add('run_read: verdict publisher must be defined before the DSS session starts')
}
Test-Contains $readDma 'function Fail-Readout' 'read_dma: failed-read publisher defined'
Test-Contains $readDma 'Fail-Readout \$failCode' 'read_dma: DSS failure path publishes FAIL'
$failIndex = $readDma.IndexOf('function Fail-Readout')
$dmaIndex = $readDma.IndexOf('session.memory.loadProgram')
if ($failIndex -lt 0 -or $dmaIndex -lt 0 -or $failIndex -gt $dmaIndex) {
    $problems.Add('read_dma: failed-read publisher must be defined before the DSS session starts')
}

# 4. the separate read-only entry points are deleted, not parked; a dormant
#    entry point keeps advertising "disconnect, then read", which is the bug.
foreach ($gone in @('ti_c2000_read_runtime.ps1', 'ti_c2000_read_array_runtime.ps1', 'dss_template.js')) {
    if (Test-Path -LiteralPath (Join-Path (Join-Path $root 'scripts') $gone)) {
        $problems.Add("read-only entry must stay deleted: scripts/$gone exists again")
    }
}
$debug = Get-ScriptText 'ti_c2000_debug.ps1'
foreach ($legacy in @('\[switch\]\$ReadOnly', '\$ReadVars', '\$ReadArray', '\$WaitFor', 'dss\.bat', 'dss_template\.js')) {
    Test-Absent $debug $legacy "debug.ps1: legacy read plumbing removed"
}
Test-Contains $debug '\$args\.Count -gt 0' 'debug.ps1: stale read switches must not be ignored'
Test-Contains $debug 'UNKNOWN_ARGUMENT' 'debug.ps1: unknown argument reported explicitly'
Test-Absent $debug 'READONLY_(UNRELIABLE|MODE_CONFLICT)' 'debug.ps1: no read-mode failure codes left'

if ($problems.Count -gt 0) {
    Write-Output 'FAILURE: READOUT_CONTRACT_BROKEN'
    foreach ($p in $problems) { Write-Output ('REASON: ' + $p) }
    Write-Output 'RESULT: FAIL'
    exit 1
}
Write-Output 'PASS: single readout dir, one RESULT line, failure overwrites verdict, read-only entries stay deleted'
Write-Output 'RESULT: OK'
exit 0
