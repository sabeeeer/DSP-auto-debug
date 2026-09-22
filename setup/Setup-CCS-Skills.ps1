# =====================================================================
# Setup-CCS-Skills.ps1  --  bootstrap the CodeBuddy skills on a new PC
#
#   What it does (idempotent, never deletes anything without a backup):
#     1. installs this repo as  <SkillsRoot>\ti-c2000-ccs-auto
#        (existing install is renamed to *.bak-<timestamp>, not deleted)
#     2. optionally installs the git-snapshot skill next to it
#     3. merges the git-management hooks into ~/.codebuddy/settings.json
#        (only adds what is missing, keeps the rest of the file untouched)
#     4. optional: set global git identity (-GitName / -GitEmail)
#     5. optional: set/clear the proxy env vars (-Proxy / -ClearProxy)
#     6. optional: run the DSP build self-check against a project (-ProjectPath)
#     7. prints the manual checklist that CANNOT be automated (CCS install,
#        token/login, XDS driver, project include paths, hardware)
#
#   Usage (new machine, right after cloning):
#     powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Setup-CCS-Skills.ps1 -DryRun
#     powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Setup-CCS-Skills.ps1 `
#         -GitSource ..\git-management -GitName "your-login" -GitEmail "you@example.com" `
#         -Proxy http://127.0.0.1:12450
#
#   Installing for another agent (the SKILL.md payload is agent agnostic, see docs/portability.md):
#     ... -Target claude      -> ~/.claude/skills/ti-c2000-ccs-auto   (hooks skipped)
#     ... -Target codex       -> ~/.codex/skills/ti-c2000-ccs-auto    (hooks skipped)
#     ... -Target custom -SkillsRoot D:\some\agent\skills
#     ... -NoHooks            -> never touch ~/.codebuddy/settings.json
#   Exit code: 0 ok | 1 failure | 2 argument/environment problem
# =====================================================================
param(
    [string]$Target      = 'codebuddy',           # codebuddy | claude | codex | custom
    [string]$SkillsRoot  = (Join-Path $HOME '.codebuddy\skills'),
    [string]$GitSource   = "",                    # folder of the git-snapshot skill repo (optional)
    [string]$GitName     = "",                    # global git user.name  (optional)
    [string]$GitEmail    = "",                    # global git user.email (optional)
    [string]$Proxy       = "",                    # e.g. http://127.0.0.1:12450 (optional)
    [switch]$ClearProxy,                          # remove proxy env vars instead
    [string]$ProjectPath = "",                    # CCS project for the build self-check (optional)
    [switch]$NoHooks,                             # do not touch ~/.codebuddy/settings.json
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path $PSScriptRoot -Parent

# ---- which agent are we installing for?  (the SKILL.md payload itself is agent agnostic) ----
# -SkillsRoot wins when given explicitly; otherwise it follows -Target.
if (-not $PSBoundParameters.ContainsKey('SkillsRoot')) {
    switch ($Target.ToLower()) {
        'codebuddy' { $SkillsRoot = Join-Path $HOME '.codebuddy\skills' }
        'claude'    { $SkillsRoot = Join-Path $HOME '.claude\skills' }
        'codex'     { $SkillsRoot = Join-Path $HOME '.codex\skills' }
        'custom'    { Write-Output "   [FAILED] -Target custom requires -SkillsRoot <dir>"; exit 2 }
        default     { Write-Output ("   [FAILED] unknown -Target '" + $Target + "' (use codebuddy | claude | codex | custom)"); exit 2 }
    }
}
$doHooks = (-not $NoHooks) -and ($Target.ToLower() -eq 'codebuddy')
function Step($m) { Write-Output ("== " + $m) }
function Note($m) { Write-Output ("   " + $m) }
function Apply-Step($m, [scriptblock]$action) {
    if ($DryRun) { Write-Output ("   [dry-run] " + $m) ; return }
    try { & $action; Write-Output ("   [ok] " + $m) } catch { Write-Output ("   [FAILED] " + $m + " -> " + $_.Exception.Message) }
}

Step "planned actions"
Note ("repo           : " + $repoRoot)
Note ("skills root    : " + $SkillsRoot)
Note ("git skill src  : " + $(if ($GitSource) { $GitSource } else { '<none>' }))
Note ("git identity   : " + $(if ($GitName -and $GitEmail) { "$GitName <$GitEmail>" } elseif ($GitName -or $GitEmail) { '<incomplete, skipped>' } else { '<unchanged>' }))
Note ("proxy          : " + $(if ($ClearProxy) { '<clear>' } elseif ($Proxy) { $Proxy } else { '<unchanged>' }))
Note ("project check  : " + $(if ($ProjectPath) { $ProjectPath } else { '<none>' }))
if ($DryRun) { Write-Output "   (dry run: nothing will be changed)" }

# ---------- 1. install this skill ----------
Step "install skill: ti-c2000-ccs-auto"
# NOTE: this variable is $installPath, NOT $target - PowerShell variable names are
# case-insensitive, so calling it $target would silently overwrite the -Target parameter.
$installPath = Join-Path $SkillsRoot 'ti-c2000-ccs-auto'
if (-not (Test-Path $SkillsRoot)) {
    Apply-Step ("create " + $SkillsRoot) { New-Item -ItemType Directory -Force -Path $SkillsRoot | Out-Null }
}
if (Test-Path $installPath) {
    $bak = "$installPath.bak-" + (Get-Date -Format 'yyyyMMdd_HHmmss')
    Apply-Step ("existing install -> " + (Split-Path $bak -Leaf)) { Move-Item -LiteralPath $installPath -Destination $bak -Force }
}
if ((Get-Item -LiteralPath $repoRoot).FullName -ne (Get-Item -LiteralPath $installPath -ErrorAction SilentlyContinue).FullName) {
    Apply-Step ("copy repo to " + $installPath) { Copy-Item -LiteralPath $repoRoot -Destination $installPath -Recurse -Force }
} else {
    Note "already installed in place (repo == skill folder)"
}

# ---------- 2. install the git snapshot skill ----------
if ($GitSource) {
    Step "install skill: git-management"
    $gsrc = (Resolve-Path -LiteralPath $GitSource -ErrorAction SilentlyContinue)
    if (-not $gsrc) {
        Write-Output ("   [FAILED] git skill source not found: " + $GitSource)
    } else {
        $gtarget = Join-Path $SkillsRoot 'git-management'
        if (Test-Path $gtarget) { Apply-Step ("existing git skill -> backup") { Move-Item -LiteralPath $gtarget -Destination ($gtarget + ".bak-" + (Get-Date -Format 'yyyyMMdd_HHmmss')) -Force } }
        Apply-Step ("copy git skill to " + $gtarget) { Copy-Item -LiteralPath $gsrc.Path -Destination $gtarget -Recurse -Force }
    }
}

# ---------- 3. merge hooks into settings.json (CodeBuddy only) ----------
# The git-management hooks use CodeBuddy's hook schema AND its tool names
# (write_to_file / replace_in_file), and they live in ~/.codebuddy/settings.json which no other
# agent reads - so this step only runs for -Target codebuddy (and not with -NoHooks).
Step "hooks (CodeBuddy only)"
if (-not $doHooks) {
    Note ("skipped: target = " + $Target + $(if ($NoHooks) { ", -NoHooks" } else { "" }))
}
$settingsPath = Join-Path $HOME '.codebuddy\settings.json'
$gitScript    = Join-Path $SkillsRoot 'git-management\scripts'
$hookDefs = @(
    @{ name = 'SessionStart'; json = @{ matcher = 'startup'; hooks = @(@{ type = 'command'; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$gitScript\sessionstart.ps1`""; timeout = 30 }) } },
    @{ name = 'PostToolUse';  json = @{ matcher = 'Write|Edit|write_to_file|replace_in_file'; hooks = @(@{ type = 'command'; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$gitScript\autosnapshot.ps1`""; timeout = 30 }) } },
    @{ name = 'SessionEnd';   json = @{ matcher = '*'; hooks = @(@{ type = 'command'; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$gitScript\autosnapshot.ps1`" -Stop"; timeout = 20 }) } }
)
if (-not $doHooks) {
    # nothing to do (see above)
} elseif ($DryRun) {
    foreach ($h in $hookDefs) { Note ("would ensure hook: " + $h.name) }
} else {
    $cfg = $null
    if (Test-Path $settingsPath) {
        try { $cfg = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Output ("   [FAILED] settings.json is not valid JSON: " + $_.Exception.Message); $cfg = $null }
    }
    if (-not $cfg) { $cfg = New-Object psobject }
    if (-not $cfg.PSObject.Properties['hooks']) { $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object psobject) -Force }
    foreach ($h in $hookDefs) {
        $existing = $cfg.hooks.PSObject.Properties[$h.name]
        if ($existing) {
            $txt = ($existing.Value | ConvertTo-Json -Depth 6 -Compress)
            if ($txt -match 'git-management') { Note ("hook already present: " + $h.name); continue }
            Write-Output ("   [WARN] hooks." + $h.name + " exists but does not reference git-management - please merge manually:")
            Note (($h.json | ConvertTo-Json -Depth 6 -Compress))
            continue
        }
        $cfg.hooks | Add-Member -NotePropertyName $h.name -NotePropertyValue $h.json -Force
        Note ("added hook: " + $h.name)
    }
    $json = $cfg | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $settingsPath -Value $json -Encoding UTF8
    Write-Output ("   [ok] wrote " + $settingsPath + "  (plugins/other settings kept)")
}

# ---------- 4. git identity ----------
if ($GitName -and $GitEmail) {
    Step "git identity"
    Apply-Step ("user.name  = " + $GitName)  { git config --global user.name  $GitName }
    Apply-Step ("user.email = " + $GitEmail) { git config --global user.email $GitEmail }
} elseif ($GitName -or $GitEmail) {
    Step "git identity"
    Write-Output "   [skip] need BOTH -GitName and -GitEmail"
}

# ---------- 5. proxy ----------
if ($ClearProxy -or $Proxy) {
    Step "proxy environment (user scope)"
    $names = @('HTTPS_PROXY', 'HTTP_PROXY', 'https_proxy', 'http_proxy')
    $val = $(if ($ClearProxy) { $null } else { $Proxy })
    foreach ($n in $names) {
        Apply-Step ("$n = " + $(if ($val) { $val } else { '<cleared>' })) { [Environment]::SetEnvironmentVariable($n, $val, 'User') }
    }
    Note "takes effect in NEW terminals; many CLIs (git/gh/pip/npm) follow these"
}

# ---------- 6. DSP toolchain / build self-check ----------
Step "DSP toolchain detection + optional build self-check"
if ($ProjectPath) {
    $buildScript = Join-Path $repoRoot 'scripts\ti_c2000_build.ps1'
    if (-not (Test-Path $buildScript)) {
        Write-Output "   [FAILED] build script missing: $buildScript"
    } else {
        Apply-Step ("build self-check on " + $ProjectPath) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $buildScript -ProjectPath $ProjectPath -Quiet |
                ForEach-Object { Write-Output ("      " + $_) }
        }
    }
} else {
    Note "no -ProjectPath given; run this later to verify toolchain + project:"
    Note ("powershell -NoProfile -ExecutionPolicy Bypass -File `"$repoRoot\scripts\ti_c2000_build.ps1`" -ProjectPath <CCS project>")
}

# ---------- 7. manual checklist ----------
Write-Output ""
Write-Output "================ MANUAL STEPS (cannot be automated) ================"
@(
    "1. Install Code Composer Studio 12.x (or 6.x) + the C2000 compiler, and the emulator driver (XDS100/110/...).",
    "2. GitHub access on this PC: run 'gh auth login' (or set GH_TOKEN) and create a token with scopes repo,read:org.",
    "   Behind a corporate/local proxy, configure it first: -Proxy http://<host>:<port>  (or git config http.proxy ...).",
    "3. Set the git identity if not done here:  git config --global user.name/user.email",
    "4. Copy the CCS project itself (e.g. your DSP2833x project) - it is NOT in this repo.",
    "   IMPORTANT: .cproject stores ABSOLUTE include paths to the TI headers (DSP2833x_*/F28xx_*).",
    "   Fix those paths in CCS (Project > Properties > Build > C2000 Compiler > Include Options) or Edit .cproject.",
    "5. Verify: scripts\ti_c2000_build.ps1 -ProjectPath <project>      (compile+link, no hardware needed)",
    "   then:  scripts\ti_c2000_debug.ps1   -ProjectPath <project> -Build -Run [-ReadVars ...]",
    "6. Hardware side: probe plugged in, board powered, targetConfigs\*.ccxml present in the project.",
    ("7. Restart the " + $Target + " session so the new skill is picked up" + $(if ($doHooks) { " (+ hooks)" } else { "" }) + ".")
) | ForEach-Object { Write-Output $_ }
Write-Output "===================================================================="
Write-Output "RESULT: OK"
exit 0
