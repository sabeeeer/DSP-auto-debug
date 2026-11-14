#requires -Version 7.0
<#
ti_c2000_service.ps1 -- the ONE place that loads. RUN MODE decides how often.

Why this exists: every read needs the JTAG session that loaded the RAM image. A
script that connects -> loads -> reads -> disconnects re-flashes the target on
every call, so two consecutive reads never describe the same running program.
Instead the load happens ONCE here, the session is kept open, and each read
(ti_c2000_run_read.ps1 / ti_c2000_read_dma.ps1) is a request against that live
session: no reload, no reset, no re-download.

  start : connect -> reset -> loadProgram -> runAsynch -> wait for requests
  read  : write cmd.txt, read res.txt (see ti_c2000_live_read.ps1)
  stop  : write STOP; the DSS script disconnects and exits

RUN MODE (two, see ti_c2000_readmode.ps1):
  SingleStep (default) - load once, run forever, read many. A load restarts the
      program and wears the target, so it happens only after a human said yes:
      -Start needs -ConfirmLoad (ask "是否编译下载并运行" first). A second -Start
      while it runs is a no-op: it reports ALREADY_RUNNING and downloads nothing.
  Iterate - continuous; driven by ti_c2000_iterate.ps1 -UserApproved, which stops
      this session, starts it again with -Build -RunMode Iterate, reads, checks
      -Expect and repeats. Inside an iterate loop this script is off limits to
      everyone else (ITERATE_IN_PROGRESS).

Reads are not part of this script. ti_c2000_run_read.ps1 / ti_c2000_read_dma.ps1
attach to the live session (ReadOnly, no download) or download once themselves
(LoadRead, see ti_c2000_readmode.ps1). The target lock keeps a download and a read
from overlapping.

Every successful load increments <project>\readout\load-count.json, so the output
says "LOAD #N" and a runaway reload loop is visible immediately.

State lives in <project>\readout\.service\:
  state.json   pid / out / outSha256 / started / loadIndex (identity of the image)
  ready.txt    written after runAsynch; its presence + a live pid == service up
  cmd.txt      request queue (one file at a time)
  res.txt      response for the last request
  server.log   DSS stdout/stderr

Exit code: 0 OK | 1 runtime failure | 2 environment/argument problem
           3 no probe | 4 load not confirmed by the user | 5 target held elsewhere
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [switch]$Start,
    [switch]$Stop,
    [switch]$Status,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    [string]$CorePattern = '.*C28xx(?:_CPU1)?$',
    [switch]$Build,
    # set this only after the user answered yes to "compile/download and run?"
    [switch]$ConfirmLoad,
    # SingleStep = load once and stay (default). Iterate = continuous, driven by
    # ti_c2000_iterate.ps1 -UserApproved, which passes -RunMode Iterate every round.
    # no [ValidateSet]: an illegal value must reach Resolve-RunModeSpec, which reports
    # FAILURE: INVALID_RUN_MODE (exit 2). A binding-time rejection exits 1 with an English
    # message, and the documented classification would be unreachable.
    [string]$RunMode = 'SingleStep',
    [switch]$UserApproved,
    [int]$StartTimeoutSec = 90,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }
