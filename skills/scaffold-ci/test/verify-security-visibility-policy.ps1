$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
$ciRoot = Join-Path $root 'scaffold-ci'
$security = Get-Content (Join-Path $ciRoot 'references' 'dependencies-and-security.md') -Raw
$ci = @(
    Get-Content (Join-Path $ciRoot 'SKILL.md') -Raw
    Get-ChildItem (Join-Path $ciRoot 'references') -Filter '*.md' | ForEach-Object { Get-Content $_.FullName -Raw }
) -join "`n"
# scaffold-repo is a sibling skill in the private home that this public mirror does not
# carry. Same convention as the absent-policy skip below: $null means ABSENT, and the
# scaffold-repo assertions are skipped with a stated reason rather than failing on a file
# the repository deliberately does not own.
$repoPath = Join-Path $root 'scaffold-repo' 'SKILL.md'
$repo = if (Test-Path -LiteralPath $repoPath) { [string](Get-Content -LiteralPath $repoPath -Raw) } else {
    Write-Host "SKIP: scaffold-repo sibling not present in this tree - $repoPath"
    $null
}
$audit = Get-Content (Join-Path $root 'audit-ci' 'SKILL.md') -Raw
$audit += "`n" + (Get-Content (Join-Path $root 'audit-ci/references/inventory.md') -Raw)
$audit += "`n" + (Get-Content (Join-Path $root 'audit-ci/references/evaluation.md') -Raw)
$estate = Get-Content (Join-Path $root 'audit-github-estate' 'SKILL.md') -Raw
$gateRoot = Join-Path $root 'quality-gate-review'
$gate = @(
    Get-Content (Join-Path $gateRoot 'SKILL.md') -Raw
    Get-ChildItem (Join-Path $gateRoot 'references') -Filter '*.md' | ForEach-Object { Get-Content $_.FullName -Raw }
) -join "`n"
$dotnet = Get-Content (Join-Path $root 'scaffold-dotnet' 'SKILL.md') -Raw
# Codex's global policy file lives OUTSIDE this repository, so it is absent on CI and on
# any machine that is not this estate. Its absence is not a defect in this repo - skip the
# assertion with a stated reason rather than failing a PR over a file the repo does not own.
# $null means ABSENT (skip); an empty string means present-but-empty, which must still be
# asserted against and fail. Gating on truthiness would turn a truncated policy into a pass.
$agentsPath = Join-Path $HOME '.codex' 'AGENTS.md'
$agents = if (Test-Path -LiteralPath $agentsPath) { [string](Get-Content -LiteralPath $agentsPath -Raw) } else {
    Write-Host "SKIP: global Codex policy not present on this host - $agentsPath"
    $null
}

