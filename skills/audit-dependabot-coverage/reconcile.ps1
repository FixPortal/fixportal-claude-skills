<#
.SYNOPSIS
  Reconcile open Dependabot alerts against open Dependabot pull requests.

.DESCRIPTION
  Answers one question per repository: is every open Dependabot alert either being
  fixed by an open Dependabot PR, or old enough that its absence is a finding?

  WHY THIS EXISTS, AND WHY IT IS NOT A CONFIG CHECK. On 2026-08-08 a high-severity
  nanoid advisory opened on <org>/<repo> and no PR was raised for
  four days. Every configuration signal read green throughout: security updates
  enabled and unpaused, the registry token present in the Dependabot secret store,
  and that same directory demonstrably able to do transitive dev-scope lockfile
  bumps. Dependabot had simply reached a WRONG verdict -- it read postcss's
  `nanoid: "^3.3.16"` as a ceiling rather than a floor and declared no fix possible.
  audit-ci already checks the configuration and would have passed the repo.
  So this checks the OUTCOME, which is a different axis. See trap 16 in
  ~/.agents/notes/npm-publishing-traps.md.

  Read-only. Never dismisses an alert, opens a PR, or closes anything.

.PARAMETER Org
  GitHub organisation or user to enumerate. Repeatable.

.PARAMETER Repo
  Explicit owner/repo to check. Repeatable. Skips enumeration when given.

.PARAMETER GraceHours
  An alert younger than this is not reported. Dependabot security updates are meant
  to be immediate, but a scheduled window plus queue time is real, so the default
  allows 48 hours for scheduler and queue delay rather than assuming instant.

.PARAMETER Json
  Emit the findings as JSON instead of a table.
