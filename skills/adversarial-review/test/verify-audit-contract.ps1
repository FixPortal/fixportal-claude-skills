$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$main = Get-Content (Join-Path $root 'SKILL.md') -Raw
$normalizedMain = $main -replace '\s+', ' '
$driver = Get-Content (Join-Path $root 'run-review.ps1') -Raw
$manifest = Get-Content (Join-Path $root 'reviewers.json') -Raw | ConvertFrom-Json
$methodology = Get-Content (Join-Path $root 'docs' 'METHODOLOGY-v2.md') -Raw
$telemetry = Get-Content (Join-Path $root 'emit-review-telemetry.ps1') -Raw
$gemini = Get-Content (Join-Path $root 'gemini-review.ps1') -Raw
$aggregate = Get-Content (Join-Path $root 'aggregate-and-emit.ps1') -Raw
$codex = Get-Content (Join-Path $root 'codex-review.ps1') -Raw
$openai = Get-Content (Join-Path $root 'openai-review.ps1') -Raw
$artefacts = Get-Content (Join-Path $root 'docs' 'run-artefacts.md') -Raw

# SKILL.md §4 gives a repoAccess:false verifier two routes (diff and context files, or a
# detached-commit worktree). run-artefacts.md used to call the hermetic route "the only
# route open" to such a member, so the two contracts contradicted each other. Adversarial
# review 20260922T222201Z, judge-observed JO-06.
function Test-VerifierRouteContract([string] $Skill, [string] $Artefacts) {
    $flatSkill = $Skill -replace '\s+', ' '
    $flatArtefacts = $Artefacts -replace '\s+', ' '
    if ($flatSkill -notmatch 'detached-commit `git worktree`') { return 'SKILL.md no longer offers the detached-commit worktree route' }
    if ($flatArtefacts -match '(?i)only route open to a `?repoAccess: ?false`? member') { return 'run-artefacts.md calls the hermetic route the only route for repoAccess:false' }
    if ($flatArtefacts -notmatch '(?i)repoAccess: false` member may take this route only through a detached-commit') {
        return 'run-artefacts.md does not state the detached-commit worktree route for repoAccess:false members'
    }
    $null
}
$routeProblem = Test-VerifierRouteContract $main $artefacts
if ($routeProblem) { throw $routeProblem }
$preFix = '- **Hermetic route** (diff and context files, no checkout — the only route open to a `repoAccess: false` member): record the diff sha256.'
if (-not (Test-VerifierRouteContract $main $preFix)) { throw 'verifier-route red check passed the pre-fix wording; the guard is inert' }

# A clean reviewer can attach its heading to the preceding narration when a CLI
# omits a newline. That is still participation, not vendor absence.
$findingPatternMatch = [regex]::Match($driver, "\`$script:FindingHeading\s*=\s*'([^']+)'")
if (-not $findingPatternMatch.Success) { throw 'run-review.ps1 no longer declares FindingHeading in a readable form' }
$findingPattern = $findingPatternMatch.Groups[1].Value
if ('I inspected the diff.### NO FINDINGS' -notmatch $findingPattern) {
    throw 'FindingHeading must admit a heading attached to preceding reviewer narration'
}
foreach ($nonHeading in 'the C# compiler', '$x  # keep', 'C# `# comment`') {
    if ($nonHeading -match $findingPattern) { throw "FindingHeading must not match an inline hash: $nonHeading" }
}
if ($findingPattern -notmatch '\^') { throw 'FindingHeading must anchor markdown headings at line start or sentence punctuation' }
if ($driver -notmatch 'function Get-ReviewHeadingLineNumbers' -or
    $driver -notmatch '\$fenceChar\s*=\s*\$null' -or
    $driver -notmatch '\$fenceLength\s*=\s*0' -or
    $driver -notmatch '\[regex\]::Escape\(\$fenceChar\).*?\$fenceLength') {
    throw 'heading parsing must skip markdown fenced code blocks'
}
if ($driver -notmatch '(?s)\$body\s*=\s*\$text\.Trim\(\).*?\$refusal' -or
    $driver -notmatch '\$onTopic\s*=\s*\$body\s*-match' -or
    $driver -notmatch 'Matched\s*=\s*-not \[string\]::IsNullOrWhiteSpace\(\$body\)') {
    throw 'run-review.ps1 must admit non-empty non-refusal prose replies as participation'
}

