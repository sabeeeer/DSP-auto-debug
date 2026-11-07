#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SdkRoot,
    [Parameter(Mandatory = $true)][string]$DeviceFamily,
    [string]$Peripheral = '',
    [ValidateSet('both', 'bitfield', 'driverlib')][string]$Style = 'both',
    [switch]$Summary
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $SdkRoot -ErrorAction Stop).Path.TrimEnd('\', '/')
$family = $DeviceFamily.ToLowerInvariant()
if ($family -notmatch '^f[0-9a-z]+$') { throw "Invalid device family: $DeviceFamily" }

$sources = @()
if ($Style -in @('both', 'bitfield')) {
    $sources += [pscustomobject]@{ Style = 'bitfield'; Path = (Join-Path $root "device_support/$family/examples") }
}
if ($Style -in @('both', 'driverlib')) {
    $sources += [pscustomobject]@{ Style = 'driverlib'; Path = (Join-Path $root "driverlib/$family/examples") }
}

$foundRoot = $false
$items = [System.Collections.Generic.List[object]]::new()
$sourceExtensions = @('.c', '.cpp', '.cla', '.asm')
foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source.Path -PathType Container)) { continue }
    $foundRoot = $true
    foreach ($file in (Get-ChildItem -LiteralPath $source.Path -Recurse -File | Where-Object { $_.Extension.ToLowerInvariant() -in $sourceExtensions })) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        if ($Peripheral -and $relative.IndexOf($Peripheral, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $belowExamples = $file.FullName.Substring($source.Path.Length).TrimStart('\', '/') -split '[\\/]'
        $group = $belowExamples[0]
        if ($group -in @('cpu1', 'cpu2', 'dual', 'cm', 'c28x') -and $belowExamples.Count -gt 1) {
            $group += '/' + $belowExamples[1]
        }
        $items.Add([pscustomobject]@{
            Style = $source.Style
            DeviceFamily = $family
            ExampleGroup = $group
            RelativePath = $relative
        })
    }
}

if (-not $foundRoot) { throw "No example tree for $family and style $Style under $root" }
if ($items.Count -eq 0) { throw "No source example matched '$Peripheral' for $family under $root" }

$ordered = @($items | Sort-Object Style, RelativePath)
if ($Summary) {
    $ordered | Group-Object Style, ExampleGroup | ForEach-Object {
        [pscustomobject]@{
            Style = $_.Group[0].Style
            DeviceFamily = $family
            ExampleGroup = $_.Group[0].ExampleGroup
            SourceFiles = $_.Count
        }
    }
}
else {
    $ordered
}
