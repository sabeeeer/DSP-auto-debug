#requires -Version 7.0
# TI_C2000_ITERATE_CHILD=1 is how the iterate loop's own children work underneath its
# marker. It must NOT double as an approval bypass: continuous mode still needs
# -UserApproved, because that flag is what the user's yes turns into.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-childflag-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $fixture 'folder'
$svc = Join-Path $root 'scripts/ti_c2000_service.ps1'

function Invoke-Script([string[]]$a, [hashtable]$envs = @{}) {
    $old = @{}
    foreach ($k in $envs.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
    try {
        $out = @(& pwsh @a 2>&1)
        return [ordered]@{ code = $LASTEXITCODE; text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
    } finally {
        foreach ($k in $old.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
    }
}

New-Item -ItemType Directory -Force -Path $project, (Join-Path $project 'targetConfigs') | Out-Null
[IO.File]::WriteAllText((Join-Path $project '.cproject'), '<project/>', (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $project 'targetConfigs/x.ccxml'), '<configurations/>', (New-Object Text.UTF8Encoding($false)))

try {
    # the child flag alone must not unlock continuous mode
    $r = Invoke-Script @('-NoProfile', '-File', $svc, '-ProjectPath', $project, '-Start', '-RunMode', 'Iterate', '-ConfirmLoad') @{ TI_C2000_ITERATE_CHILD = '1' }
    if ($r.code -ne 4 -or $r.text -notmatch 'ITERATE_NOT_APPROVED') {
        throw "the child flag unlocked iterate without approval (exit $($r.code))`n$($r.text)"
    }
    if (Test-Path (Join-Path $project 'readout/.service/state.json')) { throw 'a refused start left a session behind' }

    # ... but it must still be harmless for a normal SingleStep start attempt
    $r = Invoke-Script @('-NoProfile', '-File', $svc, '-ProjectPath', $project, '-Status') @{ TI_C2000_ITERATE_CHILD = '1' }
    if ($r.text -notmatch 'RESULT') { throw "the child flag broke -Status`n$($r.text)" }

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