#>
[CmdletBinding()]
param(
    [string[]]$Org = @('YourOrg'),
    [string[]]$Repo,
    [int]$GraceHours = 48,
    [ValidateSet('open', 'fixed', 'dismissed', 'auto_dismissed')]
    [string]$AlertState = 'open',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- the matcher -------------------------------------------------------------
# THE LOAD-BEARING PART, and the failure direction is the whole design.
#
# A too-LOOSE match reports an uncovered alert as covered, which silently
# suppresses exactly the finding this script exists to surface -- the same class of
# bug as the wrong Dependabot verdict that motivated it. A too-STRICT match produces
# a row a human reads and dismisses in seconds. So the anchoring is deliberate and
# unmatched always reports.
#
# Dependabot names the package in the PR body in two shapes, and both must be
# covered because they correspond to the two PR kinds:
#   single-dep: "Bumps [nanoid](https://...) from 3.3.16 to 3.3.18."
#   grouped:    "Updates `@azure/msal-browser` from 5.17.3 to 5.18.0"
# The body identifies packages. The branch contributes ecosystem/directory context;
# a grouped branch carries only a hash where a package name would otherwise appear.
# Compare numeric core and semver prerelease precedence. Build metadata does not affect
# precedence. Anything unparseable returns $false, which reports the alert rather than
# suppressing it -- the safe direction for this tool.
function Test-VersionAtLeast {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Minimum
    )

    function Split-Version([string] $value) {
        $core = ($value -replace '^[=vV^~><\s]+', '').Trim()
        $build = $core -split '\+', 2
        if ($build.Count -gt 1) {
            if (-not $build[1] -or @($build[1] -split '\.' | Where-Object { $_ -notmatch '^[0-9A-Za-z-]+$' }).Count) { return $null }
            $core = $build[0]
        }
        $pre = $null
        if ($core -match '-') {
            $split = $core -split '-', 2
            $core = $split[0]
            $pre = @($split[1] -split '\.')
            if ($pre.Count -eq 0 -or @($pre | Where-Object { $_ -notmatch '^[0-9A-Za-z-]+$' }).Count -gt 0) { return $null }
        }
        $parts = @($core -split '\.' | ForEach-Object {
            if ($_ -match '^\d+$') { [int]$_ } else { $null }
        })
        # COUNTED, not evaluated for truthiness. `$parts | Where-Object { $null -eq $_ }`
        # emits the $null elements themselves, and PowerShell evaluates a one-element
        # array by the truthiness of that element - which is $null, so the condition was
        # always $false and this guard never fired. (powershell-traps.md, the
        # single-element unroll.) The consequence is the silent-suppression direction the
        # comment above promises to avoid: `1.2.3.Final` split to @(1,2,3,$null), the
        # comparison read the missing segment as 0, and a PR bumping to `1.2.3` counted as
        # coverage for an advisory requiring `1.2.3.Final`. (CodeRabbit, PR #135.)
        if ($parts.Count -eq 0 -or @($parts | Where-Object { $null -eq $_ }).Count -gt 0) { return $null }
        [pscustomobject]@{ Parts = $parts; Prerelease = $pre }
    }

    $left = Split-Version $Version
    $right = Split-Version $Minimum
    if ($null -eq $left -or $null -eq $right) { return $false }

    $length = [Math]::Max($left.Parts.Count, $right.Parts.Count)
    for ($i = 0; $i -lt $length; $i++) {
        $l = if ($i -lt $left.Parts.Count) { $left.Parts[$i] } else { 0 }
        $r = if ($i -lt $right.Parts.Count) { $right.Parts[$i] } else { 0 }
        if ($l -gt $r) { return $true }
        if ($l -lt $r) { return $false }
    }
    if ($null -eq $left.Prerelease -and $null -eq $right.Prerelease) { return $true }
    if ($null -eq $left.Prerelease) { return $true }
    if ($null -eq $right.Prerelease) { return $false }
    $preLength = [Math]::Min($left.Prerelease.Count, $right.Prerelease.Count)
    for ($i = 0; $i -lt $preLength; $i++) {
        $l = [string]$left.Prerelease[$i]
        $r = [string]$right.Prerelease[$i]
        $leftNumeric = $l -match '^\d+$'
        $rightNumeric = $r -match '^\d+$'
        if ($leftNumeric -and $rightNumeric) {
            $lNumber = [Numerics.BigInteger]::Parse($l, [Globalization.CultureInfo]::InvariantCulture)
            $rNumber = [Numerics.BigInteger]::Parse($r, [Globalization.CultureInfo]::InvariantCulture)
            if ($lNumber -gt $rNumber) { return $true }
            if ($lNumber -lt $rNumber) { return $false }
        }
        elseif ($leftNumeric -ne $rightNumeric) { return -not $leftNumeric }
        else {
            $comparison = [StringComparer]::Ordinal.Compare($l, $r)
            if ($comparison -gt 0) { return $true }
            if ($comparison -lt 0) { return $false }
        }
    }
    return $left.Prerelease.Count -ge $right.Prerelease.Count
}

