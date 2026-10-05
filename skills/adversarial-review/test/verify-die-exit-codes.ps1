#Requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixtures' 'preflight-fixture.ps1')
$skillDir = Split-Path -Parent $PSScriptRoot
$spine = Join-Path $skillDir 'run-review.ps1'
# A PINNED manifest, not the live reviewers.json. Nothing here is about which model
# holds a seat, but the live manifest resolves every seat through resolve.py against
# the live registry - so a drifted tier, a retired id, or no python on PATH exited 2
# at seat resolution and this test reported "must exit 5, got 2", which reads as a
# driver regression. Literal `model` pins bypass the registry by documented contract.
$manifest = Join-Path $PSScriptRoot 'fixtures' 'pinned-reviewers.json'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("ar-die-codes-" + [Guid]::NewGuid().ToString('N'))
$workDir = Join-Path ([IO.Path]::GetTempPath()) ("ar-existing-run-" + [Guid]::NewGuid().ToString('N'))
$workDir2 = Join-Path ([IO.Path]::GetTempPath()) ("ar-no-origin-" + [Guid]::NewGuid().ToString('N'))
$workDir3 = Join-Path ([IO.Path]::GetTempPath()) ("ar-no-merge-base-" + [Guid]::NewGuid().ToString('N'))

New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
try {
    & git -C $sandbox init --quiet 2>$null
    Set-Content -LiteralPath (Join-Path $sandbox 'a.txt') -Value 'one' -Encoding utf8
    & git -C $sandbox add -A 2>$null
    & git -C $sandbox -c user.email=t@t -c user.name=t commit -m 'one' --quiet 2>$null
    Set-Content -LiteralPath (Join-Path $sandbox 'a.txt') -Value 'two' -Encoding utf8
    & git -C $sandbox add -A 2>$null
    & git -C $sandbox -c user.email=t@t -c user.name=t commit -m 'two' --quiet 2>$null

    $missing = Join-Path $sandbox 'missing.md'
    $output = & pwsh -NoProfile -File $spine -RepoPath $sandbox -ManifestPath $manifest -ContextPath $missing 2>&1 | Out-String
    if ($LASTEXITCODE -ne 2) {
        throw "a missing context file must exit 2, got $LASTEXITCODE`n$output"
    }
    # Exit 2 is also what a bad manifest, an unresolvable seat and a non-repo path all
    # produce, so the code alone does not say WHICH gate fired. Pin it to this one.
    if ($output -notmatch 'Context file not found') {
        throw "exit 2 came from something other than the context-file guard`n$output"
    }

    New-Item -ItemType Directory -Path $workDir | Out-Null
    # The pre-flight gate runs before the run-identity check, so without evidence this
    # would exit 2 and never reach the exit-5 path under test.
    Write-PreflightFixture -Dir $workDir -ManifestPath $manifest
    '{"runIdentity":"different-run"}' | Set-Content -LiteralPath (Join-Path $workDir 'status.json') -Encoding utf8
    $output = & pwsh -NoProfile -File $spine -Target 'HEAD~1..HEAD' -RepoPath $sandbox -ManifestPath $manifest -WorkDir $workDir 2>&1 | Out-String
    if ($LASTEXITCODE -ne 5) {
        throw "mismatched run evidence must exit 5, got $LASTEXITCODE`n$output"
    }

    # A failed native lookup yields $null, and .Trim() on it threw "cannot call a method
    # on a null-valued expression" before the Die that names the cause could run. Both
    # also exit 1, so the message is the assertion. The sandbox has no origin remote.
    New-Item -ItemType Directory -Path $workDir2 | Out-Null
    Write-PreflightFixture -Dir $workDir2 -ManifestPath $manifest
    $output = & pwsh -NoProfile -File $spine -Target '123' -RepoPath $sandbox -ManifestPath $manifest -WorkDir $workDir2 2>&1 | Out-String
    if ($output -notmatch 'Cannot resolve origin for PR #123') {
        throw "a PR target with no origin remote must Die naming the origin, got exit $LASTEXITCODE`n$output"
    }
    # An orphan branch shares no history with the default branch, so merge-base fails.
    & git -C $sandbox checkout --orphan lone --quiet 2>$null
    & git -C $sandbox -c user.email=t@t -c user.name=t commit -m 'lone' --quiet 2>$null
    New-Item -ItemType Directory -Path $workDir3 | Out-Null
    Write-PreflightFixture -Dir $workDir3 -ManifestPath $manifest
    $output = & pwsh -NoProfile -File $spine -RepoPath $sandbox -ManifestPath $manifest -WorkDir $workDir3 2>&1 | Out-String
    if ($output -notmatch 'Could not find merge-base of') {
        throw "a branch with no merge-base must Die naming the merge-base, got exit $LASTEXITCODE`n$output"
    }

    'run-review.ps1 OK — fatal exit codes 2 and 5 stay distinct from 1'
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $workDir2 -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $workDir3 -Recurse -Force -ErrorAction SilentlyContinue
}
