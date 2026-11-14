#requires -Version 7.0
<#
ti_c2000_check_read.ps1 -- generic verdict for a data CSV produced from C2000.

Implements verdict levels 2 (liveness) and 4 (value range) of
references/data-read-verdict.md. Levels 1 (firmware identity) and 3 (frozen
buffer) are enforced by the reader scripts while connected, because they need
gBufFull / gBufSeq / the .out hash.

Rules:
  - heartbeat variables are configurable; a missing column is MISSING, not a pass
  - no automatic heartbeat selection from unrelated numeric columns
  - with two rows, the counter must increase; with more rows, two consecutive
    non-increasing intervals fail
  - startup-window checks apply only with -CheckStartupWindow after a fresh load
  - value range is optional; when given, every value must be inside it

Usage:
  pwsh -NoProfile -File ti_c2000_check_read.ps1 -CsvPath <data.csv> `
    -HeartbeatVars "gMsTick,usMainLoop" -ValueMin 0 -ValueMax 4095

Exit code: 0 OK | 1 verdict failed | 2 argument/file problem
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string[]]$HeartbeatVars = @('gMsTick', 'usMainLoop'),
    [string[]]$RangeVars = @(),
    [Nullable[double]]$ValueMin = $null,
    [Nullable[double]]$ValueMax = $null,
    [int]$ExpectedRows = 0,
    [int]$StartupMaxMs = 10000,
    # Only meaningful immediately after this invocation loaded a fresh image.
    [switch]$CheckStartupWindow,
    # Array/CSV dumps have no heartbeat column; they still must pass count/range.
    [switch]$AllowNoHeartbeat,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $CsvPath)) {
    Out2 'FAILURE: NO_CSV'; Out2 'RESULT: FAIL'
    Out2 "REASON: '$CsvPath' not found"; exit 2
}
if ($ExpectedRows -lt 0 -or ($null -ne $ValueMin -and $null -ne $ValueMax -and $ValueMin -gt $ValueMax)) {
    Out2 'FAILURE: INVALID_VERDICT_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: ExpectedRows must be nonnegative and ValueMin must not exceed ValueMax'; exit 2
}

try {
    $rows = @(Import-Csv -LiteralPath $CsvPath)
} catch {
    Out2 'FAILURE: CSV_PARSE_ERROR'; Out2 'RESULT: FAIL'
    Out2 ('REASON: ' + $_.Exception.Message); exit 2
}
if ($rows.Count -lt 1) {
    Out2 'FAILURE: TOO_FEW_ROWS'; Out2 'RESULT: FAIL'
    Out2 'REASON: no data rows'; exit 1
}
$singleRow = ($rows.Count -lt 2)
if ($ExpectedRows -gt 0 -and $rows.Count -ne $ExpectedRows) {
    Out2 'FAILURE: COUNT_MISMATCH'; Out2 'RESULT: FAIL'
    Out2 ("REASON: expected {0} rows, got {1}" -f $ExpectedRows, $rows.Count); exit 1
}

$columns = @($rows[0].PSObject.Properties.Name)
function To-Num($v) {
    $d = 0.0
    $s = ([string]$v).Trim()
    if ($s -match '^0[xX][0-9A-Fa-f]+$') {
        try { return [double][Convert]::ToUInt64($s.Substring(2), 16) } catch { return $null }
    }
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and
        -not [double]::IsNaN($d) -and -not [double]::IsInfinity($d)) { return $d }
    return $null
}
function ColumnNumbers([string]$name) {
    $vals = foreach ($r in $rows) {
        # PSObject.Properties[$name] handles dotted/array names such as
        # EPwm1Regs.TBPRD or gAdcBuf[0], where $r.$name would not resolve.
        $p = $r.PSObject.Properties[$name]
        if ($p) { To-Num $p.Value } else { $null }
    }
    return @($vals)
}

$checks = @($HeartbeatVars | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$selected = @()
$hbSkipped = $false
foreach ($c in $checks) {
    $nums = ColumnNumbers $c
    $valid = @($nums | Where-Object { $_ -ne $null })
    if ($nums.Count -eq $rows.Count -and $valid.Count -eq $rows.Count) { $selected += $c }
    else { Out2 ("CHECKVAR {0}: MISSING/UNREADABLE - skipped" -f $c) }
}
if ($selected.Count -eq 0) {
    if ($AllowNoHeartbeat) {
        $hbSkipped = $true
        Out2 'HEARTBEAT: SKIPPED (-AllowNoHeartbeat)'
    } else {
        Out2 'HEARTBEAT: FAIL'
        Out2 'FAILURE: NO_HEARTBEAT'
        Out2 'REASON: no usable heartbeat column; cannot prove the program was running'
        Out2 'RESULT: FAIL'
        exit 1
    }
}
if ($singleRow) {
    if (-not $AllowNoHeartbeat) {
        Out2 'HEARTBEAT: FAIL'
        Out2 'FAILURE: NO_LIVENESS_INTERVAL'
        Out2 'REASON: one row cannot establish that the application advanced'
        Out2 'RESULT: FAIL'
        exit 1
    }
    if (-not $hbSkipped) { $hbSkipped = $true; Out2 'HEARTBEAT: SKIPPED (single row)' }
}

$ok = $true
foreach ($c in $(if ($hbSkipped) { @() } else { $selected })) {
    $nums = @(ColumnNumbers $c)
    if ($CheckStartupWindow -and $c -match 'Tick|RunMs' -and $nums[0] -gt $StartupMaxMs) {
        $ok = $false
        Out2 ("CHECK {0}: first value {1} > {2} - looks like an old program, not this load" -f $c, $nums[0], $StartupMaxMs)
    }
    $badRun = 0
    for ($i = 1; $i -lt $nums.Count; $i++) {
        if ($nums[$i] -gt $nums[$i - 1]) { $badRun = 0; continue }
        $badRun++
        Out2 ("CHECK {0}: row {1} not increasing ({2} -> {3})" -f $c, ($i + 1), $nums[$i - 1], $nums[$i])
        if ($badRun -ge 2 -or $nums.Count -eq 2) { $ok = $false }
    }
    Out2 ("CHECK {0}: {1} -> {2}  delta = {3}" -f $c, $nums[0], $nums[-1], ($nums[-1] - $nums[0]))
}
if ($hbSkipped) {
    # already reported SKIPPED
} elseif (-not $ok) {
    Out2 'HEARTBEAT: FAIL'
} else {
    Out2 'HEARTBEAT: OK'
}

# value range (level 4): only the columns named by -RangeVars (counters such as
# gMsTick/usMainLoop/gWaveFrames are expected to exceed ADC limits and must not
# be mixed into the same range check)
if ($null -ne $ValueMin -or $null -ne $ValueMax -or $RangeVars.Count -gt 0) {
    $rangeOk = $true
    if ($RangeVars.Count -gt 0) {
        $targetCols = @($RangeVars | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else {
        $targetCols = @($columns | Where-Object { $_ -notin @('round', 'hostMs', 'hostTime') })
        Out2 'RANGE: no -RangeVars given, checking every numeric column (counters may exceed the range)'
    }
    foreach ($col in $targetCols) {
        if ($col -in @('round', 'hostMs', 'hostTime')) { continue }
        if ($columns -notcontains $col) {
            $rangeOk = $false
            Out2 ("RANGE {0}: column not found" -f $col)
            continue
        }
        $nums = @(ColumnNumbers $col)
        $valid = @($nums | Where-Object { $_ -ne $null })
        if ($valid.Count -ne $rows.Count) {
            $rangeOk = $false
            Out2 ("RANGE {0}: {1}/{2} numeric values" -f $col, $valid.Count, $rows.Count)
            continue
        }
        $lo = ($valid | Measure-Object -Minimum).Minimum
        $hi = ($valid | Measure-Object -Maximum).Maximum
        if ($null -ne $ValueMin -and $lo -lt $ValueMin) {
            $rangeOk = $false
            Out2 ("RANGE {0}: min {1} < {2}" -f $col, $lo, $ValueMin)
        }
        if ($null -ne $ValueMax -and $hi -gt $ValueMax) {
            $rangeOk = $false
            Out2 ("RANGE {0}: max {1} > {2}" -f $col, $hi, $ValueMax)
        }
    }
    if (-not $rangeOk) { Out2 'RANGE: FAIL'; $ok = $false }
    elseif ($null -eq $ValueMin -and $null -eq $ValueMax) { Out2 'NUMERIC: OK'; Out2 'RANGE: SKIPPED (no bounds)' }
    else { Out2 'RANGE: OK' }
} else {
    Out2 'RANGE: SKIPPED (no -ValueMin/-ValueMax)'
}

Info2 ("ROWS    : {0}" -f $rows.Count)
if (-not $ok) { Out2 'RESULT: FAIL'; exit 1 }
Out2 'RESULT: OK'
exit 0
