[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepositoryRoot,
    [Parameter(Mandatory)] [string] $ScaffoldRoot,
    [string] $ActionsEvidencePath,
    [string] $ExpectedHeadSha,
    [string] $ApprovalPath
)

$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$scaffold = (Resolve-Path -LiteralPath $ScaffoldRoot).Path
# The primary workflow's FILENAME is read from the repo's own review policy, not
# hardcoded. review-policy.md permits adjusting it, while this checker built the literal
# `ci.yml` path, derived the required HIGH entries to the same literal, and byte-compared
# review-policy-guard.yml -- so a repo whose primary workflow is `build.yml` had no
# compliant state: follow the prose and the audit reports drift, ignore it and the HIGH
# entry protects a file that does not exist.
$policyPath = Join-Path $repository '.claude/review-policy.json'
if (-not (Test-Path -LiteralPath $policyPath)) { throw 'Missing review policy.' }
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
$primaryWorkflow = @($policy.high | Where-Object { $_ -match '^\.github/workflows/[^*]+\.ya?ml$' } |
    Where-Object { $_ -notmatch '(?:review-policy-(?:guard|tier)|review-tier)\.ya?ml$' -and $_ -notmatch 'canonical-asset-drift' } | Select-Object -First 1)
$primaryWorkflow = if ($primaryWorkflow) { [string]$primaryWorkflow[0] } else { '.github/workflows/ci.yml' }
$ciPath = Join-Path $repository $primaryWorkflow
$ciContract = Get-Content -LiteralPath (Join-Path $scaffold 'references/ci-workflow.md') -Raw
$securityContract = Get-Content -LiteralPath (Join-Path $scaffold 'references/dependencies-and-security.md') -Raw
$reviewContract = Get-Content -LiteralPath (Join-Path $scaffold 'references/review-policy.md') -Raw

function Assert-CanonicalFile([string] $relativePath, [string] $assetName, [string[]] $PermittedDifference) {
    $actual = Join-Path $repository $relativePath
    $canonical = Join-Path $scaffold "assets/$assetName"
    if (-not (Test-Path -LiteralPath $actual)) { throw "Missing scaffold asset: $relativePath" }
    # A byte-compared asset that hardcodes `main` cannot be adapted: audit-ci itself
    # anticipates a non-main mainline, so adapt the branch and the audit reports drift,
    # leave it and the guard never fires on that repo's mainline pushes. GitHub does not
    # evaluate ${{ }} expressions in an `on:` trigger block, so the branch cannot be
    # templated -- it is listed as a permitted difference instead, normalised away here
    # and nowhere else.
    if ($PermittedDifference) {
        $canonicalText = ([IO.File]::ReadAllText($canonical) -replace "`r`n", "`n")
        $actualText = ([IO.File]::ReadAllText($actual) -replace "`r`n", "`n")
        foreach ($difference in $PermittedDifference) {
            $parts = $difference -split '=>', 2
            if ($parts.Count -eq 2) { $actualText = $actualText.Replace($parts[1], $parts[0]) }
        }
        if ($actualText -cne $canonicalText) { throw "Scaffold asset drift: $relativePath" }
        return
    }
    # -cne. PowerShell's -ne on strings is case-INSENSITIVE, so a case-only edit
    # (`branches: [Main]`, a recased filename in a SHA-pin exemption set) compared equal
    # and passed the drift audit while behaving differently on GitHub and on Linux. The
    # sibling compare-canonical-file.ps1 already uses -ceq.
    if (([IO.File]::ReadAllText($actual) -replace "`r`n", "`n") -cne
        ([IO.File]::ReadAllText($canonical) -replace "`r`n", "`n")) {
        throw "Scaffold asset drift: $relativePath"
    }
}

function Get-JobBlocks([string] $text) {
    $lines = @($text -split "\r?\n")
    $jobsAt = [array]::IndexOf($lines, 'jobs:')
    if ($jobsAt -lt 0) { throw 'Workflow has no jobs mapping.' }
    $starts = [Collections.Generic.List[object]]::new()
    for ($i = $jobsAt + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^  (?<id>[A-Za-z_][A-Za-z0-9_-]*):\s*(?:#.*)?$') {
            $starts.Add([pscustomobject]@{ Id = $Matches.id; Index = $i })
        }
    }
    if (-not $starts.Count) { throw 'Workflow jobs mapping has no parseable jobs.' }
    $blocks = [ordered]@{}
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $end = if ($i + 1 -lt $starts.Count) { $starts[$i + 1].Index } else { $lines.Count }
        $blocks[$starts[$i].Id] = @($lines[$starts[$i].Index..($end - 1)])
    }
    $blocks
}

