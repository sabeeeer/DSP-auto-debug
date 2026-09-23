# =====================================================================
# ti_c2000_build.ps1
#   Compile + link self-check for TI C2000 CCS projects WITHOUT the CCS GUI.
#
#   Device agnostic: everything that differs between C2000 families
#   (F2833x / F2802x / F2806x / F2837x / F28004x / ...) is read back from
#   .cproject instead of being hard coded:
#     - include paths, silicon version (-v28/-v29), memory model (-ml),
#       unified memory (-mt), float support (fpu32/fpu64/softlib)
#     - codegen version -> the matching ti-cgt-c2000_* tool chain
#     - linker command file + device "*Headers*.cmd", extra *.lib
#     - runtime library: COFF vs EABI naming, fpu32/fpu64/softlib
#
#   Usage:
#     powershell -ExecutionPolicy Bypass -File ti_c2000_build.ps1 -ProjectPath <proj>
#     ... -CcsRoot D:\path\to\ccs         force a CCS installation
#     ... -CompilerRoot <ti-cgt-c2000_x.y.z.LTS>
#     ... -LinkCmd "extra1.cmd,extra2.cmd"  add linker command files
#     ... -IgnoreExclusions                also build/link resources excluded in .cproject
#     ... -OutputDir <dir>                 object/map/log location (default: %TEMP%\ti_c2000_build\<proj>;
#                                          keep it OUTSIDE the project - see the note at step 5)
#     ... -Clean | -Quiet | -NoStage
#   Exit code: 0 = compile AND link OK, 1 = failed, 2 = environment problem
#
#   What CCS really builds (and this script mirrors):
#     * sources: every .c/.asm under the project EXCEPT the ones listed in
#       <sourceEntries><entry excluding="a|b|...">  (real projects keep other
#       devices' sources in the tree and "exclude from build" them)
#     * linker inputs: the *.cmd and *.lib files in the project EXCEPT excluded ones.
#       CCS passes them all to the linker (LINKER_COMMAND_FILE is just one of them),
#       so blindly taking every "*Headers*.cmd" fails on projects that also keep
#       F2803x/F2802x/F2806x cmd files:
#         error #10263: ... memory range has already been specified
#         error #10264: ... memory range overlaps existing memory range ...
#       and compiling excluded sources fails with:
#         error #10056: symbol "..." redefined
# =====================================================================
param(
    [string]$ProjectPath  = "",
    [string]$CcsRoot      = "",
    [string]$CompilerRoot = "",
    [string]$LinkCmd      = "",
    [string]$OutputDir    = "",
    [switch]$Clean,
    [switch]$Quiet,
    [switch]$NoStage,
    [switch]$IgnoreExclusions
)

$ErrorActionPreference = 'Continue'   # native compiler stderr must not abort the loop
$sw = [Diagnostics.Stopwatch]::StartNew()

function Fail([string]$msg, [int]$code, [string]$failure = 'ENV') {
    Write-Output ("FAILURE: {0}" -f $failure)
    Write-Output "RESULT: FAIL"
    Write-Output "REASON: $msg"
    exit $code
}
function Info([string]$msg) { if (-not $Quiet) { Write-Output $msg } }

