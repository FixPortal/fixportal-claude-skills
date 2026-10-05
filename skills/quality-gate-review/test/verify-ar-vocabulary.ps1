$ErrorActionPreference = 'Stop'
$text = Get-Content (Join-Path $PSScriptRoot '..' 'SKILL.md') -Raw
$reference = Get-Content (Join-Path $PSScriptRoot '..' 'references' 'gate-contract.md') -Raw
$corpus = $text + "`n" + $reference

# Step 2 must consume the vocabulary adversarial-review actually emits.
# Phase 3 (briefs/phase3-adjudicate.txt) emits a severity plus a consensus tag —
# [unanimous] / [majority] / [contested] — with re-rating for a refuted mechanism.
# There is no "Dismissed" state anywhere in adversarial-review. CONFIRMED / REFUTED /
# INDETERMINATE belong to the separate, opt-in Phase 4 verify (briefs/phase4-verify.txt).
foreach ($pattern in '\|\s*Confirmed\s*\|', '\|\s*Disputed\s*\|', '\|\s*Dismissed\s*\|') {
    if ($corpus -match $pattern) {
        throw "Step 2 maps an AR verdict that adversarial-review never emits: $pattern"
    }
}
foreach ($pattern in '(?im)^#{2,4}\s+(Confirmed|Disputed|Dismissed)\s*$',
                     '(?im)^\*\*(Confirmed|Disputed|Dismissed)(?:\s+—[^*]*)?\*\*\s*$') {
    if ($corpus -match $pattern) {
        throw "Output template retains an obsolete AR state heading: $pattern"
    }
}

foreach ($needle in '[unanimous]', '[majority]', '[contested]', 'mechanism refuted', 'Phase 4') {
    if ($corpus -notmatch [regex]::Escape($needle)) {
        throw "Step 2 missing the real adjudication vocabulary: $needle"
    }
}

foreach ($needle in 'Lean already. Ship.', 'net: -<N> lines possible.',
                    'blocks PASS', 'Review Tier', 'UNCLASSIFIED',
                    'dependabot[bot]', 'renovate[bot]', 'coverage gap',
                    'adversarial-review', 'ai-findings-ledger') {
    if ($corpus -notmatch [regex]::Escape($needle)) {
        throw "Gate contract missing owned mapping or cross-reference: $needle"
    }
}

foreach ($needle in 'classify supplied evidence', 'sole new-review exception',
                    '| Severity | Consensus | Phase 4 | Finding |') {
    if ($corpus -notmatch [regex]::Escape($needle)) {
        throw "Gate contract has an unclear evidence or output boundary: $needle"
    }
}
if ($corpus -match 'Gate Findings \(not in AR\)') {
    throw 'Gate output still invites an unbounded second defect review.'
}

# The composition domain must be a REQUIRED input and must BLOCK, not merely be
# mentioned. A domain that is listed but not blocking is the shape that let class A
# go unowned: present on paper, no teeth.
foreach ($needle in 'composition-review', 'Composition review output') {
    if ($corpus -notmatch [regex]::Escape($needle)) {
        throw "Gate does not consume the composition domain: $needle"
    }
}
# Anchored on the NUMBERED STEP, not on a sentence in isolation. A free-floating
# "blocks PASS" phrase survives a step 6 reworded to "a composition finding, unlike a
# Ponytail finding which **blocks PASS**, is advisory only" - the ponytail clause keeps
# the needle alive while the composition rule is inverted.
if ($text -notmatch '(?m)^6\..*\bAny composition finding \*\*blocks PASS\*\*') {
    throw 'Step 6 no longer states that any composition finding blocks PASS.'
}
# ...and the inversion itself is rejected outright, wherever it is written.
if ($corpus -match '(?i)composition[^.\n]*(advisory|does not block|never blocks|non-blocking)') {
    throw 'Composition findings are described as non-blocking somewhere in the gate.'
}
# Step 6 has TWO rules and the anchor above pins only the first. The coverage-gap half is
# what stops five bare N/As reading as a pass, so it is anchored separately: leaving the
# finding sentence intact while replacing this clause with "is recorded as a note and does
# not affect the verdict" is a live mutation the finding anchor cannot see.
if ($text -notmatch '(?m)^6\..*\*\*coverage gap\*\* and blocks PASS') {
    throw 'Step 6 no longer states that a composition coverage gap blocks PASS.'
}

# The permitted-absence value must stay CONSTRAINED. Widening it to a bare `N/A` - "where
# the input is `N/A` for any reason, there are no questions to answer" - turns the
# not-required exemption into a blanket one, disabling the control on every PR from a
# single word edit. Pinned at step 6, where the widening would be written, and counted
# across the corpus so it cannot be dropped from the required-inputs line or the contract.
$permitted = 'N/A — no stateful or messaging path touched'
if ($text -notmatch ('(?m)^6\..*' + [regex]::Escape($permitted))) {
    throw "Step 6's permitted absence is no longer the constrained value: $permitted"
}
$permittedCount = [regex]::Matches($corpus, [regex]::Escape($permitted)).Count
if ($permittedCount -lt 3) {
    throw "The constrained permitted absence appears $permittedCount time(s); expected it at the required-inputs line, step 6, and the FAIL trigger."
}

$body = $text -replace '(?s)^---.*?---\s*', ''
$wordCount = [regex]::Matches($body, '\b[\p{L}\p{N}_/-]+\b').Count
if ($wordCount -ge 500) {
    throw "SKILL.md is $wordCount words; gate internals should live in its reference."
}

'quality-gate-review AR vocabulary OK'
