#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-single-session-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $fixture 'skill/scripts'
$project = Join-Path $fixture 'folder'
$ccs = Join-Path $fixture 'ccs'
$dssDir = Join-Path $ccs 'ccs_base/scripting/bin'
New-Item -ItemType Directory -Force -Path $scripts, $project, $dssDir, (Join-Path $project 'Debug'), (Join-Path $project 'targetConfigs') | Out-Null

try {
    # copy the whole scripts folder: listing files by hand means every new helper
    # (ti_c2000_readmode.ps1 arrived that way) silently breaks the fixture
    Copy-Item (Join-Path $root 'scripts/*.ps1') $scripts -Force
    # the readers dot-source the mode library, so ti_c2000_debug.ps1 must be a stub
    # AFTER the copy or it would overwrite the real one
    Remove-Item (Join-Path $scripts 'ti_c2000_debug.ps1') -Force -ErrorAction SilentlyContinue
    @'
param([string]$ProjectPath, [string]$CcsRoot, [switch]$ProbeCheckOnly)
Write-Output 'RESULT: OK'
exit 0
'@ | Set-Content (Join-Path $scripts 'ti_c2000_debug.ps1') -Encoding UTF8
    '<project/>' | Set-Content (Join-Path $project '.cproject') -Encoding UTF8
    '<projectDescription><name>DemoImage</name></projectDescription>' | Set-Content (Join-Path $project '.project') -Encoding UTF8
    '<config/>' | Set-Content (Join-Path $project 'targetConfigs/target.ccxml') -Encoding UTF8
    'fake' | Set-Content (Join-Path $project 'Debug/DemoImage.out') -Encoding ASCII

    # default path: both readers must attach to the live session, not load again
    foreach ($name in @('ti_c2000_run_read.ps1', 'ti_c2000_read_dma.ps1')) {
        $text = Get-Content -LiteralPath (Join-Path $root "scripts/$name") -Raw
        if ($text -notmatch 'ti_c2000_live_read\.ps1') { throw "$name does not read through the live session by default" }
        if ($text -notmatch '\$Standalone') { throw "$name lost its -Standalone escape hatch" }
    }

    foreach ($mode in @('scalar','array')) {
        $capture = Join-Path $fixture "$mode.js"
        @"
@echo off
copy /Y "%~1" "$capture" >nul
echo RESULT: FAIL
exit /b 1
"@ | Set-Content (Join-Path $dssDir 'dss.bat') -Encoding ASCII

        $args = @('-NoProfile', '-File', (Join-Path $scripts $(if ($mode -eq 'scalar') {'ti_c2000_run_read.ps1'} else {'ti_c2000_read_dma.ps1'})), '-ProjectPath', $project, '-CcsRoot', $ccs, '-Standalone', '-ConfirmLoad')
        if ($mode -eq 'scalar') { $args += @('-Variables', 'gRunMs,ClAdcCtrl.usResult[0]') }
        else { $args += @('-FrozenBufferReady', '-ArrayName', 'gAdcAllBuf', '-Rows', '16', '-Columns', '400', '-FrozenFlag', 'gAdcBufFull', '-FrozenValue', '2', '-SeqVar', '', '-HeartbeatExpr', 'gRunMs', '-Variables', 'gBootStage,EPwm1Regs.TBPRD') }
        $output = @(& pwsh @args 2>&1)
        if ($LASTEXITCODE -eq 0 -or -not (Test-Path $capture)) { throw "$mode fake DSS did not capture a script: $($output -join '; ')" }
        $js = Get-Content -LiteralPath $capture -Raw
        if ($js -notmatch 'DemoImage\.out' -or @([regex]::Matches($js, 'session\.memory\.loadProgram\(OUT\)')).Count -ne 1 -or
            $js -notmatch 'session\.target\.runAsynch\(\)' -or $js -notmatch 'session\.target\.isHalted\(\)') {
            throw "$mode script lacks the resolved .out, one load, run, or running-state check"
        }
        if ($js -match '\{\{[^}]+\}\}' -or $js -notmatch 'server\.openSession\(CORE\)') {
            throw "$mode generated JavaScript has an unresolved template token or no DSS session"
        }
        if ($mode -eq 'array' -and ($js -notmatch 'var EXTRAS = \["gBootStage","EPwm1Regs\.TBPRD"\]' -or $js -notmatch 'EXTRA.*before' -or $js -notmatch 'EXTRA.*after' -or $js -notmatch 'ARRAY_LAYOUT_MISMATCH' -or $js -notmatch 'var FROZEN_EXPECTED = "2"' -or $js -notmatch 'isFinite\(hAfter\)')) {
            throw 'Frozen-buffer reader omitted same-session scalars or address anchors'
        }
    }
    Write-Output 'PASS: both execution readers generate DSS scripts, resolve .project output name, and load once per session'
    Write-Output 'RESULT: OK'
    exit 0
} catch {
    Write-Output ('FAIL: ' + $_.Exception.Message)
    Write-Output 'RESULT: FAIL'
    exit 1
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ([IO.Path]::GetFileName($fixture) -like 'c2000-single-session-*' -and $fixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
