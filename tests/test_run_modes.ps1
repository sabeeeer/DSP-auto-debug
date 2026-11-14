#requires -Version 7.0
# Run modes: single-step must refuse every download it was not told about, the
# counter must move only on a real download, and continuous mode must refuse to
# start without an explicit user approval. Nothing here touches a board.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-run-modes-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $fixture 'skill/scripts'
$project = Join-Path $fixture 'folder'

function Get-Count($p) {
    $f = Join-Path $p 'readout/load-count.json'
    if (-not (Test-Path -LiteralPath $f)) { return 0 }
    return [int](Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).count
}
function Invoke-Script([string[]]$a) {
    $out = @(& pwsh @a 2>&1)
    return [ordered]@{ code = $LASTEXITCODE; text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
}

New-Item -ItemType Directory -Force -Path $scripts, $project, (Join-Path $project 'targetConfigs'), (Join-Path $project 'Debug') | Out-Null

try {
    foreach ($n in @('ti_c2000_service.ps1', 'ti_c2000_run_read.ps1', 'ti_c2000_read_dma.ps1', 'ti_c2000_loadcount.ps1', 'ti_c2000_iterate.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "scripts/$n") -Destination $scripts
    }
    # stub only: every case below must stop before any probe/DSS work happens
    '# stub' | Set-Content (Join-Path $scripts 'ti_c2000_debug.ps1') -Encoding UTF8
    '<project/>' | Set-Content (Join-Path $project '.cproject') -Encoding UTF8
    '<projectDescription><name>DemoImage</name></projectDescription>' | Set-Content (Join-Path $project '.project') -Encoding UTF8
    '<config/>' | Set-Content (Join-Path $project 'targetConfigs/target.ccxml') -Encoding UTF8
    'fake' | Set-Content (Join-Path $project 'Debug/DemoImage.out') -Encoding ASCII

    # ---- 1. counter -----------------------------------------------------------
    . (Join-Path $scripts 'ti_c2000_loadcount.ps1')
    $c0 = Get-LoadCount -ProjectPath $project
    if ($c0.count -ne 0) { throw 'counter did not start at 0' }
    for ($i = 1; $i -le 3; $i++) { $null = Add-LoadRecord -ProjectPath $project -Mode 'SingleStep' -Out 'x.out' -Sha256 ('sha' + $i) }
    $c1 = Get-LoadCount -ProjectPath $project
    if ($c1.count -ne 3) { throw "counter is $($c1.count), expected 3" }
    if (@($c1.history).Count -ne 3) { throw 'history did not record three loads' }
    if ($c1.lastSha256 -ne 'sha3') { throw 'lastSha256 not updated' }
    for ($i = 4; $i -le 25; $i++) { $null = Add-LoadRecord -ProjectPath $project -Mode 'Iterate' -Out 'x.out' -Sha256 ('sha' + $i) }
    $c2 = Get-LoadCount -ProjectPath $project
    if ($c2.count -ne 25) { throw "counter is $($c2.count), expected 25" }
    if (@($c2.history).Count -ne 20) { throw 'history is not capped at 20' }
    if ([int]@($c2.history)[-1].n -ne 25) { throw 'history does not end with the newest load' }

    # ---- 2. expectation parsing ----------------------------------------------
    $ok = Test-LoadExpectation -Expect @('gBufSeq>=3') -Values @{ gBufSeq = '5' }
    if (-not $ok.ok) { throw 'a satisfied expectation was reported as failure' }
    $bad = Test-LoadExpectation -Expect @('gBufSeq>=3') -Values @{ gBufSeq = '1' }
    if ($bad.ok) { throw 'an unsatisfied expectation passed' }
    $missing = Test-LoadExpectation -Expect @('gErr==0') -Values @{}
    if ($missing.ok) { throw 'a missing variable passed' }
    $typo = Test-LoadExpectation -Expect @('gBufSeq !! 3') -Values @{ gBufSeq = '3' }
    if ($typo.ok -or ($typo.checks -join ';') -notmatch 'UNPARSED') { throw 'a malformed expectation was not rejected' }

    # ---- 3. single-step refuses to download ----------------------------------
    $before = Get-Count $project
    $r = Invoke-Script @('-NoProfile', '-File', (Join-Path $scripts 'ti_c2000_service.ps1'), '-ProjectPath', $project, '-Start')
    if ($r.code -ne 4) { throw "service -Start without -ConfirmLoad exited $($r.code), expected 4`n$($r.text)" }
    if ($r.text -notmatch 'LOAD_NOT_CONFIRMED') { throw 'service gate did not name LOAD_NOT_CONFIRMED' }
    if (Test-Path (Join-Path $project 'readout/.service/state.json')) { throw 'service wrote a session despite the gate' }
    if ((Get-Count $project) -ne $before) { throw 'counter moved although nothing was downloaded' }

    # ---- 4. readers refuse to auto-start a session ---------------------------
    $r = Invoke-Script @('-NoProfile', '-File', (Join-Path $scripts 'ti_c2000_run_read.ps1'), '-ProjectPath', $project, '-Variables', 'gMsTick')
    if ($r.code -ne 4 -or $r.text -notmatch 'LOAD_NOT_CONFIRMED') { throw "scalar reader did not gate the auto-start`n$($r.text)" }
    $r = Invoke-Script @('-NoProfile', '-File', (Join-Path $scripts 'ti_c2000_read_dma.ps1'), '-ProjectPath', $project, '-FrozenBufferReady', '-ArrayName', 'gBuf', '-Rows', '4', '-Columns', '4')
    if ($r.code -ne 4 -or $r.text -notmatch 'LOAD_NOT_CONFIRMED') { throw "array reader did not gate the auto-start`n$($r.text)" }
    if ((Get-Count $project) -ne $before) { throw 'a gated read still counted a download' }

    # ---- 5. -Standalone needs confirmation too -------------------------------
    $r = Invoke-Script @('-NoProfile', '-File', (Join-Path $scripts 'ti_c2000_run_read.ps1'), '-ProjectPath', $project, '-Variables', 'gMsTick', '-Standalone')
    if ($r.code -ne 4 -or $r.text -notmatch 'RELOAD_BLOCKED') { throw "-Standalone reload was not blocked`n$($r.text)" }

    # ---- 6. continuous mode needs explicit approval --------------------------
    $r = Invoke-Script @('-NoProfile', '-File', (Join-Path $scripts 'ti_c2000_iterate.ps1'), '-ProjectPath', $project, '-Variables', 'gBufSeq', '-Expect', 'gBufSeq>=3')
    if ($r.code -ne 4 -or $r.text -notmatch 'ITERATE_NOT_APPROVED') { throw "iterate mode ran without approval`n$($r.text)" }
    if ((Get-Count $project) -ne $before) { throw 'iterate without approval still counted a download' }

    # ---- 7. status reports the counter without touching the target -----------
    $r = Invoke-Script @('-NoProfile', '-File', (Join-Path $scripts 'ti_c2000_service.ps1'), '-ProjectPath', $project, '-Status')
    if ($r.code -ne 0 -or $r.text -notmatch 'SERVICE : STOPPED' -or $r.text -notmatch ('LOADS   : #' + $before)) {
        throw "status did not report the stopped service and its load count`n$($r.text)"
    }

    Write-Output 'PASS: single-step gates every download, the counter moves only on real loads, continuous mode needs approval'
    Write-Output 'RESULT: OK'
    exit 0
} catch {
    Write-Output ('FAIL: ' + $_.Exception.Message)
    Write-Output 'RESULT: FAIL'
    exit 1
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ([IO.Path]::GetFileName($fixture) -like 'c2000-run-modes-*' -and $fixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
