$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$main = Get-Content (Join-Path $root 'SKILL.md') -Raw
$runbook = Get-Content (Join-Path $root 'references' 'runbook.md') -Raw
$text = $main + "`n" + $runbook

# collect.ps1 emits git.sinceReviewFiles as an INTEGER file count. The changed file NAMES
# are in each reviewCoverage[].changedFiles list and in newSource, never in that count.
if ($text -match 'sinceReviewFiles`?\s*contains') {
    throw "SKILL.md treats sinceReviewFiles as a file list; collect.ps1 emits an integer count"
}

# The triage fields are nested under a per-repo `.git` object, not top level.
foreach ($needle in 'reviewCoverage[].changedFiles',
                    '.git.sinceReviewCount',
                    'file count, not a list',
                    'UNKNOWN', 'STOP', 'unresolved', 'outsideScanPath',
                    'isDocumentReview', 'resolvedPath', 'exactly one admissible row',
                    'openReviewCount', 'oldestOpenReviewAgeDays', 'hasCoveredSource') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md missing corrected triage guidance: $needle"
    }
}

$triageTable = [regex]::Match($runbook, '(?s)\| Evidence \| Class \| Action \|.*?(?=\r?\n\r?\n`sinceReviewFiles`)')
if (-not $triageTable.Success) { throw 'Triage decision table is missing.' }

# Each literal case is anchored to one decision-table row. Restoring an unconditional
# hasTrackedSource=false shortcut, or mapping an unknown scope to skip, must fail.
$triageCases = @(
    @{ Name = 'reviewed drift'; Pattern = '(?m)^\| `hasTrackedSource = true`; `effectiveNeverReviewed = false`; any group has changed files \| drift \| Review each changed `reviewCoverage` group under that group''s boundary and changed files \|$' },
    @{ Name = 'new source'; Pattern = '(?m)^\| `hasTrackedSource = true`; `queue = new-source` \| new source \| Review the emitted `newSource` paths; do not use the newest scope''s boundary for these files \|$' },
    @{ Name = 'true never-reviewed code'; Pattern = '(?m)^\| `hasTrackedSource=true`; `effectiveNeverReviewed=true` \| audit \| Audit only the approved `subsystemPaths` pathspecs \|$' },
    @{ Name = 'validated empty subsystem'; Pattern = '(?m)^\| `scopeValidation = valid`; `hasTrackedSource = false`; `hasCoveredSource = false` \| skip/void \| Record the validated scope as not code-reviewable; do not audit \|$' },
    @{ Name = 'whole repo with no source'; Pattern = '(?m)^\| `scopeValidation = none`; `hasTrackedSource = false`; `hasCoveredSource = false` \| skip/void \| Record the whole repo as not code-reviewable; do not audit \|$' },
    @{ Name = 'deleted reviewed source'; Pattern = '(?m)^\| `hasTrackedSource = false`; `hasCoveredSource = true`; any group has changed files \| drift \| Review each changed `reviewCoverage` group under that group''s boundary and changed files; the deleted source is the change \|$' },
    @{ Name = 'exempt'; Pattern = '(?m)^\| `queue = exempt` \| skip \| Record the repo as exempt with its `exemptReason`; do not audit or review it \|$' },
    @{ Name = 'all groups unchanged'; Pattern = '(?m)^\| `hasTrackedSource = true`; `effectiveNeverReviewed = false`; all groups unchanged \| skip \| Record unchanged \|$' },
    @{ Name = 'open review'; Pattern = '(?m)^\| `openReviewCount > 0` \| open review \| Report the count and `oldestOpenReviewAgeDays` separately; report-only, no invocation; do not count it as file drift \|$' },
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

$execute = [regex]::Match($runbook, '(?s)## Execute and consolidate.*').Value
$skipRule = [regex]::Match($runbook, '(?s)\*\*Docs/assets/brand-only drift becomes skip\*\*.*?(?=\r?\n## )').Value
$runbookCases = @(
    # R06: drift runs per changed group, never on the row's newest boundary and scope.
    @{ Name = 'R06 drift per group'; Text = $execute; Pattern = '`<group\.boundarySha>\.\.HEAD -- <group\.changedFiles>`' },
    @{ Name = 'R06 subsystemPaths audit-only'; Text = $runbook; Pattern = 'For the \*\*audit\*\* row only' },
    # R30: new source has its own invocation.
    @{ Name = 'R30 new-source invocation'; Text = $execute; Pattern = '- new source: `audit -- <newSource paths>`' },
    # R31: the docs-only test names the list it runs on.
    @{ Name = 'R31 file list source'; Text = $skipRule; Pattern = 'union of\s+every changed group''s `reviewCoverage\[\]\.changedFiles` plus `newSource`' },
    # R07: instruction Markdown is reviewable.
    @{ Name = 'R07 instruction Markdown'; Text = $skipRule; Pattern = '`SKILL\.md`, agent-instruction files' },
    @{ Name = 'R07 mdx'; Text = $skipRule; Pattern = 'every `\*\.mdx`' },
    @{ Name = 'R07 references'; Text = $skipRule; Pattern = 'under\s+a `references/` folder' },
    # R15: docs/ exempts nothing by location; scripts there are code.
    # A .txt that changes what runs (dependency or build manifest) is not a document.
    @{ Name = 'txt manifests reviewable'; Text = $skipRule; Pattern = 'except build and dependency\s+manifests \(`requirements\*\.txt`, `constraints\*\.txt`, `CMakeLists\.txt`\)' },
    @{ Name = 'R15 docs location'; Text = $skipRule; Pattern = 'a `docs/` location\s+exempts nothing' },
    @{ Name = 'R15 docs scripts'; Text = $skipRule; Pattern = 'any script under `docs/`' },
    # CX11: an SVG is skipped only after its content is read.
    @{ Name = 'CX11 svg read'; Text = $skipRule; Pattern = 'an SVG you have not read is\s+reviewable' }
)
foreach ($case in $runbookCases) {
    if ($case.Text -notmatch $case.Pattern) { throw "Runbook missing '$($case.Name)'." }
}
# R07/R15: the old blanket exemptions must not return.
if ($skipRule -match '\(`\*\.md`, `\*\.mdx`' -or $skipRule -match 'anything under `docs/`') {
    throw 'Docs-only skip restored an extension-only Markdown or whole-docs/ exemption.'
}
if ($execute -match '- drift: `<boundarySha>\.\.HEAD') { throw 'Execute restored the row-boundary drift recipe (R06).' }

# Discovery either states the finite exclusions it applies or makes none. An undefined
# exclusion promise silently changes which repositories spend reviewer budget.
if ($text -match 'applying exact\s+leaf-name exclusions') {
    throw 'Discovery promises leaf-name exclusions without defining the finite list.'
}

'review-sweep triage fields OK'
