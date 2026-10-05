$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$main = Get-Content (Join-Path $root 'SKILL.md') -Raw
$runbook = Get-Content (Join-Path $root 'references' 'runbook.md') -Raw
$text = $main + "`n" + $runbook

# collect.ps1 emits sinceReviewFiles as an INTEGER file count parsed from
# `git diff --shortstat` (collect.ps1 ~L335, initialised 0 at ~L447). No field in the
# JSON exposes changed file NAMES, so a docs-only test cannot read one off it.
if ($text -match 'sinceReviewFiles`?\s*contains') {
    throw "SKILL.md treats sinceReviewFiles as a file list; collect.ps1 emits an integer count"
}

# The triage fields are nested under a per-repo `.git` object, not top level.
foreach ($needle in 'reviewCoverage[].changedFiles',
                    '.git.sinceReviewCount',
                    'file count, not a list',
                    'UNKNOWN', 'STOP', 'unresolved', 'outsideScanPath',
                    'isDocumentReview', 'resolvedPath', 'exactly one admissible row') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md missing corrected triage guidance: $needle"
    }
}

$triageTable = [regex]::Match($runbook, '(?s)\| Evidence \| Class \| Action \|.*?(?=\r?\n\r?\n`sinceReviewFiles`)')
if (-not $triageTable.Success) { throw 'Triage decision table is missing.' }

# Each literal case is anchored to one decision-table row. Restoring an unconditional
# hasTrackedSource=false shortcut, or mapping an unknown scope to skip, must fail.
$triageCases = @(
    @{ Name = 'reviewed drift'; Pattern = '(?m)^\| `hasTrackedSource = true`; `effectiveNeverReviewed = false`; any group has changed files \| drift \| Review each changed `reviewCoverage` group under that group''s boundary and paths \|$' },
    @{ Name = 'new source'; Pattern = '(?m)^\| `hasTrackedSource = true`; `queue = new-source` \| new source \| Review the emitted `newSource` paths; do not use the newest scope''s boundary for these files \|$' },
    @{ Name = 'true never-reviewed code'; Pattern = '(?m)^\| `hasTrackedSource=true`; `effectiveNeverReviewed=true` \| audit \| Audit only the approved `subsystemPaths` pathspecs \|$' },
    @{ Name = 'validated empty subsystem'; Pattern = '(?m)^\| `scopeValidation = valid`; `hasTrackedSource = false` \| skip/void \| Record the validated scope as not code-reviewable; do not audit \|$' },
    @{ Name = 'invalid subsystem'; Pattern = '(?m)^\| `scopeValidation = invalid` \| UNKNOWN \| STOP before approval; report the invalid declared subsystem paths \|$' },
    @{ Name = 'missing or unrecognized validation'; Pattern = '(?m)^\| `scopeValidation` missing or unrecognized \| UNKNOWN \| STOP before approval \|$' },
    @{ Name = 'unknown source evidence'; Pattern = '(?m)^\| usable scope state; `hasTrackedSource` missing or null \| UNKNOWN \| STOP before approval \|$' }
)
foreach ($case in $triageCases) {
    if ($triageTable.Value -notmatch $case.Pattern) {
        throw "Triage case '$($case.Name)' is missing or mapped to the wrong decision."
    }
}

$forbiddenTriageRows = @(
    '(?m)^\|.*scopeValidation = invalid.*\|\s*(?:skip/void|skip)\s*\|',
    '(?m)^\|.*scopeValidation.*(?:missing|unrecognized).*\|\s*(?:skip/void|skip)\s*\|',
    '(?m)^\|\s*`hasTrackedSource = false`\s*\|\s*skip/void\s*\|'
)
foreach ($pattern in $forbiddenTriageRows) {
    if ($triageTable.Value -match $pattern) {
        throw 'Unknown or unvalidated scope evidence must never map to skip/void.'
    }
}
if ($main -match '(?m)^\s*`hasTrackedSource=false` is skip/void') {
    throw 'SKILL.md restored the unconditional hasTrackedSource=false shortcut.'
}

foreach ($needle in '`effectiveNeverReviewed` is authoritative', 'Do not use `.git.neverReviewed`') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "Triage contract missing prose-only marker guidance: $needle"
    }
}

foreach ($needle in 'effectiveNeverReviewed', 'hasTrackedSource=false', 'unknown is STOP') {
    if ($main -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md must surface the collector triage contract: $needle"
    }
}

foreach ($needle in 'scopeValidation=invalid', 'UNKNOWN + STOP', 'validated scope') {
    if ($main -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md must surface the validated-scope triage contract: $needle"
    }
}

# Discovery either states the finite exclusions it applies or makes none. An undefined
# exclusion promise silently changes which repositories spend reviewer budget.
if ($text -match 'applying exact\s+leaf-name exclusions') {
    throw 'Discovery promises leaf-name exclusions without defining the finite list.'
}

'review-sweep triage fields OK'
