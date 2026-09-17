/*
 * dss_api_probe.js -- dump the real DSS API surface of the installed CCS.
 * Rhino's for-in does NOT enumerate Java methods, so this probe uses Java
 * reflection.  Run it whenever a DSS call fails with "undefined" or
 * "Cannot find function" - member names differ between CCS releases.
 *
 *   C:\ti\ccsv6\ccs_base\scripting\bin\dss.bat dss_api_probe.js
 */
importPackage(Packages.java.lang);

function dumpMethods(className) {
    print("=== " + className + " ===");
    try {
        var cls = java.lang.Class.forName(className);
        var ms = cls.getMethods();
        var seen = {};
        var names = [];
        for (var i = 0; i < ms.length; i++) {
            var n = ms[i].getName();
            if (!seen[n]) { seen[n] = 1; names.push(n); }
        }
        names.sort();
        print("  " + names.join(", "));
    } catch (e) {
        print("  <cannot reflect: " + e + ">");
    }
}

// defaults that gate long debug runs
try {
    var e2 = Packages.com.ti.ccstudio.scripting.environment.ScriptingEnvironment.instance();
    print("=== timeouts ===");
    print("  scriptTimeout   = " + e2.getScriptTimeout());
    print("  debuggerTimeout = " + e2.getDebuggerTimeout());
} catch (e) { print("timeout probe failed: " + e); }

dumpMethods("com.ti.debug.engine.scripting.Session");
dumpMethods("com.ti.debug.engine.scripting.Target");
dumpMethods("com.ti.debug.engine.scripting.Memory");
dumpMethods("com.ti.debug.engine.scripting.Expression");
dumpMethods("com.ti.debug.engine.scripting.Symbol");
dumpMethods("com.ti.debug.engine.scripting.Registers");
dumpMethods("com.ti.ccstudio.scripting.environment.ScriptingEnvironment");
print("PROBE: done");
