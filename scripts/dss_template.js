/*
 * dss_template.js  --  DSS (Debug Server Scripting) session template
 *   Filled with real values and launched by ti_c2000_debug.ps1, or run by hand:
 *       <CCS>\ccs_base\scripting\bin\dss.bat  my_session.js
 *   Placeholders: {{CCXML}} {{OUT}} {{RUN_MS}} {{VARS}} {{MODE}} {{WAIT_EXPR}}
 *
 *   API notes (verified on CCS12.8):
 *     - there is NO session.registers; use session.memory.readRegister()/writeRegister()
 *     - target.restart() == CCS "Restart" (reset + go to the program entry point);
 *       a plain loadProgram() alone leaves the PC wherever it was, so a RAM build
 *       would keep running the old flash program
 *     - Rhino has no env.sleep(); use java.lang.Thread.sleep()
 *     - symbol.lookupSymbol() does not exist; use symbol.getAddress()
 *   Re-check another CCS version with scripts/dss_api_probe.js
 */
importPackage(Packages.com.ti.debug.engine.scripting);
importPackage(Packages.com.ti.ccstudio.scripting.environment);
importPackage(Packages.java.lang);

var CCXML     = "{{CCXML}}";
var OUT       = "{{OUT}}";
var RUN_MS    = {{RUN_MS}};
var VARS      = "{{VARS}}".split(",");
var MODE      = "{{MODE}}";        // "full" = load+run+halt+read, "readonly" = halt+read+resume
var WAIT_EXPR = "{{WAIT_EXPR}}";   // readiness expression; empty = plain fixed sleep

function sleepMs(ms) {
    if (!ms || ms <= 0) { ms = 500; }
    try { java.lang.Thread.sleep(ms); } catch (e) { print("DSS: sleep interrupted: " + e); }
}
function tryCall(what, fn) {
    try { fn(); return true; }
    catch (e) { print("DSS: " + what + " failed: " + e); return false; }
}

var env = ScriptingEnvironment.instance();

// A big application can need minutes before its registers settle. The DSS session
// must be allowed to live longer than the readiness budget, otherwise long runs
// die with a script-timeout error instead of a real result.
var budgetMs = RUN_MS > 0 ? RUN_MS : 5000;
var oldTimeout = -1;
try { oldTimeout = env.getScriptTimeout(); } catch (e) { }
try { env.setScriptTimeout(budgetMs + 300000); } catch (e) { print("DSS: setScriptTimeout failed: " + e); }
print("DSS: script timeout " + oldTimeout + " -> " + (budgetMs + 300000) + " ms (budget " + budgetMs + " ms)");

var server = env.getServer("DebugServer.1");
server.setConfig(CCXML);

// SESSION_PATTERN selects the core on multi-core devices (F2837xD/F28379D/F2838x):
// ".*" = first/only core, or e.g. ".*CPU1.*" for core 1 of a dual core part.
var session = server.openSession("{{SESSION_PATTERN}}");
try {
    session.target.connect();
} catch (e) {
    print("CONNECT_FAILED: " + e);
    try { server.stop(); } catch (e2) { }
    throw "connect failed";       // aborts the session; the caller reports FAILURE: CONNECT_FAILED
}
print("DSS: connected (mode=" + MODE + ", core='" + "{{SESSION_PATTERN}}" + "')");

if (MODE === "full") {
    session.memory.loadProgram(OUT);
    print("DSS: loaded " + OUT);

    var restarted = tryCall("target.restart()", function () { session.target.restart(); });
    if (!restarted) {
        tryCall("target.reset()", function () { session.target.reset(); });
        tryCall("PC <- entry point", function () {
            var addr = null;
            try { addr = session.symbol.getAddress("code_start"); } catch (e1) { addr = null; }
            if (addr === null || addr === undefined) {
                try { addr = session.expression.evaluate("_c_int00"); } catch (e2) { addr = null; }
            }
            if (addr === null || addr === undefined) { throw new Error("entry symbol not found"); }
            session.memory.writeRegister("PC", addr);
            print("DSS: PC <- " + addr);
        });
    }
    tryCall("runAsynch()", function () { session.target.runAsynch(); });

    var budget = RUN_MS > 0 ? RUN_MS : 5000;
    if (WAIT_EXPR.length > 0) {
        // Poll instead of a blind sleep: DSP init code (OLED bit-banging, delays)
        // can easily take seconds, and reading too early returns all zeros.
        var waited = 0;
        var ready  = false;
        while (waited < budget) {
            sleepMs(250); waited += 250;
            // halt/evaluate/resume - guarded so no exception noise is produced
            try { if (!session.target.isHalted()) { session.target.halt(); } } catch (e2) { }
            try { ready = ("" + session.expression.evaluate(WAIT_EXPR)) !== "0"; } catch (e3) { ready = false; }
            if (ready) { print("DSS: ready ('" + WAIT_EXPR + "') after " + waited + " ms"); break; }
            try { if (session.target.isHalted()) { session.target.runAsynch(); } } catch (e4) { }
        }
        if (!ready) { print("WAIT_TIMEOUT: '" + WAIT_EXPR + "' not reached within " + budget + " ms"); }
    } else {
        print("DSS: running for " + budget + " ms");
        sleepMs(budget);
    }
} else {
    // readonly: load SYMBOLS ONLY (no memory write, no reset) so expressions resolve
    // while a program already running on the target keeps going.
    tryCall("symbol.load()", function () { session.symbol.load(OUT); });
    print("DSS: symbols loaded (readonly, target untouched)");
}

tryCall("halt()", function () { session.target.halt(); });
print("DSS: halted - reading expressions");
for (var i = 0; i < VARS.length; i++) {
    var name = VARS[i].replace(/^\s+|\s+$/g, "");
    if (name.length === 0) { continue; }
    try {
        var v = session.expression.evaluate(name);
        print("VAR " + name + " = " + v);
    } catch (e) {
        print("VAR " + name + " = <ERROR: " + e + ">");
    }
}

tryCall("resume", function () { session.target.runAsynch(); });
tryCall("disconnect", function () { session.target.disconnect(); });
tryCall("server.stop", function () { server.stop(); });
print("DSS: done");
