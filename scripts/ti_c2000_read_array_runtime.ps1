#requires -Version 7.0
<#
.SYNOPSIS
    Read a frozen 1-D or 2-D C2000 array in bounded batches without halting,
    resetting, building or downloading the target.

.EXAMPLE
    pwsh -NoProfile -File scripts/ti_c2000_read_array_runtime.ps1 `
      -ProjectPath <project> -ArrayName gAdcAllBuf -Rows 16 -Columns 400 `
      -WaitFor 'gAdcBufFull == 1' -OutputPath <new-output.csv>

    One DSS connection reads all batches. An incomplete capture stays at
    <new-output.csv>.partial; only a complete capture becomes <new-output.csv>.
#>
[CmdletBinding()]
param(
    [string]$ProjectPath,
    [string]$ArrayName,
    [int]$Columns,
    [int]$Rows = 1,
    # measured 2026-11-14: 320 -> 0.331 ms/word, 2000 -> 0.296 ms/word;
    # larger batches buy little, the limit is JTAG throughput.
    [int]$BatchSize = 2000,
    [string]$OutputPath,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    # F28335 single C28xx or F28379D CPU1; neither CPU2 nor CLA1.
    [string]$CorePattern = '.*C28xx(?:_CPU1)?$',
    [string]$WaitFor = '',
    [string]$HeartbeatExpr = 'gMsTick,gRunMs,usMainLoop',
    [int]$StartupMaxMs = 10000,
    [switch]$NoHeartbeat,
    # Force per-element evaluate (slow but works on peripheral registers)
    [switch]$PointMode,
    [int]$RunMs = 0,
    [int]$ReadTimeoutSec = 900,
    [double]$MinValue,
    [double]$MaxValue,
    [switch]$NoProbeCheck
)

$ErrorActionPreference = 'Stop'
function Fail([string]$kind, [string]$reason) {
    Write-Output "FAILURE: $kind"
    Write-Output "REASON: $reason"
    Write-Output 'RESULT: FAIL'
    exit 1
}

# Disabled: a separate read-only session cannot prove it reads the current RAM
# firmware (F28379D resets to Flash; DSP28335 may read a stale Flash program).
Write-Output 'FAILURE: READONLY_UNRELIABLE'
Write-Output 'RESULT: FAIL'
Write-Output 'REASON: use ti_c2000_read_dma.ps1 (DMA frozen buffer) or ti_c2000_run_read.ps1 (low speed, no DMA) in one session'
exit 2

if ($ArrayName -notmatch '^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$') {
    Fail 'BAD_ARRAY_NAME' 'use a simple array symbol or field path; no expressions or pointer operations'
}
if ($Rows -lt 1 -or $Columns -lt 1 -or $BatchSize -lt 1 -or $ReadTimeoutSec -lt 1 -or $ReadTimeoutSec -gt 3600) {
    Fail 'BAD_DIMENSIONS' 'Rows/Columns/BatchSize must be positive; ReadTimeoutSec must be 1..3600'
}
$checkMin = $PSBoundParameters.ContainsKey('MinValue')
$checkMax = $PSBoundParameters.ContainsKey('MaxValue')
if ($checkMin -and $checkMax -and $MinValue -gt $MaxValue) { Fail 'BAD_VALUE_RANGE' 'MinValue exceeds MaxValue' }
$total = [long]$Rows * [long]$Columns
if ($total -gt 100000) { Fail 'ARRAY_TOO_LARGE' 'this helper limits one capture to 100000 values' }
if ($NoHeartbeat) { $HeartbeatExpr = '' }
if (Test-Path -LiteralPath $OutputPath) { Fail 'OUTPUT_EXISTS' 'choose a new OutputPath; existing captures are never overwritten' }
$partial = "$OutputPath.partial"
if (Test-Path -LiteralPath $partial) { Fail 'PARTIAL_EXISTS' 'an incomplete capture already exists; inspect it before choosing another OutputPath' }
$rawLog = "$OutputPath.log"
if (Test-Path -LiteralPath $rawLog) { Fail 'LOG_EXISTS' 'a raw log already exists for this OutputPath' }
$parent = Split-Path -Path $OutputPath -Parent
if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { Fail 'NO_OUTPUT_DIR' 'OutputPath parent directory does not exist' }

