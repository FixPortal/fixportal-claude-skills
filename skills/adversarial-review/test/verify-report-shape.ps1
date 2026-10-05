$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$validator = Join-Path $root 'validate-report.ps1'
if (-not (Test-Path -LiteralPath $validator)) { throw 'adversarial-review/validate-report.ps1 is missing' }

# --- the two readers must agree -------------------------------------------------------------
# This validator and review-digest's collector both parse the same frontmatter. Whenever they
# have drifted apart, the damage has been silent and in BOTH directions: records validating
# clean here while the collector dropped them (example-app's largest review, hidden for a day,
# plus eight more for months), and records the collector used happily while this file called
# them broken (example-repo' 20260825T122032Z, one of the estate's usable runs,
# rejected for eight months; example-repo's excluded-paths truncated at an interior
# `# comment`, producing violations for exclusions it had never read).
#
# Fixing the three known symptoms does not stop the fourth. This asserts the PROPERTY - that
# both parsers return the same thing for every shape the vault actually contains - so the next
# divergence fails here instead of shipping. If review-digest is not checked out beside this
# skill, SKIP loudly rather than passing: a silent skip is how this check would rot.
$collector = Join-Path $root '..' 'review-digest' 'collect.ps1'
if (-not (Test-Path -LiteralPath $collector)) {
    'SKIP: reader-agreement - review-digest/collect.ps1 not present beside this skill'
} else {
    # Both functions are named Read-Frontmatter; dot-sourcing would collide, so each is
    # extracted into its own scriptblock and invoked in isolation.
    #
    # Their SIGNATURES differ and that is not a defect to paper over silently: the collector's
    # takes a FILE PATH and reads it, this skill's takes the TEXT, because the collector already
    # has the path in hand and this one already has the file contents. Only the parsing
    # semantics are asserted equal. The harness bridges the difference by writing each case to
    # a temp file for the collector - if either signature changes, the extraction below throws
    # rather than quietly comparing nothing.
    function Import-Reader([string] $ScriptPath, [string] $Name) {
        $text = Get-Content -LiteralPath $ScriptPath -Raw
        $m = [regex]::Match($text, "(?ms)^function\s+$Name\s*\(.*?^\}")
        if (-not $m.Success) { throw "could not extract $Name from $ScriptPath" }
        [scriptblock]::Create($m.Value + "`n" + $Name + ' $args[0]')
    }
    $readValidator = Import-Reader $validator 'Read-Frontmatter'
    $readCollector = Import-Reader $collector 'Read-Frontmatter'
    $caseFile = Join-Path ([IO.Path]::GetTempPath()) "reader-agreement-$([guid]::NewGuid().ToString('N')).md"

    # Every shape the vault carries, including the three that caused real damage.
    $cases = @(
        @{ Name = 'trailing comment on a scalar'; Text = "---`ndate: 2026-01-01`ndisposition: reviewed # AR-1 fixed in afd7dd6`n---`n" }
        @{ Name = 'interior comment inside a list'; Text = "---`nexcluded-paths:`n  - docs/**`n  # why the rest are excluded`n  - NOTICE`n  - LICENSE`n---`n" }
        @{ Name = 'inline array'; Text = "---`nreviewers: [a, b, c]`n---`n" }
        @{ Name = 'quoted scalar'; Text = "---`ntarget: `"audit:faa7388`"`n---`n" }
        @{ Name = 'key present only in the body'; Text = "---`ndate: 2026-01-01`n---`n`ntarget: deadbeef..cafe`n" }
        @{ Name = 'empty value then list'; Text = "---`nreviewed-paths:`n  - src/**`nscope-kind: repository`n---`n" }
        @{ Name = 'a later fenced yaml block must not win'; Text = "---`ndate: 2026-01-08`n---`n# r`n```````yaml`ndate: 2020-01-01`n```````n" }
    )
    try {
        foreach ($case in $cases) {
            Set-Content -LiteralPath $caseFile -Value $case.Text -NoNewline -Encoding utf8
            $a = & $readValidator $case.Text
            $b = & $readCollector $caseFile
            $keys = @(@($a.Keys) + @($b.Keys) | Sort-Object -Unique)
            if (-not $keys.Count) { throw "reader-agreement case '$($case.Name)' parsed to NO keys in either reader; the fixture proves nothing" }
            foreach ($k in $keys) {
                $av = (@($a[$k]) -join '|')
                $bv = (@($b[$k]) -join '|')
                if ($av -cne $bv) {
                    throw "reader divergence on '$($case.Name)', key '$k': validator=[$av] collector=[$bv]"
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $caseFile -ErrorAction SilentlyContinue
    }
    "reader agreement OK - $($cases.Count) frontmatter shapes parse identically in both skills"
}

$fixtures = Join-Path $PSScriptRoot 'fixtures' 'report-shape'
$bad = Join-Path $fixtures 'bad-run'
$wrapped = Join-Path $fixtures 'wrapped-run'
$good = Join-Path $fixtures 'clean-run'

# Present in the working tree is not the same as SHIPPED, and every assertion below
# reads these fixtures off disk. An untracked fixture is green here and absent in CI,
# where it surfaces as "cannot find path" in a job that never touched this skill.
# `git ls-files --error-unmatch` is the only thing that tells the two apart.
foreach ($fixture in @(
    (Join-Path $bad 'report.md'),
    (Join-Path $wrapped 'report.md'),
    (Join-Path $good 'report.md'),
    (Join-Path $good 'working' 'transcript.md')
)) {
    if (-not (Test-Path -LiteralPath $fixture)) {
        throw "report-shape fixture is missing: $fixture"
    }
    & git -C $PSScriptRoot ls-files --error-unmatch -- $fixture *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "report-shape fixture exists locally but is NOT COMMITTED, so CI will not have it: $fixture"
    }
}

# A guard is worth exactly what its fixture is worth. Assert the fixtures still CARRY
# the thing under test BEFORE asserting any verdict: three guards shipped green this
# week whose subject had quietly drifted out from under them, and a guard verified
# only by "the suite is green" is indistinguishable from a deleted guard.
$badReport = Get-Content (Join-Path $bad 'report.md') -Raw
if ($badReport -notmatch '\$\(\s*@\{') {
    throw 'bad fixture no longer carries the leaked subexpression; the reject test proves nothing'
}
if ($badReport -notmatch 'AppData[\\/]+Local[\\/]+Temp') {
    throw 'bad fixture no longer carries a scratch path; the reject test proves nothing'
}

# The wrapped fixture is only a test of anything while its defects actually STRADDLE a
# newline; reflow it and it silently degrades into a second copy of bad-run.
$wrappedReport = Get-Content (Join-Path $wrapped 'report.md') -Raw
if ($wrappedReport -notmatch '\$\(\r?\n\s*@\{') {
    throw 'wrapped fixture no longer splits the subexpression across a newline; the whole-file matching test is vacuous'
}
if ($wrappedReport -notmatch 'AppData\\\r?\n\s*Local') {
    throw 'wrapped fixture no longer splits the scratch path across a newline; the whole-file matching test is vacuous'
}

$goodReport = Get-Content (Join-Path $good 'report.md') -Raw
foreach ($legit in '$(TargetFramework)', '$(cat ', '@{ In=') {
    if ($goodReport -notmatch [regex]::Escape($legit)) {
        throw "clean fixture lost its legitimate snippet '$legit'; the false-positive test is vacuous"
    }
}
$transcript = Get-Content (Join-Path $good 'working' 'transcript.md') -Raw
if ($transcript -notmatch '\$\(\s*@\{' -or $transcript -notmatch 'AppData[\\/]+Local[\\/]+Temp') {
    throw 'clean fixture working/ transcript no longer carries both patterns; the working/ exclusion test is vacuous'
}

function Invoke-Validator {
    param([string] $Target)
    $output = & pwsh -NoProfile -File $validator -Path $Target 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output.Trim() }
}

$rejected = Invoke-Validator -Target $bad
if ($rejected.Code -eq 0) {
    throw "validator PASSED the malformed report - it is fail-open`n$($rejected.Output)"
}
foreach ($rule in 'leaked-interpolation', 'dead-scratch-path') {
    if ($rejected.Output -notmatch [regex]::Escape($rule)) {
        throw "validator did not report rule '$rule' on the malformed report`n$($rejected.Output)"
    }
}

$wrappedResult = Invoke-Validator -Target $wrapped
if ($wrappedResult.Code -eq 0) {
    throw "validator PASSED a leak word-wrapped across a newline`n$($wrappedResult.Output)"
}
foreach ($rule in 'leaked-interpolation', 'dead-scratch-path') {
    if ($wrappedResult.Output -notmatch [regex]::Escape($rule)) {
        throw "validator did not report rule '$rule' on the wrapped report`n$($wrappedResult.Output)"
    }
}

$accepted = Invoke-Validator -Target $good
if ($accepted.Code -ne 0) {
    throw "validator rejected a legitimate report (or failed to exclude working/)`n$($accepted.Output)"
}

# --- every Phase-4-scoped finding block carries its Verification line -------------------------
# A Critical/High (or any [contested]) block with no **Verification** line gives a REFUTED or
# INDETERMINATE verdict no home, so the tally keeps counting a finding nobody checked. Run
# folders dated before the rule landed are grandfathered: measured 2026-10-05, 1901 of 1920
# in-scope blocks in the vault predate it, and failing them would block every remediation
# write-back that re-validates a legacy folder. The full vault sweep reported 0 such
# violations after this rule landed.
$verifyRoot = Join-Path ([IO.Path]::GetTempPath()) "adversarial-verification-$([guid]::NewGuid().ToString('N'))"
try {
    function New-VerificationRun([string] $Name, [string] $Date, [string] $Report) {
        $run = Join-Path $verifyRoot $Name
        New-Item -ItemType Directory -Force -Path $run | Out-Null
        if ($Date) { @('---', 'project: fixture', "date: $Date", '---') | Set-Content (Join-Path $run '_index.md') }
        $Report | Set-Content (Join-Path $run 'report.md')
        $run
    }
    $highNoVerification = "# r`n`n### F1 · Null deref`n**High** · [unanimous]`n`n**Where** — ``a.cs:1```n"
    $highVerified = $highNoVerification + "`n**Verification** — VERDICT: CONFIRMED against ``a.cs:1``.`n"
    $contestedMedium = "# r`n`n### F2 · Race`n**Medium** · [contested]`n`n**Where** — ``b.cs:2```n"
    $lowOnly = "# r`n`n### F3 · Typo`n**Low** · [unanimous]`n`n**Where** — ``c.cs:3```n"
    $cases = @(
        @{ Name = 'new-high-unverified';  Date = '2026-10-05'; Report = $highNoVerification; Fail = $true }
        @{ Name = 'new-high-verified';    Date = '2026-10-05'; Report = $highVerified;       Fail = $false }
        @{ Name = 'new-contested-medium'; Date = '2026-10-05'; Report = $contestedMedium;    Fail = $true }
        @{ Name = 'new-low';              Date = '2026-10-05'; Report = $lowOnly;            Fail = $false }
        @{ Name = 'legacy-high';          Date = '2026-01-01'; Report = $highNoVerification; Fail = $false }
        # Index-less folders are legacy shape (SKILL.md 5 mandates _index.md for every new
        # run); 15 such vault files predate the rule and must not start failing.
        @{ Name = 'no-index-high';        Date = '';           Report = $highNoVerification; Fail = $false }
        # A chunk report in a subfolder is governed by its run folder's index.
        @{ Name = 'new-high-unverified/chunk-reports'; Date = ''; Report = $highNoVerification; Fail = $true }
    )
    foreach ($case in $cases) {
        $result = Invoke-Validator -Target (New-VerificationRun $case.Name $case.Date $case.Report)
        $failedForVerification = $result.Code -ne 0 -and $result.Output -match 'missing-verification'
        if ($failedForVerification -ne $case.Fail) {
            throw "Verification rule on '$($case.Name)': expected fail=$($case.Fail), got exit $($result.Code)`n$($result.Output)"
        }
    }
    # The judge brief must ask for the line the validator demands, or a report the brief
    # produces is rejected by the gate that persists it.
    $phase3 = Get-Content (Join-Path $root 'briefs' 'phase3-adjudicate.txt') -Raw
    if ($phase3 -notmatch '\*\*Verification\*\*') {
        throw 'phase3-adjudicate.txt house style has no **Verification** line, so validate-report.ps1 rejects the reports it produces'
    }
}
finally {
    Remove-Item -LiteralPath $verifyRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$coverageRoot = Join-Path ([IO.Path]::GetTempPath()) "adversarial-coverage-$([guid]::NewGuid().ToString('N'))"
try {
    $repo = Join-Path $coverageRoot 'repo'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & git init --quiet $repo
    & git -C $repo config user.email 'fixture@example.test'
    & git -C $repo config user.name 'Coverage Fixture'
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src'), (Join-Path $repo 'tests') | Out-Null
    Set-Content (Join-Path $repo 'README.md') 'base'
    & git -C $repo add README.md
    & git -C $repo commit --quiet -m 'base'
    $baseSha = (& git -C $repo rev-parse HEAD).Trim()
    Set-Content (Join-Path $repo 'src/App.cs') 'reviewed'
    Set-Content (Join-Path $repo 'tests/AppTests.cs') 'excluded'
    & git -C $repo add src/App.cs tests/AppTests.cs
    & git -C $repo commit --quiet -m 'tip'
    $tipSha = (& git -C $repo rev-parse HEAD).Trim()

    function New-CoverageRun([string] $Name, [string[]] $IndexLines) {
        $run = Join-Path $coverageRoot $Name
        New-Item -ItemType Directory -Force -Path $run | Out-Null
        $IndexLines | Set-Content (Join-Path $run '_index.md')
        '# report' | Set-Content (Join-Path $run 'report.md')
        return $run
    }

    $goodCoverage = New-CoverageRun 'good-coverage' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..$tipSha", 'reviewed-paths:', '  - src/**',
        'excluded-paths:', '  - tests/**', 'disposition: remediated', "remediation-tip: $tipSha", '---'
    )
    $symbolicCoverage = New-CoverageRun 'symbolic-coverage' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..HEAD", 'disposition: remediated', "remediation-tip: $tipSha", '---'
    )
    $uncoveredCoverage = New-CoverageRun 'uncovered-coverage' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..$tipSha", 'reviewed-paths:', '  - src/**',
        'disposition: remediated', "remediation-tip: $tipSha", '---'
    )
    $partialPathCoverage = New-CoverageRun 'partial-path-coverage' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: subsystem', "target: $baseSha..$tipSha", 'reviewed-paths:', '  - src/**',
        '  - docs/(future files)', 'disposition: reviewed', '---'
    )
    $partialPathResult = & pwsh -NoProfile -File $validator -Path $partialPathCoverage -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $partialPathResult -notmatch 'reviewed-paths entry matches no tracked files') { throw "validator accepted a partially unmatched reviewed-paths list`n$partialPathResult" }
    Remove-Item -LiteralPath $partialPathCoverage -Recurse -Force
    $futureDate = New-CoverageRun 'future-date' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2099-01-01',
        'scope-kind: repository', "target: $baseSha..$tipSha", 'disposition: reviewed', '---'
    )
    $futureDateResult = & pwsh -NoProfile -File $validator -Path $futureDate -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $futureDateResult -notmatch 'date must not be in the future') { throw "validator accepted a future review date`n$futureDateResult" }
    Remove-Item -LiteralPath $futureDate -Recurse -Force

    # A no-panel skip (SKILL.md §0) must carry its reason, checked both ways: a run
    # declaring no reviewers without a reason, and a reason attached to a run that
    # claims reviewers. Untested, the rule would let a skipped range persist looking
    # byte-identical to a completed review.
    $skipNoReason = New-CoverageRun 'skip-no-reason' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'reviewers: none', 'judge: none',
        'scope-kind: repository', "target: $baseSha..$tipSha", 'reviewed-paths:', '  - src/**',
        'excluded-paths:', '  - tests/**', 'disposition: reviewed', '---'
    )
    $reasonWithPanel = New-CoverageRun 'reason-with-panel' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'reviewers: claude, codex, kimi', 'judge: claude-opus',
        'skip-reason: dependency-only target',
        'scope-kind: repository', "target: $baseSha..$tipSha", 'reviewed-paths:', '  - src/**',
        'excluded-paths:', '  - tests/**', 'disposition: reviewed', '---'
    )
    $skipDeclared = New-CoverageRun 'skip-declared' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'reviewers: none', 'judge: none',
        'skip-reason: dependency-only target, operator chose to skip',
        'scope-kind: repository', "target: $baseSha..$tipSha", 'reviewed-paths:', '  - src/**',
        'excluded-paths:', '  - tests/**', 'disposition: reviewed', '---'
    )

    $skipNoReasonResult = & pwsh -NoProfile -File $validator -Path $skipNoReason -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $skipNoReasonResult -notmatch 'requires a non-empty skip-reason') { throw "validator accepted a no-panel run with no skip-reason`n$skipNoReasonResult" }
    $reasonWithPanelResult = & pwsh -NoProfile -File $validator -Path $reasonWithPanel -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $reasonWithPanelResult -notmatch 'skip-reason is set but') { throw "validator accepted a skip-reason on a run claiming reviewers`n$reasonWithPanelResult" }
    $skipDeclaredResult = & pwsh -NoProfile -File $validator -Path $skipDeclared -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "validator rejected a correctly declared no-panel skip`n$skipDeclaredResult" }

    # `coverage-waiver:` stops review-digest reporting a record as unreadable. Its only failure
    # mode is being used on a record that is perfectly readable, which would hide a real record
    # rather than retire a lost one - so the validator must reject it alongside a resolving
    # target, and must reject a waiver that states no reason, since the reason is all a later
    # reader gets in place of the coverage.
    $waiverWithTarget = New-CoverageRun 'waiver-with-target' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..$tipSha",
        'coverage-waiver: predates the contract and cannot be reconstructed',
        'disposition: reviewed', '---'
    )
    $waiverNoReason = New-CoverageRun 'waiver-no-reason' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', 'target: the qf-ioi-blotter branch',
        'coverage-waiver: legacy', 'disposition: reviewed', '---'
    )
    $waiverGood = New-CoverageRun 'waiver-good' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', 'target: the qf-ioi-blotter branch',
        'coverage-waiver: predates the base..tip contract; no sha in the report resolves here',
        'disposition: reviewed', '---'
    )
    # A well-formed 40..40 target whose tip is a real commit that is NOT on HEAD - a branch the
    # mainline never took. review-digest calls that `tip-not-on-head` and cannot use it, so the
    # waiver is legitimate; a shape-only check here would reject it and leave the record stuck as
    # unreadable forever with no way to retire it.
    $offHeadSha = (& git -C $repo rev-parse HEAD).Trim()
    & git -C $repo checkout -q -b abandoned $baseSha
    'stranded' | Set-Content (Join-Path $repo 'Stranded.cs')
    & git -C $repo add -A; & git -C $repo commit -qm 'work the mainline never took'
    $strandedTip = (& git -C $repo rev-parse HEAD).Trim()
    & git -C $repo checkout -q -
    $waiverOffHead = New-CoverageRun 'waiver-off-head' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..$strandedTip",
        'coverage-waiver: the reviewed tip was rewritten and no commit on the mainline carries its patch-id',
        'disposition: reviewed', '---'
    )
    $waiverOffHeadResult = & pwsh -NoProfile -File $validator -Path $waiverOffHead -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "validator rejected a waiver whose target parses but whose tip is off HEAD, which is exactly what review-digest cannot use`n$waiverOffHeadResult" }
    if ($offHeadSha -eq $strandedTip) { throw 'fixture did not create a stranded commit' }

    $waiverWithTargetResult = & pwsh -NoProfile -File $validator -Path $waiverWithTarget -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $waiverWithTargetResult -notmatch 'target already resolves') { throw "validator accepted a coverage-waiver on a record whose target resolves`n$waiverWithTargetResult" }
    $waiverNoReasonResult = & pwsh -NoProfile -File $validator -Path $waiverNoReason -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $waiverNoReasonResult -notmatch 'must state why') { throw "validator accepted a coverage-waiver with no stated reason`n$waiverNoReasonResult" }
    $waiverGoodResult = & pwsh -NoProfile -File $validator -Path $waiverGood -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "validator rejected a well-formed coverage-waiver on an unreconstructable record`n$waiverGoodResult" }

    # The consumer reads metadata only from a leading `---` block. A record carrying the same
    # keys as prose, or inside a fenced yaml block, is dropped by review-digest as `no-date`
    # while looking complete to a reader - so the validator must reject the shape, not the keys.
    $noFrontmatter = New-CoverageRun 'no-frontmatter' @(
        '# Adversarial review - fixture', '', 'project: fixture', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..$tipSha", 'disposition: remediated'
    )
    $fencedFrontmatter = New-CoverageRun 'fenced-frontmatter' @(
        '# Adversarial review - fixture', '', '```yaml', 'project: fixture', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..$tipSha", 'disposition: remediated', '```'
    )
    # Shape is not completeness: a well-formed block that omits `date` still gets dropped, and
    # a `- **date:**` bullet in the body must not satisfy the check.
    $dateInBody = New-CoverageRun 'date-in-body' @(
        '---', 'project: fixture', 'scope-kind: repository', "target: $baseSha..$tipSha",
        'disposition: remediated', "remediation-tip: $tipSha", '---', '',
        '# fixture', '', '- **date:** 2026-01-01'
    )
    $dateInBodyResult = & pwsh -NoProfile -File $validator -Path $dateInBody -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $dateInBodyResult -notmatch 'no date: inside the frontmatter') {
        throw "validator accepted a run whose date is in the body, not the frontmatter`n$dateInBodyResult"
    }

    foreach ($shape in @($noFrontmatter, $fencedFrontmatter)) {
        $shapeResult = & pwsh -NoProfile -File $validator -Path $shape -RepoPath $repo 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $shapeResult -notmatch 'frontmatter-shape') {
            throw "validator accepted an _index.md with no leading frontmatter block ($shape)`n$shapeResult"
        }
    }

    $goodCoverageResult = & pwsh -NoProfile -File $validator -Path $goodCoverage -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "validator rejected complete machine-readable coverage`n$goodCoverageResult" }
    $excludeOnly = New-CoverageRun 'exclude-only' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..$tipSha", 'excluded-paths:', '  - :!**/Migrations/**',
        'disposition: reviewed', '---'
    )
    $excludeOnlyResult = & pwsh -NoProfile -File $validator -Path $excludeOnly -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $excludeOnlyResult -notmatch 'pathspec exclusions are not allowed') {
        throw "validator accepted an exclusion-only pathspec as repository coverage`n$excludeOnlyResult"
    }
    foreach ($combinedMagic in @(':(top,exclude)Migrations/**', ':(exclude,icase)generated/**')) {
        $combined = New-CoverageRun ('combined-magic-' + [guid]::NewGuid().ToString('N')) @(
            '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
            'scope-kind: repository', "target: $baseSha..$tipSha", 'excluded-paths:', "  - $combinedMagic",
            'disposition: reviewed', '---'
        )
        $combinedResult = & pwsh -NoProfile -File $validator -Path $combined -RepoPath $repo 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $combinedResult -notmatch 'pathspec exclusions are not allowed') {
            throw "validator accepted combined exclusion pathspec '$combinedMagic'`n$combinedResult"
        }
    }
    # `<base>..HEAD` with NO `head:` key stays rejected - review-digest calls that
    # `symbolic-head-without-head-key` and cannot resolve a tip from it.
    $symbolicResult = & pwsh -NoProfile -File $validator -Path $symbolicCoverage -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $symbolicResult -notmatch 'not a shape review-digest can resolve') { throw "validator accepted symbolic HEAD coverage with no head: key`n$symbolicResult" }

    # ...but the SAME target WITH a `head:` sha must be accepted, because the collector resolves
    # it - collect.ps1's header states a `..HEAD` right side is allowed exactly when `head:` is
    # present. Rejecting it was this validator being stricter than its own consumer.
    $symbolicWithHead = New-CoverageRun 'symbolic-with-head' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..HEAD", "head: $tipSha",
        'disposition: remediated', "remediation-tip: $tipSha", '---'
    )
    $symbolicWithHeadResult = & pwsh -NoProfile -File $validator -Path $symbolicWithHead -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "validator rejected <base>..HEAD WITH a head: sha, which review-digest resolves`n$symbolicWithHeadResult" }

    # An `audit:<sha>` target is the empty-tree snapshot review-sweep MANDATES for a
    # never-reviewed repository. example-repo' 20260825T122032Z carries this shape,
    # is one of the estate's usable runs, and was rejected here for eight months.
    $auditTarget = New-CoverageRun 'audit-target' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: `"audit:$tipSha`"",
        'disposition: reviewed', '---'
    )
    $auditTargetResult = & pwsh -NoProfile -File $validator -Path $auditTarget -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "validator rejected an audit:<sha> target, which review-sweep mandates`n$auditTargetResult" }

    # A trailing `# comment` on a scalar. collect.ps1 strips it; this file did not, so the
    # comment became part of the value and failed the disposition check on its own note.
    $commentedScalar = New-CoverageRun 'commented-scalar' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..$tipSha",
        'disposition: reviewed # AR-1 fixed in afd7dd6; the rest carry no disposition', '---'
    )
    $commentedScalarResult = & pwsh -NoProfile -File $validator -Path $commentedScalar -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "validator read a trailing # comment as part of the scalar`n$commentedScalarResult" }

    # An interior `# comment` inside a list must not TERMINATE it. The old reader stopped there
    # and then reported the entries it had never read as uncovered paths.
    $commentedList = New-CoverageRun 'commented-list' @(
        '---', 'project: fixture', 'review-type: adversarial-review', 'date: 2026-01-01',
        'scope-kind: repository', "target: $baseSha..$tipSha",
        'reviewed-paths:', '  - src/**',
        'excluded-paths:',
        '  - tests/**',
        '  # everything below is config the panel did not read',
        '  - Directory.Build.props',
        'disposition: reviewed', '---'
    )
    $commentedListResult = & pwsh -NoProfile -File $validator -Path $commentedList -RepoPath $repo 2>&1 | Out-String
    if ($commentedListResult -match 'Directory\.Build\.props') { throw "an interior # comment truncated the list, so an entry after it was never read`n$commentedListResult" }
    $uncoveredResult = & pwsh -NoProfile -File $validator -Path $uncoveredCoverage -RepoPath $repo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $uncoveredResult -notmatch 'uncovered path') { throw "validator accepted incomplete repository coverage`n$uncoveredResult" }
}
finally {
    Remove-Item -LiteralPath $coverageRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# An unreferenced validator never fires. The persist step is the only place that can
# catch this, because the report is hand-assembled rather than rendered by a script.
$skill = Get-Content (Join-Path $root 'SKILL.md') -Raw
if ($skill -notmatch 'validate-report\.ps1') {
    throw 'SKILL.md never invokes validate-report.ps1, so nothing runs it at persist time'
}

# Opportunistic sweep of what is actually persisted. Host-specific by nature, so it
# skips rather than fails when the vault is unreachable - the fixture contract above
# is the part CI enforces, and it ran.
$vault = $env:OBSIDIAN_VAULT
if (-not $vault) {
    'SKIP: vault sweep - set OBSIDIAN_VAULT to also sweep persisted reports'
} else {
    $reviews = Join-Path $vault 'Claude' 'Adversarial Review'
    if (-not (Test-Path -LiteralPath $reviews)) {
        "SKIP: vault sweep - '$reviews' is not present on this host"
    } else {
        $sweep = Invoke-Validator -Target $reviews
        if ($sweep.Code -ne 0) { throw "persisted reports violate the shape contract`n$($sweep.Output)" }
    }
}

'adversarial-review report shape contract OK'
