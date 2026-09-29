#requires -Version 7.0
<#
.SYNOPSIS
    一条命令切换工程的调试探针连接类型（XDS100v1 / v2 / v3 / XDS110 / XDS200 ...），
    同时改好 <工程>\targetConfigs\*.ccxml 与 <工程>\.ccsproject。

.DESCRIPTION
    为什么需要它：.ccxml 里的"连接类型"必须与探针硬件版本一致 ——
    拿 v1 的连接类型去驱动 v2/v3 探针，会出现"能连上但时好时坏"
    （Error -151 / Error -1135）。手动改要动 ccxml 的 3 组字段 + .ccsproject 的 1 行，容易漏。
    本脚本从 CCS 的 targetdb 里读规范名（desc / id / 驱动 xml），一次改齐；改前自动备份 .bak。

    支持的 -Probe 别名：
      v1 / xds100 / xds100v1   -> TIXDS100usb_Connection.xml      + tixds100c28x.xml
      v2 / xds100v2            -> TIXDS100v2_Connection.xml       + tixds100v2c28x.xml
      v3 / xds100v3            -> TIXDS100v3_Dot7_Connection.xml  + tixds100v3c28x.xml
      xds110 / xds200 / xds560v2 ... 按名字模糊匹配 targetdb 里的连接定义
      （也可以直接给 connection xml 的文件名或连接名）

.USAGE
    pwsh -NoProfile -ExecutionPolicy Bypass -File ti_c2000_set_probe.ps1 -ProjectPath <工程>            # 只看当前配置
    powershell ... -File ti_c2000_set_probe.ps1 -ProjectPath <工程> -Probe v2                                  # 切成 XDS100v2
    powershell ... -File ti_c2000_set_probe.ps1 -ProjectPath <工程> -Probe v3 -DryRun                          # 只报告不写
    powershell ... -File ti_c2000_set_probe.ps1 -List                                                          # 列出本机可选连接

    判定：末尾 RESULT: OK / RESULT: FAIL。改完建议再跑一次 ti_c2000_debug.ps1 -Run 确认能连。
#>
[CmdletBinding()]
param(
    [string] $ProjectPath = '',
    [string] $Probe       = '',
    [switch] $List,
    [string] $CcsRoot     = '',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
function Say([string]$m) { Write-Output $m }
function Fail([string]$cat, [string]$reason) {
    Say ''
    Say 'RESULT: FAIL'
    Say ("FAILURE: {0}" -f $cat)
    Say ("REASON: {0}" -f $reason)
    exit 1
}

# ---------- 1. 定位 CCS 的 targetdb ----------
function Get-TargetDbRoot([string]$ccsRootArg) {
    $cands = New-Object System.Collections.ArrayList
    if ($ccsRootArg) { [void]$cands.Add($ccsRootArg) }
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Texas Instruments' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p.Version -and $p.Location) {
            $loc = ([string]$p.Location).TrimEnd('\')
            foreach ($c in @((Join-Path $loc 'ccs'), (Join-Path $loc ("ccs" + ($p.Version -split '\.')[0])))) {
                if (Test-Path $c) { [void]$cands.Add($c) }
            }
        }
    }
    foreach ($c in @('F:\ccs', 'C:\ti\ccs1281', 'C:\ti\ccsv6')) {
        if (Test-Path $c) { [void]$cands.Add($c) }
    }
    foreach ($d in @(Get-ChildItem 'C:\ti' -Directory -Filter 'ccs*' -ErrorAction SilentlyContinue)) {
        [void]$cands.Add($d.FullName)
    }
    foreach ($c in $cands) {
        $p = Join-Path $c 'ccs_base\common\targetdb'
        if (Test-Path $p) { return $p }
    }
    return ''
}

$tdb = Get-TargetDbRoot $CcsRoot
if (-not $tdb) { Fail 'NO_CCS' '找不到 CCS 的 ccs_base\common\targetdb（用 -CcsRoot 指定 CCS 安装目录）' }
Say ("TARGETDB  : {0}" -f $tdb)

# ---------- 2. -List：列出本机可选的连接 ----------
function Get-ConnectionInfo([string]$xmlPath) {
    $txt = [System.IO.File]::ReadAllText($xmlPath)
    $desc = ''
    $id   = ''
    $ct   = ''
    if ($txt -match '<connection\s+desc="([^"]*)"\s+id="([^"]*)"') { $desc = $Matches[1]; $id = $Matches[2] }
    elseif ($txt -match '<connection[^>]*\sid="([^"]*)"') { $id = $Matches[1] }
    if ($txt -match '<connectionType\s+Type="([^"]+)"') { $ct = $Matches[1] }   # 如 TIXDS100 / TIXDS100v2（驱动名前缀）
    return [pscustomobject]@{ Desc = $desc; Id = $id; ConnType = $ct; File = (Split-Path $xmlPath -Leaf); Path = $xmlPath }
}