function Test-DependabotPrCoversPackage {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PackageName,
        [AllowEmptyString()][string]$HeadRefName = '',
        [AllowEmptyString()][string]$ManifestPath = '',
        [AllowEmptyString()][string]$Ecosystem = '',
        # The version the advisory says fixes it. When supplied, a PR whose stated
        # destination does not reach it is NOT coverage.
        [AllowEmptyString()][string]$FirstPatchedVersion = '',
        [switch]$RequireTargetContext
    )

    if ([string]::IsNullOrWhiteSpace($Body) -or [string]::IsNullOrWhiteSpace($PackageName)) {
        return $false
    }

    $pkg = [regex]::Escape($PackageName.Trim())

    # Anchored on the verb Dependabot actually writes, then the package as a markdown
    # link, backticked, or bare. Requiring the verb is what stops a name mentioned in
    # a changelog excerpt or a release-note block quote from counting as a fix -- those
    # bodies routinely quote dozens of unrelated package names.
    $patterns = @(
        "(?im)^\s*(?:>\s*)?Bumps\s+\[$pkg\]"
        "(?im)^\s*(?:>\s*)?Bumps\s+``$pkg``"
        "(?im)^\s*(?:>\s*)?Bumps\s+$pkg\s+from\s"
        "(?im)^\s*(?:>\s*)?Updates\s+\[$pkg\]"
        "(?im)^\s*(?:>\s*)?Updates\s+``$pkg``"
        "(?im)^\s*(?:>\s*)?Updates\s+$pkg\s+from\s"
    )

    $packageMatched = $false
    foreach ($p in $patterns) {
        if ($Body -match $p) { $packageMatched = $true; break }
    }
    if (-not $packageMatched) { return $false }

    # Does this PR actually clear the advisory? Dependabot states its destination as
    # "from <a> to <b>" on the same line as the package. `none` is the API's way of saying
    # no patched release exists, so there is nothing to compare against.
    if ($FirstPatchedVersion.Trim().ToLowerInvariant() -eq 'none') { return $false }
    if (-not [string]::IsNullOrWhiteSpace($FirstPatchedVersion)) {
        $toMatch = [regex]::Match(
            $Body,
            "(?im)^\s*(?:>\s*)?(?:Bumps|Updates)\s+(?:\[$pkg\]\([^)]*\)|``$pkg``|$pkg)\s+from\s+\S+\s+to\s+(?<to>[^\s,;)]+)")
        if (-not $toMatch.Success) {
            # A destination we cannot read is not a destination we can vouch for. Fail
            # closed: report the alert rather than suppress it on an unparsed body.
            return $false
        }
        # Dependabot ends the sentence with a period, and a version legitimately contains
        # them -- so the capture keeps dots and the SENTENCE period is trimmed here.
        $toVersion = $toMatch.Groups['to'].Value.TrimEnd('.')
        if (-not (Test-VersionAtLeast -Version $toVersion -Minimum $FirstPatchedVersion)) {
            return $false
        }
    }

    # Package-only mode is retained for the lexical matcher tests. Reconciliation
    # always supplies alert context and therefore takes the fail-closed path below.
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -and
        [string]::IsNullOrWhiteSpace($Ecosystem)) { return -not $RequireTargetContext }

    $branchMatch = [regex]::Match(
        $HeadRefName, '^dependabot/(?<ecosystem>[^/]+)(?:/(?<target>.+))?$')
    if (-not $branchMatch.Success) { return $false }

    # Keyed on the BRANCH spelling, mapped to the alerts-API ecosystem value. Three
    # entries mixed the two vocabularies: `github_actions` is not a branch prefix (the
    # branch says `github_actions` and the API says `actions`, not `github-actions`),
    # Go branches read `go_modules` rather than `gomod`, and `gradle` fell through to
    # default and could never equal the API's `maven`. Every affected alert with a real
    # covering PR reported UNCOVERED -- false-positive noise, which this script's own
    # header names as the thing that gets a check switched off.
    $prEcosystem = switch ($branchMatch.Groups['ecosystem'].Value.ToLowerInvariant()) {
        'npm_and_yarn'   { 'npm' }
        'github_actions' { 'actions' }
        'bundler'        { 'rubygems' }
        'go_modules'     { 'go' }
        'gomod'          { 'go' }        # older branches
        'gradle'         { 'maven' }
        'maven'          { 'maven' }
        'cargo'          { 'rust' }
        'pip'            { 'pip' }
        'composer'       { 'composer' }
        'nuget'          { 'nuget' }
        default          { $_ }
    }
    if (-not [string]::IsNullOrWhiteSpace($Ecosystem) -and
        $prEcosystem -ne $Ecosystem.Trim().ToLowerInvariant()) { return $false }

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) { return $true }

    $manifest = $ManifestPath.Replace('\', '/').Trim('/')
    $lastSlash = $manifest.LastIndexOf('/')
    $alertDirectory = if ($lastSlash -lt 0) { '' } else { $manifest.Substring(0, $lastSlash) }

    # ALL the clauses, not the first. A grouped PR carries one "in the /<dir> directory:"
    # clause per directory it touches, and reading only the first compared every package
    # against that one directory - so a package bumped in /backend was measured against
    # /frontend. When the alert happened to sit in the first-named directory that reads
    # as COVERED, which suppresses a real alert with nothing visible to notice.
    $directoryMatches = @([regex]::Matches(
        $Body,
        '(?im)^\s*Bumps\s+.+?\s+group\s+with\s+\d+\s+updates?\s+in\s+the\s+/(?<directory>.*?)\s+directory:'))
    $directoryMatch = if ($directoryMatches.Count -eq 1) { $directoryMatches[0] } else { $null }
    if ($directoryMatches.Count -gt 1) {
        # Each clause is followed by the `Updates <pkg> from a to b` lines it covers, up
        # to the next clause. Attribute the package to the block that actually lists it;
        # if no block does, or more than one does, we cannot say which directory the bump
        # landed in, and the alert is REPORTED rather than suppressed - a visible false
        # UNCOVERED row is the direction this script is allowed to fail in.
        $backtick = [char] 96
        $mention = "(?i)(?:\[|$backtick|\s)$pkg(?:\]|$backtick|[\s,.]|`$)"
        $owning = @()
        for ($m = 0; $m -lt $directoryMatches.Count; $m++) {
            $blockStart = $directoryMatches[$m].Index + $directoryMatches[$m].Length
            $blockEnd = if ($m + 1 -lt $directoryMatches.Count) { $directoryMatches[$m + 1].Index } else { $Body.Length }
            if ($Body.Substring($blockStart, $blockEnd - $blockStart) -match $mention) {
                $owning += $directoryMatches[$m]
            }
        }
        if ($owning.Count -ne 1) { return $false }
        $directoryMatch = $owning[0]
    }
    if ($directoryMatch) {
        $prDirectory = $directoryMatch.Groups['directory'].Value.Trim('/')
    } else {
        $target = $branchMatch.Groups['target'].Value
        $package = $PackageName.Trim().TrimStart('@')
        $branchPackages = @([regex]::Escape($package))
        if ($package.Contains('/')) { $branchPackages += [regex]::Escape($package.Replace('/', '-')) }
        $packagePattern = '(?:' + ($branchPackages -join '|') + ')'
        $packageInBranch = [regex]::Match($target, "(?i)(?:^|/)(?:@)?$packagePattern(?:-[^/]+)?$")
        if (-not $packageInBranch.Success) { return $false }
        $prDirectory = $target.Substring(0, $packageInBranch.Index).Trim('/')
    }

    return $prDirectory -ceq $alertDirectory
}