# Code Quality is FREE on public repositories and PAID on private/internal ones, so the
# unsafe direction is no longer "enabled without charge approval" -- public enablement is
# now the expected state. What is still unsafe:
#
#   * enabling it on a private/internal repository, where it is billed;
#   * enabling it as a blanket default with no visibility qualifier, which reaches the
#     private repositories by omission;
#   * enabling its AI findings at ANY visibility. Those are Copilot-generated review
#     comments with no dismissal API -- the whole reason ai-findings-ledger exists -- and
#     free deterministic coverage is not a reason to turn them on.
#
# UNVERIFIED: that public Code Quality is free. The maintainer verified it against the
# organization's billing and UI on 2026-09-09, and the estate has run it on all eight
# public repositories since 2026-08-14. GitHub's published docs state no public exemption:
# its changelog calls Code Quality purchasable from GA on 2026-07-20, billed as a base
# subscription plus metered per-committer usage. Refuted if the organization's bill shows a
# charge attributable to Code Quality on a public repository -- restore the charge-approval
# gate at every visibility if so.
function Assert-NoUnsafeCodeQualityDefault {
    param([string]$Name, [string]$Text)

    foreach ($line in $Text -split '\r?\n') {
        if ($line -notmatch '(?i)Code Quality') { continue }
        if ($line -notmatch '(?i)\b(enable(?:d|s)?|configur(?:e|ed))\b') { continue }

        # "disabled" inside the AI-findings clause says nothing about the PRODUCT:
        # "Private repositories enable Code Quality with AI findings disabled." enables
        # paid Code Quality, and the guard accepted it because it saw that one word.
        # Strip the clause before deciding whether the product is disabled, and read ONLY
        # the clause when deciding about AI findings. Each half reading the whole line
        # let the other half's "disabled" vouch for it: "Enable Code Quality AI findings;
        # keep Code Quality disabled on private repositories" enables AI findings and
        # passed because the product clause said disabled.
        # A clause ends at the next mention, so "AI findings disabled and enable AI findings on
        # public repositories" is two clauses and the second is read on its own.
        $aiClausePattern = '(?i)\bAI findings\b(?:(?!\bAI findings\b)[^.;,])*'
        # "off" is in the vocabulary because it is what the stripped clause used to lend
        # the rest of the line: "AI findings disabled; private/internal keep it off" is a
        # disablement of the product, and without "off" the strip leaves it looking like
        # an enablement. But only a DISABLING "off": tied to a verb ("keep it off") or
        # directly to a visibility or the findings ("private/internal off"). A bare `off`
        # let "kick off a baseline scan" excuse a private enablement. The verb form may only
        # take it/Code Quality as its object and must end the clause or lead into a scope
        # ("on private repositories"): "turn off notifications" disabled nothing.
        $disabledWords = '(?i)\b(?:disabled?|not-configured)\b' +
            '|\b(?:keeps?|kept|turn(?:s|ed)?|switch(?:es|ed)?|leaves?|left|stays?|remains?|set)\b(?:\s+(?:it|them|paid|Code|Quality|turned|switched))*\s+off\b(?=\s*(?:$|[.;,]|\s(?:on|for|in|at|everywhere)\b))' +
            '|(?:private/internal|private or internal|repositor(?:y|ies)|AI findings)\s*:?\s*off\b' +
            # The object after "off": "turn off Code Quality on private repositories" or
            # "turn off AI findings". The product name must end the clause or lead into a scope,
            # so "turn off Code Quality AI findings" / "... notifications" leave the product enabled.
            '|\b(?:turn(?:s|ed)?|switch(?:es|ed)?|set)\s+off\s+(?:paid\s+)?Code\s+Quality\b(?=\s*(?:$|[.;,]|\s(?:on|for|in|at|everywhere)\b))' +
            # A negative status counts only for its own subject: "notifications are not enabled"
            # says nothing about Code Quality.
            '|\b(?:Code Quality|AI findings|it|them)\s+(?:(?:is|are|must|should|will|do|does|can|may)\s+)*(?:not|never)\s+(?:be\s+)?enabled\b'
        # "turn off AI findings" disables the findings only, so it counts for the AI-findings
        # verdict and never for the product: "turn off Code Quality AI findings" on a private
        # enablement still leaves paid Code Quality on.
        $aiDisabledWords = $disabledWords + '|\b(?:turn(?:s|ed)?|switch(?:es|ed)?|set)\s+off\s+(?:(?:paid\s+)?Code\s+Quality\s+)?AI findings\b'
        # One vocabulary for both halves: a clause is stripped when it says disabled in any
        # form the vocabulary accepts, so "not-configured" cannot survive the strip
        # and vouch for the product. The AI-findings verdict reads EVERY clause before a
        # "drift:" / "gap:" marker: a table row naming "AI findings enabled anywhere" as the
        # drift it reports is not an instruction to enable them, but a later instruction
        # ("keep it disabled; enable AI findings on public repositories") is.
        $aiMatches = @([regex]::Matches($line, $aiClausePattern))
        $aiClauses = @($aiMatches | ForEach-Object Value)
        $marker = [regex]::Match($line, '(?i)\b(?:drift|gap|non-compliant)\s*:')
        # Each mention is read with its governing verb: the text since the last clause boundary,
        # cut after its last conjunction, so "turn off AI findings and keep AI findings disabled"
        # reads "turn off AI findings ..." and "keep AI findings disabled", while in "keep Code
        # Quality disabled and enable AI findings" the second mention's verb is "enable".
        $withVerb = {
            param($m)
            $segment = ($line.Substring(0, $m.Index) -split '[.;,]')[-1]
            (($segment -split '(?i)\b(?:and|or|but|then|while)\b')[-1]) + $m.Value
        }
        $instructionMatches = @($aiMatches | Where-Object { -not $marker.Success -or $_.Index -lt $marker.Index })
        if (-not $instructionMatches.Count) { $instructionMatches = $aiMatches }
        $instructionClauses = @($instructionMatches | ForEach-Object { & $withVerb $_ })
        $withoutAiClause = $line
        foreach ($clause in $aiClauses) {
            if ($clause -match $disabledWords) { $withoutAiClause = $withoutAiClause.Replace($clause, '') }
        }
        $saysDisabled = $withoutAiClause -match $disabledWords
        $aiSaysDisabled = $instructionClauses.Count -gt 0 -and -not @($instructionClauses | Where-Object { $_ -notmatch $aiDisabledWords }).Count
        # Anchored on the VISIBILITY, not on the bare word: the public row of the estate
        # policy table contains "private vulnerability reporting", and matching that read
        # the public row as a private-enablement rule.
        $privateScope = '(?i)(private/internal|private or internal|private repositor\w*|internal repositor\w*)'
        if ($line -match $privateScope -and -not $saysDisabled) {
            throw "$Name enables paid Code Quality on private/internal repositories: $line"
        }
        $blanket = $line -match '(?i)(automatic(?:ally)?|by default|every visibility|all repositories)'
        if ($blanket -and $line -notmatch '(?i)\bpublic\b' -and -not $saysDisabled) {
            throw "$Name enables Code Quality with no visibility qualifier: $line"
        }
        if ($line -match '(?i)AI findings' -and -not $aiSaysDisabled) {
            throw "$Name enables Code Quality AI findings: $line"
        }
    }
}

