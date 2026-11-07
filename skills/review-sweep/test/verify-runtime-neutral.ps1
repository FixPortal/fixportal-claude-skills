$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$main = Get-Content (Join-Path $root 'SKILL.md') -Raw
$text = $main + "`n" + (Get-Content (Join-Path $root 'references' 'runbook.md') -Raw)

foreach ($pattern in '\.claude[\\/]+skills', 'OPENAI_API_KEY', 'gemini --version',
                     'TaskCreate', 'Without Tasks', '`Agent`', 'openai-review\.ps1',
                     'gemini-review\.ps1') {
    if ($text -match $pattern) {
        throw "SKILL.md contains stale host/roster coupling: $pattern"
    }
}

foreach ($needle in 'fallbackWrapper', 'minVendors', 'loaded `adversarial-review` skill directory',
                     'runtime''s durable plan', 'PREFLIGHT_COMMAND:', 'PREFLIGHT_SUCCESS:') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md missing runtime-neutral contract: $needle"
    }
}

$root = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'adversarial-review')
$manifest = Get-Content (Join-Path $root 'reviewers.json') -Raw | ConvertFrom-Json
$wrapperKeys = [System.Collections.Generic.HashSet[string]]::new()
foreach ($reviewer in @($manifest.reviewers | Where-Object enabled)) {
    [void]$wrapperKeys.Add([string]$reviewer.wrapper)
    if ($reviewer.fallbackWrapper) { [void]$wrapperKeys.Add([string]$reviewer.fallbackWrapper) }
}
foreach ($key in $wrapperKeys) {
    $wrapper = Get-Content (Join-Path $root $manifest.wrappers.$key) -Raw
    foreach ($needle in 'PREFLIGHT_COMMAND:', 'PREFLIGHT_SUCCESS:') {
        if ($wrapper -notmatch [regex]::Escape($needle)) {
            throw "Configured wrapper '$key' lacks its documented preflight field: $needle"
        }
    }
}

if ($text -match 'quality-gate-review|Gate verdict') {
    throw 'Review sweep invokes a change-oriented quality gate without gathering its required validation evidence.'
}

$words = ([regex]::Matches($main, '\b[\w/-]+\b')).Count
if ($words -ge 500) { throw "review-sweep/SKILL.md is $words words; keep detail in the runbook" }
foreach ($needle in 'Quick Reference', 'merged mainline', 'one named subsystem',
                     'audit-github-estate') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "review-sweep missing scope/router contract: $needle"
    }
}

"review-sweep runtime-neutral contract OK — $words words"
