[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EvidencePath,
    [Parameter(Mandatory)] [string] $ExpectedHeadSha,
    [Parameter(Mandatory)] [string[]] $RequiredJobNames,
    [Parameter(Mandatory)] [double] $BudgetMinutes,
    # Audited repository root. Owner approval of a budget breach is read from its
    # COMMITTED .claude/ci-budget-approval.json, which review-policy.json tiers HIGH.
    # There is no path override: the committed tree is the only approval source, so an
    # -ApprovalPath that could only ever equal that one path was redundant.
    [string] $RepositoryRoot,
    # The run the committed approval names, fetched SEPARATELY from the audited-head run
    # (`{ "run": { id, head_sha, conclusion, workflow_id } }`). It only validates approval
    # provenance; it is never the cost measurement.
    [string] $ApprovalRunEvidencePath
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $EvidencePath)) { throw "Required-lane cost evidence is missing: $EvidencePath" }
if ([string]::IsNullOrWhiteSpace($ExpectedHeadSha)) { throw 'Expected head SHA is missing.' }
if ($BudgetMinutes -le 0) { throw 'Required-lane budget must be positive.' }
$required = @($RequiredJobNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
if (-not $required.Count) { throw 'Required job names are missing.' }

try { $evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json }
catch { throw "Required-lane cost evidence is malformed JSON: $($_.Exception.Message)" }
if ($evidence -isnot [pscustomobject]) { throw 'Required-lane cost evidence must be a JSON object.' }
if ($evidence.PSObject.Properties.Name -notcontains 'run' -or $evidence.run -isnot [pscustomobject]) {
    throw 'Required-lane cost evidence omitted the run object.'
}
if ($evidence.run.PSObject.Properties.Name -notcontains 'head_sha' -or
    [string]::IsNullOrWhiteSpace([string] $evidence.run.head_sha)) {
    throw 'Required-lane cost evidence omitted run head_sha.'
}
if ($evidence.run.PSObject.Properties.Name -notcontains 'id' -or
    ($evidence.run.id -isnot [int] -and $evidence.run.id -isnot [long]) -or
    [long] $evidence.run.id -le 0) {
    throw 'Required-lane cost evidence omitted a valid run id.'
}
$evidenceHeadSha = [string] $evidence.run.head_sha
# Checked before any per-job error so a stale payload is blamed as stale, not as whichever
# job-level fault it also happens to carry. The evidence must measure the AUDITED head on
# BOTH paths: accepting the old run an approval names would let every later HEAD come back
# APPROVED_EXCEPTION on that old run's minutes, however much the lane has grown. The
# approval bounds HEAD's own measurement through its committed max_minutes.
if ($evidenceHeadSha -ne $ExpectedHeadSha) { throw 'Required-lane cost evidence head_sha is stale.' }
if ($evidence.run.PSObject.Properties.Name -notcontains 'conclusion' -or
    [string] $evidence.run.conclusion -ne 'success') {
    throw 'Required-lane cost evidence is not from a successful completed run.'
}
if ($evidence.PSObject.Properties.Name -notcontains 'jobs' -or $null -eq $evidence.jobs) {
    throw 'Required-lane cost evidence omitted jobs.'
}
if ($evidence.PSObject.Properties.Name -notcontains 'total_count' -or
    ($evidence.total_count -isnot [int] -and $evidence.total_count -isnot [long]) -or
    [long] $evidence.total_count -lt 0) {
    throw 'Required-lane cost evidence has an invalid jobs total_count.'
}

$jobs = @($evidence.jobs)
if ($jobs.Count -ne [long] $evidence.total_count) {
    throw "Required-lane cost evidence is incomplete: received $($jobs.Count) of $($evidence.total_count) jobs."
}
# Evidence from a re-run can carry BOTH attempts of the same job. The dedupe below keys
# on name plus start time, which is exactly what does NOT collapse them: a re-attempt has
# a different start time, so both legs are counted and the lane's cost is overstated -
# silently, in the direction that pushes a compliant lane into APPROVED_EXCEPTION.
# Detected rather than repaired, because choosing WHICH attempt is the measurement belongs
# to the collector: this script is handed a payload and cannot re-fetch one.
#
# `run_attempt` is REQUIRED, not read-if-present. Reading it only from jobs that carry it
# made the guard inert against the very evidence shape the skill prescribes: `run_attempt`
# was not in SKILL.md step 3's field list, so canonical evidence produced an empty
# `$attempts` and the check passed over a mixed-attempt payload it was written to refuse.
# A guard that cannot fire on the documented input is decoration. SKILL.md step 3 now
# collects the field, and evidence without it is refused here. (CodeRabbit, PR #135.)
$missingAttempt = @($jobs | Where-Object {
    $_ -is [pscustomobject] -and (
        $_.PSObject.Properties.Name -notcontains 'run_attempt' -or
        [string]::IsNullOrWhiteSpace([string] $_.run_attempt))
})
if ($missingAttempt.Count -gt 0) {
    throw "Required-lane cost evidence omits run_attempt on $($missingAttempt.Count) job(s); without it a re-run's duplicated legs cannot be detected and the lane's cost is overstated. Collect run_attempt per job (SKILL.md step 3)."
}
$attempts = @($jobs | ForEach-Object { [string] $_.run_attempt } | Sort-Object -Unique)
if ($attempts.Count -gt 1) {
    throw "Required-lane cost evidence mixes run attempts ($($attempts -join ', ')); every job must come from one attempt or its minutes are counted twice. Collect with the run's latest attempt only."
}
$counted = [Collections.Generic.List[object]]::new()
# One Actions job is counted ONCE. Leg matching is name-or-"name (" with no dedupe, so
# with required jobs `Backend` and `Backend (integration)` the shorter name absorbed the
# longer job's legs and those minutes were summed twice -- inflating the total and pushing
# a compliant lane into APPROVED_EXCEPTION. Anchoring on `\(.*\)$` does not fix it:
# `Backend (Legacy)` also ends in a bracket.
$countedJobs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
# A matrix job's declared name commonly carries an expression -- `Frontend (${{
# matrix.node }})` -- and nothing here renders it. Each required name therefore becomes an
# ANCHORED pattern: literal text escaped, every expression a wildcard, plus GitHub's
# optional ` (<matrix values>)` leg suffix. Cutting the name at its first expression
# instead dropped the literal text after it, so `Frontend (${{ matrix.node }}) tests`
# claimed an unrelated `Frontend (22) lint` as one of its legs.
$patterns = @(foreach ($requiredName in $required) {
    $literalParts = [regex]::Split($requiredName, '\$\{\{.*?\}\}')
    if ([string]::IsNullOrWhiteSpace(($literalParts -join ''))) {
        throw "Required job name '$requiredName' is only an expression, so no literal text can be matched against measured evidence. Give the job a literal name part."
    }
    $body = ($literalParts | ForEach-Object { [regex]::Escape($_) }) -join '.*'
    [pscustomobject]@{
        Name = $requiredName
        Regex = [regex]::new("^$body(?: \(.*\))?$")
        Specificity = ($literalParts -join '').Length
    }
})
# Every job belongs to EXACTLY ONE required name: an exact name match first, else the
# pattern with the most literal text. A job matching several names equally is ambiguous
# and refused. Matching each name independently let the shorter `Backend` claim the job
# `Backend (integration)`, so a required `Backend` missing from the evidence passed on a
# job that belonged to another name.
$assigned = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($pattern in $patterns) { $assigned[$pattern.Name] = [Collections.Generic.List[object]]::new() }
foreach ($job in $jobs) {
    if ($job -isnot [pscustomobject] -or $job.PSObject.Properties.Name -notcontains 'name') { continue }
    $jobName = [string] $job.name
    $best = $null; $bestScore = -1; $tied = $false
    foreach ($pattern in $patterns) {
        if (-not $pattern.Regex.IsMatch($jobName)) { continue }
        $score = if ($jobName -ceq $pattern.Name) { [int]::MaxValue } else { $pattern.Specificity }
        if ($score -gt $bestScore) { $best = $pattern; $bestScore = $score; $tied = $false }
        elseif ($score -eq $bestScore) { $tied = $true }
    }
    if (-not $best) { continue }
    if ($tied) { throw "Required-lane cost evidence job '$jobName' matches more than one required job name equally; give the required jobs distinguishable names." }
    $assigned[$best.Name].Add($job)
}
foreach ($requiredName in $required) {
    $legs = @($assigned[$requiredName])
    if (-not $legs.Count) { throw "Required-lane cost evidence omitted job '$requiredName' and its matrix legs." }
    foreach ($job in $legs) {
        # The Actions job `id` IS the identity, and it is REQUIRED -- there is no name-plus-
        # start-time fallback. That fallback is lossy in the fail-open direction: GitHub
        # permits two job ids to declare the same `name:`, and the API reports `started_at`
        # to the second, so two legs starting in the same second collapsed into one and the
        # aggregate understated the lane - turning an APPROVED_EXCEPTION into COMPLIANT,
        # the direction this script rejects everywhere else. Keeping it as a fallback kept
        # that hole open for exactly the payloads most likely to hit it, since SKILL.md
        # step 3 already collects `id` and evidence without it is stale, not merely terse.
        # (CodeRabbit, #135.)
        $rawId = if ($job.PSObject.Properties.Name -contains 'id') { $job.id } else { $null }
        [long] $jobId = 0
        if ($null -eq $rawId -or -not [long]::TryParse([string] $rawId, [ref] $jobId) -or $jobId -le 0) {
            throw "Required job '$($job.name)' omitted a valid Actions job id. Re-collect the evidence with SKILL.md step 3, which records an 'id' for every job; identity cannot fall back to name plus start time without understating matrix legs."
        }
        if (-not $countedJobs.Add("id:$jobId")) { continue }
        foreach ($field in 'started_at', 'completed_at', 'conclusion') {
            if ($job.PSObject.Properties.Name -notcontains $field -or [string]::IsNullOrWhiteSpace([string] $job.$field)) {
                throw "Required job '$($job.name)' omitted $field."
            }
        }
        # A conditionally-exempt job -- a `secrets` job carrying a `pull_request`
        # condition -- stays a member of ci-gate's `needs`, because conditional exemption
        # exempts the gate-coverage requirement, not membership. It therefore concludes
        # `skipped` on every mainline run, and treating that as a failure left a
        # configuration the corpus blesses unable to reach a passing executable result.
        # A skipped job contributes no runner minutes, so it is recorded and skipped, not
        # counted -- and never silently: the caller reports it.
        if ([string] $job.conclusion -eq 'skipped') {
            $counted.Add([pscustomobject]@{ Name = [string] $job.name; Minutes = 0.0; Skipped = $true })
            continue
        }
        if ([string] $job.conclusion -ne 'success') { throw "Required job '$($job.name)' did not conclude successfully." }
        try {
            $started = [DateTimeOffset]::Parse([string] $job.started_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            $completed = [DateTimeOffset]::Parse([string] $job.completed_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch { throw "Required job '$($job.name)' has an invalid duration timestamp." }
        # `-lt`, not `-le`. Equal timestamps are a job that started and finished inside
        # the API's one-second resolution - a sub-second job, not corrupt evidence - and
        # rejecting it threw away a whole run's cost measurement over the cheapest job in
        # it. Only a completion BEFORE its own start is impossible.
        if ($completed -lt $started) { throw "Required job '$($job.name)' has a negative measured duration." }
        $counted.Add([pscustomobject]@{ Name = [string] $job.name; Minutes = ($completed - $started).TotalMinutes })
    }
}

$aggregate = [Math]::Round([double] (($counted | Measure-Object -Property Minutes -Sum).Sum), 3)
$approval = $null
if ($aggregate -gt $BudgetMinutes) {
    # Approval must come from a COMMITTED file in the audited repository, not a temporary
    # object the auditor writes for itself. It names the run the owner reviewed (its head
    # must be an ancestor of the audited tree, so the approval cannot depend on its own
    # commit SHA) and the most minutes the owner accepts. The file is tiered HIGH, so
    # changing it is itself reviewed.
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        throw "Required-lane measured cost is $aggregate minutes; target is $BudgetMinutes and no repository root was given to locate the committed approval."
    }
    $approvalRelativePath = '.claude/ci-budget-approval.json'
    $treeEntry = @(& git -C $RepositoryRoot ls-tree $ExpectedHeadSha -- $approvalRelativePath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $treeEntry.Count -ne 1) {
        throw 'Owner approval is not present in the audited commit tree.'
    }
    # 40 hex for a SHA-1 repository, 64 for SHA-256.
    if ($treeEntry[0] -notmatch '^100(?:644|755) blob (?:[0-9a-f]{40}|[0-9a-f]{64})\s+\.claude/ci-budget-approval\.json$') {
        throw 'Owner approval in the audited tree must be a regular file, not a symlink or other object.'
    }
    $approvalJson = & git -C $RepositoryRoot show "$ExpectedHeadSha`:$approvalRelativePath" 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not read owner approval bytes from the audited commit tree.' }
    try { $approval = ($approvalJson -join "`n") | ConvertFrom-Json }
    catch { throw "Owner approval evidence is malformed JSON: $($_.Exception.Message)" }
    if ($approval -isnot [pscustomobject]) { throw 'Owner approval evidence must be a JSON object.' }
    foreach ($field in 'approved', 'owner', 'approved_at', 'head_sha', 'run_id', 'max_minutes') {
        if ($approval.PSObject.Properties.Name -notcontains $field) { throw "Owner approval evidence omitted $field." }
    }
    if ($approval.approved -isnot [bool] -or -not $approval.approved) { throw 'Owner approval evidence is not explicitly approved.' }
    if ([string]::IsNullOrWhiteSpace([string] $approval.owner)) { throw 'Owner approval evidence has no owner.' }
    try { [DateTimeOffset]::Parse([string] $approval.approved_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) | Out-Null }
    catch { throw 'Owner approval evidence has an invalid approved_at timestamp.' }
    # A full object id, so the value cannot reach git as an option or a ref expression.
    if ([string] $approval.head_sha -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
        throw 'Owner approval must identify the reviewed run head_sha.'
    }
    if (($approval.run_id -isnot [int] -and $approval.run_id -isnot [long]) -or [long] $approval.run_id -le 0) {
        throw 'Owner approval evidence run_id is missing or invalid.'
    }
    if (($approval.max_minutes -isnot [int] -and $approval.max_minutes -isnot [long] -and
            $approval.max_minutes -isnot [double] -and $approval.max_minutes -isnot [decimal]) -or
        [double] $approval.max_minutes -le 0) {
        throw 'Owner approval evidence max_minutes must be a positive number.'
    }
    & git -C $RepositoryRoot merge-base --is-ancestor ([string] $approval.head_sha) $ExpectedHeadSha 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Owner approval must refer to a measured run on an ancestor of the audited HEAD.' }
    if ($aggregate -gt [double] $approval.max_minutes) {
        throw "Required-lane measured cost is $aggregate minutes at the audited head, above the approved max_minutes of $($approval.max_minutes)."
    }
    # run_id was only checked as a positive integer, so any number produced APPROVED_EXCEPTION
    # without naming a real reviewed run. The run is verified from its own fetched evidence.
    if ([string]::IsNullOrWhiteSpace($ApprovalRunEvidencePath) -or -not (Test-Path -LiteralPath $ApprovalRunEvidencePath)) {
        throw 'Owner approval run evidence is missing; fetch the approval run_id separately (evaluation.md step 4).'
    }
    try { $approvalRun = (Get-Content -LiteralPath $ApprovalRunEvidencePath -Raw | ConvertFrom-Json).run }
    catch { throw "Owner approval run evidence is malformed JSON: $($_.Exception.Message)" }
    if ($approvalRun -isnot [pscustomobject]) { throw 'Owner approval run evidence omitted the run object.' }
    if ("$($approvalRun.id)" -ne "$($approval.run_id)") { throw 'Owner approval run evidence does not describe the approval run_id.' }
    if ([string] $approvalRun.conclusion -ne 'success') { throw 'Owner approval run did not conclude successfully.' }
    if ([string] $approvalRun.head_sha -cne [string] $approval.head_sha) { throw 'Owner approval run head_sha does not match the approval head_sha.' }
    if ([string]::IsNullOrWhiteSpace([string] $approvalRun.workflow_id) -or [string]::IsNullOrWhiteSpace([string] $evidence.run.workflow_id)) {
        throw 'Owner approval run and audited run evidence must both carry workflow_id.'
    }
    if ("$($approvalRun.workflow_id)" -ne "$($evidence.run.workflow_id)") { throw 'Owner approval run is from a different workflow than the audited run.' }
}

[pscustomobject]@{
    Status = if ($aggregate -gt $BudgetMinutes) { 'APPROVED_EXCEPTION' } else { 'COMPLIANT' }
    AggregateMinutes = $aggregate
    # Measured jobs only. A skipped job is recorded with zero minutes and named in
    # SkippedJobs, and counting it here contradicted that.
    CountedJobs = @($counted | Where-Object { -not $_.Skipped }).Count
    # EMITTED, not just recorded. The loop above sets Skipped on its internal list and the
    # output carried only a count, so no consumer could tell a skipped required job from a
    # measured one - while both the comment there and audit-ci/SKILL.md describe a report
    # naming them. An instruction no data path supports is not executable.
    # (CodeRabbit, PR #135.)
    SkippedJobs = @($counted | Where-Object { $_.Skipped } | ForEach-Object { $_.Name })
    HeadSha = $ExpectedHeadSha
    # The head the measured run actually built. Equal to HeadSha by the check above;
    # emitted so a consumer reads the measurement's provenance, not the caller's claim.
    MeasuredHeadSha = $evidenceHeadSha
    RunId = [long] $evidence.run.id
    Approval = $approval
}
