#requires -Version 7.0
# The four proofs ReadOnly has to make before it reports a number:
#   probe online | session alive | sha256(out) == state | entry symbol below 0x080000
# Two rules that must never regress:
#   1. "cannot prove RAM" is a REFUSAL, not a pass (stale Flash data must not look fresh)
#   2. an unplugged probe is NO_PROBE (exit 3), not a timeout halfway through a read
# Nothing here touches a board: the probe gate is exercised with a stub child.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-proofs-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $fixture 'skill/scripts'
$project = Join-Path $fixture 'folder'
$empty = Join-Path $fixture 'no-session'

function Invoke-Script([string[]]$a) {
    $out = @(& pwsh @a 2>&1)
    return [ordered]@{ code = $LASTEXITCODE; text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
}
function Expect([string]$label, $r, [int]$code, [string]$pattern) {
    if ($r.code -ne $code) { throw "$label : exit $($r.code), expected $code`n$($r.text)" }
    if ($pattern -and $r.text -notmatch $pattern) { throw "$label : output has no '$pattern'`n$($r.text)" }
}

New-Item -ItemType Directory -Force -Path $scripts, $project, $empty, (Join-Path $project 'targetConfigs'), (Join-Path $project 'Debug') | Out-Null
[IO.File]::WriteAllText((Join-Path $project '.cproject'), '<project/>', (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $project 'targetConfigs/x.ccxml'), '<configurations/>', (New-Object Text.UTF8Encoding($false)))

try {
    foreach ($n in @('ti_c2000_run_read.ps1', 'ti_c2000_read_dma.ps1', 'ti_c2000_readmode.ps1', 'ti_c2000_loadcount.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "scripts/$n") -Destination $scripts
    }
    '# stub: every case below stops before probe/DSS work' | Set-Content (Join-Path $scripts 'ti_c2000_debug.ps1') -Encoding UTF8

    # --- 1. the two weakening switches belong to ReadOnly only -------------------
    $r = Invoke-Script @('-NoProfile', '-File', (Join-Path $scripts 'ti_c2000_run_read.ps1'),
        '-ProjectPath', $project, '-Variables', 'gMsTick', '-Mode', 'LoadRead', '-ConfirmLoad', '-AllowUnverified')
    Expect 'LoadRead+AllowUnverified' $r 2 'FAILURE: MUTUALLY_EXCLUSIVE'

    $r = Invoke-Script @('-NoProfile', '-File', (Join-Path $scripts 'ti_c2000_read_dma.ps1'),
        '-ProjectPath', $project, '-ArrayName', 'gBuf', '-FrozenBufferReady', '-Mode', 'LoadRead', '-ConfirmLoad', '-NoProbeCheck')
    Expect 'LoadRead+NoProbeCheck' $r 2 'FAILURE: MUTUALLY_EXCLUSIVE'

    # --- 2. ReadOnly accepts them (and then fails for the honest reason) --------
    $r = Invoke-Script @('-NoProfile', '-File', (Join-Path $scripts 'ti_c2000_run_read.ps1'),
        '-ProjectPath', $project, '-Variables', 'gMsTick', '-Mode', 'ReadOnly', '-AllowUnverified', '-NoProbeCheck')
    Expect 'ReadOnly+AllowUnverified' $r 4 'FAILURE: NO_SESSION'

    # --- 3. RAM proof is fail-closed -------------------------------------------
    $lib = Join-Path $scripts 'ti_c2000_readmode.ps1'
    $ramOut = @(& pwsh -NoProfile -Command @"
. '$lib'
`$r = Test-RamImageEvidence -ProjectPath '$empty'
'ok=' + `$r.ok + ' verified=' + `$r.verified + ' text=' + `$r.text
`$r2 = Test-RamImageEvidence -ProjectPath '$empty' -AllowUnverified
'allow ok=' + `$r2.ok + ' verified=' + `$r2.verified
"@ 2>&1) | ForEach-Object { [string]$_ }
    $ramText = ($ramOut -join "`n")
    if ($ramText -notmatch 'ok=False verified=False') { throw "RAM unverified must refuse`n$ramText" }
    if ($ramText -notmatch 'allow ok=True') { throw "-AllowUnverified must pass`n$ramText" }
    if ($ramText -notmatch 'UNVERIFIED') { throw "the refusal must name the reason`n$ramText" }

    # --- 4. probe gate: a probe-less target is NO_PROBE / exit 3 ---------------
    $fake = Join-Path $fixture 'no_probe.ps1'
    [IO.File]::WriteAllText($fake, "Write-Output 'FAILURE: NO_PROBE'`nWrite-Output 'RESULT: FAIL'`nWrite-Output 'REASON: stub says no probe'`nexit 3`n", (New-Object Text.UTF8Encoding($false)))
    $gate = Join-Path $fixture 'probe_gate.ps1'
    [IO.File]::WriteAllText($gate, ". '$lib'`nAssert-ProbeOnline -ProjectPath '$project' -DebugScript '$fake'`n'PROBE gate passed (WRONG)'`n", (New-Object Text.UTF8Encoding($false)))
    $g = Invoke-Script @('-NoProfile', '-File', $gate)
    Expect 'probe gate' $g 3 'FAILURE: NO_PROBE'
    if ($g.text -match 'FAILURE: NO_PROBE[\s\S]*FAILURE: NO_PROBE') { throw "the gate must report NO_PROBE exactly once`n$($g.text)" }
    if ($g.text -match 'WRONG') { throw "the gate continued past a missing probe`n$($g.text)" }

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