$debug = Join-Path $PSScriptRoot 'ti_c2000_debug.ps1'
if (-not (Test-Path -LiteralPath $debug -PathType Leaf)) { Fail 'NO_READER' 'the versioned debug reader is missing' }
$forward = @{
    ProjectPath = $ProjectPath
    CorePattern = $CorePattern
    ReadOnly = $true
    ReadArray = $ArrayName
    ArrayRows = $Rows
    ArrayColumns = $Columns
    ArrayBatchSize = $BatchSize
    ReadTimeoutSec = $ReadTimeoutSec
}
if ($Ccxml) { $forward.Ccxml = $Ccxml }
if ($OutFile) { $forward.OutFile = $OutFile }
if ($CcsRoot) { $forward.CcsRoot = $CcsRoot }
if ($WaitFor) { $forward.WaitFor = $WaitFor }
if ($HeartbeatExpr) { $forward.HeartbeatExpr = $HeartbeatExpr }
if ($StartupMaxMs -gt 0) { $forward.StartupMaxMs = $StartupMaxMs }
if ($NoHeartbeat) { $forward.NoHeartbeat = $true }
if ($PointMode) { $forward.PointMode = $true }
if ($RunMs -gt 0) { $forward.RunMs = $RunMs }
if ($NoProbeCheck) { $forward.NoProbeCheck = $true }

try {
    $output = @(& $debug @forward 2>&1)
    $code = $LASTEXITCODE
    $output | Set-Content -LiteralPath $rawLog -Encoding UTF8
    $values = @($output | Where-Object { $_ -match '^VAR ' })
    $records = [Collections.Generic.List[object]]::new()
    $parseError = ''
    foreach ($line in $values) {
        if ([string]$line -notmatch '^VAR\s+(.+?)\s+=\s+(.+)$') { $parseError = 'unparseable VAR line'; break }
        $name = $Matches[1]
        $value = $Matches[2]
        $linear = $records.Count
        if ($linear -ge $total) { $parseError = 'extra values'; break }
        $row = [int][Math]::Floor($linear / $Columns)
        $column = [int]($linear % $Columns)
        $expected = if ($Rows -eq 1) { '{0}[{1}]' -f $ArrayName, $column }
                    else { '{0}[{1}][{2}]' -f $ArrayName, $row, $column }
        if ($name -cne $expected -or $value -match '^<ERROR:') { $parseError = "missing, reordered or failed value at index $linear"; break }
        if ($checkMin -or $checkMax) {
            $numeric = 0.0
            if ($value -match '^0[xX][0-9A-Fa-f]+$') {
                $numeric = [double][Convert]::ToUInt64($value.Substring(2), 16)
            } elseif (-not [double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$numeric)) {
                $parseError = "nonnumeric value at $name"; break
            }
            if (($checkMin -and $numeric -lt $MinValue) -or ($checkMax -and $numeric -gt $MaxValue)) {
                $parseError = "$value at $name is outside the requested range"; break
            }
        }
        $records.Add([pscustomobject]@{ row = $row; column = $column; expression = $name; value = $value })
    }
    if ($records.Count -gt 0) { $records | Export-Csv -LiteralPath $partial -NoTypeInformation -Encoding UTF8 }
    else { 'row,column,expression,value' | Set-Content -LiteralPath $partial -Encoding UTF8 }
    $batchCount = [int][Math]::Ceiling($total / $BatchSize)
    $batches = @($output | Where-Object { $_ -match '^BATCH: ' })
    $heartbeats = @($output | Where-Object { $_ -match '^DSS: heartbeat advanced ' })
    $ok = @($output | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count -eq 1
    if ($code -ne 0 -or -not $ok -or $records.Count -ne $total -or $batches.Count -ne $batchCount -or
        ($HeartbeatExpr -and $heartbeats.Count -ne ($batchCount + 1)) -or $parseError) {
        $detail = @($output | Where-Object { $_ -match '^(FAILURE:|REASON:|RESULT:|READONLY_|CONNECT_FAILED:|WAIT_TIMEOUT:)' }) | Select-Object -First 4
        Fail 'ARRAY_READ_INCOMPLETE' ("exit=$code values=$($records.Count)/$total batches=$($batches.Count)/$batchCount; $parseError; $($detail -join ' | '); partial=$partial rawLog=$rawLog")
    }
    foreach ($batch in $batches) { Write-Output $batch }
    Move-Item -LiteralPath $partial -Destination $OutputPath
    Write-Output "OUTPUT: $OutputPath"
    Write-Output "RAW_LOG: $rawLog"
    Write-Output "VALUES: $total"
    Write-Output 'RESULT: OK'
    exit 0
} catch {
    Fail 'ARRAY_READ_ERROR' "$($_.Exception.Message); partial=$partial"
}
