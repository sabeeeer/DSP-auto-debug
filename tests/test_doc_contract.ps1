#requires -Version 7.0
# An AI executes what the documents say. So every name, code, link and parameter in the
# documents is a promise that must hold in the code:
#   * a named .ps1 must exist (history may name a deleted one while saying so)
#   * a promised FAILURE code must be emitted by some script
#   * an internal .md link must resolve
#   * a `pwsh -File <script> -Foo` command must have -Foo in that script's param() block
#   * every script must declare PowerShell 7
# Precision matters more than coverage here: a noisy checker gets ignored, and an ignored
# checker is worse than none. Parameters are read through the PowerShell AST, not regex.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$problems = New-Object System.Collections.Generic.List[string]
$checked = 0

$docs = @(Get-ChildItem $root -Recurse -File -Include *.md | Where-Object { $_.FullName -notmatch '\\\.git\\' })
$ps1 = @(Get-ChildItem $root -Recurse -File -Include *.ps1 | Where-Object { $_.FullName -notmatch '\\\.git\\' })
$realNames = @($ps1 | ForEach-Object { $_.Name })
$allSrc = ($ps1 | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
$removalWords = '删除|已删|移除|已移除|当时|旧入口|旧副本|不再存在|removed|deleted|no longer|legacy'

# ---------- 1. every .ps1 named in a document must exist ------------------------
foreach ($d in $docs) {
    $rel = $d.FullName.Substring($root.Length + 1)
    $i = 0
    foreach ($line in [IO.File]::ReadAllLines($d.FullName)) {
        $i++
        foreach ($m in [regex]::Matches($line, '(?<![A-Za-z0-9_\-])([A-Za-z0-9_\-]+\.ps1)')) {
            $n = $m.Groups[1].Value
            $checked++
            if (@('scripts', 'tools', 'setup', 'tests') | Where-Object { Test-Path (Join-Path $root "$_\$n") }) { continue }
            if (@($realNames | Where-Object { $_ -like "*$n" }).Count -gt 0) { continue }   # shorthand: debug.ps1
            if ($line -match $removalWords) { continue }
            $problems.Add(('{0}:{1} names {2}, which does not exist' -f $rel, $i, $n))
        }
    }
}

# ---------- 2. every promised FAILURE code must be emitted ---------------------
# Only two shapes are promises: "FAILURE: CODE" in prose, and a table row that pairs a
# backticked code with an exit code. Verdict names (SYMBOL_MISMATCH, HEARTBEAT_RATE) and
# quoted historical logs are not part of the failure taxonomy and are not checked.
foreach ($d in $docs) {
    $rel = $d.FullName.Substring($root.Length + 1)
    $inFence = $false
    $i = 0
    foreach ($line in [IO.File]::ReadAllLines($d.FullName)) {
        $i++
        if ($line.Trim() -match '^```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        foreach ($m in [regex]::Matches($line, 'FAILURE:\s*([A-Z][A-Z0-9_]{2,})')) {
            $c = $m.Groups[1].Value
            $checked++
            if ($allSrc -notmatch [regex]::Escape($c)) { $problems.Add(('{0}:{1} promises FAILURE: {2}, but no script emits it' -f $rel, $i, $c)) }
        }
        # a table row that documents a code we have since deleted is history, not a promise
        if ($line -match '^\s*\|' -and $line -match 'exit\s*\d' -and $line -notmatch $removalWords) {
            foreach ($m in [regex]::Matches($line, '`([A-Z][A-Z0-9_]{3,})`')) {
                $c = $m.Groups[1].Value
                if ($c -notmatch '_') { continue }
                $checked++
                if ($allSrc -notmatch [regex]::Escape($c)) { $problems.Add(('{0}:{1} promises code {2} with an exit code, but no script emits it' -f $rel, $i, $c)) }
            }
        }
    }
}

# ---------- 3. every internal .md link must resolve ---------------------------
foreach ($d in $docs) {
    $rel = $d.FullName.Substring($root.Length + 1)
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($d.FullName), '\]\(([^)#]+\.md)')) {
        $link = $m.Groups[1].Value
        if ($link -match '^https?:') { continue }
        $checked++
        $target = Join-Path (Split-Path $d.FullName -Parent) $link
        try { $target = [IO.Path]::GetFullPath($target) } catch { }
        if (-not (Test-Path -LiteralPath $target)) { $problems.Add(('{0} links to {1}, which does not exist' -f $rel, $link)) }
    }
}

