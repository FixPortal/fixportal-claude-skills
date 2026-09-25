$ErrorActionPreference = 'Stop'
$text = Get-Content (Join-Path $PSScriptRoot '..' 'SKILL.md') -Raw
$root = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
$scaffoldRoot = Join-Path $root 'scaffold-ci'
$scaffoldSkill = Get-Content (Join-Path $scaffoldRoot 'SKILL.md') -Raw
$ciContract = Get-Content (Join-Path $scaffoldRoot 'references' 'ci-workflow.md') -Raw
$securityContract = Get-Content (Join-Path $scaffoldRoot 'references' 'dependencies-and-security.md') -Raw
$reviewContract = Get-Content (Join-Path $scaffoldRoot 'references' 'review-policy.md') -Raw
$secretSweep = Get-Content (Join-Path $scaffoldRoot 'assets' 'secret-sweep.yml') -Raw

# audit-ci consumes the shipped scaffold contract; it must not retain a second,
# independently-maintained baseline that will drift when scaffold-ci changes.
foreach ($reference in 'scaffold-ci/SKILL.md',
                       'scaffold-ci/references/ci-workflow.md',
                       'scaffold-ci/references/dependencies-and-security.md',
                       'scaffold-ci/references/review-policy.md',
                       'scaffold-ci/assets/assert_gate_coverage.py',
                       'scaffold-ci/assets/assert_workflow_hygiene.py',
                       'scaffold-ci/assets/secret-sweep.yml') {
    if ($text -notmatch [regex]::Escape($reference)) {
        throw "SKILL.md must reference the authoritative scaffold-ci contract: $reference"
    }
}
foreach ($path in '.github/workflows/ci.yml',
                  '.github/workflows/review-policy-guard.yml',
                  '.github/scripts/assert_gate_coverage.py',
                  '.github/scripts/assert_workflow_hygiene.py') {
    if ($reviewContract -notmatch [regex]::Escape($path)) {
        throw "scaffold-ci no longer declares the merge-barrier path audit-ci consumes: $path"
    }
}

if ($scaffoldSkill -notmatch '(?m)^3\. Apply the relevant references\. Control surfaces include .*review-tier\.yml') {
    throw 'scaffold-ci no longer declares the control-surface baseline audit-ci consumes'
}
if ($text -notmatch '(?is)PR-range scan and push-range scan in the selected primary workflow') {
    throw 'Secret-scanning guidance must follow the selected primary workflow rather than hard-code ci.yml.'
}
$normalizedSkill = $text -replace '\s+', ' '
if ($text -match 'List completed `ci\.yml` workflow runs' -or
    $normalizedSkill -notmatch 'For a normal cost check.*exactly equals the audited SHA.*When evaluating an over-budget exception.*run_id') {
    throw 'Cost evidence guidance must allow the committed approval to select its successful ancestor run.'
}
if ($ciContract -notmatch '(?s)push.*mainline.*tags `v\*`') {
    throw 'scaffold-ci no longer declares the narrow mainline-and-tag push baseline'
}
if ($secretSweep -notmatch 'actions/checkout@[0-9a-f]{40}\s+# v7') {
    throw 'scaffold-ci secret-sweep no longer carries the reviewed first-party SHA-pin exception'
}

# THE CHECKER MUST HONOUR THE EXCEPTION, not merely the asset carry it.
#
# The two assertions above and below describe the exception from the WORKFLOW side:
# secret-sweep.yml has the pin, the private gate does not copy it. Nothing asserted
# that assert_workflow_hygiene.py knows about it -- and that gap had teeth. On
# 2026-09-05 the pin check was corrected so the actions/* major-tag rule is evaluated
# before the generic pinned-reference return (it had been unreachable for exactly the
# case it is written about). The corrected rule then reported the sweep's reviewed pin
# as drift in all 19 repositories carrying it, and the apparently obvious remedy --
# remove the pins -- reached nineteen pull requests before the assertion above refused
# the first one.
#
# So both sides are pinned now. Remove the exception from the checker and this fails,
# instead of the estate discovering it one red required check at a time.
$hygiene = Get-Content (Join-Path $scaffoldRoot 'assets' 'assert_workflow_hygiene.py') -Raw

