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

var env = ScriptingEnvironment.instance();
var budgetMs = RUN_MS > 0 ? RUN_MS : 5000;
try { env.setScriptTimeout(budgetMs + 300000); }
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

    try { session.target.connect(); connected = true; }
    catch (e1) { print("CONNECT_FAILED: " + e1); throw "connect failed"; }
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
        if (!ready) { print("WAIT_TIMEOUT: '" + WAIT_EXPR + "' not reached within " + waited + " ms"); }
    }

    print("DSS: running - reading expressions");
    for (var i = 0; i < VARS.length; i++) {
        var name = VARS[i].replace(/^\s+|\s+$/g, "");
        if (name.length === 0) { continue; }
        requireRunning(session, "during runtime read");
        try {
            var value = session.expression.evaluate(name);
            print("VAR " + name + " = " + value);
        } catch (e4) {
            print("VAR " + name + " = <ERROR: " + e4 + ">");
        }
    }
    requireRunning(session, "after runtime read");
    print("DSS: target still running after read");
} finally {
    if (connected) { tryCall("disconnect", function () { session.target.disconnect(); }); }
    tryCall("server.stop", function () { server.stop(); });
}
print("DSS: done");
