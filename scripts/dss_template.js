/*
 * DSS template for reading an already running C2000 target. The wrapper fills
 * {{CCXML}}, {{OUT}}, {{RUN_MS}}, {{VARS}}, {{WAIT_EXPR}} and
 * {{SESSION_PATTERN}}. Loading and same-session verification belong to the
 * execution-mode ti_c2000_run_read.ps1 / ti_c2000_read_dma.ps1 scripts.
 *
 * This file intentionally has no target halt, reset, restart or resume path.
 * Configure the DSS connection before connect; a halted target is a failure.
 */
importPackage(Packages.com.ti.debug.engine.scripting);
importPackage(Packages.com.ti.ccstudio.scripting.environment);
importPackage(Packages.java.lang);

var CCXML     = "{{CCXML}}";
var OUT       = "{{OUT}}";
var RUN_MS    = {{RUN_MS}};
var VARS      = "{{VARS}}".split(",");
var WAIT_EXPR = "{{WAIT_EXPR}}";
var ARRAY_NAME = "{{ARRAY_NAME}}";
var ARRAY_ROWS = {{ARRAY_ROWS}};
var ARRAY_COLUMNS = {{ARRAY_COLUMNS}};
var ARRAY_BATCH_SIZE = {{ARRAY_BATCH_SIZE}};
/* Candidate list (comma separated). The first readable one becomes the
   heartbeat; if none can be read the read fails unless -NoHeartbeat was used. */
var HEARTBEAT_CANDIDATES = "{{HEARTBEAT_EXPR}}".split(",");
/* 1 = batched memory.readData (fast), 0 = per-element evaluate (point mode,
   works on any symbol including peripheral registers) */
var USE_BATCH = {{USE_BATCH}};
var READ_TIMEOUT_MS = {{READ_TIMEOUT_MS}};

function sleepMs(ms) {
    try { java.lang.Thread.sleep(ms); }
    catch (e) { print("READONLY_VALUE_ERROR: sleep interrupted: " + e); }
}
function tryCall(what, fn) {
    try { fn(); return true; }
    catch (e) { print("DSS: " + what + " failed: " + e); return false; }
}
function requireRunning(session, stage) {
    var stopped;
    try { stopped = session.target.isHalted(); }
    catch (e) {
        print("READONLY_STATE_UNKNOWN: " + stage + ": " + e);
        throw "cannot verify target running state";
    }
    if (stopped) {
        print("READONLY_STATE_ERROR: target halted " + stage + "; no resume attempted");
        throw "target is halted";
    }
}
function toNum(v) {
    var s = "" + v;
    if (s.length === 0) { return null; }
    var n = Number(s);
    return isNaN(n) ? null : n;
}
/* Strictly increasing for numeric heartbeats; "changed" for non numeric ones. */
function isAdvance(before, after) {
    var nb = toNum(before), na = toNum(after);
    if (nb !== null && na !== null) { return na > nb; }
    return after !== before;
}
/* Every readable candidate becomes a heartbeat. One readable counter is a weak
   proof (a stale or coincidental variable passes); several must all advance,
   so a single stale variable cannot carry the verdict on its own. */
var HEARTBEATS = [];
function selectHeartbeats(session) {
    HEARTBEATS = [];
    for (var i = 0; i < HEARTBEAT_CANDIDATES.length; i++) {
        var c = HEARTBEAT_CANDIDATES[i].replace(/^\s+|\s+$/g, "");
        if (c.length === 0) { continue; }
        try {
            var v = session.expression.evaluate(c);
            HEARTBEATS.push(c);
            print("DSS: heartbeat candidate '" + c + "' = " + v);
        } catch (e) { }
    }
    if (HEARTBEATS.length === 0) { return null; }
    print("DSS: heartbeats used = " + HEARTBEATS.join(","));
    return HEARTBEATS.slice();
}
function readHeartbeats(session, stage) {
    var out = {};
    for (var i = 0; i < HEARTBEATS.length; i++) {
        var name = HEARTBEATS[i];
        try { out[name] = "" + session.expression.evaluate(name); }
        catch (e) {
            print("READONLY_HEARTBEAT_ERROR: " + name + " " + stage + ": " + e);
            throw "heartbeat read failed";
        }
    }
    return out;
}
function requireHeartbeatsAdvance(session, before, stage) {
    var after = readHeartbeats(session, stage);
    var allAdvanced = true;
    for (var i = 0; i < HEARTBEATS.length; i++) {
        if (!isAdvance(before[HEARTBEATS[i]], after[HEARTBEATS[i]])) { allAdvanced = false; }
    }
    if (!allAdvanced) {
        sleepMs(50);
        requireRunning(session, "during heartbeat retry");
        after = readHeartbeats(session, stage + " retry");
        allAdvanced = true;
        for (var j = 0; j < HEARTBEATS.length; j++) {
            if (!isAdvance(before[HEARTBEATS[j]], after[HEARTBEATS[j]])) { allAdvanced = false; }
        }
    }
    for (var k = 0; k < HEARTBEATS.length; k++) {
        var hn = HEARTBEATS[k];
        print("HB " + hn + " before = " + before[hn]);
        print("HB " + hn + " after = " + after[hn]);
        print("DSS: heartbeat " + hn + " " + stage + " " + before[hn] + " -> " + after[hn]);
    }
    if (!allAdvanced) {
        print("READONLY_HEARTBEAT_ERROR: not all heartbeats increased " + stage);
        throw "application heartbeat did not advance";
    }
    return after;
}

