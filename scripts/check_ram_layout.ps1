#requires -Version 7.0
<#
.SYNOPSIS
    解析 C2000 工程的链接脚本（.cmd）：报告 RAM 布局 / .text 分配 / 是否跨片 / PAGE 冲突。

.DESCRIPTION
    专治链接报错：
        error #10099-D: program will not fit into available memory, or the section
        contains a call site that requires a trampoline that can't be generated
    用来先分清两种原因：① 段真的太小 ② section 被放在多个不连续内存块（跨片）。
    **只读脚本**：不改任何文件、不写任何东西。

    判读规则与处置办法见 references/ram-and-linker.md。

.PARAMETER ProjectPath
    工程根目录（含 .cproject 的那一层）。

.PARAMETER LinkCmd
    指定链接脚本文件名（默认从 .cproject 的 LINKER_COMMAND_FILE 反推，找不到就搜 *RAM_lnk.cmd → *.cmd）。

.EXAMPLE
    pwsh -File scripts\check_ram_layout.ps1 -ProjectPath "E:\proj\4-1Two_Level_CloseLoop"

.EXAMPLE
    # 指定链接脚本
    pwsh -File scripts\check_ram_layout.ps1 -ProjectPath "E:\proj\X" -LinkCmd "F28335.cmd"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [string]$LinkCmd = ''
)

$ErrorActionPreference = 'Stop'

