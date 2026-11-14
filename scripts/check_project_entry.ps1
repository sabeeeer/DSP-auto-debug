#requires -Version 7.0
<#
check_project_entry.ps1 -- "does this project follow the skill, or does it follow a
stale copy of it?"

Two failures this catches, both invisible until someone runs the wrong script:
  1. a copy of a skill script inside the project  -> the copy wins at run time, so the
     interlocks, the four ReadOnly proofs and the load counter are all bypassed
  2. no AI entry document in the directory the tool opens, or one that still points at
     a deleted copy -> a new session has nothing telling it that the skill exists

It never touches the target and never runs a build: file names and file contents only.

Usage:
  pwsh -NoProfile -File check_project_entry.ps1 -ProjectPath <CCS project folder>

Exit code: 0 clean | 1 violations found | 2 bad arguments
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    # how many levels above the CCS project folder to look for the entry documents
    [int]$EntrySearchDepth = 3,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    Out2 'FAILURE: NO_PROJECT'
    Out2 'RESULT: FAIL'
    Out2 ("REASON: '{0}' does not exist" -f $ProjectPath)
    exit 2
}
$root = (Get-Item -LiteralPath $ProjectPath).FullName

# files that only ever exist because someone copied skill logic into a project
$copyNamePattern = '^ti_c2000_.*\.(ps1|js)$'
$copyExact = @('verify_on_target.ps1', 'dss_load_run_read.js', 'run_hold.js')
# a document naming one of these is steering the next session at a dead endpoint
$deadNames = @('verify_on_target.ps1', 'dss_load_run_read.js', 'ti_c2000_runlog.ps1', 'run_hold.js')
# every entry document must name this, otherwise it is not about this skill
$skillToken = 'ti-c2000-ccs-auto'

$violations = New-Object System.Collections.Generic.List[string]
$notes = New-Object System.Collections.Generic.List[string]

# ---------- 1. copies of skill scripts inside the project ------------------------
$copies = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1, *.js -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    Where-Object { $_.Name -match $copyNamePattern -or $copyExact -contains $_.Name })
if ($copies.Count -gt 0) {
    foreach ($c in $copies) {
        $rel = $c.FullName.Substring($root.Length).TrimStart('\')
        $violations.Add(('skill script copy in the project: {0}' -f $rel))
    }
} else {
    $notes.Add('no skill script copies inside the project')
}

# ---------- 2. an entry document the opening tool will actually read ------------
# Walk every level instead of stopping at the first one that has any entry file: the CCS
# project folder usually holds its own CODEBUDDY.md, while the folder an AI tool opens
# (and therefore reads AGENTS.md from) is one level above. Stopping early is exactly how
# "the document exists but nobody reads it" happens.
$entryNames = @('AGENTS.md', 'CODEBUDDY.md', 'CLAUDE.md')
$dir = $root
$found = @()
for ($i = 0; $i -le $EntrySearchDepth -and $dir; $i++) {
    $hit = @($entryNames | ForEach-Object { Join-Path $dir $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if ($hit.Count -gt 0) { $found += [pscustomobject]@{ dir = $dir; files = $hit } }
    $parent = Split-Path -Parent $dir
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
}

if ($found.Count -eq 0) {
    $violations.Add(('no AI entry document (AGENTS.md / CODEBUDDY.md / CLAUDE.md) in {0} or up to {1} levels above' -f $root, $EntrySearchDepth))
} else {
    foreach ($layer in $found) { $notes.Add(('entry documents in {0}' -f $layer.dir)) }
    $hasAgents = $false
    foreach ($layer in $found) {
        foreach ($f in $layer.files) {
            $name = Split-Path -Leaf $f
            if ($name -eq 'AGENTS.md') { $hasAgents = $true }
            $label = Join-Path $layer.dir $name
            $text = ''
            try { $text = [IO.File]::ReadAllText($f) } catch {
                $violations.Add(('unreadable entry document: {0}' -f $label))
                continue
            }
            if ($text -notmatch [regex]::Escape($skillToken)) {
                $violations.Add(('{0} does not mention {1}, so it does not point at the skill' -f $label, $skillToken))
            }
            # line by line: naming a deleted copy is only wrong when the line is telling
            # someone to run it. "do not use X" / "X was deleted" is the fix, not the fault.
            $lineno = 0
            foreach ($line in ($text -split "`r?`n")) {
                $lineno++
                $named = @($deadNames | Where-Object { $line -match [regex]::Escape($_) })
                if ($named.Count -eq 0) { continue }
                if ($line -match '删除|删掉|已删|不要|禁止|不许|改用|换成|deleted|removed|do not|don''t|never|instead of') { continue }
                $violations.Add(('{0}:{1} still names the deleted copy {2} as something to run - rewrite that line to call the skill' -f $label, $lineno, ($named -join ', ')))
            }
        }
    }
    # Codex and other tools read AGENTS.md; CodeBuddy reads CODEBUDDY.md. A project that
    # only ships the CodeBuddy file silently loses every non-CodeBuddy tool.
    if (-not $hasAgents) {
        $violations.Add('AGENTS.md is missing in every level searched - Codex / generic tools would open this project with no entry document at all')
    }
}

# ---------- report ---------------------------------------------------------------
Info2 ('PROJECT : ' + $root)
Info2 ('SKILL   : ' + $script:skillToken)
foreach ($n in $notes) { Info2 ('CHECK   : ' + $n) }
if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Out2 ('VIOLATION: ' + $v) }
    Out2 'RESULT: FAIL'
    Out2 ('REASON: {0} violation(s) - the project would not run through the skill' -f $violations.Count)
    Out2 'HINT    : delete the copies; keep AGENTS.md + CODEBUDDY.md + CLAUDE.md identical and pointing at the skill'
    exit 1
}
Out2 ('CHECK   : {0} entry document(s), 0 copies' -f $found.files.Count)
Out2 'RESULT: OK'
exit 0
