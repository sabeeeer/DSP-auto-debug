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
    Write-Output 'PASS: build-only never downloads; implicit load and read-only/build conflict rejected'
    Write-Output 'RESULT: OK'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = [IO.Path]::GetFullPath($fixture)
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([IO.Path]::GetFileName($resolved) -like 'ti-c2000-mode-test-*')) { throw 'Unsafe fixture cleanup path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
