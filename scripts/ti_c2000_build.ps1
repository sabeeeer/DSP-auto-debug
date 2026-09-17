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
#     ... -CcsRoot F:\ccs                 force a CCS installation
#     ... -CompilerRoot <ti-cgt-c2000_x.y.z.LTS>
#     ... -LinkCmd "extra1.cmd,extra2.cmd"  add linker command files
#     ... -Clean | -Quiet | -NoStage
#   Exit code: 0 = compile AND link OK, 1 = failed, 2 = environment problem
# =====================================================================
param(
    [string]$ProjectPath  = "",
    [string]$CcsRoot      = "",
    [string]$CompilerRoot = "",
    [string]$LinkCmd      = "",
    [string]$OutputDir    = "",
    [switch]$Clean,
    [switch]$Quiet,
    [switch]$NoStage
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
function Get-OptionNode([string]$idPart) {
    $n = $cproj.SelectSingleNode("//cconfiguration[contains(@id,'Debug')]//option[contains(@id,'$idPart')]")
    if (-not $n) { $n = $cproj.SelectSingleNode("//option[contains(@id,'$idPart')]") }
    if (-not $n) { $n = $cproj.SelectSingleNode("//option[contains(@superClass,'$idPart')]") }
    return $n
}
function Get-OptionValue([string]$idPart, [string]$default = "") {
    $n = Get-OptionNode $idPart
    if ($n -and $n.value) { return [string]$n.value }
    return $default
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
    $c = @(Get-ChildItem 'C:\ti', 'F:\ccs' -Recurse -Directory -Filter 'ti-cgt-c2000_*' -ErrorAction SilentlyContinue |
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
        Info "NOTE    : include path missing on disk, skipped -> $q"
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
Info ("COMPILER: {0}" -f $cgRoot)
Info ("OPTIONS : -v{0}{1}{2} {3} | {4} | runtime {5}" -f $siliconVer,
      $(if ($largeMem) { ' -ml' } else { '' }), $(if ($unified) { ' -mt' } else { '' }), $floatFlag, $outFormat, $rts)

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
# device peripheral header cmd (DSP2833x_Headers_nonBIOS.cmd / F2837xD_Headers_nonBIOS_cpu1.cmd / ...)
$cmdFiles += @($allCmd | Where-Object { $_.Name -match 'Headers' -and ($cmdFiles -notcontains $_.FullName) } |
               ForEach-Object { $_.FullName })
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
$unusedCmd = @($allCmd | Where-Object { $cmdFiles -notcontains $_.FullName })
if ($unusedCmd.Count -gt 0) {
    Info ("NOTE    : .cmd files NOT linked (use -LinkCmd to add): " + (($unusedCmd | ForEach-Object { $_.Name }) -join ', '))
}
if ($cmdFiles.Count -eq 0) { Info "WARNING : no linker command file used - the link will probably fail" }

# ---- libraries referenced by the project ----
$libs = @(Get-ChildItem -Path $ProjectPath -Recurse -Filter '*.lib' -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -notmatch '\\Debug\\' } | ForEach-Object { $_.FullName })

# ---------- 4. sources ----------
$srcRoots = @()
foreach ($sub in @('APP', 'User', 'DSP2833x_Libraries')) {
    $p = Join-Path $ProjectPath $sub
    if (Test-Path $p) { $srcRoots += $p }
}
if ($srcRoots.Count -eq 0) { $srcRoots = @($ProjectPath) }
$cfiles = @(Get-ChildItem -Path $srcRoots -Recurse -File -Include '*.c', '*.asm' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\Debug\\' -and $_.FullName -notmatch '\\auto_build\\' } |
            ForEach-Object { $_.FullName })
if ($cfiles.Count -eq 0) { Fail "no C/ASM sources found under: $($srcRoots -join ', ')" 2 'NO_SOURCES' }
Info "SOURCES : $($cfiles.Count) file(s)"

# ---------- 5. output dir ----------
if (-not $OutputDir) { $OutputDir = Join-Path $ProjectPath 'Debug\auto_build' }
$objDir = Join-Path $OutputDir 'obj'
if ($Clean -and (Test-Path -LiteralPath $OutputDir)) { Remove-Item -LiteralPath $OutputDir -Recurse -Force }
# always start from an empty object dir: stale .obj of deleted sources must never be linked in
if (Test-Path -LiteralPath $objDir) { Remove-Item -LiteralPath $objDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $objDir | Out-Null
$logFile = Join-Path $OutputDir 'build.log'
$log = New-Object System.Collections.Generic.List[string]

# ---------- 6. compile ----------
$cflags = @("-v$siliconVer", '-g', '--display_error_number', '--diag_warning=225', '--diag_wrap=off', '-c')
if ($largeMem) { $cflags += '-ml' }
if ($unified)  { $cflags += '-mt' }
$cflags += $floatFlag
$incArgs = @()
foreach ($i in $includes) { $incArgs += "--include_path=$i" }

$compileErrors = @()
$warningCount = 0
$idx = 0
foreach ($f in $cfiles) {
    $idx++
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
}

# ---------- 7. link ----------
$linkErrors = @()
$outFile = Join-Path $OutputDir "$projName.out"
$stagedOut = Join-Path $ProjectPath "Debug\$projName.out"
if ($compileErrors.Count -eq 0) {
    $objs = @(Get-ChildItem -Path $objDir -Filter '*.obj' | ForEach-Object { $_.FullName })
    $lflags = @("-v$siliconVer", '-g', '--display_error_number', '--diag_warning=225', '--diag_wrap=off', '-z',
               "-m$OutputDir\$projName.map", "--stack_size=$stackSz", '--warn_sections',
               "-i$cgRoot\lib", "-i$cgRoot\include", '--reread_libs', $romModel)
    $lnkArgs = @()
    foreach ($o in $objs) { $lnkArgs += $o }
    foreach ($c in $cmdFiles) { $lnkArgs += $c }
    foreach ($l in $libs) { $lnkArgs += $l }
    $lnkArgs += (Join-Path $cgRoot "lib\$rts")
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
