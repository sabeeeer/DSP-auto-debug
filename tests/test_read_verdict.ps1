#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checker = Join-Path $root 'scripts/ti_c2000_check_read.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-verdict-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null

function Check-Csv([string]$name, [string]$body, [string]$failure, [string[]]$extraArgs = @()) {
    $path = Join-Path $fixture ($name + '.csv')
    [IO.File]::WriteAllText($path, $body)
    $output = @(& pwsh -NoProfile -File $checker -CsvPath $path @extraArgs 2>&1)
    $code = $LASTEXITCODE
    if ($failure) {
        if ($code -eq 0 -or -not @($output | Where-Object { $_ -eq "FAILURE: $failure" }).Count) {
            throw "$name should fail with $failure; got exit=$code output=$($output -join '; ')"
        }
    } elseif ($code -ne 0 -or -not @($output | Where-Object { $_ -eq 'RESULT: OK' }).Count) {
        throw "$name should pass; got exit=$code output=$($output -join '; ')"
    }
}

try {
    $path = Join-Path $fixture 'stalled.csv'
    [IO.File]::WriteAllText($path, "gMsTick`n11460`n11460`n")
    $out = @(& pwsh -NoProfile -File $checker -CsvPath $path -HeartbeatVars gMsTick 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($out | Where-Object { $_ -eq 'HEARTBEAT: FAIL' }).Count) { throw 'stalled counter passed' }

    Check-Csv 'unrelated' "adcValue`n1`n2`n" 'NO_HEARTBEAT' @('-HeartbeatVars', 'gMsTick')
    Check-Csv 'single' "gMsTick`n1`n" 'NO_LIVENESS_INTERVAL' @('-HeartbeatVars', 'gMsTick')
    Check-Csv 'existing-firmware' "gMsTick`n12000`n13000`n" '' @('-HeartbeatVars', 'gMsTick')
    Check-Csv 'one-same-interval' "gMsTick`n1`n1`n2`n" '' @('-HeartbeatVars', 'gMsTick')
    $twiceStalledPath = Join-Path $fixture 'twice-stalled.csv'
    [IO.File]::WriteAllText($twiceStalledPath, "gMsTick`n1`n1`n1`n")
    $twiceStalled = @(& pwsh -NoProfile -File $checker -CsvPath $twiceStalledPath -HeartbeatVars gMsTick 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($twiceStalled | Where-Object { $_ -eq 'HEARTBEAT: FAIL' }).Count) { throw 'two stagnant intervals passed' }
    $existingPath = Join-Path $fixture 'existing-firmware.csv'
    $fresh = @(& pwsh -NoProfile -File $checker -CsvPath $existingPath -HeartbeatVars gMsTick -CheckStartupWindow 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($fresh | Where-Object { $_ -match '^CHECK gMsTick: first value 12000' }).Count) { throw 'fresh-load startup window was ignored' }
    Check-Csv 'frozen-array' "value`n0`n4095`n" '' @('-AllowNoHeartbeat', '-ExpectedRows', '2', '-RangeVars', 'value', '-ValueMin', '0', '-ValueMax', '4095')
    Check-Csv 'hex-value' "value`n0x000F`n0x00FF`n" '' @('-AllowNoHeartbeat', '-ExpectedRows', '2', '-RangeVars', 'value', '-ValueMin', '0', '-ValueMax', '255')
    $invalidPath = Join-Path $fixture 'invalid-array.csv'
    [IO.File]::WriteAllText($invalidPath, "value`n0`ninvalid`n")
    $invalid = @(& pwsh -NoProfile -File $checker -CsvPath $invalidPath -AllowNoHeartbeat -ExpectedRows 2 -RangeVars value -ValueMin 0 -ValueMax 4095 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($invalid | Where-Object { $_ -eq 'RANGE: FAIL' }).Count) { throw 'non-numeric array data passed the range check' }
    $invalidNoBounds = @(& pwsh -NoProfile -File $checker -CsvPath $invalidPath -AllowNoHeartbeat -ExpectedRows 2 -RangeVars value 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($invalidNoBounds | Where-Object { $_ -eq 'RANGE: FAIL' }).Count) { throw 'non-numeric array data passed without bounds' }
    $singleNoHeartbeat = @(& pwsh -NoProfile -File $checker -CsvPath (Join-Path $fixture 'single.csv') -AllowNoHeartbeat -HeartbeatVars gMsTick 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not @($singleNoHeartbeat | Where-Object { $_ -match '^HEARTBEAT: SKIPPED' }).Count -or @($singleNoHeartbeat | Where-Object { $_ -eq 'HEARTBEAT: OK' }).Count) { throw 'single-row liveness was reported as OK' }
    Write-Output 'PASS: stalled/missing/single-row heartbeats fail; existing firmware and frozen arrays use separate criteria'
    Write-Output 'RESULT: OK'
    exit 0
} catch {
    Write-Output ('FAIL: ' + $_.Exception.Message)
    Write-Output 'RESULT: FAIL'
    exit 1
} finally {
    if ([IO.Path]::GetFileName($fixture) -like 'c2000-verdict-*' -and $fixture.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
