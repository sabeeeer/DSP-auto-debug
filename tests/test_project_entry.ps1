#requires -Version 7.0
# A self-check that never fails is decoration. This proves check_project_entry.ps1
# actually catches the two ways a project stops following the skill:
#   a copy of a skill script living in the project,
#   and an entry document that is missing or points at a deleted copy.
# File names and contents only: no board, no CCS, no build.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$check = Join-Path $root 'scripts/check_project_entry.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-entry-' + [guid]::NewGuid().ToString('N'))
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

$goodDoc = @'
# entry
Step 0: read %USERPROFILE%\.codebuddy\skills\ti-c2000-ccs-auto\SKILL.md
Never create ti_c2000_*.ps1 copies here.
'@

try {
    New-Item -ItemType Directory -Force -Path $proj | Out-Null

    # ---- 1. bare project: no entry document anywhere -------------------------
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj)
    if ($r.code -ne 1 -or $r.text -notmatch 'no AI entry document') { throw "missing entry documents were not caught`n$($r.text)" }

    # ---- 2. only CODEBUDDY.md: Codex would open it blind ---------------------
    Write-Text (Join-Path $proj 'CODEBUDDY.md') $goodDoc
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj)
    if ($r.code -ne 1 -or $r.text -notmatch 'AGENTS\.md is missing') { throw "a CODEBUDDY-only project passed`n$($r.text)" }

    # ---- 3. a copy of a skill script in the project -------------------------
    Write-Text (Join-Path $proj 'AGENTS.md') $goodDoc
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj)
    if ($r.code -ne 0) { throw "a clean project was rejected`n$($r.text)" }
    Write-Text (Join-Path $proj 'Tools/scripts/ti_c2000_runlog.ps1') '# stale copy'
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj)
    if ($r.code -ne 1 -or $r.text -notmatch 'skill script copy in the project') { throw "a copied skill script was not caught`n$($r.text)" }
    Remove-Item -LiteralPath (Join-Path $proj 'Tools') -Recurse -Force

    # ---- 4. entry document steering at a deleted copy -----------------------
    Write-Text (Join-Path $proj 'AGENTS.md') "# entry`nrun Tools/scripts/verify_on_target.ps1 to verify`n"
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj)
    if ($r.code -ne 1 -or $r.text -notmatch 'deleted copy verify_on_target\.ps1') { throw "a document pointing at a dead script was not caught`n$($r.text)" }

    # ---- 5. ...but a warning about the same copy is the fix, not a fault ----
    Write-Text (Join-Path $proj 'AGENTS.md') $goodDoc
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj)
    if ($r.code -ne 0) { throw "a warning that forbids the copies was treated as a violation`n$($r.text)" }

    # ---- 6. entry document that never mentions the skill --------------------
    Write-Text (Join-Path $proj 'AGENTS.md') "# entry`njust build it however`n"
    $r = Invoke-Script @('-NoProfile', '-File', $check, '-ProjectPath', $proj)
    if ($r.code -ne 1 -or $r.text -notmatch 'does not mention ti-c2000-ccs-auto') { throw "a document that ignores the skill was not caught`n$($r.text)" }

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
