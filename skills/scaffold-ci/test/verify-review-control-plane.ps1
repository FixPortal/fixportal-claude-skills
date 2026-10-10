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
        @{ Expected = 0;    Retrieved = 0;    High = 'false'; Why = 'a PR with no changed files' },
        @{ Expected = 2;    Retrieved = 2;    High = 'false'; Why = 'a small, complete list' },
        @{ Expected = 5;    Retrieved = 4;    High = 'true';  Why = 'a short enumeration' },
        @{ Expected = 3000; Retrieved = 3000; High = 'true';  Why = 'an enumeration at the 3000-file ceiling with matching counts' },
        @{ Expected = 3500; Retrieved = 3000; High = 'true';  Why = 'an enumeration capped below changed_files' },
        # `[ 1 -ne null ]` returns 2,
        # which inside `if` counts as FALSE -- the completeness check silently did
        # nothing. The case guard tiers HIGH on any non-numeric count instead.
        @{ Expected = 'null'; Retrieved = 1; High = 'true'; Why = 'a non-numeric changed_files (null)' }
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
    # cost and let the count and the list disagree mid-run.
    $filesCalls = [regex]::Matches($block.Value, 'pulls/\$PR_NUMBER/files').Count
    if ($filesCalls -ne 1) {
        throw "review-tier.yml must enumerate the changed files once; found $filesCalls /files call(s)"
    }

    # The pattern match, EXECUTED: the block translates each glob with the hook's
    # glob_to_regex (copied verbatim), so a mid-pattern `**/` matches zero directories
    # as well as many and a lone `*`/`?` matches WITHIN one path segment.
    # A lone `*` must stop at `/`; the `infra/*` case below checks that boundary
    # so the server, hook and checker agree.
    $match = [regex]::Match($tierWorkflow, '(?ms)^(?<i>[ ]+)if ! \$high; then.*?^\k<i>fi\r?$')
    if (-not $match.Success) { throw 'review-tier.yml: could not locate the pattern-match block' }
    $mIndent = $match.Groups['i'].Value.Length
    $mBody = ($match.Value -split '\r?\n' | ForEach-Object { if ($_.Length -ge $mIndent) { $_.Substring($mIndent) } else { $_.TrimStart() } }) -join "`n"
    foreach ($case in @(
        @{ Pattern = 'deploy/**/certs/**'; File = 'deploy/certs/a.pem';         High = 'true';  Why = 'mid-pattern ** at zero depth' },
        @{ Pattern = 'deploy/**/certs/**'; File = 'deploy/prod/eu/certs/a.pem'; High = 'true';  Why = 'mid-pattern ** at depth' },
        @{ Pattern = '**/secrets.json';    File = 'secrets.json';               High = 'true';  Why = 'leading ** at the root' },
        @{ Pattern = 'infra/*';            File = 'infra/a/b.bicep';            High = 'false'; Why = 'a lone * no longer crosses /' },
        @{ Pattern = 'tools/*.ps1';        File = 'tools/sub/x.ps1';            High = 'false'; Why = 'a single * must stop at the next /' },
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
    # every other failure path.
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

    # --- matcher cost, bot skip, bracket globs --------------------------------------------
    function Get-Block([string] $Text, [string] $StartPattern) {
        $m = [regex]::Match($Text, "(?ms)^(?<i>[ ]+)$StartPattern.*?^\k<i>fi\r?$")
        if (-not $m.Success) { throw "review-tier.yml: could not locate the block starting /$StartPattern/" }
        $n = $m.Groups['i'].Value.Length
        return ($m.Value -split '\r?\n' | ForEach-Object { if ($_.Length -ge $n) { $_.Substring($n) } else { $_.TrimStart() } }) -join "`n"
    }
    function Invoke-Bash([string] $Script) { ($Script -replace "`r", '') | & $bash.Source -s 2>&1 | Out-String }

    # M5: the matcher greps the whole path list once per GLOB, not once per path x glob pair.
    # 200 paths x 20 globs was 4,000 greps (and 4,000 seds); it must stay at one per glob.
    $counted = @'
set -euo pipefail
high=false
CALLS=$(mktemp)
grep() { echo g >> "$CALLS"; command grep "$@"; }
files=$(seq 1 200 | sed 's#^#src/dir/f#; s#$#.cs#')
patterns=__PATTERNS__
__BODY__
echo "HIGH=$high"
echo "GREPS=$(wc -l < "$CALLS" | tr -d ' ')"
'@
    $none = "`$(seq 1 20 | sed 's#^#zzz#; s#`$#/**#')"
    $out = Invoke-Bash $counted.Replace('__PATTERNS__', $none).Replace('__BODY__', $mBody)
    if ($out -notmatch 'HIGH=false\b') { throw "M5: 20 globs matching none of 200 paths must stay NORMAL:`n$out" }
    $greps = [int]([regex]::Match($out, 'GREPS=(\d+)').Groups[1].Value)
    if ($greps -gt 20) { throw "M5: the matcher ran $greps greps for 20 globs over 200 paths; it must run one per glob:`n$out" }
    $last = "`$(printf 'zzz/**\nsrc/dir/f200.cs\n')"
    if ((Invoke-Bash $counted.Replace('__PATTERNS__', $last).Replace('__BODY__', $mBody)) -notmatch 'HIGH=true\b') { throw 'M5: a glob matching only the LAST path must still tier HIGH' }

    # A grep error (exit 2: a regex it cannot compile) is not "no match": it fails closed to HIGH.
    $grepError = @'
set -euo pipefail
high=false
grep() { return 2; }
files='src/a.cs'
patterns='docs/**'
__BODY__
echo "HIGH=$high"
'@
    $out = Invoke-Bash $grepError.Replace('__BODY__', $mBody)
    if ($out -notmatch 'HIGH=true\b' -or $out -notmatch 'failing closed') { throw "a grep error in the matcher must fail closed to HIGH with a warning:`n$out" }

    # M5: the 3000 guard counts paths after rename expansion. 1,600 renames are 1,600 records
    # (under the ceiling) but 3,200 paths for the matcher to walk.
    $renames = @'
set -euo pipefail
GITHUB_REPOSITORY=o/r PR_NUMBER=1 high=false
gh() { case "$*" in *'/files'*) for i in $(seq 1 __N__); do printf 'n%s\to%s\n' "$i" "$i"; done ;; *) echo __N__ ;; esac; }
__BODY__
echo "HIGH=$high"
'@
    foreach ($case in @(@{ N = 1600; High = 'true' }, @{ N = 100; High = 'false' })) {
        $out = Invoke-Bash $renames.Replace('__N__', [string]$case.N).Replace('__BODY__', $body)
        if ($out -notmatch "HIGH=$($case.High)\b") { throw "M5: $($case.N) renames should give high=$($case.High) (the guard counts paths, not records):`n$out" }
    }

    # L5 + XL9: a dependency-bot PR skips classification AND sheds a stale review-high label.
    $skip = Get-Block $tierWorkflow 'if \[ "\$PR_AUTHOR" ='
    foreach ($case in @(
        @{ Author = 'dependabot[bot]'; Skipped = $true },
        @{ Author = 'renovate[bot]';   Skipped = $true },
        @{ Author = 'octocat';         Skipped = $false }
    )) {
        $out = Invoke-Bash @"
set -euo pipefail
PR_AUTHOR='$($case.Author)' GITHUB_REPOSITORY=o/r PR_NUMBER=1
LOG=`$(mktemp); trap 'cat "`$LOG"' EXIT
gh() { echo "GH:`$*" >> "`$LOG"; }
$skip
echo AFTER
"@
        $removed = $out -match 'GH:pr edit 1 --repo o/r --remove-label review-high'
        $reached = $out -match 'AFTER'
        if ($case.Skipped -and (-not $removed -or $reached)) { throw "L5/XL9: $($case.Author) must skip classification and remove review-high:`n$out" }
        if (-not $case.Skipped -and ($removed -or -not $reached)) { throw "L5/XL9: $($case.Author) must fall through untouched:`n$out" }
    }

    # L7 (server half): a bracket or brace entry on the base ref fails closed, loudly.
    $bracket = Get-Block $tierWorkflow "if grep -q '\[\[\{\]' <<< `"\`$patterns`"; then"
    foreach ($case in @(@{ P = 'src/[ab].cs'; Fails = $true }, @{ P = 'src/{a,b}.cs'; Fails = $true }, @{ P = 'src/**/*.cs'; Fails = $false })) {
        $out = Invoke-Bash @"
set -euo pipefail
BASE_REF=main
tier_high_on_failure() { echo TIERED_HIGH; }
patterns='$($case.P)'
$bracket
echo REACHED_END
"@
        if ($case.Fails -and ($out -notmatch 'TIERED_HIGH' -or $out -match 'REACHED_END')) { throw "L7: policy entry '$($case.P)' must fail closed:`n$out" }
        if (-not $case.Fails -and $out -notmatch 'REACHED_END') { throw "L7: policy entry '$($case.P)' is valid and must not fail:`n$out" }
    }
}

