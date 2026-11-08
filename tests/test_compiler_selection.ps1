#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = [IO.Path]::GetFullPath((Join-Path $tempBase ('ti-c2000-compiler-test-' + [guid]::NewGuid().ToString('N'))))
if (-not $fixture.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped temp' }

try {
    $project = Join-Path $fixture 'project'
    $ccs = Join-Path $fixture 'ccs'
    New-Item -ItemType Directory -Force -Path $project, (Join-Path $ccs 'ccs_base') | Out-Null
    @'
<cproject><cconfiguration id="test"><configuration id="cfg" name="Debug"><option id="OPT_CODEGEN_VERSION" value="99.99.99"/></configuration></cconfiguration></cproject>
'@ | Set-Content -LiteralPath (Join-Path $project '.cproject') -Encoding utf8
    $build = Join-Path $skillRoot 'scripts\ti_c2000_build.ps1'
    $output = @(& pwsh -NoProfile -File $build -ProjectPath $project -CcsRoot $ccs 2>&1)
    if ($LASTEXITCODE -ne 2 -or -not @($output | Where-Object { $_ -match '^FAILURE: COMPILER_VERSION_MISSING$' }).Count -or
        @($output | Where-Object { $_ -match '^COMPILER:' }).Count) {
        throw "Missing declared compiler did not stop before compilation: $($output -join '; ')"
    }
    Write-Output 'PASS: missing declared compiler fails closed without selecting a newer version'
    Write-Output 'RESULT: OK'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = [IO.Path]::GetFullPath($fixture)
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([IO.Path]::GetFileName($resolved) -like 'ti-c2000-compiler-test-*')) { throw 'Unsafe fixture cleanup path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
