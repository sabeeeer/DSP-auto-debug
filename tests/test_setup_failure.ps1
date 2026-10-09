#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('dsp-setup-test-' + (Get-Date -Format 'MMdd-HHmmss'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$blocker = Join-Path $root 'blocked-skills'
Set-Content -LiteralPath $blocker -Value 'not a directory' -Encoding ascii

try {
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\setup\Setup-CCS-Skills.ps1') -Target custom -SkillsRoot $blocker -NoHooks 2>&1 | Out-String
    if ($LASTEXITCODE -ne 1) {
        Write-Host ("FAIL: expected exit 1, got " + $LASTEXITCODE) -ForegroundColor Red
        exit 1
    }
    if ($out -notmatch 'RESULT: FAIL' -or $out -notmatch '\[FAILED\]') {
        Write-Host 'FAIL: failure output was not explicit' -ForegroundColor Red
        Write-Host $out
        exit 1
    }
    Write-Host 'PASS: setup reports failure and exits non-zero' -ForegroundColor Green
    Write-Host 'RESULT: OK' -ForegroundColor Green
    exit 0
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
