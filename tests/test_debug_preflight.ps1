#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = [IO.Path]::GetFullPath((Join-Path $tempBase ('ti c2000 preflight ' + [guid]::NewGuid().ToString('N'))))
if (-not $fixture.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped temp' }

try {
    $scripts = Join-Path $fixture 'scripts'
    $project = Join-Path $fixture 'project with spaces'
    $ccs = Join-Path $fixture 'ccs with spaces'
    $loadtiDir = Join-Path $ccs 'ccs_base\scripting\examples\loadti'
    $configDir = Join-Path $project 'targetConfigs'
    New-Item -ItemType Directory -Path $scripts, $configDir, (Join-Path $project 'Debug'), $loadtiDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $skillRoot 'scripts\ti_c2000_debug.ps1') -Destination $scripts
    $debug = Join-Path $scripts 'ti_c2000_debug.ps1'
    $buildMark = Join-Path $fixture 'build-called.txt'
    @"
#requires -Version 7.0
Set-Content -LiteralPath '$buildMark' -Value 'called'
Write-Output 'RESULT: OK'
exit 0
"@ | Set-Content -LiteralPath (Join-Path $scripts 'ti_c2000_build.ps1') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $project '.cproject') -Value '<project/>' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $project '.project') -Value '<projectDescription><name>mock</name></projectDescription>' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $project 'Debug\mock.out') -Value 'fixture' -Encoding ascii
    @'
<configurations><configuration><instance desc="Texas Instruments XDS100v2 USB Debug Probe"/><connection><platform><instance id="TMS320F28335_0"/></platform></connection></configuration></configurations>
'@ | Set-Content -LiteralPath (Join-Path $configDir 'target.ccxml') -Encoding utf8
    @'
@echo off
echo Done
echo Target running...
'@ | Set-Content -LiteralPath (Join-Path $loadtiDir 'loadti.bat') -Encoding ascii

    # Override only the Windows enumeration API in the child PowerShell. No
    # real CCS, probe, target or compiler is used by this fixture.
    $noProbeWrapper = Join-Path $fixture 'no-probe.ps1'
    @"
function Get-CimInstance { @() }
& '$debug' -ProjectPath '$project' -CcsRoot '$ccs' -Build -Run
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $noProbeWrapper -Encoding utf8
    $noProbe = @(& pwsh -NoProfile -File $noProbeWrapper 2>&1)
    if ($LASTEXITCODE -ne 3 -or -not @($noProbe | Where-Object { $_ -match '^FAILURE: NO_PROBE$' }).Count -or
        (Test-Path -LiteralPath $buildMark)) { throw "No-probe run did not stop before build: $($noProbe -join '; ')" }

    $checkWrapper = Join-Path $fixture 'probe-check.ps1'
    @"
function Get-CimInstance { @() }
& '$debug' -ProjectPath '$project' -CcsRoot '$ccs' -ProbeCheckOnly
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $checkWrapper -Encoding utf8
    $check = @(& pwsh -NoProfile -File $checkWrapper 2>&1)
    if ($LASTEXITCODE -ne 3 -or -not @($check | Where-Object { $_ -match '^FAILURE: NO_PROBE$' }).Count -or
        (Test-Path -LiteralPath $buildMark)) { throw 'ProbeCheckOnly did not fail closed' }

    $buildOnly = @(& pwsh -NoProfile -File $debug -ProjectPath $project -CcsRoot $ccs -Build 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $buildMark) -or
        -not @($buildOnly | Where-Object { $_ -match '^RESULT: OK$' }).Count) { throw 'Hardware-free build-only mode failed' }

    $mockRun = @(& pwsh -NoProfile -File $debug -ProjectPath $project -CcsRoot $ccs -Run -NoProbeCheck 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not @($mockRun | Where-Object { $_ -match '^RESULT: OK$' }).Count -or
        -not @($mockRun | Where-Object { $_ -match '^Target running\.\.\.$' }).Count -or
        @($mockRun | Where-Object { $_ -match 'StandardOutputEncoding' }).Count) {
        throw "Batch wrapper with spaces failed: $($mockRun -join '; ')"
    }
    $marker = Join-Path $project 'Debug\.ti_c2000_loaded.json'
    if (-not (Test-Path -LiteralPath $marker)) { throw 'Successful mock load did not record its .out hash' }
    Set-Content -LiteralPath (Join-Path $project 'Debug\mock.out') -Value 'changed symbols' -Encoding ascii
    $mismatch = @(& pwsh -NoProfile -File $debug -ProjectPath $project -CcsRoot $ccs -ReadOnly -ReadVars gBootStage -NoProbeCheck 2>&1)
    if ($LASTEXITCODE -ne 2 -or -not @($mismatch | Where-Object { $_ -match '^FAILURE: SYMBOL_MISMATCH$' }).Count) {
        throw "Changed .out was not rejected before DSS: $($mismatch -join '; ')"
    }
    Write-Output 'PASS: missing probe stops before build; batch paths with spaces run; changed symbols fail closed'
    Write-Output 'RESULT: OK'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = [IO.Path]::GetFullPath($fixture)
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([IO.Path]::GetFileName($resolved) -like 'ti c2000 preflight *')) { throw 'Unsafe fixture cleanup path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
