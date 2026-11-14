#requires -Version 7.0
<#
sync_platform_copies.ps1 -- make every AI platform's copy of this skill identical to
the one in CodeBuddy, which is the single source.

Why this exists: Codex (and any tool that keeps skills in its own directory) reads its
OWN copy, e.g. %USERPROFILE%\.codex\skills\ti-c2000-ccs-auto. That copy does not follow
edits made here. Measured on 2026-11-14: the Codex copy was 70 files / SKILL.md 7479 B
while the source was 79 files / 18840 B, and the stale copy still contained the deleted
stand-alone read entry points (ti_c2000_read_runtime.ps1, ti_c2000_read_array_runtime.ps1)
plus references\read-only-mode.md. A tool running that copy is not "not following the
skill" - it is faithfully following a skill from several days ago, which is worse because
it looks correct.

  ADD     file exists in the source only          -> copied
  UPDATE  same name, different content            -> overwritten
  KEEP    same name, same sha256                  -> untouched
  PRUNE   exists in the target only               -> deleted (use -NoPrune to keep)

Usage:
  pwsh -NoProfile -File tools/sync_platform_copies.ps1 -DryRun     # show the plan
  pwsh -NoProfile -File tools/sync_platform_copies.ps1             # apply
  pwsh -NoProfile -File tools/sync_platform_copies.ps1 -Targets D:\x\.claude\skills\ti-c2000-ccs-auto

Exit code: 0 in sync (after applying) | 1 differences remain / error | 2 bad arguments
#>
[CmdletBinding()]
param(
    # explicit target directories; default = every known platform that already has a copy
    [string[]]$Targets = @(),
    [switch]$DryRun,
    [switch]$NoPrune,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

$source = Split-Path $PSScriptRoot -Parent
$name = Split-Path -Leaf $source
if (-not (Test-Path (Join-Path $source 'SKILL.md'))) {
    Out2 'FAILURE: NOT_A_SKILL'
    Out2 'RESULT: FAIL'
    Out2 ("REASON: no SKILL.md above '{0}'" -f $PSScriptRoot)
    exit 2
}

# where the other tools look, in order. Only directories that already exist are used:
# creating a platform's skill folder for it would be a different, larger decision.
if ($Targets.Count -eq 0) {
    $candidates = @(
        (Join-Path $env:USERPROFILE ".codex\skills\$name"),
        (Join-Path $env:USERPROFILE ".claude\skills\$name"),
        (Join-Path $env:USERPROFILE ".cursor\skills\$name"),
        (Join-Path $env:USERPROFILE ".config\opencode\skills\$name")
    )
    $Targets = @($candidates | Where-Object { Test-Path -LiteralPath $_ })
}
if ($Targets.Count -eq 0) {
    Info2 'TARGET  : none (no other platform keeps a copy of this skill)'
    Out2 'RESULT: OK'
    exit 0
}

# never copy VCS internals or editor scratch into a platform copy
$excludePattern = '(^|\\)(\.git|\.github|node_modules|__pycache__)(\\|$)|\.bak$|\.tmp$'

function Get-FileMap([string]$root) {
    $map = @{}
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\')
        if ($rel -match $excludePattern) { return }
        $map[$rel] = $_.FullName
    }
    return $map
}

$srcMap = Get-FileMap $source
$blocked = 0
foreach ($t in $Targets) {
    $target = [IO.Path]::GetFullPath($t)
    if (-not (Test-Path -LiteralPath $target)) {
        Info2 ('TARGET  : {0}  (missing, skipped)' -f $target)
        continue
    }
    if ($target.TrimEnd('\') -eq $source.TrimEnd('\')) {
        Info2 ('TARGET  : {0}  (this is the source, skipped)' -f $target)
        continue
    }
    $tgtMap = Get-FileMap $target
    $add = 0; $upd = 0; $keep = 0; $prune = @()

    foreach ($rel in ($srcMap.Keys | Sort-Object)) {
        $srcFile = $srcMap[$rel]
        $dstFile = Join-Path $target $rel
        if (-not $tgtMap.ContainsKey($rel)) {
            $add++
            Info2 ('  ADD     ' + $rel)
            if (-not $DryRun) {
                $d = Split-Path -Parent $dstFile
                if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
                Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
            }
        } else {
            $h1 = (Get-FileHash -LiteralPath $srcFile -Algorithm SHA256).Hash
            $h2 = (Get-FileHash -LiteralPath $dstFile -Algorithm SHA256).Hash
            if ($h1 -ne $h2) {
                $upd++
                Info2 ('  UPDATE  ' + $rel)
                if (-not $DryRun) { Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force }
            } else { $keep++ }
        }
    }

    foreach ($rel in ($tgtMap.Keys | Sort-Object)) {
        if ($srcMap.ContainsKey($rel)) { continue }
        if ($NoPrune) { Info2 ('  KEEP-EXTRA ' + $rel + '  (-NoPrune)'); continue }
        $prune += $rel
        Info2 ('  PRUNE   ' + $rel)
        if (-not $DryRun) {
            try { [IO.File]::Delete($tgtMap[$rel]) } catch { Info2 ('  WARN    could not delete ' + $rel) }
        }
    }
    # remove directories that the prune emptied, deepest first
    if (-not $DryRun -and $prune.Count -gt 0) {
        $dirs = @($prune | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique -Descending)
        foreach ($d in $dirs) {
            if (-not $d -or $d -eq '.') { continue }
            $full = Join-Path $target $d
            if ((Test-Path -LiteralPath $full) -and -not (Get-ChildItem -LiteralPath $full -Force)) {
                Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Info2 ('TARGET  : {0}' -f $target)
    Info2 ('          add={0} update={1} keep={2} prune={3}{4}' -f $add, $upd, $keep, $prune.Count, $(if ($DryRun) { '   (dry run, nothing written)' } else { '' }))
    if (-not $DryRun -and ($add + $upd + $prune.Count) -gt 0) { $blocked++ }
}

if ($DryRun) {
    Out2 'RESULT: OK (dry run - re-run without -DryRun to apply)'
    exit 0
}
# prove it: compare again and demand an exact match
$after = 0
foreach ($t in $Targets) {
    if (-not (Test-Path -LiteralPath $t)) { continue }
    $tgtMap = Get-FileMap ([IO.Path]::GetFullPath($t))
    foreach ($rel in $srcMap.Keys) {
        if (-not $tgtMap.ContainsKey($rel)) { $after++; continue }
        if ((Get-FileHash -LiteralPath $srcMap[$rel] -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $tgtMap[$rel] -Algorithm SHA256).Hash) { $after++ }
    }
    if (-not $NoPrune) { $after += @($tgtMap.Keys | Where-Object { -not $srcMap.ContainsKey($_) }).Count }
}
if ($after -gt 0) {
    Out2 ('FAILURE: COPY_OUT_OF_SYNC')
    Out2 'RESULT: FAIL'
    Out2 ('REASON: {0} file(s) still differ after copying' -f $after)
    exit 1
}
Out2 'RESULT: OK'
exit 0
