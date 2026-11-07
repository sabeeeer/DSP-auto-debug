#requires -Version 7.0
<#
Read values from an already running C2000 target without building, downloading,
resetting or issuing a halt. The versioned DSS template configures CCS realtime
access before connecting; the existing .out supplies symbols only.

Example:
  pwsh -NoProfile -File scripts/ti_c2000_read_runtime.ps1 `
    -ProjectPath <project> -Variables 'gBootStage,EPwm1Regs.TBPRD'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][Alias('ReadVars')][string[]]$Variables,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    [string]$CorePattern = '.*',
    [string]$WaitFor = '',
    [int]$RunMs = 0,
    [switch]$NoProbeCheck,
    [switch]$Quiet
)

$names = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names.Count -eq 0) {
    Write-Output 'FAILURE: READONLY_NEEDS_READVARS'
    Write-Output 'RESULT: FAIL'
    Write-Output 'REASON: -Variables requires at least one variable or register expression'
    exit 2
}

$debugScript = Join-Path $PSScriptRoot 'ti_c2000_debug.ps1'
if (-not (Test-Path -LiteralPath $debugScript -PathType Leaf)) {
    Write-Output 'FAILURE: ENV_NO_DEBUG_SCRIPT'
    Write-Output 'RESULT: FAIL'
    Write-Output 'REASON: ti_c2000_debug.ps1 is missing from this skill installation'
    exit 2
}

$forward = @{
    ProjectPath = $ProjectPath
    ReadOnly = $true
    ReadVars = ($names -join ',')
    CorePattern = $CorePattern
}
if ($Ccxml) { $forward.Ccxml = $Ccxml }
if ($OutFile) { $forward.OutFile = $OutFile }
if ($CcsRoot) { $forward.CcsRoot = $CcsRoot }
if ($WaitFor) { $forward.WaitFor = $WaitFor }
if ($RunMs -gt 0) { $forward.RunMs = $RunMs }
if ($NoProbeCheck) { $forward.NoProbeCheck = $true }
if ($Quiet) { $forward.Quiet = $true }

& $debugScript @forward
exit $LASTEXITCODE
