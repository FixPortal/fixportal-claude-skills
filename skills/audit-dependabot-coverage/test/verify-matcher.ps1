<#
  Contract test for audit-dependabot-coverage's matcher.
  Run: pwsh -File ~/.agents/skills/audit-dependabot-coverage/test/verify-matcher.ps1

  BACKTESTED AGAINST THE CASE THAT MOTIVATED THE SKILL, not against invented input.
  Every fixture below is the real body shape captured from example-org/example-app
  in August 2026, so the matcher is exercised on the exact bug it exists to catch
  (nanoid alert #4, open four days, no PR) and on the false-positive shape that would
  make the whole check noise (brace-expansion, genuinely covered by PR #196).

  Offline and deterministic on purpose: a test that hit the live API would change
  verdict as PRs merge, and would pass or fail for reasons unrelated to the matcher.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Source functions without running the sweep. PowerShell's parser owns function
# boundaries; regex extraction truncates nested or deliberately reformatted bodies.
$script:reconcile = Join-Path (Split-Path -Parent $PSScriptRoot) 'reconcile.ps1'
if (-not (Test-Path $script:reconcile)) { throw "reconcile.ps1 not found at $script:reconcile" }

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $script:reconcile, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$orgParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Org' }
if ($null -eq $orgParameter -or $orgParameter.DefaultValue.Extent.Text -ne "@('YourOrg')") {
    throw 'Org must preserve the owner-selected <your-org> default.'
}

$requiredFunctions = @(
    'Test-DependabotPrCoversPackage'
    # Coverage now includes the DESTINATION VERSION, so the comparison helper is part of
    # the matcher's surface and has to be sourced with it.
    'Test-VersionAtLeast'
    'ConvertFrom-PrListJson'
    'ConvertFrom-PaginatedJson'
    'Get-Prop'
    'Invoke-Gh'
    'Get-NotCheckedReason'
    'Get-RepoList'
    'Get-DependabotPullRequests'
    'Get-DependabotAlerts'
    'Get-SecurityUpdateState'
    'Get-SecurityUpdateClassification'
    'Add-UnmatchedAlert'
)
$missingFunctions = @()
foreach ($fn in $requiredFunctions) {
    $node = $ast.FindAll({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq $fn
    }, $true) | Select-Object -First 1
    if ($null -eq $node) {
        $missingFunctions += $fn
        continue
    }
    . ([scriptblock]::Create($node.Extent.Text))
}

$fail = 0
function ok  { param($m) "ok   $m" }
function bad { param($m) $script:fail = 1; "FAIL $m" }

function Assert-Match {
    param(
        [string]$Body,
        [string]$Pkg,
        [bool]$Expected,
        [string]$Label,
        [string]$HeadRefName,
        [string]$ManifestPath,
        [string]$Ecosystem,
        [string]$FirstPatchedVersion,
        [switch]$RequireTargetContext
    )
    try {
        $parameters = @{
            Body = $Body
            PackageName = $Pkg
            HeadRefName = $HeadRefName
            ManifestPath = $ManifestPath
            Ecosystem = $Ecosystem
            FirstPatchedVersion = $FirstPatchedVersion
        }
        if ($RequireTargetContext) { $parameters.RequireTargetContext = $true }
        $got = Test-DependabotPrCoversPackage @parameters
    } catch {
        bad "$Label ($($_.Exception.Message))"
        return
    }
    if ($got -eq $Expected) { ok $Label } else { bad "$Label (want $Expected, got $got)" }
}

foreach ($fn in $missingFunctions) { bad "required production function exists: $fn" }

# --- real fixture: single-dep PR #196 ---------------------------------------
# Verbatim first line of the real body, plus the commit list that follows it.
$single = @'
Bumps [brace-expansion](https://github.com/juliangruber/brace-expansion) from 5.0.8 to 5.0.9.
<details>
<summary>Commits</summary>
<ul>
<li><a href="https://github.com/juliangruber/brace-expansion/commit/fbcf8ec"><code>fbcf8ec</code></a> 5.0.9</li>
</ul>
</details>
'@

Assert-Match -Body $single -Pkg 'brace-expansion' -Expected $true `
    -Label 'real single-dep body matches its own package (PR #196)'

# --- destination version is part of coverage --------------------------------
# The motivating case, one version short. Matching on package, ecosystem and directory
# alone let a PR bumping to 3.3.17 suppress an alert requiring 3.3.18: silent suppression
# indistinguishable from a fix, in the tool written because Dependabot reached a wrong
# verdict on this exact package.
$shortBump = 'Bumps [nanoid](https://github.com/ai/nanoid) from 3.3.16 to 3.3.17.'
Assert-Match -Body $shortBump -Pkg 'nanoid' -FirstPatchedVersion '3.3.18' -Expected $false `
    -Label 'a PR that does not reach the patched version is not coverage'
Assert-Match -Body $shortBump -Pkg 'nanoid' -FirstPatchedVersion '3.3.17' -Expected $true `
    -Label 'a PR that reaches the patched version exactly is coverage'
Assert-Match -Body 'Bumps [nanoid](https://github.com/ai/nanoid) from 3.3.16 to 3.4.0.' `
    -Pkg 'nanoid' -FirstPatchedVersion '3.3.18' -Expected $true `
    -Label 'a PR that overshoots the patched version is coverage'
Assert-Match -Body $shortBump -Pkg 'nanoid' -FirstPatchedVersion 'none' -Expected $false `
    -Label "'none' means no patched release exists, so no same-package PR proves the alert fixed"
Assert-Match -Body $shortBump -Pkg 'nanoid' -FirstPatchedVersion '' -Expected $true `
    -Label 'no advisory version supplied leaves the old behaviour unchanged'
# Fail CLOSED on a destination that cannot be read: report the alert, never suppress it.
Assert-Match -Body 'Bumps [nanoid](https://github.com/ai/nanoid) to the latest version.' `
    -Pkg 'nanoid' -FirstPatchedVersion '3.3.18' -Expected $false `
    -Label 'an unreadable destination version is not coverage'
# A prerelease has not reached the release of the same number.
Assert-Match -Body 'Bumps [nanoid](https://github.com/ai/nanoid) from 3.3.16 to 3.3.18-rc1.' `
    -Pkg 'nanoid' -FirstPatchedVersion '3.3.18' -Expected $false `
    -Label 'a prerelease does not clear an advisory naming its release'
Assert-Match -Body 'Bumps [nanoid](https://github.com/ai/nanoid) from 1.2.3-rc.1 to 1.2.3-rc.2.' `
    -Pkg 'nanoid' -FirstPatchedVersion '1.2.3-rc.3' -Expected $false `
    -Label 'a lower prerelease does not clear a later prerelease floor'
Assert-Match -Body 'Bumps [nanoid](https://github.com/ai/nanoid) from 1.2.3-rc.1 to 1.2.3-rc.4.' `
    -Pkg 'nanoid' -FirstPatchedVersion '1.2.3-rc.3' -Expected $true `
    -Label 'a higher prerelease clears a lower prerelease floor'

# --- real fixture: grouped PR #212 ------------------------------------------
# Verbatim from the real body. The branch for this PR is
# dependabot/npm_and_yarn/web/npm-minor-and-patch-eff5aeb2ab and names NO package,
# which is why matching reads the body and not the branch.
$grouped = @'
Bumps the npm-minor-and-patch group with 6 updates in the /web directory:
Updates `@azure/msal-browser` from 5.17.3 to 5.18.0
Updates `@azure/msal-react` from 5.5.4 to 5.5.5
Updates `swr` from 2.4.2 to 2.5.0
Updates `@testing-library/user-event` from 14.6.1 to 14.6.3
Updates `globals` from 17.8.0 to 17.9.0
Updates `typescript-eslint` from 8.65.0 to 8.66.0
'@

Assert-Match -Body $grouped -Pkg '@azure/msal-browser' -Expected $true `
    -Label 'grouped body matches a scoped package (PR #212)'
Assert-Match -Body $grouped -Pkg 'swr' -Expected $true `
    -Label 'grouped body matches an unscoped package'

# THE REGRESSION THAT DEFINES THE SKILL. nanoid alert #4 was open for four days while
# PR #212 was the only open npm PR for /web. If the matcher counts #212 as covering
# nanoid, the sweep reports the repo clean and reproduces the exact silent miss.
Assert-Match -Body $grouped -Pkg 'nanoid' -Expected $false `
    -Label 'grouped body does NOT cover nanoid (the 2026-08-08 silent miss)'

# --- the dangerous false positive -------------------------------------------
# Dependabot embeds release notes and changelogs that name many unrelated packages.
# An unanchored substring match would treat every one as fixed, suppressing real
# findings -- the same silent-absence failure the skill exists to catch.
$withReleaseNotes = @'
Bumps [vite](https://github.com/vitejs/vite) from 8.2.0 to 8.2.1.
<details>
<summary>Release notes</summary>
<blockquote>
<h2>What's Changed</h2>
<ul>
<li>fix: bump nanoid to patch a CVE in the postcss dependency chain</li>
<li>chore: update swr and globals in the example app</li>
</ul>
</blockquote>
</details>
'@

Assert-Match -Body $withReleaseNotes -Pkg 'vite' -Expected $true `
    -Label 'body matches the package it actually bumps'
Assert-Match -Body $withReleaseNotes -Pkg 'nanoid' -Expected $false `
    -Label 'a package named only in RELEASE NOTES is not counted as fixed'
Assert-Match -Body $withReleaseNotes -Pkg 'swr' -Expected $false `
    -Label 'nor one named in a changelog bullet'

# --- regex-safety -----------------------------------------------------------
# A package name is interpolated into a pattern, so an unescaped name would let its
# metacharacters match. `.` is the one that actually occurs across this estate
# (Scalar.AspNetCore, Microsoft.Extensions.*), and it would match ANY character.
$nuget = 'Bumps [Scalar.AspNetCore](https://github.com/scalar/scalar) from 2.16.17 to 2.16.18.'
Assert-Match -Body $nuget -Pkg 'Scalar.AspNetCore' -Expected $true `
    -Label 'a dotted NuGet package matches itself'
Assert-Match -Body $nuget -Pkg 'ScalarXAspNetCore' -Expected $false `
    -Label 'the dot is escaped, not treated as any-char'

# --- an unparseable advisory version ----------------------------------------
# `1.2.3.Final` is a real shape (Maven, RubyGems). Its fourth segment is not numeric, so
# the version is UNPARSEABLE and nothing may be reported as clearing it. The guard that
# was supposed to say so never fired - a one-element array of $null is falsy - so the
# comparison read the missing segment as 0 and a bump to `1.2.3` suppressed the alert.
Assert-Match -Body 'Bumps [thing](https://example.invalid/thing) from 1.2.2 to 1.2.3.' `
    -Pkg 'thing' -FirstPatchedVersion '1.2.3.Final' -Expected $false `
    -Label 'an unparseable advisory version is never cleared'
# ...and the same destination still clears an advisory that IS parseable, so the case
# above cannot pass because version comparison stopped working altogether.
Assert-Match -Body 'Bumps [thing](https://example.invalid/thing) from 1.2.2 to 1.2.3.' `
    -Pkg 'thing' -FirstPatchedVersion '1.2.3' -Expected $true `
    -Label 'a parseable advisory version is still cleared by an equal destination'
Assert-Match -Body 'Bumps [thing](https://example.invalid/thing) from 1.2.2 to 1.2.3+!!!.' `
    -Pkg 'thing' -FirstPatchedVersion '1.2.3' -Expected $false `
    -Label 'invalid SemVer build metadata does not count as a valid destination version'

# Version segments are compared NUMERICALLY, not lexically. `1.10` is above `1.9`, and a
# string comparison says the opposite - which would drop an alert whose fix the PR does
# not actually reach.
Assert-Match -Body 'Bumps [thing](https://example.invalid/thing) from 1.8 to 1.10.' `
    -Pkg 'thing' -FirstPatchedVersion '1.9' -Expected $true `
    -Label '1.10 clears an advisory requiring 1.9'
Assert-Match -Body 'Bumps [thing](https://example.invalid/thing) from 1.8 to 1.9.' `
    -Pkg 'thing' -FirstPatchedVersion '1.10' -Expected $false `
    -Label '1.9 does not clear an advisory requiring 1.10'

# --- degenerate input -------------------------------------------------------
# A PR whose body failed to fetch must never read as coverage: empty body plus a real
# package is precisely the shape an API hiccup produces, and counting it as a match
# would mark every alert in the repo covered.
Assert-Match -Body '' -Pkg 'nanoid' -Expected $false `
    -Label 'an empty body covers nothing'
Assert-Match -Body $single -Pkg '' -Expected $false `
    -Label 'an empty package name matches nothing'

# --- manifest and ecosystem identity ---------------------------------------
$webGrouped = @'
Bumps the npm-minor-and-patch group with 1 update in the /web directory:
Updates `nanoid` from 3.3.16 to 3.3.18
'@
$webBranch = 'dependabot/npm_and_yarn/web/npm-minor-and-patch-abc123'

Assert-Match -Body $webGrouped -Pkg 'nanoid' -HeadRefName $webBranch `
    -ManifestPath 'web/package-lock.json' -Ecosystem 'npm' -Expected $true `
    -Label 'same package, manifest directory, and ecosystem is covered'
Assert-Match -Body $webGrouped -Pkg 'nanoid' -HeadRefName $webBranch `
    -ManifestPath 'api/package-lock.json' -Ecosystem 'npm' -Expected $false `
    -Label 'same package in a different manifest directory stays unmatched'
Assert-Match -Body $webGrouped -Pkg 'nanoid' -HeadRefName $webBranch `
    -ManifestPath 'web/packages.lock.json' -Ecosystem 'nuget' -Expected $false `
    -Label 'same package in a different ecosystem stays unmatched'
Assert-Match -Body $webGrouped -Pkg 'nanoid' -HeadRefName '' `
    -ManifestPath 'web/package-lock.json' -Ecosystem 'npm' -Expected $false `
    -Label 'missing PR target context stays unmatched rather than guessing'
Assert-Match -Body $webGrouped -Pkg 'nanoid' -HeadRefName $webBranch `
    -ManifestPath '' -Ecosystem '' -RequireTargetContext -Expected $false `
    -Label 'missing alert target context stays unmatched in reconciliation mode'

# --- a grouped PR spanning SEVERAL directories -------------------------------
# One clause per directory, each followed by the updates it covers. Reading only the
# first clause measured every package against /web: `undici`, bumped in /api, then
# compared against a /web alert and read as COVERED - suppressing a real alert with
# nothing visible to notice. Attribution is now per block.
$multiDirectory = @'
Bumps the npm-minor-and-patch group with 1 update in the /web directory:
Updates `nanoid` from 3.3.16 to 3.3.18

Bumps the npm-minor-and-patch group with 1 update in the /api directory:
Updates `undici` from 6.19.0 to 6.21.1
'@
$multiBranch = 'dependabot/npm_and_yarn/npm-minor-and-patch-def456'

Assert-Match -Body $multiDirectory -Pkg 'nanoid' -HeadRefName $multiBranch `
    -ManifestPath 'web/package-lock.json' -Ecosystem 'npm' -Expected $true `
    -Label 'a package is matched against the directory clause that lists it'
Assert-Match -Body $multiDirectory -Pkg 'undici' -HeadRefName $multiBranch `
    -ManifestPath 'api/package-lock.json' -Ecosystem 'npm' -Expected $true `
    -Label 'a package under the SECOND directory clause is matched against that directory'
Assert-Match -Body $multiDirectory -Pkg 'undici' -HeadRefName $multiBranch `
    -ManifestPath 'web/package-lock.json' -Ecosystem 'npm' -Expected $false `
    -Label 'a package bumped in /api does not cover the same package alerted in /web'

$scopedSingle = 'Bumps [@azure/msal-browser](https://github.com/AzureAD/microsoft-authentication-library-for-js) from 5.17.3 to 5.18.0.'
Assert-Match -Body $scopedSingle -Pkg '@azure/msal-browser' `
    -HeadRefName 'dependabot/npm_and_yarn/web/@azure/msal-browser-5.18.0' `
    -ManifestPath 'web/package-lock.json' -Ecosystem 'npm' -Expected $true `
    -Label 'scoped npm package matches Dependabot slash-form single-dependency branch'
Assert-Match -Body $scopedSingle -Pkg '@azure/msal-browser' `
    -HeadRefName 'dependabot/npm_and_yarn/web/azure-msal-browser-5.18.0' `
    -ManifestPath 'web/package-lock.json' -Ecosystem 'npm' -Expected $true `
    -Label 'scoped npm package also matches the normalized hyphen-form branch'

$singleApi = 'Bumps [api](https://example.invalid/api) from 1.0.0 to 1.0.1.'
Assert-Match -Body $singleApi -Pkg 'api' `
    -HeadRefName 'dependabot/npm_and_yarn/api-service/api-2' `
    -ManifestPath 'package-lock.json' -Ecosystem 'npm' -Expected $false `
    -Label 'a directory prefix shaped like the package cannot cover the root manifest'

$caseVariantGrouped = @'
Bumps the npm-minor-and-patch group with 1 update in the /Web directory:
Updates `nanoid` from 3.3.16 to 3.3.18
'@
Assert-Match -Body $caseVariantGrouped -Pkg 'nanoid' -HeadRefName $webBranch `
    -ManifestPath 'web/package-lock.json' -Ecosystem 'npm' -Expected $false `
    -Label 'manifest directory identity is case-sensitive'

# --- unreadable PR list must NOT read as "no PRs" ---------------------------
# THE FALSE-POSITIVE FLOOD PATH, and the one my own validation could not have caught.
# If a failed PR query is treated as an empty list, every alert in that repo has nothing
# to match against and every one is reported uncovered -- noise indistinguishable from
# real findings. The live run could not have exposed it either: the estate currently has
# zero open alerts, so nothing was ever compared.
#
# Raised in review of PR #59. Its stated cause was wrong -- `--author app/dependabot`
# does filter correctly (224 PRs total vs 71 filtered on example-app, with
# non-Dependabot authors excluded) -- but the uncovered code path was real.
function Assert-PrList {
    param($Raw, [bool]$ExpectNull, [string]$Label)
    $got = ConvertFrom-PrListJson -Raw $Raw
    $isNull = ($null -eq $got)
    if ($isNull -eq $ExpectNull) { ok $Label } else { bad "$Label (expected null=$ExpectNull, got null=$isNull)" }
}

Assert-PrList -Raw $null           -ExpectNull $true  -Label 'a failed PR query is UNREADABLE, not an empty list'
Assert-PrList -Raw ''              -ExpectNull $true  -Label 'empty output is unreadable, not an empty list'
Assert-PrList -Raw '   '           -ExpectNull $true  -Label 'whitespace-only output is unreadable'
Assert-PrList -Raw 'not json {'    -ExpectNull $true  -Label 'unparseable output is unreadable'
Assert-PrList -Raw '[]'            -ExpectNull $false -Label 'a genuine empty array IS a readable result'
Assert-PrList -Raw '[{"number":1,"body":"Bumps [x](u) from 1 to 2."}]' -ExpectNull $false `
    -Label 'a populated array is readable'

# --- multi-page gh output shape ----------------------------------------------
# A reviewer claimed `gh api --paginate` emits each page as a SEPARATE JSON document, so
# without --slurp ConvertFrom-Json would fail on any multi-page response. Settled by live
# probe (gh 2.87.3, 2026-08-25): REST array pages are MERGED into ONE array document - 90
# PRs fetched at per_page=1 arrived as a single 90-element array that parses cleanly. Pin
# the shape gh actually emits so a regression to separate documents fails loudly here
# instead of silently in the sweep.
$mergedPages = '[{"number":1,"body":"Bumps [a](u) from 1 to 2."},{"number":2,"body":"Bumps [b](u) from 3 to 4."}]'
$pageSet = ConvertFrom-PrListJson -Raw $mergedPages
if ($null -ne $pageSet -and @($pageSet).Count -eq 2) { ok 'a merged multi-page array parses as every page' }
else { bad 'a merged multi-page array parses as every page' }
# If gh ever DID emit separate documents, the safe direction is UNREADABLE (skip the
# repo), never a partial or empty read.
Assert-PrList -Raw ("[{`"number`":1}]" + "`n" + '[{"number":2}]') -ExpectNull $true `
    -Label 'separate JSON documents per page would be UNREADABLE, never a partial read'

# And the readable-empty case must survive as an enumerable, or a repo with alerts and
# genuinely no Dependabot PRs would crash rather than report.
$emptySet = ConvertFrom-PrListJson -Raw '[]'
if (@($emptySet).Count -eq 0) { ok 'a readable empty result enumerates as zero PRs' }
else { bad 'a readable empty result enumerates as zero PRs' }

# --- Get-Prop: the safe accessor --------------------------------------------
# Load-bearing defensive code on every alert field, so a regression here would blind
# the tool to malformed payloads silently. Raised in review of PR #59.
#
# Fixtures come from ConvertFrom-Json rather than hand-built hashtables, because that
# is the only shape it is ever given -- Get-Prop reads PSObject.Properties, which does
# NOT enumerate hashtable keys, so a hashtable fixture would test behaviour the tool
# never relies on and would pass or fail for the wrong reason.
$alertLike = '{"number":4,"dependency":{"package":{"name":"nanoid"},"scope":"development"},
  "security_vulnerability":{"first_patched_version":{"identifier":"3.3.17"}}}' | ConvertFrom-Json
$noFix     = '{"number":9,"security_vulnerability":{"first_patched_version":null}}' | ConvertFrom-Json

function Assert-Prop {
    param($Object, [string[]]$Path, $Default, $Expected, [string]$Label)
    $got = Get-Prop $Object $Path $Default
    if ($got -eq $Expected) { ok $Label } else { bad "$Label (want '$Expected', got '$got')" }
}

Assert-Prop -Object $alertLike -Path @('number') -Expected 4 `
    -Label 'Get-Prop reads a top-level value'
Assert-Prop -Object $alertLike -Path @('dependency', 'package', 'name') -Expected 'nanoid' `
    -Label 'Get-Prop walks a nested path'
Assert-Prop -Object $alertLike -Path @('security_vulnerability', 'first_patched_version', 'identifier') `
    -Expected '3.3.17' -Label 'Get-Prop reads a present patched version'

# THE CASE IT WAS WRITTEN FOR. A null intermediate is what a no-fix-available advisory
# looks like, and StrictMode throws on property access through it -- which crashed the
# live run before this existed. 'none' is the meaningful rendering, not absence.
Assert-Prop -Object $noFix -Path @('security_vulnerability', 'first_patched_version', 'identifier') `
    -Default 'none' -Expected 'none' `
    -Label 'a null intermediate yields the default, not a crash (no fix available)'

Assert-Prop -Object $alertLike -Path @('nope') -Default 'fallback' -Expected 'fallback' `
    -Label 'a missing property yields the default'
Assert-Prop -Object $alertLike -Path @('dependency', 'nope', 'deeper') -Default 'fallback' `
    -Expected 'fallback' -Label 'a missing intermediate yields the default'
Assert-Prop -Object $null -Path @('anything') -Default 'fallback' -Expected 'fallback' `
    -Label 'a null object yields the default'

# No explicit Default means $null, and it must not become the string 'null' or throw.
$implicit = Get-Prop $alertLike @('nope')
if ($null -eq $implicit) { ok 'a missing property with no Default yields $null' }
else { bad "a missing property with no Default yields `$null (got '$implicit')" }

# --- enumeration is paginated, not capped ----------------------------------
$productionInvokeGh = (Get-Command Invoke-Gh).ScriptBlock
$script:capturedGhArguments = @()
function Invoke-Gh {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $script:capturedGhArguments = $Arguments
    return @(1..201 | ForEach-Object { "example-org/repo-$_" })
}

$repos = @(Get-RepoList -Orgs @('example-org') -Explicit @())
if ($repos.Count -eq 201) { ok 'repository enumeration retains a result beyond the old 200 cap' }
else { bad "repository enumeration retains a result beyond the old 200 cap (got $($repos.Count))" }
if ($script:capturedGhArguments -contains '--paginate' -and
    $script:capturedGhArguments -notcontains '--limit') {
    ok 'repository enumeration requests every page without a numeric cap'
} else {
    bad "repository enumeration requests every page without a numeric cap ($($script:capturedGhArguments -join ' '))"
}
Set-Item -Path Function:\Invoke-Gh -Value $productionInvokeGh

if (Get-Command Get-DependabotPullRequests -ErrorAction SilentlyContinue) {
    $script:capturedGhArguments = @()
    function Invoke-Gh {
        param([string[]]$Arguments, [switch]$AllowFailure)
        $script:capturedGhArguments = $Arguments
        $items = @(1..101 | ForEach-Object {
            [pscustomobject]@{
                number = $_
                title = "Bump package-$_"
                body = "Bumps [package-$_](https://example.invalid) from 1 to 2."
                user = [pscustomobject]@{ login = 'dependabot[bot]' }
                head = [pscustomobject]@{ ref = "dependabot/npm_and_yarn/package-$_-2" }
            }
        })
        $pages = [object[]]::new(2)
        $pages[0] = @($items[0..99])
        $pages[1] = @($items[100])
        return ,($pages | ConvertTo-Json -Depth 4 -Compress)
    }
    $prs = @(Get-DependabotPullRequests -Slug 'example-org/example')
    if ($prs.Count -eq 101) { ok 'PR enumeration retains a result beyond the old 100 cap' }
    else { bad "PR enumeration retains a result beyond the old 100 cap (got $($prs.Count))" }
    if ($script:capturedGhArguments -contains '--paginate' -and
        $script:capturedGhArguments -notcontains '--limit' -and
        -not ($script:capturedGhArguments -contains '--slurp' -and
            $script:capturedGhArguments -contains '--jq')) {
        ok 'PR enumeration requests every page without a numeric cap or incompatible format flags'
    } else {
        bad "PR enumeration requests every page without a numeric cap or incompatible format flags ($($script:capturedGhArguments -join ' '))"
    }
    Set-Item -Path Function:\Invoke-Gh -Value $productionInvokeGh
}

# --- state query and classification -----------------------------------------
if (Get-Command Get-DependabotAlerts -ErrorAction SilentlyContinue) {
    $script:capturedGhArguments = @()
    function Invoke-Gh {
        param([string[]]$Arguments, [switch]$AllowFailure)
        $script:capturedGhArguments = $Arguments
        return '[[{"number":77,"state":"auto_dismissed"}]]'
    }
    $autoDismissed = @(Get-DependabotAlerts -Slug 'example-org/example' -State 'auto_dismissed')
    if ($autoDismissed.Count -eq 1 -and $autoDismissed[0].state -eq 'auto_dismissed') {
        ok 'auto_dismissed alerts are queried and returned'
    } else { bad 'auto_dismissed alerts are queried and returned' }
    if (($script:capturedGhArguments -join ' ') -match 'state=auto_dismissed' -and
        $script:capturedGhArguments -contains '--paginate') {
        ok 'auto_dismissed uses the paginated alert endpoint'
    } else { bad "auto_dismissed uses the paginated alert endpoint ($($script:capturedGhArguments -join ' '))" }

    function Invoke-Gh {
        param([string[]]$Arguments, [switch]$AllowFailure)
        $script:lastGhError = 'AUTH_DENIED'
        return $null
    }
    $failedAlerts = Get-DependabotAlerts -Slug 'example-org/example' -State 'open'
    if ($null -eq $failedAlerts) { ok 'a failed alert query is UNREADABLE, not an empty list' }
    else { bad 'a failed alert query is UNREADABLE, not an empty list' }

    function Invoke-Gh {
        param([string[]]$Arguments, [switch]$AllowFailure)
        return '[[]]'
    }
    $emptyAlerts = Get-DependabotAlerts -Slug 'example-org/example' -State 'open'
    if ($null -ne $emptyAlerts -and @($emptyAlerts).Count -eq 0) {
        ok 'a readable empty alert page remains distinct from API failure'
    } else { bad 'a readable empty alert page remains distinct from API failure' }
    Set-Item -Path Function:\Invoke-Gh -Value $productionInvokeGh
}

if (Get-Command Get-SecurityUpdateClassification -ErrorAction SilentlyContinue) {
    if ((Get-SecurityUpdateClassification -State 'unknown') -eq 'unknown') {
        ok 'UNKNOWN security-update state is not classified as unhealthy'
    } else { bad 'UNKNOWN security-update state is not classified as unhealthy' }
    if ((Get-SecurityUpdateClassification -State 'DISABLED') -eq 'unhealthy' -and
        (Get-SecurityUpdateClassification -State 'PAUSED') -eq 'unhealthy') {
        ok 'only confirmed disabled or paused states are unhealthy'
    } else { bad 'only confirmed disabled or paused states are unhealthy' }
    $productionSecurityProbe = (Get-Command Invoke-Gh -CommandType Function).ScriptBlock
    function Invoke-Gh {
        param([string[]]$Arguments, [switch]$AllowFailure)
        $script:lastGhError = 'HTTP 404 Not Found'
        return $null
    }
    if ((Get-SecurityUpdateState -Slug 'example-org/example') -eq 'unknown' -and
        $script:lastGhError -match 'cannot distinguish disabled.*hidden by token permissions') {
        ok 'automated-security-fixes HTTP 404 remains unknown when permission masking is possible'
    } else { bad 'automated-security-fixes HTTP 404 remains unknown when permission masking is possible' }
    function Invoke-Gh {
        param([string[]]$Arguments, [switch]$AllowFailure)
        $script:lastGhError = 'HTTP 403 Forbidden'
        return $null
    }
    if ((Get-SecurityUpdateState -Slug 'example-org/example') -eq 'unknown') {
        ok 'non-404 API failures remain UNKNOWN'
    } else { bad 'non-404 API failures remain UNKNOWN' }
    Set-Item -Path Function:\Invoke-Gh -Value $productionSecurityProbe
}

# --- failed APIs retain only bounded stderr ---------------------------------
$script:lastGhError = $null
function gh {
    Write-Error ('AUTH_DENIED ' + ('x' * 700)) -ErrorAction Continue
    $global:LASTEXITCODE = 1
    'unsafe response body'
}
$failedApi = Invoke-Gh -Arguments @('api', 'repos/example-org/example/dependabot/alerts') -AllowFailure
$diagnostic = if (Get-Variable -Name lastGhError -Scope Script -ErrorAction SilentlyContinue) {
    [string]$script:lastGhError
} else { '' }
if ($null -eq $failedApi) { ok 'a failed API call returns no successful payload' }
else { bad 'a failed API call returns no successful payload' }
if ($diagnostic -match 'AUTH_DENIED' -and $diagnostic.Length -le 512 -and
    $diagnostic -notmatch 'unsafe response body') {
    ok 'a failed API call retains bounded stderr without trusting stdout'
} else { bad "a failed API call retains bounded stderr without trusting stdout (length $($diagnostic.Length))" }
if (Get-Command Get-NotCheckedReason -ErrorAction SilentlyContinue) {
    $reason = Get-NotCheckedReason -Reason 'alerts unreadable'
    if ($reason -match '^alerts unreadable: .*AUTH_DENIED' -and $reason.Length -le 531) {
        ok 'NOT CHECKED reason carries the bounded API diagnostic'
    } else { bad "NOT CHECKED reason carries the bounded API diagnostic ($reason)" }
}
Remove-Item -Path Function:\gh

# --- grace is an explicit per-alert ledger ----------------------------------
if (Get-Command Add-UnmatchedAlert -ErrorAction SilentlyContinue) {
    $findingRows = [System.Collections.Generic.List[object]]::new()
    $gracedRows = [System.Collections.Generic.List[object]]::new()
    Add-UnmatchedAlert -Row ([pscustomobject]@{ Alert = 10 }) -AgeHours 1 -GraceHours 48 `
        -Findings $findingRows -Graced $gracedRows
    Add-UnmatchedAlert -Row ([pscustomobject]@{ Alert = 11 }) -AgeHours 47 -GraceHours 48 `
        -Findings $findingRows -Graced $gracedRows
    if ($findingRows.Count -eq 0 -and $gracedRows.Count -eq 2 -and
        $gracedRows[0].Alert -eq 10 -and $gracedRows[1].Alert -eq 11) {
        ok 'every graced unmatched alert remains individually visible'
    } else { bad 'every graced unmatched alert remains individually visible' }
}

# --- red check --------------------------------------------------------------
# A suite that cannot fail is not a suite. This asserts a deliberately false
# expectation is reported as a failure, then repairs the counter.
$before = $script:fail
$script:fail = 0
$null = Assert-Match -Body $single -Pkg 'brace-expansion' -Expected $false -Label 'red-check probe'
if ($script:fail -eq 1) { $script:fail = $before; ok 'red check: a false expectation is reported as a failure' }
else { $script:fail = 1; bad 'red check: a false expectation is reported as a failure' }

''
if ($script:fail -eq 0) { 'PASS'; exit 0 } else { 'FAILURES ABOVE'; exit 1 }
