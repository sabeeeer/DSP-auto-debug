#requires -Version 7.0
# Chaos on the on-disk state the interlocks read. Every entry point decides "is a session
# alive / is a continuous run going / is the target busy" from files, so those files get
# corrupted in real life: a crash leaves a lock, a killed process leaves a marker, a power
# loss truncates JSON. The rule in every case is the same:
#   * a lock or marker owned by a DEAD process must never block anyone (no permanent jam)
#   * a lock owned by a LIVE process must block (one writer at a time)
#   * unreadable state is "no session", never "assume it is fine"
# Tested against the library functions directly: fast, and no CCS needed.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/ti_c2000_readmode.ps1')

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-chaos-' + [guid]::NewGuid().ToString('N'))
$bad = New-Object System.Collections.Generic.List[string]
$cases = 0
$deadPid = 999999

function Write-Text([string]$path, [string]$text) {
    $d = Split-Path -Parent $path
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function New-Proj([string]$name) {
    $p = Join-Path $fixture $name
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'readout\.service'), (Join-Path $p 'readout\iterate') | Out-Null
    Write-Text (Join-Path $p '.cproject') '<project/>'
    return $p
}
function Check([string]$label, [bool]$ok, [string]$detail) {
    $script:cases++
    if (-not $ok) { $bad.Add(('{0}: {1}' -f $label, $detail)) }
}

