$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$text = @(
    Get-Content (Join-Path $root 'SKILL.md') -Raw
    Get-ChildItem (Join-Path $root 'references') -Filter '*.md' | ForEach-Object { Get-Content $_.FullName -Raw }
) -join "`n"

# .gitignore was removed from the review-policy `high` list on 2026-08-02 and replaced
# by a CI guard. scaffold-ci/assets/review-policy.example.json says verbatim:
# "Do NOT re-add .gitignore here without first checking whether that CI guard is
# present in the repo." Scaffolding it HIGH reintroduces a superseded rule and bills a
# metered CodeRabbit review for every trivial ignore edit.
if ($text -match '`\.claude/review-policy\.json`\s*\r?\n?\s*itself, `\.coderabbit\.yaml`, and `\.gitignore`') {
    throw "SKILL.md still mandates .gitignore in the review control plane's HIGH list"
}

# The guard workflow that replaced it must be scaffolded as its own control surface.
foreach ($needle in 'review-policy-guard.yml',
                    'git check-ignore --no-index',
                    'review-tier.yml') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md missing the review-policy guard: $needle"
    }
}

# The guard and the policy example must SHIP with the skill, at the cross-CLI canonical
# path. They previously lived only under ~/.claude/resources/, which no non-Claude runtime
# can resolve - so a Codex/Kimi/Antigravity caller following this skill got an ad-hoc
# policy or none, and a repo with no policy tiers every PR NORMAL: the exact failure the
# section exists to prevent. ci-workflow.md already states the rule ("not any single
# runtime's skills root"); this holds the assets to it.
$assets = Join-Path $root 'assets'
foreach ($asset in 'review-policy-guard.yml', 'review-policy.example.json', 'review-tier.yml', 'assert_gate_coverage.py', 'assert_workflow_hygiene.py') {
    if (-not (Test-Path -LiteralPath (Join-Path $assets $asset) -PathType Leaf)) {
        throw "scaffold-ci must ship $asset under assets/, not reference a runtime-specific path"
    }
}
# This mirror nests the skill under skills/, so the repository root is two levels up.
$repoCodeRabbit = Get-Content (Join-Path $root '..' '..' '.coderabbit.yaml') -Raw
if (-not $repoCodeRabbit.Contains('labels: ["review-high", "review-high-manual"]')) {
    throw 'the repository CodeRabbit config must enable both the tier label and manual HIGH override'
}
if ($text -match [regex]::Escape('~/.claude/resources/')) {
    throw 'scaffold-ci cites a Claude-only asset path; use ~/.agents/skills/scaffold-ci/assets/'
}

# The guard must be COPIED, not paraphrased. An inlined snippet drifted from the asset and
# silently lost four of its checks; these are the ones that were missing.
$guard = Get-Content (Join-Path $assets 'review-policy-guard.yml') -Raw
$tierWorkflow = Get-Content (Join-Path $assets 'review-tier.yml') -Raw
if ($tierWorkflow -notmatch '\.previous_filename') {
    throw 'review-tier.yml must include previous_filename so renames retain HIGH coverage'
}
# That a leading **/ also matches repository-root files is asserted by EXECUTING the match
# block below ('**/secrets.json' vs 'secrets.json', and the doubled '**/**/' cases), not by
# grepping for one spelling of the suffix strip.
# That renames keep HIGH, and that the completeness count is of FILES rather than of names,
# is asserted by executing the enumeration and match blocks below, not by grepping for a
# particular jq spelling.
foreach ($needle in 'cancel-in-progress: false', 'trap tier_high_on_failure ERR', 'tier_high_on_failure', 'review-high-manual', 'Could not enumerate the complete changed-file list') {
    if ($tierWorkflow -notmatch [regex]::Escape($needle)) {
        throw "review-tier.yml is missing fail-high control: $needle"
    }
}

