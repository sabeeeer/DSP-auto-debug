#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ti-c2000-mode-test-' + [guid]::NewGuid().ToString('N'))
$fixture = [IO.Path]::GetFullPath($fixture)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $fixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture path escaped the temp directory' }

try {
    $scripts = Join-Path $fixture 'scripts'
    $project = Join-Path $fixture 'project'
    $ccs = Join-Path $fixture 'ccs'
    New-Item -ItemType Directory -Path $scripts, $project, (Join-Path $ccs 'ccs_base') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $skillRoot 'scripts/ti_c2000_debug.ps1') -Destination $scripts
    Set-Content -LiteralPath (Join-Path $scripts 'ti_c2000_build.ps1') -Value "#requires -Version 7.0`nWrite-Output 'RESULT: OK'`nexit 0" -Encoding utf8
    Set-Content -LiteralPath (Join-Path $project '.cproject') -Value '<project/>' -Encoding utf8
    $debug = Join-Path $scripts 'ti_c2000_debug.ps1'

    $buildOutput = @(& pwsh -NoProfile -File $debug -ProjectPath $project -CcsRoot $ccs -Build 2>&1)
    $buildCode = $LASTEXITCODE
    if ($buildCode -ne 0 -or -not @($buildOutput | Where-Object { $_ -match '^RESULT: OK$' }).Count -or
        -not @($buildOutput | Where-Object { $_ -match 'no download or run requested' }).Count) {
        throw "Build-only mode tried to load or failed: $($buildOutput -join '; ')"
    }

    $emptyOutput = @(& pwsh -NoProfile -File $debug -ProjectPath $project -CcsRoot $ccs 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($emptyOutput | Where-Object { $_ -match '^FAILURE: ACTION_REQUIRED$' }).Count) {
        throw 'Missing-action invocation did not fail closed'
    }

    $conflictOutput = @(& pwsh -NoProfile -File $debug -ProjectPath $project -ReadOnly -ReadVars gBootStage -Build 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($conflictOutput | Where-Object { $_ -match '^FAILURE: READONLY_MODE_CONFLICT$' }).Count) {
        throw 'Read-only and build were allowed together'
    }
    $combinedOutput = @(& pwsh -NoProfile -File $debug -ProjectPath $project -Build -Run -ReadVars gBootStage 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($combinedOutput | Where-Object { $_ -match '^FAILURE: READ_REQUIRES_SEPARATE_READONLY$' }).Count) {
        throw 'Build/run/read combination was allowed to enter the halting DSS path'
    }
    $waitOnlyOutput = @(& pwsh -NoProfile -File $debug -ProjectPath $project -Run -WaitFor 'gBootStage == 5' 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($waitOnlyOutput | Where-Object { $_ -match '^FAILURE: WAIT_REQUIRES_READONLY$' }).Count) {
        throw 'Run-only command silently accepted a read condition'
    }

    # Validation must run before the script searches for CCS or touches JTAG.
    $badReads = @('gValue=1', 'gValue++', 'functionCall()', '(*f)()', 'gValue ? x : y', 'gValue;foo', 'gArray[gIndex]')
    foreach ($bad in $badReads) {
        $badOutput = @(& pwsh -NoProfile -File $debug -ProjectPath $project -ReadOnly -ReadVars $bad 2>&1)
        if ($LASTEXITCODE -eq 0 -or -not @($badOutput | Where-Object { $_ -match '^FAILURE: READONLY_EXPRESSION_UNSAFE$' }).Count) {
            throw "Unsafe read expression was accepted: $bad"
        }
    }
    $badWaitOutput = @(& pwsh -NoProfile -File $debug -ProjectPath $project -ReadOnly -ReadVars gValue -WaitFor 'gValue = 1' 2>&1)
    if ($LASTEXITCODE -eq 0 -or -not @($badWaitOutput | Where-Object { $_ -match '^FAILURE: READONLY_EXPRESSION_UNSAFE$' }).Count) {
        throw 'Unsafe wait expression was accepted'
    }
    $safeOutput = @(& pwsh -NoProfile -File $debug -ProjectPath (Join-Path $fixture 'missing-project') -ReadOnly -ReadVars 'ClAdcCtrl.usResult[0],EPwm1Regs.TBPRD' -WaitFor 'y1 > 5.8 && y2 > 13.2' 2>&1)
    if (-not @($safeOutput | Where-Object { $_ -match '^FAILURE: NO_PROJECT$' }).Count) {
        throw 'Safe read expressions were rejected before project lookup'
    }
    $autoReadonlyOutput = @(& pwsh -NoProfile -File $debug -ProjectPath $project -CcsRoot $ccs -ReadVars 'gBootStage' 2>&1)
    if (-not @($autoReadonlyOutput | Where-Object { $_ -match '^FAILURE: NO_OUT_FILE$' }).Count -or
        -not @($autoReadonlyOutput | Where-Object { $_ -match 'read-only mode will not build or download' }).Count) {
        throw 'Read-only shorthand did not route to the non-stop path'
    }
    $dssTemplate = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/dss_template.js') -Raw
    if ($dssTemplate -match 'session\.target\.(halt|runAsynch|reset|restart)\s*\(' -or $dssTemplate -match 'session\.memory\.loadProgram\s*\(') {
        throw 'Read-only DSS template contains a target state change or program load'
    }
    Write-Output 'PASS: build/run/read separated; read-only DSS has no halt/reset/load; expressions gated'
    Write-Output 'RESULT: OK'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = [IO.Path]::GetFullPath($fixture)
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([IO.Path]::GetFileName($resolved) -like 'ti-c2000-mode-test-*')) { throw 'Unsafe fixture cleanup path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
