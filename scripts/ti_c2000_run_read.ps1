#requires -Version 7.0
<#
ti_c2000_run_read.ps1 -- single-session "run + read while running".

Some targets reset when the JTAG session closes (measured: F28379D + XDS100v2),
so a separate read-only call can never work. The only way to read a RAM program
is inside ONE session:

    connect -> reset (fallback halt) -> loadProgram -> runAsynch
    -> read N rounds while the target keeps running -> disconnect

Execution mode, not read-only: it loads the program once per invocation. For
RAM-linked F28335 projects, capture every required scalar in this invocation;
do not verify a new RAM image by a separate connect after the loader exits.

Liveness proof (see references/data-read-verdict.md):
  - every readable heartbeat candidate is checked for advancement
  - numeric values must strictly increase across rounds
  - gMsTick / gRunMs style counters must start below -StartupMaxMs
  - -NoHeartbeat disables the check explicitly (not recommended)

Exit code: 0 OK | 1 failure | 2 environment/argument problem | 3 no probe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    # AllowEmptyString so an empty -Variables reaches the NEED_VARIABLES guard
    # (exit 2) instead of failing parameter binding with exit 1.
    [AllowEmptyString()][Parameter(Mandatory)][string[]]$Variables,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    [string]$CorePattern = '.*C28xx(?:_CPU1)?$',
    [string]$HeartbeatExpr = 'gMsTick,gRunMs,usMainLoop',
    [int]$StartupMaxMs = 10000,
    # default: 5 s total, 0.5 s interval -> 10 rounds
    [int]$Rounds = 10,
    [int]$IntervalMs = 500,
    [int]$WarmupMs = 500,
    [int]$TimeoutSec = 600,
    [string]$OutRoot = '',
    [switch]$Build,
    [switch]$NoHeartbeat,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

