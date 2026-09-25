$ErrorActionPreference = 'Stop'

# Pins the four secret-scanning decisions most likely to be softened later by someone
# with a green build and a deadline. Every assertion runs through Test-Contract so the
# red checks at the bottom exercise the same code path as the real run: a contract test
# that cannot be shown to fail is decorative.

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$text = Get-Content (Join-Path $root 'references' 'dependencies-and-security.md') -Raw

# The asset is the file repos actually copy, so it is asserted directly rather than
# trusted to match the prose describing it. Declared at script scope, which Test-Contract
# reads the same way it reads $stale and $required.
$sweepPath = Join-Path $root 'assets' 'secret-sweep.yml'
if (-not (Test-Path $sweepPath)) { throw 'missing shipped asset: assets/secret-sweep.yml' }
$sweep = Get-Content $sweepPath -Raw
$detectorAllowlist = 'AWS,AWSSessionKey,Azure,AzureStorage,AzureSQL,AzureSasToken,AzureActiveDirectoryApplicationSecret,AzureContainerRegistry,AzureOpenAI,Github,GitHubApp,GitHubOauth2,OpenAI,Anthropic,NpmToken,Postgres,Dockerhub'

# Each guard matches the USAGE form, never a bare mention. The reference deliberately
# names `gitleaks/gitleaks-action` and `GITLEAKS_LICENSE` in order to forbid them, so an
# unanchored guard would fail on the document's own prohibition. That exact mistake was
# made in scaffold-python's contract test and caught only by running it.
$stale = @{
    'wires gitleaks-action into a workflow'  = '(?m)uses:\s*gitleaks/gitleaks-action'
    'introduces a GITLEAKS_LICENSE secret'   = 'secrets\.GITLEAKS_LICENSE'
    'softens the gate to advisory'           = 'gate[^\r\n.]{0,40}(advisory|non-blocking|does not fail|warn only)'
    'reports unverified trufflehog findings' = '--results=all|--no-verification'
    # Verifying against the release's own checksums file is the OLD shape: a replaced
    # release could swap archive and checksums together. Anchored to the curl usage
    # line so the prose prohibition does not trip it.
    'downloads the release checksums file'   = '(?m)^\s+curl[^\r\n]*checksums'
}

$required = @(
    'gitleaks'
    'trufflehog'
    '--results=verified'
    '\.gitleaksignore'
    '--log-opts'
    'GITLEAKS_SHA256: 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'
    'private repositories only'
    'The gate blocks'
    'staggered weekly UTC schedule'
    # The range scan resolves base.sha, which a default shallow checkout does not
    # contain. Without this the gate passes by scanning nothing, which is worse than
    # having no gate at all. Raised by Gitar on PR #45.
    #
    # Anchored to the indented YAML line, not any mention: the surrounding prose also
    # says `fetch-depth: 0`, and an unanchored form was satisfied by that prose even
    # after the actual snippet line was deleted. Its red check caught it.
    '(?m)^\s+fetch-depth: 0'
)

function Test-Contract {
    param(
        [string]$Text,
        [string]$SweepText
    )

    $problems = @()

    foreach ($entry in $stale.GetEnumerator()) {
        if ($Text -match $entry.Value) { $problems += "secret scanning $($entry.Key)" }
    }

    foreach ($needle in $required) {
        if ($Text -notmatch $needle) { $problems += "secret scanning missing contract term: $needle" }
    }

    # Structural: the blocking claim must stand as its own sentence, not be inferable
    # from surrounding prose that a later edit could soften without tripping a substring.
    if ($Text -notmatch '(?m)\*\*The gate blocks\.\*\*') {
        $problems += 'secret scanning does not state the gate blocks as its own claim'
    }

    if ($SweepText -notmatch '--results=verified') {
        $problems += 'secret-sweep.yml does not restrict trufflehog to verified results'
    }
    if ($SweepText -notmatch '(?m)^\s+version: 3\.96\.0@sha256:aa821cf4ace8861c7d096d83818cdf7bb9719028a52d37a52eaad44086a52577$') {
        $problems += 'secret-sweep.yml does not pin the trufflehog scanner image to 3.96.0 by digest'
    }
    if ($SweepText -match '(?m)^\s+version: 3\.96\.0$') {
        $problems += 'secret-sweep.yml pins the trufflehog scanner by bare tag, not digest - a re-pushed tag would change the scanner without a commit'
    }
    if ($SweepText -match '(?m)uses:\s*trufflesecurity/trufflehog@(main|master|v[\d.]+)\s*$') {
        $problems += 'secret-sweep.yml pins trufflehog by tag or branch rather than commit SHA'
    }
    if ($SweepText -notmatch '(?m)^\s*schedule:') {
        $problems += 'secret-sweep.yml has no weekly schedule - a sweep nobody triggers is not a control'
    }
    if ($SweepText -notmatch "(?m)^\s+--include-detectors=$([regex]::Escape($detectorAllowlist))$") {
        $problems += 'secret-sweep.yml does not use the reviewed detector allowlist'
    }

    foreach ($installTerm in @(
        '(?m)^\s+GITLEAKS_VERSION: 8\.30\.1$'
        '(?m)^\s+GITLEAKS_SHA256: 551f6fc8[0-9a-f]+$'
        '(?m)^\s+archive="gitleaks_\$\{GITLEAKS_VERSION\}_linux_x64\.tar\.gz"$'
        'releases/download/v\$\{GITLEAKS_VERSION\}/\$\{archive\}'
        'echo "\$\{GITLEAKS_SHA256\}  \$\{archive\}" \| sha256sum --check --strict'
        'tar --extract --gzip --file "\$\{archive\}" gitleaks'
        'install -m 0755 gitleaks "\$RUNNER_TEMP/gitleaks"'
        '"\$RUNNER_TEMP/gitleaks" git -v --redact --log-opts='
    )) {
        if ($Text -notmatch $installTerm) {
            $problems += "private gitleaks job missing executable install term: $installTerm"
        }
    }

    return $problems
}

