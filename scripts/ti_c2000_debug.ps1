# =====================================================================
# ti_c2000_debug.ps1
#   Automatic "build -> load into debugger -> run -> read back" for
#   TI C2000 / DSP2833x in Code Composer Studio (CCS12 preferred, CCS6 ok).
#
#   - auto-detects the CCS installation (registry / C:\ti / %USERPROFILE%\ti)
#   - detects the XDS probe and fails fast & clearly when the board is absent
#   - load/run through loadti.bat, or DSS when variables must be read back
#
#   Usage:
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -Build -Run
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -Build -Run -RunMs 2000 -ReadVars "g_cnt,EPwm1Regs.TBPRD"
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -ReadOnly -ReadVars "EPwm1Regs.TBPRD"
#     ... -CcsRoot D:\path\to\ccs         force a CCS installation
#   Exit code: 0 OK | 1 failure | 2 environment/toolchain problem | 3 no probe
# =====================================================================
param(
    [string]$ProjectPath = "",
    [string]$CcsRoot     = "",
    [string]$Ccxml       = "",
    [string]$OutFile     = "",
    [switch]$Build,
    [switch]$Run,
    [switch]$LoadOnly,
    [switch]$ReadOnly,
    [int]$RunMs          = 0,
    [string]$ReadVars    = "",
    [string]$WaitFor     = "",
    [string]$CorePattern = ".*",
    [switch]$NoProbeCheck,
    [switch]$AllowNotReady,
    [int]$TimeoutSec     = 180,
    [switch]$Quiet,
    [switch]$Background,
    [string]$LogFile     = "",
    [switch]$Detached
)
$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