function Test-PowerShellExamples {
    param([string]$Text)

    $problems = @()
    $blocks = [regex]::Matches($Text, '(?ms)^[ \t]*```powershell[ \t]*\r?\n(?<body>.*?)(?=^[ \t]*```[ \t]*$)')
    $commands = @($blocks | ForEach-Object { $_.Groups['body'].Value.Trim() })

    foreach ($command in $commands) {
        if ($command -match '\r?\n') {
            $problems += "PowerShell example is not one line: $command"
        }
    }

    if ($commands -notcontains '$repo = gh repo view --json nameWithOwner --jq .nameWithOwner') {
        $problems += 'PowerShell examples do not resolve the current repository'
    }
    if ($commands -notcontains '$pr = gh pr view --json number --jq .number') {
        $problems += 'PowerShell examples do not resolve the current pull request'
    }

    foreach ($command in $commands | Where-Object { $_ -match '^gh api\b' }) {
        if ($command -notmatch '^gh api(?: -X [A-Z]+)? "repos/\$repo(?:/[^" ]*)?"(?: |$)') {
            $problems += "gh api endpoint is not quoted and repository-resolved: $command"
        }
    }

    if (($commands -join "`n") -match 'OWNER/REPO|<n>|\{owner\}|\{repo\}') {
        $problems += 'PowerShell examples contain manual repository or pull-request placeholders'
    }

    $alertCommand = $commands | Where-Object { $_ -match 'code-scanning/alerts' } | Select-Object -First 1
    if ($alertCommand -notmatch 'refs/pull/\$pr/head') {
        $problems += 'Code scanning alert example does not use the resolved pull request number'
    }

    return $problems
}