# L7 (PR-time half): the policy guard rejects a bracket or brace glob where the policy is edited.
$jq = Get-Command jq -ErrorAction SilentlyContinue
$guardJq = [regex]::Match($guard, "if ! jq -e '(?<f>[^']*test\([^']*)' `"\`$policy`"")
if (-not $guardJq.Success) { throw 'review-policy-guard.yml has lost its bracket/brace glob check' }
if (-not $jq) { Write-Host 'SKIP: no jq on this host; the guard bracket check was not executed' }
else {
    foreach ($case in @(
        @{ Policy = '{"high":["a/[ab].cs"]}';                  Ok = $false },
        @{ Policy = '{"high":["a/{x,y}.cs"]}';                 Ok = $false },
        @{ Policy = '{"high":["a/**"],"low":["docs/[x].md"]}'; Ok = $false },
        @{ Policy = '{"high":["a/**","b/*.cs"],"low":["docs/**"]}'; Ok = $true },
        @{ Policy = '{"high":["a/**"]}';                       Ok = $true }
    )) {
        $file = New-TemporaryFile
        try {
            Set-Content -LiteralPath $file -Value $case.Policy -NoNewline
            & $jq.Source -e $guardJq.Groups['f'].Value $file *> $null
            if (($LASTEXITCODE -eq 0) -ne $case.Ok) { throw "L7: the guard's glob check gave exit $LASTEXITCODE for $($case.Policy)" }
        }
        finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
}

# XL10: the safety comment must not claim that every read is against the base ref; PR metadata
# (changed files, labels, author) is read through the API too.
if ($tierWorkflow -match 'every read is an API call against the base ref') {
    throw 'XL10: review-tier.yml still claims every read is against the base ref'
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
if ($guard -notmatch '(?s)for required in \.claude/ci-budget-approval\.json \.github/canonical-assets\.json \\\s+\.github/scripts/assert_canonical_assets\.py \\\s+nuget\.config NuGet\.config global\.json \.config/dotnet-tools\.json \.npmrc Directory\.Build\.props; do') {
    throw 'the guard must check optional HIGH paths, including the manifest and its checker, with both NuGet casings'
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
# The $comment block says the FIRST TWO high entries are the review control plane -- this
# file and .coderabbit.yaml. The order is what the comment points at, so it is pinned.
if ($policy.high[0] -ne '.claude/review-policy.json' -or $policy.high[1] -ne '.coderabbit.yaml') {
    throw "the example policy's first two high entries must be the review control plane; got '$($policy.high[0])', '$($policy.high[1])'"
}
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

# Standard GitHub-hosted runner minutes are FREE on public repositories (GitHub's Actions
# billing docs), so the bill never flags an over-budget lane there; only larger runners
# are charged at every visibility. review-policy.md used to claim the opposite, which
# turned the envelope's "unmeasured on public repos" gap into a cost claim that was false.
if ($text -match "(?s)public\s+repo's\s+minutes\s+are\s+billed\s+the\s+same") {
    throw "review-policy.md claims public Actions minutes are billed like a private repo's"
}
if ($text -notmatch '(?s)standard\s+GitHub-hosted\s+runner\s+minutes\s+are\s+free\s+on\s+public\s+repositories') {
    throw 'review-policy.md must state that standard runner minutes are free on public repositories'
}

# The mechanical-sync exception used to say an asset-parity PR "is NORMAL, not HIGH".
# review-tier.yml (shipped by this same skill) labels any PR touching a HIGH path and
# re-applies a removed label, so the PR is HIGH and CodeRabbit runs regardless. The
# exception governs what the PR's review COVERAGE rests on (byte parity), not the label
# or the spend, and the doc has to say so or it contradicts the workflow it ships.
$mechanicalSync = [regex]::Match($text, '(?ms)^\*\*Mechanical-sync exception\.\*\*(?<body>.*?)(?=^### )').Groups['body'].Value
if (-not $mechanicalSync) { throw 'review-policy.md has lost the mechanical-sync exception section' }
if ($mechanicalSync -match '(?s)is\s+NORMAL,\s+not\s+HIGH') {
    throw 'the mechanical-sync exception claims a parity PR tiers NORMAL; review-tier.yml labels it HIGH'
}
if ($mechanicalSync -notmatch '(?s)review-tier\.yml`?\s+still\s+labels\s+the\s+PR\s+HIGH' -or
    $mechanicalSync -notmatch '(?s)CodeRabbit\s+still\s+runs') {
    throw 'the mechanical-sync exception must state that the PR stays labelled HIGH and CodeRabbit still runs'
}

# The parity proof must point at what scripts/canonical-assets.json actually names as
# canonical. It used to say "under assets/" for every shipped file, but the Stryker
# summariser's canonical is templates/summarize-stryker.ps1 -- a comparison against a
# path that does not exist proves nothing.
if ($mechanicalSync -match '(?s)canonical\s+asset\s+under\s+`~/\.agents/skills/scaffold-ci/assets/`') {
    throw 'the mechanical-sync exception puts every canonical asset under assets/; the Stryker summariser is under templates/'
}
foreach ($needle in 'scripts/canonical-assets.json', 'templates/summarize-stryker.ps1') {
    if ($mechanicalSync -notmatch [regex]::Escape($needle)) {
        throw "the mechanical-sync exception must locate canonical assets by the inventory: $needle"
    }
}

# The criterion must describe the comparison it cites. It said BYTE-IDENTICAL while the
# required proof is compare-canonical-file.ps1 -IgnoreLineEndings, which accepts files
# differing only in line endings -- so a PR could pass the proof without meeting the
# stated condition.
if ($mechanicalSync -notmatch '-IgnoreLineEndings') {
    throw 'the mechanical-sync exception must name compare-canonical-file.ps1 -IgnoreLineEndings as the proof'
}
if ($mechanicalSync -match 'BYTE-IDENTICAL') {
    throw 'the mechanical-sync exception claims byte identity, but its proof ignores line endings'
}
if ($mechanicalSync -notmatch '(?s)line\s+endings\s+aside') {
    throw 'the mechanical-sync exception must state that parity is judged with line endings aside'
}

'scaffold-ci review control plane OK'
