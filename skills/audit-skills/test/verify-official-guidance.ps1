$ErrorActionPreference = 'Stop'

# The rubric is graded against the official skill guidance (snapshotted under
# assets/guidance/), not against superpowers' writing-skills. Until 2026-10-03 the brief
# required every description to start "Use when" and capped the whole frontmatter at 1024
# characters - both writing-skills rules that the official pages do not state. This
# replaces verify-trigger-form.ps1, which pinned that prefix on five skills.

function Get-BriefViolations([string] $brief) {
    $violations = @()
    # Usage forms, not mentions: the brief may say "Use when" is allowed.
    $forbidden = [ordered]@{
        '(?i)starts with\s+"Use when'                  = 'requires the "Use when" prefix'
        '(?i)against\s+`writing-skills`'               = 'grades against writing-skills instead of the official guidance'
        '(?i)Frontmatter\s*≤\s*1024\s*chars\s*total'    = 'caps the whole frontmatter at 1024 characters'
        '(?im)^-\s*(?:\*\*)?Polish(?:\*\*)?.*missing section' = 'counts a missing section as a finding (the spec sets no format restrictions)'
    }
    foreach ($pattern in $forbidden.Keys) {
        if ($brief -match $pattern) { $violations += $forbidden[$pattern] }
    }
    # The brief is hard-wrapped, so every multi-word needle allows a line break.
    $required = [ordered]@{
        '(?is)`description`.{0,80}1024'                        = 'description limit of 1024 characters'
        '(?i)1536'                                             = 'Claude Code listing cap of 1536 characters (description + when_to_use)'
        '(?i)without\s+summari[sz]ing\s+the\s+workflow'        = 'no workflow summary in the description'
        '(?i)one\s+level\s+deep'                               = 'references one level deep from SKILL.md'
        '(?is)over\s+100\s+lines.{0,80}contents'               = 'contents list on reference files over 100 lines'
        '(?i)500\s+lines'                                      = 'SKILL.md body under 500 lines'
        '(?i)5,?000\s+tokens'                                  = 'critical rules inside the first 5,000 tokens kept after compaction'
        '(?is)owner:\s+<your-org>.{0,200}local\s+exception'    = 'owner: <your-org> recorded as the intended local exception'
        'assets/guidance/'                             = 'rules cite the committed guidance snapshot'
        '(?m)^## Contents'                             = 'the brief carries its own contents list'
    }
    foreach ($pattern in $required.Keys) {
        if ($brief -notmatch $pattern) { $violations += "missing: $($required[$pattern])" }
    }
    # Plain return; every caller wraps in @() (see powershell-traps, empty-collection entry).
    return $violations
}

$root = Split-Path -Parent $PSScriptRoot
$brief = Get-Content -Raw -LiteralPath (Join-Path $root 'audit-brief.md')
$skill = Get-Content -Raw -LiteralPath (Join-Path $root 'SKILL.md')

$violations = @(Get-BriefViolations $brief)
if ($violations.Count) { throw "audit-brief.md: $($violations -join '; ')" }

foreach ($needle in 'guidance_drift.py', 'guidance-drift.json', 'suspended_axes', 'guidance: ') {
    if ($skill -notmatch [regex]::Escape($needle)) { throw "SKILL.md Phase 0 is missing the guidance check: $needle" }
}

# RED CHECK: the brief as it stood before this change must fail on every retired rule.
$retired = @'
Grade the frontmatter `description` against `writing-skills` CSO rules:
- Third person; starts with "Use when…"; concrete triggers/symptoms/keywords.
- `name`: letters/numbers/hyphens only. Frontmatter ≤ 1024 chars total.
- **Polish** — bloat, missing section, weak example.
'@
$caught = @(Get-BriefViolations $retired)
foreach ($expected in 'requires the "Use when" prefix', 'grades against writing-skills', 'caps the whole frontmatter', 'counts a missing section') {
    if (-not @($caught | Where-Object { $_ -like "$expected*" }).Count) {
        throw "red check: the retired rule '$expected' was not detected"
    }
}

# A brief that only MENTIONS the prefix as allowed must pass that check.
if (@(Get-BriefViolations 'A description may begin "Use when"; nothing requires it.' | Where-Object { $_ -like 'requires*' }).Count) {
    throw 'red check: a mention of "Use when" was read as a requirement'
}

Write-Host 'official guidance rubric OK'