# THE ASSIGNMENT IS EXTRACTED FIRST, and every assertion below reads only that. Both of
# the looser forms this replaced were found by CodeRabbit in review of this skill
# and both failed in the permissive direction:
#   * searching the whole FILE for secret-sweep.yml passed on a mention anywhere in it,
#     including in a comment, without the filename ever being a member of the set;
#   * rejecting only `frozenset(os.environ` missed every other spelling -- a generator
#     reading the environment one expression later satisfied it.
# An assertion that guards an exception must not itself be widenable.
$exemptMatch = [regex]::Match($hygiene, 'SHA_PIN_EXEMPT_WORKFLOWS\s*=\s*(?<body>[^)]*\))')
if (-not $exemptMatch.Success) {
    throw 'scaffold-ci assert_workflow_hygiene.py no longer declares SHA_PIN_EXEMPT_WORKFLOWS; the first-party major-tag rule would report the reviewed secret-sweep pin as drift in every repository that carries the sweep'
}
$exemptBody = $exemptMatch.Groups['body'].Value
if ($exemptBody -notmatch '["'']secret-sweep\.ya?ml["'']') {
    throw 'scaffold-ci assert_workflow_hygiene.py no longer lists secret-sweep.yml as a member of SHA_PIN_EXEMPT_WORKFLOWS'
}
# Scoped by FILENAME, never by anything the caller supplies. An exception the caller can
# widen is an exception that spreads, which is precisely what the private-gate assertion
# below exists to prevent. Checked against the ASSIGNMENT, so no spelling escapes it.
foreach ($widener in 'os\.environ', 'sys\.argv', 'getenv') {
    if ($exemptBody -match $widener) {
        throw "the secret-sweep SHA-pin exception must stay filename-scoped, not caller-widenable (found '$widener' in its assignment)"
    }
}
$privateGateMatch = [regex]::Match($securityContract, '(?s)### The gate.*?```yaml\r?\n(?<yaml>.*?)\r?\n```')
if (-not $privateGateMatch.Success) {
    throw 'scaffold-ci private secret gate snippet is missing'
}
$privateGate = $privateGateMatch.Groups['yaml'].Value
if ($privateGate -notmatch '(?m)^\s*- uses: actions/checkout@v7$') {
    throw 'scaffold-ci private secret gate must use the house first-party checkout tag'
}
if ($privateGate -match 'actions/checkout@[0-9a-f]{40}') {
    throw 'scaffold-ci private secret gate incorrectly duplicates the sweep-only SHA-pin exception'
}

$secretSweepSurface = [regex]::Match($text, '(?m)^\| \*\*Secret scanning\*\* \|.*$')
if (-not $secretSweepSurface.Success) {
    throw 'audit-ci does not explicitly audit secret-sweep.yml as a scaffold control surface'
}
foreach ($needle in 'scaffold-ci/assets/secret-sweep.yml',
                    'scaffold-ci/references/dependencies-and-security.md',
                    'trigger',
                    'pin',
                    'detector',
                    'install') {
    if ($secretSweepSurface.Value -notmatch [regex]::Escape($needle)) {
        throw "audit-ci secret-scanning surface must delegate its $needle contract to scaffold-ci"
    }
}

foreach ($needle in 'push to mainline + tags `v*`',
                    'reviewed exception',
                    'blacksmith-<N>vcpu-ubuntu-2404') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md missing current scaffold-ci guidance: $needle"
    }
}

# Blacksmith guidance verified against docs.blacksmith.sh/blacksmith-caching/docker-builds
# on 2026-08-03. Each forbidden string below was factually wrong at that date.
foreach ($pattern in 'setup-docker-builder@<full-commit-sha> # v1',
                     'blacksmith-<N>vcpu-ubuntu-2204',
                     'Do not assume a\s+vendor-specific notes path') {
    if ($text -match $pattern) {
        throw "SKILL.md carries guidance refuted by the vendor docs: $pattern"
    }
}

# `max-cache-size-mb` does not exist as an input. The name may still appear, but ONLY
# on a line that marks it as refuted — never as a recommendation or a drift check.
$lines = Get-Content (Join-Path $PSScriptRoot '..' 'SKILL.md')
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'max-cache-size-mb' -and
        $lines[$i] -notmatch 'invented|corrected|refuted|does not exist') {
        throw "SKILL.md line $($i + 1) treats max-cache-size-mb as real: $($lines[$i].Trim())"
    }
}

# cache-key is a REQUIRED input on setup-docker-builder and appears in every
# official @v2 example; the swap table must carry it.
foreach ($needle in 'cache-key',
                    'setup-docker-builder@<full-commit-sha> # v2',
                    '~/.agents/notes/deploy-and-ci-traps.md',
                    'time-based garbage collection') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md missing corrected Blacksmith guidance: $needle"
    }
}

'audit-ci Blacksmith guidance OK'