. (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')

$modes = @($Start, $Stop, $Status) | Where-Object { $_ }
if ($modes.Count -ne 1) {
    Out2 'FAILURE: NEED_MODE'; Out2 'RESULT: FAIL'
    Out2 'REASON: pass exactly one of -Start / -Stop / -Status'; exit 2
}

if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) {
    Out2 'FAILURE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName

# ---- identity + hygiene ------------------------------------------------------
# -Start writes the target, so a stale copy of a skill script inside the project is a
# hard refusal there (that copy is what would decide the download); -Stop/-Status only
# report it. Either way the run is stamped into readout\skill-runs.jsonl, which is how
# a later check can prove the operation came from this skill.
if ($Start) {
    Initialize-SkillRun -ProjectPath $ProjectPath -Script 'ti_c2000_service.ps1' -Mode 'Start' -Block -Quiet:$Quiet
} elseif ($Stop) {
    Initialize-SkillRun -ProjectPath $ProjectPath -Script 'ti_c2000_service.ps1' -Mode 'Stop' -Quiet:$Quiet
} else {
    Initialize-SkillRun -ProjectPath $ProjectPath -Script 'ti_c2000_service.ps1' -Mode 'Status'
}

# ---- run mode ----------------------------------------------------------------
# SingleStep (default) or Iterate (continuous, only via ti_c2000_iterate.ps1).
# -Status is pure reporting and stays available; Start/Stop must not fight a
# running iterate loop over the same target.
$runSpec = Resolve-RunModeSpec -RunMode $RunMode -ConfirmLoad:$ConfirmLoad -UserApproved:$UserApproved -MaxLoads 1
if (-not $Status) {
    $opName = if ($Start) { 'service -Start' } else { 'service -Stop' }
    Assert-RunModeInterlock -ProjectPath $ProjectPath -What $opName
}

$svcDir = Join-Path $ProjectPath 'readout\.service'
$stateFile = Join-Path $svcDir 'state.json'
$readyFile = Join-Path $svcDir 'ready.txt'
$stoppedFile = Join-Path $svcDir 'stopped.txt'
$errorFile = Join-Path $svcDir 'error.txt'
$cmdFile = Join-Path $svcDir 'cmd.txt'
$resFile = Join-Path $svcDir 'res.txt'
$logFile = Join-Path $svcDir 'server.log'

function Get-ServiceState {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try { return (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json) } catch { return $null }
}
function Test-ServiceAlive {
    $st = Get-ServiceState
    if (-not $st) { return $false }
    if (-not (Test-Path -LiteralPath $readyFile)) { return $false }
    if (Test-Path -LiteralPath $stoppedFile) { return $false }
    $p = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    return $true
}

$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

# ---------------------------------------------------------------- status -----
if ($Status) {
    $st = Get-ServiceState
    $cnt = Get-LoadCount -ProjectPath $ProjectPath
    if (Test-ServiceAlive) {
        # sessions started before the counter existed have no loadIndex; if the
        # image matches the last counted download we can still name it
        $idx = $st.loadIndex
        if (-not $idx -and $st.outSha256 -and $st.outSha256 -eq $cnt.lastSha256) { $idx = $cnt.count }
        Out2 ('SERVICE : RUNNING (pid {0}, since {1})' -f $st.pid, $st.started)
        $rm = if ($st.runMode) { [string]$st.runMode } else { 'SingleStep' }
        # runMode=Iterate in the state file only means "a loop put this image here"; whether
        # a loop is running NOW is the marker's job (see Get-RunModeInfo)
        $miLive = Get-RunModeInfo -ProjectPath $ProjectPath
        $rmText = if ($miLive.active) { 'Iterate (continuous - a loop owns the target)' }
                  elseif ($rm -eq 'Iterate') { 'SingleStep (image left by a finished continuous run; reads attach)' }
                  else { 'SingleStep (load once, run forever; reads attach)' }
        Out2 ('RUN MODE: {0}' -f $rmText)
        Out2 ('LOAD    : #' + $(if ($idx) { $idx } else { '?' }) + ' (this session)')
        Out2 ('LOADS   : #{0} total for this project, last at {1}' -f $cnt.count, $cnt.lastLoad)
        Out2 ('OUT     : {0}' -f $st.out)
        Out2 ('SHA256  : {0}' -f $st.outSha256)
        Out2 ('DIR     : {0}' -f $svcDir)
        Out2 'RESULT: OK'
        exit 0
    }
    $mi = Get-RunModeInfo -ProjectPath $ProjectPath
    Out2 'SERVICE : STOPPED'
    if ($mi.active) {
        Out2 ('RUN MODE: Iterate (continuous run in progress, pid {0}, round {1}/{2})' -f $mi.pid, $mi.round, $mi.maxLoads)
    } else {
        $lastRm = if ($cnt.lastMode -eq 'Iterate') { 'Iterate (last download was a continuous round)' } else { 'SingleStep' }
        Out2 ('RUN MODE: {0} - no session right now' -f $lastRm)
    }
    Out2 ('LOADS   : #{0} total for this project, last at {1}' -f $cnt.count, $cnt.lastLoad)
    if (Test-Path -LiteralPath $logFile) { Out2 ('LAST LOG: {0}' -f $logFile) }
    Out2 'RESULT: OK'
    exit 0
}

# ----------------------------------------------------------------- stop ------
if ($Stop) {
    if (-not (Test-ServiceAlive)) {
        foreach ($f in @($readyFile, $stateFile)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
        Out2 'SERVICE : ALREADY_STOPPED'
        Out2 'RESULT: OK'
        exit 0
    }
    $lk = Enter-TargetLock -ProjectPath $ProjectPath -Mode 'Stop'
    if (-not $lk.ok) { foreach ($l in $lk.message) { Out2 $l }; exit 5 }
    $st = Get-ServiceState
    # ask the DSS script to leave its loop and disconnect, so the probe is released
    [IO.File]::WriteAllText($cmdFile, 'STOP', [Text.Encoding]::ASCII)
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 200
    }
    $alive = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
    if ($alive) {
        # the loop is stuck; kill the process tree so the probe is not held open
        & cmd.exe /d /c "taskkill /PID $($st.pid) /T /F" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        Info2 'NOTE    : service did not stop on request; process tree killed'
    }
    foreach ($f in @($cmdFile, $resFile, $readyFile, $stateFile)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    $cnt = Get-LoadCount -ProjectPath $ProjectPath
    Exit-TargetLock -ProjectPath $ProjectPath
    Out2 'SERVICE : STOPPED'
    Out2 ('LOADS   : #{0} kept (the next -Start would be load #{1})' -f $cnt.count, ([int]$cnt.count + 1))
    Out2 'RESULT: OK'
    exit 0
}

# ---------------------------------------------------------------- start ------
if (Test-ServiceAlive) {
    $st = Get-ServiceState
    $cnt0 = Get-LoadCount -ProjectPath $ProjectPath
    Out2 ('SERVICE : ALREADY_RUNNING (pid {0})' -f $st.pid)
    Out2 ('LOAD    : #' + $(if ($st.loadIndex) { $st.loadIndex } else { '?' }) + ' is still the loaded image - no download happened')
    Out2 ('LOADS   : #{0} total for this project' -f $cnt0.count)
    if ($Build) { Out2 'NOTE    : -Build ignored, the running session already holds a loaded image; stop it first to reload' }
    Out2 'RESULT: OK'
    exit 0
}

# ---- download guard ----------------------------------------------------------
# A load rewrites the whole image, restarts the program and wears the target. The
# only execution mode never does that without a human saying yes first. Reads are
# never affected: they attach to the session and never come through here.
if (-not $ConfirmLoad) {
    $cnt = Get-LoadCount -ProjectPath $ProjectPath
    Out2 'FAILURE: LOAD_NOT_CONFIRMED'
    Out2 'RESULT: FAIL'
    Out2 'REASON: nothing was written to the target - this start would compile/download and restart the program'
    Out2 ('HINT    : ask the user "是否编译下载并运行？" first, then re-run the same command with -ConfirmLoad (next download would be #' + ([int]$cnt.count + 1) + ')')
    if ($runSpec.continuous) { Out2 'HINT    : continuous mode also needs -UserApproved; ti_c2000_iterate.ps1 passes both for you' }
    Out2 'HINT    : reading does not need this - ti_c2000_run_read.ps1 / ti_c2000_read_dma.ps1 attach to a running session (-Mode ReadOnly)'
    exit 4
}

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
if (-not $Ccxml -or -not (Test-Path -LiteralPath $Ccxml)) {
    Out2 'FAILURE: NO_CCXML'; Out2 'RESULT: FAIL'; Out2 'REASON: no .ccxml found; pass -Ccxml <file>'; exit 2
}
if (-not $OutFile) { $OutFile = Join-Path $ProjectPath "Debug\$projName.out" }

$skillRoot = Split-Path $PSScriptRoot -Parent
$debugScript = Join-Path $skillRoot 'scripts\ti_c2000_debug.ps1'
if (-not (Test-Path -LiteralPath $debugScript)) {
    Out2 'FAILURE: ENV_NO_DEBUG_SCRIPT'; Out2 'RESULT: FAIL'
    Out2 'REASON: ti_c2000_debug.ps1 is missing from this skill installation'; exit 2
}

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
    foreach ($line in $bout) { if (-not $Quiet -and [string]$line -notmatch '^RESULT:') { Out2 ([string]$line) } }
    if ($bcode -ne 0 -or -not @($bout | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
        $bfail = @($bout | Where-Object { $_ -match '^FAILURE: ' }) | Select-Object -First 1
        if (-not $bfail) { $bfail = 'FAILURE: BUILD_FAILED' }
        Out2 $bfail; Out2 'RESULT: FAIL'; Out2 'REASON: build failed - service not started'; exit 1
    }
    Info2 'BUILD   : OK (this is the one compile for the session)'
}
if (-not (Test-Path -LiteralPath $OutFile)) {
    Out2 'FAILURE: NO_OUT_FILE'; Out2 'RESULT: FAIL'
    Out2 "REASON: '$OutFile' not found - add -Build or build/stage first"; exit 2
}

$ccsPath = ''
if ($probeText -match '(?m)^CCS\s*:\s*(.+?)\s+\(v') { $ccsPath = $Matches[1].Trim() }
if (-not $ccsPath -and $CcsRoot -and (Test-Path (Join-Path $CcsRoot 'ccs_base'))) { $ccsPath = (Get-Item -LiteralPath $CcsRoot).FullName }
if (-not $ccsPath) { Out2 'FAILURE: ENV_NO_CCS'; Out2 'RESULT: FAIL'; Out2 'REASON: cannot resolve CCS; pass -CcsRoot'; exit 2 }
$dss = Join-Path $ccsPath 'ccs_base\scripting\bin\dss.bat'
if (-not (Test-Path -LiteralPath $dss)) { Out2 'FAILURE: ENV_NO_DSS'; Out2 'RESULT: FAIL'; Out2 "REASON: dss.bat not found under '$ccsPath'"; exit 2 }

New-Item -ItemType Directory -Path $svcDir -Force | Out-Null
# from here on the target is being taken: hold the lock so no read can attach while
# the image is being written (checked after the cheap build/probe work on purpose)
$lk = Enter-TargetLock -ProjectPath $ProjectPath -Mode 'Start'
if (-not $lk.ok) { foreach ($l in $lk.message) { Out2 $l }; exit 5 }
foreach ($f in @($readyFile, $stoppedFile, $errorFile, $cmdFile, $resFile, $stateFile)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}
$outSha = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash

# forward slashes: the DSS script is JavaScript, not PowerShell
$workJs = $svcDir.Replace('\', '/')
$ccxmlJs = (Get-Item -LiteralPath $Ccxml).FullName.Replace('\', '/')
$outJs = (Get-Item -LiteralPath $OutFile).FullName.Replace('\', '/')
$coreJs = $CorePattern.Replace('\', '\\').Replace('"', '\"')

$jsPath = Join-Path $svcDir 'server.js'
$js = @'
importPackage(Packages.com.ti.debug.engine.scripting);
importPackage(Packages.com.ti.ccstudio.scripting.environment);

var WORK  = "__WORK__";
var CCXML = "__CCXML__";
var OUT   = "__OUT__";
var CORE  = "__CORE__";

function sleepMs(ms) { java.lang.Thread.sleep(ms); }
function exists(p) { return (new java.io.File(p)).exists(); }
// Rhino cannot call java.nio.file.Paths.get (varargs), so plain java.io it is
function readText(p) {
    try {
        var r = new java.io.BufferedReader(new java.io.InputStreamReader(new java.io.FileInputStream(p), "UTF-8"));
        var sb = "", line;
        while ((line = r.readLine()) !== null) { sb += line + "\n"; }
        r.close();
        return sb;
    } catch (e) { return ""; }
}
// File.delete() cannot be called from Rhino ("delete" is a JS keyword); toPath()
// is argument-free, so delete through java.nio instead.
function deleteFile(p) {
    try {
        var f = new java.io.File(p);
        if (f.exists()) { java.nio.file.Files.deleteIfExists(f.toPath()); }
    } catch (e) { }
}
function writeText(p, s) {
    var tmp = p + ".tmp";
    var w = new java.io.BufferedWriter(new java.io.OutputStreamWriter(new java.io.FileOutputStream(tmp), "UTF-8"));
    w.write("" + s);
    w.close();
    deleteFile(p);
    var src = new java.io.File(tmp), dst = new java.io.File(p);
    if (!src.renameTo(dst)) {
        var w2 = new java.io.BufferedWriter(new java.io.OutputStreamWriter(new java.io.FileOutputStream(p), "UTF-8"));
        w2.write("" + s);
        w2.close();
    }
}
function removeIfExists(p) { deleteFile(p); }

var env = ScriptingEnvironment.instance();
try { env.setScriptTimeout(0); } catch (eT) { }
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
if (!connected) { writeText(WORK + "/error.txt", "CONNECT_FAILED"); throw "connect failed"; }
print("DSS: connected");

try { session.target.reset(); print("DSS: reset"); }
catch (e1) {
    print("DSS: reset failed (" + e1 + "), fallback halt");
    try { session.target.halt(); print("DSS: halted"); } catch (e2) { print("DSS: halt skipped: " + e2); }
}
try { session.memory.loadProgram(OUT); }
catch (e3) { writeText(WORK + "/error.txt", "LOAD_FAILED " + e3); throw "load failed"; }
print("DSS: loaded");
session.target.runAsynch();
sleepMs(300);
if (session.target.isHalted()) { writeText(WORK + "/error.txt", "TARGET_HALTED_AFTER_RUN"); throw "halted after run"; }
writeText(WORK + "/ready.txt", "ready");
print("SERVICE: READY");

var running = true;
while (running) {
    var cmdPath = WORK + "/cmd.txt";
    if (!exists(cmdPath)) { sleepMs(60); continue; }
    var cmd = readText(cmdPath).replace(/\s+$/, "");
    removeIfExists(cmdPath);
    if (cmd.length === 0) { continue; }
    if (cmd === "STOP") { running = false; break; }

    var out = [];
    var halted = session.target.isHalted();
    out.push("HALTED " + (halted ? "1" : "0"));
    try {
        if (cmd.indexOf("PING") === 0) {
            out.push("END");
        } else if (cmd.indexOf("VARS ") === 0) {
            var vs = cmd.substring(5).split("|");
            for (var vi = 0; vi < vs.length; vi++) {
                if (!vs[vi]) { continue; }
                try { out.push("V " + vs[vi] + " " + session.expression.evaluate(vs[vi])); }
                catch (eV) { out.push("E " + vs[vi] + " " + eV); }
            }
            out.push("END");
        } else if (cmd.indexOf("ARRAY ") === 0) {
            // ARRAY <name>|<rows>|<cols>
            var parts = cmd.substring(6).split("|");
            var name = parts[0], rows = parseInt(parts[1], 10), cols = parseInt(parts[2], 10);
            var total = rows * cols;
            var base = null;
            try { base = Number(session.symbol.getAddress(name)); } catch (eB) { base = null; }
            if (base === null || isNaN(base)) {
                out.push("E " + name + " address unresolved");
            } else {
                for (var off = 0; off < total; off += 2000) {
                    var cnt = Math.min(2000, total - off);
                    var vals = session.memory.readData(1, base + off, 16, cnt);
                    if (vals === null || vals.length !== cnt) { out.push("E " + name + " count mismatch"); break; }
                    for (var k = 0; k < cnt; k++) { out.push("A " + (off + k) + " " + vals[k]); }
                }
            }
            out.push("END");
        } else {
            out.push("E unknown command");
            out.push("END");
        }
    } catch (eR) {
        out.push("E " + eR);
        out.push("END");
    }
    writeText(WORK + "/res.txt", out.join("\n"));
}
try { session.target.disconnect(); } catch (eD) { }
writeText(WORK + "/stopped.txt", "stopped");
print("SERVICE: STOPPED");
'@
$js = $js.Replace('__WORK__', $workJs).Replace('__CCXML__', $ccxmlJs).Replace('__OUT__', $outJs).Replace('__CORE__', $coreJs)
[IO.File]::WriteAllText($jsPath, $js, [Text.Encoding]::ASCII)

Info2 "PROJECT : $ProjectPath"
Info2 "CCS     : $ccsPath"
Info2 "CCXML   : $Ccxml"
Info2 "OUT     : $OutFile"
Info2 "SESSION : $svcDir"
Info2 'STEP    : connect -> reset -> load once -> run forever'

# cmd /s /c "<whole command>" : /s makes cmd strip only the outer quotes, so
# paths with spaces survive. Output is redirected by cmd itself; Start-Process
# redirection would tie the log to this process and stop once it exits.
$cmdLine = '/d /s /c ""' + $dss + '" "' + $jsPath + '" > "' + $logFile + '" 2>&1"'
$psi = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -PassThru -WindowStyle Hidden
$cmdPid = $psi.Id

$deadline = (Get-Date).AddSeconds($StartTimeoutSec)
$failReason = ''
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $readyFile) { break }
    if (Test-Path -LiteralPath $errorFile) { $failReason = (Get-Content -LiteralPath $errorFile -Raw).Trim(); break }
    if (-not (Get-Process -Id $cmdPid -ErrorAction SilentlyContinue)) { $failReason = 'service process exited before ready'; break }
    Start-Sleep -Milliseconds 300
}

if (-not (Test-Path -LiteralPath $readyFile)) {
    $tail = @()
    if (Test-Path -LiteralPath $logFile) { $tail = @(Get-Content -LiteralPath $logFile -Tail 12 -ErrorAction SilentlyContinue) }
    if (-not $failReason) { $failReason = 'no ready signal within the startup timeout' }
    & cmd.exe /d /c "taskkill /PID $cmdPid /T /F" 2>&1 | Out-Null
    Exit-TargetLock -ProjectPath $ProjectPath
    foreach ($line in $tail) { Out2 ([string]$line) }
    Out2 'FAILURE: SERVICE_START_FAILED'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $failReason); exit 1
}

$state = [ordered]@{
    pid       = $cmdPid
    started   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    project   = $ProjectPath
    out       = $OutFile
    outSha256 = $outSha
    ccxml     = (Get-Item -LiteralPath $Ccxml).FullName
    core      = $CorePattern
    status    = 'RUNNING'
    loadIndex = 0
    runMode   = $runSpec.mode
}
[IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))

# the image is on the target now: this is a real download, so the shared counter
# moves (kept in readout\, outside .service, -Stop never resets it)
$rec = Add-LoadRecord -ProjectPath $ProjectPath -Mode $runSpec.mode -Out $OutFile -Sha256 $outSha
$state.loadIndex = $rec.count
[IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))
Exit-TargetLock -ProjectPath $ProjectPath

Info2 ('SERVICE : RUNNING (pid {0})' -f $cmdPid)
Info2 ('RUN MODE: {0}' -f $(if ($runSpec.continuous) {
            'Iterate (continuous - this session is one round; a loop re-downloads)'
        } else {
            'SingleStep (load once, run forever; reads attach, ReadOnly never downloads)'
        }))
Info2 ('LOAD    : #{0} (this is download number {0} for this project, previous {1})' -f $rec.count, $rec.previous)
Info2 ('LOG     : {0}' -f $logFile)
Out2 'RESULT: OK'
exit 0