$connDir = Join-Path $tdb 'connections'
$allConn = @(Get-ChildItem $connDir -Filter '*Connection*.xml' -ErrorAction SilentlyContinue | ForEach-Object { Get-ConnectionInfo $_.FullName })

if ($List) {
    Say ''
    Say '=== 本机可选的连接类型（targetdb\connections）==='
    foreach ($c in ($allConn | Sort-Object File)) {
        Say ("  {0,-38} {1}" -f $c.File, $c.Desc)
    }
    Say ''
    Say '用法示例:  -Probe v2    (或 v1 / v3 / xds110 / 上面任意文件名/连接名)'
    Say 'RESULT: OK'
    exit 0
}

# ---------- 3. 解析 -Probe 别名 ----------
$alias = @{
    'v1' = 'TIXDS100usb_Connection.xml'; 'xds100' = 'TIXDS100usb_Connection.xml'; 'xds100v1' = 'TIXDS100usb_Connection.xml'
    'v2' = 'TIXDS100v2_Connection.xml';  'xds100v2' = 'TIXDS100v2_Connection.xml'
    'v3' = 'TIXDS100v3_Dot7_Connection.xml'; 'xds100v3' = 'TIXDS100v3_Dot7_Connection.xml'
    'xds110' = 'TIXDS110_Connection.xml'
}
function Resolve-ConnectionFile([string]$probe) {
    if (-not $probe) { return $null }
    $key = $probe.Trim().ToLower()
    if ($alias.ContainsKey($key)) {
        $want = $alias[$key]
        $hit = $allConn | Where-Object { $_.File -eq $want }
        if ($hit) { return $hit | Select-Object -First 1 }
    }
    # 直接给文件名 / 连接名 / 模糊包含
    $hit = $allConn | Where-Object { $_.File -like "*$probe*" -or $_.Desc -like "*$probe*" -or $_.Id -like "*$probe*" }
    if ($hit) { return $hit | Select-Object -First 1 }
    return $null
}

