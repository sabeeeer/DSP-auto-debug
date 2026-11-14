#requires -Version 7.0
<#
ti_c2000_read_dma.ps1 -- read a firmware-frozen RAM buffer in the same DSS
session that loads and runs the program. The buffer may be filled by DMA or ISR.

PRECONDITION:
  The firmware must fill a RAM array and stop writing it when the frozen flag
  is set. A sequence counter is recommended when the buffer can be rearmed.
  Pass -FrozenBufferReady after checking the actual firmware; -DmaReady is kept
  as a compatible alias for projects that really use DMA.

Why one session: on targets that reset when JTAG closes (F28379D), a separate
read-only call cannot work. This loads + runs + waits for the freeze + reads
the frozen buffer inside ONE session.

Verdict (same rules as references/data-read-verdict.md, independent of mode):
  BUF_NOT_READY / NO_SEQ / BUF_CHANGED / COUNT_MISMATCH / VALUE_OUT_OF_RANGE
The point-mode array reader (ti_c2000_read_array_runtime.ps1) needs no DMA and
remains available for short captures.

Exit code: 0 OK | 1 failure | 2 argument/environment | 3 no probe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$ArrayName,
    [int]$Rows = 1,
    [int]$Columns = 1,
    [string]$FrozenFlag = 'gBufFull',
    [string]$FrozenValue = '1',
    [string]$SeqVar = 'gBufSeq',
    [switch]$FrozenBufferReady,
    [switch]$DmaReady,
    [string[]]$Variables = @(),
    [string]$HeartbeatExpr = 'gMsTick,gRunMs,usMainLoop',
    [string]$OutRoot = '',
    [string]$OutputPath = '',
    [int]$WaitMs = 10000,
    [Nullable[double]]$ValueMin = $null,
    [Nullable[double]]$ValueMax = $null,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    [string]$CorePattern = '.*C28xx(?:_CPU1)?$',
    [int]$TimeoutSec = 600,
    [switch]$Build,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