$collapsedDependabotPattern = 'automated-security-fixes[^\r\n]*HTTP 204 means enabled|vulnerability alerts and automated security fixes[^|\r\n]*both return HTTP 204'

$forbidden = @{
    'scaffold-ci enables CodeQL for every repository' = $ci -match 'CodeQL \*\*default setup\*\* \| code scanning \| always'
    'scaffold-ci calls paid private features free' = $ci -match 'CodeQL and Code Quality are GitHub-side and free per commit'
    # These four used to FORBID public Code Quality enablement, when it was a paid opt-in at
    # every visibility. It is free on public repositories now, so public enablement is the
    # expected state and forbidding it would fail the correct policy. What replaces them is
    # the private half, which is still billed -- see the four entries below.
    'scaffold-ci enables Code Quality on private repositories' = $ci -match '(?i)private[^\r\n]*(enable|configure)[^\r\n]*Code Quality'
    'scaffold-repo enables Code Quality on private repositories' = $repo -match '(?i)private[^\r\n]*(enable|configure)[^\r\n]*Code Quality'
    'audit-ci expects Code Quality on private repositories' = $audit -match '(?i)private/internal:[^|\r\n]*Code Quality (configured|enabled)'
    'audit-github-estate enables Code Quality on private repositories' = $estate -match '(?i)Private or internal \|[^\r\n]*Keep Code Quality enabled'
    'scaffold-ci enables paid Code Quality by default' = $ci -match 'Enable paid Code Quality by default'
    'scaffold-ci enables Code Quality AI findings' = $ci -match '(?i)Code Quality AI findings[^\r\n]*enabled(?![^\r\n]*disabled)'
    'scaffold-ci mistakes a dynamic CodeQL workflow for default setup' = $ci -match 'dynamic/github-code-scanning/codeql[^\r\n]*(means|=)[^\r\n]*default setup'
    'audit-ci mistakes a dynamic CodeQL workflow for default setup' = $audit -match 'dynamic/github-code-scanning/codeql[^\r\n]*(means|=)[^\r\n]*default setup'
    'audit-ci collapses both Dependabot GET contracts to HTTP 204' = $audit -match $collapsedDependabotPattern
    'scaffold-ci collapses both Dependabot GET contracts to HTTP 204' = $ci -match 'Verify both endpoints return HTTP 204'
    'scaffold-repo provisions Copilot review' = $repo -match 'ruleset-copilot-review\.json'
    'scaffold-repo enables secret scanning estate-wide' = $repo -match 'Secret scanning \+ push protection\*\* — on for the estate'
    'scaffold-repo expects two rulesets' = $repo -match 'two active rulesets'
    'scaffold-dotnet implies CodeQL is universal' = $dotnet -match '\(ci\.yml, mutation\.yml, CodeQL\)'
    'scaffold-ci gives user-facing Bash commands' = $security -match '(?m)^[ \t]*```bash[ \t]*$'
}

foreach ($entry in $forbidden.GetEnumerator()) {
    if ($entry.Value) { throw $entry.Key }
}

$powerShellProblems = Test-PowerShellExamples $security
if ($powerShellProblems.Count -gt 0) { throw ($powerShellProblems -join "`n") }

foreach ($mutation in @(
    @{ Name = 'a hard-coded repository'; From = '$repo = gh repo view --json nameWithOwner --jq .nameWithOwner'; To = '$repo = ''OWNER/REPO''' },
    @{ Name = 'an unquoted gh endpoint'; From = '"repos/$repo/code-scanning/default-setup"'; To = 'repos/{owner}/{repo}/code-scanning/default-setup' },
    @{ Name = 'a manual pull request number'; From = 'refs/pull/$pr/head'; To = 'refs/pull/<n>/head' }
)) {
    $mutated = $security.Replace($mutation.From, $mutation.To)
    if ($mutated -eq $security) { throw "PowerShell red check '$($mutation.Name)' did not modify the reference" }
    if ((Test-PowerShellExamples $mutated).Count -eq 0) {
        throw "PowerShell red check failed: $($mutation.Name) was accepted"
    }
}

