#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $skillRoot 'scripts/ti_c2000_set_probe.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('c2000-probe-serial-' + [guid]::NewGuid().ToString('N'))
$targetDir = Join-Path $tempRoot 'targetConfigs'
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
$ccxml = Join-Path $targetDir 'TMS320F28335.ccxml'
@'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<configurations XML_version="1.2" id="configurations_0">
  <configuration XML_version="1.2" id="configuration_0">
    <instance XML_version="1.2" desc="Texas Instruments XDS100v2 USB Debug Probe" href="connections/TIXDS100v2_Connection.xml" id="Texas Instruments XDS100v2 USB Emulator" xml="TIXDS100v2_Connection.xml" xmlpath="connections"/>
    <connection XML_version="1.2" id="Texas Instruments XDS100v2 USB Emulator">
      <instance XML_version="1.2" href="drivers/tixds100v2c28x.xml" id="drivers" xml="tixds100v2c28x.xml" xmlpath="drivers"/>
      <property Type="choicelist" Value="1" id="Emulator Selection">
        <choice Name="Select by serial number" value="0">
          <property Type="stringfield" Value="OLD" id="-- Enter the serial number"/>
        </choice>
      </property>
      <platform XML_version="1.2" id="platform_0">
        <instance XML_version="1.2" desc="TMS320F28335_0" href="devices/f28335.xml" id="TMS320F28335_0" xml="f28335.xml" xmlpath="devices"/>
      </platform>
    </connection>
  </configuration>
</configurations>
'@ | Set-Content -LiteralPath $ccxml -Encoding utf8

try {
    $before = [IO.File]::ReadAllText($ccxml)
    $failOut = & pwsh -NoProfile -File $scriptPath -ProjectPath $tempRoot -Probe v1 2>&1 | Out-String
    if ($LASTEXITCODE -ne 1 -or $failOut -notmatch 'SERIAL_REQUIRED' -or [IO.File]::ReadAllText($ccxml) -ne $before) { throw 'missing -Serial should fail without mutation' }

    $dryOut = & pwsh -NoProfile -File $scriptPath -ProjectPath $tempRoot -Probe v1 -Serial TI1P9CM8 -DryRun 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $dryOut -notmatch 'RESULT: OK' -or [IO.File]::ReadAllText($ccxml) -ne $before) { throw 'DryRun should preserve fixture' }

    $out = & pwsh -NoProfile -File $scriptPath -ProjectPath $tempRoot -Probe v1 -Serial TI1P9CM8 2>&1 | Out-String
    $after = [IO.File]::ReadAllText($ccxml)
    [xml]$parsed = $after
    if ($LASTEXITCODE -ne 0 -or $out -notmatch 'RESULT: OK' -or $after -notmatch 'Value="TI1P9CM8"' -or $after -notmatch 'TIXDS100usb_Connection.xml') { throw 'switch must preserve selected serial' }
    if ($parsed.configurations.configuration.connection.property.choice.property.Value -ne 'TI1P9CM8') { throw 'serial selection XML was not retained' }

    $out2 = & pwsh -NoProfile -File $scriptPath -ProjectPath $tempRoot -Probe v1 -Serial NEW123 2>&1 | Out-String
    $after2 = [IO.File]::ReadAllText($ccxml)
    if ($LASTEXITCODE -ne 0 -or $out2 -notmatch 'RESULT: OK' -or $after2 -notmatch 'Value="NEW123"') { throw 'same probe should allow explicit serial update' }

    Write-Output 'PASS: probe switch requires, keeps and updates serial without touching real projects'
    Write-Output 'RESULT: OK'
    exit 0
}
catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output 'RESULT: FAIL'
    exit 1
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
