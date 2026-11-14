#requires -Version 7.0
# Two orthogonal dimensions, and every illegal combination between them:
#   RUN MODE  : SingleStep (load once, then attach) | Iterate (continuous re-download)
#   READ MODE : ReadOnly (never downloads)          | LoadRead (downloads once)
# Each refusal must be one FAILURE line plus one documented exit code, decided before
# any probe/DSS work. Nothing here touches a board.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-modes-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $fixture 'skill/scripts'
$project = Join-Path $fixture 'folder'
$svcDir = Join-Path $project 'readout/.service'
$marker = Join-Path $project 'readout/iterate/active.json'

function Get-Count($p) {
    $f = Join-Path $p 'readout/load-count.json'
    if (-not (Test-Path -LiteralPath $f)) { return 0 }
    return [int](Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).count
}
function Invoke-Script([string[]]$a) {
    $out = @(& pwsh @a 2>&1)
    return [ordered]@{ code = $LASTEXITCODE; text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
}
function Expect([string]$label, $r, [int]$code, [string]$pattern) {
    if ($r.code -ne $code) { throw "$label : exit $($r.code), expected $code`n$($r.text)" }
    if ($pattern -and $r.text -notmatch $pattern) { throw "$label : output has no '$pattern'`n$($r.text)" }
}
function Write-Marker([int]$holderPid) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
    $o = [ordered]@{
        mode = 'Iterate'; pid = $holderPid; round = 2; maxLoads = 5
        expect = @('gBufSeq>=3'); started = '2026-11-14 10:00:00'
    }
    [IO.File]::WriteAllText($marker, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

New-Item -ItemType Directory -Force -Path $scripts, $project, (Join-Path $project 'targetConfigs'), (Join-Path $project 'Debug'), $svcDir | Out-Null

try {
    foreach ($n in @('ti_c2000_service.ps1', 'ti_c2000_run_read.ps1', 'ti_c2000_read_dma.ps1',
                     'ti_c2000_iterate.ps1', 'ti_c2000_loadcount.ps1', 'ti_c2000_readmode.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "scripts/$n") -Destination $scripts
    }
    # stub only: every case below must stop before any probe/DSS work happens
    '# stub' | Set-Content (Join-Path $scripts 'ti_c2000_debug.ps1') -Encoding UTF8
    '<project/>' | Set-Content (Join-Path $project '.cproject') -Encoding UTF8
    '<projectDescription><name>DemoImage</name></projectDescription>' | Set-Content (Join-Path $project '.project') -Encoding UTF8
    '<config/>' | Set-Content (Join-Path $project 'targetConfigs/target.ccxml') -Encoding UTF8
    'fake' | Set-Content (Join-Path $project 'Debug/DemoImage.out') -Encoding ASCII

    $svc = Join-Path $scripts 'ti_c2000_service.ps1'
    $read = Join-Path $scripts 'ti_c2000_run_read.ps1'
    $dma = Join-Path $scripts 'ti_c2000_read_dma.ps1'
    $iter = Join-Path $scripts 'ti_c2000_iterate.ps1'

    # ---- 1. download counter accepts every real download, rejects retired names --
    . (Join-Path $scripts 'ti_c2000_loadcount.ps1')
    if ((Get-LoadCount -ProjectPath $project).count -ne 0) { throw 'counter did not start at 0' }
    $null = Add-LoadRecord -ProjectPath $project -Mode 'SingleStep' -Out 'x.out' -Sha256 'sha1'
    $null = Add-LoadRecord -ProjectPath $project -Mode 'Iterate' -Out 'x.out' -Sha256 'sha2'
    $null = Add-LoadRecord -ProjectPath $project -Mode 'LoadRead' -Out 'x.out' -Sha256 'sha3'
    $null = Add-LoadRecord -ProjectPath $project -Mode 'Explicit' -Out 'x.out' -Sha256 'sha4'
    $c = Get-LoadCount -ProjectPath $project
    if ($c.count -ne 4) { throw "counter is $($c.count), expected 4" }
    if ($c.lastMode -ne 'Explicit') { throw "lastMode is '$($c.lastMode)'" }
    for ($i = 5; $i -le 25; $i++) { $null = Add-LoadRecord -ProjectPath $project -Mode 'Iterate' -Sha256 ('sha' + $i) }
    $c = Get-LoadCount -ProjectPath $project
    if ($c.count -ne 25) { throw "counter is $($c.count), expected 25" }
    if (@($c.history).Count -ne 20) { throw 'history is not capped at 20' }
    $rejected = $false
    try { $null = Add-LoadRecord -ProjectPath $project -Mode 'SingleStepV2' } catch { $rejected = $true }
    if (-not $rejected) { throw 'an unknown mode name was accepted by Add-LoadRecord' }

    # reset the history so the load assertions below read cleanly
    Remove-Item -LiteralPath (Join-Path $project 'readout/load-count.json') -Force
    $before = Get-Count $project

    # ---- 2. RUN MODE gate: continuous needs the user's yes ----------------------
    $r = Invoke-Script @('-NoProfile', '-File', $svc, '-ProjectPath', $project, '-Start', '-RunMode', 'Iterate', '-ConfirmLoad')
    Expect 'service -RunMode Iterate without approval' $r 4 'ITERATE_NOT_APPROVED'
    if (Test-Path (Join-Path $svcDir 'state.json')) { throw 'a refused iterate start left a session behind' }

    $r = Invoke-Script @('-NoProfile', '-File', $iter, '-ProjectPath', $project, '-Variables', 'gBufSeq', '-Expect', 'gBufSeq>=3')
    Expect 'iterate without -UserApproved' $r 4 'ITERATE_NOT_APPROVED'
    if ((Get-Count $project) -ne $before) { throw 'a refused iterate run counted a download' }
    if (Test-Path -LiteralPath $marker) { throw 'a refused iterate run left its marker behind' }

    # ---- 3. the plain download gate still holds --------------------------------
    $r = Invoke-Script @('-NoProfile', '-File', $svc, '-ProjectPath', $project, '-Start')
    Expect 'service -Start without -ConfirmLoad' $r 4 'LOAD_NOT_CONFIRMED'
    $r = Invoke-Script @('-NoProfile', '-File', $read, '-ProjectPath', $project, '-Mode', 'LoadRead', '-Variables', 'gMsTick')
    Expect 'LoadRead without -ConfirmLoad' $r 4 'LOAD_NOT_CONFIRMED'
    $r = Invoke-Script @('-NoProfile', '-File', $read, '-ProjectPath', $project, '-Standalone', '-Variables', 'gMsTick')
    Expect '-Standalone without -ConfirmLoad' $r 4 'LOAD_NOT_CONFIRMED'
    if ((Get-Count $project) -ne $before) { throw 'a refused download counted a download' }

    # ---- 4. READ MODE gate: ReadOnly never carries download switches -----------
    # -Standalone is not listed: it is the LoadRead alias, so it means "download"
    foreach ($clash in @(@('-ConfirmLoad'), @('-Build'))) {
        $a = @('-NoProfile', '-File', $read, '-ProjectPath', $project, '-Variables', 'gMsTick') + $clash
        $r = Invoke-Script $a
        Expect "ReadOnly + $($clash -join ' ')" $r 2 'MUTUALLY_EXCLUSIVE'
    }
    $r = Invoke-Script @('-NoProfile', '-File', $read, '-ProjectPath', $project, '-Variables', 'gMsTick', '-Expect', 'gMsTick>0')
    Expect 'ReadOnly + -Expect' $r 2 'MUTUALLY_EXCLUSIVE'
    $r = Invoke-Script @('-NoProfile', '-File', $dma, '-ProjectPath', $project, '-ArrayName', 'gBuf', '-Rows', '2', '-Columns', '2', '-FrozenBufferReady', '-ConfirmLoad')
    Expect 'DMA ReadOnly + -ConfirmLoad' $r 2 'MUTUALLY_EXCLUSIVE'

    # ---- 5. ReadOnly needs a live session; nothing is downloaded to create one --
    $r = Invoke-Script @('-NoProfile', '-File', $read, '-ProjectPath', $project, '-Variables', 'gMsTick')
    Expect 'ReadOnly without a session' $r 4 'NO_SESSION'
    $r = Invoke-Script @('-NoProfile', '-File', $dma, '-ProjectPath', $project, '-ArrayName', 'gBuf', '-Rows', '2', '-Columns', '2', '-FrozenBufferReady')
    Expect 'DMA ReadOnly without a session' $r 4 'NO_SESSION'
    if ((Get-Count $project) -ne $before) { throw 'a refused read counted a download' }

    # ---- 6. while Iterate runs, everything else is locked out ------------------
    Write-Marker $PID

    $r = Invoke-Script @('-NoProfile', '-File', $read, '-ProjectPath', $project, '-Variables', 'gMsTick')
    Expect 'ReadOnly while Iterate runs' $r 4 'READONLY_IN_ITERATE'
    $r = Invoke-Script @('-NoProfile', '-File', $read, '-ProjectPath', $project, '-Mode', 'LoadRead', '-ConfirmLoad', '-Variables', 'gMsTick')
    Expect 'LoadRead while Iterate runs' $r 2 'MUTUALLY_EXCLUSIVE'
    $r = Invoke-Script @('-NoProfile', '-File', $svc, '-ProjectPath', $project, '-Start', '-ConfirmLoad')
    Expect 'service -Start while Iterate runs' $r 4 'ITERATE_IN_PROGRESS'
    $r = Invoke-Script @('-NoProfile', '-File', $svc, '-ProjectPath', $project, '-Stop')
    Expect 'service -Stop while Iterate runs' $r 4 'ITERATE_IN_PROGRESS'
    $r = Invoke-Script @('-NoProfile', '-File', $iter, '-ProjectPath', $project, '-UserApproved', '-Variables', 'gBufSeq')
    Expect 'second Iterate while one runs' $r 4 'ITERATE_IN_PROGRESS'
    if ((Get-Count $project) -ne $before) { throw 'a locked-out call counted a download' }

    # -Status only reports, so it must stay usable during a continuous run
    $r = Invoke-Script @('-NoProfile', '-File', $svc, '-ProjectPath', $project, '-Status')
    Expect 'service -Status while Iterate runs' $r 0 'RESULT: OK'
    if ($r.text -notmatch 'RUN MODE') { throw "status does not report the run mode`n$($r.text)" }

    # ---- 7. a marker from a dead process must not lock the project for ever ----
    Write-Marker 999999
    $r = Invoke-Script @('-NoProfile', '-File', $read, '-ProjectPath', $project, '-Variables', 'gMsTick')
    Expect 'stale iterate marker is ignored' $r 4 'NO_SESSION'
    Remove-Item -LiteralPath $marker -Force

    # ---- 8. with the user's yes, LoadRead gets as far as the probe ------------
    $r = Invoke-Script @('-NoProfile', '-File', $read, '-ProjectPath', $project, '-Mode', 'LoadRead', '-ConfirmLoad', '-Variables', 'gMsTick')
    if ($r.code -eq 4 -or $r.text -match 'LOAD_NOT_CONFIRMED|MUTUALLY_EXCLUSIVE|ITERATE_IN_PROGRESS') {
        throw "an approved LoadRead was refused before the probe check`n$($r.text)"
    }
    Expect 'approved LoadRead reaches the probe check' $r 2 'PROBE_CHECK_FAILED'
    if (Test-Path -LiteralPath (Join-Path $svcDir 'target.lock')) { throw 'the target lock was left behind after a failed LoadRead' }
    if ((Get-Count $project) -ne $before) { throw 'a read that never reached the target counted a download' }

    Write-Output 'PASS: SingleStep/Iterate and ReadOnly/LoadRead are gated separately, cross-locked while Iterate runs, and no refusal downloads anything'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