# ---------- 1. locate project root ----------
if (-not $ProjectPath) {
    $d = Get-Item -LiteralPath (Get-Location).Path
    while ($d) {
        if (Test-Path (Join-Path $d.FullName '.cproject')) { $ProjectPath = $d.FullName; break }
        $d = $d.Parent
    }
}
if (-not $ProjectPath -or -not (Test-Path (Join-Path $ProjectPath '.cproject'))) {
    Fail "no .cproject found; pass -ProjectPath <project folder>" 2 'NO_PROJECT'
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName
Info "PROJECT : $ProjectPath"

# ---------- 2. discover CCS installations ----------
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
$ccsRoots = @()
if ($CcsRoot -and (Test-Path (Join-Path $CcsRoot 'ccs_base'))) {
    $ccsRoots = @([pscustomobject]@{ Path = (Get-Item -LiteralPath $CcsRoot).FullName; Version = 'forced' })
} else {
    $ccsRoots = Get-CcsRoots
}
Info ("CCS     : " + (($ccsRoots | ForEach-Object { "$($_.Path) [$($_.Version)]" }) -join ' | '))

# ---------- 3. read .cproject ----------
[xml]$cproj = Get-Content -LiteralPath (Join-Path $ProjectPath '.cproject') -Raw
$projName = (Split-Path $ProjectPath -Leaf)
if (Test-Path (Join-Path $ProjectPath '.project')) {
    try {
        [xml]$prj = Get-Content -LiteralPath (Join-Path $ProjectPath '.project') -Raw
        if ($prj.projectDescription.name) { $projName = $prj.projectDescription.name }
    } catch { }
}
# ---- pick the build configuration whose options are used ----
# A .cproject may declare several configurations (Debug / Release / F2837xD_CPU1 ...) plus a
# <refreshScope> block that also contains <configuration> nodes but has no @id - those must not
# be mistaken for a build configuration.  CCS writes its build output into <project>\<config name>,
# so an existing folder with the configuration's name is the strongest hint; then a name/parent
# containing "Debug"; then the first one.
$cfgCands = @($cproj.SelectNodes('//configuration[@id]'))
$cfg = $null
foreach ($c in $cfgCands) {
    $nm = [string]$c.name
    if ($nm -and (Test-Path -LiteralPath (Join-Path $ProjectPath $nm))) { $cfg = $c; break }
}
if (-not $cfg) { foreach ($c in $cfgCands) { if ([string]$c.name -match 'Debug' -or [string]$c.parent -match 'Debug') { $cfg = $c; break } } }
if (-not $cfg -and $cfgCands.Count -gt 0) { $cfg = $cfgCands[0] }
$cfgId = ''; $cfgName = ''
if ($cfg) { $cfgId = [string]$cfg.id; $cfgName = [string]$cfg.name }

function Get-OptionNode([string]$idPart) {
    if ($cfgId) {
        $n = $cproj.SelectSingleNode("//cconfiguration[@id='$cfgId']//option[contains(@id,'$idPart')]")
        if (-not $n) { $n = $cproj.SelectSingleNode("//cconfiguration[@id='$cfgId']//option[contains(@superClass,'$idPart')]") }
        if ($n) { return $n }
    }
    $n = $cproj.SelectSingleNode("//cconfiguration[contains(@id,'Debug')]//option[contains(@id,'$idPart')]")
    if (-not $n) { $n = $cproj.SelectSingleNode("//option[contains(@id,'$idPart')]") }
    if (-not $n) { $n = $cproj.SelectSingleNode("//option[contains(@superClass,'$idPart')]") }
    return $n
}

# list-valued option (--define, --include_path, --search_path, --diag_suppress, ...)
function Get-OptionList([string]$idPart) {
    $vals = @()
    $node = Get-OptionNode $idPart
    if ($node) {
        foreach ($v in $node.listOptionValue) {
            $s = ([string]$v.value).Trim()
            if ($s) { $vals += $s }
        }
    }
    return $vals
}
function Get-OptionValue([string]$idPart, [string]$default = "") {
    $n = Get-OptionNode $idPart
    if ($n -and $n.value) { return [string]$n.value }
    return $default
}

# ---- "exclude from build" list declared in .cproject ----
# Eclipse stores it as  <sourceEntries><entry excluding="a|b|dir/|..."/>  (project relative,
# '/'-separated; a trailing '/' means a whole folder).  CCS does not compile or link these,
# so neither may this script - otherwise a project that keeps another device's commands
# files / sources in the tree reports bogus LINK_ERRORS.
$excludeFiles = New-Object System.Collections.ArrayList
$excludeDirs  = New-Object System.Collections.ArrayList
foreach ($entry in $cproj.SelectNodes('//sourceEntries/entry')) {
    $ex = [string]$entry.excluding
    if (-not $ex) { continue }
    foreach ($e in ($ex -split '\|')) {
        $p = $e.Trim().Replace('\', '/').TrimStart('/')
        if (-not $p) { continue }
        if ($p.EndsWith('/')) { [void]$excludeDirs.Add($p) } else { [void]$excludeFiles.Add($p) }
    }
}
function Test-Excluded([string]$fullPath) {
    if ($IgnoreExclusions) { return $false }
    if ($excludeFiles.Count -eq 0 -and $excludeDirs.Count -eq 0) { return $false }
    $rel = $fullPath.Substring($script:ProjectPath.Length).TrimStart('\', '/').Replace('\', '/')
    foreach ($d in $excludeDirs) {
        if ($rel.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($x in $excludeFiles) {
        if ($rel.Equals($x, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($rel.StartsWith($x + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ---- codegen / device knobs straight from the project ----
$cgVersion = Get-OptionValue 'OPT_CODEGEN_VERSION'
$siliconVer = '28'
$v = Get-OptionValue 'compilerID.SILICON_VERSION'
if ($v -match '\.(\d+)\s*$') { $siliconVer = $Matches[1] }
$largeMem = (Get-OptionValue 'compilerID.LARGE_MEMORY_MODEL') -eq 'true'
$unified  = (Get-OptionValue 'compilerID.UNIFIED_MEMORY')    -eq 'true'
$fs       = Get-OptionValue 'compilerID.FLOAT_SUPPORT'
$stackSz  = Get-OptionValue 'linkerID.STACK_SIZE' '0x300'
$outFormat = 'COFF'
$n = $cproj.SelectSingleNode("//listOptionValue[contains(@value,'OUTPUT_FORMAT=')]")
if ($n) { $outFormat = ([string]$n.value) -replace '.*OUTPUT_FORMAT=', '' }
$romModel = '--rom_model'
if ((Get-OptionValue 'linkerID.RAM_MODEL') -eq 'true') { $romModel = '--ram_model' }

# ---- the rest of the project's switches, so exactly the same code paths get compiled ----
# (without -D the #ifdef FLASH / #ifdef PC_COMMU_ENABLE ... branches are compiled differently
#  from CCS and the check would validate something the board never runs)
$defines = @(Get-OptionList 'compilerID.DEFINE')
$optLevel = ''
$v = Get-OptionValue 'compilerID.OPT_LEVEL'
if ($v -match 'OPT_LEVEL\.(\d+)\s*$') { $optLevel = "-O" + $Matches[1] }
$mfOpt = ''
$v = Get-OptionValue 'compilerID.OPT_FOR_SPEED'
if ($v -match 'OPT_FOR_SPEED\.(\d+)\s*$') { $mfOpt = "-mf" + $Matches[1] }
$fpMode = ''
$v = Get-OptionValue 'compilerID.FP_MODE'
if ($v -match 'FP_MODE\.(\w+)\s*$') { $fpMode = "--fp_mode=" + $Matches[1] }
$relaxedAnsi = ((Get-OptionValue 'compilerID.LANGUAGE_MODE') -match 'RELAXED_ANSI')
$diagWarn = @(Get-OptionList 'compilerID.DIAG_WARNING')
if ($diagWarn.Count -eq 0) { $diagWarn = @('225') }
$diagSuppress = @(Get-OptionList 'compilerID.DIAG_SUPPRESS')
$otherFlags   = @(Get-OptionList 'compilerID.OTHER_FLAGS')
$lnkSearch    = @(Get-OptionList 'linkerID.SEARCH_PATH')
$lnkDiagSupp  = @(Get-OptionList 'linkerID.DIAG_SUPPRESS')
$lnkPriority  = (Get-OptionValue 'linkerID.PRIORITY') -eq 'true'

# ---- compiler root ----
$cgRoot = ""
if ($CompilerRoot) {
    if (Test-Path (Join-Path $CompilerRoot 'bin\cl2000.exe')) { $cgRoot = (Get-Item -LiteralPath $CompilerRoot).FullName }
    else { Fail "-CompilerRoot does not contain bin\cl2000.exe: $CompilerRoot" 2 'ENV_BAD_ARG' }
}
if (-not $cgRoot) {
    foreach ($root in $ccsRoots) {
        if ($cgVersion) {
            $cand = Join-Path $root.Path "tools\compiler\ti-cgt-c2000_$cgVersion"
            if (Test-Path (Join-Path $cand 'bin\cl2000.exe')) { $cgRoot = $cand; break }
        }
        $newest = @(Get-ChildItem (Join-Path $root.Path 'tools\compiler') -Directory -Filter 'ti-cgt-c2000_*' -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending) | Select-Object -First 1
        if ($newest) {
            $cgRoot = $newest.FullName
            if ($cgVersion -and $newest.Name -ne "ti-cgt-c2000_$cgVersion") {
                Info "NOTE    : .cproject declares $cgVersion, not installed in $($root.Path); using $($newest.Name)"
            }
            break
        }
    }
}
if (-not $cgRoot) {
    # last resort: TI default install locations (use -CcsRoot for anything else)
    $c = @(Get-ChildItem 'C:\ti', "$env:USERPROFILE\ti" -Recurse -Directory -Filter 'ti-cgt-c2000_*' -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending) | Select-Object -First 1
    if ($c) { $cgRoot = $c.FullName }
}
if (-not $cgRoot) { Fail "no TI C2000 codegen tools found (check your CCS installation)" 2 'ENV_NO_COMPILER' }
$cl2000 = Join-Path $cgRoot 'bin\cl2000.exe'
if (-not (Test-Path $cl2000)) { Fail "cl2000.exe not found under $cgRoot" 2 'ENV_NO_COMPILER' }

# ---- include paths ----
$incNode = Get-OptionNode 'compilerID.INCLUDE_PATH'
$rawInc = @()
if ($incNode) { foreach ($x in $incNode.listOptionValue) { $rawInc += [string]$x.value } }
$includes = @()
foreach ($p in $rawInc) {
    $q = ([string]$p).Trim('"')
    $q = $q.Replace('${workspace_loc:/${ProjName}}', $ProjectPath)
    $q = $q.Replace('${workspace_loc:/${ProjName}/', ($ProjectPath + '\'))
    $q = $q.Replace('${ProjName}', $projName)
    $q = $q.Replace('${CG_TOOL_ROOT}', $cgRoot)
    $q = $q -replace '/', '\'
    $q = $q.Trim('"').TrimEnd('}')
    if ($q -and -not (Test-Path -LiteralPath $q)) {
        # include path declared in the project but missing on disk (other PC / moved project):
        # CCS would fail here; we skip it and keep compiling, but say it loudly - otherwise the
        # later "cannot open source file" error is hard to trace back to its cause.
        Info "WARNING : include path missing on disk, skipped -> $q"
        continue
    }
    $includes += $q
}
if (-not $includes) { Fail "no usable include path parsed from .cproject" 2 'ENV_BAD_CPROJECT' }

# ---- device family fingerprint (for the log + docs, not for logic) ----
$devHdr = ''
$knownHdr = @('DSP2833x_Device.h','DSP2834x_Device.h','DSP2823x_Device.h','F2802x_Device.h','F2803x_Device.h',
              'F2805x_Device.h','F2806x_Device.h','F2837xD_Device.h','F2837xS_Device.h','F2807x_Device.h',
              'F2838x_Device.h','F28004x_Device.h','F28003x_Device.h','F28M35x_Device.h','F29H85x_Device.h',
              'driverlib.h','device.h')
foreach ($d in ($includes + $ProjectPath)) {
    foreach ($h in $knownHdr) { if (Test-Path (Join-Path $d $h)) { $devHdr = $h; break } }
    if ($devHdr) { break }
}
$devNote = ''
if ($devHdr -match 'driverlib\.h|^device\.h$') { $devNote = ' (driverlib/SysConfig style: expect EABI + *_eabi.lib)' }

# ---- runtime library ----
$floatFlag = '--float_support=fpu32'
$base = 'rts2800_fpu32'
if ($fs -match 'fpu64') { $base = 'rts2800_fpu64'; $floatFlag = '--float_support=fpu64' }
elseif ($fs -match 'softlib') { $base = 'rts2800_ml'; $floatFlag = '--float_support=softlib' }
elseif ($fs -match 'none') { $base = 'rts2800_ml'; $floatFlag = '--float_support=none' }
$rtsCandidates = @()
if ($outFormat -match 'EABI') { $rtsCandidates += "$base`_eabi.lib" }
$rtsCandidates += "$base.lib"
if ($base -ne 'rts2800_ml') { $rtsCandidates += 'rts2800_ml.lib' }
$rts = $null
foreach ($c in $rtsCandidates) { if (Test-Path (Join-Path $cgRoot "lib\$c")) { $rts = $c; break } }
if (-not $rts) { Fail "no runtime library found under $cgRoot\lib (tried: $($rtsCandidates -join ', '))" 2 'ENV_NO_RUNTIME' }

Info ("DEVICE  : {0}{1}" -f $(if ($devHdr) { $devHdr } else { '<unknown device header>' }), $devNote)
Info ("CONFIG  : {0}{1}" -f $(if ($cfgName) { $cfgName } else { '<first configuration>' }),
      $(if ($IgnoreExclusions) { '   (-IgnoreExclusions)' } else { '' }))
Info ("COMPILER: {0}" -f $cgRoot)
Info ("OPTIONS : -v{0}{1}{2} {3}{4}{5}{6}{7} | {8} | runtime {9}" -f $siliconVer,
      $(if ($largeMem) { ' -ml' } else { '' }), $(if ($unified) { ' -mt' } else { '' }), $floatFlag,
      $(if ($optLevel) { " $optLevel" } else { '' }), $(if ($mfOpt) { " $mfOpt" } else { '' }),
      $(if ($fpMode) { " $fpMode" } else { '' }), $(if ($relaxedAnsi) { ' --relaxed_ansi' } else { '' }),
      $outFormat, $rts)
Info ("DEFINES : {0}" -f $(if ($defines.Count -gt 0) { ($defines -join ', ') } else { '<none>' }))

# ---- linker command files ----
$lnkCmd = ""
$n = $cproj.SelectSingleNode("//listOptionValue[contains(@value,'LINKER_COMMAND_FILE=')]")
if ($n) { $lnkCmd = ([string]$n.value) -replace '.*LINKER_COMMAND_FILE=', '' }
$cmdFiles = @()
if ($lnkCmd) {
    $f = Get-ChildItem -Path $ProjectPath -Recurse -Filter $lnkCmd -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch '\\Debug\\' } | Select-Object -First 1
    if ($f) { $cmdFiles += $f.FullName }
}
$allCmd = @(Get-ChildItem -Path $ProjectPath -Recurse -Filter '*.cmd' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\Debug\\' })
$cmdExcluded = @($allCmd | Where-Object { Test-Excluded $_.FullName })
$cmdActive   = @($allCmd | Where-Object { -not (Test-Excluded $_.FullName) } | Sort-Object Name)
# CCS's managed build hands EVERY *.cmd of the project to the linker - which is exactly why
# other devices' cmd files have to be marked "exclude from build" in .cproject.  So collect
# them all here instead of guessing by the "Headers" name.
foreach ($f in $cmdActive) {
    if ($cmdFiles -notcontains $f.FullName) { $cmdFiles += $f.FullName }
}
if ($cmdExcluded.Count -gt 0) {
    Info ("EXCLUDED: .cmd skipped (exclude from build in .cproject): " + (($cmdExcluded | ForEach-Object { $_.Name }) -join ', '))
}
if ($LinkCmd) {
    foreach ($c in ($LinkCmd -split ',')) {
        $cn = $c.Trim()
        if (-not $cn) { continue }
        $f = if (Test-Path $cn) { Get-Item -LiteralPath $cn } else {
            Get-ChildItem -Path $ProjectPath -Recurse -Filter $cn -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\Debug\\' } | Select-Object -First 1
        }
        if ($f) { if ($cmdFiles -notcontains $f.FullName) { $cmdFiles += $f.FullName } }
        else { Fail "-LinkCmd file not found: $cn" 2 'ENV_BAD_ARG' }
    }
}
$unusedCmd = @($cmdActive | Where-Object { $cmdFiles -notcontains $_.FullName })
if ($unusedCmd.Count -gt 0) {
    Info ("NOTE    : .cmd files NOT linked (use -LinkCmd to add): " + (($unusedCmd | ForEach-Object { $_.Name }) -join ', '))
}
if ($cmdFiles.Count -eq 0) { Info "WARNING : no linker command file used - the link will probably fail" }

# ---- libraries referenced by the project (same rule: every *.lib except excluded ones) ----
$allLibs = @(Get-ChildItem -Path $ProjectPath -Recurse -Filter '*.lib' -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch '\\Debug\\' })
$libExcluded = @($allLibs | Where-Object { Test-Excluded $_.FullName })
$libs = @($allLibs | Where-Object { -not (Test-Excluded $_.FullName) } | ForEach-Object { $_.FullName })
if ($libExcluded.Count -gt 0) {
    Info ("EXCLUDED: .lib skipped (exclude from build in .cproject): " + (($libExcluded | ForEach-Object { $_.Name }) -join ', '))
}

# ---------- 4. sources ----------
$srcRoots = @()
foreach ($sub in @('APP', 'User', 'DSP2833x_Libraries')) {
    $p = Join-Path $ProjectPath $sub
    if (Test-Path $p) { $srcRoots += $p }
}
if ($srcRoots.Count -eq 0) { $srcRoots = @($ProjectPath) }
$srcAll = @(Get-ChildItem -Path $srcRoots -Recurse -File -Include '*.c', '*.asm' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\Debug\\' -and $_.FullName -notmatch '\\auto_build\\' })
$srcExcluded = @($srcAll | Where-Object { Test-Excluded $_.FullName })
$cfiles = @($srcAll | Where-Object { -not (Test-Excluded $_.FullName) } | ForEach-Object { $_.FullName })
if ($cfiles.Count -eq 0) { Fail "no C/ASM sources found under: $($srcRoots -join ', ')" 2 'NO_SOURCES' }
if ($srcExcluded.Count -gt 0) {
    Info ("EXCLUDED: source skipped (exclude from build in .cproject): " + (($srcExcluded | ForEach-Object { $_.Name }) -join ', '))
}
Info "SOURCES : $($cfiles.Count) file(s)"

# ---------- 5. output dir ----------
# NEVER put the object files inside the project tree.
# CCS's managed build hands EVERY *.obj found in the project to the linker (exactly the same
# rule as for .cmd/.lib), so a scratch dir such as <project>\Debug\auto_build\obj makes the
# CCS GUI build fail with hundreds of lines like
#     error #10056: symbol "_InitAdc" redefined:
#         first defined in "../Debug/auto_build/obj/DSP2833x_Adc.obj";
#         redefined in "./HW_Configuration/.../DSP2833x_Adc.obj"
# (its own fresh objects collide with our copies).  So the default lives in %TEMP%.
if (-not $OutputDir) { $OutputDir = Join-Path ([IO.Path]::GetTempPath()) ("ti_c2000_build\" + $projName) }
$objDir = Join-Path $OutputDir 'obj'
# leftover scratch from an earlier version of this script, still inside the project -> remove it,
# otherwise the CCS GUI keeps linking those stale objects together with its own
$legacyObj = Join-Path $ProjectPath 'Debug\auto_build\obj'
if ((Test-Path -LiteralPath $legacyObj) -and -not $legacyObj.StartsWith($objDir, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $legacyObj -Recurse -Force
    Info ("NOTE    : removed stale in-project objects (the CCS GUI would link them a second time): $legacyObj")
}
if ($OutputDir.StartsWith($ProjectPath, [StringComparison]::OrdinalIgnoreCase)) {
    Info ("WARNING : -OutputDir is inside the project: $OutputDir")
    Info "          CCS links every *.obj in the project tree, so a CCS GUI build will now fail with"
    Info "          '#10056 symbol ... redefined'. Use a directory outside the project instead."
}
if ($Clean -and (Test-Path -LiteralPath $OutputDir)) { Remove-Item -LiteralPath $OutputDir -Recurse -Force }
# always start from an empty object dir: stale .obj of deleted sources must never be linked in
if (Test-Path -LiteralPath $objDir) { Remove-Item -LiteralPath $objDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $objDir | Out-Null
$logFile = Join-Path $OutputDir 'build.log'
$log = New-Object System.Collections.Generic.List[string]

# ---------- 6. compile ----------
$cflags = @("-v$siliconVer", '-g', '--display_error_number', '--diag_wrap=off', '-c')
if ($largeMem) { $cflags += '-ml' }
if ($unified)  { $cflags += '-mt' }
$cflags += $floatFlag
if ($optLevel)    { $cflags += $optLevel }
if ($mfOpt)       { $cflags += $mfOpt }
if ($fpMode)      { $cflags += $fpMode }
if ($relaxedAnsi) { $cflags += '--relaxed_ansi' }
foreach ($d in $diagWarn)     { $cflags += "--diag_warning=$d" }
foreach ($d in $diagSuppress) { $cflags += "--diag_suppress=$d" }
foreach ($d in $otherFlags)   { $cflags += $d }
foreach ($d in $defines)      { $cflags += "-D$d" }
$incArgs = @()
foreach ($i in $includes) { $incArgs += "--include_path=$i" }

$compileErrors = @()
$warningCount = 0
$idx = 0
$dupBase = @{}
foreach ($f in $cfiles) {
    $b = [IO.Path]::GetFileNameWithoutExtension($f)
    if ($dupBase.ContainsKey($b)) { $dupBase[$b] = $true } else { $dupBase[$b] = $false }
}
$renameNote = @()
foreach ($f in $cfiles) {
    $idx++
    $base = [IO.Path]::GetFileNameWithoutExtension($f)
    if (-not $Quiet) { Write-Output ("[{0,3}/{1}] {2}" -f $idx, $cfiles.Count, (Split-Path $f -Leaf)) }
    $out = & $cl2000 @cflags @incArgs "--obj_directory=$objDir" $f 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) {
        $s = [string]$line
        $log.Add($s)
        if ($s -match 'warning') { $warningCount++ }
        if ($code -ne 0 -and ($s -match 'error')) {
            $short = $s.Trim()
            if ($short.Length -gt 300) { $short = $short.Substring(0, 300) }
            if ($compileErrors -notcontains $short) { $compileErrors += $short }
        }
    }
    if ($code -ne 0) { $compileErrors += "FAILED FILE: $f" }
    # same-named sources in different folders produce the same <name>.obj and the later one
    # silently overwrites the earlier (the link would drop a whole module) -> rename at once
    if ($code -eq 0 -and $dupBase[$base]) {
        $objPath = Join-Path $objDir "$base.obj"
        if (Test-Path -LiteralPath $objPath) {
            $parent  = Split-Path (Split-Path $f -Parent) -Leaf
            $newName = "${base}_${parent}.obj"
            $k = 1
            while (Test-Path -LiteralPath (Join-Path $objDir $newName)) { $newName = "${base}_${parent}$k.obj"; $k++ }
            Move-Item -LiteralPath $objPath -Destination (Join-Path $objDir $newName) -Force
            $renameNote += "$base.obj->$newName"
        }
    }
}
if ($renameNote.Count -gt 0) {
    Info ("NOTE    : duplicate source names got unique objects: " + ($renameNote -join ', '))
}

# ---------- 7. link ----------
$linkErrors = @()
$outFile = Join-Path $OutputDir "$projName.out"
# the staged copy stays inside the project on purpose: ti_c2000_debug.ps1 / loadti load it from
# there, and a lone .out is NOT a link input for the CCS build (unlike .obj/.cmd/.lib)
$stagedOut = Join-Path $ProjectPath "Debug\$projName.out"
if ($compileErrors.Count -eq 0) {
    $objs = @(Get-ChildItem -Path $objDir -Filter '*.obj' | ForEach-Object { $_.FullName })
    $lflags = @("-v$siliconVer", '-g', '--display_error_number', '--diag_warning=225', '--diag_wrap=off', '-z',
               "-m$OutputDir\$projName.map", "--stack_size=$stackSz", '--warn_sections',
               "-i$cgRoot\lib", "-i$cgRoot\include", '--reread_libs', $romModel)
    if ($lnkPriority) { $lflags += '--priority' }
    foreach ($d in $lnkDiagSupp) { $lflags += "--diag_suppress=$d" }
    # the project's own library search paths (--search_path), macros expanded, existing ones only
    foreach ($p in $lnkSearch) {
        $q = ([string]$p).Trim('"')
        $q = $q.Replace('${workspace_loc:/${ProjName}}', $ProjectPath)
        $q = $q.Replace('${workspace_loc:/${ProjName}/', ($ProjectPath + '\'))
        $q = $q.Replace('${ProjName}', $projName)
        $q = $q.Replace('${CG_TOOL_ROOT}', $cgRoot)
        $q = $q -replace '/', '\'
        $q = $q.TrimEnd('}')
        if ($q -and (Test-Path -LiteralPath $q)) { $lflags += "-i$q" }
    }
    $lnkArgs = @()
    foreach ($o in $objs) { $lnkArgs += $o }
    foreach ($c in $cmdFiles) { $lnkArgs += $c }
    foreach ($l in $libs) { $lnkArgs += $l }
    # runtime library: if the project ships its own copy, that is what CCS links - use it and
    # do not append the compiler's copy on top
    if (@($libs | Where-Object { (Split-Path $_ -Leaf) -ieq $rts }).Count -gt 0) {
        Info ("NOTE    : runtime library taken from the project: $rts")
    } else {
        $lnkArgs += (Join-Path $cgRoot "lib\$rts")
    }
    $lnkArgs += "-o$outFile"
    $out = & $cl2000 @lflags @lnkArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) {
        $s = [string]$line
        $log.Add($s)
        if ($s -match 'error' -or $s -match 'undefined') {
            $short = $s.Trim()
            if ($short.Length -gt 300) { $short = $short.Substring(0, 300) }
            if ($linkErrors -notcontains $short) { $linkErrors += $short }
        }
    }
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $outFile)) { $linkErrors += "LINK FAILED (exit $code)" }
}

# ---------- 8. report ----------
$log | Set-Content -LiteralPath $logFile -Encoding UTF8
$sw.Stop()
$ok = ($compileErrors.Count -eq 0 -and $linkErrors.Count -eq 0)

Write-Output ""
Write-Output "================ BUILD SUMMARY ================"
Write-Output ("project   : {0}" -f $projName)
Write-Output ("device    : {0}{1}" -f $(if ($devHdr) { $devHdr } else { 'unknown' }), $devNote)
Write-Output ("config    : {0}" -f $(if ($cfgName) { $cfgName } else { '<first configuration>' }))
Write-Output ("compiler  : {0}" -f $cgRoot)
Write-Output ("linkcmd   : {0}" -f (($cmdFiles | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))
Write-Output ("sources   : {0}   warnings: {1}" -f $cfiles.Count, $warningCount)
Write-Output ("compile   : {0}" -f $(if ($compileErrors.Count -eq 0) { 'OK' } else { "FAILED ($($compileErrors.Count) message(s))" }))
Write-Output ("link      : {0}" -f $(if ($compileErrors.Count -ne 0) { 'SKIPPED' } elseif ($linkErrors.Count -eq 0) { 'OK' } else { "FAILED ($($linkErrors.Count) message(s))" }))
Write-Output ("elapsed   : {0:n1} s" -f $sw.Elapsed.TotalSeconds)
if ($ok) {
    $len = (Get-Item -LiteralPath $outFile).Length
    Write-Output ("out       : {0}  ({1} bytes)" -f $outFile, $len)
    if (-not $NoStage) {
        New-Item -ItemType Directory -Force -Path (Split-Path $stagedOut -Parent) | Out-Null
        Copy-Item -LiteralPath $outFile -Destination $stagedOut -Force
        Write-Output ("staged    : {0}" -f $stagedOut)
    }
    Write-Output ("log       : {0}" -f $logFile)
    Write-Output "RESULT: OK"
    exit 0
} else {
    Write-Output "--------------- FIRST ERRORS ----------------"
    $all = @()
    $all += $compileErrors
    $all += $linkErrors
    $all | Select-Object -First 25 | ForEach-Object { Write-Output $_ }
    if ($all.Count -gt 25) { Write-Output ("... {0} more (see log)" -f ($all.Count - 25)) }
    Write-Output ("log       : {0}" -f $logFile)
    if ($compileErrors.Count -gt 0) { Write-Output "FAILURE: COMPILE_ERRORS" } else { Write-Output "FAILURE: LINK_ERRORS" }
    Write-Output "RESULT: FAIL"
    exit 1
}
