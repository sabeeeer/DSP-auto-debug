#requires -Version 7.0
<#
.SYNOPSIS
  C2000Ware 检索器：自动定位参照源（本机 SDK / 本机快照 / GitHub 快照），找官方例程 / 库 / API。
.DESCRIPTION
  参照源优先级（-Source auto，先本机、后 GitHub）：
    1) -SdkRoot 显式指定
    2) 环境变量 C2000WARE_ROOT / C2000WARE
    3) 常见安装路径：C:\ti\c2000\C2000Ware_*、<盘>:\c2000ware-core-sdk …
    4) 本机快照仓库：%USERPROFILE%\CodeBuddy\c2000ware-ref 等
    5) GitHub 快照：把 sabeeeer/c2000ware-ref 的 Release 附件下载解压到
       %LOCALAPPDATA%\c2000ware-snapshot 当缓存，之后按本机方式高速检索（-NoDownload 可禁用）
  所有检索都在本机做（不管是本机 SDK 还是下载来的缓存），所以快、能全库 grep。
  输出一律英文（避免 PowerShell 5.1 编码问题）。
.EXAMPLE
  c2000ware_find.ps1 -Keyword deadband
  c2000ware_find.ps1 -Keyword pid -Kind example
  c2000ware_find.ps1 -Keyword EPWM_setDeadBandDelayMode -Kind api
  c2000ware_find.ps1 -List devices
  c2000ware_find.ps1 -Source github -Keyword epwm_ex1_trip_zone     # 强制用 GitHub 快照
  c2000ware_find.ps1 -GetFile driverlib/f2837xd/driverlib/epwm.h    # 直接看某个文件
#>
[CmdletBinding()]
param(
    [string]$Keyword = '',
    [ValidateSet('all','example','library','api')][string]$Kind = 'all',
    [string]$SdkRoot = '',
    [ValidateSet('auto','local','github')][string]$Source = 'auto',
    [string]$GithubRepo = 'sabeeeer/c2000ware-ref',
    [string]$GithubTag  = 'v26.00.00.00-snapshot',
    [string]$GetFile = '',
    [ValidateSet('devices','libs')][string]$List = '',
    [switch]$NoDownload,
    [int]$Max = 30
)

$ErrorActionPreference = 'Continue'

function Get-GhPath {
    $c = Get-Command gh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'GitHubCLI\bin\gh.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Test-SdkDir([string]$d) {
    if (-not $d) { return $false }
    if (-not (Test-Path -LiteralPath $d)) { return $false }
    foreach ($s in @('device_support', 'driverlib', 'libraries')) {
        if (Test-Path -LiteralPath (Join-Path $d $s)) { return $true }
    }
    return $false
}