$problems = Test-Contract -Text $text -SweepText $sweep

# The INSTALLED workflow, not only the asset it was copied from. This repository's own
# copy shipped the bare `version: 3.96.0` tag directly beneath the comment explaining why
# an unpinned scanner is unacceptable, and had drifted on the detector list too - while
# this test read the asset and nothing else, so both differences were invisible. The copy
# that actually runs is the one that decides what counts as a live credential.
#
# Field-level, not byte-level: the asset's own header forbids copying its cron value
# across the estate, so a repository-specific schedule and header are correct differences.
# The scanner pin, detector allowlist, verified-results restriction and action SHA are not.
# This mirror nests the skill under skills/, so the repository root is two levels up.
$repoRoot = Split-Path (Split-Path $root -Parent) -Parent
$installedSweepPath = Join-Path $repoRoot '.github' 'workflows' 'secret-sweep.yml'
if (Test-Path -LiteralPath $installedSweepPath) {
    $installed = (Get-Content -LiteralPath $installedSweepPath -Raw) -replace "`r`n", "`n"
    foreach ($installedProblem in (Test-Contract -Text $text -SweepText $installed)) {
        if ($installedProblem -notin $problems) { $problems += "installed workflow: $installedProblem" }
    }
}

if ($problems.Count -gt 0) { throw ($problems -join "`n") }

# --- red checks: prove each assertion family can actually fail --------------------
# Mutations APPEND rather than -replace: the .NET replacement string treats ${name} as a
# group reference, so a `${{ secrets.X }}` payload cannot go through -replace safely.
$redChecks = @{
    'a wired-in gitleaks-action'   = { param($t) $t + [Environment]::NewLine + '      uses: gitleaks/gitleaks-action@v2' }
    'a GITLEAKS_LICENSE secret'    = { param($t) $t + [Environment]::NewLine + 'GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}' }
    'an advisory gate'             = { param($t) $t -replace '\*\*The gate blocks\.\*\*', 'The gate is advisory.' }
    'unverified sweep results'     = { param($t) $t -replace '--results=verified', '--results=all' }
    'a dropped baseline mechanism' = { param($t) $t -replace '\.gitleaksignore', '.secretsignore' }
    'a shallow gate checkout'      = { param($t) $t -replace '(?m)^\s*fetch-depth: 0\r?\n', '' }
}

foreach ($check in $redChecks.GetEnumerator()) {
    $mutated = & $check.Value $text
    if ($mutated -eq $text) {
        throw "red check '$($check.Key)' did not modify the document - the mutation no longer matches"
    }
    if ((Test-Contract -Text $mutated -SweepText $sweep).Count -eq 0) {
        throw "red check failed: $($check.Key) was accepted by the contract"
    }
}

# The shipped asset gets its own red checks. Three assertions were added for it above,
# and an assertion nobody has watched fail is exactly the decorative kind this file
# exists to avoid.
$sweepRedChecks = @{
    'a sweep reporting every result' = { param($s) $s -replace '--results=verified', '--results=all' }
    'an unpinned scanner image'       = { param($s) $s -replace '(?m)^\s+version: 3\.96\.0@sha256:[0-9a-f]{64}$', '          version: 3.96.0' }
    'a branch-pinned action'         = { param($s) $s -replace 'trufflesecurity/trufflehog@\w+ # v[\d.]+', 'trufflesecurity/trufflehog@main' }
    'a sweep with no schedule'       = { param($s) $s -replace '(?m)^\s*schedule:.*\r?\n\s*- cron:.*\r?\n', '' }
    'an unconstrained detector set'  = { param($s) $s -replace '(?m)^\s*--include-detectors=.*\r?\n?', '' }
}

foreach ($check in $sweepRedChecks.GetEnumerator()) {
    $mutated = & $check.Value $sweep
    if ($mutated -eq $sweep) {
        throw "sweep red check '$($check.Key)' did not modify the asset - the mutation no longer matches"
    }
    if ((Test-Contract -Text $text -SweepText $mutated).Count -eq 0) {
        throw "sweep red check failed: $($check.Key) was accepted by the contract"
    }
}

$installMutations = @(
    @{ Name = 'an incomplete gitleaks install'; From = 'sha256sum --check --strict'; To = 'sha256sum --version' },
    @{ Name = 'the wrong gitleaks platform'; From = 'archive="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"'; To = 'archive="gitleaks_${GITLEAKS_VERSION}_linux_arm64.tar.gz"' },
    @{ Name = 'a swapped gitleaks hash'; From = '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'; To = 'aaaaaaaa7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080' },
    @{ Name = 'a non-redacted gitleaks scan'; From = '"$RUNNER_TEMP/gitleaks" git -v --redact '; To = '"$RUNNER_TEMP/gitleaks" git -v ' }
)

foreach ($mutation in $installMutations) {
    $mutated = $text.Replace($mutation.From, $mutation.To)
    if ($mutated -eq $text) {
        throw "red check '$($mutation.Name)' did not modify the document"
    }
    if ((Test-Contract -Text $mutated -SweepText $sweep).Count -eq 0) {
        throw "red check failed: $($mutation.Name) was accepted by the contract"
    }
}

'scaffold-ci secret scanning contract OK'