$names = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names.Count -eq 0) { Out2 'FAILURE: NEED_VARIABLES'; Out2 'RESULT: FAIL'; Out2 'REASON: -Variables requires at least one expression'; exit 2 }
if (@($names | Sort-Object -Unique).Count -ne $names.Count) {
    Out2 'FAILURE: DUPLICATE_VARIABLES'; Out2 'RESULT: FAIL'; Out2 'REASON: each variable may appear only once'; exit 2
}
if ($NoHeartbeat) { $HeartbeatExpr = '' }
$pathPattern = '[A-Za-z_][A-Za-z0-9_]*(?:(?:\.|->)[A-Za-z_][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]*)\])*'
$heartbeats = @($HeartbeatExpr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (@($names | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    @($heartbeats | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    $Rounds -lt 2 -or $IntervalMs -lt 0 -or $WarmupMs -lt 0) {
    Out2 'FAILURE: INVALID_READ_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: use simple read paths, at least two rounds and nonnegative timing values'; exit 2
}

if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) { Out2 'FAILURE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2 }
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName
$projName = Split-Path -Leaf $ProjectPath
$projectFile = Join-Path $ProjectPath '.project'
if (Test-Path -LiteralPath $projectFile) {
    try {
        [xml]$projectXml = Get-Content -LiteralPath $projectFile -Raw
        if ($projectXml.projectDescription.name) { $projName = [string]$projectXml.projectDescription.name }
    } catch { Out2 'FAILURE: INVALID_PROJECT_NAME'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $_.Exception.Message); exit 2 }
}
$projName = [IO.Path]::GetFileName($projName)
$projName = [regex]::Replace($projName, '[^A-Za-z0-9._-]+', '_').Trim('.', '_')

if (-not $Ccxml) {
    $c = @(Get-ChildItem -Path (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue | Sort-Object Name) | Select-Object -First 1
    if ($c) { $Ccxml = $c.FullName }
}
if (-not $Ccxml -or -not (Test-Path -LiteralPath $Ccxml)) { Out2 'FAILURE: NO_CCXML'; Out2 'RESULT: FAIL'; Out2 'REASON: no .ccxml found; pass -Ccxml <file>'; exit 2 }
if (-not $OutFile) { $OutFile = Join-Path $ProjectPath "Debug\$projName.out" }

$skillRoot = Split-Path $PSScriptRoot -Parent
$debugScript = Join-Path $skillRoot 'scripts\ti_c2000_debug.ps1'
if (-not (Test-Path -LiteralPath $debugScript)) { Out2 'FAILURE: ENV_NO_DEBUG_SCRIPT'; Out2 'RESULT: FAIL'; Out2 'REASON: ti_c2000_debug.ps1 is missing from this skill installation'; exit 2 }
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

$probeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $debugScript, '-ProjectPath', $ProjectPath, '-ProbeCheckOnly')
if ($CcsRoot) { $probeArgs += @('-CcsRoot', $CcsRoot) }
$probeOut = & $pwshExe @probeArgs 2>&1
$probeCode = $LASTEXITCODE
$probeText = (@($probeOut | ForEach-Object { [string]$_ }) -join "`n")
if ($probeCode -ne 0 -or $probeText -notmatch 'RESULT: OK') {
    foreach ($line in $probeOut) { Out2 ([string]$line) }
    if ($probeCode -eq 3 -or $probeText -match 'NO_PROBE') { Out2 'FAILURE: NO_PROBE'; Out2 'RESULT: FAIL'; Out2 'REASON: no debug probe detected'; exit 3 }
    Out2 'FAILURE: PROBE_CHECK_FAILED'; Out2 'RESULT: FAIL'; Out2 'REASON: probe pre-check did not return RESULT: OK'; exit 2
}
if ($Build) {
    $buildScript = Join-Path $skillRoot 'scripts\ti_c2000_build.ps1'
    $bargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript, '-ProjectPath', $ProjectPath, '-Stage', '-KeepLaunches')
    if ($CcsRoot) { $bargs += @('-CcsRoot', $CcsRoot) }
    Info2 'STEP    : build'
    $bout = & $pwshExe @bargs 2>&1
    $bcode = $LASTEXITCODE
    # keep exactly one RESULT line per invocation: the build reports BUILD, not RESULT
    foreach ($line in $bout) { if (-not $Quiet -and [string]$line -notmatch '^RESULT:') { Out2 ([string]$line) } }
    if ($bcode -ne 0 -or -not @($bout | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
        $bfail = @($bout | Where-Object { $_ -match '^FAILURE: ' }) | Select-Object -First 1
        if (-not $bfail) { $bfail = 'FAILURE: BUILD_FAILED' }
        Out2 $bfail; Out2 'RESULT: FAIL'; Out2 'REASON: build failed - run/read aborted'; exit 1
    }
    Info2 'BUILD   : OK (freshly built .out staged for this read)'
}
if (-not (Test-Path -LiteralPath $OutFile)) { Out2 'FAILURE: NO_OUT_FILE'; Out2 'RESULT: FAIL'; Out2 "REASON: '$OutFile' not found - add -Build or build/stage first"; exit 2 }
$outShaBefore = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
$ccsPath = ''
if ($probeText -match '(?m)^CCS\s*:\s*(.+?)\s+\(v') { $ccsPath = $Matches[1].Trim() }
if (-not $ccsPath -and $CcsRoot -and (Test-Path (Join-Path $CcsRoot 'ccs_base'))) { $ccsPath = (Get-Item -LiteralPath $CcsRoot).FullName }
if (-not $ccsPath) { Out2 'FAILURE: ENV_NO_CCS'; Out2 'RESULT: FAIL'; Out2 'REASON: cannot resolve CCS; pass -CcsRoot'; exit 2 }
$dss = Join-Path $ccsPath 'ccs_base\scripting\bin\dss.bat'
if (-not (Test-Path -LiteralPath $dss)) { Out2 'FAILURE: ENV_NO_DSS'; Out2 'RESULT: FAIL'; Out2 "REASON: dss.bat not found under '$ccsPath'"; exit 2 }

Info2 "PROJECT : $ProjectPath"
Info2 "CCS     : $ccsPath"
Info2 "CCXML   : $Ccxml"
Info2 "OUT     : $OutFile"
Info2 ("STEP    : single session, {0} round(s) x {1} ms" -f $Rounds, $IntervalMs)

# one readout folder, two sub folders: check (verdict + variable mapping),
# data (the CSV that was actually read).
# One fixed folder in the project root: each read refreshes check/ and data/.
if (-not $OutRoot) { $OutRoot = $ProjectPath }
$runDir = Join-Path $OutRoot 'readout'
$dataDir = Join-Path $runDir 'data'
$checkDir = Join-Path $runDir 'check'
New-Item -ItemType Directory -Force -Path $dataDir, $checkDir | Out-Null
Info2 "OUTDIR  : $runDir"

# ---------------------------------------------------------------------------
# verdict publishing, defined before the first possible failure so that a
# failed read never leaves an older "result: OK" verdict (and its data.csv)
# behind. A read is only usable when the last RESULT line of this run is OK.
# ---------------------------------------------------------------------------
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$verdictPath = Join-Path $checkDir 'verdict.txt'
$hbStatus = 'PENDING'
function Get-VerdictText([string]$result, [string]$reason, [string]$checker) {
    @(
        'TI C2000 readout',
        ('created   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('project   : ' + $ProjectPath),
        ('ccxml     : ' + $Ccxml),
        ('out       : ' + $OutFile),
        ('out sha256: ' + $outShaBefore),
        'mode      : single session, run + read',
        'identity  : SAME_SESSION_LOAD (out hash stable)',
        'freeze    : NOT_APPLICABLE',
        'range     : SKIPPED (scalar limits not requested)',
        ('rounds    : {0}, interval {1} ms' -f $Rounds, $IntervalMs),
        ('variables : ' + ($names -join ', ')),
        ('heartbeat : ' + $hbStatus),
        ('data csv  : ' + (Join-Path $dataDir 'data.csv')),
        ('checker   : ' + $checker),
        ('result    : ' + $result),
        ('reason    : ' + $reason)
    )
}
function Publish-Readout([string]$result, [string]$reason, [string]$checker = 'SKIPPED') {
    try { [IO.File]::WriteAllLines($verdictPath, (Get-VerdictText $result $reason $checker), $utf8Bom) }
    catch { Out2 'FAILURE: READOUT_PUBLISH_FAILED'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $_.Exception.Message); exit 1 }
}
function Clear-StaleReadout {
    # called only when this run produced no usable data: drop the previous
    # data.csv / variables.csv so nothing stale can be consumed.
    foreach ($f in @((Join-Path $dataDir 'data.csv'), (Join-Path $checkDir 'variables.csv'))) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
}

function Escape-Js([string]$v) { return $v.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n') }
$varJs = ($names | ForEach-Object { '"' + (Escape-Js $_) + '"' }) -join ','
$jsPath = Join-Path $env:TEMP ('ti_c2000_run_read_{0}.js' -f (Get-Random))
$js = @"
importPackage(Packages.com.ti.debug.engine.scripting);
importPackage(Packages.com.ti.ccstudio.scripting.environment);
importPackage(Packages.java.lang);

var CCXML     = "$(Escape-Js $Ccxml)";
var OUT       = "$(Escape-Js $OutFile)";
var VARS      = [$varJs];
var ROUNDS    = $Rounds;
var INTERVAL  = $IntervalMs;
var WARMUP    = $WarmupMs;
var CORE      = "$(Escape-Js $CorePattern)";
var HB_CANDS  = "$(Escape-Js $HeartbeatExpr)".split(",");
var STARTUP   = $StartupMaxMs;

function sleepMs(ms) { java.lang.Thread.sleep(ms); }
function toNum(v) { var s = "" + v; if (s.length === 0) { return null; } var n = Number(s); return isNaN(n) ? null : n; }
var HB_NAMES = [];
function selectHeartbeats(session) {
    HB_NAMES = [];
    for (var i = 0; i < HB_CANDS.length; i++) {
        var c = HB_CANDS[i].replace(/^\s+|\s+$/g, "");
        if (c.length === 0) { continue; }
        try { var v = session.expression.evaluate(c); HB_NAMES.push(c); print("DSS: heartbeat candidate '" + c + "' = " + v); }
        catch (e) { }
    }
    if (HB_NAMES.length === 0) { return null; }
    print("DSS: heartbeats used = " + HB_NAMES.join(","));
    return HB_NAMES.slice();
}

var env = ScriptingEnvironment.instance();
try { env.setScriptTimeout($($TimeoutSec * 1000)); } catch (e) {}
var server = env.getServer("DebugServer.1");
server.setConfig(CCXML);
var session = server.openSession(CORE);
session.options.setBoolean("AllowInterruptsWhenHalted", true);
session.options.setBoolean("PoliteRealtimeMode", true);

var connected = false;
for (var i = 1; i <= 3 && !connected; i++) {
    try { session.target.connect(); connected = true; }
    catch (e) { print("CONNECT_RETRY: " + e); sleepMs(1000); }
}
if (!connected) { print("FAILURE: CONNECT_FAILED"); print("RESULT: FAIL"); throw "connect failed"; }
print("DSS: connected");

try { session.target.reset(); print("DSS: reset"); }
catch (e1) {
    print("DSS: reset failed (" + e1 + "), fallback halt");
    try { session.target.halt(); print("DSS: halted (load only)"); } catch (e2) { print("DSS: halt skipped: " + e2); }
}

try { session.memory.loadProgram(OUT); }
catch (e3) { print("FAILURE: LOAD_FAILED"); print("REASON: " + e3); print("RESULT: FAIL"); throw "load failed"; }
print("DSS: loaded");
session.target.runAsynch();
print("DSS: running");
sleepMs(WARMUP);
if (session.target.isHalted()) { print("FAILURE: TARGET_HALTED_AFTER_RUN"); print("RESULT: FAIL"); throw "target halted after run"; }

var hb = null;
if (HB_CANDS.length > 0 && HB_CANDS[0].length > 0) {
    hb = selectHeartbeats(session);
    if (hb === null) { print("FAILURE: NO_HEARTBEAT"); print("REASON: no heartbeat candidate readable"); print("RESULT: FAIL"); throw "no heartbeat"; }
    for (var hi = 0; hi < HB_NAMES.length; hi++) {
        var hn = HB_NAMES[hi];
        if (/Tick|RunMs/i.test(hn)) {
            var n0 = toNum("" + session.expression.evaluate(hn));
            if (n0 !== null && n0 > STARTUP) {
                print("FAILURE: STALE_PROGRAM"); print("REASON: " + hn + " too large right after load"); print("RESULT: FAIL"); throw "stale program";
            }
        }
    }
}

var hbValues = [];
for (var r = 1; r <= ROUNDS; r++) {
    if (session.target.isHalted()) { print("FAILURE: TARGET_HALTED_DURING_READ"); print("RESULT: FAIL"); throw "target halted during read"; }
    print("TS " + r + " = " + new Date().getTime());
    for (var k = 0; k < VARS.length; k++) {
        var n = VARS[k];
        try { print("VAR " + n + "@T" + r + " = " + session.expression.evaluate(n)); }
        catch (e4) { print("VAR " + n + "@T" + r + " = <ERROR: " + e4 + ">"); }
    }
    if (hb !== null) {
        for (var hk = 0; hk < HB_NAMES.length; hk++) {
            try { var hv = "" + session.expression.evaluate(HB_NAMES[hk]); print("HB " + HB_NAMES[hk] + " " + r + " = " + hv); }
            catch (e5) { print("FAILURE: HEARTBEAT_READ"); print("REASON: " + e5); print("RESULT: FAIL"); throw "heartbeat read failed"; }
        }
    }
    if (r < ROUNDS && INTERVAL > 0) { sleepMs(INTERVAL); }
}

if (session.target.isHalted()) { print("FAILURE: TARGET_HALTED_DURING_READ"); print("RESULT: FAIL"); throw "target halted during read"; }
print("DSS: target still running before disconnect");
session.target.disconnect();
print("DSS: disconnected");
print("RESULT: OK");
"@
[IO.File]::WriteAllText($jsPath, $js, [Text.Encoding]::ASCII)
Info2 "JS      : $jsPath"

$dout = & cmd.exe /d /c $dss $jsPath 2>&1
$dcode = $LASTEXITCODE
foreach ($line in $dout) { if ($line -match '^(DSS:|VAR |HB |CONNECT_RETRY|FAILURE)') { Out2 ([string]$line) } }
Remove-Item -LiteralPath $jsPath -Force -ErrorAction SilentlyContinue

$text = (@($dout | ForEach-Object { [string]$_ }) -join "`n")
$varLines = @($dout | Where-Object { $_ -match '^VAR .+@T\d+ = ' -and $_ -notmatch '<ERROR' })
$varErrors = @($dout | Where-Object { $_ -match '^VAR .+@T\d+ = <ERROR:' })
if ($dcode -ne 0 -or $text -notmatch 'RESULT: OK' -or $varLines.Count -ne ($names.Count * $Rounds) -or $varErrors.Count -gt 0) {
    $failCode = 'DSS_SCRIPT_ERROR'; $failReason = 'DSS session did not finish with RESULT: OK'
    # The DSS script names its own failure; keep that identity instead of
    # guessing from keywords (TARGET_HALTED_*, HEARTBEAT_READ, ... all count).
    $jsFail = @($dout | Where-Object { [string]$_ -match '^FAILURE: [A-Z0-9_]+' }) | Select-Object -First 1
    if ($jsFail -and ([string]$jsFail -match '^FAILURE: ([A-Z0-9_]+)')) {
        $failCode = $Matches[1]
        $jsReason = @($dout | Where-Object { [string]$_ -match '^REASON: ' }) | Select-Object -First 1
        if ($jsReason -and ([string]$jsReason -match '^REASON: (.+)$')) { $failReason = $Matches[1] }
        else { $failReason = 'see the DSS failure above' }
    }
    elseif ($text -match 'NO_HEARTBEAT') { $failCode = 'NO_HEARTBEAT'; $failReason = 'no heartbeat candidate readable' }
    elseif ($text -match 'STALE_PROGRAM') { $failCode = 'STALE_PROGRAM'; $failReason = 'heartbeat too large right after load' }
    elseif ($text -match 'CONNECT_FAILED') { $failCode = 'CONNECT_FAILED'; $failReason = 'could not take over the target' }
    elseif ($text -match 'LOAD_FAILED') { $failCode = 'LOAD_FAILED'; $failReason = 'memory.loadProgram failed' }
    elseif ($varErrors.Count -gt 0) { $failCode = 'VALUE_READ_FAILED'; $failReason = [string]($varErrors | Select-Object -First 1) }
    elseif ($varLines.Count -ne ($names.Count * $Rounds)) { $failCode = 'INCOMPLETE_VALUES'; $failReason = ("read {0}/{1} values" -f $varLines.Count, ($names.Count * $Rounds)) }
    Clear-StaleReadout
    Publish-Readout 'FAIL' $failReason $failCode
    Out2 ('FAILURE: ' + $failCode); Out2 ('REASON: ' + $failReason)
    foreach ($line in (@($dout | Where-Object { [string]$_ -notmatch '^RESULT:' }) | Select-Object -Last 8)) { Out2 ([string]$line) }
    Out2 'RESULT: FAIL'
    exit 1
}
if ((Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ne $outShaBefore) {
    Clear-StaleReadout
    Publish-Readout 'FAIL' 'the .out file changed between load and result packaging' 'OUT_CHANGED_DURING_READ'
    Out2 'FAILURE: OUT_CHANGED_DURING_READ'; Out2 'RESULT: FAIL'
    Out2 'REASON: the .out file changed between load and result packaging'; exit 1
}

# ---------- parse samples ----------
$ts = @{}
foreach ($line in $dout) { if ([string]$line -match '^TS (\d+) = (\d+)$') { $ts[[int]$Matches[1]] = [long]$Matches[2] } }
$samples = @{}
foreach ($line in $varLines) {
    if ([string]$line -match '^VAR (.+?)@T(\d+) = (.*)$') {
        $n = $Matches[1]; $r = [int]$Matches[2]; $v = $Matches[3]
        if (-not $samples.ContainsKey($r)) { $samples[$r] = [ordered]@{} }
        $samples[$r][$n] = $v
    }
}
$roundNums = @($samples.Keys | Sort-Object)
if ($roundNums.Count -ne $Rounds -or $ts.Count -ne $Rounds) {
    $rr = ("parsed {0}/{1} data rounds and {2}/{1} timestamps" -f $roundNums.Count, $Rounds, $ts.Count)
    Clear-StaleReadout
    Publish-Readout 'FAIL' $rr 'INCOMPLETE_ROUNDS'
    Out2 'FAILURE: INCOMPLETE_ROUNDS'; Out2 'RESULT: FAIL'; Out2 ("REASON: " + $rr); exit 1
}
for ($r = 1; $r -le $Rounds; $r++) {
    if (-not $samples.ContainsKey($r) -or -not $ts.ContainsKey($r) -or $samples[$r].Count -ne $names.Count -or
        @($names | Where-Object { -not $samples[$r].Contains($_) }).Count -gt 0 -or
        ($r -gt 1 -and $ts[$r] -le $ts[$r - 1])) {
        $rr = "round $r is missing, duplicated or has a non-increasing host timestamp"
        Clear-StaleReadout
        Publish-Readout 'FAIL' $rr 'INCOMPLETE_ROUNDS'
        Out2 'FAILURE: INCOMPLETE_ROUNDS'; Out2 'RESULT: FAIL'; Out2 ("REASON: " + $rr); exit 1
    }
}

# ---------- data/data.csv ----------
$hbData = @{}
foreach ($line in $dout) {
    if ([string]$line -match '^HB (\S+) (\d+) = (.+)$') {
        $hn = $Matches[1]; $hr = [int]$Matches[2]; $hv = $Matches[3]
        if (-not $hbData.ContainsKey($hn)) { $hbData[$hn] = @{} }
        $hbData[$hn][$hr] = $hv
    }
}
$dataCols = @('round', 'hostMs', 'hostTime') + $names + @($hbData.Keys | Where-Object { $_ -notin $names } | Sort-Object)
$sw = New-Object System.IO.StreamWriter((Join-Path $dataDir 'data.csv'), $false, $utf8Bom)
try {
    $sw.WriteLine(($dataCols -join ','))
    foreach ($r in $roundNums) {
        $ms = if ($ts.ContainsKey($r)) { $ts[$r] } else { 0 }
        $vals = @($r, $ms, ([DateTimeOffset]::FromUnixTimeMilliseconds($ms)).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss.fff'))
        foreach ($n in ($dataCols | Select-Object -Skip 3)) {
            $v = if ($samples[$r].Contains($n)) { [string]$samples[$r][$n] } elseif ($hbData.ContainsKey($n) -and $hbData[$n].ContainsKey($r)) { [string]$hbData[$n][$r] } else { '' }
            $v = $v.Replace('"', '""')
            if ($v -match '[,"\r\n]') { $v = '"' + $v + '"' }
            $vals += $v
        }
        $sw.WriteLine(($vals -join ','))
    }
} finally { $sw.Dispose() }

$dataReadme = @(
    '本文件夹存放实际读到的数据。',
    '  data.csv  宽表：round(轮次), hostMs(主机时间戳), hostTime(可读时间), 以及每个被读变量的列'
)
[IO.File]::WriteAllLines((Join-Path $dataDir 'README.txt'), $dataReadme, $utf8Bom)

# ---------- heartbeat verdict + check/variables.csv (all candidates) ----------
$hbStatus = 'SKIPPED'
$hbOk = $true
$hbFailed = @()
$mapLines = @('role,name,first,last,delta,status')
if ($hbData.Count -gt 0) {
    foreach ($hn in ($hbData.Keys | Sort-Object)) {
        $roundsOfHb = @($hbData[$hn].Keys | Sort-Object)
        $first = $hbData[$hn][$roundsOfHb[0]]
        $last = $hbData[$hn][$roundsOfHb[-1]]
        $candidateOk = $true
        if ($roundsOfHb.Count -lt 2) {
            $mapLines += ('heartbeat,{0},{1},{2},{3},{4}' -f $hn, $first, $first, 0, 'SKIPPED(need -Rounds>=2)')
            continue
        }
        $bad = 0
        for ($i = 1; $i -lt $roundsOfHb.Count; $i++) {
            $prev = 0.0; $cur = 0.0
            $prevOk = [double]::TryParse([string]$hbData[$hn][$roundsOfHb[$i - 1]], [ref]$prev)
            $curOk = [double]::TryParse([string]$hbData[$hn][$roundsOfHb[$i]], [ref]$cur)
            $advanced = $prevOk -and $curOk -and $cur -gt $prev
            if ($advanced) { $bad = 0; continue }
            $bad++
            Out2 ("CHECK heartbeat {0}: round {1} not increasing ({2} -> {3})" -f $hn, ($i + 1), $hbData[$hn][$roundsOfHb[$i - 1]], $hbData[$hn][$roundsOfHb[$i]])
            if ($bad -ge 2 -or $roundsOfHb.Count -eq 2 -or -not $prevOk -or -not $curOk) { $candidateOk = $false }
        }
        $delta = 0
        $f = 0.0; $l = 0.0
        if ([double]::TryParse([string]$first, [ref]$f) -and [double]::TryParse([string]$last, [ref]$l)) { $delta = $l - $f }
        if (-not $candidateOk) { $hbOk = $false; $hbFailed += $hn }
        $mapLines += ('heartbeat,{0},{1},{2},{3},{4}' -f $hn, $first, $last, $delta, $(if ($candidateOk) { 'OK' } else { 'FAIL' }))
    }
    $hbStatus = if ($hbOk) { 'OK' } else { 'FAIL' }
    if ($hbOk) { Out2 'HEARTBEAT: OK (all candidates increased)' } else { Out2 'HEARTBEAT: FAIL' }
} else {
    $mapLines += ('heartbeat,{0},{1},{2},{3},{4}' -f '', '', '', '', 'SKIPPED(-NoHeartbeat)')
}
[IO.File]::WriteAllLines((Join-Path $checkDir 'variables.csv'), $mapLines, $utf8Bom)

$checkReadme = @(
    '本文件夹存放校验与判据，用于确认数据可信，不参与数据处理。',
    '  variables.csv  校验变量映射：role(角色), name(变量名), first(首值), last(末值), delta(增量), status(判据状态)',
    '  verdict.txt    判据结论：固件 SHA256、读取模式、轮数/间隔、变量列表、心跳状态、数据文件路径'
)
[IO.File]::WriteAllLines((Join-Path $checkDir 'README.txt'), $checkReadme, $utf8Bom)

$readme = @(
    'TI C2000 readout',
    '================',
    '',
    '本目录由 ti_c2000_run_read.ps1 自动生成：一次"运行并读取"的结果。',
    '',
    'check/   校验与判据（辅助确认数据可信，不参与数据处理）',
    '  variables.csv  校验变量映射：role(角色), name(变量名), first(首值), last(末值), delta(增量), status(判据状态)',
    '  verdict.txt    判据结论：固件 SHA256、读取模式、轮数/间隔、变量列表、心跳状态、数据文件路径',
    '',
    'data/    实际读到的数据',
    '  data.csv       宽表：round(轮次), hostMs(主机时间戳), hostTime(可读时间), 以及每个被读变量的列'
)
[IO.File]::WriteAllLines((Join-Path $runDir 'README.txt'), $readme, $utf8Bom)



Out2 ("DATA    : {0}" -f (Join-Path $dataDir 'data.csv'))
Out2 ("CHECK   : {0}" -f (Join-Path $checkDir 'variables.csv'))
Out2 ("VERDICT : {0}" -f (Join-Path $checkDir 'verdict.txt'))
Out2 ("VALUES  : {0}" -f $varLines.Count)
if (-not $hbOk) {
    $hbReason = 'heartbeat did not meet liveness criterion'
    if ($hbFailed.Count -gt 0) { $hbReason += ' (not increasing: ' + ($hbFailed -join ', ') + ')' }
    Publish-Readout 'FAIL' $hbReason 'HEARTBEAT_FAIL'
    Out2 'FAILURE: HEARTBEAT_FAIL'; Out2 ('REASON: ' + $hbReason); Out2 'RESULT: FAIL'; exit 1
}

# ---------- mandatory verdict: no read may return OK without it ----------
$verdictScript = Join-Path $PSScriptRoot 'ti_c2000_check_read.ps1'
if (-not (Test-Path -LiteralPath $verdictScript)) {
    Publish-Readout 'FAIL' 'mandatory verdict script missing' 'MISSING'
    Out2 'FAILURE: ENV_NO_VERDICT_SCRIPT'; Out2 'RESULT: FAIL'
    Out2 'REASON: ti_c2000_check_read.ps1 is missing; reads are not allowed without the verdict'; exit 2
}
$vargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verdictScript,
           '-CsvPath', (Join-Path $dataDir 'data.csv'), '-StartupMaxMs', [string]$StartupMaxMs,
           '-CheckStartupWindow', '-RangeVars', ($names -join ','))
if ($hbData.Count -gt 0) {
    $vargs += @('-HeartbeatVars', (($hbData.Keys | Sort-Object) -join ','))
} else {
    $vargs += '-AllowNoHeartbeat'
}
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
$vout = & $pwshExe @vargs 2>&1
$vcode = $LASTEXITCODE
foreach ($l in $vout) { if ([string]$l -notmatch '^RESULT:') { Out2 ([string]$l) } }
if ($vcode -ne 0 -or -not @($vout | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
    Publish-Readout 'FAIL' 'mandatory CSV verdict failed' 'FAIL'
    Out2 'FAILURE: VERDICT_FAILED'
    Out2 'REASON: data.csv did not pass the mandatory verdict (references/data-read-verdict.md)'
    Out2 'RESULT: FAIL'
    exit 1
}

Publish-Readout 'OK' 'mandatory CSV verdict passed' 'OK'
Out2 'RESULT: OK'
exit 0