$collapsedAuditMutation = $audit + "`n| **Dependabot security settings** | vulnerability alerts and automated security fixes both return HTTP 204 | gap |"
if ($collapsedAuditMutation -notmatch $collapsedDependabotPattern) {
    throw 'Collapsed Dependabot audit contract mutation was not rejected'
}

Assert-NoUnsafeCodeQualityDefault 'scaffold-ci' $ci
if ($null -ne $repo) { Assert-NoUnsafeCodeQualityDefault 'scaffold-repo' $repo }
Assert-NoUnsafeCodeQualityDefault 'audit-ci' $audit
Assert-NoUnsafeCodeQualityDefault 'audit-github-estate' $estate
if ($null -ne $agents) { Assert-NoUnsafeCodeQualityDefault 'AGENTS.md' $agents }

# RED CHECKS for the guard itself. The old mutation was "Public repositories enable paid
# Code Quality automatically", which the current guard correctly ACCEPTS -- public
# enablement is the expected state now -- so it would have silently stopped testing
# anything. Each mutation below must still be rejected.
foreach ($mutation in @(
    @{ Name = 'private enablement'; Line = 'Private repositories enable paid Code Quality automatically.' },
    @{ Name = 'internal enablement'; Line = 'Configure Code Quality on internal repositories too.' },
    @{ Name = 'visibility-agnostic default'; Line = 'Enable Code Quality by default for all repositories.' },
    @{ Name = 'AI findings'; Line = 'Leave Code Quality AI findings enabled so Copilot can comment.' },
    # The only "disabled" on this line belongs to the AI-findings clause; the product
    # itself is being enabled on private repositories. The guard read that one word as
    # the whole line being a disablement and accepted it.
    @{ Name = 'private enablement masked by AI-findings clause'; Line = 'Private repositories enable Code Quality with AI findings disabled.' },
    # The mirror image: the only "disabled" belongs to the PRODUCT clause, and the
    # AI-findings clause enables them. The guard read the whole line for the AI check
    # and accepted it. (code review.)
    @{ Name = 'AI-findings enablement masked by the product clause'; Line = 'Enable Code Quality AI findings; keep Code Quality disabled on private repositories.' },
    # R-D M40: a clause ending in "not-configured" survived the strip and vouched for the product.
    @{ Name = 'private enablement masked by a not-configured AI-findings clause'; Line = 'Private repositories enable Code Quality with AI findings not-configured.' },
    # R-D XL24: a bare "off" anywhere excused the line.
    @{ Name = 'private enablement excused by an unrelated off'; Line = 'Private repositories enable Code Quality and kick off a baseline scan.' },
    # "turn off" matched the verb form of the vocabulary with nothing tied to Code Quality.
    @{ Name = 'private enablement excused by an unrelated turn off'; Line = 'Enable Code Quality on private repositories and turn off notifications.' },
    # Only the FIRST AI-findings clause was read, so a later one enabling them was accepted.
    @{ Name = 'a later AI-findings clause enables them'; Line = 'Keep Code Quality AI findings disabled; enable AI findings on public repositories.' },
    # Code review: with no punctuation between them, the first clause swallowed the second.
    @{ Name = 'a later AI-findings mention in the same clause enables them'; Line = 'Keep Code Quality AI findings disabled and enable AI findings on public repositories.' },
    @{ Name = 'private enablement excused by turning off only the AI findings'; Line = 'Enable Code Quality on private repositories and turn off Code Quality AI findings.' },
    # Second review: "off" with another object after the product name, and a negative status
    # whose subject is not Code Quality, each excused an enablement.
    @{ Name = 'private enablement excused by turning off Code Quality notifications'; Line = 'Enable Code Quality on private repositories and turn off Code Quality notifications.' },
    @{ Name = 'AI-findings enablement excused by an unrelated not enabled'; Line = 'Enable Code Quality with AI findings when notifications are not enabled.' }
)) {
    $rejected = $false
    try {
        Assert-NoUnsafeCodeQualityDefault 'mutation check' ($ci + "`n" + $mutation.Line)
    } catch {
        $rejected = $true
    }
    if (-not $rejected) { throw "Unsafe Code Quality mutation was not rejected: $($mutation.Name)" }
}
# ...and the tightened "off" must still read real disablements as disablements.
foreach ($line in @(
    'Code Quality: public enabled, AI findings disabled; private/internal off.',
    'Enable Code Quality on public repositories and keep it turned off on private repositories.',
    'Configure Code Quality on public repositories with AI findings off.',
    'Enable Code Quality on public repositories and turn off Code Quality on private repositories.',
    'Code Quality AI findings disabled; AI findings must not be enabled on public repositories.',
    'Enable Code Quality on public repositories and turn off AI findings and keep AI findings disabled.'
)) {
    Assert-NoUnsafeCodeQualityDefault 'accepted-line check' $line
}