var env = ScriptingEnvironment.instance();
var budgetMs = RUN_MS > 0 ? RUN_MS : 5000;
try { env.setScriptTimeout(budgetMs + READ_TIMEOUT_MS); }
catch (e) { print("DSS: setScriptTimeout failed: " + e); }

var server = env.getServer("DebugServer.1");
server.setConfig(CCXML);
var session = server.openSession("{{SESSION_PATTERN}}");
var connected = false;

try {
    try {
        session.options.setBoolean("HaltOnConnect", false);
        session.options.setBoolean("AutoResetOnConnect", false);
        session.options.setBoolean("RestartOnSymbolLoad", false);
        session.options.setBoolean("UseLegacyStopMode", false);
        session.options.setBoolean("AllowInterruptsWhenHalted", true);
        session.options.setBoolean("PoliteRealtimeMode", true);
        print("DSS: realtime options set before connect (no auto-halt/reset/restart)");
    } catch (e0) {
        print("READONLY_CONFIG_ERROR: cannot enable non-stop realtime access: " + e0);
        throw "read-only debugger configuration failed";
    }

    var connectError = "";
    for (var attempt = 1; attempt <= 3 && !connected; attempt++) {
        try { session.target.connect(); connected = true; }
        catch (e1) {
            connectError = "" + e1;
            print("CONNECT_RETRY: attempt " + attempt + "/3 failed: " + connectError);
            if (attempt < 3) { sleepMs(1000); }
        }
    }
    if (!connected) { print("CONNECT_FAILED: " + connectError); throw "connect failed"; }
    print("DSS: connected (mode=readonly, core='{{SESSION_PATTERN}}')");
    requireRunning(session, "at connect");
    print("DSS: target at connect was running");

    try { session.symbol.load(OUT); }
    catch (e2) {
        print("READONLY_SYMBOL_ERROR: could not load symbols without downloading: " + e2);
        throw "read-only symbol load failed";
    }
    print("DSS: symbols loaded (readonly, no program download)");
    requireRunning(session, "during symbol load");

    /* Default heartbeat: first readable expression from the candidate list.
       None readable -> fail unless the caller explicitly used -NoHeartbeat. */
    var hbInitial = null;
    if (HEARTBEAT_CANDIDATES.length > 0 && HEARTBEAT_CANDIDATES[0].length > 0) {
        hbInitial = selectHeartbeats(session);
        if (hbInitial === null) {
            print("READONLY_NO_HEARTBEAT: none of '" + HEARTBEAT_CANDIDATES.join(",") + "' could be read");
            throw "no heartbeat variable available";
        }
    }

    if (WAIT_EXPR.length > 0) {
        var waited = 0;
        var ready = false;
        while (waited < budgetMs) {
            sleepMs(250); waited += 250;
            requireRunning(session, "during runtime polling");
            var v;
            try { v = ("" + session.expression.evaluate(WAIT_EXPR)).replace(/^\s+|\s+$/g, "").toLowerCase(); }
            catch (e3) {
                print("READONLY_VALUE_ERROR: readiness read failed: " + e3);
                throw "readiness read failed";
            }
            var numeric = Number(v);
            ready = v === "true" || (v !== "false" && v !== "" && !isNaN(numeric) && numeric !== 0);
            if (ready) {
                print("DSS: ready ('" + WAIT_EXPR + "') after " + waited + " ms");
                break;
            }
        }
        if (!ready) {
            print("WAIT_TIMEOUT: '" + WAIT_EXPR + "' not reached within " + waited + " ms");
            if (ARRAY_NAME.length > 0) { throw "array capture readiness failed"; }
        }
    }

    print("DSS: running - reading expressions");
    if (ARRAY_NAME.length > 0) {
        var total = ARRAY_ROWS * ARRAY_COLUMNS;
        var heartbeat = null;
        if (HEARTBEATS.length > 0) {
            heartbeat = readHeartbeats(session, "before array capture");
            sleepMs(50);
            requireRunning(session, "before array capture heartbeat check");
            heartbeat = requireHeartbeatsAdvance(session, heartbeat, "before array capture");
        }
        /* Batched readData is ~39x faster than per-element evaluate
           (measured 2026-11-14: 14.0 ms per evaluate vs 0.36 ms per 16-bit
           word; DSS typeSize is a BIT width, not bytes: 16/32 only; page=1
           works for RAM; address advances per C28x 16-bit word).
           Fall back to per-element evaluate if the symbol address cannot be
           resolved or readData rejects the request (e.g. peripheral frame). */
        var arrayBase = null;
        try { arrayBase = Number(session.symbol.getAddress(ARRAY_NAME)); } catch (eBase) { arrayBase = null; }
        if (arrayBase === null || arrayBase === undefined || isNaN(arrayBase)) {
            print("DSS: array base address unavailable, using per-element evaluate");
        } else {
            print("DSS: array base address = " + arrayBase + " (batched readData)");
        }
        for (var offset = 0; offset < total; offset += ARRAY_BATCH_SIZE) {
            var count = Math.min(ARRAY_BATCH_SIZE, total - offset);
            var batchNo = Math.floor(offset / ARRAY_BATCH_SIZE) + 1;
            requireRunning(session, "before array batch " + batchNo);
            var vals = null;
            if (USE_BATCH === 1 && arrayBase !== null && arrayBase !== undefined) {
                try { vals = session.memory.readData(1, arrayBase + offset, 16, count); }
                catch (eRd) {
                    print("DSS: readData failed, falling back to evaluate: " + eRd);
                    arrayBase = null;
                    vals = null;
                }
            }
            if (vals !== null && vals !== undefined && vals.length === count) {
                for (var j = 0; j < count; j++) {
                    var linear = offset + j;
                    var row = Math.floor(linear / ARRAY_COLUMNS);
                    var column = linear % ARRAY_COLUMNS;
                    var name = ARRAY_ROWS === 1 ? ARRAY_NAME + "[" + column + "]" :
                               ARRAY_NAME + "[" + row + "][" + column + "]";
                    print("VAR " + name + " = " + vals[j]);
                }
            } else {
                for (var j2 = 0; j2 < count; j2++) {
                    var linear2 = offset + j2;
                    var row2 = Math.floor(linear2 / ARRAY_COLUMNS);
                    var column2 = linear2 % ARRAY_COLUMNS;
                    var name2 = ARRAY_ROWS === 1 ? ARRAY_NAME + "[" + column2 + "]" :
                                ARRAY_NAME + "[" + row2 + "][" + column2 + "]";
                    try {
                        print("VAR " + name2 + " = " + session.expression.evaluate(name2));
                    } catch (e4) {
                        print("VAR " + name2 + " = <ERROR: " + e4 + ">");
                        print("READONLY_VALUE_ERROR: array element read failed: " + name2);
                        throw "array element read failed";
                    }
                }
            }
            requireRunning(session, "after array batch " + batchNo);
            if (HEARTBEATS.length > 0) {
                heartbeat = requireHeartbeatsAdvance(session, heartbeat, "after array batch " + batchNo);
            }
            print("BATCH: " + batchNo + " values=" + count + " endIndex=" + (offset + count - 1));
        }
    } else {
        var hbBefore = null;
        if (HEARTBEATS.length > 0) {
            hbBefore = readHeartbeats(session, "before value read");
        }
        for (var i = 0; i < VARS.length; i++) {
            var name = VARS[i].replace(/^\s+|\s+$/g, "");
            if (name.length === 0) { continue; }
            requireRunning(session, "during runtime read");
            try {
                var value = session.expression.evaluate(name);
                print("VAR " + name + " = " + value);
            } catch (e5) {
                print("VAR " + name + " = <ERROR: " + e5 + ">");
            }
        }
        if (HEARTBEATS.length > 0) {
            requireHeartbeatsAdvance(session, hbBefore, "after value read");
        }
    }
    requireRunning(session, "after runtime read");
    print("DSS: target still running after read");
} finally {
    if (connected) { tryCall("disconnect", function () { session.target.disconnect(); }); }
    tryCall("server.stop", function () { server.stop(); });
}
print("DSS: done");
