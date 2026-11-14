#requires -Version 7.0
# "The run went through the skill" has to be checkable, not assumed. Two mechanisms:
#   Initialize-SkillRun  stamps readout\skill-runs.jsonl and refuses (or warns) when the
#                        project still holds a copy of a skill script
#   check_project_entry -MaxRunAgeMinutes  later proves the newest run is recent and
#                        came from this skill directory
# This test exercises both with file fixtures: no board, no CCS, no build.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$lib = Join-Path $root 'scripts/ti_c2000_readmode.ps1'
$check = Join-Path $root 'scripts/check_project_entry.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-ident-' + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $fixture 'Fw'

function Invoke-Script([string[]]$a) {
    $out = @(& pwsh @a 2>&1)
    return [ordered]@{ code = $LASTEXITCODE; text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
}
function Write-Text([string]$path, [string]$text) {
    $d = Split-Path -Parent $path
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

# entry documents that satisfy check_project_entry.ps1
$doc = "# entry`nStep 0: read %USERPROFILE%\.codebuddy\skills\ti-c2000-ccs-auto\SKILL.md`nNever keep ti_c2000_*.ps1 copies.`n"

try {
    New-Item -ItemType Directory -Force -Path $proj | Out-Null
    Write-Text (Join-Path $proj 'AGENTS.md') $doc
    Write-Text (Join-Path $proj 'CODEBUDDY.md') $doc
    Write-Text (Join-Path $proj 'CLAUDE.md') $doc

    # ---- 1. a copy in the project blocks the download path -------------------
    Write-Text (Join-Path $proj 'Tools/scripts/ti_c2000_runlog.ps1') '# stale copy'
    $g = Join-Path $fixture 'block.ps1'
    Write-Text $g ". '$lib'`nInitialize-SkillRun -ProjectPath '$proj' -Script 'x' -Mode 'Start' -Block`n'CONTINUED (WRONG)'`n"
    $r = Invoke-Script @('-NoProfile', '-File', $g)
    if ($r.code -ne 2) { throw "a copied skill script did not block a -Start (exit $($r.code))`n$($r.text)" }
    if ($r.text -notmatch 'FAILURE: PROJECT_NOT_CLEAN') { throw "wrong failure for a dirty project`n$($r.text)" }
    if ($r.text -match 'CONTINUED') { throw "the run continued past a dirty project`n$($r.text)" }
    if (Test-Path (Join-Path $proj 'readout/skill-runs.jsonl')) { throw 'a refused run still stamped the run log' }

    # ---- 2. a read only warns, and still stamps the run ----------------------
    $g = Join-Path $fixture 'warn.ps1'
    Write-Text $g ". '$lib'`nInitialize-SkillRun -ProjectPath '$proj' -Script 'y' -Mode 'ReadOnly'`n'reached-read'`n"
    $r = Invoke-Script @('-NoProfile', '-File', $g)
    if ($r.code -ne 0) { throw "a read was blocked by a copy (exit $($r.code))`n$($r.text)" }
    if ($r.text -notmatch 'WARN\s+: 1 copy') { throw "the read did not warn about the copy`n$($r.text)" }
    if ($r.text -notmatch 'SKILL\s+: ti-c2000-ccs-auto@') { throw "no skill identity line`n$($r.text)" }
    if ($r.text -notmatch 'reached-read') { throw 'the read did not continue' }

    $log = Join-Path $proj 'readout/skill-runs.jsonl'
    if (-not (Test-Path $log)) { throw 'the run was not stamped' }
    $rec = Get-Content -LiteralPath $log -Encoding utf8 | Select-Object -Last 1 | ConvertFrom-Json
    if ($rec.script -ne 'y' -or $rec.mode -ne 'ReadOnly') { throw "the record lost its script/mode: $($rec | ConvertTo-Json -Compress)" }
    if (-not $rec.version -or $rec.version -eq 'unknown') { throw 'the record has no skill version' }
    if ((Split-Path -Leaf ([string]$rec.skill)) -ne 'ti-c2000-ccs-auto') { throw "the record names another skill: $($rec.skill)" }

    # ---- 3. the run log proves (or disproves) recent skill use --------------
    Remove-Item -LiteralPath (Join-Path $proj 'Tools') -Recurse -Force
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj, '-MaxRunAgeMinutes', '30')
    if ($r.code -ne 0) { throw "a fresh skill run did not satisfy -MaxRunAgeMinutes`n$($r.text)" }
    if ($r.text -notmatch 'last skill run') { throw "the checker forgot to report the run`n$($r.text)" }

    # age the record by two hours: the same project must now be refused
    $old = [ordered]@{ at = (Get-Date).AddHours(-2).ToString('yyyy-MM-dd HH:mm:ss'); pid = 1; script = 'y'; mode = 'ReadOnly'; skill = $rec.skill; version = $rec.version }
    [IO.File]::WriteAllText($log, (($old | ConvertTo-Json -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj, '-MaxRunAgeMinutes', '30')
    if ($r.code -ne 1 -or $r.text -notmatch 'min old') { throw "a stale run was accepted`n$($r.text)" }

    # a run recorded by a different skill directory is not proof either
    $other = [ordered]@{ at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); pid = 1; script = 'y'; mode = 'ReadOnly'; skill = (Join-Path $fixture 'copy-of-skill'); version = $rec.version }
    [IO.File]::WriteAllText($log, (($other | ConvertTo-Json -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj, '-MaxRunAgeMinutes', '30')
    if ($r.code -ne 1 -or $r.text -notmatch 'another skill copy') { throw "a run from another skill copy was accepted`n$($r.text)" }

    'RESULT: OK'
    exit 0
} catch {
    'FAILURE: TEST_FAILED'
    'REASON: ' + $_.Exception.Message
    'RESULT: FAIL'
    exit 1
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
