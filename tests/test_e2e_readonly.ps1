#requires -Version 7.0
<#
End-to-end on a real board, read-only only: this test NEVER downloads.
It is the one layer the fixture tests cannot cover - the probe, the live session, the
four proofs and the load counter all together. When there is no probe (CI, or a machine
without the board) it reports SKIP and exits 0, so it can live in the same runner.

  pwsh -NoProfile -File tests/test_e2e_readonly.ps1 -ProjectPath <ccs project>
#>
[CmdletBinding()]
param(
    [string]$ProjectPath = '',
    [string]$CcsRoot = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sc = Join-Path $root 'scripts'
$bad = New-Object System.Collections.Generic.List[string]
$cases = 0

function Say([string]$m) { Write-Host $m }
function Run([string]$label, [string[]]$argv, [int]$wantCode, [string]$wantPattern) {
    $out = @(& pwsh @argv 2>&1)
    $code = $LASTEXITCODE
    $text = (@($out | ForEach-Object { [string]$_ }) -join "`n")
    $res = @($text -split "`n" | Where-Object { $_ -match '^RESULT:' }).Count
    $script:cases++
    $ok = ($code -eq $wantCode) -and ($text -match $wantPattern) -and ($res -eq 1)
    Say ('  {0,-44} exit={1} RESULT={2}  {3}' -f $label, $code, $res, $(if ($ok) { 'OK' } else { 'FAIL' }))
    if (-not $ok) {
        $script:bad.Add(('{0}: exit {1}, want {2} /{3}/' -f $label, $code, $wantCode, $wantPattern))
        $out | Select-Object -Last 5 | ForEach-Object { Say ('      ' + $_) }
    }
    return $text
}

# ---------- skip cleanly when the hardware is not there -----------------------
if (-not $ProjectPath) {
    Say 'SKIP    : no -ProjectPath given (this test needs a real project + probe)'
    Say 'RESULT: OK'
    exit 0
}
if (-not (Test-Path -LiteralPath $ProjectPath)) {
    Say ('SKIP    : {0} does not exist' -f $ProjectPath)
    Say 'RESULT: OK'
    exit 0
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName
$probeArgs = @('-NoProfile', '-File', (Join-Path $sc 'ti_c2000_debug.ps1'), '-ProjectPath', $ProjectPath, '-ProbeCheckOnly')
if ($CcsRoot) { $probeArgs += @('-CcsRoot', $CcsRoot) }
$probeOut = @(& pwsh @probeArgs 2>&1)
if ($LASTEXITCODE -ne 0) {
    Say 'SKIP    : no debug probe on this machine (NO_PROBE) - nothing to read'
    Say 'RESULT: OK'
    exit 0
}

try {
    $common = @('-NoProfile')
    Say 'E2E     : read-only cases against a live board (no download anywhere)'
    $countBefore = $null
    $countFile = Join-Path $ProjectPath 'readout\load-count.json'
    if (Test-Path $countFile) { $countBefore = [int](Get-Content $countFile -Raw -Encoding utf8 | ConvertFrom-Json).count }

    $t = Run 'service -Status' ($common + @('-File', (Join-Path $sc 'ti_c2000_service.ps1'), '-ProjectPath', $ProjectPath, '-Status')) 0 'RESULT: OK'
    if ($t -notmatch 'SKILL\s+:\s+ti-c2000-ccs-auto@[0-9a-f]{8}') { $bad.Add('service -Status printed no skill identity line') }

    $null = Run 'read a heartbeat' ($common + @('-File', (Join-Path $sc 'ti_c2000_run_read.ps1'), '-ProjectPath', $ProjectPath, '-Variables', 'gMsTick', '-Mode', 'ReadOnly', '-Rounds', '2', '-IntervalMs', '300')) 0 'RESULT: OK'
    $null = Run 'read a register too' ($common + @('-File', (Join-Path $sc 'ti_c2000_run_read.ps1'), '-ProjectPath', $ProjectPath, '-Variables', 'gMsTick,EPwm1Regs.TBPRD', '-Mode', 'ReadOnly', '-Rounds', '3', '-IntervalMs', '200')) 0 'RESULT: OK'
    # the heartbeat must be read on its own: a read whose -Variables has no counter used
    # to fail with HEARTBEAT_FAIL on a perfectly alive target (fixed 2026-11-14)
    $null = Run 'registers only, no heartbeat var' ($common + @('-File', (Join-Path $sc 'ti_c2000_run_read.ps1'), '-ProjectPath', $ProjectPath, '-Variables', 'EPwm1Regs.TBPRD,EPwm1Regs.CMPA.bit.CMPA', '-Mode', 'ReadOnly', '-Rounds', '3', '-IntervalMs', '200')) 0 'HEARTBEAT: OK'
    $null = Run '-NoHeartbeat skips liveness' ($common + @('-File', (Join-Path $sc 'ti_c2000_run_read.ps1'), '-ProjectPath', $ProjectPath, '-Variables', 'EPwm1Regs.TBPRD', '-Mode', 'ReadOnly', '-Rounds', '2', '-IntervalMs', '200', '-NoHeartbeat')) 0 'RESULT: OK'
    # nothing readable means liveness cannot be proven: a failure is the correct answer
    $null = Run 'all variables missing -> fail' ($common + @('-File', (Join-Path $sc 'ti_c2000_run_read.ps1'), '-ProjectPath', $ProjectPath, '-Variables', 'gNoSuchVar', '-Mode', 'ReadOnly', '-Rounds', '2', '-IntervalMs', '100')) 1 'FAILURE:'
    $null = Run 'illegal mode -> INVALID_READ_MODE' ($common + @('-File', (Join-Path $sc 'ti_c2000_run_read.ps1'), '-ProjectPath', $ProjectPath, '-Variables', 'gMsTick', '-Mode', 'Foo')) 2 'FAILURE: INVALID_READ_MODE'
    $null = Run 'readonly + -ConfirmLoad -> refuse' ($common + @('-File', (Join-Path $sc 'ti_c2000_run_read.ps1'), '-ProjectPath', $ProjectPath, '-Variables', 'gMsTick', '-ConfirmLoad')) 2 'FAILURE: MUTUALLY_EXCLUSIVE'
    $null = Run 'dma without frozen promise' ($common + @('-File', (Join-Path $sc 'ti_c2000_read_dma.ps1'), '-ProjectPath', $ProjectPath, '-ArrayName', 'gBuf')) 2 'FAILURE: BUFFER_NOT_CONFIRMED'
    $null = Run 'entry check' ($common + @('-File', (Join-Path $sc 'check_project_entry.ps1'), '-ProjectPath', $ProjectPath)) 0 'RESULT: OK'
    $null = Run 'entry check with a recent run' ($common + @('-File', (Join-Path $sc 'check_project_entry.ps1'), '-ProjectPath', $ProjectPath, '-MaxRunAgeMinutes', '10')) 0 'RESULT: OK'

    # the whole point of ReadOnly: it must not have counted a download
    if ($null -ne $countBefore) {
        $countAfter = [int](Get-Content $countFile -Raw -Encoding utf8 | ConvertFrom-Json).count
        $cases++
        if ($countAfter -ne $countBefore) {
            $bad.Add(('read-only cases changed the download counter: {0} -> {1}' -f $countBefore, $countAfter))
            Say ('  counter 1 -> 2 : FAIL')
        } else {
            Say ('  download counter untouched ({0}) : OK' -f $countAfter)
        }
    }

    if ($bad.Count -gt 0) {
        'FAILURE: E2E_READONLY'
        foreach ($b in $bad) { 'VIOLATION: ' + $b }
        'REASON: {0} of {1} on-target cases misbehaved' -f $bad.Count, $cases
        'RESULT: FAIL'
        exit 1
    }
    'CHECK   : {0} on-target read-only cases behaved as documented' -f $cases
    'RESULT: OK'
    exit 0
} catch {
    'FAILURE: TEST_FAILED'
    'REASON: ' + $_.Exception.Message
    'RESULT: FAIL'
    exit 1
}