# Repo-aware Codex is an explicit capability, not the default routing shape.
if ($codex -notmatch '(?m)^\s*\[switch\]\s*\$AllowRepoCommands') {
    throw 'codex-review.ps1 must require an explicit -AllowRepoCommands opt-in for -RepoPath'
}
if ($codex -notmatch '\$RepoPath\s*-and\s*-not\s*\$AllowRepoCommands') {
    throw 'codex-review.ps1 must reject -RepoPath without -AllowRepoCommands'
}
if ($driver -notmatch '\$r\.allowRepoCommands' -or $driver -match '\$caps -contains ''AllowRepoCommands''\) \{\s*\$a \+= ''-AllowRepoCommands''') {
    throw 'run-review.ps1 must gate Codex repo commands on an explicit manifest flag'
}
if ($driver -notmatch 'gh pr diff \$Target --repo \$repoSlug') {
    throw 'PR diffs must name the repository resolved from the supplied -RepoPath'
}
if ($driver -match 'git -C \$RepoPath diff @(?:diffArgs|wtArgs|compactArgs) 2>&1') {
    throw 'git diff stderr must not be merged into and hashed as the review evidence text'
}
# Every repo-aware Codex record, not only seat X: codex-review.ps1 exits 2 on -RepoPath
# without the opt-in, so a judgeAudit/verifier pool member or a fixture seat lacking it
# dies before reviewing. The pinned fixture is held to the same contract as the live file.
$pinned = Get-Content (Join-Path $root 'test' 'fixtures' 'pinned-reviewers.json') -Raw | ConvertFrom-Json
foreach ($m in @($manifest, $pinned)) {
    $codexRecords = @($m.reviewers) + @($m.roles.PSObject.Properties.Value | ForEach-Object { $_; @($_.pool) }) |
        Where-Object { $_ -and $_.wrapper -eq 'codex' -and $_.repoAccess }
    foreach ($rec in $codexRecords) {
        if (-not $rec.allowRepoCommands) {
            throw "repo-aware Codex record '$($rec.id ?? "$($rec.vendor) pool member")' must set allowRepoCommands, or codex-review.ps1 exits 2 on -RepoPath"
        }
    }
}
foreach ($refusalToken in 'will\s+not', 'won''''t', 'decline(?:d)?\s+to', 'not\s+going\s+to', 'be\s+reviewed') {
    if ($driver -notmatch [regex]::Escape($refusalToken)) {
        throw "refusal detection must cover '$refusalToken'"
    }
}
if ($driver -notmatch [regex]::Escape("model-routing-traps.md") -or
    $driver -notmatch [regex]::Escape('Routing trap reminders:')) {
    throw 'run-review.ps1 must print the relevant model-routing trap headings at startup'
}

# Telemetry decisions are controller-owned; methodology retains rationale only.
# Cardinality is per VENDOR-participant, not per manifest seat: -Reviewer is a
# vendor-level ValidateSet and the Observatory upserts on (runId, reviewer, role),
# so two Anthropic seats cannot hold two rows -- the second overwrites the first.
foreach ($needle in 'one telemetry row per **vendor-participant**',
                    'merge into one `anthropic/reviewer` row',
                    'Multi-chunk runs use `aggregate-and-emit.ps1`',
                    'call `emit-review-telemetry.ps1` after Phase 4',
                    'work directory''s `-RunId`',
                    'Include `Role`',
                    '(runId, reviewer, role)',
                    "vendor's own Phase-1 findings",
                    'derive ownership from pooled provenance',
                    'never let accepted exceed raised',
                    'canonical model registry',
                    'preserve `costUnknown=true`',
                    'render `UNKNOWN`',
                    'Disclose every metered fallback') {
    if ($normalizedMain -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md is missing its controller-owned telemetry rule: $needle"
    }
}
foreach ($duplicatedRule in '(?m)^- Emit one row',
                            '(?m)^- `IssuesAccepted` credits',
                            '(?m)^- Resolve moving aliases') {
    if ($methodology -match $duplicatedRule) {
        throw "METHODOLOGY-v2.md duplicates a controller-owned telemetry imperative: $duplicatedRule"
    }
}

# Cost policy belongs only to SKILL.md. Match the live semantic rule rather than a
# Markdown shape so moving it from a bullet into prose cannot bypass this ownership
# check. Historical explanation may mention the registry or unknown-cost state alone;
# it fails only when it restates the operative lookup/preservation relationship.
$duplicatedCostPolicies = [ordered]@{
    'canonical-registry lookup' = '(?is)(?:(?:prices?|model aliases?).{0,100}(?:come only from|must (?:be )?resolve(?:d)? (?:only )?(?:through|from)|are resolve(?:d)? (?:only )?(?:through|from))|resolve(?: moving)? (?:model aliases and )?prices? (?:only )?(?:through|from)).{0,80}canonical model registry'
    'unknown-cost preservation' = '(?is)(?:absent|missing|unresolved) prices?.{0,100}(?:remains?|must (?:remain|be preserved|be set)|is (?:preserved|set)).{0,80}costUnknown=true.{0,140}(?:renders?|must render|is rendered).{0,60}UNKNOWN'
}
foreach ($entry in $duplicatedCostPolicies.GetEnumerator()) {
    if ($methodology -match $entry.Value) {
        throw "METHODOLOGY-v2.md duplicates the controller-owned $($entry.Key) rule"
    }
}
foreach ($liveRule in 'Prices come only from the canonical model registry.',
                      'Resolve moving model aliases and prices through the canonical model registry.',
                      'An absent price remains costUnknown=true and renders UNKNOWN.',
                      'Missing prices must be preserved as costUnknown=true and must render UNKNOWN.') {
    if (-not ($duplicatedCostPolicies.Values | Where-Object { $liveRule -match $_ })) {
        throw "The semantic duplication guard misses a live cost-policy restatement: $liveRule"
    }
}
foreach ($historical in 'In v2, prices were resolved only through the canonical model registry.',
                        'An absent price was preserved as costUnknown=true and rendered UNKNOWN in the v2 design.') {
    foreach ($entry in $duplicatedCostPolicies.GetEnumerator()) {
        if ($historical -match $entry.Value) {
            throw "The $($entry.Key) guard incorrectly rejects historical rationale: $historical"
        }
    }
}

# A smell alarm, not the contract. What must not happen is prompt bodies and roster
# facts being mirrored here, and the needle checks below enforce that DIRECTLY - this
# count is the blunt proxy sitting on top of them. It was 1200, which the file reached
# with four words to spare, and a tripwire that tight buys nothing: the next legitimate
# addition either deletes load-bearing content to make room or silently bumps the
# number. Raised to 1400 once; the file then sat at 1397, three words under, so the
# same squeeze had returned.
#
# Raised to 1900 by the 20260905T175252Z remediation. The instruction there was to look
# for mirrored canonical detail FIRST: every JSON artefact shape moved out to
# docs/run-artefacts.md, and the needle checks below (plus the stale-detail list) still
# hold the direct contract. What remains is new normative rule text that eight verified
# findings required in the controller itself -- the pre-flight gate, the dirty-target
# worktree rule, non-PR tier derivation, REFUTED's disposition, telemetry cardinality.
# Deleting operator-facing rules to satisfy a proxy would trade a real control for a
# tidy number. If 1900 is approached, extract shapes and tables again before arguing.
$words = ([regex]::Matches($main, '\b[\w/-]+\b')).Count
if ($words -ge 1900) { throw "adversarial-review/SKILL.md is $words words; canonical prompts/roster must stay external" }
foreach ($stale in 'Gemini and GPT', 'G+X', 'claude-sonnet-4-6',
                      'claude-opus-4-8', '### Audit-mode preamble') {
    if ($main -match [regex]::Escape($stale)) { throw "SKILL.md retains duplicated/stale detail: $stale" }
}
foreach ($needle in 'PR targets do not support pathspecs', 'repoAccess:false',
                     'Resolve-TelemetryModel', 'Get-BlendedRatePerMillion') {
    if ($driver -notmatch [regex]::Escape($needle)) { throw "run-review.ps1 missing contract: $needle" }
}
# The registry path must be built with Join-Path segments, not a backslash literal. This
# needle used to be the literal 'model-registry\registry.json', which pinned the
# non-portable spelling in place: making the path portable BROKE the test guarding it.
foreach ($piece in "'model-registry'", "'registry.json'") {
    if ($driver -notmatch [regex]::Escape($piece)) { throw "run-review.ps1 must build the registry path from Join-Path segments: $piece" }
}
if ($driver -match [regex]::Escape('model-registry\registry.json')) {
    throw 'run-review.ps1 still embeds a backslash registry path; it fails soft to $null off Windows'
}
if ($aggregate -match [regex]::Escape('model-registry\registry.json')) {
    throw 'aggregate-and-emit.ps1 still embeds a backslash registry path'
}

# A wrapper with no hard per-invocation read-only mode must never be granted repo access
# anywhere in the manifest. Kimi's reviewer entry is deliberately repoAccess:false, but a
# ROLE-WIDE flag re-granted it as a Phase-4 verifier - write access to the very tree the
# phase exists to produce trustworthy evidence about.
# A repo-aware wrapper that runs the model in a SCRATCH working directory must name the
# resolved repository root in the prompt. claude-review.ps1 deliberately runs from a
# throwaway cwd so the repo's own CLAUDE.md cannot bias the review, and exposes the tree
# via --add-dir only - so without that line the model is handed repo-relative finding
# paths it has no way to resolve, reads an empty cwd, and reports the cited code as
# ABSENT. Measured 2026-09-07 (run 20260907T132023Z): two Phase-4 verifications returned
# INDETERMINATE "no such file" against a clean tree that contained every cited path; the
# same wrapper and model CONFIRMED both once the root was stated in the instruction.
# Refuted if: a claude-review.ps1 run with -RepoPath resolves a repo-relative path from
# its scratch cwd without the prompt naming the root.
# -cnotmatch, NOT -notmatch: PowerShell's -match is case-INSENSITIVE, so the lowercase
# "Repository root." in this wrapper's own .PARAMETER RepoPath doc comment satisfied the
# case-blind form and the assertion passed while the defect was still present. The token
# asserted here is the upper-case one the wrapper emits into the prompt.
$claudeWrapper = Get-Content (Join-Path $root 'claude-review.ps1') -Raw
if ($claudeWrapper -cnotmatch 'REPOSITORY ROOT:') {
    throw 'claude-review.ps1 runs from a scratch cwd but never names the repository root in the prompt; a repo-aware reviewer cannot resolve repo-relative paths'
}

$noSandbox = @($manifest.noSandboxWrappers)
if (-not $noSandbox) { throw 'reviewers.json must declare noSandboxWrappers' }
foreach ($r in @($manifest.reviewers) + @($manifest.alternates)) {
    if ($noSandbox -contains $r.wrapper -and $r.repoAccess) {
        throw "reviewer '$($r.id)' uses no-sandbox wrapper '$($r.wrapper)' with repoAccess:true"
    }
}
foreach ($roleName in $manifest.roles.PSObject.Properties.Name) {
    if ($roleName -eq '_comment') { continue }
    $role = $manifest.roles.$roleName
    if ($role.wrapper -and $noSandbox -contains $role.wrapper -and $role.repoAccess) {
        throw "role '$roleName' uses no-sandbox wrapper '$($role.wrapper)' with repoAccess:true"
    }
    # A role carrying a pool must NOT also carry a role-wide repoAccess: that is exactly the
    # shape that promoted every member to repo-aware regardless of its own posture.
    if ($role.pool) {
        if ($null -ne $role.PSObject.Properties['repoAccess']) {
            throw "role '$roleName' has a pool AND a role-wide repoAccess; access must be declared per pool member"
        }
        foreach ($member in @($role.pool)) {
            if ($member -isnot [System.Management.Automation.PSCustomObject]) {
                throw "role '$roleName' pool member '$member' is a bare string; it must declare its own repoAccess"
            }
            if (-not $member.vendor -or (-not $member.select -and -not $member.model)) {
                throw "role '$roleName' pool member '$($member.wrapper)' must declare its vendor and model selection"
            }
            if ($noSandbox -contains $member.wrapper -and $member.repoAccess) {
                throw "role '$roleName' pool member '$($member.wrapper)' has no read-only mode but carries repoAccess:true"
            }
        }
    }
}
if ($driver -match 'return (6\.0|20\.0|30\.0)') { throw 'run-review.ps1 retains hardcoded blended model rates' }
foreach ($needle in 'Resolve-ModelSelector', 'Get-RegistryCost', 'judgeCostEstimated') {
    if ($aggregate -notmatch [regex]::Escape($needle)) { throw "judge aggregation missing current-model contract: $needle" }
}

# "Cost unknown" must survive all the way to the Observatory, not stop at metrics.json:
# a bare 0.0 there is indistinguishable from a genuinely free subscription-backed call.
$emitParams = (Get-Command (Join-Path $root 'emit-review-telemetry.ps1')).Parameters
if (-not $emitParams.ContainsKey('CostUnknown')) {
    throw 'emit-review-telemetry.ps1 has no -CostUnknown parameter, so unknown cost reaches the dashboard as 0.0'
}
# It MUST be a switch. Callers invoke through `pwsh -File`, where every argument is a
# string, and a [bool] parameter refuses a string outright ("Cannot convert value
# System.String to type System.Boolean") for "False"/"True"/"1"/"0" alike - so a [bool]
# here fails the entire emit call the moment the flag is passed.
if ($emitParams['CostUnknown'].ParameterType -ne [switch]) {
    throw "emit-review-telemetry.ps1 -CostUnknown must be [switch], not $($emitParams['CostUnknown'].ParameterType); a [bool] cannot bind through pwsh -File"
}
if ($emitParams['CostUnknown'].ParameterType -eq [switch] -and $aggregate -notmatch '\$v -is \[bool\]') {
    throw 'Invoke-Emit must render boolean values as bare switch flags; "-Flag False" cannot bind and would invert the meaning'
}
foreach ($needle in 'CostUnknown = [bool]$r.costUnknown', 'CostUnknown = $judgeCostUnknown') {
    if ($aggregate -notmatch [regex]::Escape($needle)) { throw "aggregate-and-emit.ps1 does not forward costUnknown to emission: $needle" }
}
if ($driver -notmatch 'costUnknown\s+=') { throw 'run-review.ps1 does not record costUnknown in metrics.json' }
foreach ($wrapper in @{ 'codex-review.ps1' = $codex; 'openai-review.ps1' = $openai }.GetEnumerator()) {
    if ($wrapper.Value -match "(?m)^\s*'gpt-5\.6-sol'\s*=") {
        throw "$($wrapper.Key) privately prices unpriced registry model gpt-5.6-sol"
    }
}
if ($main -notmatch [regex]::Escape('~/.agents/notes/model-routing-traps.md')) {
    throw 'SKILL.md must read the canonical model-routing traps before repository-aware Codex routing'
}

foreach ($wrapperName in ($manifest.wrappers.PSObject.Properties | Where-Object Name -ne '_comment' | ForEach-Object Value)) {
    $params = (Get-Command (Join-Path $root $wrapperName)).Parameters.Keys
    foreach ($required in 'Instruction', 'DiffPath', 'FindingsPath', 'ContextPath', 'Model') {
        if ($params -notcontains $required) { throw "$wrapperName lacks required minimum parameter -$required" }
    }
    # Seats resolve their model from the canonical registry (reviewers.json
    # 'select'), so no wrapper may pin a -Model default: a hardcoded id silently
    # ages into a superseded model on a direct invocation.
    $wrapperBody = Get-Content (Join-Path $root $wrapperName) -Raw
    if ($wrapperBody -match "(?m)\`$Model\s*=\s*'") {
        throw "$wrapperName hardcodes a -Model default; seats resolve through the model registry, so -Model stays mandatory with no pinned id"
    }
}
# The appended per-finding STYLE directive is a Phase-1 shape. In Phase 2 (-FindingsPath)
# the brief owns the F#-verdict format, and a per-finding directive AFTER it contradicts it.
foreach ($wrapperName in 'codex-review.ps1', 'gemini-review.ps1', 'openai-review.ps1') {
    if ((Get-Content (Join-Path $root $wrapperName) -Raw) -notmatch '(?s)if \(-not \$FindingsPath\) \{[^}]*STYLE REQUIREMENT') {
        throw "$wrapperName appends the Phase-1 STYLE REQUIREMENT in Phase 2 too; it must sit inside if (-not `$FindingsPath)"
    }
}
foreach ($wrapperName in 'kimi-review.ps1', 'grok-review.ps1') {
    if ((Get-Content (Join-Path $root $wrapperName) -Raw) -notmatch 'Context file not found') {
        throw "$wrapperName must fail when a requested context file is missing"
    }
}
foreach ($wrapperName in 'agy-review.ps1', 'kimi-review.ps1', 'grok-review.ps1') {
    if ((Get-Content (Join-Path $root $wrapperName) -Raw) -notmatch 'INDEX\.txt') {
        throw "$wrapperName must preserve original context paths in context/INDEX.txt"
    }
}
if ((Get-Content (Join-Path $root 'grok-review.ps1') -Raw) -notmatch 'non-retryable HTTP 402') {
    throw 'grok-review.ps1 must stop immediately on HTTP 402'
}

# Every wrapper an ENABLED reviewer can actually reach - primary or declared fallback -
# must be pre-flightable, because pre-flight is what keeps an unauthenticated CLI from
# being discovered mid-fan-out, inside a paid parallel round.
$reachable = @($manifest.reviewers | Where-Object { $_.enabled } | ForEach-Object { $_.wrapper; $_.fallbackWrapper }) |
    Where-Object { $_ } | Sort-Object -Unique
foreach ($w in $reachable) {
    $file = $manifest.wrappers.$w
    if (-not $file) { throw "enabled reviewer references undeclared wrapper '$w'" }
    $body = Get-Content (Join-Path $root $file) -Raw
    if ($body -notmatch '(?m)^\s*PREFLIGHT_COMMAND:\s*\S') { throw "$file declares no PREFLIGHT_COMMAND" }
    if ($body -notmatch '(?m)^\s*PREFLIGHT_SUCCESS:\s*\S') { throw "$file declares no PREFLIGHT_SUCCESS" }
}

# The OpenAI pre-flight probe must keep its inner command SINGLE-quoted. Double-quoted,
# the invoking shell expands the key before the child runs: the child gets a ParserError
# and the literal credential lands on its command line, so the only declared OpenAI
# fallback reads as permanently unavailable AND leaks the key exactly when one is set.
if ($openai -match 'PREFLIGHT_COMMAND:[^\r\n]*-Command\s+"') {
    throw 'openai-review.ps1 pre-flight uses a double-quoted inner command; the invoking shell expands $env:OPENAI_API_KEY onto the child command line'
}
if ($openai -notmatch "PREFLIGHT_COMMAND:[^\r\n]*-Command\s+'[^']*IsNullOrWhiteSpace\(\`$env:OPENAI_API_KEY\)'") {
    throw 'openai-review.ps1 pre-flight must single-quote the in-child key test'
}

if ($methodology -match '~/.claude/skills/adversarial-review|own `default_model`|unchanged, uniform') {
    throw 'methodology retains stale canonical-home, Kimi-default, or uniform-contract wording'
}
if ($telemetry -notmatch 'own Phase-1 findings' -or $telemetry -match 'credit all four vendors') {
    throw 'telemetry help must use own-finding attribution, not consensus credit'
}
foreach ($path in 'claude-review.ps1', 'gemini-review.ps1', 'openai-review.ps1', 'emit-review-telemetry.ps1') {
    $help = (Get-Content (Join-Path $root $path) -Raw) -split '#>', 2 | Select-Object -First 1
    if ($help -match '(?m)^\s+pwsh .+`\s*$') { throw "$path exposes a backtick-continued copy/paste example" }
}

if ($gemini -notmatch 'NewGuid\(\).*paused|paused\.\$PID.*NewGuid' -or
    $gemini -match "oauth_creds\.json\.paused'" -or
    $gemini -match 'restore.*SilentlyContinue') {
    throw 'gemini OAuth shadowing must use a unique backup and strict restore'
}

# Every vendor the manifest can emit telemetry for MUST be in the -Reviewer ValidateSet.
# This drift is silent end to end: aggregate-and-emit.ps1 keys $byReviewer by vendor and
# passes the key through as -Reviewer, a missing vendor fails parameter binding in the
# subprocess, and that caller only Write-Warnings on a non-zero exit -- so the run
# succeeds and the vendor's raised/accepted counts are lost for good. Caught on PR #194,
# where seat R (xai) was added while the ValidateSet still listed four vendors.
# Anchored to the DECLARATION preceding `$Reviewer`, not to any mention of the vendor
# name: this file and the script both name every vendor in prose, so a substring search
# would read the documentation as compliance.
$telemetrySource = Get-Content (Join-Path $root 'emit-review-telemetry.ps1') -Raw
if ($telemetrySource -notmatch '(?s)\[ValidateSet\(([^)]*)\)\]\s*\r?\n\s*\[string\]\s*\$Reviewer') {
    throw 'emit-review-telemetry.ps1 no longer declares a ValidateSet directly above [string] $Reviewer; the vendor-coverage guard cannot read it'
}
$allowedVendors = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
# Seats that can produce a telemetry row: enabled reviewers, plus any role or pool member
# declaring a vendor. Disabled alternates are excluded -- they emit nothing until enabled,
# and re-enabling one goes through this same guard.
$emittingVendors = [System.Collections.Generic.List[string]]::new()
foreach ($r in @($manifest.reviewers | Where-Object { $_.enabled })) { if ($r.vendor) { $emittingVendors.Add([string]$r.vendor) } }
foreach ($roleName in $manifest.roles.PSObject.Properties.Name) {
    $role = $manifest.roles.$roleName
    if ($roleName -eq '_comment') { continue }
    if ($role.vendor) { $emittingVendors.Add([string]$role.vendor) }
    foreach ($member in @($role.pool)) { if ($member.vendor) { $emittingVendors.Add([string]$member.vendor) } }
}
$missingVendors = @($emittingVendors | Sort-Object -Unique | Where-Object { $allowedVendors -notcontains $_ })
if ($missingVendors) {
    throw ("reviewers.json can emit telemetry for vendor(s) the -Reviewer ValidateSet rejects: " +
        ($missingVendors -join ', ') +
        ". Add them to emit-review-telemetry.ps1 or their rows are silently dropped.")
}

"adversarial-review audit contract OK — $words words"