# The completeness check, EXECUTED rather than grepped: the shipped enumeration block runs
# under bash with `gh` stubbed to return a chosen changed_files and file count. The files
# endpoint stops at 3000, and whether changed_files is capped there too is unverified, so
# an enumeration that reaches 3000 must tier HIGH even when the two counts agree.
$bash = Get-Command bash -ErrorAction SilentlyContinue
$block = [regex]::Match($tierWorkflow, '(?ms)^(?<i>[ ]+)if ! expected=\$\(gh api.*?^\k<i>fi\r?$')
if (-not $block.Success) { throw 'review-tier.yml: could not locate the changed-file enumeration block' }
if (-not $bash) {
    Write-Host 'SKIP: no bash on this host; review-tier enumeration block not executed'
}
else {
    $indent = $block.Groups['i'].Value.Length
    $body = ($block.Value -split '\r?\n' | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { $_.TrimStart() } }) -join "`n"
    foreach ($case in @(
        @{ Expected = 0;    Retrieved = 0;    High = 'false'; Why = 'a PR with no changed files (follow-up batch, item 2)' },
        @{ Expected = 2;    Retrieved = 2;    High = 'false'; Why = 'a small, complete list' },
        @{ Expected = 5;    Retrieved = 4;    High = 'true';  Why = 'a short enumeration' },
        @{ Expected = 3000; Retrieved = 3000; High = 'true';  Why = 'an enumeration at the 3000-file ceiling with matching counts' },
        @{ Expected = 3500; Retrieved = 3000; High = 'true';  Why = 'an enumeration capped below changed_files' }
    )) {
        $script = @"
set -euo pipefail
GITHUB_REPOSITORY=o/r PR_NUMBER=1 high=false
gh() { case "`$*" in *'/files'*) seq 1 $($case.Retrieved) | sed 's/^/f/' ;; *) echo $($case.Expected) ;; esac; }
$body
echo "HIGH=`$high"
"@
        $out = ($script -replace "`r", '') | & $bash.Source -s 2>&1 | Out-String
        if ($out -notmatch "HIGH=$($case.High)\b") {
            throw "review-tier.yml tiered $($case.Why) wrong (expected high=$($case.High)):`n$out"
        }
    }
    # A RENAME is one file with two names: the count must not double (which would force every
    # rename HIGH), while the match list must carry the vacated path (so moving a HIGH file
    # out of its tier still tiers HIGH). Enumeration and match run together here.
    if (-not $match) { $match = [regex]::Match($tierWorkflow, '(?ms)^(?<i>[ ]+)if ! \$high; then.*?^\k<i>fi\r?$') }
    $rIndent = $match.Groups['i'].Value.Length
    $rMatch = ($match.Value -split '\r?\n' | ForEach-Object { if ($_.Length -ge $rIndent) { $_.Substring($rIndent) } else { $_.TrimStart() } }) -join "`n"
    foreach ($case in @(
        @{ Records = 'moved/policy.json\t.claude/review-policy.json'; High = 'true';  Why = 'a rename out of a HIGH path' },
        @{ Records = 'src/b.cs\tsrc/a.cs';                             High = 'false'; Why = 'a rename between NORMAL paths, counted once' }
    )) {
        $script = @"
set -euo pipefail
GITHUB_REPOSITORY=o/r PR_NUMBER=1 high=false
patterns='.claude/review-policy.json'
gh() { case "`$*" in *'/files'*) printf '$($case.Records)\n' ;; *) echo 1 ;; esac; }
$body
$rMatch
echo "HIGH=`$high"
"@
        $out = ($script -replace "`r", '') | & $bash.Source -s 2>&1 | Out-String
        if ($out -notmatch "HIGH=$($case.High)\b") {
            throw "review-tier.yml tiered $($case.Why) wrong (expected high=$($case.High)):`n$out"
        }
    }

    # The changed-file list is enumerated ONCE: a second paginated call doubled the API
    # cost and let the count and the list disagree mid-run (follow-up batch, item 1).
    $filesCalls = [regex]::Matches($block.Value, 'pulls/\$PR_NUMBER/files').Count
    if ($filesCalls -ne 1) {
        throw "review-tier.yml must enumerate the changed files once; found $filesCalls /files call(s)"
    }

    # The pattern match, EXECUTED: a mid-pattern `**/` must match zero directories as well
    # as many (follow-up batch, item 5), without narrowing what the bash `case` glob matched before.
    $match = [regex]::Match($tierWorkflow, '(?ms)^(?<i>[ ]+)if ! \$high; then.*?^\k<i>fi\r?$')
    if (-not $match.Success) { throw 'review-tier.yml: could not locate the pattern-match block' }
    $mIndent = $match.Groups['i'].Value.Length
    $mBody = ($match.Value -split '\r?\n' | ForEach-Object { if ($_.Length -ge $mIndent) { $_.Substring($mIndent) } else { $_.TrimStart() } }) -join "`n"
    foreach ($case in @(
        @{ Pattern = 'deploy/**/certs/**'; File = 'deploy/certs/a.pem';         High = 'true';  Why = 'mid-pattern ** at zero depth' },
        @{ Pattern = 'deploy/**/certs/**'; File = 'deploy/prod/eu/certs/a.pem'; High = 'true';  Why = 'mid-pattern ** at depth' },
        @{ Pattern = '**/secrets.json';    File = 'secrets.json';               High = 'true';  Why = 'leading ** at the root' },
        @{ Pattern = 'infra/*';            File = 'infra/a/b.bicep';            High = 'true';  Why = 'a single * still crossing /, as bash case always did' },
        @{ Pattern = 'deploy/**/certs/**'; File = 'deploy/foocerts/a.pem';      High = 'false'; Why = 'a sibling directory whose name merely ends in certs' },
        @{ Pattern = 'a/**/b/**/c';        File = 'a/b/x/c';                    High = 'true';  Why = 'two embedded ** segments, one at zero depth' },
        @{ Pattern = '**/scripts/**/*.py'; File = 'scripts/foo.py';             High = 'true';  Why = 'leading AND mid ** both at zero depth' },
        @{ Pattern = '**/scripts/**/*.py'; File = 'a/scripts/foo.py';           High = 'true';  Why = 'leading ** at depth, mid ** at zero depth' },
        @{ Pattern = '**/scripts/**/*.py'; File = 'xscripts/foo.py';            High = 'false'; Why = 'a sibling of the combined pattern' },
        @{ Pattern = '**/**/secrets.yml';  File = 'secrets.yml';                High = 'true';  Why = 'a doubled leading **/ at the root' },
        @{ Pattern = '**/**/secrets.yml';  File = 'a/secrets.yml';              High = 'true';  Why = 'a doubled leading **/ at depth one' },
        @{ Pattern = 'deploy/**/certs/**'; File = 'docs/readme.md';             High = 'false'; Why = 'an unrelated path' }
    )) {
        $script = @"
set -euo pipefail
high=false
patterns='$($case.Pattern)'
files='$($case.File)'
$mBody
echo "HIGH=`$high"
"@
        $out = ($script -replace "`r", '') | & $bash.Source -s 2>&1 | Out-String
        if ($out -notmatch "HIGH=$($case.High)\b") {
            throw "review-tier.yml matched $($case.Why) wrong ($($case.Pattern) vs $($case.File), expected high=$($case.High)):`n$out"
        }
    }

    # A label-read failure on a NORMAL PR keeps HIGH coverage AND fails the job, like
    # every other failure path (follow-up batch, item 3).
    $label = [regex]::Match($tierWorkflow, '(?ms)^(?<i>[ ]+)if \$high; then.*?^\k<i>fi\r?$')
    if (-not $label.Success) { throw 'review-tier.yml: could not locate the label block' }
    $lIndent = $label.Groups['i'].Value.Length
    $lBody = ($label.Value -split '\r?\n' | ForEach-Object { if ($_.Length -ge $lIndent) { $_.Substring($lIndent) } else { $_.TrimStart() } }) -join "`n"
    $script = @"