function Say   ($m) { Write-Host $m }
function Head  ($m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Good  ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn  ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Bad   ($m) { Write-Host "  [BAD]  $m" -ForegroundColor Red }
function Info  ($m) { Write-Host "  [info] $m" -ForegroundColor Gray }

# 读文件并判断编码：UTF-8 严格解码成功 = UTF-8/ASCII；否则按 GBK(936)（TI 例程 .cmd 常见）
function Read-Smart([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $strict = New-Object Text.UTF8Encoding($false, $true)
    $isUtf8 = $true
    try { $null = $strict.GetString($bytes) } catch { $isUtf8 = $false }
    if ($isUtf8) {
        return @{ Text = [Text.Encoding]::UTF8.GetString($bytes); Enc = 'UTF-8/ASCII' }
    }
    return @{ Text = [Text.Encoding]::GetEncoding(936).GetString($bytes); Enc = 'GBK(936)' }
}

# ---------------------------------------------------------------------------
Head "1) 定位工程的链接脚本"

if (-not (Test-Path $ProjectPath)) {
    Bad "工程目录不存在：$ProjectPath"
    exit 2
}
$proj = (Resolve-Path $ProjectPath).Path
Say "  工程：$proj"

$cmdFile = $null

if ($LinkCmd) {
    $hit = Get-ChildItem -Path $proj -Recurse -Filter ([IO.Path]::GetFileName($LinkCmd)) -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notmatch '\\Debug\\' } | Select-Object -First 1
    if ($hit) { $cmdFile = $hit.FullName }
}
else {
    $cproj = Join-Path $proj '.cproject'
    if (Test-Path $cproj) {
        $cprojTxt = Get-Content -Raw -Encoding UTF8 $cproj
        # .cproject 里 .cmd 的写法不统一：可能在 linkerID.LIBRARY.CHOICE 的 value 里，
        # 也可能出现在 CMD_SRCS / GEN_CMDS 等 inputType 的 listOptionValue 里。
        # 稳妥做法：把 .cproject 里所有 "xxx.cmd" 字样都当候选，逐个在磁盘上找。
        $cands = @()
        foreach ($mm in [regex]::Matches($cprojTxt, '([A-Za-z0-9_\-\.]+\.cmd)')) {
            $nm = $mm.Groups[1].Value
            if ($nm -and ($cands -notcontains $nm)) { $cands += $nm }
        }
        if ($cands.Count -eq 0) { Info ".cproject 里没提到任何 .cmd" }
        foreach ($nm in $cands) {
            $hit = Get-ChildItem -Path $proj -Recurse -Filter $nm -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -notmatch '\\Debug\\' } | Select-Object -First 1
            if ($hit -and -not $cmdFile) {
                $cmdFile = $hit.FullName
                Info ".cproject 引用到 .cmd：$nm"
            }
        }
    }
    if (-not $cmdFile) {
        $hit = Get-ChildItem -Path $proj -Recurse -Filter '*RAM_lnk.cmd' -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\Debug\\' } | Select-Object -First 1
        if ($hit) { $cmdFile = $hit.FullName; Info "退回搜索 *RAM_lnk.cmd" }
    }
    if (-not $cmdFile) {
        $all = @(Get-ChildItem -Path $proj -Recurse -Filter '*.cmd' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\Debug\\' })
        if ($all.Count -eq 1) { $cmdFile = $all[0].FullName }
        elseif ($all.Count -gt 1) {
            Warn "找到多个 .cmd，请用 -LinkCmd 指定："
            $all | ForEach-Object { Say ("         " + $_.FullName.Replace($proj + '\','')) }
            exit 3
        }
    }
}

if (-not $cmdFile) {
    Bad "没找到链接脚本（.cmd）。请用 -LinkCmd 明确指定。"
    exit 2
}
Good ("链接脚本：" + $cmdFile.Replace($proj + '\',''))
if ($cmdFile -match 'RAM_lnk') { Info "这是 **RAM 链接**：掉电即失，仅供调试；脱机运行要换 Flash 版 cmd" }

$r  = Read-Smart $cmdFile
$tx = $r.Text
Say ("  编码判断：" + $r.Enc)
if ($r.Enc -like 'GBK*') { Info "GBK 文件：用 PowerShell 改它时必须按 936 读写，否则中文注释会变成乱码（不可逆）" }

# ---------------------------------------------------------------------------
Head "2) MEMORY（各内存块）"

$mem = New-Object System.Collections.ArrayList
$page = 0; $inMem = $false
foreach ($line in ($tx -split "`r?`n")) {
    if ($line -match '^\s*MEMORY\s*$') { $inMem = $true; continue }
    if ($inMem -and $line -match '^\s*\}') { $inMem = $false; continue }
    if (-not $inMem) { continue }
    if ($line -match '^\s*PAGE\s+(\d)\s*:') { $page = [int]$Matches[1]; continue }
    $m = [regex]::Match($line, '^\s*([A-Za-z_]\w*)\s*:\s*origin\s*=\s*(0x[0-9A-Fa-f]+)\s*,\s*length\s*=\s*(0x[0-9A-Fa-f]+)')
    if ($m.Success) {
        [void]$mem.Add([pscustomobject]@{
            Name   = $m.Groups[1].Value
            Page   = $page
            Origin = [Convert]::ToInt64($m.Groups[2].Value, 16)
            Len    = [Convert]::ToInt64($m.Groups[3].Value, 16)
        })
    }
}

if ($mem.Count -eq 0) { Bad "没解析出任何 MEMORY 段（格式可能不标准，请人工看 $cmdFile）"; exit 4 }

foreach ($p in ($mem | Group-Object Page | Sort-Object Name)) {
    Say ("  PAGE " + $p.Name + " :")
    foreach ($s in ($p.Group | Sort-Object Origin)) {
        $end = $s.Origin + $s.Len - 1
        Say ("     {0,-12} 0x{1:X6} ~ 0x{2:X6}   {3,6} 字 ({4,6:N1} KB)" -f `
             $s.Name, $s.Origin, $end, $s.Len, ($s.Len * 2 / 1024))
    }
}

# PAGE 冲突：两个 PAGE 里的块地址范围重叠（同一物理内存被定义两次）
Head "3) PAGE 冲突检查（同一物理内存不能同时属于 PAGE 0 和 PAGE 1）"
$conflicts = 0
$memArr = $mem.ToArray()
for ($i = 0; $i -lt $memArr.Count; $i++) {
    for ($j = $i + 1; $j -lt $memArr.Count; $j++) {
        $a = $memArr[$i]; $b = $memArr[$j]
        if ($a.Page -eq $b.Page) { continue }
        $aEnd = $a.Origin + $a.Len; $bEnd = $b.Origin + $b.Len
        if ($a.Origin -lt $bEnd -and $b.Origin -lt $aEnd) {
            Bad ("PAGE {0} 的 {1} 与 PAGE {2} 的 {3} 地址重叠：0x{4:X}~0x{5:X} vs 0x{6:X}~0x{7:X}" -f `
                 $a.Page, $a.Name, $b.Page, $b.Name, $a.Origin, ($aEnd-1), $b.Origin, ($bEnd-1))
            $conflicts++
        }
    }
}
if ($conflicts -eq 0) { Good "无冲突" } else { Warn "重叠会让程序与数据互相踩（运行时玄学），必须改掉其中一个" }

# ---------------------------------------------------------------------------
Head "4) SECTIONS（关键段分到哪里）"

$secs = New-Object System.Collections.ArrayList
$inSec = $false
foreach ($line in ($tx -split "`r?`n")) {
    if ($line -match '^\s*SECTIONS\s*$') { $inSec = $true; continue }
    if ($inSec -and $line -match '^\s*\}') { break }
    if (-not $inSec) { continue }
    if ($line -match '^\s*/\*' -or $line -match '^\s*\*') { continue }
    $m = [regex]::Match($line, '^\s*([\.\w]+)\s*:\s*>\s*([^,]+?)\s*,\s*PAGE\s*=\s*(\d)')
    if ($m.Success) {
        [void]$secs.Add([pscustomobject]@{
            Section = $m.Groups[1].Value
            Targets = ($m.Groups[2].Value.Trim())
            Page    = [int]$m.Groups[3].Value
        })
    }
}

foreach ($s in $secs) {
    $flag = ''
    if ($s.Targets -match '\|') { $flag = '   <== 跨片!' }
    Say ("  {0,-14} : > {1,-28} PAGE = {2}{3}" -f $s.Section, $s.Targets, $s.Page, $flag)
}

# ---------------------------------------------------------------------------
Head "5) 结论与建议"

# 5.1 跨片检查（对代码类段）
$codeSecs = @('.text', 'ramfuncs', '.cinit', '.pinit', '.switch', 'IQmath')
$crossed  = @()
$codeBytes = 0
foreach ($s in $secs) {
    if ($codeSecs -notcontains $s.Section) { continue }
    if ($s.Targets -match '\|') { $crossed += $s.Section }
    foreach ($t in ($s.Targets -split '\|')) {
        $tn = $t.Trim()
        $hit = $mem | Where-Object { $_.Name -eq $tn }
        if ($hit) { $codeBytes += $hit.Len }
    }
}

if ($crossed.Count -gt 0) {
    Bad ("这些段被放在多个内存块里（跨片）：" + ($crossed -join ', '))
    Warn "跨片调用会触发 `"requires a trampoline`" 类链接错误 —— 把内存合并成**连续大块**："
    Say  "         RAMCODE : origin = 0x008000, length = 0x004000   (L0~L3, 16K 字)"
    Say  "         RAMDATA : origin = 0x00C000, length = 0x004000   (L4~L7, 16K 字)"
    Say  "         然后  .text : > RAMCODE, PAGE = 0"
    Say  "         详见 references/ram-and-linker.md §3"
}
else {
    Good "代码类段未跨片"
}

$textHit = $secs | Where-Object { $_.Section -eq '.text' } | Select-Object -First 1
if ($textHit) {
    $tNames = ($textHit.Targets -split '\|') | ForEach-Object { $_.Trim() }
    $tTotal = 0
    foreach ($tn in $tNames) {
        $hit = $mem | Where-Object { $_.Name -eq $tn }
        if ($hit) { $tTotal += $hit.Len }
    }
    Say ("  .text 可用空间合计：{0} 字（{1:N1} KB）" -f $tTotal, ($tTotal * 2 / 1024))
    if ($tTotal -lt 8192)  { Warn ".text 小于 8K 字，工程稍大就会爆。建议合并到 16K 连续块（L0~L3）" }
    elseif ($tTotal -lt 16384) { Info ".text 在 8K~16K 之间：中小工程够用；再大就合并到 16K 连续块" }
    else { Good ".text 已是 16K 字以上（连续大块），工程扩展余量充足" }
}

# 5.2 数据段（按目标块名去重，避免 .ebss/.econst 指向同一块时重复累加）
$dataSecs = @('.ebss', '.econst', '.esysmem')
$dataTargets = @{}
foreach ($s in $secs) {
    if ($dataSecs -notcontains $s.Section) { continue }
    foreach ($t in ($s.Targets -split '\|')) {
        $tn = $t.Trim()
        $hit = $mem | Where-Object { $_.Name -eq $tn }
        if ($hit) { $dataTargets[$tn] = [int64]$hit.Len }
    }
}
$dataTotal = 0
foreach ($v in $dataTargets.Values) { $dataTotal += $v }
if ($dataTotal -gt 0) {
    Say ("  数据段可用空间合计（去重）：{0} 字（{1:N1} KB），目标块：{2}" -f `
         $dataTotal, ($dataTotal * 2 / 1024), (($dataTargets.Keys | Sort-Object) -join ' + '))
}

if ($cmdFile -match 'RAM_lnk') {
    Info "提示：RAM 版链接只适合调试；代码量继续增长时可换 Flash 链接（F28335 有 256K 字 Flash），见 ram-and-linker.md §6"
}

Say ""
Say "详细判读规则与改造步骤：references\ram-and-linker.md"
Say "RESULT: DONE"
