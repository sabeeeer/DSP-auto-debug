#requires -Version 7.0
<#
.SYNOPSIS
    Read a frozen 1-D or 2-D C2000 array in bounded batches without halting,
    resetting, building or downloading the target.

.EXAMPLE
    pwsh -NoProfile -File scripts/ti_c2000_read_array_runtime.ps1 `
      -ProjectPath <project> -ArrayName gAdcAllBuf -Rows 16 -Columns 400 `
      -WaitFor 'gAdcBufFull == 1' -OutputPath <new-output.csv>

    Each batch invokes ti_c2000_read_runtime.ps1. An incomplete capture stays
    at <new-output.csv>.partial; only a complete capture becomes <new-output.csv>.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$ArrayName,
    [Parameter(Mandatory)][int]$Columns,
    [int]$Rows = 1,
    [int]$BatchSize = 128,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    [string]$CorePattern = '.*',
    [string]$WaitFor = '',
    [int]$RunMs = 0,
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

if ($ArrayName -notmatch '^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$') {
    Fail 'BAD_ARRAY_NAME' 'use a simple array symbol or field path; no expressions or pointer operations'
}
if ($Rows -lt 1 -or $Columns -lt 1 -or $BatchSize -lt 1 -or $BatchSize -gt 256) {
    Fail 'BAD_DIMENSIONS' 'Rows/Columns must be positive; BatchSize must be 1..256'
}
$checkMin = $PSBoundParameters.ContainsKey('MinValue')
$checkMax = $PSBoundParameters.ContainsKey('MaxValue')
if ($checkMin -and $checkMax -and $MinValue -gt $MaxValue) { Fail 'BAD_VALUE_RANGE' 'MinValue exceeds MaxValue' }
$total = [long]$Rows * [long]$Columns
if ($total -gt 100000) { Fail 'ARRAY_TOO_LARGE' 'this helper limits one capture to 100000 values' }
if (Test-Path -LiteralPath $OutputPath) { Fail 'OUTPUT_EXISTS' 'choose a new OutputPath; existing captures are never overwritten' }
$partial = "$OutputPath.partial"
if (Test-Path -LiteralPath $partial) { Fail 'PARTIAL_EXISTS' 'an incomplete capture already exists; inspect it before choosing another OutputPath' }
$parent = Split-Path -Path $OutputPath -Parent
if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { Fail 'NO_OUTPUT_DIR' 'OutputPath parent directory does not exist' }

$reader = Join-Path $PSScriptRoot 'ti_c2000_read_runtime.ps1'
if (-not (Test-Path -LiteralPath $reader -PathType Leaf)) { Fail 'NO_READER' 'the versioned runtime reader is missing' }
$forward = @{ ProjectPath = $ProjectPath; CorePattern = $CorePattern }
if ($Ccxml) { $forward.Ccxml = $Ccxml }
if ($OutFile) { $forward.OutFile = $OutFile }
if ($CcsRoot) { $forward.CcsRoot = $CcsRoot }
if ($WaitFor) { $forward.WaitFor = $WaitFor }
if ($RunMs -gt 0) { $forward.RunMs = $RunMs }
if ($NoProbeCheck) { $forward.NoProbeCheck = $true }

try {
    $batchNumber = 0
    for ($offset = [long]0; $offset -lt $total; $offset += $BatchSize) {
        $count = [int][Math]::Min($BatchSize, $total - $offset)
        $expressions = @()
        for ($j = 0; $j -lt $count; $j++) {
            $linear = $offset + $j
            $row = [int][Math]::Floor($linear / $Columns)
            $column = [int]($linear % $Columns)
            if ($Rows -eq 1) { $expressions += ('{0}[{1}]' -f $ArrayName, $column) }
            else { $expressions += ('{0}[{1}][{2}]' -f $ArrayName, $row, $column) }
        }
        $batchNumber++
        $output = @(& $reader @forward -Variables $expressions 2>&1)
        $code = $LASTEXITCODE
        $ok = @($output | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count -eq 1
        $values = @($output | Where-Object { $_ -match '^VAR ' })
        if ($code -ne 0 -or -not $ok -or $values.Count -ne $count) {
            $detail = @($output | Where-Object { $_ -match '^(FAILURE:|REASON:|RESULT:|VAR .*<ERROR:)' }) | Select-Object -First 3
            Fail 'ARRAY_BATCH_FAILED' ("batch $batchNumber/$([Math]::Ceiling($total / $BatchSize)) at index $offset; exit=$code values=$($values.Count)/$count; $($detail -join ' | '); partial=$partial")
        }
        $records = @()
        for ($j = 0; $j -lt $count; $j++) {
            if ([string]$values[$j] -notmatch '^VAR\s+(.+?)\s+=\s+(.+)$') {
                Fail 'ARRAY_PARSE_FAILED' "batch $batchNumber returned an unparseable value; partial=$partial"
            }
            $name = $Matches[1]
            $value = $Matches[2]
            if ($name -cne $expressions[$j] -or $value -match '^<ERROR:') {
                Fail 'ARRAY_VALUE_MISMATCH' "batch $batchNumber returned a missing, reordered or failed value; partial=$partial"
            }
            if ($checkMin -or $checkMax) {
                $numeric = 0.0
                if ($value -match '^0[xX][0-9A-Fa-f]+$') {
                    $numeric = [double][Convert]::ToUInt64($value.Substring(2), 16)
                } elseif (-not [double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$numeric)) {
                    Fail 'ARRAY_VALUE_NOT_NUMERIC' "batch $batchNumber returned a nonnumeric value at $name; partial=$partial"
                }
                if (($checkMin -and $numeric -lt $MinValue) -or ($checkMax -and $numeric -gt $MaxValue)) {
                    Fail 'ARRAY_VALUE_OUT_OF_RANGE' "batch $batchNumber returned $value at $name outside the requested range; partial=$partial"
                }
            }
            $linear = $offset + $j
            $records += [pscustomobject]@{
                row = [int][Math]::Floor($linear / $Columns)
                column = [int]($linear % $Columns)
                expression = $name
                value = $value
            }
        }
        $records | Export-Csv -LiteralPath $partial -NoTypeInformation -Encoding UTF8 -Append
        Write-Output "BATCH: $batchNumber values=$count endIndex=$($offset + $count - 1)"
    }
    Move-Item -LiteralPath $partial -Destination $OutputPath
    Write-Output "OUTPUT: $OutputPath"
    Write-Output "VALUES: $total"
    Write-Output 'RESULT: OK'
    exit 0
} catch {
    Fail 'ARRAY_READ_ERROR' "$($_.Exception.Message); partial=$partial"
}
