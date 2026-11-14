#requires -Version 7.0
# =====================================================================
# ti_c2000_debug.ps1
#   Two modes for TI C2000 in CCS: non-stop realtime read of an existing target,
#   or the execution build/load/run workflow. A later standalone read cannot
#   establish the identity of a just-loaded RAM image after the loader exits;
#   use ti_c2000_run_read.ps1 for same-session execution and observation.
#
#   - auto-detects the CCS installation (registry / C:\ti / %USERPROFILE%\ti)
#   - detects the XDS probe and fails fast & clearly when the board is absent
#   - load/run through loadti.bat; runtime read through non-stop DSS
#
#   Usage:
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -Build -Run
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -ReadOnly -ReadVars "g_cnt,EPwm1Regs.TBPRD"
#
#   -WaitFor belongs to the later read-only call. Prefer a value that proves
#   initialization completed (e.g. "EPwm1Regs.TBPRD == 14999"). A loose
#   nonzero .bss value may be a leftover from an earlier RAM run.
#     ... -CcsRoot D:\path\to\ccs         force a CCS installation
#   Exit code: 0 OK | 1 failure | 2 environment/toolchain problem | 3 no probe
# =====================================================================
param(
    [string]$ProjectPath = "",
    [string]$CcsRoot     = "",
    [string]$Ccxml       = "",
    [string]$OutFile     = "",
    [switch]$Build,
    [switch]$AllowCompilerFallback,
    [switch]$Run,
    [switch]$LoadOnly,
    [switch]$ProbeCheckOnly,
    [switch]$ReadOnly,
    [int]$RunMs          = 0,
    [string]$ReadVars    = "",
    [string]$ReadArray   = "",
    [int]$ArrayRows     = 1,
    [int]$ArrayColumns  = 0,
    # measured 2026-11-14: 320 -> 0.331 ms/word, 2000 -> 0.296 ms/word
    [int]$ArrayBatchSize = 2000,
    # Candidate list: the first readable expression becomes the liveness proof.
    # -NoHeartbeat explicitly disables it (not recommended).
    [string]$HeartbeatExpr = "gMsTick,gRunMs,usMainLoop",
    [int]$StartupMaxMs  = 10000,
    [switch]$NoHeartbeat,
    # Force per-element evaluate instead of batched memory.readData
    [switch]$PointMode,
    [int]$ReadTimeoutSec = 300,
    [string]$WaitFor     = "",
    # Match the single C28xx core on F28335 or CPU1 on F28379D; exclude CLA1.
    [string]$CorePattern = '.*C28xx(?:_CPU1)?$',
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
# can start. Reading is always a separate non-stop realtime operation.
if ($ReadVars -or $ReadArray -or $ReadOnly) {
    Out2 'FAILURE: READONLY_UNRELIABLE'
    Out2 'RESULT: FAIL'
    Out2 'REASON: separate read-only sessions are disabled; use ti_c2000_run_read.ps1 or ti_c2000_read_dma.ps1 in one session'
    exit 2
}
if ($WaitFor) {
    Out2 'FAILURE: WAIT_REQUIRES_SINGLE_SESSION'
    Out2 'RESULT: FAIL'
    Out2 'REASON: -WaitFor belongs to a single-session read; use run_read/read_dma, not the legacy wrapper'
    exit 2
}
if ($ProbeCheckOnly -and ($Build -or $AllowCompilerFallback -or $Run -or $LoadOnly -or $ReadOnly -or $ReadVars -or $ReadArray -or $NoProbeCheck)) {
    Out2 "FAILURE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -ProbeCheckOnly cannot build, access the target or skip the probe check"
    exit 2
}
if ($AllowCompilerFallback -and -not $Build) {
    Out2 "FAILURE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -AllowCompilerFallback only applies when -Build is specified"
    exit 2
}
if ($ReadOnly) {
    if ($Build -or $Run -or $LoadOnly) {
        Out2 "FAILURE: READONLY_MODE_CONFLICT"
        Out2 "RESULT: FAIL"
        Out2 "REASON: -ReadOnly cannot be combined with -Build, -Run or -LoadOnly"
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($ReadVars) -and [string]::IsNullOrWhiteSpace($ReadArray)) {
        Out2 "FAILURE: READONLY_NEEDS_READVARS"
        Out2 "RESULT: FAIL"
        Out2 "REASON: -ReadOnly requires -ReadVars or -ReadArray; no program will be loaded"
        exit 2
    }
    # Only simple data paths may be evaluated against a running target. A
    # blacklist can miss C expression side effects (e.g. pointer calls or
    # comma operators), so reject anything outside this small read grammar.
    $pathPattern = '[A-Za-z_][A-Za-z0-9_]*(?:(?:\.|->)[A-Za-z_][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]*)\])*'
    $numberPattern = '-?(?:0[xX][0-9A-Fa-f]+|(?:0|[1-9][0-9]*)(?:\.[0-9]+)?)'
    $waitAtom = "(?:$pathPattern)(?:\s*(?:==|!=|<=|>=|<|>)\s*(?:$pathPattern|$numberPattern))?"
    $waitPattern = "^\s*$waitAtom(?:\s*(?:&&|\|\|)\s*$waitAtom)*\s*$"
    $readNames = if ($ReadVars) { @($ReadVars -split ',' | ForEach-Object { $_.Trim() }) } else { @() }
    $unsafeRead = @($readNames | Where-Object { $_ -notmatch "^$pathPattern$" })
    if ($ReadVars -and $ReadArray) {
        Out2 "FAILURE: READONLY_MODE_CONFLICT"
        Out2 "RESULT: FAIL"
        Out2 "REASON: -ReadVars and -ReadArray are separate read modes"
        exit 2
    }
    $heartbeatNames = if ($NoHeartbeat) { @() } else { @($HeartbeatExpr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $unsafeHeartbeat = @($heartbeatNames | Where-Object { $_ -notmatch "^$pathPattern$" })
    if ($unsafeRead.Count -gt 0 -or ($WaitFor -and $WaitFor -notmatch $waitPattern) -or
        ($ReadArray -and $ReadArray -notmatch '^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$') -or
        $unsafeHeartbeat.Count -gt 0 -or
        ($ReadArray -and ($ArrayRows -lt 1 -or $ArrayColumns -lt 1 -or $ArrayBatchSize -lt 1 -or
                         ([long]$ArrayRows * [long]$ArrayColumns) -gt 100000)) -or
        $ReadTimeoutSec -lt 1 -or $ReadTimeoutSec -gt 3600) {
        Out2 "FAILURE: READONLY_EXPRESSION_UNSAFE"
        Out2 "RESULT: FAIL"
        Out2 "REASON: use simple read paths, positive bounded array dimensions and a 1..3600 s timeout"
        exit 2
    }
} elseif ($LoadOnly -and $Run) {
    Out2 "FAILURE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -LoadOnly cannot be combined with -Run"
    exit 2
} elseif (-not $Build -and -not $Run -and -not $LoadOnly -and -not $ReadVars -and -not $ReadArray -and -not $ProbeCheckOnly) {
    Out2 "FAILURE: ACTION_REQUIRED"
    Out2 "RESULT: FAIL"
    Out2 "REASON: choose -Build, -Run, -LoadOnly or -ReadOnly -ReadVars; no implicit load-only action"
    exit 2
}
if ($NoHeartbeat) { $HeartbeatExpr = '' }

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

function Get-ConnectedProbes {
    $probePatterns = 'XDS|Texas Instruments.*(Debug|Emulat|Probe)|Debug Probe|Spectrum Digital|Blackhawk|SEGGER|J-Link|ICDI'
    $found = @()
    try {
        $found = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop 2>$null |
                   Where-Object { $_.Name -match $probePatterns })
    } catch { $found = @() }
    if ($found.Count -eq 0) {
        $xdsTool = Join-Path $ccs.Path 'ccs_base\common\uscif\xds100serial.exe'
        if (Test-Path -LiteralPath $xdsTool) {
            $xdsRows = @(& $xdsTool -l 2>$null | Where-Object { $_ -match '^[0-9a-fA-F]{4}/[0-9a-fA-F]{4}\s+XDS100' })
            foreach ($row in $xdsRows) { $found += [pscustomobject]@{ Name = $row.Trim() } }
        }
    }
    return @($found)
}

function Stop-NoProbe {
    Out2 "PROBE   : NOT FOUND"
    Out2 "FAILURE: NO_PROBE"
    Out2 "RESULT: FAIL"
    Out2 "REASON: no JTAG probe enumerated by Windows (checked: XDS*, Spectrum Digital, Blackhawk, SEGGER, Debug Probe)"
    Out2 "HINT    : connect the probe and target board, then ask the operator before retrying"
    exit 3
}

# A hardware run with -Build must stop here if its probe is absent. The
# compiler must not be invoked first and an agent must not retry until the
# operator confirms the physical connection. Build-only remains hardware-free.
if ($ProbeCheckOnly -or ($Build -and ($Run -or $LoadOnly) -and -not $NoProbeCheck)) {
    $preCcxml = $Ccxml
    if (-not $preCcxml) {
        $candidate = Get-ChildItem -Path (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue |
                     Select-Object -First 1
        if ($candidate) { $preCcxml = $candidate.FullName }
    }
    if (-not $preCcxml -or -not (Test-Path -LiteralPath $preCcxml)) {
        Out2 "FAILURE: NO_CCXML"
        Out2 "RESULT: FAIL"
        Out2 "REASON: no .ccxml target configuration found - pass -Ccxml <file>"
        exit 2
    }
    $preIsSim = $false
    try {
        [xml]$preConfig = Get-Content -LiteralPath $preCcxml -Raw
        $preEmu = $preConfig.SelectSingleNode('//configuration/instance[@desc]')
        if ($preEmu -and [string]$preEmu.desc -match 'simulator|tisim') { $preIsSim = $true }
    } catch { }
    if ($preIsSim) {
        Info2 "PROBE   : skipped (simulator target)"
    } else {
        $preProbes = @(Get-ConnectedProbes)
        if ($preProbes.Count -eq 0) { Stop-NoProbe }
        foreach ($item in $preProbes) { Info2 ("PROBE   : {0}" -f $item.Name) }
    }
    if ($ProbeCheckOnly) {
        Out2 "RESULT: OK"
        exit 0
    }
}

# ---------- 2. optional build (same toolchain family) ----------
if ($Build) {
    Info2 "STEP    : build"
    $buildScript = Join-Path $PSScriptRoot 'ti_c2000_build.ps1'
    $bargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript, '-ProjectPath', $ProjectPath, '-KeepLaunches')
    if ($CcsRoot) { $bargs += @('-CcsRoot', $CcsRoot) }
    if ($AllowCompilerFallback) { $bargs += '-AllowCompilerFallback' }
    if ($Run -or $LoadOnly) { $bargs += '-Stage' }
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
    if (-not $Run -and -not $LoadOnly) {
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
$loadedMarker = Join-Path $ProjectPath 'Debug\.ti_c2000_loaded.json'
if ($ReadOnly) {
    if (Test-Path -LiteralPath $loadedMarker) {
        try {
            $loaded = Get-Content -LiteralPath $loadedMarker -Raw | ConvertFrom-Json
            $currentHash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
            if (-not $loaded.outSha256 -or $currentHash -ne [string]$loaded.outSha256) {
                Out2 'FAILURE: SYMBOL_MISMATCH'
                Out2 'RESULT: FAIL'
                Out2 "REASON: $OutFile differs from the last .out loaded by this helper; select matching symbols or verify the current firmware before reading"
                exit 2
            }
            Info2 "SYMBOLS : .out hash matches the last load recorded by this helper"
        } catch {
            Out2 'FAILURE: SYMBOL_RECORD_INVALID'
            Out2 'RESULT: FAIL'
            Out2 "REASON: cannot validate $loadedMarker; $($_.Exception.Message)"
            exit 2
        }
    } else {
        Info2 'WARN    : no helper load record; verify that this .out matches the running firmware before trusting RAM symbols'
    }
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
$probe = @()
if (-not $isSim -and -not $NoProbeCheck) {
    $probe = @(Get-ConnectedProbes)
}
if ($isSim) {
    Info2 "PROBE   : skipped (simulator target, no hardware needed)"
    $probe = @([pscustomobject]@{ Name = 'TI simulator' })
} elseif ($NoProbeCheck) {
    Info2 "PROBE   : check skipped by -NoProbeCheck"
} elseif ($probe.Count -eq 0) {
    Stop-NoProbe
} else {
    foreach ($p in $probe) { Info2 ("PROBE   : {0}" -f $p.Name) }
}
if (@(Get-Process ccstudio, ccstudio64, eclipsec -ErrorAction SilentlyContinue).Count -gt 0) {
    Info2 "WARN    : CCS GUI is running - close any active debug session if the JTAG turns out to be busy"
}

# ---------- 5a. DSS path: read-only values or full load/run/read ----------
if ($ReadVars -or $ReadArray) {
    Out2 'FAILURE: READONLY_UNRELIABLE'
    Out2 'RESULT: FAIL'
    Out2 'REASON: separate read-only sessions cannot prove they read the current RAM firmware; use ti_c2000_run_read.ps1 or ti_c2000_read_dma.ps1 in one session'
    exit 2
    if (-not (Test-Path $dss)) { Out2 "RESULT: FAIL"; Out2 "REASON: dss.bat not found at $dss"; exit 2 }
    $tpl = Join-Path $PSScriptRoot 'dss_template.js'
    if (-not (Test-Path $tpl)) { Out2 "RESULT: FAIL"; Out2 "REASON: dss_template.js missing"; exit 2 }
    $js = Join-Path $env:TEMP ("ti_c2000_dss_{0}.js" -f (Get-Random))
    $body = Get-Content -LiteralPath $tpl -Raw
    if ($RunMs -le 0) { $RunMs = 8000 }   # upper bound for polling; DSP init with OLED/I2C can take seconds
    # Optional readiness condition is polled in the running state. Without it,
    # return the current values immediately; never insert a halt-based wait.
    $waitExpr = $WaitFor
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
    $body = $body.Replace('{{ARRAY_NAME}}', (Escape-JsString $ReadArray))
    $body = $body.Replace('{{ARRAY_ROWS}}', [string]$ArrayRows)
    $body = $body.Replace('{{ARRAY_COLUMNS}}', [string]$ArrayColumns)
    $body = $body.Replace('{{ARRAY_BATCH_SIZE}}', [string]$ArrayBatchSize)
    $body = $body.Replace('{{HEARTBEAT_EXPR}}', (Escape-JsString $HeartbeatExpr))
    $body = $body.Replace('{{USE_BATCH}}', $(if ($PointMode) { '0' } else { '1' }))
    $body = $body.Replace('{{READ_TIMEOUT_MS}}', [string]($ReadTimeoutSec * 1000))
    $body = $body.Replace('{{WAIT_EXPR}}', (Escape-JsString $waitExpr))
    $body = $body.Replace('{{SESSION_PATTERN}}', (Escape-JsString $CorePattern))
    $body | Set-Content -LiteralPath $js -Encoding ASCII
    Info2 "STEP    : DSS read-only values (no build/download/halt, wait='$waitExpr')"
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
    $jsErr    = @($dout | Where-Object { $_ -notmatch '^VAR ' -and $_ -notmatch '^CONNECT_RETRY:' -and $_ -notmatch '\(poll\)' -and $_ -match 'uncaught JavaScript|JavaScript runtime|TypeError|Cannot find function' })
    $varLines = @($dout | Where-Object { $_ -match '^VAR ' -and $_ -notmatch '<ERROR' })
    $varErrors = @($dout | Where-Object { $_ -match '^VAR .*<ERROR:' })
    $connFail = @($dout | Where-Object { $_ -match 'CONNECT_FAILED' })
    $readonlyIssue = @($dout | Where-Object { $_ -match '^READONLY_(STATE_ERROR|STATE_UNKNOWN|CONFIG_ERROR|SYMBOL_ERROR|VALUE_ERROR|HEARTBEAT_ERROR):' })
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
    if ($connFail.Count -gt 0 -or -not $connectedSeen -or ($dcode -ne 0 -and -not $readySeen -and -not $doneSeen)) {
        Out2 "FAILURE: CONNECT_FAILED"
        if ($txt -match 'Error -1133') {
            Out2 "REASON: CCS -1133: target was executing non-debuggable code during realtime connect; bounded read-only retries did not connect"
        } else {
            Out2 "REASON: no debug session could be opened/used (check probe, target power, ccxml/core and other CCS sessions)"
        }
        if ($connFail.Count -gt 0) { Out2 ($connFail | Select-Object -First 1) }
        $diag = @($dout | Where-Object { $_ -match 'Exception|Error parsing|Fatal Error|Cannot' }) | Select-Object -First 2
        foreach ($d in $diag) { Out2 ("    " + $d) }
        Out2 "RESULT: FAIL"
        exit 1
    }
    if ($timedOut.Count -gt 0 -and -not $AllowNotReady) {
        Out2 "FAILURE: TIMEOUT"
        Out2 "REASON: condition not observed in read-only mode; no program was built or downloaded"
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

    # ---------- mandatory verdict: no read may return OK without it ----------
    $verdictScript = Join-Path $PSScriptRoot 'ti_c2000_check_read.ps1'
    if (-not (Test-Path -LiteralPath $verdictScript)) {
        Out2 "FAILURE: ENV_NO_VERDICT_SCRIPT"
        Out2 "RESULT: FAIL"
        Out2 "REASON: ti_c2000_check_read.ps1 is missing; reads are not allowed without the verdict"
        exit 2
    }
    $hbBefore = [ordered]@{}
    $hbAfter = [ordered]@{}
    foreach ($l in $dout) {
        if ([string]$l -match '^HB\s+(\S+)\s+(before|after)\s+=\s+(.+)$') {
            if ($Matches[2] -eq 'before' -and -not $hbBefore.Contains($Matches[1])) { $hbBefore[$Matches[1]] = $Matches[3] }
            if ($Matches[2] -eq 'after') { $hbAfter[$Matches[1]] = $Matches[3] }
        }
    }
    if ($HeartbeatExpr -and ($hbBefore.Count -eq 0 -or $hbAfter.Count -ne $hbBefore.Count)) {
        Out2 'FAILURE: NO_LIVENESS_EVIDENCE'
        Out2 'RESULT: FAIL'
        Out2 'REASON: DSS did not return a complete before/after heartbeat pair'
        exit 1
    }
    $expectedValues = if ($ReadArray) { [long]$ArrayRows * [long]$ArrayColumns } else { $readNames.Count }
    $valueRows = @($varLines | ForEach-Object {
        if ([string]$_ -match '^VAR\s+(.+?)\s+=\s+(.+)$') {
            [pscustomobject]@{ expression = $Matches[1]; value = $Matches[2] }
        }
    })
    if ($valueRows.Count -ne $expectedValues) {
        Out2 'FAILURE: INCOMPLETE_VALUES'; Out2 'RESULT: FAIL'
        Out2 ("REASON: parsed {0}/{1} requested values" -f $valueRows.Count, $expectedValues); exit 1
    }
    $numericCsv = Join-Path $env:TEMP ("ti_c2000_values_{0}.csv" -f ([guid]::NewGuid().ToString('N')))
    $valueRows | Select-Object -Property value | Export-Csv -LiteralPath $numericCsv -NoTypeInformation -Encoding UTF8
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
    $numericOut = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $verdictScript -CsvPath $numericCsv -AllowNoHeartbeat -ExpectedRows $expectedValues -RangeVars value 2>&1
    $numericCode = $LASTEXITCODE
    Remove-Item -LiteralPath $numericCsv -Force -ErrorAction SilentlyContinue
    foreach ($l in $numericOut) { if ([string]$l -notmatch '^RESULT: ') { Out2 ([string]$l) } }
    if ($numericCode -ne 0 -or -not @($numericOut | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
        Out2 'FAILURE: VERDICT_FAILED'; Out2 'RESULT: FAIL'
        Out2 'REASON: a requested data value is missing or not a finite number'; exit 1
    }
    $tmpCsv = Join-Path $env:TEMP ("ti_c2000_verdict_{0}.csv" -f (Get-Random))
    $vf = New-Object System.Text.UTF8Encoding($true)
    $sw = New-Object System.IO.StreamWriter($tmpCsv, $false, $vf)
    try {
        if ($hbBefore.Count -gt 0) {
            $sw.WriteLine((@($hbBefore.Keys) -join ','))
            $sw.WriteLine((@($hbBefore.Values) -join ','))
            $sw.WriteLine((@($hbBefore.Keys | ForEach-Object { $hbAfter[$_] }) -join ','))
        } else {
            $sw.WriteLine('status')
            $sw.WriteLine('1')
        }
    } finally { $sw.Dispose() }
    $vargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verdictScript,
               '-CsvPath', $tmpCsv)
    if ($hbBefore.Count -gt 0) { $vargs += @('-HeartbeatVars', (@($hbBefore.Keys) -join ',')) }
    else { $vargs += '-AllowNoHeartbeat' }
    $vout = & $pwshExe @vargs 2>&1
    $vcode = $LASTEXITCODE
    foreach ($l in $vout) { if ([string]$l -notmatch '^RESULT: ') { Out2 ([string]$l) } }
    Remove-Item -LiteralPath $tmpCsv -Force -ErrorAction SilentlyContinue
    if ($vcode -ne 0) {
        Out2 "FAILURE: VERDICT_FAILED"
        Out2 "REASON: read data did not pass the mandatory verdict (references/data-read-verdict.md)"
        Out2 "RESULT: FAIL"
        exit 1
    }

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
# PowerShell 7 can throw StandardOutputEncoding before a .bat starts. Use
# cmd.exe through ProcessStartInfo so paths containing spaces retain cmd's
# required quoting; PowerShell's native argument re-quoting is bypassed.
function Quote-CmdArgument([string]$value) {
    if ($value -match '["%\r\n]') { throw "unsupported character in loadti path or argument" }
    return '"' + $value + '"'
}
try {
    $command = (Quote-CmdArgument $loadti) + ' ' + (($ltArgs | ForEach-Object { Quote-CmdArgument $_ }) -join ' ')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    $start.Arguments = '/d /v:off /s /c "' + $command + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $waitMs = [int][Math]::Min(2147483647L, ([long]$TimeoutSec * 1000L + 30000L))
    $expired = -not $process.WaitForExit($waitMs)
    if ($expired) { $process.Kill($true); $process.WaitForExit() }
    $out = @((($stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()) -split '\r?\n') |
             Where-Object { $_ -ne '' })
    $code = $process.ExitCode
    $process.Dispose()
} catch {
    Out2 "FAILURE: LOADTI_LAUNCH_ERROR"
    Out2 "RESULT: FAIL"
    Out2 "REASON: loadti could not be started: $($_.Exception.Message)"
    exit 1
}
if (-not $Quiet) { $out | Select-Object -Last 25 | ForEach-Object { Out2 $_ } }
$bad    = @($out | Where-Object { $_ -match 'error|failed|cannot|aborted' })
$ldDone = @($out | Where-Object { $_ -match '\bDone\b' })
$runSeen = @($out | Where-Object { $_ -match '^Target running\.\.\.' })
if ($expired -or $code -ne 0 -or $bad.Count -gt 0 -or $ldDone.Count -eq 0 -or ($Run -and $runSeen.Count -eq 0)) {
    if ($expired) {
        Out2 "FAILURE: LOADTI_TIMEOUT"
        Out2 "REASON: loadti exceeded its $TimeoutSec s target timeout"
    } elseif ($code -ne 0 -or $bad.Count -gt 0) {
        Out2 "FAILURE: LOADTI_ERROR"
        Out2 "REASON: loadti exited with code $code or reported an error"
        $bad | Select-Object -First 3 | ForEach-Object { Out2 ("    " + $_) }
    } else {
        Out2 "FAILURE: LOADTI_INCOMPLETE"
        Out2 "REASON: loadti exited without the required Done and Target running markers"
    }
    Out2 "RESULT: FAIL"
    exit 1
}
if ($LoadOnly) { Out2 "NOTE    : program loaded and halted (no run requested)" }
elseif ($Run)  { Out2 "NOTE    : program started on target (async run)" }
try {
    $record = [ordered]@{
        outPath = [IO.Path]::GetFullPath($OutFile)
        outSha256 = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
        ccxmlPath = [IO.Path]::GetFullPath($Ccxml)
        mode = if ($Run) { 'run' } else { 'load-only' }
        loadedAt = (Get-Date).ToString('o')
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $loadedMarker -Parent) | Out-Null
    $markerTemp = "$loadedMarker.tmp"
    $record | ConvertTo-Json | Set-Content -LiteralPath $markerTemp -Encoding UTF8
    Move-Item -LiteralPath $markerTemp -Destination $loadedMarker -Force
} catch {
    Out2 'FAILURE: LOAD_RECORD_ERROR'
    Out2 'RESULT: FAIL'
    Out2 "REASON: target load succeeded, but symbol identity record could not be saved: $($_.Exception.Message)"
    exit 1
}
Out2 "RESULT: OK"
exit 0
