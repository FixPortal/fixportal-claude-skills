#Requires -Version 7
<#
.SYNOPSIS
    A reviewer whose wrapper exits non-zero degrades: it is recorded as unavailable,
    excluded from the pool, and never counted as a participating vendor - while the
    run itself continues so long as vendor diversity still holds.

.DESCRIPTION
    This branch (run-review.ps1, the `$res.Exit -ne 0` arm of Invoke-Round) had no
    test at all. It is the arm that does NOT run Strip-Preamble and does NOT record
    off-contract output, so nothing distinguished "correctly skipped" from "silently
    admitted": a regression that let a failed reviewer's stderr into the pool, or
    that counted it toward minVendors, would have shipped green.

    The distinction the assertions turn on is that an UNAVAILABLE reviewer and an
    OFF-CONTRACT one are handled by different arms and must stay distinguishable -
    the second is forwarded to the judge as unpooled, the first has nothing to
    forward.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixtures' 'preflight-fixture.ps1')

$source = Join-Path $PSScriptRoot '..' 'run-review.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ar-degrade-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'skill'
$repo = Join-Path $root 'repo'
$work = Join-Path $root 'work'

try {
    New-Item -ItemType Directory -Path $fixture, $repo | Out-Null
    Write-PreflightFixture -Dir $root -ReviewerId 'A', 'B', 'C'
    Copy-Item -LiteralPath $source -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..' 'briefs') -Destination $fixture -Recurse

    @'
param(
    [string] $Instruction,
    [string] $DiffPath,
    [string] $FindingsPath,
    [string] $Model
)

if ($Model -eq 'always-fails') {
    # Written to stdout as well as stderr on purpose: the degrade arm captures the
    # merged stream into the OutFile, and the assertion that this text never reaches
    # the pool is only meaningful if there is text to leak.
    'FABRICATED FINDING TEXT THAT MUST NEVER BE POOLED'
    Write-Error 'fixture reviewer is unavailable'
    exit 7
}
if ($FindingsPath) {
    'F1: AGREE - fixture cross-examination'
    exit 0
}
@"
### Fixture finding from $Model
- **Severity:** Low
- **Location:** sample.txt:1
- **Trigger:** fixture
- **Issue:** fixture
- **Impact:** fixture
- **Suggested fix:** fixture
"@
'@ | Set-Content -LiteralPath (Join-Path $fixture 'stub-review.ps1') -Encoding utf8

    [ordered]@{
        minVendors = 2
        wrappers = [ordered]@{ stub = 'stub-review.ps1' }
        reviewers = @(
            [ordered]@{ id = 'A'; label = 'Alpha'; wrapper = 'stub'; model = 'survives-a'; vendor = 'alpha'; enabled = $true; repoAccess = $false },
            [ordered]@{ id = 'B'; label = 'Beta'; wrapper = 'stub'; model = 'survives-b'; vendor = 'beta'; enabled = $true; repoAccess = $false },
            [ordered]@{ id = 'C'; label = 'Gamma'; wrapper = 'stub'; model = 'always-fails'; vendor = 'gamma'; enabled = $true; repoAccess = $false }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'reviewers.json') -Encoding utf8

    # Every fixture git call is checked. Unchecked, a failed `init`/`add`/`commit` let the
    # script continue and the driver then died on something unrelated - an empty diff, a
    # missing HEAD - so a broken fixture repository read as a degrade-branch defect.
    function Invoke-FixtureGit {
        & git @args
        if ($LASTEXITCODE -ne 0) { throw "fixture git setup failed (exit $LASTEXITCODE): git $($args -join ' ')" }
    }
    Invoke-FixtureGit -C $repo init --quiet
    Invoke-FixtureGit -C $repo config user.email fixture@example.com
    Invoke-FixtureGit -C $repo config user.name Fixture
    'fixture' | Set-Content -LiteralPath (Join-Path $repo 'sample.txt') -Encoding utf8
    Invoke-FixtureGit -C $repo add sample.txt
    Invoke-FixtureGit -C $repo -c commit.gpgsign=false commit --quiet -m fixture

    $output = & pwsh -NoProfile -File (Join-Path $fixture 'run-review.ps1') `
        -RepoPath $repo -Target audit -Pathspec sample.txt -WorkDir $work `
        -ManifestPath (Join-Path $fixture 'reviewers.json') 2>&1 | Out-String
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        throw "a single failed reviewer must degrade, not abort, while 2 vendors remain (exit $code):`n$output"
    }
    if ($output -notmatch 'FAILED \(exit 7\)') {
        throw "the failure was not reported against the reviewer that produced it:`n$output"
    }

    # The unavailable marker is what the packet and any later reader key on. Without
    # it an empty file is indistinguishable from a reviewer that legitimately said
    # nothing.
    $failedOut = Join-Path $work 'p1-C.txt'
    if (-not (Test-Path -LiteralPath $failedOut)) { throw "no phase-1 artefact was written for the failed reviewer: $failedOut" }
    $failedText = Get-Content -LiteralPath $failedOut -Raw
    if ($failedText -notmatch [regex]::Escape('[reviewer unavailable: exit 7]')) {
        throw "the failed reviewer's artefact carries no unavailable marker:`n$failedText"
    }
    # It must NOT be relabelled off-contract: that arm forwards text to the judge as a
    # substantive-but-unformatted reply, which is a different claim entirely.
    if ($failedText -match 'reviewer off-contract') {
        throw 'an unavailable reviewer was recorded as off-contract; the two arms have collapsed'
    }

    $pooled = Get-Content -LiteralPath (Join-Path $work 'pooled-findings.txt') -Raw
    if ($pooled -match 'FABRICATED FINDING TEXT') {
        throw "the failed reviewer's output reached the pool:`n$pooled"
    }
    $map = Get-Content -LiteralPath (Join-Path $work 'pooled-map.json') -Raw | ConvertFrom-Json
    $attributed = @($map.findings.PSObject.Properties | Where-Object { $_.Value.reviewer -ceq 'C' })
    if ($attributed.Count -gt 0) {
        throw "$($attributed.Count) pooled finding(s) are attributed to the reviewer that never reported"
    }
    # Two surviving reviewers, one finding each: proves the pool is not empty for an
    # unrelated reason, which would satisfy both assertions above vacuously.
    if (@($map.findings.PSObject.Properties).Count -ne 2) {
        throw "expected the two surviving reviewers' findings in the pool, got $(@($map.findings.PSObject.Properties).Count)"
    }

    $status = Get-Content -LiteralPath (Join-Path $work 'status.json') -Raw | ConvertFrom-Json
    if ($status.state -ne 'complete') { throw "run did not complete: state=$($status.state)" }

    'run-review.ps1 OK - a failed reviewer degrades: marked unavailable, unpooled, uncounted'
}
finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