function Get-Steps([string[]] $job) {
    $starts = [Collections.Generic.List[int]]::new()
    for ($i = 1; $i -lt $job.Count; $i++) {
        if ($job[$i] -match '^      -\s+') { $starts.Add($i) }
    }
    $steps = @()
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $end = if ($i + 1 -lt $starts.Count) { $starts[$i + 1] } else { $job.Count }
        $block = @($job[$starts[$i]..($end - 1)] | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $steps += $block
    }
    $steps
}

# A YAML block-scalar header: the indicator, an optional indentation/chomping indicator in
# either order, and an optional trailing comment. `run: |`, `run: >-`, `run: |2` and
# `run: | # diagnostic script` are all headers whose VALUE is the following indented
# lines. Every reader of a `run:` value has to agree on this, or one of them treats the
# header text as the command and never reads the body - which is how a correct tag-fired
# publish job lost its ancestry assertion and its continue-on-error scan at once.
# (CodeRabbit, PR #135.)
$BlockScalarHeader = '[>|](?:[0-9][+-]?|[+-][0-9]?)?(?:\s+#.*)?'

function Get-RunSteps([string[]] $job) {
    @(Get-Steps $job | Where-Object { $_ -match '(?m)^\s*(?:-\s*)?run:\s*' })
}

function Get-StepCommands([string] $step) {
    $lines = @($step -split "\r?\n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^\s*(?:-\s*)?run:\s*(?<value>.*)$') { continue }
        $inline = $Matches.value.Trim()
        if ($inline -and $inline -notmatch "^$BlockScalarHeader$") { return @($inline) }
        return @($lines[($i + 1)..($lines.Count - 1)] | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^#' })
    }
    @()
}

# BEST-EFFORT detector, and it must be read that way: an absent finding here is not
# evidence that a publish path was checked. It was `^`-anchored per trimmed line, so
# `cd src && npm publish`, a `for ... dotnet nuget push` loop and `./scripts/release.sh`
# all read as "not a publish step". The anchor is gone and the shapes below are widened;
# an arbitrary wrapper script still cannot be recognised by pattern.
function Test-PublishDeployStep([string] $step) {
    foreach ($command in @(Get-StepCommands $step)) {
        if ($command -match '(?:^|[\s;&|(])(?:dotnet\s+(?:pack|publish|nuget\s+push)|npm\s+publish|pnpm\s+publish|yarn\s+npm\s+publish|gh\s+release\s+create|docker\s+(?:push|buildx\s+build\b.*--push)|az\s+(?:deployment|acr\s+build|containerapp|webapp\s+deploy|functionapp\s+deploy|storage\s+blob\s+upload(?:-batch)?)|kubectl\s+(?:apply|set\s+image)|helm\s+upgrade|twine\s+upload)\b') {
            return $true
        }
    }
    $step -match '(?im)^\s*(?:-\s*)?uses:\s*(?:docker/(?:build-push-action|login-action)|azure/(?:webapps-deploy|functions-action|container-apps-deploy-action|static-web-apps-deploy)|softprops/action-gh-release|ncipollo/release-action|JS-DevTools/npm-publish|pypa/gh-action-pypi-publish)@'
}

# A publish step that runs whatever happened upstream is not gated by anything, so a
# failing ancestry assertion does not stop it.
function Test-UnconditionalPublishStep([string] $step) {
    $condition = [regex]::Match($step, '(?m)^\s*(?:-\s*)?if:\s*(?<condition>.+?)\s*$').Groups['condition'].Value
    $condition -match '(?i)\b(?:always|cancelled)\s*\(\s*\)'
}

function Assert-AncestryRunsOnTag([string[]] $job, [string] $step, [string] $jobId, [string] $workflowName) {
    # Indentation-independent. Both checks were keyed to an absolute column (four spaces
    # for job scope, eight for the step), while Get-Steps accepts a dash followed by any
    # whitespace run -- so one extra space put `continue-on-error: true` at nine spaces
    # and made it invisible, and the inline dash form evaded it identically. The one
    # control stopping a tag-fired ancestry assertion being defanged could itself be
    # defanged by re-indenting one key. Any non-false value anywhere in a tag-fired
    # publish job is rejected, at either scope.
    # BLOCK-SCALAR BODIES ARE EXCLUDED before the scan. The pattern is deliberately
    # unanchored (see above), which also means it matches inside a `run: |` script:
    # probed, `# continue-on-error: true` and `echo continue-on-error: true` both match,
    # so a diagnostic line in a shell body could reject a correct tag-fired publish job.
    # (A QUOTED `echo "continue-on-error: true"` does not match - the preceding character
    # is a quote, not whitespace - so the reachable shapes are the unquoted and commented
    # ones.) Dropping only the `run:` LINE would not help; the body is what matters, and a
    # block scalar's body is every following line indented deeper than its key.
    $mappingLines = [Collections.Generic.List[string]]::new()
    $blockIndent = -1
    foreach ($line in @($job) + @($step -split "\r?\n")) {
        $indent = $line.Length - $line.TrimStart(' ').Length
        if ($blockIndent -ge 0) {
            if ([string]::IsNullOrWhiteSpace($line) -or $indent -gt $blockIndent) { continue }
            $blockIndent = -1
        }
        $mappingLines.Add($line)
        # ANY key opening a block scalar, not just run:. See $BlockScalarHeader above for
        # why the trailing-comment form has to be part of it.
        if ($line -match ":\s*$BlockScalarHeader\s*$") { $blockIndent = $indent }
    }
    $continueValues = @(
        $mappingLines |
            ForEach-Object {
                if ($_ -match '(?:^|\s|-\s*)continue-on-error:\s*(?<value>.*?)\s*$') { $Matches.value.Trim() }
            } |
            Where-Object { $null -ne $_ }
    )
    if ($continueValues | Where-Object { $_ -notmatch '^(?i:false)(?:\s+#.*)?$' }) {
        throw "Tag-fired job '$jobId' in '$workflowName' has a non-failing continue-on-error value."
    }
    $condition = [regex]::Match($step, '(?m)^\s*(?:-\s*)?if:\s*(?<condition>.+?)\s*$').Groups['condition'].Value.Trim()
    if (-not $condition) { return }
    if ($condition -match '^\$\{\{\s*(?<body>.*?)\s*\}\}$') { $condition = $Matches.body.Trim() }
    # The prefix must be EXACTLY refs/tags/. Accepting any prefix let a workflow with
    # `tags: ['v*','hotfix-*']` condition the ancestry step on `refs/tags/v`, so a
    # `hotfix-1.2` tag skipped the assertion while the unconditioned publish step ran.
    if ($condition -notmatch '^github\.ref_type\s*==\s*[''\"]tag[''\"]$' -and
        $condition -notmatch '^startsWith\(github\.ref,\s*[''\"]refs/tags/[''\"]\)$') {
        throw "Tag-fired job '$jobId' in '$workflowName' has an ancestry step that does not execute on every tag it can fire for (accept an unconditioned step, github.ref_type == 'tag', or startsWith(github.ref, 'refs/tags/'))."
    }
}

function Get-Needs([string[]] $job) {
    for ($i = 1; $i -lt $job.Count; $i++) {
        if ($job[$i] -match '^    needs:\s*\[(?<items>[^]]*)\]') {
            return @($Matches.items.Split(',') | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
        }
        # The SCALAR form. `needs: build` is valid and common on a single-dependency job,
        # and returning @() for it did not fail loudly here - it produced an empty
        # required-job list that later hit a mandatory parameter, so the operator was
        # told the evidence was malformed rather than that this parser cannot read a
        # scalar. Fails closed either way; the defect was the diagnosis, not the safety.
        if ($job[$i] -match '^    needs:\s*(?<id>["'']?)(?<value>[A-Za-z_][A-Za-z0-9_-]*)\k<id>\s*(?:#.*)?$') {
            return @($Matches.value)
        }
        if ($job[$i] -match '^    needs:\s*(?:#.*)?$') {
            $items = [Collections.Generic.List[string]]::new()
            for ($j = $i + 1; $j -lt $job.Count -and $job[$j] -match '^\s{6,}-\s*(?<id>[A-Za-z_][A-Za-z0-9_-]*)'; $j++) {
                $items.Add($Matches.id)
            }
            return @($items)
        }
    }
    @()
}

function Test-ReusableWorkflowJob([string[]] $job) {
    [bool] (@($job) -join "`n" -match '(?m)^    uses:\s*\S')
}

function Get-Timeout([string[]] $job, [string] $jobId) {
    # GitHub's schema forbids timeout-minutes on a job that calls a reusable workflow
    # (`jobs.<id>.uses`), and the house deploy pattern prescribes exactly that shape --
    # so demanding it made the reference's own deploy job permanently unsatisfiable.
    # The timeout belongs inside the called workflow; $null means "not applicable here".
    if (Test-ReusableWorkflowJob $job) { return $null }
    # `(?:#.*)?` because a trailing comment is in-house style in this estate's own
    # workflows, and `timeout-minutes: 15 # matches the budget` then read as NO timeout
    # at all - the audit reporting a missing control that is right there on the line.
    $line = $job | Where-Object { $_ -match '^    timeout-minutes:\s*(?<minutes>\d+)\s*(?:#.*)?$' } | Select-Object -First 1
    if (-not $line) { throw "Substantive job '$jobId' has no timeout-minutes." }
    [int] ([regex]::Match($line, '^\s*timeout-minutes:\s*(?<minutes>\d+)').Groups['minutes'].Value)
}

function Get-JobName([string[]] $job, [string] $jobId) {
    $line = $job | Where-Object { $_ -match '^    name:\s*(?<name>.+?)\s*$' } | Select-Object -First 1
    if (-not $line) { return $jobId }
    $value = [regex]::Match($line, '^    name:\s*(?<name>.+?)\s*$').Groups['name'].Value
    # A YAML plain scalar ends at an unquoted ` #`, so `name: Backend # legacy lane` names
    # the job "Backend". Folding the comment into the name made that job unmatchable
    # against measured evidence, and the audit then reported the job as absent - while
    # inline comments are exactly what this repo's own workflow fixtures use.
    if ($value -notmatch '^["'']') { $value = ($value -replace '\s+#.*$', '') }
    $value.Trim().Trim("'").Trim('"')
}

function Assert-DotNetJob([string[]] $job, [string] $jobId, [int] $testSeconds) {
    $steps = @(Get-Steps $job)
    $setupAt = [array]::FindIndex($steps, [Predicate[string]] { param($step) $step -match 'uses:\s*actions/setup-dotnet@' })
    $toolAt = [array]::FindIndex($steps, [Predicate[string]] { param($step) @(Get-StepCommands $step | Where-Object { $_ -match '^dotnet tool restore\s*$' }).Count -gt 0 })
    $formatAt = [array]::FindIndex($steps, [Predicate[string]] { param($step) @(Get-StepCommands $step | Where-Object { $_ -match '^dotnet csharpier check \.\s*$' }).Count -gt 0 })
    $restoreAt = [array]::FindIndex($steps, [Predicate[string]] { param($step) @(Get-StepCommands $step | Where-Object { $_ -match '^dotnet restore\s+' }).Count -gt 0 })
    if ($setupAt -lt 0 -or $toolAt -ne ($setupAt + 1) -or $formatAt -ne ($toolAt + 1) -or $restoreAt -le $formatAt) {
        throw ".NET backend job '$jobId' must set up .NET, restore tools, run CSharpier, then restore packages."
    }
    # `--blame-hang-timeout` is VSTest-only, and the reference directs MTP-runner repos to
    # keep operation-local deadlines and the ten-minute job cap INSTEAD -- so requiring
    # that flag unconditionally left an MTP repo with no compliant state, while the audit
    # forbids working around a failure. Accept either runner's enforcement, and name both
    # when neither is present: no command silently skips the requirement.
    foreach ($command in $steps | ForEach-Object { Get-StepCommands $_ } | Where-Object { $_ -match '^dotnet test\s+' }) {
        $hasVsTestTimeout = $command -match [regex]::Escape("--blame-hang-timeout ${testSeconds}s")
        $hasMtpTimeout = $command -match '(?<![\w-])--hangdump-timeout\s+\S' -or $command -match '(?<![\w-])--timeout\s+\S'
        if (-not ($hasVsTestTimeout -or $hasMtpTimeout)) {
            throw ".NET test step in '$jobId' has no per-test timeout: expected VSTest '--blame-hang-timeout ${testSeconds}s' or an MTP '--hangdump-timeout'/'--timeout'."
        }
    }
}

if (-not (Test-Path -LiteralPath $ciPath)) { throw "Missing primary workflow: $primaryWorkflow (declared HIGH in .claude/review-policy.json)" }
$ci = Get-Content -LiteralPath $ciPath -Raw
$jobs = Get-JobBlocks $ci
# Derived here rather than at the ancestry loop, because the guard's byte-comparison
# needs it too.
$ciPushBlock = [regex]::Match($ci, '(?m)^  push:\s*\r?\n(?<body>(?:^ {4,}.*(?:\r?\n|$))*)').Groups['body'].Value
$mainlineBranch = [regex]::Match($ciPushBlock, '(?m)^    branches:\s*\[(?<branch>[^],]+)').Groups['branch'].Value.Trim().Trim("'").Trim('"')

Assert-CanonicalFile '.github/scripts/assert_gate_coverage.py' 'assert_gate_coverage.py'
Assert-CanonicalFile '.github/scripts/assert_workflow_hygiene.py' 'assert_workflow_hygiene.py'
$guardDifferences = @()
if ($mainlineBranch -and $mainlineBranch -cne 'main') { $guardDifferences += "main=>$mainlineBranch" }
$guardDifferences += "ci.yml=>$([IO.Path]::GetFileName($primaryWorkflow))"
Assert-CanonicalFile '.github/workflows/review-policy-guard.yml' 'review-policy-guard.yml' $guardDifferences

$python = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }
$gateCoverage = @($jobs['gate-coverage']) -join "`n"
$gateCoverageCommands = @(Get-RunSteps $jobs['gate-coverage'] | ForEach-Object { Get-StepCommands $_ })

# assert_gate_coverage.py reads its exemptions from the PROCESS ENVIRONMENT
# (split_env("GATE_EXEMPT") / split_env("GATE_CONDITIONAL_EXEMPT")), and the in-repo job
# supplies them as step `env:` -- the skeleton itself ships `GATE_EXEMPT: docker`. Running
# the checker with an empty environment therefore scored every publishing or deploying
# repo as structurally failing a control it satisfies, and the audit forbids falling back
# to the prose checklist. Where the reference grants an adaptation, the checker must take
# that adaptation as INPUT rather than re-deriving it from the canonical asset.
$gateExemptions = @{}
foreach ($name in 'GATE_EXEMPT', 'GATE_CONDITIONAL_EXEMPT', 'PRIVILEGED_TRIGGER_NO_CHECKOUT') {
    $match = [regex]::Match($gateCoverage, "(?m)^\s+$name\s*:\s*(?<value>.*?)\s*$")
    if ($match.Success) { $gateExemptions[$name] = $match.Groups['value'].Value.Trim("'", '"') }
}
$previousExemptions = @{}
foreach ($name in 'GATE_EXEMPT', 'GATE_CONDITIONAL_EXEMPT', 'PRIVILEGED_TRIGGER_NO_CHECKOUT') {
    $previousExemptions[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, $gateExemptions[$name])
}
try {
    & $python (Join-Path $repository '.github/scripts/assert_gate_coverage.py') $ciPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $declared = ($gateExemptions.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join ' '
        throw "CI Gate coverage or semantics failed (repo exemptions: $(if ($declared) { $declared } else { 'none declared' }))."
    }
}
finally {
    foreach ($name in 'GATE_EXEMPT', 'GATE_CONDITIONAL_EXEMPT', 'PRIVILEGED_TRIGGER_NO_CHECKOUT') {
        [Environment]::SetEnvironmentVariable($name, $previousExemptions[$name])
    }
}

if ($gateCoverageCommands -notcontains "python3 .github/scripts/assert_gate_coverage.py $primaryWorkflow") {
    throw 'Gate coverage does not execute the shipped checker.'
}
$gate = @($jobs['ci-gate']) -join "`n"
if ($gate -notmatch '(?m)^    permissions:\s*\{\}\s*$') { throw 'CI Gate must have zero permissions.' }

Push-Location $repository
try {
    & $python '.github/scripts/assert_workflow_hygiene.py' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Workflow hygiene failed.' }
}
finally { Pop-Location }

$guardText = Get-Content -LiteralPath (Join-Path $repository '.github/workflows/review-policy-guard.yml') -Raw
$requiredLoop = [regex]::Match($guardText, '(?s)for required in (?<paths>.*?)\s*; do')
$requiredHigh = @([regex]::Matches($requiredLoop.Groups['paths'].Value, '\.github/[^\s\\]+|\.claude/[^\s\\]+|\.coderabbit\.yaml') |
    ForEach-Object Value | Select-Object -Unique)
if (-not $requiredLoop.Success -or -not $requiredHigh.Count) { throw 'Cannot derive required HIGH paths from the guard workflow.' }
foreach ($path in $requiredHigh) {
    # The canonical prose names `ci.yml`; a repo that renamed its primary workflow needs
    # the entry for the file it actually has. Substitute, then assert the HIGH glob
    # resolves to a tracked file -- nothing did that before, so a HIGH entry could name
    # a path that did not exist and read as protection.
    $expected = if ($path -eq '.github/workflows/ci.yml') { $primaryWorkflow } else { $path }
    if (@($policy.high) -notcontains $expected) { throw "Merge-barrier path is not HIGH: $expected" }
    if ($expected -notmatch '[*?]' -and -not (Test-Path -LiteralPath (Join-Path $repository $expected))) {
        throw "HIGH merge-barrier path does not exist in the repository: $expected"
    }
}

$requiredTimeout = [int] [regex]::Match($ciContract, 'each substantive required job gets `timeout-minutes: (?<minutes>\d+)`').Groups['minutes'].Value
$aggregateBudget = [int] [regex]::Match($ciContract, '(?<minutes>\d+) aggregate runner-minutes').Groups['minutes'].Value
$testSeconds = [int] [regex]::Match($ciContract, 'One test gets a (?<seconds>\d+)-second hard\s+ceiling').Groups['seconds'].Value
if (-not $requiredTimeout -or -not $aggregateBudget -or -not $testSeconds) { throw 'Cannot derive executable CI time limits from scaffold-ci.' }
$requiredJobs = @(Get-Needs $jobs['ci-gate'] | Where-Object { $_ -ne 'gate-coverage' })
$controlJobs = @('ci-gate', 'gate-coverage')
foreach ($entry in $jobs.GetEnumerator() | Where-Object { $_.Key -notin $controlJobs }) {
    Get-Timeout $entry.Value $entry.Key | Out-Null
}
foreach ($jobId in $requiredJobs) {
    if (-not $jobs.Contains($jobId)) { throw "CI Gate needs unknown job '$jobId'." }
    $timeout = Get-Timeout $jobs[$jobId] $jobId
    if ($null -ne $timeout -and $timeout -gt $requiredTimeout) { throw "Required job '$jobId' exceeds $requiredTimeout minutes." }
    $jobCommands = @(Get-RunSteps $jobs[$jobId] | ForEach-Object { Get-StepCommands $_ })
    if ($jobCommands | Where-Object { $_ -match '^dotnet (?:restore|build|test)\s+' }) {
        Assert-DotNetJob $jobs[$jobId] $jobId $testSeconds
    }
}

if ([string]::IsNullOrWhiteSpace($ActionsEvidencePath)) { throw 'Required-lane Actions cost evidence is missing.' }
if ([string]::IsNullOrWhiteSpace($ExpectedHeadSha)) { throw 'Required-lane expected head SHA is missing.' }
$requiredJobNames = @($requiredJobs | ForEach-Object { Get-JobName $jobs[$_] $_ })
$costEvidence = & (Join-Path $PSScriptRoot 'test-required-lane-cost.ps1') -EvidencePath $ActionsEvidencePath `
    -ExpectedHeadSha $ExpectedHeadSha -RequiredJobNames $requiredJobNames -BudgetMinutes $aggregateBudget `
    -RepositoryRoot $repository -ApprovalPath $ApprovalPath

$extendedLimit = [int] [regex]::Match($ciContract, 'weekly/manual jobs capped at (?<minutes>\d+) minutes').Groups['minutes'].Value
if (-not $extendedLimit) { $extendedLimit = [int] [regex]::Match($ciContract, 'timeout-minutes: (?<minutes>45)').Groups['minutes'].Value }
foreach ($workflow in Get-ChildItem -LiteralPath (Join-Path $repository '.github/workflows') -File | Where-Object { $_.FullName -ne $ciPath -and $_.Extension -in '.yml', '.yaml' }) {
    $text = Get-Content -LiteralPath $workflow.FullName -Raw
    if ($text -notmatch '(?im)^name:\s*Extended tests\s*$') { continue }
    foreach ($entry in (Get-JobBlocks $text).GetEnumerator()) {
        $timeout = Get-Timeout $entry.Value $entry.Key
        if ($null -ne $timeout -and $timeout -gt $extendedLimit) { throw "Extended job '$($entry.Key)' exceeds $extendedLimit minutes." }
    }
}

# Reused, not re-derived. This was a second copy of the extraction above, feeding the
# ancestry loop while the first fed guard normalisation - two copies of a load-bearing
# regex that are always equal until one is edited. (CodeRabbit, PR #135.)
$mainline = $mainlineBranch
$workflowFiles = @(Get-ChildItem -LiteralPath (Join-Path $repository '.github/workflows') -File | Where-Object { $_.Extension -in '.yml', '.yaml' })
$workflowQueue = [Collections.Generic.List[object]]::new()
$queuedTagWorkflows = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $workflowFiles) {
    $workflowQueue.Add([pscustomobject]@{ File = $file; InheritedTag = $false })
}
for ($workflowIndex = 0; $workflowIndex -lt $workflowQueue.Count; $workflowIndex++) {
    $workflowItem = $workflowQueue[$workflowIndex]
    $workflow = $workflowItem.File
    $workflowText = Get-Content -LiteralPath $workflow.FullName -Raw
    $push = [regex]::Match($workflowText, '(?m)^  push:\s*\r?\n(?<body>(?:^ {4,}.*(?:\r?\n|$))*)').Groups['body'].Value
    # Tag-reachable is broader than `push.tags`. A bare `push:` with no filters fires on
    # every tag; `release: types: [published]` runs with github.ref = refs/tags/<tag>; and
    # the flow form `on: [push]` is invisible to the block regex above. All three used to
    # `continue` past the entire ancestry inspection, leaving the control fail-open for
    # the two most common publish trigger shapes.
    $hasTagFilter = $push -match '(?m)^    tags(?:-ignore)?:\s*(?:\[.*\]\s*|)$'
    $bareBlockPush = [regex]::IsMatch($workflowText, '(?m)^  push:\s*(?:#.*)?$') -and
        $push -notmatch '(?m)^    (?:branches|branches-ignore|tags|tags-ignore|paths|paths-ignore):'
    $flowPush = [regex]::IsMatch($workflowText, '(?m)^on:\s*\[[^\]]*\bpush\b[^\]]*\]\s*$')
    $releaseTrigger = [regex]::IsMatch($workflowText, '(?m)^  release:\s*(?:#.*)?$') -or
        [regex]::IsMatch($workflowText, '(?m)^on:\s*\[[^\]]*\brelease\b[^\]]*\]\s*$')
    $tagReachable = $workflowItem.InheritedTag -or $hasTagFilter -or $bareBlockPush -or $flowPush -or $releaseTrigger
    if (-not $tagReachable) { continue }
    if (-not $mainline) { throw 'Cannot derive the default branch for tag ancestry.' }
    foreach ($entry in (Get-JobBlocks $workflowText).GetEnumerator()) {
        $jobText = @($entry.Value) -join "`n"
        $localCall = [regex]::Match($jobText, '(?m)^    uses:\s*(?:\./|\$/)\.github/workflows/(?<file>[^@\s]+)')
        if ($localCall.Success) {
            $calledPath = Join-Path $repository ('.github/workflows/' + $localCall.Groups['file'].Value)
            if (-not (Test-Path -LiteralPath $calledPath -PathType Leaf)) { throw "Tag-fired reusable workflow '$($workflow.Name)' calls missing local workflow '$calledPath'." }
            $calledFile = Get-Item -LiteralPath $calledPath
            if ($queuedTagWorkflows.Add($calledFile.FullName)) {
                $workflowQueue.Add([pscustomobject]@{ File = $calledFile; InheritedTag = $true })
            }
        }
        # A job gated to the mainline branch cannot run on a tag ref, so requiring a tag
        # ancestry assertion on it fails a workflow that is already correct -- the
        # false-positive half of this control.
        #
        # Anchored at JOB scope (four spaces), not `^\s+`. `$jobText` is the whole job
        # block, so `^\s+if:` also matched a STEP-level condition: one unrelated step
        # carrying `if: github.ref == 'refs/heads/main'` made the loop `continue`, and
        # every publish step in that job then escaped the publish detector, the ordering
        # check, the continue-on-error check and Assert-AncestryRunsOnTag. Fail-open, and
        # reachable by adding one guard to one step. (CodeRabbit, PR #135.)
        $mainlineNameGate = $mainline -and $jobText -match ("(?m)^    if:.*github\.ref_name\s*==\s*['`"]" + [regex]::Escape($mainline) + "['`"]")
        if (($mainlineNameGate -or $jobText -match "(?m)^    if:.*github\.ref\s*==\s*['`"]refs/heads/") -and
            $jobText -notmatch '(?i)refs/tags|ref_type|startsWith\s*\(\s*github\.ref') { continue }
        # A `uses:` job calls a reusable workflow and has no steps of its own, so neither
        # the publish detector nor the ancestry check can see anything. Requiring the
        # assertion inside the called workflow is the only place it can live.
        if ($jobText -match '(?m)^    uses:\s*\S') { continue }
        $steps = @(Get-Steps $entry.Value)
        $publishAt = @()
        for ($i = 0; $i -lt $steps.Count; $i++) {
            if (Test-PublishDeployStep $steps[$i]) { $publishAt += $i }
        }
        if (-not $publishAt.Count) { continue }
        $ancestryAt = @()
        for ($i = 0; $i -lt $steps.Count; $i++) {
            if (@(Get-StepCommands $steps[$i] | Where-Object { $_ -match '^if ! git merge-base --is-ancestor\s+' }).Count) { $ancestryAt += $i }
        }
        if ($ancestryAt.Count -ne 1) { throw "Tag-fired publish/deploy path in job '$($entry.Key)' in '$($workflow.Name)' must have exactly one ancestry assertion step." }
        # STRICTLY before, and the assertion step must not itself publish: a publish
        # command inside the ancestry step shares its index, and `-gt` on equal indexes
        # passed the ordering check while the publish ran regardless of the assertion.
        if ($publishAt -contains $ancestryAt[0]) {
            throw "Tag-fired job '$($entry.Key)' in '$($workflow.Name)' publishes inside its own ancestry assertion step."
        }
        if ($ancestryAt[0] -gt ($publishAt | Measure-Object -Minimum).Minimum) {
            throw "Tag-fired publish/deploy path in job '$($entry.Key)' in '$($workflow.Name)' runs before ancestry is proven."
        }
        # `if: always()` (or `!cancelled()`) on a publish step means a failing ancestry
        # assertion does not stop it, so ordering proves nothing.
        foreach ($publishIndex in $publishAt) {
            if (Test-UnconditionalPublishStep $steps[$publishIndex]) {
                throw "Tag-fired job '$($entry.Key)' in '$($workflow.Name)' has a publish/deploy step that runs regardless of the ancestry assertion."
            }
        }
        for ($i = 0; $i -lt $ancestryAt[0]; $i++) {
            if (@(Get-StepCommands $steps[$i] | Where-Object { $_ -match '^dotnet restore\s+' }).Count) {
                throw "Tag-fired job '$($entry.Key)' in '$($workflow.Name)' restores before ancestry is proven."
            }
        }
        $command = $steps[$ancestryAt[0]]
        Assert-AncestryRunsOnTag $entry.Value $command $entry.Key $workflow.Name
        $tokens = @('set -euo pipefail', "git fetch --no-tags origin $mainline", 'if ! git merge-base --is-ancestor "$GITHUB_SHA" FETCH_HEAD; then', 'exit 1', 'fi')
        $position = -1
        foreach ($token in $tokens) {
            $next = $command.IndexOf($token, $position + 1, [StringComparison]::Ordinal)
            if ($next -lt 0) { throw "Tag-fired job '$($entry.Key)' in '$($workflow.Name)' has an incomplete ancestry assertion: $token" }
            $position = $next
        }
    }
}

$secretJobId = [regex]::Match($securityContract, 'One `(?<id>[A-Za-z0-9_-]+)` job in `ci\.yml`').Groups['id'].Value
if (-not $secretJobId -or -not $jobs.Contains($secretJobId)) { throw 'Cannot locate the scaffold-ci private secret job.' }
$secretRuns = @(Get-RunSteps $jobs[$secretJobId])
$canonicalGitleaks = @([regex]::Matches($securityContract, '(?m)^\s*(?<command>"\$RUNNER_TEMP/gitleaks"\s+(?:git|dir)\s+.+)$') |
    ForEach-Object { $_.Groups['command'].Value.Trim() } | Select-Object -Unique)
# Three now: the pull_request range, the push range, and the checked-out tree. The
# range scan was one command reading `github.event.pull_request.base.sha`, which renders
# empty on every non-pull_request event and collapsed to a zero-commit scan that exited
# 0. Deriving the count from the reference keeps this honest if the set changes again.
if ($canonicalGitleaks.Count -ne 3) { throw "Expected three canonical Gitleaks invocations in scaffold-ci, derived $($canonicalGitleaks.Count)." }
foreach ($command in $canonicalGitleaks) {
    $invocation = '(?m)^\s*(?:-\s*run:\s*)?' + [regex]::Escape($command) + '\s*$'
    if (-not ($secretRuns | Where-Object { $_ -match $invocation })) { throw "Private secret job is missing canonical scan: $command" }
}

[pscustomobject]@{ Status = $costEvidence.Status; Repository = $repository; CostEvidence = $costEvidence }
