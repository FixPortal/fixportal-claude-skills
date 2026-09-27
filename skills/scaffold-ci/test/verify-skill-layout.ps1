$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$main = Get-Content (Join-Path $root 'SKILL.md') -Raw
$ci = Get-Content (Join-Path $root 'references' 'ci-workflow.md') -Raw
$mutation = Get-Content (Join-Path $root 'references' 'mutation.md') -Raw
$all = @(
    $main
    Get-ChildItem (Join-Path $root 'references') -Filter '*.md' | ForEach-Object { Get-Content $_.FullName -Raw }
) -join "`n"
$gate = Get-Content (Join-Path $root 'assets' 'assert_gate_coverage.py') -Raw

$words = ([regex]::Matches($main, '\b[\p{L}\p{N}][\p{L}\p{N}''.-]*\b')).Count
if ($words -gt 500) { throw "SKILL.md is $words words; detailed contracts belong in references" }

foreach ($name in 'ci-workflow.md','mutation.md','dependencies-and-security.md','review-policy.md','common-mistakes.md') {
    if (-not (Test-Path (Join-Path $root "references" "$name"))) { throw "missing reference: $name" }
}

if ($all -match '(?i)actionlint is the first validation step of every job') { throw 'actionlint still claims gate-control jobs' }
foreach ($needle in 'substantive build, test, publish', 'gate-control jobs', 'weekly UTC schedule') {
    if ($all -notmatch [regex]::Escape($needle)) { throw "missing contract: $needle" }
}

foreach ($needle in 'timeout-minutes: 10', '--blame-hang-timeout 30s', '--blame-hang-dump-type none', '15 aggregate runner-minutes', 'timeout-minutes: 45') {
    if ($ci -notmatch [regex]::Escape($needle)) { throw "missing CI cost contract: $needle" }
}
if ($mutation -notmatch 'timeout-minutes: 30') { throw 'mutation jobs are not capped at 30 minutes' }
if ($ci -notmatch '(?is)end-to-end.*stress.*load.*soak') { throw 'extended test kinds are not routed out of PR CI' }
if ($ci -notmatch '(?is)workflow_dispatch.*schedule:') { throw 'extended tests are not both manually runnable and weekly' }
if ($ci -notmatch '(?i)never (?:a )?required PR gate') { throw 'extended tests can still become a hidden PR gate' }
if ($ci -notmatch '(?i)compatibility matrices.*weekly') { throw 'broad compatibility fan-out is still allowed on every PR' }
if ($ci -notmatch '(?i)never retry|not retry') { throw 'timeout retries can still hide budget failures' }

if ($gate -match '(?m)^\s*import yaml\b|PyYAML ships') { throw 'gate coverage still depends on undeclared PyYAML' }

"scaffold-ci layout OK — $words words; focused references and stdlib gate present"
