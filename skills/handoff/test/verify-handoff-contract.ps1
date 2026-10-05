$ErrorActionPreference = 'Stop'
$skill = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') 'SKILL.md')

$required = @(
    '/handoff kimi',
    '/handoff copilot',
    "git log '@{u}..HEAD' --oneline",
    '`mechanical`',
    '`workhorse`',
    '`frontier`',
    '`estate`',
    '`low`',
    '`medium`',
    '`high`',
    'model-registry/resolve.py --tier',
    'model-routing-traps.md',
    'No repository is in scope',
    'Join-Path',
    '[System.IO.File]::Move',
    'unique per request',
    'is ever overwritten'
)
$forbidden = @(
    '| cheapest |',
    '| mid |',
    '| top |',
    'models_cache.json',
    'grep for `slug`'
)

foreach ($value in $required) {
    if (-not $skill.Contains($value)) { throw "Missing handoff contract: $value" }
}
foreach ($value in $forbidden) {
    if ($skill.Contains($value)) { throw "Stale handoff contract: $value" }
}
if ($skill -match '(?<![\w-])medium-high(?![\w-])') {
    throw 'Invalid handoff reasoning effort: medium-high'
}

$step2Start = $skill.IndexOf('### 2. Gather git state')
$step3Start = $skill.IndexOf('### 3. Establish the task')
if ($step2Start -lt 0 -or $step3Start -le $step2Start) {
    throw 'Handoff procedure is missing ordered steps 2 and 3'
}
$step2 = $skill.Substring($step2Start, $step3Start - $step2Start)
foreach ($value in @(
    'If no repository is in scope',
    'skip Git and PR discovery',
    'Repository: `estate`',
    'Branch: `none`',
    'Worktree: `none`',
    'Working tree: `N/A`',
    'Unpushed commits: `N/A`',
    'Open PR: `N/A`'
)) {
    if (-not $step2.Contains($value)) { throw "Estate handoff branch is missing: $value" }
}

$step6Start = $skill.IndexOf('### 6. Write the brief and hand off')
$ignoredCheckStart = $skill.IndexOf('Briefs are session ephemera', $step6Start)
if ($step6Start -lt 0 -or $ignoredCheckStart -le $step6Start) {
    throw 'Handoff procedure is missing the bounded publication step'
}
$publication = $skill.Substring($step6Start, $ignoredCheckStart - $step6Start)
$lastIndex = -1
foreach ($value in @(
    '$token = [guid]::NewGuid()',
    '$briefFile = Join-Path',
    '$briefTemp = Join-Path',
    'Set-Content -LiteralPath $briefTemp',
    '[System.IO.File]::Move($briefTemp, $briefFile)',
    'File.Move` throw IS the never-overwrite guard'
)) {
    $index = $publication.IndexOf($value)
    if ($index -le $lastIndex) { throw "Handoff publication is missing or out of order: $value" }
    $lastIndex = $index
}
foreach ($value in @(
    'Join-Path $estateHome (Join-Path',
    'Join-Path $repoRoot (Join-Path'
)) {
    if (-not $publication.Contains($value)) { throw "Handoff path join is not PowerShell 5.1 portable: $value" }
}

# A shared output name is the defect this step exists to prevent: several agents work one
# repository at once and cannot see each other, so any fixed-name artefact is last-writer-
# wins over a brief another session was about to resume from. Assert the ABSENCE of the
# pointer, anchored to the write form - a bare 'latest.md' match would be satisfied by the
# prose that forbids it.
foreach ($pattern in @(
    '\$latest\w*\s*=',
    'Destination\s+\$latest',
    '::Replace\(',
    "Set-Content[^\r\n]*'latest\.md'",
    'Join-Path \$handoffRoot ''(latest|current|handoff)\.md'''
)) {
    if ($skill -match $pattern) { throw "Handoff writes a shared fixed-name output: $pattern" }
}

# The string assertions above cannot see a runtime failure, which is how the publication
# block shipped with a call that threw on every second handoff. So run the documented block
# rather than reading it - twice, with the same date and slug, which is the exact shape of
# two agents handing off the same task in the same repository on the same day.
$blockStart = $publication.IndexOf('New-Item -ItemType Directory -Force -Path $handoffRoot')
$blockEnd = $publication.IndexOf('```', $blockStart)
if ($blockStart -lt 0 -or $blockEnd -le $blockStart) {
    throw 'Handoff publication block could not be located for execution'
}
$publicationBlock = [scriptblock]::Create($publication.Substring($blockStart, $blockEnd - $blockStart))

# The name block is executed too, not reconstructed here: a test that computes its own
# filename proves nothing about the one the skill documents.
$nameStart = $publication.IndexOf('$token = [guid]::NewGuid()')
$nameEnd = $publication.IndexOf('```', $nameStart)
if ($nameStart -lt 0 -or $nameEnd -le $nameStart) {
    throw 'Handoff filename block could not be located for execution'
}
$nameBlock = [scriptblock]::Create($publication.Substring($nameStart, $nameEnd - $nameStart))

$handoffRoot = Join-Path ([System.IO.Path]::GetTempPath()) "handoff-contract-$([guid]::NewGuid().ToString('n'))"
try {
    $date = '2026-01-01'
    $slug = 'same-task'

    $brief = "# Handoff: first`n"
    # Dot-sourced, not called: `& $block` runs in a child scope, so the filename the block
    # computes would never reach this scope and the publication would bind $null.
    . $nameBlock
    & $publicationBlock
    $firstBrief = $briefFile
    if (-not (Test-Path -LiteralPath $firstBrief)) { throw 'Handoff publication did not write the first brief' }

    # Second agent, same date, same slug, no knowledge of the first.
    $brief = "# Handoff: second`n"
    . $nameBlock
    & $publicationBlock
    $secondBrief = $briefFile
    if (-not (Test-Path -LiteralPath $secondBrief)) { throw 'Handoff publication did not write the second brief' }

    if ($firstBrief -eq $secondBrief) {
        throw 'Handoff produced the same path for two requests; concurrent agents would overwrite each other'
    }
    if (-not ((Get-Content -Raw -LiteralPath $firstBrief) -match 'first')) {
        throw 'Handoff publication destroyed the first brief'
    }
    if (-not ((Get-Content -Raw -LiteralPath $secondBrief) -match 'second')) {
        throw 'Handoff publication did not write the second brief content'
    }
    if (@(Get-ChildItem -LiteralPath $handoffRoot -Filter '*.md').Count -ne 2) {
        throw 'Handoff publication did not leave both briefs in place'
    }
    if (Get-ChildItem -LiteralPath $handoffRoot -Force -Filter '*.tmp') {
        throw 'Handoff publication left a temporary file behind'
    }
}
finally {
    if (Test-Path -LiteralPath $handoffRoot) { Remove-Item -LiteralPath $handoffRoot -Recurse -Force }
}

'handoff contract OK'