foreach ($required in @(
    @{ Name = 'scaffold-ci public free policy'; Text = $ci; Pattern = '(?m)^\| Public \|[^\r\n]*CodeQL[^\r\n]*secret scanning[^\r\n]*push protection[^\r\n]*Code Quality[^\r\n]*AI findings disabled' },
    @{ Name = 'scaffold-ci private paid Code Quality stays off'; Text = $ci; Pattern = '(?m)^\| Private or internal \|[^\r\n]*Keep paid Code Quality disabled' },
    @{ Name = 'scaffold-ci retains the accepted visibility policy'; Text = $ci; Pattern = 'accepted policy enables Code Quality on public repositories and keeps it\s+off on private/internal repositories' },
    @{ Name = 'scaffold-ci qualifies the universal pricing premise'; Text = $ci; Pattern = 'UNVERIFIED: that public Code Quality has a universal pricing exemption.*Refuted if' },
    @{ Name = 'scaffold-ci enforced public access scope'; Text = $ci; Pattern = 'Selected repositories.*exactly the public repositories.*Enforce access' },
    @{ Name = 'scaffold-ci CodeQL setup verification'; Text = $ci; Pattern = 'GET.*code-scanning/default-setup.*state.*configured' },
    @{ Name = 'scaffold-ci vulnerability-alerts GET contract'; Text = $ci; Pattern = 'GET.{0,100}?vulnerability-alerts.{0,100}?HTTP 204' },
    @{ Name = 'scaffold-ci automated-security-fixes GET contract'; Text = $ci; Pattern = 'GET.{0,100}?automated-security-fixes.{0,150}?HTTP 200.{0,100}?enabled.{0,50}?true.{0,100}?paused.{0,50}?false' },
    @{ Name = 'scaffold-ci automated-security-fixes noncompliant states'; Text = $ci; Pattern = 'automated-security-fixes.{0,250}?404.{0,100}?enabled.{0,50}?false.{0,100}?paused.{0,50}?true.{0,100}?non-compliant' },
    @{ Name = 'scaffold-ci private security policy'; Text = $ci; Pattern = 'Private or internal.*disable.*Code Security.*secret scanning' },
    @{ Name = 'scaffold-ci live public push-protection verification'; Text = $security; Pattern = 'verify.*live.*security_and_analysis\.secret_scanning_push_protection.*enabled' },
    @{ Name = 'scaffold-ci disables Code Quality AI'; Text = $ci; Pattern = 'Code Quality AI.*disabled' },
    @{ Name = 'audit-ci visibility-aware CodeQL'; Text = $audit; Pattern = 'CodeQL.*public' },
    @{ Name = 'audit-ci visibility-split Code Quality'; Text = $audit; Pattern = 'GitHub security surfaces.*public:.*Code Quality configured.*every visibility: Code Quality AI findings disabled.*private/internal:.*paid Code Quality disabled' },
    @{ Name = 'audit-ci organization Code Quality gate'; Text = $audit; Pattern = 'Repository access.*enforcement.*free on\s+public repositories and paid on private/internal' },
    @{ Name = 'audit-ci keeps the UI-only org access gap'; Text = $audit; Pattern = 'Code Quality org access: UNVERIFIED \(UI-only, awaiting operator\)' },
    @{ Name = 'audit-ci CodeQL setup verification'; Text = $audit; Pattern = 'GET.*code-scanning/default-setup.*state.*configured' },
    @{ Name = 'audit-ci vulnerability-alerts GET contract'; Text = $audit; Pattern = 'vulnerability-alerts.{0,150}?HTTP 204' },
    @{ Name = 'audit-ci automated-security-fixes GET contract'; Text = $audit; Pattern = 'automated-security-fixes.{0,150}?HTTP 200.{0,100}?enabled.{0,50}?true.{0,100}?paused.{0,50}?false' },
    @{ Name = 'audit-ci automated-security-fixes noncompliant states'; Text = $audit; Pattern = 'automated-security-fixes.{0,250}?404.{0,100}?enabled.{0,50}?false.{0,100}?paused.{0,50}?true.{0,100}?non-compliant' },
    @{ Name = 'audit estate organization Code Quality gate'; Text = $estate; Pattern = 'organization Repository access and enforcement before any Code Quality\s+mutation' },
    @{ Name = 'audit estate enforced public access scope'; Text = $estate; Pattern = 'Selected repositories.*exactly the public repositories.*Enforce access' },
    @{ Name = 'audit estate keeps No repositories as verified-not-compliant'; Text = $estate; Pattern = 'No repositories.*verified reading, not a compliant one' },
    @{ Name = 'audit estate visibility-split Code Quality'; Text = $estate; Pattern = '(?m)^\| Public \|[^\r\n]*free public CodeQL and Secret Protection[^\r\n]*Code Quality under the estate''s accepted public policy[^\r\n]*Keep Code Quality enabled on public repositories' },
    @{ Name = 'audit estate private Code Quality stays off'; Text = $estate; Pattern = '(?m)^\| Private or internal \|[^\r\n]*keep Code Quality disabled' },
    @{ Name = 'scaffold-repo organization Code Quality gate'; Text = $repo; Pattern = 'Repository\s+access and enforcement before any repository setup change' },
    @{ Name = 'scaffold-repo private paid Code Quality stays off'; Text = $repo; Pattern = 'Keep paid Code\s+Quality disabled on private/internal repositories' },
    @{ Name = 'scaffold-repo public free Code Quality'; Text = $repo; Pattern = 'free deterministic Code Quality with AI findings disabled' },
    @{ Name = 'quality gate checks only applicable surfaces'; Text = $gate; Pattern = 'expected enabled tool with no result is a gap.*disabled.*N/A' },
    @{ Name = 'scaffold-dotnet delegates visibility policy'; Text = $dotnet; Pattern = 'visibility-appropriate' }
)) {
    # A $null Text is an absent sibling skill (see the scaffold-repo skip above), not a
    # missing assertion: -notmatch against $null would fail every such row spuriously.
    if ($null -eq $required.Text) { continue }
    if ($required.Text -notmatch "(?is)$($required.Pattern)") {
        throw "Missing $($required.Name)"
    }
}

if ($null -ne $agents -and $agents -notmatch '(?is)Public\s+CodeQL and Secret Protection remain enabled.*so is Code Quality.*enabled on public repositories.*disabled\s+on\s+private/internal.*AI findings stay disabled at every visibility') {
    throw 'Global AGENTS.md contradicts the mandatory public baseline or the Code Quality visibility split'
}

$copilotAsset = Join-Path $root 'scaffold-repo' 'assets' 'ruleset-copilot-review.json'
if (Test-Path $copilotAsset) {
    throw 'Obsolete Copilot review ruleset asset still exists'
}

'GitHub security visibility policy OK'