# --- gh helpers --------------------------------------------------------------
# gh writes its error BODY to stdout and only a one-line summary to stderr, so a
# 403/404 yields a whole JSON document unless the exit status is checked. Every
# call here honours $LASTEXITCODE rather than inspecting the payload.
function Invoke-Gh {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)

    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $out = & gh @Arguments 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stderr = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0) {
        $diagnostic = ([string]$stderr -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($diagnostic)) { $diagnostic = "gh exited $exitCode" }
        if ($diagnostic.Length -gt 512) { $diagnostic = $diagnostic.Substring(0, 509) + '...' }
        $script:lastGhError = $diagnostic
        if ($AllowFailure) { return $null }
        throw "gh $($Arguments -join ' ') failed with exit $exitCode`: $diagnostic"
    }
    $script:lastGhError = $null
    return $out
}

function Get-NotCheckedReason {
    param([Parameter(Mandatory)][string]$Reason)

    if ($script:lastGhError) { return "$Reason`: $script:lastGhError" }
    return $Reason
}

function Get-RepoList {
    param([string[]]$Orgs, [string[]]$Explicit)

    # @() on return AND at the call site: a single-element array unrolls to a scalar on
    # return, and a bare string has no .Count, so `-Repo one/thing` died under
    # StrictMode where two repos worked. Single-item is the common interactive case.
    if ($Explicit) { return @($Explicit) }

    $all = @()
    foreach ($o in $Orgs) {
        # Derived live, never a hard-coded list: a repo added after this was written
        # would otherwise be silently uncovered, which is the same silent-absence
        # class of failure the script exists to catch.
        $query = 'query($endCursor:String,$owner:String!){repositoryOwner(login:$owner){repositories(first:100,after:$endCursor,isArchived:false,ownerAffiliations:OWNER){nodes{nameWithOwner}pageInfo{hasNextPage,endCursor}}}}'
        $names = Invoke-Gh @('api', 'graphql', '--paginate', '-f', "query=$query",
            '-F', "owner=$o", '--jq', '.data.repositoryOwner.repositories.nodes[].nameWithOwner')
        if ($names) { $all += @($names) }
    }
    return @($all | Where-Object { $_ })
}

