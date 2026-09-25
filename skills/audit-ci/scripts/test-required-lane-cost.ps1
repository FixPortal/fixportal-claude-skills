[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EvidencePath,
    [Parameter(Mandatory)] [string] $ExpectedHeadSha,
    [Parameter(Mandatory)] [string[]] $RequiredJobNames,
    [Parameter(Mandatory)] [double] $BudgetMinutes,
    # Audited repository root. Owner approval of a budget breach is read from its
    # COMMITTED .claude/ci-budget-approval.json, which review-policy.json tiers HIGH.
    [string] $RepositoryRoot,
    # Explicit override for that file's location. Never a temporary object the auditor
    # wrote for itself -- that is provenance-free and leaves no durable record.
    [string] $ApprovalPath
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
foreach ($requiredName in $required) {
    # A matrix job's declared name commonly carries an expression -- `Frontend (${{
    # matrix.node }})` -- and nothing here renders it, so an exact or "name (" match
    # could never hit the Actions job names and every repo using the ordinary matrix
    # naming pattern failed outright, blaming the evidence producer for an omission that
    # had not happened. Match on the literal prefix before the first expression instead.
    $expressionAt = $requiredName.IndexOf('${{', [StringComparison]::Ordinal)
    $matchName = if ($expressionAt -ge 0) { $requiredName.Substring(0, $expressionAt).TrimEnd(' ', '(') } else { $requiredName }
    if ([string]::IsNullOrWhiteSpace($matchName)) {
        throw "Required job name '$requiredName' begins with an expression, so no literal prefix can be matched against measured evidence. Give the job a literal name prefix."
    }
    $legs = @($jobs | Where-Object {
        $_ -is [pscustomobject] -and $_.PSObject.Properties.Name -contains 'name' -and
        ([string] $_.name -eq $matchName -or ([string] $_.name).StartsWith("$matchName (", [StringComparison]::Ordinal))
    })
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
    # object the auditor writes for itself. The committed approval names the measured
    # run's head and id; its head must be an ancestor of the audited tree, so the approval
    # cannot depend on its own commit SHA. The file is tiered HIGH, so changing it is
    # itself reviewed.
    if ([string]::IsNullOrWhiteSpace($ApprovalPath)) {
        if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
            throw "Required-lane measured cost is $aggregate minutes; target is $BudgetMinutes and no repository root was given to locate the committed approval."
        }
        $ApprovalPath = Join-Path $RepositoryRoot '.claude' 'ci-budget-approval.json'
    }
    if (-not $RepositoryRoot) { throw 'A budget exception requires RepositoryRoot so approval provenance can be verified.' }
    $approvalRelativePath = '.claude/ci-budget-approval.json'
    $expectedApprovalPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $approvalRelativePath))
    if ([IO.Path]::GetFullPath($ApprovalPath) -ne $expectedApprovalPath) {
        throw "Owner approval must be read from $expectedApprovalPath."
    }
    $treeEntry = @(& git -C $RepositoryRoot ls-tree $ExpectedHeadSha -- $approvalRelativePath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $treeEntry.Count -ne 1) {
        throw 'Owner approval is not present in the audited commit tree.'
    }
    if ($treeEntry[0] -notmatch '^100(?:644|755) blob [0-9a-f]{40}\s+\.claude/ci-budget-approval\.json$') {
        throw 'Owner approval in the audited tree must be a regular file, not a symlink or other object.'
    }
    $approvalJson = & git -C $RepositoryRoot show "$ExpectedHeadSha`:$approvalRelativePath" 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not read owner approval bytes from the audited commit tree.' }
    try { $approval = ($approvalJson -join "`n") | ConvertFrom-Json }
    catch { throw "Owner approval evidence is malformed JSON: $($_.Exception.Message)" }
    if ($approval -isnot [pscustomobject]) { throw 'Owner approval evidence must be a JSON object.' }
    foreach ($field in 'approved', 'owner', 'approved_at', 'head_sha', 'run_id') {
        if ($approval.PSObject.Properties.Name -notcontains $field) { throw "Owner approval evidence omitted $field." }
    }
    if ($approval.approved -isnot [bool] -or -not $approval.approved) { throw 'Owner approval evidence is not explicitly approved.' }
    if ([string]::IsNullOrWhiteSpace([string] $approval.owner)) { throw 'Owner approval evidence has no owner.' }
    try { [DateTimeOffset]::Parse([string] $approval.approved_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) | Out-Null }
    catch { throw 'Owner approval evidence has an invalid approved_at timestamp.' }
    if ([string]::IsNullOrWhiteSpace([string] $approval.head_sha) -or [string] $approval.head_sha -ne $evidenceHeadSha) {
        throw 'Owner approval must identify the measured run head_sha.'
    }
    if (($approval.run_id -isnot [int] -and $approval.run_id -isnot [long]) -or
        [long] $approval.run_id -ne [long] $evidence.run.id) {
        throw 'Owner approval evidence run_id is missing or stale.'
    }
    & git -C $RepositoryRoot merge-base --is-ancestor $evidenceHeadSha $ExpectedHeadSha 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Owner approval must refer to a measured run on an ancestor of the audited HEAD.' }
}
elseif ($evidenceHeadSha -ne $ExpectedHeadSha) { throw 'Required-lane cost evidence head_sha is stale.' }

[pscustomobject]@{
    Status = if ($aggregate -gt $BudgetMinutes) { 'APPROVED_EXCEPTION' } else { 'COMPLIANT' }
    AggregateMinutes = $aggregate
    CountedJobs = $counted.Count
    # EMITTED, not just recorded. The loop above sets Skipped on its internal list and the
    # output carried only a count, so no consumer could tell a skipped required job from a
    # measured one - while both the comment there and audit-ci/SKILL.md describe a report
    # naming them. An instruction no data path supports is not executable.
    # (CodeRabbit, PR #135.)
    SkippedJobs = @($counted | Where-Object { $_.Skipped } | ForEach-Object { $_.Name })
    HeadSha = $ExpectedHeadSha
    RunId = [long] $evidence.run.id
    Approval = $approval
}