# ---------- 4. SKILL.md must name every entry point an AI is expected to use --
$skillMd = [IO.File]::ReadAllText((Join-Path $root 'SKILL.md'))
foreach ($n in @('ti_c2000_service.ps1', 'ti_c2000_run_read.ps1', 'ti_c2000_read_dma.ps1',
    'ti_c2000_iterate.ps1', 'ti_c2000_readmode.ps1', 'ti_c2000_loadcount.ps1',
    'ti_c2000_check_read.ps1', 'ti_c2000_debug.ps1', 'ti_c2000_build.ps1',
    'check_project_entry.ps1', 'sync_platform_copies.ps1')) {
    $checked++
    if ($skillMd -notmatch [regex]::Escape($n)) { $problems.Add(("SKILL.md never mentions $n - an AI reading it would not know that entry point")) }
}

# ---------- 5. every parameter of a documented command must exist -------------
# Only real invocations count: "pwsh ... -File <script> -Foo". Shell helpers like
# `loadti.bat -r -a` and template lines with <, >, ... or $ are skipped.
$paramCache = @{}
function Get-ParamNames([string]$path) {
    if ($paramCache.ContainsKey($path)) { return $paramCache[$path] }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $names = @()
    if ($ast.ParamBlock) {
        foreach ($p in $ast.ParamBlock.Parameters) { $names += ('-' + $p.Name.VariablePath.UserPath) }
    }
    $paramCache[$path] = @($names | Sort-Object -Unique)
    return $paramCache[$path]
}
foreach ($d in $docs) {
    $rel = $d.FullName.Substring($root.Length + 1)
    foreach ($line in [IO.File]::ReadAllLines($d.FullName)) {
        if ($line -notmatch 'pwsh') { continue }
        if ($line -match 'loadti|\.bat\b') { continue }
        if ($line -match '[<>]|\.\.\.|\$env:|\$skill|\$proj|\$HOME') { continue }
        $fm = [regex]::Match($line, '-File\s+"?([A-Za-z0-9_\-]+\.ps1)"?')
        if (-not $fm.Success) { continue }
        $scriptName = $fm.Groups[1].Value
        $target = @('scripts', 'tools', 'setup', 'tests') | ForEach-Object { Join-Path $root "$_\$scriptName" } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $target) { continue }
        $known = Get-ParamNames $target
        $tail = $line.Substring($fm.Index + $fm.Length)
        foreach ($pm in [regex]::Matches($tail, '(?<![\w-])(-[A-Za-z][A-Za-z0-9_]*)')) {
            $p = $pm.Groups[1].Value
            $checked++
            if ($known -notcontains $p) { $problems.Add(('{0} runs "{1} {2}", but that script has no such parameter' -f $rel, $scriptName, $p)) }
        }
    }
}

# ---------- 6. every script stays on PowerShell 7 ----------------------------
foreach ($f in $ps1) {
    $checked++
    if (([IO.File]::ReadAllText($f.FullName)) -notmatch '^#requires -Version 7\.0') {
        $problems.Add(('{0} does not start with "#requires -Version 7.0"' -f ($f.FullName.Substring($root.Length + 1))))
    }
}

if ($problems.Count -gt 0) {
    'FAILURE: DOC_CONTRACT_BROKEN'
    foreach ($p in $problems | Select-Object -First 40) { 'VIOLATION: ' + $p }
    'REASON: {0} problem(s) in {1} checked promises' -f $problems.Count, $checked
    'RESULT: FAIL'
    exit 1
}
'CHECK   : {0} document promises verified against the code' -f $checked
'RESULT: OK'
exit 0