set -euo pipefail
GITHUB_REPOSITORY=o/r PR_NUMBER=1 high=false
tier_high_on_failure() { echo TIERED_HIGH; }
gh() { case "`$*" in 'pr view'*) return 1 ;; *) return 0 ;; esac; }
$lBody
echo REACHED_END
"@
    $out = ($script -replace "`r", '') | & $bash.Source -s 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($out -notmatch 'TIERED_HIGH' -or $code -eq 0 -or $out -match 'REACHED_END') {
        throw "a label-read failure must apply HIGH and fail the job (exit $code):`n$out"
    }
}
foreach ($check in '-s "$policy"', 'jq -e . "$policy"', 'has("high")', 'permissions:') {
    if ($guard -notmatch [regex]::Escape($check)) {
        throw "the shipped review-policy guard has lost a content check: $check"
    }
}
foreach ($needle in '.github/canonical-assets.json', '[ ! -f "$required" ]', '[ -f "$required" ]') {
    if ($guard -notmatch [regex]::Escape($needle)) {
        throw "review-policy-guard.yml is missing a control-plane presence/high check: $needle"
    }
}
if ($guard -notmatch '(?s)for required in \.claude/ci-budget-approval\.json \.github/canonical-assets\.json \\\s+nuget\.config NuGet\.config global\.json \.config/dotnet-tools\.json \.npmrc Directory\.Build\.props; do') {
    throw 'the guard must check optional HIGH paths, including the manifest, with both NuGet casings'
}

$widePush = "branches: ['**']"
if ($text -match [regex]::Escape($widePush) -or $guard -match [regex]::Escape($widePush)) {
    throw 'scaffold-ci must not emit duplicate push and pull_request runs for PR branches'
}

