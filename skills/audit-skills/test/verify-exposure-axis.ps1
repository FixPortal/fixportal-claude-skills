$ErrorActionPreference = 'Stop'

$root = Join-Path $PSScriptRoot '..'
$skill = Get-Content -LiteralPath (Join-Path $root 'SKILL.md') -Raw
$brief = Get-Content -LiteralPath (Join-Path $root 'audit-brief.md') -Raw
$classesPath = Join-Path $root 'references\exposure-classes.md'

if (-not (Test-Path -LiteralPath $classesPath)) {
    throw 'Axis 5 routes to references/exposure-classes.md; the file must exist.'
}
$classes = Get-Content -LiteralPath $classesPath -Raw

# The axis is worthless if it can report clean without saying what it was clean OVER.
# This is the T1 failure class (absence of evidence rendered as a clean result), and it
# is the specific reason a scope statement is contractual rather than advisory.
foreach ($needle in @(
    'Axis 5 — Exposure',
    'exposure_findings',
    'third_party_homes'
)) {
    if ($brief -notmatch [regex]::Escape($needle)) {
        throw "Worker exposure contract is missing: $needle"
    }
}

if ($brief -notmatch '(?s)🟩 exposure grade with no stated scope') {
    throw 'The brief must forbid an unscoped clean exposure grade.'
}

if ($skill -notmatch [regex]::Escape('never omit the scope line')) {
    throw 'The controller must require the exposure scope line even when the table is omitted.'
}

# PI is a real mounted surface pointed at third-party vendors. Dropping it from discovery
# reintroduces exactly the blind spot this axis was added for: a surface nobody enumerates
# exports skill bodies while the audit reports on five homes and calls that complete.
foreach ($needle in @('~/.pi/skills', '~/.pi/agent/skills')) {
    if ($skill -notmatch [regex]::Escape($needle)) {
        throw "Surface discovery must enumerate PI root: $needle"
    }
    if ($brief -notmatch [regex]::Escape($needle)) {
        throw "Cross-home drift must compare PI root: $needle"
    }
}

if ($skill -notmatch [regex]::Escape('all six runtime surfaces')) {
    throw 'Surface count in the controller must match the enumerated list.'
}
if ($brief -notmatch [regex]::Escape('six runtime surfaces')) {
    throw 'Surface count in the brief must match the enumerated list.'
}

# A sandbox restricts file access, never prompt contents. A reviewer who believes
# otherwise will close a real finding as contained, so both documents must say it.
foreach ($pair in @(@{ n = 'skill'; t = $skill }, @{ n = 'brief'; t = $brief })) {
    # Whitespace-tolerant: both documents wrap prose, so a literal pin would fail on a
    # reflow that changed nothing about the rule.
    if ($pair.t -notmatch '(?s)working\s+directory' -or $pair.t -notmatch 'sandbox') {
        throw "The $($pair.n) must state that a workspace sandbox does not contain skill-body exposure."
    }
}

# Check the reference, NOT the brief. Every class name is a substring of the brief's single
# JSON enum line, so an -or across both documents passes on that one line alone and never
# reads exposure-classes.md at all - the grade table could be deleted outright and this
# still reported OK. Verified by deleting it: the earlier form stayed green.
foreach ($class in 'Credential material', 'Identity and topology', 'Attribution', 'Generic') {
    if ($classes -notmatch [regex]::Escape($class)) {
        throw "Exposure grade table is missing its row: $class"
    }
}

# runtime-fetch is enum-only by design - it has no grade-table row - so it needs its own
# definition, or a worker has a class value with nothing to confirm it against.
if ($classes -notmatch [regex]::Escape('## The `runtime-fetch` class')) {
    throw 'exposure-classes.md must define runtime-fetch, which has no grade-table row.'
}
if ($classes -notmatch [regex]::Escape('cross-project memory store')) {
    throw 'exposure-classes.md must keep the runtime-fetch class, which no token sweep can catch.'
}

# Decisions the user has already made must be written where the grader reads them, or
# every run re-raises them as findings (the 2026-09-25 audit graded thirteen skills 🟧 for
# pointing at the shared traps notes, which the user then accepted as deliberate).
foreach ($needle in '## Accepted disclosures', '~/.agents/notes', 'verify-private-identifiers.ps1') {
    if ($classes -notmatch [regex]::Escape($needle)) {
        throw "exposure-classes.md must record the accepted-disclosure decisions: $needle"
    }
}

# The JSON enum and the reference must not drift apart into two taxonomies.
if ($brief -notmatch [regex]::Escape('"credential|identity-topology|attribution|runtime-fetch"')) {
    throw 'The brief exposure class enum must match the documented taxonomy.'
}

'audit-skills exposure axis OK'
