#requires -Version 7.0
# =====================================================================
# ti_c2000_debug.ps1
#   Two modes for TI C2000 in CCS: non-stop realtime read of an existing target,
#   or the original build/load/run/read-back workflow.
#
#   - auto-detects the CCS installation (registry / C:\ti / %USERPROFILE%\ti)
#   - detects the XDS probe and fails fast & clearly when the board is absent
#   - load/run through loadti.bat, or DSS when variables must be read back
#
#   Usage:
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -Build -Run
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -Build -Run -RunMs 2000 -ReadVars "g_cnt,EPwm1Regs.TBPRD"
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -ReadOnly -ReadVars "EPwm1Regs.TBPRD"
#
#   -WaitFor / default readiness test: prefer a PERIPHERAL REGISTER (e.g. "EPwm1Regs.TBPRD == 14999",
#   "SciaRegs.SCILBAUD != 0").  loadProgram() does NOT clear .bss, so a global variable can already be
#   non-zero from RAM leftovers and would report "ready" in 250 ms while the init code has not run yet
#   (symptom: TBPRD / SCILBAUD still read 0).  The DSS template warns when ready comes that early.
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

# Reject incompatible arguments before a background process, build or loader
# can start.  Without ReadVars the old flow fell through to loadti -l.
if ($ReadOnly) {
    if ($Build -or $Run -or $LoadOnly) {
        Out2 "FAILURE: READONLY_MODE_CONFLICT"
        Out2 "RESULT: FAIL"
        Out2 "REASON: -ReadOnly cannot be combined with -Build, -Run or -LoadOnly"
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($ReadVars)) {
        Out2 "FAILURE: READONLY_NEEDS_READVARS"
        Out2 "RESULT: FAIL"
        Out2 "REASON: -ReadOnly requires -ReadVars; no program will be loaded"
        exit 2
    }
    # Only simple data paths may be evaluated against a running target. A
    # blacklist can miss C expression side effects (e.g. pointer calls or
    # comma operators), so reject anything outside this small read grammar.
    $pathPattern = '[A-Za-z_][A-Za-z0-9_]*(?:(?:\.|->)[A-Za-z_][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]*)\])*'
    $numberPattern = '-?(?:0[xX][0-9A-Fa-f]+|(?:0|[1-9][0-9]*)(?:\.[0-9]+)?)'
    $waitAtom = "(?:$pathPattern)(?:\s*(?:==|!=|<=|>=|<|>)\s*(?:$pathPattern|$numberPattern))?"
    $waitPattern = "^\s*$waitAtom(?:\s*(?:&&|\|\|)\s*$waitAtom)*\s*$"
    $readNames = @($ReadVars -split ',' | ForEach-Object { $_.Trim() })
    $unsafeRead = @($readNames | Where-Object { $_ -notmatch "^$pathPattern$" })
    if ($unsafeRead.Count -gt 0 -or ($WaitFor -and $WaitFor -notmatch $waitPattern)) {
        Out2 "FAILURE: READONLY_EXPRESSION_UNSAFE"
        Out2 "RESULT: FAIL"
        Out2 "REASON: read-only values must be simple symbol/field/constant-index paths; -WaitFor may compare them to paths or numbers with &&/||"
        exit 2
    }
} elseif ($LoadOnly -and ($Run -or $ReadVars)) {
    Out2 "FAILURE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -LoadOnly cannot be combined with -Run or -ReadVars"
    exit 2
} elseif (-not $Build -and -not $Run -and -not $LoadOnly -and -not $ReadVars) {
    Out2 "FAILURE: ACTION_REQUIRED"
    Out2 "RESULT: FAIL"
    Out2 "REASON: choose -Build, -Run, -LoadOnly, -ReadVars or -ReadOnly; no implicit load-only action"
    exit 2
}

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
    # ★一律用 PowerShell 7 引擎：本脚本首行是 #requires -Version 7.0，
    #   所以 $PSHOME 就是 PS7 安装目录 ——用它启动后台实例，绝不退回 Windows PowerShell 5.1
    #   （退回 5.1 时子脚本会因为自己的 #requires 直接失败：ScriptRequiresUnmatchedPSVersion）。
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }   # 兜底走 PATH
    Start-Process -FilePath $pwshExe -ArgumentList $argList -WindowStyle Hidden `
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
if (-not $ProjectPath -or -not (Test-Path -LiteralPath $ProjectPath -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $ProjectPath '.cproject') -PathType Leaf)) {
    Out2 "FAILURE: NO_PROJECT"
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
    # ★引擎统一：用 PowerShell 7（pwsh）跑子脚本，绝不退回 Windows PowerShell 5.1
    #   （退回 5.1 时 ti_c2000_build.ps1 会因自身 #requires -Version 7.0 直接失败）
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }   # 兜底走 PATH
    $bout = & $pwshExe @bargs 2>&1
    $bcode = $LASTEXITCODE
    if (-not $Quiet) { $bout | Select-Object -Last 12 | ForEach-Object { Out2 $_ } }
    if ($bcode -ne 0 -or -not @($bout | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
        $bfail = @($bout | Where-Object { $_ -match '^FAILURE: ' }) | Select-Object -First 1
        if (-not $bfail) { $bfail = 'FAILURE: BUILD_FAILED' }
        Out2 $bfail
        Out2 "RESULT: FAIL"
        Out2 "REASON: build failed - debugger step aborted (see the build script output / its build.log)"
        exit 1
    }
    if (-not $Run -and -not $LoadOnly -and -not $ReadVars) {
        Out2 "NOTE    : build completed; no download or run requested"
        Out2 "RESULT: OK"
        exit 0
    }
}

# ---------- 3. resolve .out / .ccxml / tools ----------
if (-not $OutFile) { $OutFile = Join-Path $ProjectPath "Debug\$projName.out" }
if (-not (Test-Path -LiteralPath $OutFile)) {
    Out2 "FAILURE: NO_OUT_FILE"
    if ($ReadOnly) {
        Out2 "RESULT: FAIL"; Out2 "REASON: $OutFile not found - provide an existing .out matching the running firmware; read-only mode will not build or download"; exit 2
    }
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
if ($ReadOnly) {
    if (-not (Test-Path -LiteralPath $dss)) { Out2 "FAILURE: ENV_NO_DSS"; Out2 "RESULT: FAIL"; Out2 "REASON: dss.bat not found under any CCS installation"; exit 2 }
} elseif (-not (Test-Path -LiteralPath $loadti)) {
    Out2 "FAILURE: ENV_NO_LOADTI"; Out2 "RESULT: FAIL"; Out2 "REASON: loadti.bat not found under any CCS installation"; exit 2
}
Info2 "OUTCARD : $OutFile"
Info2 "CCXML   : $Ccxml"
if ($ReadOnly) { Info2 "DSS     : $dss (symbols only)" }
else { Info2 "LOADTI  : $loadti" }

# ---------- 4. probe / GUI pre-flight ----------
# probe detection covers TI XDS family (XDS100/110/200/510/560), Spectrum Digital,
# Blackhawk, SEGGER J-Link and other JTAG probes that ccxml files can reference
$probePatterns = 'XDS|Texas Instruments.*(Debug|Emulat|Probe)|Debug Probe|Spectrum Digital|Blackhawk|SEGGER|J-Link|ICDI'
$probe = @()
if (-not $isSim -and -not $NoProbeCheck) {
    try {
        $probe = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop 2>$null |
                   Where-Object { $_.Name -match $probePatterns })
    } catch { $probe = @() }
    # Some Windows installations reject Win32_PnPEntity even though the USB
    # emulator is usable. CCS's own enumerator is authoritative for XDS100.
    if ($probe.Count -eq 0) {
        $xdsTool = Join-Path $ccs.Path 'ccs_base\common\uscif\xds100serial.exe'
        if (Test-Path -LiteralPath $xdsTool) {
            $xdsRows = @(& $xdsTool -l 2>$null | Where-Object { $_ -match '^[0-9a-fA-F]{4}/[0-9a-fA-F]{4}\s+XDS100' })
            foreach ($row in $xdsRows) { $probe += [pscustomobject]@{ Name = $row.Trim() } }
        }
    }
}
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

# ---------- 5a. DSS path: read-only values or full load/run/read ----------
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
    function Escape-JsString([string]$value) {
        $escaped = $value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return [regex]::Replace($escaped, '[^\x00-\x7F]', {
            param($match)
            return ('\u{0:X4}' -f [int][char]$match.Value[0])
        })
    }
    $body = $body.Replace('{{CCXML}}', (Escape-JsString $Ccxml))
    $body = $body.Replace('{{OUT}}',   (Escape-JsString $OutFile))
    $body = $body.Replace('{{RUN_MS}}', [string]$RunMs)
    $body = $body.Replace('{{VARS}}',  (Escape-JsString $ReadVars))
    $body = $body.Replace('{{MODE}}',  $(if ($ReadOnly) { 'readonly' } else { 'full' }))
    $body = $body.Replace('{{WAIT_EXPR}}', (Escape-JsString $waitExpr))
    $body = $body.Replace('{{SESSION_PATTERN}}', (Escape-JsString $CorePattern))
    $body | Set-Content -LiteralPath $js -Encoding ASCII
    if ($ReadOnly) { Info2 "STEP    : DSS read-only values (no build/download, wait='$waitExpr')" }
    else { Info2 "STEP    : DSS load/run/read (mode=full, budget=${RunMs}ms, wait='$waitExpr')" }
    # PowerShell 7 can fail before starting a .bat with
    # "StandardOutputEncoding is only supported when standard output is redirected".
    # Launch the CCS batch wrapper through cmd.exe; pass the two paths as separate
    # arguments so PowerShell adds the quotes (a pre-quoted single string gets its
    # inner quotes escaped as \" by PS7 and cmd.exe then fails to parse it).
    $dout = & cmd.exe /d /c $dss $js 2>&1
    $dcode = $LASTEXITCODE
    if (-not $Quiet) { $dout | ForEach-Object { Out2 $_ } }
    Remove-Item -LiteralPath $js -Force -ErrorAction SilentlyContinue
    $txt      = (($dout | ForEach-Object { [string]$_ }) -join "`n")
    # A partial read is not a complete result: report failed expressions explicitly.
    $jsErr    = @($dout | Where-Object { $_ -notmatch '^VAR ' -and $_ -notmatch '\(poll\)' -and $_ -match 'uncaught JavaScript|JavaScript runtime|TypeError|Cannot find function|SEVERE|ScriptingException' })
    $varLines = @($dout | Where-Object { $_ -match '^VAR ' -and $_ -notmatch '<ERROR' })
    $varErrors = @($dout | Where-Object { $_ -match '^VAR .*<ERROR:' })
    $connFail = @($dout | Where-Object { $_ -match 'CONNECT_FAILED' })
    $readonlyIssue = @($dout | Where-Object { $_ -match '^READONLY_(STATE_ERROR|STATE_UNKNOWN|CONFIG_ERROR|SYMBOL_ERROR|VALUE_ERROR):' })
    $fullRunError = @($dout | Where-Object { $_ -match '^FULL_RUN_ERROR:' })
    $timedOut = @($dout | Where-Object { $_ -match 'WAIT_TIMEOUT' })
    $readySeen = ($txt -match 'DSS: ready')
    $doneSeen  = ($txt -match 'DSS: done')

    # failure classification - every failure must be named explicitly
    $connectedSeen = ($txt -match 'DSS: connected')
    if ($ReadOnly -and $readonlyIssue.Count -gt 0) {
        Out2 "FAILURE: READONLY_ACCESS_ERROR"
        Out2 "REASON: non-stop realtime read could not be completed; no program was built or downloaded"
        Out2 ($readonlyIssue | Select-Object -First 1)
        Out2 "RESULT: FAIL"
        exit 1
    }
    if (-not $ReadOnly -and $fullRunError.Count -gt 0) {
        Out2 "FAILURE: TARGET_NOT_RUNNING"
        Out2 "REASON: program load/read path could not verify that the target resumed"
        Out2 ($fullRunError | Select-Object -First 1)
        Out2 "RESULT: FAIL"
        exit 1
    }
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
        if ($ReadOnly) { Out2 "REASON: condition not observed in read-only mode; no program was built or downloaded" }
        else { Out2 "REASON: readiness condition not reached within $RunMs ms (program stuck/reset, wrong -WaitFor expression, or truly needs longer)" }
        Out2 "NOTE    : any VAR values printed above were sampled AFTER the timeout and may be invalid"
        Out2 ($timedOut | Select-Object -First 1)
        Out2 "HINT    : raise -RunMs / fix -WaitFor; use -AllowNotReady to read values anyway"
        Out2 "RESULT: FAIL"
        exit 1
    }
    if ($dcode -ne 0 -or -not $doneSeen -or $jsErr.Count -gt 0 -or $varLines.Count -eq 0 -or $varErrors.Count -gt 0) {
        Out2 "FAILURE: DSS_SCRIPT_ERROR"
        Out2 "REASON: DSS session incomplete (exit=$dcode, done=$doneSeen, jsErrors=$($jsErr.Count), valuesRead=$($varLines.Count), valuesFailed=$($varErrors.Count))"
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
# ★不要把参数拼成一个字符串交给 cmd /c：PowerShell 7 调用原生 exe 时会按 C 运行库规则
#   把内嵌引号转义成 \"，而 cmd.exe 不认反斜杠转义 —— 工程路径一旦含空格（如 "...\Working Folder"）
#   就会得到  '""F:\...\loadti.bat" "-c' is not recognized as an internal or external command，
#   并被误判成 LOADTI_TIMEOUT。直接以数组传参给 .bat，由 PowerShell 负责加引号。
$out = & $loadti @ltArgs 2>&1
$code = $LASTEXITCODE
if (-not $Quiet) { $out | Select-Object -Last 25 | ForEach-Object { Out2 $_ } }
$bad    = @($out | Where-Object { $_ -match 'error|failed|cannot|aborted' })
$ldDone = @($out | Where-Object { $_ -match '\bDone\b' })
$runSeen = @($out | Where-Object { $_ -match '^Target running\.\.\.' })
if ($code -ne 0 -or $bad.Count -gt 0 -or $ldDone.Count -eq 0 -or ($Run -and $runSeen.Count -eq 0)) {
    if ($bad.Count -eq 0) {
        Out2 "FAILURE: LOADTI_TIMEOUT"
        Out2 "REASON: loadti did not confirm load and requested run within $TimeoutSec s (check Done and Target running markers)"
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
