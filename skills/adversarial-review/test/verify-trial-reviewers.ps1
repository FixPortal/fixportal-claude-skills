$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixtures/preflight-fixture.ps1')
$source = Join-Path $PSScriptRoot '../run-review.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ar-trial-' + [guid]::NewGuid().ToString('N'))
try {
    $fixture = New-Item -ItemType Directory -Path (Join-Path $root 'skill')
    $repo = New-Item -ItemType Directory -Path (Join-Path $root 'repo')
    Copy-Item -LiteralPath $source -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../briefs') -Destination $fixture -Recurse
    Write-PreflightFixture -Dir $root -ReviewerId A,B,Z
    @'
param($Instruction, $DiffPath, $FindingsPath, $Model)
if ($Model -eq 'fail-p1' -or ($Model -eq 'fail-p2' -and $FindingsPath)) { exit 7 }
if ($FindingsPath) { 'F1: AGREE - evidence verified'; return }
"### Finding from $Model"
'- **Severity:** Low'
'- **Location:** sample.txt:1'
'- **Trigger:** fixture'
'- **Issue:** fixture'
'- **Impact:** fixture'
'- **Suggested fix:** fixture'
'@ | Set-Content (Join-Path $fixture 'stub.ps1')
    git -C $repo init --quiet
    if ($LASTEXITCODE) { throw 'fixture init failed' }
    'fixture' | Set-Content (Join-Path $repo 'sample.txt')
    git -C $repo add sample.txt
    if ($LASTEXITCODE) { throw 'fixture add failed' }
    git -C $repo -c user.name=Fixture -c user.email=fixture@example.com -c commit.gpgsign=false commit --quiet -m fixture
    if ($LASTEXITCODE) { throw 'fixture commit failed' }
    $manifest = @{
        minVendors = 2; wrappers = @{ stub = 'stub.ps1' }
        reviewers = @(
            @{ id='A'; label='A'; wrapper='stub'; model='a'; vendor='alpha'; enabled=$true },
            @{ id='B'; label='B'; wrapper='stub'; model='b'; vendor='beta'; enabled=$true },
            @{ id='Z'; label='Trial'; wrapper='stub'; model='z'; vendor='zai'; enabled=$true; supplemental=$true; expiresAt='2099-11-01T00:00:00Z' }
        )
    }
    function Run-Case([string]$Name, [string]$ExpectedFailure) {
        $manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $fixture 'reviewers.json')
        $work = Join-Path $root $Name
        $output = & pwsh -NoProfile -File (Join-Path $fixture 'run-review.ps1') -RepoPath $repo -Target audit -Pathspec sample.txt -WorkDir $work 2>&1 | Out-String
        $code = $LASTEXITCODE
        if ($ExpectedFailure) {
            if ($code -eq 0 -or $output -notmatch $ExpectedFailure) { throw "$Name failed: $output" }
        } else {
            if ($code) { throw "$Name failed: $output" }
            return Get-Content (Join-Path $work 'status.json') -Raw | ConvertFrom-Json
        }
    }
    $manifest.reviewers[1].model = 'fail-p1'
    Run-Case 'quorum-p1' 'Only 1 vendor\(s\) produced Phase 1'
    $manifest.reviewers[1].model = 'fail-p2'
    Run-Case 'quorum-p2' 'Only 1 vendor\(s\) produced Phase 2'
    $manifest.reviewers[1].model = 'b'
    $manifest.minVendors = 3
    Run-Case 'quorum-config' 'Vendor-diversity invariant unmet'
    $manifest.minVendors = 2
    $status = Run-Case 'participates'
    if ($status.vendorsP1 -ne 3 -or $status.quorumVendorsP1 -ne 2 -or $status.quorumVendorsP2 -ne 2) { throw 'Actual participation and qualified quorum must be recorded separately' }
    if ($status.phase2Reviewers.id -notcontains 'Z') { throw 'Trial must cross-examine' }
    $map = Get-Content (Join-Path $root 'participates/pooled-map.json') -Raw | ConvertFrom-Json
    if (@($map.findings.PSObject.Properties.Value | Where-Object reviewer -eq 'Z').Count -ne 1) { throw 'Trial findings must be pooled' }
    $packet = Get-Content (Join-Path $root 'participates/judge-packet.md') -Raw
    if ($packet -notmatch 'Supplemental reviewers: Z' -or $packet -notmatch 'Finding from z') { throw 'Judge must receive trial evidence and its status' }
    Write-PreflightFixture -Dir $root -ReviewerId A,B
    $status = Run-Case 'missing-trial-preflight'
    if ($status.phase1Reviewers.id -contains 'Z' -or $status.skippedSupplementalReviewers -notcontains 'Z' -or $status.supplementalReviewers.Count) { throw 'Unverified supplemental seat must be skipped and disclosed' }
    $preflightPath = Join-Path $root 'preflight.json'
    $preflight = Get-Content $preflightPath -Raw | ConvertFrom-Json
    $preflight.checked += @{reviewer='Z';result='PREFLIGHT_FAILED'}
    $preflight | ConvertTo-Json -Depth 5 | Set-Content $preflightPath
    $status = Run-Case 'failed-trial-preflight'
    if ($status.phase2Reviewers.id -contains 'Z' -or $status.skippedSupplementalReviewers -notcontains 'Z' -or $status.quorumVendorsP2 -ne 2) { throw 'Failed supplemental preflight must not block the qualified panel' }
    $packet = Get-Content (Join-Path $root 'failed-trial-preflight/judge-packet.md') -Raw
    if ($packet -notmatch 'Supplemental reviewers skipped.*Z') { throw 'Judge must see skipped supplemental coverage' }
    Write-PreflightFixture -Dir $root -ReviewerId A,Z
    Run-Case 'missing-regular-preflight' 'no PREFLIGHT_SUCCESS entry.*B'
    Write-PreflightFixture -Dir $root -ReviewerId A,B,Z
    $manifest.reviewers[2].expiresAt = '2000-01-01T00:00:00Z'
    $manifest.reviewers[2].wrapper = 'absent'
    $status = Run-Case 'expired'
    if ($status.phase1Reviewers.id -contains 'Z' -or $status.expiredReviewers -notcontains 'Z') { throw 'Expired trial must be skipped before wrapper resolution' }
    $manifest.reviewers[2].expiresAt = 'not-a-date'
    Run-Case 'bad-expiry' 'Invalid expiresAt'
    # Deterministic exact-boundary test against the same function the driver uses.
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ReviewerExpired' }, $true)
    Invoke-Expression $function.Extent.Text
    if (-not (Test-ReviewerExpired '2026-11-01T00:00:00Z' ([datetimeoffset]'2026-11-01T00:00:00Z'))) { throw 'Trial must expire exactly at cutoff' }
    if (Test-ReviewerExpired '2026-11-01T00:00:00Z' ([datetimeoffset]'2026-10-31T23:59:59Z')) { throw 'Trial expired early' }
    'Trial reviewer contracts passed: expiry, pooling, cross-examination and all three quorum gates.'
} finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