# `.github/workflows/**` left the policy's high list on 2026-08-19 and is asserted in the
# guard instead. Scaffolding it HIGH again reinstates a superseded rule and re-spends a
# metered CodeRabbit review on every workflow edit - measured at four actionable comments
# across 27 config-only HIGH PRs in a month, while 45 of 100 HIGH PRs were throttled out
# entirely. The example policy carries the same instruction in its own $comment block.
$policyExample = Get-Content (Join-Path $assets 'review-policy.example.json') -Raw
$policy = $policyExample | ConvertFrom-Json
if ($policy.high -notcontains '.claude/ci-budget-approval.json' -or
    $guard -notmatch [regex]::Escape('.claude/ci-budget-approval.json')) {
    throw 'The committed CI-budget approval must be tiered HIGH and required by the guard.'
}
if ($policy.high -contains '.github/workflows/**') {
    throw "the example policy tiers .github/workflows/** HIGH again; the guard's assertions replaced it"
}
if ($policy.high -notcontains '.config/dotnet-tools.json' -or
    $guard -notmatch [regex]::Escape('.config/dotnet-tools.json')) {
    throw '.config/dotnet-tools.json must be HIGH when present and included in the example policy'
}
# The trade only holds while the assertions that replaced the glob are actually shipped.
# They moved OUT of this workflow on 2026-08-24: the two grep steps became one call to
# assert_workflow_hygiene.py, so the assertions are pinned in the script and the guard is
# pinned to invoke it. Checking only the guard would now pass over a deleted checker.
$hygiene = Get-Content (Join-Path $assets 'assert_workflow_hygiene.py') -Raw
if ($guard -notmatch [regex]::Escape('python3 .github/scripts/assert_workflow_hygiene.py')) {
    throw 'the guard no longer invokes assert_workflow_hygiene.py; the hygiene assertions would never run'
}

# The scheduled drift sweep is a workflow of the canonical (private) skills repository, not
# of this mirror. Skip with a stated reason where it is absent rather than fail on a file
# this repository deliberately does not own.
$driftWorkflowPath = Join-Path $root '..' '..' '.github' 'workflows' 'canonical-asset-drift.yml'
if (Test-Path -LiteralPath $driftWorkflowPath) {
    $driftWorkflow = Get-Content -LiteralPath $driftWorkflowPath -Raw
    if (-not $driftWorkflow.Contains("steps.mirror_semantics.outcome == 'success'") -or
        -not $driftWorkflow.Contains('absent from the public mirror; nothing compared')) {
        throw 'drift issue closure must require a successful mirror comparison, and missing mirror assets must fail'
    }
}
else {
    Write-Host "SKIP: canonical-asset-drift.yml not present in this tree - $driftWorkflowPath"
}
foreach ($assertion in 'SHA_LEN', 'pull_request_target', 'workflow_run', 'write-all') {
    if ($hygiene -notmatch [regex]::Escape($assertion)) {
        throw "assert_workflow_hygiene.py has lost the assertion that replaced the high glob: $assertion"
    }
}
# Scoped to third-party owners on purpose: a gate on all owners would have failed 27 of 28
# estate repos, since every unpinned ref measured was actions/*.
# Matched on the METHOD CALL, not on the receiver's name. This used to pin the literal
# `ref.startswith("actions/")`, and on 2026-09-05 the receiver legitimately became
# `owner` when comparisons were normalised to lowercase -- GitHub resolves an action's
# owner/repository case-insensitively, so `Actions/checkout@<sha>` was being classified
# third-party and slipping the first-party rule entirely. The behaviour this assertion
# exists to protect was unchanged by that; only the spelling moved. Pinning a spelling
# turns a correct refactor into a red required check, so pin the branch instead.
if ($hygiene -notmatch 'startswith\("actions/"\)') {
    throw 'the hygiene checker must exempt first-party actions/* from the third-party pin FAILURE, or it reddens the estate'
}
# The allowlist must stay OPT-IN. Defaulting it on fails any repo using a third-party
# action not in it, which across this estate is most of them.
if ($hygiene -notmatch [regex]::Escape('os.environ.get("TRUSTED_THIRD_PARTY_ACTIONS", "")')) {
    throw 'the third-party allowlist must be read from the environment, not hardcoded on'
}
# Required status check across the estate; renaming it detaches the branch rule silently.
if ($guard -notmatch [regex]::Escape('name: Review policy intact')) {
    throw 'the guard job must stay named "Review policy intact" - it is a required status check'
}

