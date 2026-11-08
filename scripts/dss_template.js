/*
 * DSS template for reading an already running C2000 target. The wrapper fills
 * {{CCXML}}, {{OUT}}, {{RUN_MS}}, {{VARS}}, {{WAIT_EXPR}} and
 * {{SESSION_PATTERN}}. Program loading belongs to ti_c2000_debug.ps1 -Run.
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
var HEARTBEAT_EXPR = "{{HEARTBEAT_EXPR}}";
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
function readHeartbeat(session, stage) {
    try { return "" + session.expression.evaluate(HEARTBEAT_EXPR); }
    catch (e) {
        print("READONLY_HEARTBEAT_ERROR: " + stage + ": " + e);
        throw "heartbeat read failed";
    }
}
function requireHeartbeatAdvance(session, before, stage) {
    var after = readHeartbeat(session, stage);
    if (after === before) {
        sleepMs(50);
        requireRunning(session, "during heartbeat retry");
        after = readHeartbeat(session, stage + " retry");
    }
    if (after === before) {
        print("READONLY_HEARTBEAT_ERROR: " + HEARTBEAT_EXPR + " did not advance " + stage);
        throw "application heartbeat did not advance";
    }
    print("DSS: heartbeat advanced " + stage + " (" + before + " -> " + after + ")");
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
        var heartbeat = "";
        if (HEARTBEAT_EXPR.length > 0) {
            heartbeat = readHeartbeat(session, "before array capture");
            sleepMs(50);
            requireRunning(session, "before array capture heartbeat check");
            heartbeat = requireHeartbeatAdvance(session, heartbeat, "before array capture");
        }
        for (var offset = 0; offset < total; offset += ARRAY_BATCH_SIZE) {
            var count = Math.min(ARRAY_BATCH_SIZE, total - offset);
            requireRunning(session, "before array batch " + (offset / ARRAY_BATCH_SIZE + 1));
            for (var j = 0; j < count; j++) {
                var linear = offset + j;
                var row = Math.floor(linear / ARRAY_COLUMNS);
                var column = linear % ARRAY_COLUMNS;
                var name = ARRAY_ROWS === 1 ? ARRAY_NAME + "[" + column + "]" :
                           ARRAY_NAME + "[" + row + "][" + column + "]";
                try {
                    print("VAR " + name + " = " + session.expression.evaluate(name));
                } catch (e4) {
                    print("VAR " + name + " = <ERROR: " + e4 + ">");
                    print("READONLY_VALUE_ERROR: array element read failed: " + name);
                    throw "array element read failed";
                }
            }
            requireRunning(session, "after array batch " + (offset / ARRAY_BATCH_SIZE + 1));
            if (HEARTBEAT_EXPR.length > 0) {
                heartbeat = requireHeartbeatAdvance(session, heartbeat, "after array batch " + (offset / ARRAY_BATCH_SIZE + 1));
            }
            print("BATCH: " + (Math.floor(offset / ARRAY_BATCH_SIZE) + 1) +
                  " values=" + count + " endIndex=" + (offset + count - 1));
        }
    } else {
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
    }
    requireRunning(session, "after runtime read");
    print("DSS: target still running after read");
} finally {
    if (connected) { tryCall("disconnect", function () { session.target.disconnect(); }); }
    tryCall("server.stop", function () { server.stop(); });
}
print("DSS: done");