# ---------- 0. detached mode ----------
# A big application may need minutes before its registers settle; an IDE/agent
# command timeout would kill such a run. -Background relaunches this script
# detached, writes everything to a log and returns immediately.
if ($Background -and -not $Detached) {
    $log = if ($LogFile) { $LogFile } else { Join-Path $env:TEMP ("ti_c2000_debug_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')) }
    $errLog = "$log.err.txt"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'Background' -or $k -eq 'LogFile') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    $argList += '-Detached'
    Start-Process -FilePath 'powershell' -ArgumentList $argList -WindowStyle Hidden `
                  -RedirectStandardOutput $log -RedirectStandardError $errLog | Out-Null
    Out2 "BACKGROUND: started detached, log = $log"
    Out2 "HINT    : poll with   Select-String -Path '$log' -Pattern 'RESULT|^VAR |ready|BACKGROUND'"
    exit 0
}

# ---------- locate project ----------
if (-not $ProjectPath) {
    $d = Get-Item -LiteralPath (Get-Location).Path
    while ($d) {
        if (Test-Path (Join-Path $d.FullName '.cproject')) { $ProjectPath = $d.FullName; break }
        $d = $d.Parent
    }
}
if (-not $ProjectPath -or -not (Test-Path (Join-Path $ProjectPath '.cproject'))) {
    Out2 "RESULT: FAIL"; Out2 "REASON: project (.cproject) not found"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName
$projName = Split-Path $ProjectPath -Leaf
if (Test-Path (Join-Path $ProjectPath '.project')) {
    try {
        [xml]$prj = Get-Content -LiteralPath (Join-Path $ProjectPath '.project') -Raw
        if ($prj.projectDescription.name) { $projName = $prj.projectDescription.name }
    } catch { }
}
Info2 "PROJECT : $ProjectPath"

# ---------- 1. detect CCS installations (newest first) ----------
function Get-CcsRoots {
    $list = New-Object System.Collections.ArrayList
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Texas Instruments' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p.Version -and $p.Location) {
            $loc = ([string]$p.Location).TrimEnd('\')
            foreach ($cand in @((Join-Path $loc 'ccs'), (Join-Path $loc ("ccs" + ($p.Version -split '\.')[0])))) {
                if (Test-Path (Join-Path $cand 'ccs_base')) {
                    [void]$list.Add([pscustomobject]@{ Path = (Get-Item -LiteralPath $cand).FullName; Version = [string]$p.Version })
                    break
                }
            }
        }
    }
    foreach ($g in @("$env:USERPROFILE\ti\ccs*", 'C:\ti\ccsv*', 'C:\ti\ccs*')) {
        foreach ($cand in @(Get-Item -Path $g -ErrorAction SilentlyContinue)) {
            if ((Test-Path (Join-Path $cand.FullName 'ccs_base')) -and $cand.Name -notmatch '^ccs_base') {
                if (-not ($list | Where-Object { $_.Path -eq $cand.FullName })) {
                    $ver = '6.0'; if ($cand.Name -match 'ccs(\d+)') { $ver = $Matches[1] + '.0' }
                    [void]$list.Add([pscustomobject]@{ Path = $cand.FullName; Version = $ver })
                }
            }
        }
    }
    return @($list | Sort-Object { [double](($_.Version -split '[^\d]')[0]) } -Descending)
}
$roots = @()
if ($CcsRoot -and (Test-Path (Join-Path $CcsRoot 'ccs_base'))) {
    $roots = @([pscustomobject]@{ Path = (Get-Item -LiteralPath $CcsRoot).FullName; Version = 'forced' })
} else {
    $roots = Get-CcsRoots
}
if ($roots.Count -eq 0) { Out2 "FAILURE: ENV_NO_CCS"; Out2 "RESULT: FAIL"; Out2 "REASON: no CCS installation found"; exit 2 }
$ccs = $roots[0]
Info2 "CCS     : $($ccs.Path)  (v$($ccs.Version))"

# ---------- 2. optional build (same toolchain family) ----------
if ($Build) {
    Info2 "STEP    : build"
    $buildScript = Join-Path $PSScriptRoot 'ti_c2000_build.ps1'
    $bargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript, '-ProjectPath', $ProjectPath)
    if ($CcsRoot) { $bargs += @('-CcsRoot', $CcsRoot) }
    $bout = & powershell @bargs 2>&1
    $bcode = $LASTEXITCODE
    if (-not $Quiet) { $bout | Select-Object -Last 12 | ForEach-Object { Out2 $_ } }
    if ($bcode -ne 0) {
        $bfail = @($bout | Where-Object { $_ -match '^FAILURE: ' }) | Select-Object -First 1
        if (-not $bfail) { $bfail = 'FAILURE: BUILD_FAILED' }
        Out2 $bfail
        Out2 "RESULT: FAIL"
        Out2 "REASON: build failed - debugger step aborted (details in Debug\auto_build\build.log)"
        exit 1
    }
}

# ---------- 3. resolve .out / .ccxml / tools ----------
if (-not $OutFile) { $OutFile = Join-Path $ProjectPath "Debug\$projName.out" }
if (-not (Test-Path -LiteralPath $OutFile)) {
    Out2 "FAILURE: NO_OUT_FILE"
    Out2 "RESULT: FAIL"; Out2 "REASON: $OutFile not found - run the build first (add -Build)"; exit 2
}
if (-not $Ccxml) {
    $c = Get-ChildItem -Path (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($c) { $Ccxml = $c.FullName }
}
if (-not $Ccxml -or -not (Test-Path -LiteralPath $Ccxml)) {
    Out2 "FAILURE: NO_CCXML"
    Out2 "RESULT: FAIL"; Out2 "REASON: no .ccxml target configuration found - pass -Ccxml <file>"; exit 2
}
# what device / emulator does this target configuration ask for?
$ccxmlEmu = ''; $ccxmlDev = ''; $isSim = $false
try {
    [xml]$cc = Get-Content -LiteralPath $Ccxml -Raw
    $n = $cc.SelectSingleNode("//configuration/instance[@desc]")
    if ($n) { $ccxmlEmu = [string]$n.desc }
    $n = $cc.SelectSingleNode("//platform/instance[@id]")
    if ($n) { $ccxmlDev = [string]$n.id }
} catch { }
if (-not $ccxmlEmu) { $ccxmlEmu = '<unknown>' }
if (-not $ccxmlDev) { $ccxmlDev = '<unknown>' }
if ($ccxmlEmu -match 'simulator|tisim') { $isSim = $true }
Info2 "TARGET  : $ccxmlDev  via  $ccxmlEmu$(if ($isSim) { '  [simulator]' })"

$loadti = Join-Path $ccs.Path 'ccs_base\scripting\examples\loadti\loadti.bat'
$dss    = Join-Path $ccs.Path 'ccs_base\scripting\bin\dss.bat'
if (-not (Test-Path $loadti)) {
    foreach ($r in $roots) {
        $c = Join-Path $r.Path 'ccs_base\scripting\examples\loadti\loadti.bat'
        if (Test-Path $c) { $loadti = $c; $dss = Join-Path $r.Path 'ccs_base\scripting\bin\dss.bat'; break }
    }
}
if (-not (Test-Path $loadti)) { Out2 "FAILURE: ENV_NO_LOADTI"; Out2 "RESULT: FAIL"; Out2 "REASON: loadti.bat not found under any CCS installation"; exit 2 }
Info2 "OUTCARD : $OutFile"
Info2 "CCXML   : $Ccxml"
Info2 "LOADTI  : $loadti"

# ---------- 4. probe / GUI pre-flight ----------
# probe detection covers TI XDS family (XDS100/110/200/510/560), Spectrum Digital,
# Blackhawk, SEGGER J-Link and other JTAG probes that ccxml files can reference
$probePatterns = 'XDS|Texas Instruments.*(Debug|Emulat|Probe)|Debug Probe|Spectrum Digital|Blackhawk|SEGGER|J-Link|ICDI'
$probe = @(Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $probePatterns })
if ($isSim) {
    Info2 "PROBE   : skipped (simulator target, no hardware needed)"
    $probe = @([pscustomobject]@{ Name = 'TI simulator' })
} elseif ($NoProbeCheck) {
    Info2 "PROBE   : check skipped by -NoProbeCheck"
} elseif ($probe.Count -eq 0) {
    Out2 "PROBE   : NOT FOUND"
    Out2 "FAILURE: NO_PROBE"
    Out2 "RESULT: FAIL"
    Out2 "REASON: no JTAG probe enumerated by Windows (checked: XDS*, Spectrum Digital, Blackhawk, SEGGER, Debug Probe)"
    Out2 "HINT    : plug the JTAG probe in and power the target board, then retry"
    Out2 "HINT    : code-only verification needs no hardware - run ti_c2000_build.ps1 instead"
    Out2 "HINT2   : a simulator target (tisim) needs no hardware; -NoProbeCheck skips this check"
    exit 3
} else {
    foreach ($p in $probe) { Info2 ("PROBE   : {0}" -f $p.Name) }
}
if (@(Get-Process ccstudio, ccstudio64, eclipsec -ErrorAction SilentlyContinue).Count -gt 0) {
    Info2 "WARN    : CCS GUI is running - close any active debug session if the JTAG turns out to be busy"
}

# ---------- 5a. DSS path: load + run + halt + read variables ----------
if ($ReadVars) {
    if (-not (Test-Path $dss)) { Out2 "RESULT: FAIL"; Out2 "REASON: dss.bat not found at $dss"; exit 2 }
    $tpl = Join-Path $PSScriptRoot 'dss_template.js'
    if (-not (Test-Path $tpl)) { Out2 "RESULT: FAIL"; Out2 "REASON: dss_template.js missing"; exit 2 }
    $js = Join-Path $env:TEMP ("ti_c2000_dss_{0}.js" -f (Get-Random))
    $body = Get-Content -LiteralPath $tpl -Raw
    if ($RunMs -le 0) { $RunMs = 8000 }   # upper bound for polling; DSP init with OLED/I2C can take seconds
    # readiness expression: poll until the first requested value becomes non-zero,
    # instead of blindly sleeping (reading too early returns all zeros)
    $waitExpr = $WaitFor
    if (-not $waitExpr -and -not $ReadOnly) {
        $first = ($ReadVars -split ',')[0].Trim()
        if ($first) { $waitExpr = "$first != 0" }
    }
    $body = $body.Replace('{{CCXML}}', $Ccxml.Replace('\', '\\'))
    $body = $body.Replace('{{OUT}}',   $OutFile.Replace('\', '\\'))
    $body = $body.Replace('{{RUN_MS}}', [string]$RunMs)
    $body = $body.Replace('{{VARS}}',  $ReadVars)
    $body = $body.Replace('{{MODE}}',  $(if ($ReadOnly) { 'readonly' } else { 'full' }))
    $body = $body.Replace('{{WAIT_EXPR}}', $waitExpr)
    $body = $body.Replace('{{SESSION_PATTERN}}', $CorePattern)
    $body | Set-Content -LiteralPath $js -Encoding ASCII
    Info2 "STEP    : DSS load/run/read (mode=$(if ($ReadOnly) { 'readonly' } else { 'full' }), budget=${RunMs}ms, wait='$waitExpr')"
    $dout = & $dss $js 2>&1
    $dcode = $LASTEXITCODE
    if (-not $Quiet) { $dout | ForEach-Object { Out2 $_ } }
    Remove-Item -LiteralPath $js -Force -ErrorAction SilentlyContinue
    $txt      = (($dout | ForEach-Object { [string]$_ }) -join "`n")
    # per-expression failures are reported as "VAR x = <ERROR: ...>" and are tolerable;
    # only script-level errors abort the result
    $jsErr    = @($dout | Where-Object { $_ -notmatch '^VAR ' -and $_ -notmatch '\(poll\)' -and $_ -match 'uncaught JavaScript|JavaScript runtime|TypeError|Cannot find function|SEVERE|ScriptingException' })
    $varLines = @($dout | Where-Object { $_ -match '^VAR ' -and $_ -notmatch '<ERROR' })
    $connFail = @($dout | Where-Object { $_ -match 'CONNECT_FAILED' })
    $timedOut = @($dout | Where-Object { $_ -match 'WAIT_TIMEOUT' })
    $readySeen = ($txt -match 'DSS: ready')
    $doneSeen  = ($txt -match 'DSS: done')

    # failure classification - every failure must be named explicitly
    $connectedSeen = ($txt -match 'DSS: connected')
    if ($connFail.Count -gt 0 -or -not $connectedSeen -or ($dcode -ne 0 -and -not $readySeen -and -not $doneSeen)) {
        Out2 "FAILURE: CONNECT_FAILED"
        Out2 "REASON: no debug session could be opened/used (invalid ccxml? JTAG busy in the CCS GUI? board not powered? wrong core?)"
        if ($connFail.Count -gt 0) { Out2 ($connFail | Select-Object -First 1) }
        $diag = @($dout | Where-Object { $_ -match 'Exception|Error parsing|Fatal Error|Cannot' }) | Select-Object -First 2
        foreach ($d in $diag) { Out2 ("    " + $d) }
        Out2 "RESULT: FAIL"
        exit 1
    }
    if ($timedOut.Count -gt 0 -and -not $AllowNotReady) {
        Out2 "FAILURE: TIMEOUT"
        Out2 "REASON: readiness condition not reached within $RunMs ms (program stuck/reset, wrong -WaitFor expression, or truly needs longer)"
        Out2 "NOTE    : any VAR values printed above were sampled AFTER the timeout and may be invalid"
        Out2 ($timedOut | Select-Object -First 1)
        Out2 "HINT    : raise -RunMs / fix -WaitFor; use -AllowNotReady to read values anyway"
        Out2 "RESULT: FAIL"
        exit 1
    }
    if ($dcode -ne 0 -or -not $doneSeen -or $jsErr.Count -gt 0 -or $varLines.Count -eq 0) {
        Out2 "FAILURE: DSS_SCRIPT_ERROR"
        Out2 "REASON: DSS session incomplete (exit=$dcode, done=$doneSeen, jsErrors=$($jsErr.Count), valuesRead=$($varLines.Count))"
        Out2 "RESULT: FAIL"
        exit 1
    }
    if ($timedOut.Count -gt 0) { Out2 "WARN    : readiness timed out but -AllowNotReady was given; values below may be stale/zero" }
    Out2 "RESULT: OK"
    exit 0
}

# ---------- 5b. loadti path ----------
$ltArgs = @("-c=$Ccxml")
if ($LoadOnly) { $ltArgs += '-l' }
elseif ($Run)  { $ltArgs += @('-r', '-a') }
else           { $ltArgs += '-l' }
$ltArgs += "-t=$($TimeoutSec * 1000)"
$ltArgs += $OutFile
Info2 ("STEP    : loadti {0}" -f ($ltArgs -join ' '))
$out = & $loadti @ltArgs 2>&1
$code = $LASTEXITCODE
if (-not $Quiet) { $out | Select-Object -Last 25 | ForEach-Object { Out2 $_ } }
$bad    = @($out | Where-Object { $_ -match 'error|Error|failed|Failed|cannot' })
$ldDone = @($out | Where-Object { $_ -match '\bDone\b' })
if ($code -ne 0 -or $bad.Count -gt 0 -or $ldDone.Count -eq 0) {
    if ($bad.Count -eq 0) {
        Out2 "FAILURE: LOADTI_TIMEOUT"
        Out2 "REASON: no 'Done' marker from loadti within $TimeoutSec s - probe/board problem, JTAG busy, or the load really is slower than the timeout"
        Out2 "HINT    : raise -TimeoutSec; check probe + board power; make sure the CCS GUI is not holding the JTAG"
    } else {
        Out2 "FAILURE: LOADTI_ERROR"
        Out2 "REASON: loadti reported an error (probe busy / board power / wrong ccxml)"
        $bad | Select-Object -First 3 | ForEach-Object { Out2 ("    " + $_) }
    }
    Out2 "RESULT: FAIL"
    exit 1
}
if ($LoadOnly) { Out2 "NOTE    : program loaded and halted (no run requested)" }
elseif ($Run)  { Out2 "NOTE    : program started on target (async run)" }
Out2 "RESULT: OK"
exit 0
