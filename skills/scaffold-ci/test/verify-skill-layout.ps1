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

# Usage form: the YAML step block with its run: line, Format ahead of Lint (cheapest first).
# Anchored at the Node job's own `npm ci` step and barred from crossing a job header, so a
# Lint pair in another job cannot satisfy it.
if ($ci -notmatch '(?s)run: npm ci\r?\n(?:[ \t]*#[^\r\n]*\r?\n)*[ \t]*- name: Format \(read-only\)\r?\n\s+run: npm run format\r?\n(?:(?!\r?\n  [A-Za-z0-9_-]+:[ \t]*\r?\n).)*?- name: Lint\r?\n\s+run: npm run lint') { throw 'Node job must run "npm run format" in a Format (read-only) step before the Lint step' }

# `npm run format` is read-only only while the repo's script is `prettier --check .`; the
# common-mistakes row must say to confirm it (R-C CX13).
$prettierRow = @($all -split '\r?\n' | Where-Object { $_ -match '^\| Node job has no read-only Prettier gate' })
if ($prettierRow.Count -ne 1 -or $prettierRow[0] -notmatch '(?i)confirm[^|]*`format` script is exactly `prettier --check \.`') {
    throw 'the Prettier common-mistakes row must tell the reader to confirm the format script is prettier --check .'
}

# The checker reads workflow structure through PyYAML, like assert_workflow_hygiene.py, so the
# dependency must be declared where the skill describes the job, and a missing PyYAML must fail
# loudly instead of falling back to a weaker line scan.
if ($main -match 'stdlib-only' -or $main -notmatch '`Gate coverage` runs the shipped asset on system `python3` with PyYAML') {
    throw 'scaffold-ci SKILL.md must declare that Gate coverage needs PyYAML on system python3'
}
if ($gate -match '(?m)^\s*import yaml\b' -and $gate -notmatch 'python3 cannot import yaml') {
    throw 'gate coverage imports PyYAML but no longer fails loudly when it is missing'
}

"scaffold-ci layout OK — $words words; focused references and declared gate dependency present"