# ---------- 4. 读工程现状 ----------
if (-not $ProjectPath -or -not (Test-Path $ProjectPath)) { Fail 'BAD_PARAM' '-ProjectPath 必须是已存在的工程目录' }
$ProjectPath = (Resolve-Path $ProjectPath).Path
$ccxmls = @(Get-ChildItem (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue)
if ($ccxmls.Count -eq 0) { Fail 'NO_CCXML' "工程里没有 targetConfigs\*.ccxml（先在 CCS 里建一个 target configuration）" }
$ccxml = $ccxmls[0]

$ccxmlTxt = [System.IO.File]::ReadAllText($ccxml.FullName)
$curFile = ''
if ($ccxmlTxt -match 'connections/([^"]+\.xml)') { $curFile = $Matches[1] }
$cur = $allConn | Where-Object { $_.File -eq $curFile } | Select-Object -First 1

Say ("PROJECT   : {0}" -f $ProjectPath)
Say ("CCXML     : {0}" -f $ccxml.Name)
if ($cur) { Say ("CURRENT   : {0}   [{1}]" -f $cur.Desc, $cur.File) }
else      { Say ("CURRENT   : (未识别)   [{0}]" -f $curFile) }

if (-not $Probe) {
    Say ''
    Say '未指定 -Probe：只显示当前配置。用 -Probe v1|v2|v3|xds110|... 切换，或 -List 看全部可选。'
    Say 'RESULT: OK'
    exit 0
}

$target = Resolve-ConnectionFile $Probe
if (-not $target) { Fail 'BAD_PROBE' ("targetdb 里找不到与 '{0}' 匹配的连接定义；用 -List 看可选列表" -f $Probe) }
Say ("NEW       : {0}   [{1}]" -f $target.Desc, $target.File)

if ($curFile -eq $target.File) {
    Say ''
    Say '已经是目标连接类型，无需修改。'
    Say 'RESULT: OK'
    exit 0
}

# ---------- 5. 找配套的 C28x 驱动 xml ----------
# 规则（targetdb 实测）：驱动名 = connection xml 里 <connectionType Type="XXX"/> 的小写 + "c28x.xml"
#   XDS100v1 -> TIXDS100    -> tixds100c28x.xml
#   XDS100v2 -> TIXDS100v2  -> tixds100v2c28x.xml
#   XDS100v3 -> TIXDS100v2  -> tixds100v2c28x.xml   （v3 复用 v2 的驱动，实测如此）
$drvDir  = Join-Path $tdb 'drivers'
$drvName = ''
$drvPath = ''
if ($target.ConnType) {
    $drvName = ($target.ConnType.ToLower() + 'c28x.xml')
    $drvPath = Join-Path $drvDir $drvName
}
if (-not $drvPath -or -not (Test-Path $drvPath)) {
    # 回退：按 connection 文件名推（去 _Connection.xml / _Dot7 / usb）后模糊匹配
    $base = $target.File -replace '_Connection\.xml$', '' -replace '_Dot7$', '' -replace 'usb$', ''
    $cand = @(Get-ChildItem $drvDir -Filter '*c28x*.xml' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name.ToLower().StartsWith($base.ToLower()) } | Select-Object -First 1)
    if ($cand) { $drvPath = $cand.FullName; $drvName = $cand.Name } else { $drvPath = '' }
}
if (-not $drvPath) {
    $all = @(Get-ChildItem $drvDir -Filter '*c28x*.xml' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Fail 'NO_DRIVER' ("找不到与 {0}（ConnType={1}）配套的 C28x 驱动；drivers 里可选: {2}" -f $target.File, $target.ConnType, ($all -join ', '))
}
Say ("DRIVER    : {0}" -f $drvName)

# ---------- 6. 生成新 ccxml（保留器件 platform 行）----------
$devLine = ''
if ($ccxmlTxt -match '(?m)^\s*(<instance[^>]*xmlpath="devices"[^>]*/>)\s*$') { $devLine = $Matches[1].Trim() }
if (-not $devLine) { Fail 'NO_DEVICE' 'ccxml 里找不到 devices 那一行（器件定义），无法保留器件设置' }

$nl = "`r`n"
$newXml = '<?xml version="1.0" encoding="UTF-8" standalone="no"?>' + $nl +
'<configurations XML_version="1.2" id="configurations_0">' + $nl +
'    <configuration XML_version="1.2" id="configuration_0">' + $nl +
('        <instance XML_version="1.2" desc="{0}" href="connections/{1}" id="{2}" xml="{1}" xmlpath="connections"/>' -f $target.Desc, $target.File, $target.Id) + $nl +
('        <connection XML_version="1.2" id="{0}">' -f $target.Id) + $nl +
('            <instance XML_version="1.2" href="drivers/{0}" id="drivers" xml="{0}" xmlpath="drivers"/>' -f $drvName) + $nl +
'            <platform XML_version="1.2" id="platform_0">' + $nl +
('                ' + $devLine) + $nl +
'            </platform>' + $nl +
'        </connection>' + $nl +
'    </configuration>' + $nl +
'</configurations>' + $nl

# ---------- 7. 写回（备份 + 更新 .ccsproject）----------
if ($DryRun) {
    Say ''
    Say '[DryRun] 将写入上面的 NEW 配置（未实际修改任何文件）'
    Say 'RESULT: OK'
    exit 0
}

$bak = $ccxml.FullName + '.bak'
Copy-Item -LiteralPath $ccxml.FullName -Destination $bak -Force
[System.IO.File]::WriteAllText($ccxml.FullName, $newXml)
Say ("CCXML     : 已更新（备份 {0}）" -f (Split-Path $bak -Leaf))

$ccsproj = Join-Path $ProjectPath '.ccsproject'
if (Test-Path $ccsproj) {
    $txt = [System.IO.File]::ReadAllText($ccsproj)
    $pat = '<connection\s+value="[^"]*"\s*/>'
    if ($txt -match $pat) {
        $newLine = ('<connection value="common/targetdb/connections/{0}"/>' -f $target.File)
        $txt = [System.Text.RegularExpressions.Regex]::Replace($txt, $pat, $newLine, 1)
        Copy-Item -LiteralPath $ccsproj -Destination ($ccsproj + '.bak') -Force
        [System.IO.File]::WriteAllText($ccsproj, $txt)
        Say 'CCSPROJECT: 已更新'
    } else {
        Say 'CCSPROJECT: 没找到 <connection value="..."/> 行，跳过（不影响连接，ccxml 才是关键）'
    }
} else {
    Say 'CCSPROJECT: 文件不存在，跳过'
}

Say ''
Say '提示：跑一次 ti_c2000_debug.ps1 -Run 确认连接正常（应打印 TARGET: ... 与你的探针一致）。'
Say 'RESULT: OK'
exit 0
