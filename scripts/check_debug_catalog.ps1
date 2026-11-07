#requires -Version 7.0
param(
    [string]$SkillRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $SkillRoot).Path
$indexPath = Join-Path $root 'references/debugging-experience.md'
$casesPath = Join-Path $root 'references/debug-cases'
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw "Missing index: $indexPath" }
if (-not (Test-Path -LiteralPath $casesPath -PathType Container)) { throw "Missing case directory: $casesPath" }

$index = Get-Content -LiteralPath $indexPath -Raw -Encoding utf8
$section = [regex]::Match($index, '(?s)## 新案例索引\s*(.*?)\s*## 每次调试结束时的归档判定')
if (-not $section.Success) { throw 'Missing new-case index section' }
$rows = @($section.Groups[1].Value -split "`r?`n" | Where-Object { $_ -match '^\|' })
$links = @($rows | ForEach-Object { [regex]::Matches($_, '\]\((debug-cases/(?!CASE-TEMPLATE\.md)[^\)#]+\.md)(?:#[^\)]*)?\)') | ForEach-Object { $_.Groups[1].Value } })
$errors = [System.Collections.Generic.List[string]]::new()
$caseFiles = @(Get-ChildItem -LiteralPath $casesPath -Recurse -File -Filter '*.md' | Where-Object { $_.Name -ne 'CASE-TEMPLATE.md' })

foreach ($file in $caseFiles) {
    $relative = 'debug-cases/' + $file.FullName.Substring($casesPath.Length).TrimStart('\', '/').Replace('\', '/')
    $count = @($links | Where-Object { $_ -ieq $relative }).Count
    if ($count -ne 1) { $errors.Add("Case must appear exactly once in index ($count): $relative") }
    if ($count -eq 1) {
        $row = @($rows | Where-Object { $_ -like "*]($relative)*" })[0]
        $columns = @($row -split '\|')
        $indexStatus = $columns[4].Trim()
        $caseText = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
        $caseStatus = [regex]::Match($caseText, '(?m)^- 状态：\*\*([^*]+)\*\*')
        if (-not $caseStatus.Success) {
            $errors.Add("Case missing bold status: $relative")
        }
        elseif ($caseStatus.Groups[1].Value.Trim() -cne $indexStatus) {
            $errors.Add("Index/case status mismatch: $relative ($indexStatus vs $($caseStatus.Groups[1].Value))")
        }
    }
}
foreach ($link in $links) {
    $target = Join-Path (Join-Path $root 'references') $link.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $errors.Add("Broken case link: $link") }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 1
}
Write-Output "DEBUG_CATALOG_OK: $($caseFiles.Count) case files, $($links.Count) indexed links"