try {
    # ---------- 1. target lock ------------------------------------------------
    $p = New-Proj 'lock-dead'
    Write-Text (Join-Path $p 'readout\.service\target.lock') ("{0}|ReadOnly|2026-11-14 10:00:00" -f $deadPid)
    $lk = Enter-TargetLock -ProjectPath $p -Mode 'ReadOnly'
    Check 'lock: dead holder must be taken over' $lk.ok ("Enter-TargetLock returned ok=$($lk.ok)")
    if ($lk.ok) { Exit-TargetLock -ProjectPath $p }
    Check 'lock: released after take-over' (-not (Test-Path (Join-Path $p 'readout\.service\target.lock'))) 'lock file still there'

    $p = New-Proj 'lock-garbage'
    Write-Text (Join-Path $p 'readout\.service\target.lock') 'not-a-pid|who|knows'
    $lk = Enter-TargetLock -ProjectPath $p -Mode 'ReadOnly'
    Check 'lock: unparsable holder must be taken over' $lk.ok ("Enter-TargetLock returned ok=$($lk.ok)")
    if ($lk.ok) { Exit-TargetLock -ProjectPath $p }

    $p = New-Proj 'lock-live'
    Write-Text (Join-Path $p 'readout\.service\target.lock') ("{0}|Start|2026-11-14 10:00:00" -f $PID)
    $lk = Enter-TargetLock -ProjectPath $p -Mode 'ReadOnly'
    Check 'lock: live holder must block' (-not $lk.ok) ("Enter-TargetLock returned ok=$($lk.ok) while pid $PID holds it")
    # and it must not have deleted the other process's lock
    Check 'lock: live holder lock preserved' (Test-Path (Join-Path $p 'readout\.service\target.lock')) 'the live lock was deleted'

    # ---------- 2. iterate marker --------------------------------------------
    $p = New-Proj 'marker-dead'
    Write-Text (Join-Path $p 'readout\iterate\active.json') ('{"mode":"Iterate","pid":' + $deadPid + ',"round":2,"maxLoads":5}')
    $mi = Get-RunModeInfo -ProjectPath $p
    Check 'marker: dead owner must not count as active' (-not $mi.active) ('mode=' + $mi.mode + ' active=' + $mi.active + ' src=' + $mi.source)

    $p = New-Proj 'marker-garbage'
    Write-Text (Join-Path $p 'readout\iterate\active.json') '{ broken json '
    $mi = Get-RunModeInfo -ProjectPath $p
    Check 'marker: unreadable marker must not count as active' (-not $mi.active) ('mode=' + $mi.mode + ' active=' + $mi.active)

    $p = New-Proj 'marker-live'
    Write-Text (Join-Path $p 'readout\iterate\active.json') ('{"mode":"Iterate","pid":' + $PID + ',"round":2,"maxLoads":5}')
    $mi = Get-RunModeInfo -ProjectPath $p
    Check 'marker: live owner must count as active' $mi.active ('mode=' + $mi.mode + ' active=' + $mi.active)
    Check 'marker: live owner reports Iterate' ($mi.mode -eq 'Iterate') ('mode=' + $mi.mode)

    # ---------- 3. session liveness ------------------------------------------
    $p = New-Proj 'session-nothing'
    $s = Get-LiveSessionInfo -ProjectPath $p
    Check 'session: no files -> not alive' (-not $s.alive) 'reported alive with no state'

    $p = New-Proj 'session-garbage'
    Write-Text (Join-Path $p 'readout\.service\state.json') '{ half a json'
    Write-Text (Join-Path $p 'readout\.service\ready.txt') 'ready'
    $s = Get-LiveSessionInfo -ProjectPath $p
    Check 'session: unreadable state -> not alive' (-not $s.alive) ('reported alive: ' + $s.reason)
    Check 'session: unreadable state is named' ($s.reason -match 'unreadable|gone|missing|no session|stopped') ('reason=' + $s.reason)

    $p = New-Proj 'session-dead-pid'
    Write-Text (Join-Path $p 'readout\.service\state.json') ('{"pid":' + $deadPid + ',"started":"2026-11-14 10:00:00","outSha256":"x","runMode":"SingleStep"}')
    Write-Text (Join-Path $p 'readout\.service\ready.txt') 'ready'
    $s = Get-LiveSessionInfo -ProjectPath $p
    Check 'session: gone pid -> not alive' (-not $s.alive) ('reported alive with pid ' + $deadPid)

    $p = New-Proj 'session-stopped'
    Write-Text (Join-Path $p 'readout\.service\state.json') ('{"pid":' + $PID + ',"started":"2026-11-14 10:00:00","outSha256":"x","runMode":"SingleStep"}')
    Write-Text (Join-Path $p 'readout\.service\ready.txt') 'ready'
    Write-Text (Join-Path $p 'readout\.service\stopped.txt') 'stopped'
    $s = Get-LiveSessionInfo -ProjectPath $p
    Check 'session: stopped marker wins' (-not $s.alive) 'a stopped session was reported alive'

    $p = New-Proj 'session-no-ready'
    Write-Text (Join-Path $p 'readout\.service\state.json') ('{"pid":' + $PID + ',"started":"2026-11-14 10:00:00","outSha256":"x","runMode":"SingleStep"}')
    $s = Get-LiveSessionInfo -ProjectPath $p
    Check 'session: missing ready.txt -> not alive' (-not $s.alive) 'alive without ready.txt'

    $p = New-Proj 'session-ok'
    Write-Text (Join-Path $p 'readout\.service\state.json') ('{"pid":' + $PID + ',"started":"2026-11-14 10:00:00","outSha256":"x","runMode":"SingleStep"}')
    Write-Text (Join-Path $p 'readout\.service\ready.txt') 'ready'
    $s = Get-LiveSessionInfo -ProjectPath $p
    Check 'session: complete files -> alive' $s.alive ('not alive: ' + $s.reason)

    # a live session claiming runMode Iterate must be treated as a continuous run
    $mi = Get-RunModeInfo -ProjectPath $p
    Check 'session: SingleStep session is not a continuous run' (-not $mi.active) ('mode=' + $mi.mode)
    Write-Text (Join-Path $p 'readout\.service\state.json') ('{"pid":' + $PID + ',"started":"2026-11-14 10:00:00","outSha256":"x","runMode":"Iterate","loadIndex":3}')
    $mi = Get-RunModeInfo -ProjectPath $p
    # a FINISHED loop leaves runMode=Iterate in the session it leaves behind. That must
    # not count as "a continuous run is in progress", or every later read is refused with
    # READONLY_IN_ITERATE until someone stops the session (measured 2026-11-14).
    Check 'session: leftover Iterate session must not block reads' (-not $mi.active) ('mode=' + $mi.mode + ' active=' + $mi.active + ' src=' + $mi.source)
    Check 'session: leftover Iterate session still reports its mode' ($mi.mode -eq 'Iterate') ('mode=' + $mi.mode)
    # only the marker means "running right now"
    Write-Text (Join-Path $p 'readout\iterate\active.json') ('{"mode":"Iterate","pid":' + $PID + ',"round":2,"maxLoads":5}')
    $mi = Get-RunModeInfo -ProjectPath $p
    Check 'session: live marker does block reads' $mi.active ('mode=' + $mi.mode + ' active=' + $mi.active)
    Remove-Item (Join-Path $p 'readout\iterate\active.json') -Force

    # ---------- 4. load counter survives corruption -------------------------
    $p = New-Proj 'count-garbage'
    Write-Text (Join-Path $p 'readout\load-count.json') '{"count": "many"}'
    $c1 = $null
    try { $c1 = Get-LoadCount -ProjectPath $p } catch { $bad.Add('count: unreadable counter threw ' + $_.Exception.Message) }
    $script:cases++
    if ($null -eq $c1) { $bad.Add('count: unreadable counter returned nothing') }
    elseif ([int]$c1.count -ne 0) { $bad.Add('count: unreadable counter returned count=' + $c1.count) }

    # ---------- 5. report ---------------------------------------------------
    if ($bad.Count -gt 0) {
        'FAILURE: STATE_CHAOS'
        foreach ($b in $bad) { 'VIOLATION: ' + $b }
        'REASON: {0} of {1} state cases misbehaved' -f $bad.Count, $cases
        'RESULT: FAIL'
        exit 1
    }
    'CHECK   : {0} corrupted-state cases behaved as the interlocks require' -f $cases
    'RESULT: OK'
    exit 0
} catch {
    'FAILURE: TEST_FAILED'
    'REASON: ' + $_.Exception.Message
    'RESULT: FAIL'
    exit 1
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
