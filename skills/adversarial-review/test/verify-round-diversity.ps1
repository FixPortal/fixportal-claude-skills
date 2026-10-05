$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixtures' 'preflight-fixture.ps1')

$source = Join-Path $PSScriptRoot '..' 'run-review.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ar-round-diversity-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'skill'
$repo = Join-Path $root 'repo'
$work = Join-Path $root 'work'

try {
    New-Item -ItemType Directory -Path $fixture, $repo | Out-Null
    # Every WorkDir below sits under $root, and the driver reads pre-flight evidence
    # from WorkDir or its parent -- so one file here covers all of them.
    Write-PreflightFixture -Dir $root -ReviewerId 'A', 'B'
    Copy-Item -LiteralPath $source -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..' 'briefs') -Destination $fixture -Recurse

    @'
param(
    [string] $Instruction,
    [string] $DiffPath,
    [string] $FindingsPath,
    [string] $Model
)

if ($FindingsPath -and $Model -eq 'drops-in-phase-2') {
    Write-Error 'fixture reviewer unavailable in phase 2'
    exit 7
}
if ($FindingsPath) {
    'F1: AGREE - fixture cross-examination'
    exit 0
}
@"
### Fixture finding
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
            [ordered]@{ id = 'A'; label = 'Alpha'; wrapper = 'stub'; model = 'survives'; vendor = 'alpha'; enabled = $true; repoAccess = $false },
            [ordered]@{ id = 'B'; label = 'Beta'; wrapper = 'stub'; model = 'drops-in-phase-2'; vendor = 'beta'; enabled = $true; repoAccess = $false }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'reviewers.json') -Encoding utf8

    & git -C $repo init --quiet
    & git -C $repo config user.email fixture@example.com
    & git -C $repo config user.name Fixture
    'fixture' | Set-Content -LiteralPath (Join-Path $repo 'sample.txt') -Encoding utf8
    & git -C $repo add sample.txt
    & git -C $repo -c commit.gpgsign=false commit --quiet -m fixture

    $output = & pwsh -NoProfile -File (Join-Path $fixture 'run-review.ps1') `
        -RepoPath $repo -Target audit -Pathspec sample.txt -WorkDir $work `
        -ManifestPath (Join-Path $fixture 'reviewers.json') 2>&1 | Out-String
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        throw 'run-review.ps1 must stop when Phase 2 drops below minVendors'
    }
    if ($output -notmatch 'Only 1 vendor\(s\) produced Phase 2 cross-examinations \(min 2\)') {
        throw "expected the Phase 2 diversity failure, got:`n$output"
    }

    $zeroManifest = Get-Content -LiteralPath (Join-Path $fixture 'reviewers.json') -Raw | ConvertFrom-Json
    foreach ($reviewer in $zeroManifest.reviewers) { $reviewer.model = 'drops-in-phase-2' }
    $zeroManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'reviewers.json') -Encoding utf8
    $zeroWork = Join-Path $root 'work-zero'
    $zeroOutput = & pwsh -NoProfile -File (Join-Path $fixture 'run-review.ps1') `
        -RepoPath $repo -Target audit -Pathspec sample.txt -WorkDir $zeroWork `
        -ManifestPath (Join-Path $fixture 'reviewers.json') 2>&1 | Out-String
    $zeroCode = $LASTEXITCODE
    if ($zeroCode -eq 0 -or $zeroOutput -notmatch 'No reviewer produced Phase 2 cross-examinations') {
        throw "expected the zero-vendor Phase 2 failure, got:`n$zeroOutput"
    }

    # One output filename must never stand in for two manifest participants. Duplicate
    # ids map both vendors to p1-A.txt / p2-A.txt, so accepting the manifest lets the
    # last writer's evidence satisfy minVendors twice and duplicates it in the packet.
    $duplicateManifest = Get-Content -LiteralPath (Join-Path $fixture 'reviewers.json') -Raw | ConvertFrom-Json
    $duplicateManifest.reviewers[0].model = 'survives'
    $duplicateManifest.reviewers[1].model = 'survives'
    $duplicateManifest.reviewers[1].id = 'A'
    $duplicateManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'reviewers.json') -Encoding utf8
    $duplicateOutput = & pwsh -NoProfile -File (Join-Path $fixture 'run-review.ps1') `
        -RepoPath $repo -Target audit -Pathspec sample.txt -WorkDir (Join-Path $root 'work-duplicate') `
        -ManifestPath (Join-Path $fixture 'reviewers.json') 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $duplicateOutput -notmatch 'Reviewer ids must be unique') {
        throw "duplicate reviewer ids must fail before one phase file can satisfy two vendors, got:`n$duplicateOutput"
    }

    # A WorkDir is an evidence boundary, not just a scratch path. Reusing it for a
    # different repository/ref/diff must refuse before the old phase artefacts can be
    # mistaken for evidence from the new run.
    $reuseManifest = Get-Content -LiteralPath (Join-Path $fixture 'reviewers.json') -Raw | ConvertFrom-Json
    $reuseManifest.reviewers[1].id = 'B'
    $reuseManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'reviewers.json') -Encoding utf8
    $reuseWork = Join-Path $root 'work-reused'
    & pwsh -NoProfile -File (Join-Path $fixture 'run-review.ps1') `
        -RepoPath $repo -Target audit -Pathspec sample.txt -WorkDir $reuseWork `
        -ManifestPath (Join-Path $fixture 'reviewers.json') *> $null
    if ($LASTEXITCODE -ne 0) { throw "first reused-workdir fixture run exited $LASTEXITCODE" }

    $otherRepo = Join-Path $root 'other-repo'
    New-Item -ItemType Directory -Path $otherRepo | Out-Null
    & git -C $otherRepo init --quiet
    & git -C $otherRepo config user.email fixture@example.com
    & git -C $otherRepo config user.name Fixture
    'different fixture' | Set-Content -LiteralPath (Join-Path $otherRepo 'sample.txt') -Encoding utf8
    & git -C $otherRepo add sample.txt
    & git -C $otherRepo -c commit.gpgsign=false commit --quiet -m fixture
    $reusedOutput = & pwsh -NoProfile -File (Join-Path $fixture 'run-review.ps1') `
        -RepoPath $otherRepo -Target audit -Pathspec sample.txt -WorkDir $reuseWork `
        -ManifestPath (Join-Path $fixture 'reviewers.json') 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $reusedOutput -notmatch 'different run identity') {
        throw "a reused WorkDir must reject evidence from another repo/ref/diff, got:`n$reusedOutput"
    }

    'run-review.ps1 OK — round diversity requires distinct, provenance-bound reviewer outputs'
}
finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
