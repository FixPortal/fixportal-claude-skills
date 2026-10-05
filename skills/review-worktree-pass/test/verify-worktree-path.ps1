$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$text = Get-Content (Join-Path $PSScriptRoot '..' 'SKILL.md') -Raw

# ~/.codex/AGENTS.md and ~/.kimi-code/AGENTS.md both state the worktree directory
# "is `.claude` regardless of which agent you are, and is not a Codex config path".
# A per-runtime example splits what is meant to be one shared worktree per project.
foreach ($pattern in '\.Codex\\+worktrees', 'under the running runtime''s') {
    if ($text -match $pattern) {
        throw "SKILL.md contradicts the AGENTS.md worktree-path correction: $pattern"
    }
}

foreach ($needle in 'regardless of which agent', '.claude\worktrees\reviewer-passes') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md missing the corrected worktree-path rule: $needle"
    }
}

# A third superseded pattern, naming a private project code, is omitted from this
# public mirror; the two below carry the same regression contract.
foreach ($pattern in 'remote branch gone \+ matching commit titles,\s*or an empty', 'Covers which checkout') {
    if ($text -match $pattern) { throw "SKILL.md retains a superseded worktree contract: $pattern" }
}

foreach ($needle in 'both', 'remote branch is gone', 'commit titles match', 'supplemental evidence', 'outside the review worktree') {
    if ($text -notmatch [regex]::Escape($needle)) { throw "SKILL.md missing safe teardown contract: $needle" }
}

if ($text -notmatch '(?m)^description:.*selecting or implementing remediation actions') {
    throw 'SKILL.md selector must target remediation actions'
}

if ($text -notmatch '(?m)^description:.*Do not use for read-only review, review-digest, or audit requests') {
    throw 'SKILL.md selector must exclude read-only review, digest, and audit requests'
}

$normalized = $text -replace '\s+', ' '
foreach ($needle in 'origin/HEAD',
                     'git symbolic-ref --quiet --short refs/remotes/origin/HEAD',
                     'git ls-remote --symref origin HEAD',
                     'git rev-parse --verify',
                     '<mainline-ref>') {
    if ($normalized -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md missing default-branch resolution contract: $needle"
    }
}
if ($text -match 'origin/main') {
    throw 'SKILL.md must not hard-code origin/main as the project mainline'
}
if ($text -notmatch '(?is)closed, unmerged PR.*?stop before batch selection.*?resume the branch.*?abandon the pass') {
    throw 'A closed, unmerged review PR must stop before batch selection and require an explicit resume or abandon choice.'
}

foreach ($needle in 'disposition: remediated', 'remediation-tip:', 'validate-report.ps1', '-RepoPath') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md does not close the machine-readable review artefact after remediation: $needle"
    }
}
if ($text -notmatch '(?is)only after.*all.*findings.*fixed.*declined.*deferred') {
    throw 'Review artefact must close only after every finding has a recorded disposition.'
}

$fetch = $normalized.IndexOf('`git fetch --prune`', [System.StringComparison]::Ordinal)
$resolve = $normalized.IndexOf('origin/HEAD', [System.StringComparison]::Ordinal)
$batch = $normalized.IndexOf('select the next batch number', [System.StringComparison]::Ordinal)
if ($fetch -lt 0 -or $resolve -lt 0 -or $batch -lt 0 -or $fetch -gt $resolve -or $resolve -gt $batch) {
    throw 'SKILL.md must fetch and resolve the verified mainline before batch selection'
}

$absentWorktree = [regex]::Match($normalized, 'If the review worktree is absent.*?verified primary checkout.*?`git fetch --prune`.*?origin/HEAD.*?select the next batch number.*?`git worktree add`.*?<mainline-ref>')
if (-not $absentWorktree.Success) {
    throw 'SKILL.md must recreate an absent review worktree from the refreshed, verified remote mainline'
}

$existingWorktree = [regex]::Match($normalized, 'If the review worktree already exists.*?`git fetch --prune`.*?before any new branch choice')
if (-not $existingWorktree.Success) {
    throw 'SKILL.md must fetch inside an existing review worktree before branch selection'
}

# Exercise both origin/HEAD and the advertised-HEAD fallback against a repository whose
# default branch is deliberately not main.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "review-worktree-$([guid]::NewGuid())"
try {
    $source = Join-Path $fixtureRoot 'source'
    $remote = Join-Path $fixtureRoot 'remote.git'
    $clone = Join-Path $fixtureRoot 'clone'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    git -C $source init --initial-branch=trunk --quiet
    git -C $source config core.autocrlf false
    git -C $source config core.safecrlf false
    [IO.File]::WriteAllText((Join-Path $source 'README.md'), "fixture`n")
    git -C $source add README.md
    git -C $source -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
    git -c core.autocrlf=false clone --quiet --bare $source $remote
    git -c core.autocrlf=false clone --quiet $remote $clone

    $mainline = (git -C $clone symbolic-ref --quiet --short refs/remotes/origin/HEAD).Trim()
    if ($mainline -cne 'origin/trunk') { throw "origin/HEAD resolved '$mainline', expected origin/trunk" }
    git -C $clone rev-parse --verify --quiet "$mainline^{commit}" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Resolved origin/HEAD does not name a fetched commit' }

    git -C $clone symbolic-ref --delete refs/remotes/origin/HEAD
    $advertised = git -C $clone ls-remote --symref origin HEAD
    $match = [regex]::Match(($advertised -join "`n"), '(?m)^ref:\s+refs/heads/(?<branch>\S+)\s+HEAD$')
    if (-not $match.Success) { throw 'Fallback could not resolve the remote advertised HEAD' }
    $mainline = "origin/$($match.Groups['branch'].Value)"
    git -C $clone rev-parse --verify --quiet "$mainline^{commit}" | Out-Null
    if ($LASTEXITCODE -ne 0 -or $mainline -cne 'origin/trunk') {
        throw 'Advertised-HEAD fallback did not resolve and verify origin/trunk'
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

'review-worktree-pass worktree path OK'
