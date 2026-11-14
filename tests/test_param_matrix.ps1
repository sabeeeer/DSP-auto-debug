#requires -Version 7.0
# Brute force on the argument surface: every entry point, every wrong way to call it.
# Two things must hold for each case, and both matter to an AI reading the output:
#   1. the exact FAILURE code and exit code (otherwise "it failed" is not actionable)
#   2. exactly ONE "RESULT:" line (a tool that greps for RESULT must never see two, and
#      must never see zero when a failure was reported)
# No board, no CCS: the fixtures are empty project folders with a .cproject and .ccxml.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sc = Join-Path $root 'scripts'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-args-' + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $fixture 'Fw'
$bare = Join-Path $fixture 'NoProject'
$noCcxml = Join-Path $fixture 'NoCcxml'
$bad = New-Object System.Collections.Generic.List[string]
$cases = 0

function Write-Text([string]$path, [string]$text) {
    $d = Split-Path -Parent $path
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function Invoke-Script([string[]]$a) {
    $out = @(& pwsh @a 2>&1)
    return [ordered]@{ code = $LASTEXITCODE; text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
}
function Case([string]$label, [string[]]$argv, [int]$wantCode, [string]$wantPattern) {
    $script:cases++
    $r = Invoke-Script $argv
    $resLines = @($r.text -split "`n" | Where-Object { $_ -match '^RESULT:' }).Count
    if ($r.code -ne $wantCode) {
        $bad.Add(('{0}: exit {1}, expected {2}  [{3}]' -f $label, $r.code, $wantCode, ($r.text -replace "`n", ' | ')))
        return
    }
    if ($wantPattern -and $r.text -notmatch $wantPattern) {
        $bad.Add(('{0}: no /{1}/ in output  [{2}]' -f $label, $wantPattern, ($r.text -replace "`n", ' | ')))
        return
    }
    if ($resLines -ne 1) { $bad.Add(('{0}: {1} RESULT lines (contract is exactly 1)' -f $label, $resLines)) }
}

try {
    New-Item -ItemType Directory -Force -Path $proj, (Join-Path $proj 'targetConfigs'), $bare, $noCcxml | Out-Null
    Write-Text (Join-Path $proj '.cproject') '<project/>'
    Write-Text (Join-Path $proj 'targetConfigs/x.ccxml') '<configurations/>'
    Write-Text (Join-Path $noCcxml '.cproject') '<project/>'

    # ---------------- ti_c2000_service.ps1 --------------------------------------
    $svc = Join-Path $sc 'ti_c2000_service.ps1'
    Case 'service: no mode' @('-NoProfile', '-File', $svc, '-ProjectPath', $proj) 2 'FAILURE: NEED_MODE'
    Case 'service: two modes' @('-NoProfile', '-File', $svc, '-ProjectPath', $proj, '-Start', '-Stop') 2 'FAILURE: NEED_MODE'
    Case 'service: missing path' @('-NoProfile', '-File', $svc, '-ProjectPath', (Join-Path $fixture 'nope'), '-Status') 2 'FAILURE: NO_PROJECT'
    Case 'service: no .cproject' @('-NoProfile', '-File', $svc, '-ProjectPath', $bare, '-Status') 2 'FAILURE: NO_PROJECT'
    Case 'service: bad run mode' @('-NoProfile', '-File', $svc, '-ProjectPath', $proj, '-Start', '-RunMode', 'Foo', '-ConfirmLoad') 2 'FAILURE: INVALID_RUN_MODE'
    Case 'service: iterate unapproved' @('-NoProfile', '-File', $svc, '-ProjectPath', $proj, '-Start', '-RunMode', 'Iterate', '-ConfirmLoad') 4 'FAILURE: ITERATE_NOT_APPROVED'
    Case 'service: no ccxml' @('-NoProfile', '-File', $svc, '-ProjectPath', $noCcxml, '-Start', '-ConfirmLoad') 2 'FAILURE: NO_CCXML'

    # ---------------- ti_c2000_run_read.ps1 -------------------------------------
    $rd = Join-Path $sc 'ti_c2000_run_read.ps1'
    Case 'read: empty variables' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', '') 2 'FAILURE: NEED_VARIABLES'
    Case 'read: duplicate variables' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick,gMsTick') 2 'FAILURE: DUPLICATE_VARIABLES'
    Case 'read: one round' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-Rounds', '1') 2 'FAILURE: INVALID_READ_REQUEST'
    Case 'read: negative interval' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-IntervalMs', '-5') 2 'FAILURE: INVALID_READ_REQUEST'
    Case 'read: injected variable' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick;rm') 2 'FAILURE: INVALID_READ_REQUEST'
    Case 'read: missing path' @('-NoProfile', '-File', $rd, '-ProjectPath', (Join-Path $fixture 'nope'), '-Variables', 'gMsTick') 2 'FAILURE: NO_PROJECT'
    Case 'read: no ccxml' @('-NoProfile', '-File', $rd, '-ProjectPath', $noCcxml, '-Variables', 'gMsTick') 2 'FAILURE: NO_CCXML'
    Case 'read: loadread unconfirmed' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-Mode', 'LoadRead') 4 'FAILURE: LOAD_NOT_CONFIRMED'
    Case 'read: loadread + allowunverified' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-Mode', 'LoadRead', '-ConfirmLoad', '-AllowUnverified') 2 'FAILURE: MUTUALLY_EXCLUSIVE'
    Case 'read: readonly + confirmload' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-ConfirmLoad') 2 'FAILURE: MUTUALLY_EXCLUSIVE'
    Case 'read: readonly + build' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-Build') 2 'FAILURE: MUTUALLY_EXCLUSIVE'
    Case 'read: readonly + expect' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-Expect', 'gMsTick>0') 2 'FAILURE: MUTUALLY_EXCLUSIVE'
    Case 'read: readonly + maxloads' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-MaxLoads', '2') 2 'FAILURE: MUTUALLY_EXCLUSIVE'
    Case 'read: readonly no session' @('-NoProfile', '-File', $rd, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-NoProbeCheck') 4 'FAILURE: NO_SESSION'

    # ---------------- ti_c2000_read_dma.ps1 -------------------------------------
    $dma = Join-Path $sc 'ti_c2000_read_dma.ps1'
    Case 'dma: zero rows' @('-NoProfile', '-File', $dma, '-ProjectPath', $proj, '-ArrayName', 'gBuf', '-FrozenBufferReady', '-Rows', '0') 2 'FAILURE: BAD_DIMENSIONS'
    Case 'dma: too large' @('-NoProfile', '-File', $dma, '-ProjectPath', $proj, '-ArrayName', 'gBuf', '-FrozenBufferReady', '-Rows', '1000', '-Columns', '1000') 2 'FAILURE: ARRAY_TOO_LARGE'
    Case 'dma: inverted range' @('-NoProfile', '-File', $dma, '-ProjectPath', $proj, '-ArrayName', 'gBuf', '-FrozenBufferReady', '-ValueMin', '10', '-ValueMax', '1') 2 'FAILURE: BAD_VALUE_RANGE'
    Case 'dma: injected array name' @('-NoProfile', '-File', $dma, '-ProjectPath', $proj, '-ArrayName', 'gBuf[0];x', '-FrozenBufferReady') 2 'FAILURE: INVALID_READ_REQUEST'
    Case 'dma: loadread + noprobecheck' @('-NoProfile', '-File', $dma, '-ProjectPath', $proj, '-ArrayName', 'gBuf', '-Mode', 'LoadRead', '-ConfirmLoad', '-NoProbeCheck') 2 'FAILURE: MUTUALLY_EXCLUSIVE'

    # ---------------- ti_c2000_iterate.ps1 --------------------------------------
    $it = Join-Path $sc 'ti_c2000_iterate.ps1'
    Case 'iterate: no variables' @('-NoProfile', '-File', $it, '-ProjectPath', $proj, '-UserApproved') 2 'FAILURE: NEED_VARIABLES'
    Case 'iterate: unapproved' @('-NoProfile', '-File', $it, '-ProjectPath', $proj, '-Variables', 'gMsTick') 4 'FAILURE: ITERATE_NOT_APPROVED'
    Case 'iterate: maxloads 21' @('-NoProfile', '-File', $it, '-ProjectPath', $proj, '-Variables', 'gMsTick', '-UserApproved', '-MaxLoads', '21') 2 'FAILURE: INVALID_MAX_LOADS'

    # ---------------- check_project_entry.ps1 -----------------------------------
    $cpe = Join-Path $root 'scripts/check_project_entry.ps1'
    Case 'entry: missing path' @('-NoProfile', '-File', $cpe, '-ProjectPath', (Join-Path $fixture 'nope')) 2 'FAILURE: NO_PROJECT'

    if ($bad.Count -gt 0) {
        'FAILURE: PARAM_MATRIX'
        foreach ($b in $bad) { 'VIOLATION: ' + $b }
        'REASON: {0} of {1} argument cases misbehaved' -f $bad.Count, $cases
        'RESULT: FAIL'
        exit 1
    }
    'CHECK   : {0} argument cases behaved exactly as documented' -f $cases
    'RESULT: OK'
    exit 0
} catch {
    'FAILURE: TEST_FAILED'
    'REASON: ' + $_.Exception.Message
    'RESULT: FAIL'
    exit 1
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