# THE MERGE BARRIER MUST BE HIGH, and the guard must assert it. Added 2026-08-23 after an
# adversarial-review sweep found the same hole in six estate repos: "CI Gate" is a required
# check produced by the PR's own copy of ci.yml, so a PR that keeps the job, its name and
# its needs: list, and only guts the aggregation step, reports green while gating nothing.
# The policy and the guard have to agree, or the guard fails every repo it is installed
# into (it exits 1 on a required path missing from .high).
$mergeBarrier = @(
    '.github/workflows/ci.yml',
    '.github/workflows/review-policy-guard.yml',
    '.github/workflows/review-tier.yml',
    '.github/scripts/assert_gate_coverage.py',
    '.github/scripts/assert_workflow_hygiene.py'
)
foreach ($path in $mergeBarrier) {
    if ($policy.high -notcontains $path) {
        throw "the example policy no longer tiers the merge barrier HIGH: $path"
    }
    if ($guard -notmatch [regex]::Escape($path)) {
        throw "the guard's required-high loop no longer asserts: $path"
    }
}
if ($policy.high -notcontains '.github/canonical-assets.json' -or
    $guard -notmatch [regex]::Escape('.github/canonical-assets.json')) {
    throw 'the example policy and optional-file guard must keep the canonical-asset manifest HIGH when present'
}

# Keep this contract tied to the guard's actual required list so adding a new
# control path cannot leave the example policy and its test behind.
$requiredLoop = [regex]::Match($guard, '(?s)for required in (?<paths>.*?)\s*; do')
if (-not $requiredLoop.Success) { throw 'review-policy-guard.yml required-high loop was not found' }
$requiredPaths = @([regex]::Matches($requiredLoop.Groups['paths'].Value, '\.github/[^\s\\]+|\.claude/[^\s\\]+|\.coderabbit\.yaml') | ForEach-Object Value)
foreach ($path in $requiredPaths) {
    if ($policy.high -notcontains $path) { throw "the example policy omits guard-required HIGH path: $path" }
}

# The gate checker must assert the gate's OWN semantics, not just its needs: membership.
# A gate with no `if: always()` is skipped exactly when an upstream job fails, and a gate
# with no step keyed on a needs.<job>.result aggregates nothing - both report green.
$gateChecker = Get-Content (Join-Path $assets 'assert_gate_coverage.py') -Raw
foreach ($semantic in 'always()', 'GATE_CONDITIONAL_EXEMPT') {
    if ($gateChecker -notmatch [regex]::Escape($semantic)) {
        throw "assert_gate_coverage.py has lost a gate-semantics assertion: $semantic"
    }
}
# The needs.<job>.result pattern is asserted by SHAPE rather than as a literal. It used
# to be pinned as the exact string `needs\.[A-Za-z0-9_*-]+\.result`, and on 2026-09-05 a
# capture group was added around the job id so the checker could require the gate's
# condition to cover EVERY declared dependency rather than merely one of them -- a gate
# declaring `needs: [build, lint]` whose condition named only `build` had been passing
# while a lone lint failure left the required context green. The literal no longer
# matched, so a strictly stronger checker failed the assertion protecting it.
# It has now broken a SECOND time for the same reason, on 2026-09-09: the character
# class moved behind the shared $ID interpolation when the checker absorbed the
# per-outcome coverage rule from <repo>, so the pattern is spelt
# `needs\.({ID}|\*)\.result` and `needs\.({ID})\.result`. Twice is a signal about the
# assertion, not about the checker -- pinning one spelling of a regex fails every time
# that regex gets stronger, which is the wrong direction for a guard.
#
# So this now asserts only that the checker still keys on `needs.<something>.result`,
# and that the constant carrying those semantics is present. What the pattern MEANS is
# owned by scaffold-ci/test/verify-gate-coverage.ps1, which exercises per-job and
# per-outcome coverage against real workflows rather than grepping for a spelling.
if ($gateChecker -notmatch 'needs\\\.[^\\\s]{0,24}\\\.result') {
    throw 'assert_gate_coverage.py has lost the needs.<job>.result gate-semantics assertion'
}
if ($gateChecker -notmatch 'FAILURE_CONDITION_ATOM') {
    throw 'assert_gate_coverage.py has lost the failure/cancellation condition atom'
}

# The old grep self-match probe was dormant: the guard no longer contains those greps.
# Assert the actual parser-based control remains wired instead of looping over zero
# patterns and reporting a vacuous pass.
if ($guard -match 'grep\s+-rEn') {
    throw 'review-policy-guard.yml reintroduced workflow greps; the current parsed hygiene check must own this control'
}
if ($guard -notmatch 'assert_workflow_hygiene\.py') {
    throw 'review-policy-guard.yml no longer runs the parsed workflow hygiene checker'
}

'scaffold-ci review control plane OK'