function Get-LocalRoot([string]$Explicit) {
    if (Test-SdkDir $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
    foreach ($v in @($env:C2000WARE_ROOT, $env:C2000WARE)) { if (Test-SdkDir $v) { return $v } }
    $cands = @()
    foreach ($base in @('C:\ti\c2000', 'C:\ti', 'D:\ti', 'E:\ti', 'F:\ti')) {
        $cands += @(Get-ChildItem $base -Directory -Filter 'C2000Ware*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    foreach ($drv in @('C','D','E','F')) { $cands += "${drv}:\c2000ware-core-sdk" }
    $cands += @(
        (Join-Path $env:USERPROFILE 'CodeBuddy\c2000ware-ref'),
        (Join-Path $env:USERPROFILE 'c2000ware-ref')
    )
    $cands += @(Get-ChildItem (Get-Location) -Directory -Filter 'c2000ware*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($c in $cands) { if (Test-SdkDir $c) { return (Resolve-Path -LiteralPath $c).Path } }
    return $null
}

function Get-SnapshotFromGitHub {
    $cache = Join-Path $env:LOCALAPPDATA 'c2000ware-snapshot'
    if (Test-SdkDir $cache) { return $cache }
    if ($NoDownload) { return $null }
    $gh = Get-GhPath
    if (-not $gh) { Write-Host "  (gh CLI not found -> cannot download GitHub snapshot)"; return $null }
    Write-Host ("  (no local C2000Ware found -> downloading snapshot from GitHub release " + $GithubTag + " ...)")
    $dl = Join-Path $env:TEMP 'c2000ware-snapshot-dl'
    if (Test-Path $dl) { Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $list = & $gh api "repos/$GithubRepo/releases/tags/$GithubTag" --jq '.assets[] | (.id|tostring) + " " + .name' 2>$null
    if (-not $list) { Write-Host "  (cannot list release assets - network?)"; return $null }
    $tok = (& $gh auth token 2>$null | Out-String).Trim()
    if (-not $tok) { Write-Output "  (no gh token -> cannot download)"; return $null }
    $cfg = Join-Path $dl 'curl.cfg'
    [IO.File]::WriteAllText($cfg, "header = `"Authorization: token $tok`"`nheader = `"Accept: application/octet-stream`"`nuser-agent = cb-check`nsilent`nshow-error`nlocation`n", (New-Object System.Text.UTF8Encoding($false)))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ok = 0
    foreach ($line in @($list)) {
        $line = "$line".Trim()
        if (-not $line) { continue }
        $parts = $line -split '\s+', 2
        $id = $parts[0]; $name = $parts[1]
        $zip = Join-Path $dl $name
        curl.exe --config $cfg -o "$zip" "https://api.github.com/repos/$GithubRepo/releases/assets/$id" 2>$null
        if (-not (Test-Path $zip)) { continue }
        $sub = [IO.Path]::GetFileNameWithoutExtension($name)
        $dest = Join-Path $cache $sub
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
        try { [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest); $ok++ } catch {}
    }
    Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue
    if ((Test-SdkDir $cache) -and $ok -gt 0) { Write-Host ("  (snapshot ready: " + $cache + ")"); return $cache }
    return $null
}

# ---------- 选源 ----------
$root = $null
if ($Source -eq 'github') {
    $root = Get-SnapshotFromGitHub
} else {
    $root = Get-LocalRoot $SdkRoot
    if (-not $root -and $Source -eq 'auto') { $root = Get-SnapshotFromGitHub }
}
if (-not $root) {
    Write-Output "SOURCE: none"
    Write-Output "FATAL: no C2000Ware source. Options:"
    Write-Output "  -SdkRoot <dir>            point to a local C2000Ware / snapshot"
    Write-Output "  (default auto)            install C2000Ware, or clone https://github.com/$GithubRepo"
    exit 2
}
Write-Output ("SOURCE: " + $root)

function Rel([string]$p) { return $p.Replace($root + '\', '') }

# ---------- 直接看某个文件 ----------
if ($GetFile) {
    $f = Join-Path $root $GetFile
    if (Test-Path -LiteralPath $f) { Write-Output ("===== FILE: " + $GetFile + " ====="); Get-Content -LiteralPath $f -TotalCount 200 }
    else { Write-Output ("not found: " + $GetFile) ; exit 1 }
    exit 0
}

# ---------- -List ----------
if ($List -eq 'devices') {
    foreach ($fam in @('device_support', 'driverlib')) {
        Write-Output "===== $fam ====="
        Get-ChildItem (Join-Path $root $fam) -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^\.' } | ForEach-Object { Write-Output ("  " + $_.Name) }
    }
    exit 0
}
if ($List -eq 'libs') {
    Write-Output "===== libraries ====="
    $libRoot = Join-Path $root 'libraries'
    foreach ($cat in (Get-ChildItem $libRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' })) {
        foreach ($lib in (Get-ChildItem $cat.FullName -Directory -ErrorAction SilentlyContinue)) {
            $subs = @(Get-ChildItem $lib.FullName -Recurse -Depth 2 -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -in @('include','lib','examples','cmd','docs','source') } |
                      ForEach-Object { $_.Name } | Select-Object -Unique)
            Write-Output ("libraries\{0}\{1}   [{2}]" -f $cat.Name, $lib.Name, ($subs -join ','))
        }
    }
    exit 0
}

if (-not $Keyword) { Write-Output "usage: -Keyword <word> [-Kind all|example|library|api] | -List devices|libs | -GetFile <path> [-Source auto|local|github]"; exit 1 }
$kw = $Keyword

# ---------- 例程 ----------
if ($Kind -eq 'example' -or $Kind -eq 'all') {
    Write-Output "===== examples ====="
    $roots = @()
    foreach ($fam in @('device_support', 'driverlib')) {
        foreach ($dev in (Get-ChildItem (Join-Path $root $fam) -Directory -ErrorAction SilentlyContinue)) {
            $e = Join-Path $dev.FullName 'examples'
            if (Test-Path $e) { $roots += $e }
        }
    }
    $libRoot = Join-Path $root 'libraries'
    $roots += @(Get-ChildItem $libRoot -Recurse -Depth 6 -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'examples' } | ForEach-Object { $_.FullName })
    $hits = @()
    foreach ($r in $roots) {
        $hits += @(Get-ChildItem $r -Recurse -Depth 3 -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$kw*" })
    }
    $shown = 0; $seenDirs = @()
    foreach ($h in ($hits | Sort-Object FullName -Unique)) {
        if (@($seenDirs | Where-Object { $h.FullName.StartsWith($_) }).Count -gt 0) { continue }
        if ($shown -ge $Max) { Write-Output "  ... (more, raise -Max)"; break }
        if ($h.PSIsContainer) {
            $seenDirs += $h.FullName
            Write-Output ("  [example] " + (Rel $h.FullName))
            $mains = @(Get-ChildItem $h.FullName -File -Filter '*.c' -ErrorAction SilentlyContinue | Select-Object -First 3)
            if ($mains.Count -gt 0) { foreach ($m in $mains) { Write-Output ("            main file: " + $m.Name) } }
            else { foreach ($s in (Get-ChildItem $h.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 8)) { Write-Output ("            subdir: " + $s.Name) } }
        } else { Write-Output ("  [file] " + (Rel $h.FullName)) }
        $shown++
    }
    if ($shown -eq 0) { Write-Output "  (none - try another keyword, or see references\c2000ware-index.md)" }
}

# ---------- 库 ----------
if ($Kind -eq 'library' -or $Kind -eq 'all') {
    Write-Output "===== libraries ====="
    $n = 0
    $libRoot = Join-Path $root 'libraries'
    foreach ($cat in (Get-ChildItem $libRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' })) {
        foreach ($lib in (Get-ChildItem $cat.FullName -Directory -ErrorAction SilentlyContinue)) {
            if (($lib.Name -like "*$kw*") -or ($cat.Name -like "*$kw*")) {
                Write-Output ("  [lib] libraries\{0}\{1}" -f $cat.Name, $lib.Name)
                foreach ($sub in @('include','lib','examples','cmd','docs','source','ccs','reference','models')) {
                    $fp = Join-Path (Join-Path $lib.FullName 'c28') $sub
                    $sp = Join-Path $lib.FullName $sub
                    if (Test-Path $fp) { Write-Output ("          " + (Rel $fp)) } elseif (Test-Path $sp) { Write-Output ("          " + (Rel $sp)) }
                }
                $n++
            }
        }
    }
    if ($n -eq 0 -and $Kind -eq 'library') { Write-Output "  (none - run -List libs to see all)" }
}

# ---------- API ----------
if ($Kind -eq 'api' -or $Kind -eq 'all') {
    Write-Output "===== driverlib API ====="
    $dlRoots = @()
    foreach ($dev in (Get-ChildItem (Join-Path $root 'driverlib') -Directory -ErrorAction SilentlyContinue)) {
        $d = Join-Path $dev.FullName 'driverlib'
        if (Test-Path $d) { $dlRoots += $d }
    }
    $files = @(Get-ChildItem $dlRoots -Recurse -File -Filter '*.h' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notmatch '^(hw_|driver_inclusive|pin_map)' })
    $ms = @($files | Select-String -Pattern ([regex]::Escape($kw)) -ErrorAction SilentlyContinue |
            Where-Object { ($_.Line -match '[A-Za-z_]\w*\s*\(') -and ($_.Line -notmatch '^\s*(//|\*|/\*)') } |
            Select-Object -First $Max)
    foreach ($m in $ms) { Write-Output ("  " + (Rel $m.Path) + ":" + $m.LineNumber + "  " + $m.Line.Trim()) }
    if ($ms.Count -eq 0) { Write-Output "  (no API hit - maybe a macro; try -Kind all)" }
}