# ConvertFrom-Json already converts an ISO-8601 field into a [datetime], so calling
# [datetime]::Parse on it round-trips through the CURRENT CULTURE and throws on this
# box: the object stringifies as 08/13/2026 and en-GB reads that as month 13. The
# failure is seasonal, which is worse than constant -- for the first twelve days of any
# month both readings are valid and it silently computes the wrong age.
# Accept the value as it actually arrives, and pin the culture on the string path.
function ConvertTo-Utc {
    param([Parameter(Mandatory)][AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return ([datetimeoffset]$Value).UtcDateTime }

    return [datetime]::Parse(
        [string]$Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
        [System.Globalization.DateTimeStyles]::AssumeUniversal)
}

# UNREADABLE AND EMPTY MUST NOT COLLAPSE, and this is the direction that bites.
#
# If the PR query fails and its result is treated as "no PRs", then every alert in the
# repo has nothing to match against and every one is reported uncovered. That is not a
# safe failure: it is a false-positive flood, indistinguishable from real findings, and
# noise is what gets a check switched off.
#
# Returns $null when the query could not be read at all, and an array (possibly empty)
# when it genuinely was. Raised in review of PR #59, whose stated cause was wrong -- the
# `--author app/dependabot` filter does work, verified as 224 PRs total against 71
# filtered on example-app, with non-Dependabot authors excluded -- but the
# uncovered path it pointed at was real.
function ConvertFrom-PrListJson {
    param([Parameter(Mandatory)][AllowNull()]$Raw)

    if ($null -eq $Raw) { return $null }
    $text = ($Raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try { $parsed = @($text | ConvertFrom-Json) } catch { return $null }

    # `return ,$parsed`, not `return $parsed`. An EMPTY array unrolls to nothing on
    # return, so the caller receives $null — which would collapse "readable, no open
    # Dependabot PRs" back into "unreadable", destroying the one distinction this
    # function exists to make. The unary comma preserves the array. Caught by the test
    # for the '[]' case; the same unroll trap also bit -Repo with a single element.
    if ($parsed.Count -eq 0) { return ,$parsed }
    return $parsed
}

function ConvertFrom-PaginatedJson {
    param([Parameter(Mandatory)][AllowNull()]$Raw)

    if ($null -eq $Raw) { return $null }
    $text = ($Raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { $pages = @($text | ConvertFrom-Json) } catch { return $null }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($page in $pages) {
        foreach ($item in @($page)) {
            if ($null -ne $item) { $items.Add($item) }
        }
    }
    if ($items.Count -eq 0) { return ,@() }
    return @($items)
}

function Get-DependabotPullRequests {
    param([Parameter(Mandatory)][string]$Slug)

    $raw = Invoke-Gh @('api', "repos/$Slug/pulls?state=open&per_page=100", '--paginate',
        '--slurp') -AllowFailure
    $items = ConvertFrom-PaginatedJson -Raw $raw
    if ($null -eq $items -and $null -ne $raw) {
        $script:lastGhError = 'GitHub returned unreadable pull-request JSON'
    }
    if ($null -eq $items) { return $null }
    $parsed = @($items | Where-Object {
        (Get-Prop $_ @('user', 'login') '') -eq 'dependabot[bot]'
    } | ForEach-Object {
        [pscustomobject]@{
            number      = Get-Prop $_ @('number')
            title       = Get-Prop $_ @('title') ''
            body        = Get-Prop $_ @('body') ''
            headRefName = Get-Prop $_ @('head', 'ref') ''
        }
    })
    if (@($parsed).Count -eq 0) { return ,@() }
    return $parsed
}

function Get-DependabotAlerts {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$State
    )

    $raw = Invoke-Gh @('api', "repos/$Slug/dependabot/alerts?state=$State&per_page=100",
        '--paginate', '--slurp') -AllowFailure
    $parsed = ConvertFrom-PaginatedJson -Raw $raw
    if ($null -eq $parsed -and $null -ne $raw) {
        $script:lastGhError = 'GitHub returned unreadable Dependabot alert JSON'
    }
    if (@($parsed).Count -eq 0) { return ,@() }
    return $parsed
}

# StrictMode throws on property access through a $null, and the GitHub payload has
# genuinely optional branches. `security_vulnerability.first_patched_version` is null
# whenever NO fix exists yet -- which is not an edge case but the single most important
# benign reason an alert has no PR, so crashing on it would blind the tool to exactly
# the rows a human most needs to tell apart from a wrong verdict.
function Get-Prop {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string[]]$Path, $Default = $null)

    $cur = $Object
    foreach ($p in $Path) {
        if ($null -eq $cur) { return $Default }
        if ($cur.PSObject.Properties.Name -notcontains $p) { return $Default }
        $cur = $cur.$p
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Get-SecurityUpdateState {
    param([Parameter(Mandatory)][string]$Slug)

    $raw = Invoke-Gh @('api', "repos/$Slug/automated-security-fixes") -AllowFailure
    if (-not $raw) {
        if ($script:lastGhError -match '(?i)(?:HTTP\s*)?404|Not Found') {
            $script:lastGhError = 'HTTP 404 cannot distinguish disabled automated security fixes from a resource hidden by token permissions'
            return 'unknown'
        }
        return 'unknown'
    }
    try { $j = ($raw | Out-String | ConvertFrom-Json) } catch {
        $script:lastGhError = 'GitHub returned unreadable automated-security-fixes JSON'
        return 'unknown'
    }
    if (-not $j.enabled) { return 'DISABLED' }
    if ($j.paused)       { return 'PAUSED' }
    return 'on'
}

function Get-SecurityUpdateClassification {
    param([Parameter(Mandatory)][string]$State)

    switch ($State.ToUpperInvariant()) {
        'ON'       { return 'healthy' }
        'DISABLED' { return 'unhealthy' }
        'PAUSED'   { return 'unhealthy' }
        default    { return 'unknown' }
    }
}

function Add-UnmatchedAlert {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][int]$AgeHours,
        [Parameter(Mandatory)][int]$GraceHours,
        [Parameter(Mandatory)]$Findings,
        [Parameter(Mandatory)]$Graced
    )

    if ($AgeHours -lt $GraceHours) { $Graced.Add($Row) } else { $Findings.Add($Row) }
}

