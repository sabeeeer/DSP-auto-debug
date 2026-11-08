#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-read-array-' + [guid]::NewGuid().ToString('N'))
$fixture = [IO.Path]::GetFullPath($fixture)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $fixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped temp directory' }
$scripts = Join-Path $fixture 'scripts'
New-Item -ItemType Directory -Path $scripts -Force | Out-Null

try {
    Copy-Item -LiteralPath (Join-Path $skillRoot 'scripts/ti_c2000_read_array_runtime.ps1') -Destination $scripts
    @'
#requires -Version 7.0
param([string]$ProjectPath,[string]$ReadArray,[int]$ArrayRows,[int]$ArrayColumns,[int]$ArrayBatchSize,[string]$HeartbeatExpr)
$sample = if ($env:TI_C2000_TEST_ARRAY_VALUE) { $env:TI_C2000_TEST_ARRAY_VALUE } else { '123' }
Add-Content -LiteralPath (Join-Path $ProjectPath 'calls.txt') -Value 'called'
if ($HeartbeatExpr) { Write-Output 'DSS: heartbeat advanced before array capture (1 -> 2)' }
$total = $ArrayRows * $ArrayColumns
for ($i = 0; $i -lt $total; $i++) {
    $row = [int][Math]::Floor($i / $ArrayColumns)
    $col = $i % $ArrayColumns
    $name = if ($ArrayRows -eq 1) { '{0}[{1}]' -f $ReadArray,$col } else { '{0}[{1}][{2}]' -f $ReadArray,$row,$col }
    Write-Output "VAR $name = $sample"
    if ((($i + 1) % $ArrayBatchSize -eq 0) -or ($i + 1 -eq $total)) {
        $batch = [int][Math]::Ceiling(($i + 1) / $ArrayBatchSize)
        if ($HeartbeatExpr) { Write-Output "DSS: heartbeat advanced after array batch $batch (2 -> 3)" }
        Write-Output "BATCH: $batch values=$([Math]::Min($ArrayBatchSize,$total-($batch-1)*$ArrayBatchSize)) endIndex=$i"
    }
}
Write-Output 'RESULT: OK'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $scripts 'ti_c2000_debug.ps1') -Encoding UTF8

    $arrayScript = Join-Path $scripts 'ti_c2000_read_array_runtime.ps1'
    $outputPath = Join-Path $fixture 'array.csv'
    $result = @(& pwsh -NoProfile -File $arrayScript -ProjectPath $fixture -ArrayName gAdcAllBuf -Rows 2 -Columns 3 -BatchSize 2 -WaitFor 'gAdcBufFull == 1' -HeartbeatExpr gRunMs -MinValue 0 -MaxValue 4095 -OutputPath $outputPath 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not @($result | Where-Object { $_ -eq 'RESULT: OK' }).Count) { throw "batch capture failed: $($result -join '; ')" }
    $records = @(Import-Csv -LiteralPath $outputPath)
    if ($records.Count -ne 6 -or $records[0].expression -ne 'gAdcAllBuf[0][0]' -or $records[5].expression -ne 'gAdcAllBuf[1][2]' -or $records[5].value -ne '123') {
        throw 'batch capture dimensions or values were incorrect'
    }
    if (@($result | Where-Object { $_ -match '^BATCH: ' }).Count -ne 3) { throw 'expected three bounded batches' }
    if (@(Get-Content (Join-Path $fixture 'calls.txt')).Count -ne 1) { throw 'array helper opened more than one DSS session' }

    $existing = @(& pwsh -NoProfile -File $arrayScript -ProjectPath $fixture -ArrayName gAdcAllBuf -Rows 2 -Columns 3 -OutputPath $outputPath 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($existing | Where-Object { $_ -eq 'FAILURE: OUTPUT_EXISTS' }).Count) { throw 'existing capture could be overwritten' }

    $env:TI_C2000_TEST_ARRAY_VALUE = '65012'
    $badOutputPath = Join-Path $fixture 'out-of-range.csv'
    $bad = @(& pwsh -NoProfile -File $arrayScript -ProjectPath $fixture -ArrayName gAdcAllBuf -Rows 2 -Columns 3 -BatchSize 2 -MinValue 0 -MaxValue 4095 -OutputPath $badOutputPath 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($bad | Where-Object { $_ -eq 'FAILURE: ARRAY_READ_INCOMPLETE' }).Count -or (Test-Path $badOutputPath) -or
        -not (Test-Path "$badOutputPath.partial")) {
        throw 'out-of-range ADC result was accepted as a complete capture'
    }
    Remove-Item Env:TI_C2000_TEST_ARRAY_VALUE -ErrorAction SilentlyContinue

    Write-Output 'PASS: one-session array helper checks fixed indices, heartbeat and range without overwriting captures'
    Write-Output 'RESULT: OK'
    exit 0
} catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output 'RESULT: FAIL'
    exit 1
} finally {
    Remove-Item Env:TI_C2000_TEST_ARRAY_VALUE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture) {
        $resolved = [IO.Path]::GetFullPath($fixture)
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([IO.Path]::GetFileName($resolved) -like 'c2000-read-array-*')) { throw 'Unsafe fixture cleanup path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