if (-not ($FrozenBufferReady -or $DmaReady)) {
    Out2 'FAILURE: BUFFER_NOT_CONFIRMED'
    Out2 'RESULT: FAIL'
    Out2 'REASON: confirm the firmware fills and freezes this RAM buffer, then pass -FrozenBufferReady'
    exit 2
}
$pathPattern = '[A-Za-z_][A-Za-z0-9_]*(?:(?:\.|->)[A-Za-z_][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]*)\])*'
$heartbeats = @($HeartbeatExpr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$extraNames = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($ArrayName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or
    $FrozenFlag -notmatch "^$pathPattern$" -or $FrozenValue -notmatch '^(?:true|[1-9][0-9]*)$' -or
    ($SeqVar -and $SeqVar -notmatch "^$pathPattern$") -or
    $heartbeats.Count -eq 0 -or @($heartbeats | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    @($extraNames | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    $WaitMs -lt 1) {
    Out2 'FAILURE: INVALID_READ_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: use a simple array/flag/counter name, valid heartbeat candidates and positive wait time'; exit 2
}
if ($Rows -lt 1 -or $Columns -lt 1) { Out2 'FAILURE: BAD_DIMENSIONS'; Out2 'RESULT: FAIL'; Out2 'REASON: Rows/Columns must be positive'; exit 2 }
if ($null -ne $ValueMin -and $null -ne $ValueMax -and $ValueMin -gt $ValueMax) {
    Out2 'FAILURE: BAD_VALUE_RANGE'; Out2 'RESULT: FAIL'; Out2 'REASON: ValueMin exceeds ValueMax'; exit 2
}
$total = [long]$Rows * [long]$Columns
if ($total -gt 100000) { Out2 'FAILURE: ARRAY_TOO_LARGE'; Out2 'RESULT: FAIL'; Out2 'REASON: one capture is limited to 100000 values'; exit 2 }

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
    foreach ($line in $bout) { if (-not $Quiet) { Out2 ([string]$line) } }
    if ($bcode -ne 0 -or -not @($bout | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
        $bfail = @($bout | Where-Object { $_ -match '^FAILURE: ' }) | Select-Object -First 1
        if (-not $bfail) { $bfail = 'FAILURE: BUILD_FAILED' }
        Out2 $bfail; Out2 'RESULT: FAIL'; Out2 'REASON: build failed - DMA read aborted'; exit 1
    }
}
if (-not (Test-Path -LiteralPath $OutFile)) { Out2 'FAILURE: NO_OUT_FILE'; Out2 'RESULT: FAIL'; Out2 "REASON: '$OutFile' not found - add -Build or build/stage first"; exit 2 }
$outShaBefore = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
# Create the readout only after preflight, build and .out resolution succeed.
# One fixed folder; each read refreshes check/ and data/ in place.
if (-not $OutRoot) { $OutRoot = $ProjectPath }
$runDir = Join-Path $OutRoot 'readout'
$dataDir = Join-Path $runDir 'data'
$checkDir = Join-Path $runDir 'check'
New-Item -ItemType Directory -Force -Path $dataDir, $checkDir | Out-Null
$extraOutputPath = $OutputPath
$OutputPath = Join-Path $dataDir 'array.csv'
if ($extraOutputPath -and (Test-Path -LiteralPath $extraOutputPath)) {
    Out2 'FAILURE: OUTPUT_EXISTS'; Out2 'RESULT: FAIL'
    Out2 "REASON: refusing to overwrite '$extraOutputPath' before loading the target"; exit 2
}
$extraOutputParent = if ($extraOutputPath) { Split-Path -Path $extraOutputPath -Parent } else { '' }
if ($extraOutputPath -and -not $extraOutputParent) { $extraOutputParent = (Get-Location).Path }
if ($extraOutputPath -and -not (Test-Path -LiteralPath $extraOutputParent -PathType Container)) {
    Out2 'FAILURE: NO_OUTPUT_DIR'; Out2 'RESULT: FAIL'
    Out2 "REASON: parent of '$extraOutputPath' does not exist"; exit 2
}

# ---------------------------------------------------------------------------
# failed-read publisher, defined before the first possible read failure so a
# failed DMA read never leaves the previous run's "result: OK" verdict and its
# array.csv behind. Only the last RESULT line of this run decides usability.
# ---------------------------------------------------------------------------
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$verdictPath = Join-Path $checkDir 'verdict.txt'
function Fail-Readout([string]$code, [string]$reason) {
    foreach ($f in @($OutputPath, (Join-Path $dataDir 'variables.csv'), (Join-Path $checkDir 'variables.csv'))) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
    $lines = @(
        'TI C2000 frozen-buffer readout',
        ('created   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('project   : ' + $ProjectPath),
        ('ccxml     : ' + $Ccxml),
        ('out       : ' + $OutFile),
        ('out sha256: ' + $outShaBefore),
        'mode      : single session, firmware-frozen RAM buffer',
        ('array     : {0} ({1} x {2})' -f $ArrayName, $Rows, $Columns),
        ('data csv  : ' + $OutputPath),
        'checker   : SKIPPED',
        'result    : FAIL',
        ('failure   : ' + $code),
        ('reason    : ' + $reason)
    )
    try { [IO.File]::WriteAllLines($verdictPath, $lines, $utf8Bom) } catch { }
}
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
Info2 "ARRAY   : $ArrayName ($Rows x $Columns = $total)"
Info2 "OUTPUT  : $OutputPath"

function Escape-Js([string]$v) { return $v.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n') }
$extraJs = ($extraNames | ForEach-Object { '"' + (Escape-Js $_) + '"' }) -join ','
$jsPath = Join-Path $env:TEMP ('ti_c2000_dma_{0}.js' -f (Get-Random))
$js = @"
importPackage(Packages.com.ti.debug.engine.scripting);
importPackage(Packages.com.ti.ccstudio.scripting.environment);
importPackage(Packages.java.lang);

var CCXML  = "$(Escape-Js $Ccxml)";
var OUT    = "$(Escape-Js $OutFile)";
var ARRAY  = "$(Escape-Js $ArrayName)";
var ROWS   = $Rows;
var COLS   = $Columns;
var FROZEN = "$(Escape-Js $FrozenFlag)";
var FROZEN_EXPECTED = "$(Escape-Js $FrozenValue)";
var SEQ    = "$(Escape-Js $SeqVar)";
var WAIT   = $WaitMs;
var CORE   = "$(Escape-Js $CorePattern)";
var HB_CANDS = "$(Escape-Js $HeartbeatExpr)".split(",");
var EXTRAS = [$extraJs];

function sleepMs(ms) { java.lang.Thread.sleep(ms); }
function flagMatches(value) {
    var actual = ("" + value).toLowerCase();
    if (actual === FROZEN_EXPECTED.toLowerCase()) { return true; }
    var a = Number(actual), expected = Number(FROZEN_EXPECTED);
    return !isNaN(a) && !isNaN(expected) && a === expected;
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
sleepMs(300);
if (session.target.isHalted()) { print("FAILURE: TARGET_HALTED_AFTER_RUN"); print("RESULT: FAIL"); throw "target halted after run"; }
var hbNames = [];
var hbBefore = {};
for (var h = 0; h < HB_CANDS.length; h++) {
    var hbName = HB_CANDS[h].replace(/^\s+|\s+$/g, "");
    if (hbName.length === 0) { continue; }
    try {
        hbBefore[hbName] = Number(session.expression.evaluate(hbName));
        if (isFinite(hbBefore[hbName])) { hbNames.push(hbName); }
    } catch (eH) { }
}
if (hbNames.length === 0) { print("FAILURE: NO_HEARTBEAT"); print("RESULT: FAIL"); throw "no application heartbeat"; }

/* wait for the firmware to freeze the capture */
var frozen = false;
var waited = 0;
var lastFlag = "";
while (waited < WAIT) {
    if (session.target.isHalted()) { print("FAILURE: TARGET_HALTED_DURING_READ"); print("RESULT: FAIL"); throw "target halted while waiting for buffer"; }
    try {
        lastFlag = "" + session.expression.evaluate(FROZEN);
        if (flagMatches(lastFlag)) { frozen = true; break; }
    } catch (eF) {
        print("FAILURE: NO_FROZEN_FLAG");
        print("REASON: cannot read '" + FROZEN + "': " + eF);
        print("RESULT: FAIL");
        throw "frozen flag unreadable";
    }
    sleepMs(100); waited += 100;
}
if (!frozen) {
    print("FAILURE: BUF_NOT_READY");
    print("REASON: '" + FROZEN + "' did not reach " + FROZEN_EXPECTED + " within " + WAIT + " ms; last=" + lastFlag);
    print("RESULT: FAIL");
    throw "buffer not ready";
}
print("DSS: frozen after " + waited + " ms, " + FROZEN + " = " + lastFlag);
for (var ex = 0; ex < EXTRAS.length; ex++) {
    try { print("EXTRA " + EXTRAS[ex] + " before = " + session.expression.evaluate(EXTRAS[ex])); }
    catch (eX) { print("FAILURE: EXTRA_READ_FAILED"); print("REASON: " + EXTRAS[ex] + ": " + eX); print("RESULT: FAIL"); throw "extra read failed"; }
}

var seqBefore = "";
if (SEQ.length > 0) {
    try { seqBefore = "" + session.expression.evaluate(SEQ); }
    catch (eS) { print("FAILURE: NO_SEQ"); print("REASON: cannot read '" + SEQ + "': " + eS); print("RESULT: FAIL"); throw "seq unreadable"; }
    print("DSS: seq before = " + seqBefore);
}

var base = null;
try { base = Number(session.symbol.getAddress(ARRAY)); } catch (eB) { base = null; }
if (base === null || base === undefined || isNaN(base)) {
    print("FAILURE: NO_ARRAY");
    print("REASON: cannot resolve address of '" + ARRAY + "'");
    print("RESULT: FAIL");
    throw "array address unresolved";
}
print("DSS: array base = " + base);

var total = ROWS * COLS;
var anchorIndex = [0, total - 1];
if (ROWS > 1) { anchorIndex.push(COLS); }
var anchorValues = {};
for (var offset = 0; offset < total; offset += 2000) {
    if (session.target.isHalted()) { print("FAILURE: TARGET_HALTED_DURING_READ"); print("RESULT: FAIL"); throw "target halted during read"; }
    var count = Math.min(2000, total - offset);
    var vals = null;
    try { vals = session.memory.readData(1, base + offset, 16, count); }
    catch (eR) { print("FAILURE: READDATA_ERROR"); print("REASON: " + eR); print("RESULT: FAIL"); throw "readData failed"; }
    if (vals === null || vals === undefined || vals.length !== count) {
        print("FAILURE: COUNT_MISMATCH");
        print("REASON: readData returned " + (vals ? vals.length : 0) + ", expected " + count);
        print("RESULT: FAIL");
        throw "count mismatch";
    }
    for (var j = 0; j < count; j++) {
        var linear = offset + j;
        var row = Math.floor(linear / COLS);
        var column = linear % COLS;
        var name = ROWS === 1 ? ARRAY + "[" + column + "]" : ARRAY + "[" + row + "][" + column + "]";
        print("VAR " + name + " = " + vals[j]);
        for (var ai = 0; ai < anchorIndex.length; ai++) {
            if (linear === anchorIndex[ai]) { anchorValues[linear] = Number(vals[j]); }
        }
    }
    print("BATCH: " + (Math.floor(offset / 2000) + 1) + " values=" + count + " endIndex=" + (offset + count - 1));
    if (session.target.isHalted()) { print("FAILURE: TARGET_HALTED_DURING_READ"); print("RESULT: FAIL"); throw "target halted during read"; }
}
for (var a = 0; a < anchorIndex.length; a++) {
    var ix = anchorIndex[a];
    var ar = Math.floor(ix / COLS), ac = ix % COLS;
    var expr = ROWS === 1 ? ARRAY + "[" + ac + "]" : ARRAY + "[" + ar + "][" + ac + "]";
    var expressionValue = Number(session.expression.evaluate(expr));
    if (isNaN(expressionValue) || isNaN(anchorValues[ix]) ||
        (expressionValue & 0xFFFF) !== (anchorValues[ix] & 0xFFFF)) {
        print("FAILURE: ARRAY_LAYOUT_MISMATCH");
        print("REASON: " + expr + " evaluate=" + expressionValue + " readData=" + anchorValues[ix]);
        print("RESULT: FAIL");
        throw "array layout or data format mismatch";
    }
}
print("DSS: readData anchors matched expressions");

var finalFlag = "";
try { finalFlag = "" + session.expression.evaluate(FROZEN); }
catch (eF2) { print("FAILURE: NO_FROZEN_FLAG"); print("REASON: post-read flag: " + eF2); print("RESULT: FAIL"); throw "frozen flag unreadable after read"; }
print("DSS: frozen after read = " + finalFlag);
if (!flagMatches(finalFlag)) {
    print("FAILURE: BUF_CHANGED"); print("REASON: frozen flag changed during read (" + lastFlag + " -> " + finalFlag + ")");
    print("RESULT: FAIL"); throw "buffer no longer frozen";
}

if (SEQ.length > 0) {
    var seqAfter = "";
    try { seqAfter = "" + session.expression.evaluate(SEQ); }
    catch (eS2) { print("FAILURE: NO_SEQ"); print("REASON: " + eS2); print("RESULT: FAIL"); throw "seq unreadable"; }
    print("DSS: seq after = " + seqAfter);
    if (seqAfter !== seqBefore) {
        print("FAILURE: BUF_CHANGED");
        print("REASON: '" + SEQ + "' changed while reading (" + seqBefore + " -> " + seqAfter + ")");
        print("RESULT: FAIL");
        throw "buffer changed";
    }
}

for (var ex2 = 0; ex2 < EXTRAS.length; ex2++) {
    try { print("EXTRA " + EXTRAS[ex2] + " after = " + session.expression.evaluate(EXTRAS[ex2])); }
    catch (eX2) { print("FAILURE: EXTRA_READ_FAILED"); print("REASON: " + EXTRAS[ex2] + ": " + eX2); print("RESULT: FAIL"); throw "extra read failed"; }
}
for (var h2 = 0; h2 < hbNames.length; h2++) {
    var hName = hbNames[h2];
    var hAfter = Number(session.expression.evaluate(hName));
    print("HB " + hName + " before = " + hbBefore[hName]);
    print("HB " + hName + " after = " + hAfter);
    if (!isFinite(hAfter) || hAfter <= hbBefore[hName]) {
        print("FAILURE: HEARTBEAT_NOT_ADVANCING"); print("RESULT: FAIL"); throw "application heartbeat did not advance";
    }
}
print("DSS: target still running before disconnect");
session.target.disconnect();
print("DSS: disconnected");
print("RESULT: OK");
"@
[IO.File]::WriteAllText($jsPath, $js, [Text.Encoding]::ASCII)
Info2 "JS      : $jsPath"

$dout = & cmd.exe /d /c $dss $jsPath 2>&1
$dcode = $LASTEXITCODE
foreach ($line in $dout) { if ($line -match '^(DSS:|VAR |EXTRA |BATCH:|CONNECT_RETRY|FAILURE)') { Out2 ([string]$line) } }
Remove-Item -LiteralPath $jsPath -Force -ErrorAction SilentlyContinue

$text = (@($dout | ForEach-Object { [string]$_ }) -join "`n")
$hbBefore = [ordered]@{}
$hbAfter = [ordered]@{}
$extraBefore = [ordered]@{}
$extraAfter = [ordered]@{}
foreach ($line in $dout) {
    if ([string]$line -match '^HB\s+(\S+)\s+(before|after)\s+=\s+(.+)$') {
        if ($Matches[2] -eq 'before') { $hbBefore[$Matches[1]] = $Matches[3] }
        else { $hbAfter[$Matches[1]] = $Matches[3] }
    }
    if ([string]$line -match '^EXTRA\s+(\S+)\s+(before|after)\s+=\s+(.+)$') {
        if ($Matches[2] -eq 'before') { $extraBefore[$Matches[1]] = $Matches[3] }
        else { $extraAfter[$Matches[1]] = $Matches[3] }
    }
}
$varLines = @($dout | Where-Object { $_ -match '^VAR .+ = ' -and $_ -notmatch '<ERROR' })
if ($dcode -ne 0 -or $text -notmatch 'RESULT: OK' -or $varLines.Count -ne $total -or
    $text -notmatch 'DSS: frozen after read = ' -or
    $hbBefore.Count -eq 0 -or $hbAfter.Count -ne $hbBefore.Count -or
    $extraBefore.Count -ne $extraNames.Count -or $extraAfter.Count -ne $extraNames.Count) {
    $failCode = 'DMA_READ_INCOMPLETE'; $failReason = ("values={0}/{1}" -f $varLines.Count, $total)
    # The DSS script names its own failure; keep that identity instead of
    # guessing from keywords (NO_FROZEN_FLAG, TARGET_HALTED_*, ... all count).
    $jsFail = @($dout | Where-Object { [string]$_ -match '^FAILURE: [A-Z0-9_]+' }) | Select-Object -First 1
    if ($jsFail -and ([string]$jsFail -match '^FAILURE: ([A-Z0-9_]+)')) {
        $failCode = $Matches[1]
        $jsReason = @($dout | Where-Object { [string]$_ -match '^REASON: ' }) | Select-Object -First 1
        if ($jsReason -and ([string]$jsReason -match '^REASON: (.+)$')) { $failReason = $Matches[1] }
        else { $failReason = 'see the DSS failure above' }
    }
    elseif ($text -match 'BUF_NOT_READY') { $failCode = 'BUF_NOT_READY'; $failReason = 'frozen flag never asserted' }
    elseif ($text -match 'BUF_CHANGED') { $failCode = 'BUF_CHANGED'; $failReason = 'sequence changed during the read' }
    elseif ($text -match 'NO_SEQ') { $failCode = 'NO_SEQ'; $failReason = 'sequence counter unreadable' }
    elseif ($text -match 'COUNT_MISMATCH') { $failCode = 'COUNT_MISMATCH'; $failReason = 'readData returned the wrong count' }
    elseif ($text -match 'NO_ARRAY') { $failCode = 'NO_ARRAY'; $failReason = 'array symbol not found' }
    elseif ($text -match 'ARRAY_LAYOUT_MISMATCH') { $failCode = 'ARRAY_LAYOUT_MISMATCH'; $failReason = 'readData disagreed with expression anchors' }
    elseif ($text -match 'CONNECT_FAILED') { $failCode = 'CONNECT_FAILED'; $failReason = 'could not take over the target' }
    elseif ($text -match 'LOAD_FAILED') { $failCode = 'LOAD_FAILED'; $failReason = 'memory.loadProgram failed' }
    elseif ($text -match 'EXTRA_READ_FAILED' -or $extraBefore.Count -ne $extraNames.Count -or $extraAfter.Count -ne $extraNames.Count) { $failCode = 'EXTRA_READ_FAILED'; $failReason = 'requested scalar read was incomplete' }
    elseif ($text -match 'HEARTBEAT_NOT_ADVANCING') { $failCode = 'HEARTBEAT_NOT_ADVANCING'; $failReason = 'application counter did not advance during buffer read' }
    elseif ($hbBefore.Count -eq 0 -or $hbAfter.Count -ne $hbBefore.Count) { $failCode = 'NO_LIVENESS_EVIDENCE'; $failReason = 'heartbeat pair missing' }
    Fail-Readout $failCode $failReason
    Out2 ('FAILURE: ' + $failCode); Out2 ('REASON: ' + $failReason)
    foreach ($line in (@($dout | Where-Object { [string]$_ -notmatch '^RESULT:' }) | Select-Object -Last 8)) { Out2 ([string]$line) }
    Out2 'RESULT: FAIL'
    exit 1
}
foreach ($hbName in $hbBefore.Keys) {
    $before = 0.0; $after = 0.0
    $numericBefore = [double]::TryParse([string]$hbBefore[$hbName], [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$before)
    $numericAfter = $hbAfter.Contains($hbName) -and
        [double]::TryParse([string]$hbAfter[$hbName], [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$after)
    if (-not $numericBefore -or -not $numericAfter -or
        [double]::IsNaN($before) -or [double]::IsInfinity($before) -or
        [double]::IsNaN($after) -or [double]::IsInfinity($after) -or $after -le $before) {
        $rr = ("{0}: {1} -> {2} is not a finite increase" -f $hbName, $hbBefore[$hbName], $hbAfter[$hbName])
        Fail-Readout 'HEARTBEAT_NOT_ADVANCING' $rr
        Out2 'FAILURE: HEARTBEAT_NOT_ADVANCING'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $rr); exit 1
    }
}
if ((Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ne $outShaBefore) {
    Fail-Readout 'OUT_CHANGED_DURING_READ' 'the .out file changed between load and result packaging'
    Out2 'FAILURE: OUT_CHANGED_DURING_READ'; Out2 'RESULT: FAIL'
    Out2 'REASON: the .out file changed between load and result packaging'; exit 1
}

# ---------- write CSV ----------
$records = New-Object System.Collections.ArrayList
foreach ($line in $varLines) {
    if ([string]$line -match '^VAR\s+(.+?)\s+=\s+(.+)$') {
        $index = $records.Count
        $row = [int][Math]::Floor($index / $Columns)
        $column = [int]($index % $Columns)
        $expected = if ($Rows -eq 1) { '{0}[{1}]' -f $ArrayName, $column }
                    else { '{0}[{1}][{2}]' -f $ArrayName, $row, $column }
        if ($Matches[1] -cne $expected) {
            $rr = ("index {0} expected {1}, got {2}" -f $index, $expected, $Matches[1])
            Fail-Readout 'ARRAY_ORDER_MISMATCH' $rr
            Out2 'FAILURE: ARRAY_ORDER_MISMATCH'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $rr); exit 1
        }
        [void]$records.Add([pscustomobject]@{ expression = $Matches[1]; value = $Matches[2] })
    }
}
if ($records.Count -ne $total) {
    $rr = ("parsed {0}/{1}" -f $records.Count, $total)
    Fail-Readout 'PARSE_FAILED' $rr
    Out2 'FAILURE: PARSE_FAILED'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $rr); exit 1
}
foreach ($record in $records) {
    $numericValue = 0.0
    if (-not [double]::TryParse([string]$record.value, [ref]$numericValue) -or
        [double]::IsNaN($numericValue) -or [double]::IsInfinity($numericValue)) {
        $rr = ("{0} = {1}" -f $record.expression, $record.value)
        Fail-Readout 'VALUE_NOT_NUMERIC' $rr
        Out2 'FAILURE: VALUE_NOT_NUMERIC'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $rr); exit 1
    }
}
$records | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
$extraCsv = Join-Path $dataDir 'variables.csv'
if ($extraNames.Count -gt 0) {
    @($extraNames | ForEach-Object {
        [pscustomobject]@{ expression = $_; before = $extraBefore[$_]; after = $extraAfter[$_] }
    }) | Export-Csv -LiteralPath $extraCsv -NoTypeInformation -Encoding UTF8
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$dataReadme = @(
    '本文件夹存放实际读到的数据。',
    '  array.csv      长表：expression(元素表达式，如 gAdcBuf[0]), value(数值)',
    '  variables.csv  可选：同一 DSS 会话在数组搬运前后读取的标量'
)
[IO.File]::WriteAllLines((Join-Path $dataDir 'README.txt'), $dataReadme, $utf8Bom)

# ---------- verdict: count + range (level 3/4 of data-read-verdict.md) ----------
$rangeOk = $true
$minSeen = $null; $maxSeen = $null
if ($null -ne $ValueMin -or $null -ne $ValueMax) {
    foreach ($r in $records) {
        $d = 0.0
        if ([double]::TryParse([string]$r.value, [ref]$d)) {
            if ($null -eq $minSeen -or $d -lt $minSeen) { $minSeen = $d }
            if ($null -eq $maxSeen -or $d -gt $maxSeen) { $maxSeen = $d }
            if (($null -ne $ValueMin -and $d -lt $ValueMin) -or ($null -ne $ValueMax -and $d -gt $ValueMax)) { $rangeOk = $false }
        }
    }
}
Out2 'CHECK FROZEN: OK'
if ($SeqVar) { Out2 'CHECK SEQ: OK' } else { Out2 'CHECK SEQ: SKIPPED' }
Out2 ("CHECK COUNT: OK ({0})" -f $records.Count)
if ($null -eq $ValueMin -and $null -eq $ValueMax) {
    Out2 'CHECK RANGE: SKIPPED (no -ValueMin/-ValueMax)'
} elseif ($rangeOk) {
    Out2 ("CHECK RANGE: OK ({0} .. {1})" -f $minSeen, $maxSeen)
} else {
    Out2 ("CHECK RANGE: FAIL ({0} .. {1}, expected {2} .. {3})" -f $minSeen, $maxSeen, $ValueMin, $ValueMax)
}

# ---------- check/variables.csv + check/verdict.txt ----------
$frozenVal = ''; $frozenAfterVal = ''; $seqBefore = ''; $seqAfter = ''
if ($text -match 'DSS: frozen after [0-9]+ ms, .+ = (.+)') { $frozenVal = $Matches[1].Trim() }
if ($text -match 'DSS: frozen after read = (.+)') { $frozenAfterVal = $Matches[1].Trim() }
if ($text -match 'DSS: seq before = (.+)') { $seqBefore = $Matches[1].Trim() }
if ($text -match 'DSS: seq after = (.+)') { $seqAfter = $Matches[1].Trim() }
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$mapLines = @('role,name,first,last,delta,status')
$mapLines += ('frozen,{0},{1},{2},,OK' -f $FrozenFlag, $frozenVal, $frozenAfterVal)
$mapLines += ('sequence,{0},{1},{2},,{3}' -f $SeqVar, $seqBefore, $seqAfter, $(if ($seqBefore) { 'OK' } else { 'SKIPPED' }))
$mapLines += ('array,{0},,,{1},OK' -f $ArrayName, $records.Count)
foreach ($hbName in $hbBefore.Keys) {
    $mapLines += ('heartbeat,{0},{1},{2},{3},OK' -f $hbName, $hbBefore[$hbName], $hbAfter[$hbName], ([double]$hbAfter[$hbName] - [double]$hbBefore[$hbName]))
}
foreach ($extraName in $extraNames) {
    $mapLines += ('scalar,{0},{1},{2},,OK' -f $extraName, $extraBefore[$extraName], $extraAfter[$extraName])
}
[IO.File]::WriteAllLines((Join-Path $checkDir 'variables.csv'), $mapLines, $utf8Bom)

$verdict = @(
    'TI C2000 frozen-buffer readout',
    ('created   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('project   : ' + $ProjectPath),
    ('ccxml     : ' + $Ccxml),
    ('out       : ' + $OutFile),
    ('out sha256: ' + $outShaBefore),
    ('mode      : single session, firmware-frozen RAM buffer'),
    ('identity  : SAME_SESSION_LOAD (out hash stable)'),
    ('array     : {0} ({1} x {2})' -f $ArrayName, $Rows, $Columns),
    ('frozen    : {0} = {1} -> {2} (expected {3})' -f $FrozenFlag, $frozenVal, $frozenAfterVal, $FrozenValue),
    ('sequence  : {0}' -f $(if ($seqBefore) { "$seqBefore -> $seqAfter" } else { 'SKIPPED' })),
    ('values    : {0}' -f $records.Count),
    ('heartbeat : {0}' -f (@($hbBefore.Keys) -join ', ')),
    ('scalars   : {0}' -f ($extraNames -join ', ')),
    ('range     : ' + $(if ($null -eq $ValueMin -and $null -eq $ValueMax) { 'SKIPPED' } elseif ($rangeOk) { 'OK' } else { 'FAIL' })),
    ('data csv  : ' + $OutputPath)
)
[IO.File]::WriteAllLines((Join-Path $checkDir 'verdict.txt'), $verdict, $utf8Bom)

$checkReadme = @(
    '本文件夹存放校验与判据，用于确认数据可信，不参与数据处理。',
    '  variables.csv  校验变量映射：role, name, first, last, delta, status；不适用的数值留空',
    '  verdict.txt    判据结论：固件 SHA256、数组名/尺寸、冻结标志值、序号前后、点数、范围判据'
)
[IO.File]::WriteAllLines((Join-Path $checkDir 'README.txt'), $checkReadme, $utf8Bom)

$readme = @(
    'TI C2000 readout (frozen RAM buffer)',
    '==================================',
    '',
    '本目录由 ti_c2000_read_dma.ps1 自动生成：固件用 ISR 或 DMA 采满并冻结后，DSS 搬运整块缓冲。',
    '',
    'check/   校验与判据（辅助确认数据可信，不参与数据处理）',
    '  variables.csv  校验变量映射：role, name, first, last, delta, status；不适用的数值留空',
    '  verdict.txt    判据结论：固件 SHA256、数组名/尺寸、冻结标志值、序号前后、点数、范围判据',
    '',
    'data/    实际读到的数据',
    '  array.csv      长表：expression(元素表达式，如 gAdcBuf[0]), value(数值)',
    '  variables.csv  可选：同一会话的标量前后值'
)
[IO.File]::WriteAllLines((Join-Path $runDir 'README.txt'), $readme, $utf8Bom)

$verdictPath = Join-Path $checkDir 'verdict.txt'
function Publish-Readout([string]$result, [string]$reason, [string]$checker = 'SKIPPED') {
    try {
        [IO.File]::WriteAllLines($verdictPath, (@($verdict) + @("checker   : $checker", "result    : $result", "reason    : $reason")), $utf8Bom)
    } catch {
        Out2 'FAILURE: READOUT_PUBLISH_FAILED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: ' + $_.Exception.Message); exit 1
    }
}

Out2 ("OUTDIR  : {0}" -f $runDir)
Out2 ("DATA    : {0}" -f $OutputPath)
Out2 ("CHECK   : {0}" -f (Join-Path $checkDir 'variables.csv'))
Out2 ("VERDICT : {0}" -f (Join-Path $checkDir 'verdict.txt'))
Out2 ("VALUES  : {0}" -f $records.Count)

# ---------- mandatory verdict: no read may return OK without it ----------
$verdictScript = Join-Path $PSScriptRoot 'ti_c2000_check_read.ps1'
if (-not (Test-Path -LiteralPath $verdictScript)) {
    Publish-Readout 'FAIL' 'mandatory verdict script missing' 'MISSING'
    Out2 'FAILURE: ENV_NO_VERDICT_SCRIPT'; Out2 'RESULT: FAIL'
    Out2 'REASON: ti_c2000_check_read.ps1 is missing; reads are not allowed without the verdict'; exit 2
}
$vargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verdictScript,
           '-CsvPath', $OutputPath, '-AllowNoHeartbeat', '-ExpectedRows', [string]$records.Count,
           '-RangeVars', 'value')
if ($null -ne $ValueMin -or $null -ne $ValueMax) {
    if ($null -ne $ValueMin) { $vargs += @('-ValueMin', [string]$ValueMin) }
    if ($null -ne $ValueMax) { $vargs += @('-ValueMax', [string]$ValueMax) }
}
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
$vout = & $pwshExe @vargs 2>&1
$vcode = $LASTEXITCODE
foreach ($l in $vout) { if ([string]$l -notmatch '^RESULT:') { Out2 ([string]$l) } }
if ($vcode -ne 0 -or -not @($vout | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count -or -not $rangeOk) {
    Publish-Readout 'FAIL' 'mandatory array verdict or range check failed' 'FAIL'
    Out2 'FAILURE: VERDICT_FAILED'
    Out2 'REASON: array.csv did not pass the mandatory verdict (references/data-read-verdict.md)'
    Out2 'RESULT: FAIL'
    exit 1
}

if ($extraOutputPath) {
    try {
        Copy-Item -LiteralPath $OutputPath -Destination $extraOutputPath -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $extraOutputPath -Algorithm SHA256).Hash) { throw 'extra output differs' }
        Out2 ("EXTRA   : {0}" -f $extraOutputPath)
    } catch {
        Publish-Readout 'FAIL' ('extra output failed: ' + $_.Exception.Message)
        Out2 'FAILURE: EXTRA_OUTPUT_FAILED'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $_.Exception.Message); exit 1
    }
}
Publish-Readout 'OK' 'mandatory array verdict passed' 'OK'
Out2 'RESULT: OK'
exit 0