# --- main --------------------------------------------------------------------
$now = (Get-Date).ToUniversalTime()
$findings = [System.Collections.Generic.List[object]]::new()
$graced   = [System.Collections.Generic.List[object]]::new()
$skipped  = [System.Collections.Generic.List[object]]::new()
$secWarnings = [System.Collections.Generic.List[object]]::new()
$script:examined = 0

$repos = @(Get-RepoList -Orgs $Org -Explicit $Repo)
if (-not $repos) { throw 'No repositories resolved. Check -Org / -Repo and gh auth.' }

Write-Verbose "Reconciling $($repos.Count) repositories"

foreach ($slug in $repos) {
    # A repo with alerts disabled, or one this token cannot read, is NOT the same as a
    # repo with zero alerts, and must never be reported as clean. It is recorded as
    # skipped and surfaced separately.
    $alerts = Get-DependabotAlerts -Slug $slug -State $AlertState
    if ($null -eq $alerts) {
        $skipped.Add([pscustomobject]@{
            Repo = $slug
            Reason = Get-NotCheckedReason `
                -Reason 'alerts unreadable (disabled, or token lacks security_events)'
        })
        continue
    }

    $alerts = @($alerts | Where-Object { $null -ne $_ -and $null -ne $_.number })
    if ($alerts.Count -eq 0) { continue }
    # NB: the examined counter is incremented only AFTER the PR list is known to be
    # readable, further down. Counting here would credit a repo that then gets skipped,
    # so the summary would claim to have reconciled alerts it never compared.

    # Only fetched when the repo actually has open alerts — most repos have none, and
    # this keeps the sweep to roughly one call per repo in the common case.
    $prs = Get-DependabotPullRequests -Slug $slug
    if ($null -eq $prs) {
        # Cannot reconcile this repo: with no PR list, every alert would report as
        # uncovered. Say so instead of emitting rows that look like findings.
        $skipped.Add([pscustomobject]@{
            Repo   = $slug
            Reason = Get-NotCheckedReason -Reason `
                "has $($alerts.Count) $AlertState alert(s) but the Dependabot PR list was unreadable - NOT reconciled"
        })
        continue
    }

    # Counted so a clean report can say how much it actually reconciled. "No findings"
    # and "no alerts seen" are different claims, and reporting them identically is the
    # absence-reads-as-clean failure this skill exists to catch — it must not commit it.
    $script:examined += $alerts.Count

    # A repo-level fact, so it is reported once per repo below rather than repeated on
    # every finding row (raised in review of PR #59). It stays on the object for the
    # -Json consumer, where a row is the natural unit.
    $secState = Get-SecurityUpdateState -Slug $slug
    $secClassification = Get-SecurityUpdateClassification -State $secState
    if ($secClassification -eq 'unhealthy') {
        $secWarnings.Add([pscustomobject]@{ Repo = $slug; SecurityUpdates = $secState })
    } elseif ($secClassification -eq 'unknown') {
        $skipped.Add([pscustomobject]@{
            Repo = $slug
            Reason = Get-NotCheckedReason -Reason 'automated security update health UNKNOWN'
        })
    }

    foreach ($a in $alerts) {
        $pkg = Get-Prop $a @('dependency', 'package', 'name')
        $created = ConvertTo-Utc -Value (Get-Prop $a @('created_at'))
        if ($null -eq $created) {
            # No timestamp means the age gate cannot be applied. Report rather than
            # skip: an unaged alert dropped silently is the failure mode this whole
            # script exists to prevent.
            $ageHours = [int]::MaxValue
        } else {
            $ageHours = [int]($now - $created).TotalHours
        }

        # The DESTINATION VERSION is part of coverage. Matching on package, ecosystem and
        # directory alone let an open PR bumping nanoid 3.3.16 -> 3.3.17 suppress an alert
        # requiring 3.3.18: silent suppression indistinguishable from a fix, in the tool
        # written because Dependabot reached a wrong verdict on exactly that package.
        $firstPatched = [string](Get-Prop $a @('security_vulnerability', 'first_patched_version', 'identifier') '')
        $match = $prs | Where-Object {
            Test-DependabotPrCoversPackage -Body ([string]$_.body) -PackageName ([string]$pkg) `
                -HeadRefName ([string](Get-Prop $_ @('headRefName') '')) `
                -ManifestPath ([string](Get-Prop $a @('dependency', 'manifest_path') '')) `
                -Ecosystem ([string](Get-Prop $a @('dependency', 'package', 'ecosystem') '')) `
                -FirstPatchedVersion $firstPatched `
                -RequireTargetContext
        } | Select-Object -First 1

        if ($match) { continue }

        $row = [pscustomobject]@{
            Repo         = $slug
            Alert        = Get-Prop $a @('number')
            Package      = $pkg
            Ecosystem    = Get-Prop $a @('dependency', 'package', 'ecosystem') ''
            Severity     = Get-Prop $a @('security_advisory', 'severity') 'unknown'
            AgeDays      = if ($ageHours -eq [int]::MaxValue) { 'unknown' } else { [math]::Round($ageHours / 24, 1) }
            Scope        = Get-Prop $a @('dependency', 'scope') ''
            Manifest     = Get-Prop $a @('dependency', 'manifest_path') ''
            # 'none' is a MEANINGFUL value, not missing data: it says GitHub knows of no
            # patched release, which is the main legitimate reason an alert has no PR and
            # is the row a human can dismiss fastest.
            FirstPatched = Get-Prop $a @('security_vulnerability', 'first_patched_version', 'identifier') 'none'
            SecUpdates   = $secState
            Url          = Get-Prop $a @('html_url') ''
        }
        Add-UnmatchedAlert -Row $row -AgeHours $ageHours -GraceHours $GraceHours `
            -Findings $findings -Graced $graced
    }
}

$rank = @{ critical = 0; high = 1; medium = 2; moderate = 2; low = 3 }
$sorted = @($findings | Sort-Object `
    @{ Expression = { if ($rank.ContainsKey([string]$_.Severity)) { $rank[[string]$_.Severity] } else { 9 } } }, `
    @{ Expression = { if ($_.AgeDays -eq 'unknown') { [double]::MaxValue } else { [double]$_.AgeDays } }; Descending = $true })
$gracedSorted = @($graced | Sort-Object Repo, Alert)

if ($Json) {
    [pscustomobject]@{
        generatedUtc = $now.ToString('o')
        graceHours   = $GraceHours
        alertState   = $AlertState
        reposChecked = $repos.Count
        alertsExamined = $script:examined
        findings     = $sorted
        gracedUnmatched = $gracedSorted
        securityUpdatesNotHealthy = @($secWarnings)
        skipped      = @($skipped)
    } | ConvertTo-Json -Depth 6
    return
}

"Dependabot coverage reconciliation - $($now.ToString('yyyy-MM-dd HH:mm')) UTC"
"Repositories checked: $($repos.Count)   Alerts examined: $($script:examined)   State: $AlertState   Grace: ${GraceHours}h"
''

if ($sorted.Count -eq 0) {
    if ($script:examined -eq 0) {
        # Deliberately NOT phrased as a pass. Zero alerts examined proves nothing about
        # coverage, and saying "all clear" here would be the same absence-as-approval
        # mistake the skill was written to catch.
        "No $AlertState alerts existed in any checked repository, so there was nothing to reconcile."
    } else {
        "All $($script:examined) $AlertState alert(s) are covered by an open Dependabot PR, or are within the ${GraceHours}h grace window."
    }
} else {
    # A table, not prose: every row here is something a human must action by hand.
    $sorted | Format-Table -AutoSize `
        Repo, Alert, Package, Ecosystem, Manifest, Severity, AgeDays, Scope, FirstPatched | Out-String
    ''
    'Each row is an alert with no open Dependabot PR matching its package and target context.'
    'Dependabot may have decided no fix exists -- or decided that WRONGLY. Those are'
    'indistinguishable from outside, so read the update-job log by hand:'
    '  Insights > Dependency graph > Dependabot > the ecosystem row > Last checked'
    'Before accepting a "cannot update" verdict, read what the PARENT actually declares:'
    '  a caret or tilde range spanning the patched version means a lockfile-only bump works.'
}

if ($gracedSorted.Count -gt 0) {
    ''
    "GRACED UNMATCHED ALERTS (younger than ${GraceHours}h; not findings yet):"
    $gracedSorted | Format-Table -AutoSize `
        Repo, Alert, Package, Ecosystem, Manifest, Severity, AgeDays | Out-String
}

if ($secWarnings.Count -gt 0) {
    ''
    'SECURITY UPDATES NOT HEALTHY (a repo here cannot fix its own alerts automatically):'
    $secWarnings | Format-Table -AutoSize Repo, SecurityUpdates | Out-String
}

if ($skipped.Count -gt 0) {
    ''
    'NOT CHECKED (absence of findings here is not evidence of none):'
    $skipped | Format-Table -AutoSize Repo, Reason | Out-String
}
