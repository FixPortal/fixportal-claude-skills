$ErrorActionPreference = 'Stop'

# What the judge RECEIVES decides what the run can conclude. Three separate ways a
# run has silently narrowed that input, all measured on 2026-08-16 during the
# example-repo spa/src pass:
#
#   1. run-review.ps1 discarded reviewer output that failed the round's start-pattern
#      check. That check must decide PARTICIPATION (an off-contract reply is not a
#      vendor vote) and nothing else. Three substantive anthropic reviews were dropped
#      on formatting alone -- prose lead-in, and verdicts written `**F1** ... AGREE`
#      rather than line-initial `F1:` -- leaving that chunk's cross-examination with
#      no anthropic vote at all.
#   2. claude-review.ps1 asked for `--output-format text`, which returns only the FINAL
#      assistant message. A Stop hook forcing a correction turn therefore replaced a
#      16 KB adjudication with a 1.8 KB fragment, twice, silently.
#   3. Nothing told a repo-blind reviewer to cite source lines rather than diff
#      offsets, and nothing warned the judge that it might be looking at one. An
#      adjudication dismissed two genuine dissents as "fabricated line numbers".
#
# Each assertion below fails against the code as it stood before those fixes.

. (Join-Path $PSScriptRoot 'fixtures' 'preflight-fixture.ps1')
$skillRoot = Join-Path $PSScriptRoot '..'
$source = Join-Path $skillRoot 'run-review.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ar-judge-input-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'skill'
$repo = Join-Path $root 'repo'
$work = Join-Path $root 'work'

try {
    New-Item -ItemType Directory -Path $fixture, $repo | Out-Null
    Copy-Item -LiteralPath $source -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $skillRoot 'briefs') -Destination $fixture -Recurse
    # $work sits under $root, and the driver reads pre-flight evidence from WorkDir
    # or its parent.
    Write-PreflightFixture -Dir $root -ReviewerId 'A', 'B', 'C'

    # Reviewer C answers with prose only -- no '### ', no line-initial 'F<n>:' -- but
    # says something a judge would want. That is the shape that was being thrown away.
    @'
param(
    [string] $Instruction,
    [string] $DiffPath,
    [string] $FindingsPath,
    [string] $Model
)

if ($Model -eq 'off-contract') {
    'Prose lead-in, no contract heading anywhere in this reply.'
    ''
    '**F1** (fixture finding): AGREE -- UNPOOLED_CANARY_TEXT establishes the mechanism.'
    exit 0
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
            [ordered]@{ id = 'A'; label = 'Alpha'; wrapper = 'stub'; model = 'on-contract';  vendor = 'alpha'; enabled = $true; repoAccess = $false },
            [ordered]@{ id = 'B'; label = 'Beta';  wrapper = 'stub'; model = 'on-contract';  vendor = 'beta';  enabled = $true; repoAccess = $false },
            [ordered]@{ id = 'C'; label = 'Gamma'; wrapper = 'stub'; model = 'off-contract'; vendor = 'gamma'; enabled = $true; repoAccess = $false }
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
    if ($LASTEXITCODE -ne 0) { throw "fixture run exited $LASTEXITCODE`n$output" }

    $packet = Get-Content -LiteralPath (Join-Path $work 'judge-packet.md') -Raw
    if ($packet -notmatch 'Unpooled — off-contract reviewer output') {
        throw 'judge packet must carry an explicitly labelled unpooled section for off-contract output'
    }
    if ($packet -notmatch 'UNPOOLED_CANARY_TEXT') {
        throw 'off-contract reviewer text must reach the judge, not be discarded on a format check'
    }

    # ...and must count as a vendor response without buying a pooled finding.
    $status = Get-Content -LiteralPath (Join-Path $work 'status.json') -Raw | ConvertFrom-Json
    if (@($status.phase1Reviewers | Where-Object { $_.id -eq 'C' }).Count -ne 1) {
        throw 'a non-empty on-topic prose reply must count as a participating Phase 1 reviewer'
    }
    if ($status.vendorsP1 -ne 3) {
        throw "a participating prose reply must count toward the vendor count (got $($status.vendorsP1), expected 3)"
    }
    if (@($status.offContract | Where-Object { $_.id -eq 'C' }).Count -eq 0) {
        throw 'status.json must record which participating replies were unpooled, so the format loss is never silent'
    }
    $pooled = Get-Content -LiteralPath (Join-Path $work 'pooled-findings.txt') -Raw
    if ($pooled -match 'UNPOOLED_CANARY_TEXT') {
        throw 'off-contract text must stay OUT of the anonymised pooled set — it carries no F-id'
    }

    # 2. The Claude wrapper must capture every assistant turn, not only the last.
    $claudeWrapper = Get-Content -LiteralPath (Join-Path $skillRoot 'claude-review.ps1') -Raw
    if ($claudeWrapper -match "'--output-format',\s*'text'") {
        throw "claude-review.ps1 must not use --output-format text: it returns only the final assistant message, so a hook-forced correction turn silently replaces the whole review"
    }
    if ($claudeWrapper -notmatch "'--output-format',\s*'stream-json'") {
        throw 'claude-review.ps1 must request stream-json so every assistant turn is recoverable'
    }
    if ($claudeWrapper -notmatch "type\s*-ne\s*'assistant'" -and $claudeWrapper -notmatch "type\s*-eq\s*'assistant'") {
        throw 'claude-review.ps1 must select assistant events from the stream and concatenate their text blocks'
    }

    # 3. Citation coordinate system: instructed to reviewers, and flagged to the judge.
    $p1 = Get-Content -LiteralPath (Join-Path $skillRoot 'briefs' 'phase1-review.txt') -Raw
    if ($p1 -notmatch '(?s)SOURCE-FILE lines.*@@') {
        throw 'phase1-review.txt must tell reviewers to cite source-file lines and how to derive them from @@ hunk headers'
    }
    $p3 = Get-Content -LiteralPath (Join-Path $skillRoot 'briefs' 'phase3-adjudicate.txt') -Raw
    if ($p3 -notmatch '(?s)offsets into the diff.*fabricated') {
        throw 'phase3-adjudicate.txt must warn the judge that a repo-blind citation may be a diff offset, before it calls one fabricated'
    }

    'judge input integrity OK — off-contract output forwarded but never counted, every assistant turn captured, citation coordinates pinned'
}
finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
