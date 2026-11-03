$ErrorActionPreference = 'Stop'

$skillRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$workflowInventory = Join-Path $skillRoot 'scripts/get-workflow-inventory.ps1'
$canonicalCompare = Join-Path $skillRoot 'scripts/compare-canonical-file.ps1'
$contractCheck = Join-Path $skillRoot 'scripts/test-scaffold-contract.ps1'
$costCheck = Join-Path $skillRoot 'scripts/test-required-lane-cost.ps1'
$scaffoldRoot = Resolve-Path (Join-Path $skillRoot '..' 'scaffold-ci')
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('audit-ci-mechanics-' + [guid]::NewGuid().ToString('N'))
$headSha = '1111111111111111111111111111111111111111'
$costEvidence = Join-Path $fixtures 'actions-cost-compliant.json'
$validApproval = Join-Path $fixtures 'actions-cost-approval-valid.json'

function Assert-Equal($actual, $expected, [string] $because) {
    $actualText = @($actual) -join "`n"
    $expectedText = @($expected) -join "`n"
    if ($actualText -ne $expectedText) {
        throw "$because`nExpected:`n$expectedText`nActual:`n$actualText"
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $approvalRepo = Join-Path $tempRoot 'approval-repo'
    New-Item -ItemType Directory -Path (Join-Path $approvalRepo '.claude') -Force | Out-Null
    function Invoke-ApprovalGit { $output = & git @args 2>&1; if ($LASTEXITCODE -ne 0) { throw "approval fixture git failed: $output" } }
    # Over-budget evidence (18 minutes over four jobs) measured at $sha.
    function Write-OverBudgetEvidence([string] $sha, [string] $name) {
        $value = Get-Content -LiteralPath (Join-Path $fixtures 'actions-cost-over-budget-matrix.json') -Raw | ConvertFrom-Json
        $value.run.head_sha = $sha
        $value.run | Add-Member -NotePropertyName workflow_id -NotePropertyValue 77 -Force
        $path = Join-Path $tempRoot "$name.json"
        [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 10))
        $path
    }
    # The run the approval names, fetched separately from the audited-head run.
    function Write-ApprovalRunEvidence([string] $name, [string] $head, [long] $id = 4241, [string] $conclusion = 'success', [long] $workflowId = 77) {
        $value = [pscustomobject]@{ run = [pscustomobject]@{ id = $id; head_sha = $head; conclusion = $conclusion; workflow_id = $workflowId } }
        $path = Join-Path $tempRoot "$name.json"
        [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 10))
        $path
    }
    # A refusal must come from the guard the case names. `catch { $failed = $true }`
    # accepted ANY exception, so a case could pass on an unrelated throw.
    function Assert-CostFails([string] $because, [string] $expected, [hashtable] $arguments) {
        $message = $null
        try { & $costCheck @arguments 2>$null | Out-Null } catch { $message = $_.Exception.Message }
        if ($null -eq $message) { throw "$($because): the cost check passed" }
        if ($message -notmatch $expected) { throw "$($because): refused for the wrong reason: $message" }
    }
    Invoke-ApprovalGit -C $approvalRepo init --quiet
    Invoke-ApprovalGit -C $approvalRepo config user.email fixture@example.com
    Invoke-ApprovalGit -C $approvalRepo config user.name Fixture
    Set-Content -LiteralPath (Join-Path $approvalRepo seed.txt) -Value baseline
    Invoke-ApprovalGit -C $approvalRepo add seed.txt
    Invoke-ApprovalGit -C $approvalRepo -c commit.gpgsign=false commit --quiet -m baseline
    $approvalAncestorSha = (& git -C $approvalRepo rev-parse HEAD).Trim()
    # The approval names the run the owner reviewed (on an ancestor) and the most minutes
    # accepted; the EVIDENCE always measures the audited head itself.
    $approvalTemplate = Get-Content -LiteralPath $validApproval -Raw | ConvertFrom-Json
    $approvalTemplate.head_sha = $approvalAncestorSha
    $validApproval = Join-Path $tempRoot 'valid-approval-template.json'
    [IO.File]::WriteAllText($validApproval, ($approvalTemplate | ConvertTo-Json -Depth 10))
    $approvalPath = Join-Path $approvalRepo '.claude/ci-budget-approval.json'
    Copy-Item -LiteralPath $validApproval -Destination $approvalPath
    Invoke-ApprovalGit -C $approvalRepo add .claude/ci-budget-approval.json
    Invoke-ApprovalGit -C $approvalRepo -c commit.gpgsign=false commit --quiet -m approval
    $approvalCommitSha = (& git -C $approvalRepo rev-parse HEAD).Trim()
    $approvalEvidencePath = Write-OverBudgetEvidence $approvalCommitSha 'actions-cost-approved-head'
    $ancestorEvidencePath = Write-OverBudgetEvidence $approvalAncestorSha 'actions-cost-approved-ancestor'
    $approvalRunPath = Write-ApprovalRunEvidence 'approval-run' $approvalAncestorSha
    $laneJobs = @('Backend (.NET)', 'Frontend (UI)', 'Secrets')
    $cost =& $costCheck -EvidencePath (Join-Path $fixtures 'actions-cost-compliant.json') -ExpectedHeadSha $headSha `
        -RequiredJobNames @('Backend (.NET)', 'Frontend (UI)', 'Secrets') -BudgetMinutes 15
    if ($cost.Status -ne 'COMPLIANT' -or $cost.AggregateMinutes -ne 12 -or $cost.CountedJobs -ne 3) {
        throw "Canonical hybrid measured cost was misclassified: $($cost | ConvertTo-Json -Compress)"
    }

    foreach ($case in @(
        @{ Name = 'over-budget matrix'; Path = 'actions-cost-over-budget-matrix.json'; Jobs = @('Backend (.NET)', 'Frontend (UI)') },
        @{ Name = 'missing duration'; Path = 'actions-cost-missing-duration.json'; Jobs = @('Backend (.NET)', 'Frontend (UI)') },
        @{ Name = 'missing head SHA'; Path = 'actions-cost-missing-head.json'; Jobs = @('Backend (.NET)') },
        @{ Name = 'stale head SHA'; Path = 'actions-cost-stale.json'; Jobs = @('Backend (.NET)', 'Frontend (UI)') }
    )) {
        $failed = $false
        try { & $costCheck -EvidencePath (Join-Path $fixtures $case.Path) -ExpectedHeadSha $headSha -RequiredJobNames $case.Jobs -BudgetMinutes 15 2>$null | Out-Null }
        catch { $failed = $true }
        if (-not $failed) { throw "Required-lane cost evidence failed open: $($case.Name)" }
    }
    $missingEvidenceFailed = $false
    try { & $costCheck -EvidencePath (Join-Path $fixtures 'missing-actions-cost.json') -ExpectedHeadSha $headSha -RequiredJobNames @('Backend (.NET)') -BudgetMinutes 15 2>$null | Out-Null }
    catch { $missingEvidenceFailed = $true }
    if (-not $missingEvidenceFailed) { throw 'Missing required-lane cost evidence passed the audit.' }

    $omittedLegPath = Join-Path $tempRoot 'actions-cost-omitted-leg.json'
    $omittedLeg = Get-Content -LiteralPath (Join-Path $fixtures 'actions-cost-over-budget-matrix.json') -Raw | ConvertFrom-Json
    $omittedLeg.jobs = @($omittedLeg.jobs[0], $omittedLeg.jobs[1], $omittedLeg.jobs[3])
    [IO.File]::WriteAllText($omittedLegPath, ($omittedLeg | ConvertTo-Json -Depth 10))
    $omittedLegFailed = $false
    try { & $costCheck -EvidencePath $omittedLegPath -ExpectedHeadSha $headSha -RequiredJobNames @('Backend (.NET)', 'Frontend (UI)', 'Secrets') -BudgetMinutes 15 2>$null | Out-Null }
    catch { $omittedLegFailed = $true }
    if (-not $omittedLegFailed) { throw 'An omitted matrix leg passed despite the jobs total_count mismatch.' }

    # Each case mutates a baseline that PASSES and must be refused by its OWN guard. The
    # cases ran over budget with no RepositoryRoot, so even the unmutated fixture threw
    # and any guard could be deleted with every case still green. Every case is
    # tried before failing, so a removed guard names all the cases it covered.
    $evidenceArguments = @{ ExpectedHeadSha = $headSha; RequiredJobNames = $laneJobs; BudgetMinutes = 60 }
    $baseline = & $costCheck -EvidencePath (Join-Path $fixtures 'actions-cost-over-budget-matrix.json') @evidenceArguments
    if ($baseline.Status -ne 'COMPLIANT') { throw "The invalid-evidence baseline must pass before it is mutated: $($baseline | ConvertTo-Json -Compress)" }
    $openCases = [Collections.Generic.List[string]]::new()
    foreach ($case in @(
        @{ Name = 'missing total_count'; Expect = 'invalid jobs total_count'; Mutate = { param($value) $value.PSObject.Properties.Remove('total_count') } },
        @{ Name = 'negative total_count'; Expect = 'invalid jobs total_count'; Mutate = { param($value) $value.total_count = -1 } },
        @{ Name = 'string total_count'; Expect = 'invalid jobs total_count'; Mutate = { param($value) $value.total_count = '4' } },
        @{ Name = 'missing run id'; Expect = 'omitted a valid run id'; Mutate = { param($value) $value.run.PSObject.Properties.Remove('id') } },
        # `run_attempt` was read only from jobs that carried it, and it was not in the
        # evidence contract - so on canonical evidence the mixed-attempt guard had nothing
        # to read and passed over the payload it was written to refuse. Both halves are
        # pinned: the field is REQUIRED, and two attempts in one payload are refused.
        @{ Name = 'omitted run_attempt'; Expect = 'omits run_attempt'; Mutate = { param($value) $value.jobs[0].PSObject.Properties.Remove('run_attempt') } },
        @{ Name = 'mixed run attempts'; Expect = 'mixes run attempts'; Mutate = { param($value) $value.jobs[0].run_attempt = 2 } },
        # The job `id` is the counting identity and has no fallback. While `name|started_at`
        # stood behind it, evidence collected before SKILL.md step 3 required `id` silently
        # took the lossy path -- which is precisely the payload shape most likely to collapse
        # two legs. Missing, non-numeric and non-positive are all refused. (CodeRabbit, #135.)
        @{ Name = 'omitted job id'; Expect = 'omitted a valid Actions job id'; Mutate = { param($value) $value.jobs[1].PSObject.Properties.Remove('id') } },
        @{ Name = 'null job id'; Expect = 'omitted a valid Actions job id'; Mutate = { param($value) $value.jobs[1].id = $null } },
        @{ Name = 'non-numeric job id'; Expect = 'omitted a valid Actions job id'; Mutate = { param($value) $value.jobs[1].id = 'abc' } },
        @{ Name = 'zero job id'; Expect = 'omitted a valid Actions job id'; Mutate = { param($value) $value.jobs[1].id = 0 } },
        @{ Name = 'negative job id'; Expect = 'omitted a valid Actions job id'; Mutate = { param($value) $value.jobs[1].id = -3 } }
    )) {
        $invalidEvidence = Get-Content -LiteralPath (Join-Path $fixtures 'actions-cost-over-budget-matrix.json') -Raw | ConvertFrom-Json
        & $case.Mutate $invalidEvidence
        $invalidEvidencePath = Join-Path $tempRoot (($case.Name -replace ' ', '-') + '.json')
        [IO.File]::WriteAllText($invalidEvidencePath, ($invalidEvidence | ConvertTo-Json -Depth 10))
        $message = $null
        try { & $costCheck -EvidencePath $invalidEvidencePath @evidenceArguments 2>$null | Out-Null }
        catch { $message = $_.Exception.Message }
        if ($null -eq $message) { $openCases.Add("$($case.Name): passed") }
        elseif ($message -notmatch $case.Expect) { $openCases.Add("$($case.Name): refused for the wrong reason: $message") }
    }
    if ($openCases.Count) { throw "Invalid Actions evidence was not refused by its own guard:`n  $($openCases -join "`n  ")" }

    # Each job belongs to exactly ONE required name. Otherwise a shorter required `Backend`
    # claims the job `Backend (integration)` as one of its legs, and a required `Backend`
    # absent from the evidence passes on another job's measurement.
    function Write-JobEvidence([string] $name, [object[]] $jobList) {
        $value = [pscustomobject]@{
            run = [pscustomobject]@{ id = 4242; head_sha = $headSha; conclusion = 'success' }
            total_count = $jobList.Count
            jobs = $jobList
        }
        $path = Join-Path $tempRoot "$name.json"
        [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 10))
        $path
    }
    function New-EvidenceJob([string] $name, [long] $id, [string] $conclusion = 'success', [string] $started = '2026-08-26T10:00:00Z', [string] $completed = '2026-08-26T10:02:00Z') {
        [pscustomobject]@{ id = $id; name = $name; started_at = $started; completed_at = $completed; conclusion = $conclusion; run_attempt = 1 }
    }
    $nestedNames = @('Backend', 'Backend (integration)')
    $absorbedPath = Write-JobEvidence 'absorbed-shorter-name' @((New-EvidenceJob 'Backend (integration)' 2001))
    Assert-CostFails 'A required job absent from the evidence was satisfied by a longer job name' "omitted job 'Backend'" `
        @{ EvidencePath = $absorbedPath; ExpectedHeadSha = $headSha; RequiredJobNames = $nestedNames; BudgetMinutes = 60 }
    $bothPresentPath = Write-JobEvidence 'nested-names-present' @((New-EvidenceJob 'Backend (unit)' 2001), (New-EvidenceJob 'Backend (integration)' 2002))
    $bothPresent = & $costCheck -EvidencePath $bothPresentPath -ExpectedHeadSha $headSha -RequiredJobNames $nestedNames -BudgetMinutes 60
    if ($bothPresent.CountedJobs -ne 2 -or $bothPresent.AggregateMinutes -ne 4) { throw "Nested required names were miscounted: $($bothPresent | ConvertTo-Json -Compress)" }

    # The literal text AFTER an expression is part of the name. Cutting at the first
    # expression reduced `Frontend (${{ matrix.node }}) tests` to `Frontend`, which claimed
    # an unrelated `Frontend (22) lint` as one of its legs.
    $templateNames = @('Frontend (${{ matrix.node }}) tests')
    $templatePath = Write-JobEvidence 'template-suffix' @((New-EvidenceJob 'Frontend (22) tests' 2101), (New-EvidenceJob 'Frontend (22) lint' 2102))
    $template = & $costCheck -EvidencePath $templatePath -ExpectedHeadSha $headSha -RequiredJobNames $templateNames -BudgetMinutes 60
    if ($template.CountedJobs -ne 1 -or $template.AggregateMinutes -ne 2) { throw "A matrix name template claimed a job whose literal suffix differs: $($template | ConvertTo-Json -Compress)" }
    $lintOnlyPath = Write-JobEvidence 'template-suffix-absent' @((New-EvidenceJob 'Frontend (22) lint' 2102))
    Assert-CostFails 'A matrix name template was satisfied by a job with a different literal suffix' 'omitted job' `
        @{ EvidencePath = $lintOnlyPath; ExpectedHeadSha = $headSha; RequiredJobNames = $templateNames; BudgetMinutes = 60 }

    # A skipped required job contributes no minutes and is named in SkippedJobs, so it
    # is not a COUNTED job. The timestamps are the real API shape for a job skipped
    # by `if:` -- both present, completion one second BEFORE start (observed on
    # a consumer CI run, 2026-11-01).
    $skippedPath = Write-JobEvidence 'skipped-required-job' @(
        (New-EvidenceJob 'Backend (.NET)' 2201),
        (New-EvidenceJob 'Secrets' 2202 'skipped' '2026-08-26T10:41:30Z' '2026-08-26T10:41:29Z'))
    $skipped = & $costCheck -EvidencePath $skippedPath -ExpectedHeadSha $headSha -RequiredJobNames @('Backend (.NET)', 'Secrets') -BudgetMinutes 60
    if ($skipped.CountedJobs -ne 1 -or (@($skipped.SkippedJobs) -join ',') -ne 'Secrets' -or $skipped.AggregateMinutes -ne 2) {
        throw "A skipped required job was counted as measured: $($skipped | ConvertTo-Json -Compress)"
    }

    # -ApprovalPath could only ever equal the committed path RepositoryRoot already names.
    foreach ($script in $costCheck, $contractCheck) {
        if ((Get-Command -Name $script).Parameters.ContainsKey('ApprovalPath')) { throw "$script still declares the redundant -ApprovalPath parameter." }
    }

    # Two required legs may share a display NAME and a start SECOND - GitHub permits two
    # job ids to declare the same `name:`, and the Actions API reports started_at to the
    # second. Identity was `name|started_at`, so the second leg was dropped and the lane
    # understated, turning an APPROVED_EXCEPTION into COMPLIANT. Keyed on the job `id`,
    # both are counted. (CodeRabbit, PR #135.)
    $collidingPath = Join-Path $tempRoot 'colliding-legs.json'
    $colliding = Get-Content -LiteralPath $approvalEvidencePath -Raw | ConvertFrom-Json
    $colliding.jobs[1].name = $colliding.jobs[0].name
    $colliding.jobs[1].started_at = $colliding.jobs[0].started_at
    $colliding.jobs[1].completed_at = $colliding.jobs[0].completed_at
    [IO.File]::WriteAllText($collidingPath, ($colliding | ConvertTo-Json -Depth 10))
    $collidingResult = & $costCheck -EvidencePath $collidingPath -ExpectedHeadSha $approvalCommitSha `
        -RequiredJobNames @('Backend (.NET)', 'Frontend (UI)', 'Secrets') -BudgetMinutes 15 -RepositoryRoot $approvalRepo `
        -ApprovalRunEvidencePath $approvalRunPath
    if ($collidingResult.CountedJobs -ne 4) {
        throw "two legs sharing a name and a start second collapsed: counted $($collidingResult.CountedJobs) of 4"
    }

    $approved = & $costCheck -EvidencePath $approvalEvidencePath -ExpectedHeadSha $approvalCommitSha `
        -RequiredJobNames @('Backend (.NET)', 'Frontend (UI)', 'Secrets') -BudgetMinutes 15 -RepositoryRoot $approvalRepo `
        -ApprovalRunEvidencePath $approvalRunPath
    if ($approved.Status -ne 'APPROVED_EXCEPTION' -or $approved.AggregateMinutes -ne 18 -or $approved.CountedJobs -ne 4 -or
        $approved.MeasuredHeadSha -ne $approvalCommitSha) {
        throw "Approved measured exception was misclassified: $($approved | ConvertTo-Json -Compress)"
    }

    # The approval's run_id is provenance and must be VERIFIED from the run fetched
    # separately; a bare positive integer must not yield APPROVED_EXCEPTION. Each case differs
    # from the passing call above in exactly one respect.
    $approvalRunArguments = @{ EvidencePath = $approvalEvidencePath; ExpectedHeadSha = $approvalCommitSha; RequiredJobNames = $laneJobs; BudgetMinutes = 15; RepositoryRoot = $approvalRepo }
    Assert-CostFails 'An approval was accepted with no evidence for its run_id' 'approval run evidence is missing' $approvalRunArguments
    foreach ($case in @(
        @{ Name = 'another run id'; Expect = 'does not describe the approval run_id'; Path = (Write-ApprovalRunEvidence 'approval-run-other-id' $approvalAncestorSha 9999) },
        @{ Name = 'unsuccessful run'; Expect = 'did not conclude successfully'; Path = (Write-ApprovalRunEvidence 'approval-run-failed' $approvalAncestorSha 4241 'failure') },
        @{ Name = 'run at another head'; Expect = 'head_sha does not match'; Path = (Write-ApprovalRunEvidence 'approval-run-other-head' $approvalCommitSha) },
        @{ Name = 'run of another workflow'; Expect = 'different workflow'; Path = (Write-ApprovalRunEvidence 'approval-run-other-workflow' $approvalAncestorSha 4241 'success' 78) }
    )) {
        Assert-CostFails "Approval run provenance ($($case.Name))" $case.Expect ($approvalRunArguments + @{ ApprovalRunEvidencePath = $case.Path })
    }

    # A stale payload must be reported as stale even when it also carries a job-level fault;
    # the head check ran after the job loop, so the job's error masked the real cause.
    $staleAndFailed = Get-Content -LiteralPath $approvalEvidencePath -Raw | ConvertFrom-Json
    $staleAndFailed.run.head_sha = $approvalAncestorSha
    $staleAndFailed.jobs[1].conclusion = 'failure'
    $staleAndFailedPath = Join-Path $tempRoot 'stale-and-failed-job.json'
    [IO.File]::WriteAllText($staleAndFailedPath, ($staleAndFailed | ConvertTo-Json -Depth 10))
    Assert-CostFails 'A stale payload with a failed job was blamed on the job' 'head_sha is stale' `
        @{ EvidencePath = $staleAndFailedPath; ExpectedHeadSha = $approvalCommitSha; RequiredJobNames = $laneJobs; BudgetMinutes = 15; RepositoryRoot = $approvalRepo }

    # The approved ANCESTOR run's evidence must not stand for the audited HEAD. It did:
    # after one approval every later HEAD came back APPROVED_EXCEPTION on the old run's
    # minutes, however much the lane had grown, with HEAD reported as measured.
    Assert-CostFails 'An approved ancestor run stood in for the unmeasured audited HEAD' 'head_sha is stale' `
        @{ EvidencePath = $ancestorEvidencePath; ExpectedHeadSha = $approvalCommitSha; RequiredJobNames = $laneJobs; BudgetMinutes = 15; RepositoryRoot = $approvalRepo }

    Assert-CostFails 'Approval from local HEAD was accepted when ExpectedHeadSha omitted it' 'not present in the audited commit tree' `
        @{ EvidencePath = $ancestorEvidencePath; ExpectedHeadSha = $approvalAncestorSha; RequiredJobNames = $laneJobs; BudgetMinutes = 15; RepositoryRoot = $approvalRepo }

    function Write-ApprovalVariant([string] $path, [scriptblock] $change) {
        $value = Get-Content -LiteralPath $validApproval -Raw | ConvertFrom-Json
        & $change $value
        [IO.File]::WriteAllText($path, ($value | ConvertTo-Json))
    }
    foreach ($case in @(
        @{ Name = 'malformed approval'; Expect = 'malformed JSON'; Mutate = { param($path) [IO.File]::WriteAllText($path, 'banana') } },
        @{ Name = 'approval missing owner'; Expect = 'omitted owner'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.PSObject.Properties.Remove('owner') } } },
        @{ Name = 'approval missing date'; Expect = 'omitted approved_at'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.PSObject.Properties.Remove('approved_at') } } },
        @{ Name = 'approval invalid date'; Expect = 'invalid approved_at'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.approved_at = 'banana' } } },
        @{ Name = 'approval not approved'; Expect = 'not explicitly approved'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.approved = $false } } },
        @{ Name = 'approval stale SHA'; Expect = 'ancestor of the audited HEAD'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.head_sha = '2222222222222222222222222222222222222222' } } },
        @{ Name = 'approval head_sha not an object id'; Expect = 'identify the reviewed run head_sha'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.head_sha = '--output=pwned' } } },
        @{ Name = 'approval invalid run_id'; Expect = 'run_id is missing or invalid'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.run_id = 'abc' } } },
        # The bound on HEAD's own measurement. Without it an approval is permanent.
        @{ Name = 'approval missing max_minutes'; Expect = 'omitted max_minutes'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.PSObject.Properties.Remove('max_minutes') } } },
        @{ Name = 'approval zero max_minutes'; Expect = 'max_minutes must be a positive number'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.max_minutes = 0 } } },
        @{ Name = 'approval string max_minutes'; Expect = 'max_minutes must be a positive number'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.max_minutes = '30' } } },
        @{ Name = 'lane grew past the approval'; Expect = 'above the approved max_minutes'; Mutate = { param($path) Write-ApprovalVariant $path { param($v) $v.max_minutes = 17 } } }
    )) {
        $invalidApprovalPath = Join-Path $tempRoot (($case.Name -replace ' ', '-') + '.json')
        & $case.Mutate $invalidApprovalPath
        Copy-Item -LiteralPath $invalidApprovalPath -Destination $approvalPath -Force
        Invoke-ApprovalGit -C $approvalRepo add .claude/ci-budget-approval.json
        Invoke-ApprovalGit -C $approvalRepo -c commit.gpgsign=false commit --quiet -m "invalid $($case.Name)"
        $invalidApprovalHead = (& git -C $approvalRepo rev-parse HEAD).Trim()
        # Measured AT the audited head, so only the approval itself can refuse it.
        $invalidHeadEvidence = Write-OverBudgetEvidence $invalidApprovalHead (($case.Name -replace ' ', '-') + '-evidence')
        Assert-CostFails "Invalid approval evidence ($($case.Name))" $case.Expect `
            @{ EvidencePath = $invalidHeadEvidence; ExpectedHeadSha = $invalidApprovalHead; RequiredJobNames = $laneJobs; BudgetMinutes = 15; RepositoryRoot = $approvalRepo }
    }
    Invoke-ApprovalGit -C $approvalRepo rm .claude/ci-budget-approval.json
    Invoke-ApprovalGit -C $approvalRepo -c commit.gpgsign=false commit --quiet -m remove-approval
    New-Item -ItemType Directory -Path (Join-Path $approvalRepo '.claude') -Force | Out-Null
    Copy-Item -LiteralPath $validApproval -Destination $approvalPath
    $untrackedApprovalHead = (& git -C $approvalRepo rev-parse HEAD).Trim()
    $untrackedEvidence = Write-OverBudgetEvidence $untrackedApprovalHead 'untracked-approval-evidence'
    Assert-CostFails 'An untracked CI-budget approval passed the audit' 'not present in the audited commit tree' `
        @{ EvidencePath = $untrackedEvidence; ExpectedHeadSha = $untrackedApprovalHead; RequiredJobNames = $laneJobs; BudgetMinutes = 15; RepositoryRoot = $approvalRepo }

    # A SHA-256 repository writes 64-hex object ids, and the tree-entry pattern accepted
    # only 40, so a valid committed approval there was refused as "not a regular file".
    $sha256Repo = Join-Path $tempRoot 'approval-repo-sha256'
    New-Item -ItemType Directory -Path (Join-Path $sha256Repo '.claude') -Force | Out-Null
    Invoke-ApprovalGit -C $sha256Repo init --quiet --object-format=sha256
    Invoke-ApprovalGit -C $sha256Repo config user.email fixture@example.com
    Invoke-ApprovalGit -C $sha256Repo config user.name Fixture
    Set-Content -LiteralPath (Join-Path $sha256Repo seed.txt) -Value baseline
    Invoke-ApprovalGit -C $sha256Repo add seed.txt
    Invoke-ApprovalGit -C $sha256Repo -c commit.gpgsign=false commit --quiet -m baseline
    $sha256Ancestor = (& git -C $sha256Repo rev-parse HEAD).Trim()
    if ($sha256Ancestor.Length -ne 64) { throw "the SHA-256 fixture produced a $($sha256Ancestor.Length)-character id; the case would be vacuous" }
    Write-ApprovalVariant (Join-Path $sha256Repo '.claude/ci-budget-approval.json') { param($v) $v.head_sha = $sha256Ancestor }
    Invoke-ApprovalGit -C $sha256Repo add .claude/ci-budget-approval.json
    Invoke-ApprovalGit -C $sha256Repo -c commit.gpgsign=false commit --quiet -m approval
    $sha256Head = (& git -C $sha256Repo rev-parse HEAD).Trim()
    $sha256Evidence = Write-OverBudgetEvidence $sha256Head 'sha256-approval-evidence'
    $sha256RunPath = Write-ApprovalRunEvidence 'sha256-approval-run' $sha256Ancestor
    $sha256Result = & $costCheck -EvidencePath $sha256Evidence -ExpectedHeadSha $sha256Head -RequiredJobNames $laneJobs -BudgetMinutes 15 -RepositoryRoot $sha256Repo -ApprovalRunEvidencePath $sha256RunPath
    if ($sha256Result.Status -ne 'APPROVED_EXCEPTION') { throw "A committed approval in a SHA-256 repository was refused: $($sha256Result | ConvertTo-Json -Compress)" }

    New-Item -ItemType Directory -Path (Join-Path $tempRoot '.github/workflows') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tempRoot '.github/workflows/ci.yml') -Value 'name: ci'
    Set-Content -LiteralPath (Join-Path $tempRoot '.github/workflows/deploy.yaml') -Value 'name: deploy'
    Set-Content -LiteralPath (Join-Path $tempRoot '.github/workflows/readme.txt') -Value 'not a workflow'

    $inventory = @(& $workflowInventory -RepositoryRoot $tempRoot)
    Assert-Equal $inventory @('.github/workflows/ci.yml', '.github/workflows/deploy.yaml') 'Inventory must include both workflow extensions and nothing else.'

    $canonical = Join-Path $tempRoot 'canonical.txt'
    $sameEol = Join-Path $tempRoot 'same-eol.txt'
    $drifted = Join-Path $tempRoot 'drifted.txt'
    [IO.File]::WriteAllText($canonical, "one`ntwo`n")
    [IO.File]::WriteAllText($sameEol, "one`r`ntwo`r`n")
    [IO.File]::WriteAllText($drifted, "one`r`nchanged`r`n")

    & $canonicalCompare -ActualPath $sameEol -CanonicalPath $canonical -IgnoreLineEndings | Out-Null

    $driftFailed = $false
    try { & $canonicalCompare -ActualPath $drifted -CanonicalPath $canonical -IgnoreLineEndings 2>$null | Out-Null }
    catch { $driftFailed = $true }
    if (-not $driftFailed) { throw 'Content drift must fail a copy-only comparison.' }

    $repo = Join-Path $tempRoot 'repo'
    New-Item -ItemType Directory -Path (Join-Path $repo '.github/workflows') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo '.github/scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repo '.github/canonical-assets.json') -Value '{}'
    Set-Content -LiteralPath (Join-Path $repo '.claude/ci-budget-approval.json') -Value '{}'
    # Double-quoted: single quotes wrote a literal backtick-n, not newlines.
    Set-Content -LiteralPath (Join-Path $repo '.coderabbit.yaml') -Value "reviews:`n  auto_review:`n    enabled: false"
    if ([IO.File]::ReadAllText((Join-Path $repo '.coderabbit.yaml')).Contains('`n')) { throw 'the .coderabbit.yaml fixture holds a literal backtick-n instead of newlines' }
    Copy-Item (Join-Path $scaffoldRoot 'assets/assert_gate_coverage.py') (Join-Path $repo '.github/scripts/assert_gate_coverage.py')
    Copy-Item (Join-Path $scaffoldRoot 'assets/assert_workflow_hygiene.py') (Join-Path $repo '.github/scripts/assert_workflow_hygiene.py')
    Copy-Item (Join-Path $scaffoldRoot 'assets/review-policy-guard.yml') (Join-Path $repo '.github/workflows/review-policy-guard.yml')
    # A real target-context trigger, as the rollout ships it. A stub with no `on:` let the
    # contract pass while it ran hygiene without the guard's PRIVILEGED_TRIGGER_NO_CHECKOUT,
    # which failed every real repo carrying review-tier.yml.
    $reviewTier = "name: Review tier`non:`n  pull_request_target:`n    types: [opened, synchronize]`npermissions:`n  pull-requests: write`njobs:`n  tier:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: echo tier`n"
    [IO.File]::WriteAllText((Join-Path $repo '.github/workflows/review-tier.yml'), $reviewTier)
    Copy-Item (Join-Path $scaffoldRoot 'assets/review-policy.example.json') (Join-Path $repo '.claude/review-policy.json')

    $workflow = @'
name: CI
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    name: Backend (.NET)
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-dotnet@v6
      - run: |
          dotnet tool restore
      - run: |
          dotnet csharpier check .
      - run: |
          dotnet restore Example.sln
      - run: |
          dotnet test Example.sln --blame-hang-timeout 30s
  frontend:
    name: Frontend (UI)
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - run: echo frontend
  secrets:
    name: Secrets
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - if: github.event_name == 'pull_request'
        run: |
          "$RUNNER_TEMP/gitleaks" git -v --redact --log-opts="--diff-merges=remerge ${BASE_SHA}..${HEAD_SHA}" .
      - if: github.event_name == 'push'
        run: |
          "$RUNNER_TEMP/gitleaks" git -v --redact --log-opts="--diff-merges=remerge ${range}" .
      - run: |
          "$RUNNER_TEMP/gitleaks" dir -v --redact -i .gitleaksignore-tree .
  publish:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: build
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - name: Assert the tagged commit is reachable from main
        run: |
          set -euo pipefail
          git fetch --no-tags origin main
          if ! git merge-base --is-ancestor "$GITHUB_SHA" FETCH_HEAD; then
            echo "::error::unreviewed tag"
            exit 1
          fi
      - uses: actions/setup-dotnet@v6
      - run: dotnet pack Example.sln --no-build
  gate-coverage:
    name: Gate coverage
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v7
      - run: python3 .github/scripts/assert_gate_coverage.py .github/workflows/ci.yml
        env:
          GATE_EXEMPT: publish
  ci-gate:
    name: CI Gate
    if: always()
    needs: [build, frontend, secrets, gate-coverage]
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions: {}
    steps:
      - if: always() && (contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled'))
        run: exit 1
'@
    $workflowPath = Join-Path $repo '.github/workflows/ci.yml'
    [IO.File]::WriteAllText($workflowPath, $workflow.Replace("`r`n", "`n"))
    $extended = @'
name: Extended tests
on:
  workflow_dispatch:
  schedule:
    - cron: '17 3 * * 2'
permissions:
  contents: read
jobs:
  extended-tests:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v7
      - run: dotnet test tests/Example.ExtendedTests/Example.ExtendedTests.csproj
'@
    $extendedPath = Join-Path $repo '.github/workflows/extended-tests.yml'
    [IO.File]::WriteAllText($extendedPath, $extended.Replace("`r`n", "`n"))
    $release = @'
name: Release
on:
  push:
    branches:
      - main
    tags:
      - 'v*'
permissions:
  contents: read
jobs:
  ship:
    continue-on-error: false # ancestry failures remain blocking
    name: Ship
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - name: Assert the tagged commit is reachable from main
        continue-on-error: false # ancestry failures remain blocking
        run: |
          set -euo pipefail
          # ship ancestry
          git fetch --no-tags origin main
          if ! git merge-base --is-ancestor "$GITHUB_SHA" FETCH_HEAD; then
            echo "::error::unreviewed tag"
            exit 1
          fi
      - run: dotnet pack Example.sln --no-build
  deliver:
    if: github.ref_type == 'tag'
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - if: startsWith(github.ref, 'refs/tags/')
        run: |
          set -euo pipefail
          # deliver ancestry
          git fetch --no-tags origin main
          if ! git merge-base --is-ancestor "$GITHUB_SHA" FETCH_HEAD; then
            echo "::error::unreviewed deliver tag"
            exit 1
          fi
      - run: gh release create "$GITHUB_REF_NAME"
  opaque:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - if: github.ref_type == 'tag'
        run: |
          set -euo pipefail
          # opaque ancestry
          git fetch --no-tags origin main
          if ! git merge-base --is-ancestor "$GITHUB_SHA" FETCH_HEAD; then
            echo "::error::unreviewed opaque tag"
            exit 1
          fi
      - if: github.ref_type == 'tag'
        run: npm publish
'@
    $releasePath = Join-Path $repo '.github/workflows/release.yml'
    [IO.File]::WriteAllText($releasePath, $release.Replace("`r`n", "`n"))
    Invoke-ApprovalGit -C $repo init --quiet
    Invoke-ApprovalGit -C $repo config user.email fixture@example.com
    Invoke-ApprovalGit -C $repo config user.name Fixture
    Invoke-ApprovalGit -C $repo add -A
    Invoke-ApprovalGit -C $repo -c commit.gpgsign=false commit --quiet -m audited-tree
    $repoApprovalAncestor = (& git -C $repo rev-parse HEAD).Trim()
    # NO ambient GATE_EXEMPT. The fixture declares `GATE_EXEMPT: publish` on its own
    # gate-coverage step, exactly as the skeleton ships `GATE_EXEMPT: docker`, and the
    # audit must read it from there. Injecting it into the auditor's process was the
    # workaround that hid the defect: the audit ran the checker with an empty environment
    # and scored every publishing or deploying repo as structurally failing a control it
    # satisfies.
    $priorGateExempt = $env:GATE_EXEMPT
    $priorPrivilegedTrigger = $env:PRIVILEGED_TRIGGER_NO_CHECKOUT
    $env:GATE_EXEMPT = $null
    $env:PRIVILEGED_TRIGGER_NO_CHECKOUT = 'caller-sentinel'
    $contractArguments = @{
        RepositoryRoot = $repo
        ScaffoldRoot = $scaffoldRoot
        ActionsEvidencePath = $costEvidence
        ExpectedHeadSha = $headSha
    }
    # The cases below edit the fixture's working tree on purpose, without committing; the
    # clean-checkout guard has its own cases that omit this switch.
    $contractArguments.AllowDirtyCheckout = $true
    $cleanContractArguments = @{ RepositoryRoot = $repo; ScaffoldRoot = $scaffoldRoot; ActionsEvidencePath = $costEvidence; ExpectedHeadSha = $headSha }
    $missingContractEvidenceFailed = $false
    try { & $contractCheck -RepositoryRoot $repo -ScaffoldRoot $scaffoldRoot -ExpectedHeadSha $headSha 2>$null | Out-Null }
    catch { $missingContractEvidenceFailed = $true }
    if (-not $missingContractEvidenceFailed) { throw 'The scaffold contract passed without measured Actions evidence.' }
    $contractResult = & $contractCheck @contractArguments
    # Job names come from this checkout while the evidence measures ExpectedHeadSha, so
    # the result records the checkout's own HEAD.
    if ($contractResult.CheckoutHeadSha -ne $repoApprovalAncestor) {
        throw "The scaffold contract did not record the checkout HEAD: '$($contractResult.CheckoutHeadSha)' vs '$repoApprovalAncestor'"
    }
    function Assert-ContractFails([string] $because, [string] $expected, [hashtable] $arguments = $contractArguments) {
        $message = $null
        try { & $contractCheck @arguments 2>$null | Out-Null } catch { $message = "$_" }
        if ($null -eq $message) { throw "$($because): the contract passed" }
        if ($message -notmatch $expected) { throw "$($because): failed for the wrong reason: $message" }
    }

    # A matching CheckoutHeadSha says nothing about the working tree the checker actually
    # reads. A clean tree passes; a modified tracked workflow and an untracked one are each
    # refused, and the tree is restored after.
    & $contractCheck @cleanContractArguments | Out-Null
    $dirtyExtendedOriginal = [IO.File]::ReadAllText($extendedPath)
    [IO.File]::WriteAllText($extendedPath, $dirtyExtendedOriginal + "# uncommitted`n")
    Assert-ContractFails 'A modified tracked workflow passed against an unchanged CheckoutHeadSha' 'differ from the checkout HEAD' $cleanContractArguments
    [IO.File]::WriteAllText($extendedPath, $dirtyExtendedOriginal)
    $untrackedWorkflowPath = Join-Path $repo '.github/workflows/untracked-extra.yml'
    [IO.File]::WriteAllText($untrackedWorkflowPath, "name: Untracked`n")
    Assert-ContractFails 'An untracked workflow passed against an unchanged CheckoutHeadSha' 'differ from the checkout HEAD' $cleanContractArguments
    Remove-Item -LiteralPath $untrackedWorkflowPath -Force
    # Code review: a gitignored workflow is read like any other, so it is refused too;
    # a bytecode cache under .github/scripts is not.
    $gitignorePath = Join-Path $repo '.gitignore'
    [IO.File]::WriteAllText($gitignorePath, "ignored-extra.yml`n__pycache__/`n")
    $ignoredWorkflowPath = Join-Path $repo '.github/workflows/ignored-extra.yml'
    [IO.File]::WriteAllText($ignoredWorkflowPath, "name: Ignored`n")
    Assert-ContractFails 'A gitignored workflow passed against an unchanged CheckoutHeadSha' 'differ from the checkout HEAD' $cleanContractArguments
    Remove-Item -LiteralPath $ignoredWorkflowPath -Force
    $pycachePath = Join-Path $repo '.github/scripts/__pycache__'
    New-Item -ItemType Directory -Path $pycachePath | Out-Null
    $pycacheFile = Join-Path $pycachePath 'x.cpython-312.pyc'
    [IO.File]::WriteAllText($pycacheFile, 'cache')
    & $contractCheck @cleanContractArguments | Out-Null
    Remove-Item -LiteralPath $pycacheFile -Force
    Remove-Item -LiteralPath $pycachePath -Force
    Remove-Item -LiteralPath $gitignorePath -Force
    # A git checkout whose status cannot be read is a failure, not a skip.
    $indexPath = Join-Path $repo '.git/index'
    $indexBytes = [IO.File]::ReadAllBytes($indexPath)
    [IO.File]::WriteAllText($indexPath, 'not an index')
    try { Assert-ContractFails 'An unreadable git status was skipped' 'git status failed' $cleanContractArguments }
    finally { [IO.File]::WriteAllBytes($indexPath, $indexBytes) }
    & $contractCheck @cleanContractArguments | Out-Null
    # Code review: an index flag hides a modified workflow from git status.
    $extendedRelative = [IO.Path]::GetRelativePath($repo, $extendedPath).Replace('\', '/')
    foreach ($flag in '--assume-unchanged', '--skip-worktree') {
        Invoke-ApprovalGit -C $repo update-index $flag $extendedRelative
        [IO.File]::WriteAllText($extendedPath, $dirtyExtendedOriginal + "# hidden by $flag`n")
        try { Assert-ContractFails "A workflow modified under $flag passed" 'differ from the checkout HEAD' $cleanContractArguments }
        finally {
            [IO.File]::WriteAllText($extendedPath, $dirtyExtendedOriginal)
            Invoke-ApprovalGit -C $repo update-index ($flag -replace '^--', '--no-') $extendedRelative
        }
    }
    & $contractCheck @cleanContractArguments | Out-Null

    # The audited repository's OWN gate scripts must never run. A canonical-compare
    # failure is recorded rather than thrown, and the drifted copies then executed inside
    # the auditor's environment. The scaffold's copies run instead.
    $gateScriptPath = Join-Path $repo '.github/scripts/assert_gate_coverage.py'
    $hygieneScriptPath = Join-Path $repo '.github/scripts/assert_workflow_hygiene.py'
    $repoCodeSentinel = Join-Path $tempRoot 'audited-repo-code-ran.txt'
    $hostileScript = "open(r'$repoCodeSentinel', 'a').write('ran')`n"
    [IO.File]::WriteAllText($gateScriptPath, $hostileScript)
    [IO.File]::WriteAllText($hygieneScriptPath, $hostileScript)
    Assert-ContractFails 'Drifted gate scripts' 'Scaffold asset drift: \.github/scripts/assert_gate_coverage\.py'
    Copy-Item (Join-Path $scaffoldRoot 'assets/assert_gate_coverage.py') $gateScriptPath -Force
    Copy-Item (Join-Path $scaffoldRoot 'assets/assert_workflow_hygiene.py') $hygieneScriptPath -Force
    if (Test-Path -LiteralPath $repoCodeSentinel) { throw "The audit executed the audited repository's own drifted gate script." }

    # A CRASHING hygiene checker prints a traceback with no ::error line, and the failure
    # read "Workflow hygiene failed: " with nothing after it. Both copies crash, so
    # the case holds whichever copy the audit runs.
    $crashScaffold = Join-Path $tempRoot 'crash-scaffold'
    Copy-Item -LiteralPath $scaffoldRoot -Destination $crashScaffold -Recurse
    $crasher = "raise RuntimeError('hygiene-crash-marker')`n"
    [IO.File]::WriteAllText((Join-Path $crashScaffold 'assets/assert_workflow_hygiene.py'), $crasher)
    [IO.File]::WriteAllText($hygieneScriptPath, $crasher)
    $crashMessage = $null
    $crashArguments = $contractArguments.Clone()
    $crashArguments.ScaffoldRoot = $crashScaffold
    try { & $contractCheck @crashArguments 2>$null | Out-Null } catch { $crashMessage = "$_" }
    Copy-Item (Join-Path $scaffoldRoot 'assets/assert_workflow_hygiene.py') $hygieneScriptPath -Force
    if ($crashMessage -notmatch 'Workflow hygiene failed: .*hygiene-crash-marker') {
        throw "A crashing hygiene checker was reported without its output: $crashMessage"
    }
    # TWO independent defects in one tree must BOTH be reported, with a non-zero exit. The
    # checker stopped at its first throw, so an operator fixing one finding found the next
    # only on the following run.
    $hygienePath = Join-Path $repo '.github/scripts/assert_workflow_hygiene.py'
    $hygieneOriginal = [IO.File]::ReadAllText($hygienePath)
    [IO.File]::WriteAllText($hygienePath, $hygieneOriginal + "# drift`n")
    $alwaysPublish = $release.Replace("      - run: gh release create", "      - if: always()`n        run: gh release create")
    if ($alwaysPublish -eq $release) { throw 'the always() publish fixture mutated nothing; the case would be vacuous' }
    [IO.File]::WriteAllText($releasePath, $alwaysPublish.Replace("`r`n", "`n"))
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $twoFailureOutput = (& pwsh -NoProfile -File $contractCheck -RepositoryRoot $repo -ScaffoldRoot $scaffoldRoot `
            -ActionsEvidencePath $costEvidence -ExpectedHeadSha $headSha -AllowDirtyCheckout 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $twoFailureExit = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    [IO.File]::WriteAllText($hygienePath, $hygieneOriginal)
    [IO.File]::WriteAllText($releasePath, $release.Replace("`r`n", "`n"))
    if ($twoFailureExit -eq 0) { throw 'A tree with two contract failures exited zero.' }
    # pwsh on a CI runner word-wraps the error record into "      | " gutter lines, so
    # flatten ANSI, the gutter and whitespace before matching.
    $twoFailureOutput = $twoFailureOutput -replace '\x1b\[[0-9;]*m', '' -replace '\s*\|\s+', ' ' -replace '\s+', ' '
    foreach ($expected in 'Scaffold asset drift: .github/scripts/assert_workflow_hygiene.py', "job 'deliver' in 'release.yml' has a publish/deploy step that runs regardless") {
        if (-not $twoFailureOutput.Contains($expected)) { throw "Two-failure run did not report '$expected'. Output: $twoFailureOutput" }
    }
    if ($env:PRIVILEGED_TRIGGER_NO_CHECKOUT -ne 'caller-sentinel') {
        throw "The scaffold contract did not restore the caller's PRIVILEGED_TRIGGER_NO_CHECKOUT environment value."
    }
    function Remove-FirstShipAncestry([string]$text) {
        $needle = 'if ! git merge-base --is-ancestor'
        $at = $text.IndexOf($needle, [StringComparison]::Ordinal)
        if ($at -lt 0) { throw 'ship ancestry assertion fixture did not match' }
        $text.Remove($at, $needle.Length).Insert($at, 'echo missing ancestry assertion')
    }
    $branchAndTagJob = $release.Replace(
        "  ship:`n",
        "  ship:`n    if: github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')`n")
    $branchAndTagJob = Remove-FirstShipAncestry $branchAndTagJob
    [IO.File]::WriteAllText($releasePath, $branchAndTagJob.Replace("`r`n", "`n"))
    $branchAndTagFailed = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $branchAndTagFailed = $true }
    if (-not $branchAndTagFailed) { throw 'A tag-capable branch-and-tag job skipped ancestry validation.' }
    [IO.File]::WriteAllText($releasePath, $release.Replace("`r`n", "`n"))
    $shipLacksAncestry = "job 'ship' in 'release\.yml' must have exactly one ancestry assertion"
    $mainlineNameGate = $release.Replace("  ship:`n", "  ship:`n    if: github.ref_name == 'main' && github.ref_type == 'branch'`n")
    $mainlineNameGate = Remove-FirstShipAncestry $mainlineNameGate
    [IO.File]::WriteAllText($releasePath, $mainlineNameGate.Replace("`r`n", "`n"))
    try { & $contractCheck @contractArguments | Out-Null }
    catch { throw "A github.ref_name mainline-only job was incorrectly treated as tag-capable: $_" }
    # `ref_name == 'main'` ALONE is also true for a TAG named `main`, so it does not prove
    # a branch-only job.
    $refNameOnlyIf = $release.Replace("  ship:`n", "  ship:`n    if: github.ref_name == 'main'`n")
    if ($refNameOnlyIf -eq $release) { throw 'the ref_name-only fixture mutated nothing; the case would be vacuous' }
    $refNameOnly = Remove-FirstShipAncestry $refNameOnlyIf
    [IO.File]::WriteAllText($releasePath, $refNameOnly.Replace("`r`n", "`n"))
    Assert-ContractFails 'A ref_name-only mainline job (true for a tag named main) skipped ancestry validation' $shipLacksAncestry
    # A NEGATED mainline comparison has no `||` and is true on every tag.
    $negatedGateIf = $release.Replace("  ship:`n", "  ship:`n    if: `${{ !(github.ref == 'refs/heads/main') }}`n")
    if ($negatedGateIf -eq $release) { throw 'the negated-gate fixture mutated nothing; the case would be vacuous' }
    $negatedGate = Remove-FirstShipAncestry $negatedGateIf
    [IO.File]::WriteAllText($releasePath, $negatedGate.Replace("`r`n", "`n"))
    Assert-ContractFails 'A negated mainline guard skipped ancestry validation' $shipLacksAncestry
    # ...but a negated FUNCTION call is not a negated group: `!cancelled()` beside the
    # mainline comparison is still branch-only and must not be inspected as tag-fired.
    $notCancelledGateIf = $release.Replace("  ship:`n", "  ship:`n    if: `${{ !cancelled() && github.ref == 'refs/heads/main' }}`n")
    if ($notCancelledGateIf -eq $release) { throw 'the !cancelled() fixture mutated nothing; the case would be vacuous' }
    $notCancelledGate = Remove-FirstShipAncestry $notCancelledGateIf
    [IO.File]::WriteAllText($releasePath, $notCancelledGate.Replace("`r`n", "`n"))
    try { & $contractCheck @contractArguments | Out-Null }
    catch { throw "A !cancelled() mainline-only job was incorrectly treated as tag-capable: $_" }
    $tagIgnoreOnly = $release.Replace("      - 'v*'", "    tags-ignore: ['v*']")
    $tagIgnoreOnly = Remove-FirstShipAncestry $tagIgnoreOnly
    [IO.File]::WriteAllText($releasePath, $tagIgnoreOnly.Replace("`r`n", "`n"))
    $tagIgnoreFailed = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $tagIgnoreFailed = $true }
    if (-not $tagIgnoreFailed) { throw 'A tags-ignore-only publish path without ancestry validation passed.' }
    # GitHub does not evaluate paths/paths-ignore for tag pushes, so a push block carrying
    # ONLY a path filter fires on every tag -- yet it read as "filtered" and skipped the
    # ancestry inspection. (code review.)
    $pathsOnly = $release.Replace("    branches:`n      - main`n    tags:`n      - 'v*'`n", "    paths: ['src/**']`n")
    if ($pathsOnly -eq $release) { throw 'the paths-only push fixture mutated nothing; the case would be vacuous' }
    $pathsOnly = Remove-FirstShipAncestry $pathsOnly
    [IO.File]::WriteAllText($releasePath, $pathsOnly.Replace("`r`n", "`n"))
    $pathsOnlyFailed = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $pathsOnlyFailed = $true }
    if (-not $pathsOnlyFailed) { throw 'A paths-only push publish path without ancestry validation passed.' }
    # A branch comparison OR-ed with always() still runs on a tag; the job-level skip
    # inferred "branch-only" from the comparison substring alone. (CodeRabbit, public
    # mirror PR #124.)
    $alwaysJob = $release.Replace("  ship:`n", "  ship:`n    if: github.ref == 'refs/heads/main' || always()`n")
    $alwaysJob = Remove-FirstShipAncestry $alwaysJob
    [IO.File]::WriteAllText($releasePath, $alwaysJob.Replace("`r`n", "`n"))
    $alwaysJobFailed = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $alwaysJobFailed = $true }
    if (-not $alwaysJobFailed) { throw 'A mainline-or-always() job without ancestry validation passed.' }
    [IO.File]::WriteAllText($releasePath, $release.Replace("`r`n", "`n"))
    $approvedContractArguments = $contractArguments.Clone()
    Write-ApprovalVariant (Join-Path $repo '.claude/ci-budget-approval.json') { param($v) $v.head_sha = $repoApprovalAncestor }
    Invoke-ApprovalGit -C $repo add .claude/ci-budget-approval.json
    Invoke-ApprovalGit -C $repo -c commit.gpgsign=false commit --quiet -m approve-budget
    $approvedContractArguments.ExpectedHeadSha = (& git -C $repo rev-parse HEAD).Trim()
    # Measured at the audited head; the approval names the ancestor run it reviewed.
    $approvedContractArguments.ActionsEvidencePath = Write-OverBudgetEvidence $approvedContractArguments.ExpectedHeadSha 'repo-approval-evidence'
    $approvedContractArguments.ApprovalRunEvidencePath = Write-ApprovalRunEvidence 'repo-approval-run' $repoApprovalAncestor
    $approvedContract = & $contractCheck @approvedContractArguments
    if ($approvedContract.Status -ne 'APPROVED_EXCEPTION') {
        throw "Approved exception was not propagated to the scaffold contract: $($approvedContract.Status)"
    }

    $mutations = [ordered]@{
        'CI Gate always semantics' = @{ Old = '    if: always()'; New = '    if: success()' }
        'CI Gate zero permissions' = @{ Old = '    permissions: {}'; New = '    permissions: contents: read' }
        'CI Gate needs coverage' = @{ Old = '    needs: [build, frontend, secrets, gate-coverage]'; New = '    needs: [build, frontend, gate-coverage]' }
        'gate coverage execution' = @{ Old = '      - run: python3 .github/scripts/assert_gate_coverage.py .github/workflows/ci.yml'; New = '      - run: echo skipped' }
        'required-job timeout' = @{ Old = "  secrets:`n    name: Secrets`n    runs-on: ubuntu-latest`n    timeout-minutes: 10"; New = "  secrets:`n    name: Secrets`n    runs-on: ubuntu-latest" }
        'every substantive job timeout' = @{ Old = "  publish:`n    if: startsWith(github.ref, 'refs/tags/v')`n    needs: build`n    runs-on: ubuntu-latest`n    timeout-minutes: 10"; New = "  publish:`n    if: startsWith(github.ref, 'refs/tags/v')`n    needs: build`n    runs-on: ubuntu-latest" }
        'per-test timeout' = @{ Old = ' --blame-hang-timeout 30s'; New = '' }
        'CSharpier job scope' = @{ Old = '          dotnet csharpier check .'; New = "          echo no-format-gate`n          # dotnet csharpier check ." }
        'every .NET backend CSharpier gate' = @{
            Old = '  secrets:'
            New = "  backend-secondary:`n    runs-on: ubuntu-latest`n    timeout-minutes: 1`n    steps:`n      - uses: actions/setup-dotnet@v6`n      - run: dotnet tool restore`n      - run: dotnet restore Secondary.sln`n      - run: dotnet test Secondary.sln --blame-hang-timeout 30s`n  secrets:"
            SecondOld = '    needs: [build, frontend, secrets, gate-coverage]'
            SecondNew = '    needs: [build, backend-secondary, frontend, secrets, gate-coverage]'
        }
        'every .NET test step timeout' = @{ Old = '          dotnet test Example.sln --blame-hang-timeout 30s'; New = "          dotnet test Example.sln --blame-hang-timeout 30s`n      - run: dotnet test Other.sln" }
        'per-test timeout job scope' = @{ Old = ' --blame-hang-timeout 30s'; New = "`n  # misplaced: --blame-hang-timeout 30s" }
        'tag ancestry job scope' = @{ Old = '          if ! git merge-base --is-ancestor "$GITHUB_SHA" FETCH_HEAD; then'; New = "          echo unsafe-publish`n  # misplaced: git merge-base --is-ancestor `"`$GITHUB_SHA`" FETCH_HEAD" }
        'tag ancestry fetch' = @{ Old = '          git fetch --no-tags origin main'; New = '          echo no-fetch' }
        'tag ancestry shell failure' = @{ Old = '          set -euo pipefail'; New = '          echo no-fail-closed-shell' }
        'tag ancestry explicit failure' = @{ Old = '            exit 1'; New = '            echo accepted' }
        'tag ancestry before restore' = @{ Old = '      - name: Assert the tagged commit is reachable from main'; New = "      - run: dotnet restore Publish.sln`n      - name: Assert the tagged commit is reachable from main" }
        'PR range secret scan job scope' = @{ Old = '          "$RUNNER_TEMP/gitleaks" git -v --redact --log-opts="--diff-merges=remerge ${BASE_SHA}..${HEAD_SHA}" .'; New = '          echo no-range-scan' }
        # The push-event range scan is load-bearing in its own right: without it, every
        # non-pull_request run of this job scanned a zero-commit range and exited 0.
        'push range secret scan job scope' = @{ Old = '          "$RUNNER_TEMP/gitleaks" git -v --redact --log-opts="--diff-merges=remerge ${range}" .'; New = '          echo no-push-range-scan' }
        'checked-out-tree secret scan job scope' = @{ Old = '          "$RUNNER_TEMP/gitleaks" dir -v --redact -i .gitleaksignore-tree .'; New = '          echo no-tree-scan' }
        'PR range secret scan arguments' = @{ Old = '--log-opts="--diff-merges=remerge ${BASE_SHA}..${HEAD_SHA}" .'; New = '--log-opts="--diff-merges=remerge ${HEAD_SHA}" .' }
        # --no-merges emits no merge diff, so a secret written in a conflict resolution
        # and removed later reached neither range scan nor the tree scan.
        'range secret scan sees merge resolutions' = @{ Old = '--log-opts="--diff-merges=remerge ${range}" .'; New = '--log-opts="--no-merges ${range}" .' }
        'checked-out-tree secret scan target' = @{ Old = '"$RUNNER_TEMP/gitleaks" dir -v --redact -i .gitleaksignore-tree .'; New = '"$RUNNER_TEMP/gitleaks" dir -v --redact -i .gitleaksignore-tree src' }
    }

    [IO.File]::WriteAllText($workflowPath, $workflow.Replace("`r`n", "`n"))
    [IO.File]::WriteAllText($extendedPath, $extended.Replace('timeout-minutes: 45', 'timeout-minutes: 46').Replace("`r`n", "`n"))
    $extendedFailed = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $extendedFailed = $true }
    if (-not $extendedFailed) { throw 'An extended lane above 45 minutes passed the audit.' }
    [IO.File]::WriteAllText($extendedPath, $extended.Replace("`r`n", "`n"))

    foreach ($case in @(
        @{ Name = 'mixed block-list unconditional publish'; Old = "          # ship ancestry`n          git fetch --no-tags origin main"; New = "          # ship ancestry`n          echo no-fetch" },
        @{ Name = 'ref_type tag predicate'; Old = "            echo `"::error::unreviewed deliver tag`"`n            exit 1"; New = "            echo accepted deliver tag" },
        @{ Name = 'step-conditioned opaque publish'; Old = "          # opaque ancestry`n          git fetch --no-tags origin main"; New = "          # opaque ancestry`n          echo no-fetch" },
        @{ Name = 'ancestry excludes tag path'; Old = '      - name: Assert the tagged commit is reachable from main'; New = "      - name: Assert the tagged commit is reachable from main`n        if: github.ref_type != 'tag'" },
        @{ Name = 'ancestry step continues on error'; Old = "      - name: Assert the tagged commit is reachable from main`n        continue-on-error: false # ancestry failures remain blocking"; New = "      - name: Assert the tagged commit is reachable from main`n        continue-on-error: true" },
        @{ Name = 'ancestry job continues on error'; Old = "  ship:`n    continue-on-error: false # ancestry failures remain blocking`n    name: Ship"; New = "  ship:`n    continue-on-error: true`n    name: Ship" },
        @{ Name = 'ancestry step true with comment'; Old = "      - name: Assert the tagged commit is reachable from main`n        continue-on-error: false # ancestry failures remain blocking"; New = "      - name: Assert the tagged commit is reachable from main`n        continue-on-error: true # bypass" },
        @{ Name = 'ancestry job true with comment'; Old = "  ship:`n    continue-on-error: false # ancestry failures remain blocking`n    name: Ship"; New = "  ship:`n    continue-on-error: true # bypass`n    name: Ship" },
        @{ Name = 'ancestry step expression continue'; Old = "      - name: Assert the tagged commit is reachable from main`n        continue-on-error: false # ancestry failures remain blocking"; New = "      - name: Assert the tagged commit is reachable from main`n        continue-on-error: `${{ matrix.experimental }}" },
        @{ Name = 'ancestry job expression continue'; Old = "  ship:`n    continue-on-error: false # ancestry failures remain blocking`n    name: Ship"; New = "  ship:`n    continue-on-error: `${{ true }}`n    name: Ship" },
        # The gate was keyed to an absolute column, so one extra space in the dash run
        # put continue-on-error at nine spaces and made it invisible. The one control
        # stopping an ancestry assertion being defanged could be defanged by re-indenting.
        @{ Name = 'ancestry step continue at a shifted indent'; Old = "      - name: Assert the tagged commit is reachable from main`n        continue-on-error: false # ancestry failures remain blocking"; New = "      -  name: Assert the tagged commit is reachable from main`n         continue-on-error: true" },
        # Any startsWith prefix used to satisfy the check, so `tags: ['v*','hotfix-*']`
        # with a `refs/tags/v` condition let a hotfix tag skip the assertion entirely
        # while the publish step still ran.
        @{ Name = 'ancestry condition narrower than the tag filter'; Old = "      - if: startsWith(github.ref, 'refs/tags/')"; New = "      - if: startsWith(github.ref, 'refs/tags/v')" },
        # `if: always()` on the publish step means a failing assertion does not stop it,
        # so step ordering proves nothing.
        @{ Name = 'publish runs regardless of the assertion'; Old = "      - run: gh release create `"`$GITHUB_REF_NAME`""; New = "      - if: always()`n        run: gh release create `"`$GITHUB_REF_NAME`"" },
        # A publish command inside the assertion step shares its index, and the ordering
        # comparison used -gt, so equal indexes passed.
        @{ Name = 'publish inside the ancestry step'; Old = "            exit 1`n          fi`n      - run: gh release create `"`$GITHUB_REF_NAME`""; New = "            exit 1`n          fi`n          gh release create `"`$GITHUB_REF_NAME`"" },
        # A mainline `if:` on ONE STEP must not exempt the whole job. `^\s+if:` matched at
        # any indentation, so one unrelated step-level guard made every publish step in
        # that job escape the publish detector, the ordering check, the continue-on-error
        # check and the ancestry assertion. Fail-open, one line away. (CodeRabbit, #135.)
        @{ Name = 'step-level mainline condition exempts the job'
           Old = "      - uses: actions/checkout@v7`n      - if: startsWith(github.ref, 'refs/tags/')`n        run: |`n          set -euo pipefail`n          # deliver ancestry`n          git fetch --no-tags origin main"
           # The condition is on its OWN line under a step, which is the shape `^\s+if:`
           # matched: written inline as `- if:` the character after the whitespace is a
           # dash, so only this form reaches the exemption.
           New = "      - run: echo unrelated`n        if: github.ref == 'refs/heads/main'`n      - uses: actions/checkout@v7`n      - if: startsWith(github.ref, 'refs/tags/')`n        run: |`n          set -euo pipefail`n          # deliver ancestry`n          echo no-fetch" }
    )) {
        [IO.File]::WriteAllText($releasePath, $release.Replace($case.Old, $case.New).Replace("`r`n", "`n"))
        $releaseFailed = $false
        try { & $contractCheck @contractArguments 2>$null | Out-Null }
        catch { $releaseFailed = $true }
        if (-not $releaseFailed) { throw "A tag path failed open: $($case.Name)" }
    }

    # POSITIVE case: the continue-on-error scan is deliberately unanchored - an absolute
    # column let one extra space defang it - which also makes it match inside a `run: |`
    # body. Probed: `# continue-on-error: true` and an unquoted `echo continue-on-error:
    # true` both match the pattern, so a diagnostic line in a shell script could reject a
    # correct tag-fired publish job. Block-scalar bodies are excluded before the scan;
    # this is the case that fails if that exclusion is removed. (Raised by Gitar on #135.)
    $shellComment = $release.Replace(
        "          # deliver ancestry`n",
        "          # deliver ancestry`n          # continue-on-error: true`n          echo continue-on-error: true`n")
    if ($shellComment -eq $release) { throw 'the run-body continue-on-error fixture mutated nothing; the case would be vacuous' }
    [IO.File]::WriteAllText($releasePath, $shellComment.Replace("`r`n", "`n"))
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { throw "a continue-on-error string inside a run: body failed the audit: $_" }

    # ...and the same body under a header carrying a TRAILING YAML COMMENT. `run: | #
    # diagnostic script` is a valid block-scalar header; a header regex anchored on
    # end-of-line does not see it, the body is scanned as mapping lines, and the diagnostic
    # line inside rejects a correct publish job. Same false RED as above, reached by a
    # header spelling rather than a body one. (CodeRabbit, PR #135.)
    $commentedHeader = $shellComment.Replace("        run: |`n", "        run: | # diagnostic script`n")
    if ($commentedHeader -eq $shellComment) { throw 'the commented block-scalar header fixture mutated nothing; the case would be vacuous' }
    [IO.File]::WriteAllText($releasePath, $commentedHeader.Replace("`r`n", "`n"))
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { throw "a block-scalar header with a trailing comment failed the audit: $_" }

    [IO.File]::WriteAllText($releasePath, $release.Replace("`r`n", "`n"))

    $reusableCaller = Join-Path $repo '.github/workflows/reusable-caller.yml'
    $reusableDeploy = Join-Path $repo '.github/workflows/_deploy.yml'
    # A MAIN-GATED caller does not make its callee tag-reachable. The callee was queued
    # as tag-fired before the caller's mainline skip ran, so it failed for lacking an
    # ancestry assertion it can never need.
    @'
name: Reusable caller
on:
  push:
    branches: [main]
    tags: ['v*']
permissions:
  contents: read
jobs:
  deploy:
    if: github.ref == 'refs/heads/main'
    uses: ./.github/workflows/_deploy.yml
'@ | Set-Content -LiteralPath $reusableCaller
    @'
name: Deploy
on:
  workflow_call:
permissions:
  contents: read
jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: docker push example/image
'@ | Set-Content -LiteralPath $reusableDeploy
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { throw "A main-gated caller made its reusable callee tag-reachable: $_" }
    @'
name: Reusable caller
on:
  push:
    tags: ['v*']
jobs:
  deploy:
    uses: ./.github/workflows/_deploy.yml
'@ | Set-Content -LiteralPath $reusableCaller
    @'
name: Deploy
on:
  workflow_call:
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: docker push example/image
'@ | Set-Content -LiteralPath $reusableDeploy
    $reusableFailed = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $reusableFailed = $true }
    if (-not $reusableFailed) { throw 'A ./ tag-fired local reusable deploy without ancestry validation passed the audit.' }
    $callerText = Get-Content -LiteralPath $reusableCaller -Raw
    [IO.File]::WriteAllText($reusableCaller, $callerText.Replace('./.github/workflows/', '$/.github/workflows/'))
    $selfRepoReusableFailed = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $selfRepoReusableFailed = $true }
    Remove-Item -LiteralPath $reusableCaller, $reusableDeploy -Force
    if (-not $selfRepoReusableFailed) { throw 'A $/ tag-fired local reusable deploy without ancestry validation passed the audit.' }

    foreach ($mutation in $mutations.GetEnumerator()) {
        $changed = $workflow.Replace($mutation.Value.Old, $mutation.Value.New)
        if ($mutation.Value.SecondOld) { $changed = $changed.Replace($mutation.Value.SecondOld, $mutation.Value.SecondNew) }
        [IO.File]::WriteAllText($workflowPath, $changed.Replace("`r`n", "`n"))
        $failed = $false
        try { & $contractCheck @contractArguments 2>$null | Out-Null }
        catch { $failed = $true }
        if (-not $failed) { throw "Incomplete fixture passed audit: $($mutation.Key)" }
    }

    # POSITIVE case: inline comments must not turn correct configuration into findings.
    # A YAML plain scalar ends at an unquoted ` #`, and inline comments are this estate's
    # own workflow style - yet `timeout-minutes: 10 # ...` read as NO timeout, and
    # `name: Backend (.NET) # ...` produced a job name that matched no measured evidence,
    # so the audit reported a missing control and a missing required job that are both
    # right there on the line.
    $commented = $workflow.
        Replace('    name: Backend (.NET)', '    name: Backend (.NET) # the legacy lane').
        Replace('    timeout-minutes: 10', '    timeout-minutes: 10 # matches the aggregate budget')
    if ($commented -eq $workflow) { throw 'the inline-comment fixture mutated nothing; the case would be vacuous' }
    [IO.File]::WriteAllText($workflowPath, $commented.Replace("`r`n", "`n"))
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { throw "inline comments on name:/timeout-minutes: failed the audit: $_" }

    [IO.File]::WriteAllText($workflowPath, $workflow.Replace("`r`n", "`n"))
    Add-Content -LiteralPath (Join-Path $repo '.github/scripts/assert_workflow_hygiene.py') -Value '# drift'
    $hygieneFailed = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $hygieneFailed = $true }
    if (-not $hygieneFailed) { throw 'A drifted workflow-hygiene checker passed the audit.' }

    Copy-Item (Join-Path $scaffoldRoot 'assets/assert_workflow_hygiene.py') (Join-Path $repo '.github/scripts/assert_workflow_hygiene.py') -Force
    $policyPath = Join-Path $repo '.claude/review-policy.json'
    $originalPolicy = Get-Content -LiteralPath $policyPath -Raw
    foreach ($requiredPath in '.github/scripts/assert_gate_coverage.py', '.github/workflows/review-tier.yml') {
        $policy = $originalPolicy | ConvertFrom-Json
        $policy.high = @($policy.high | Where-Object { $_ -ne $requiredPath })
        $policy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $policyPath
        $policyFailed = $false
        try { & $contractCheck @contractArguments 2>$null | Out-Null }
        catch { $policyFailed = $true }
        if (-not $policyFailed) { throw "Guard-required path '$requiredPath' missing from HIGH passed the audit." }
    }

    # Primary-workflow selection. SKILL.md defines ONE primary workflow; the checker took
    # whichever HIGH workflow came first in the policy array, so a repo tiering a deploy
    # workflow HIGH beside ci.yml could be audited against the wrong file (Gitar, public
    # mirror PR #124). ci.yml wins when present; otherwise several candidates are ambiguous.
    $policy = $originalPolicy | ConvertFrom-Json
    $policy.high = @('.github/workflows/deploy.yml') + @($policy.high)
    $policy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $policyPath
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { throw "A HIGH deploy workflow listed before ci.yml displaced ci.yml as the primary workflow: $_" }

    $policy = $originalPolicy | ConvertFrom-Json
    $policy.high = @('.github/workflows/build.yml', '.github/workflows/deploy.yml') +
        @($policy.high | Where-Object { $_ -ne '.github/workflows/ci.yml' })
    $policy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $policyPath
    $ambiguous = $null
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $ambiguous = "$_" }
    if ($ambiguous -notmatch 'Ambiguous primary workflow') {
        throw "Two HIGH workflows without ci.yml were not reported as an ambiguous primary workflow: $ambiguous"
    }

    Copy-Item (Join-Path $scaffoldRoot 'assets/review-policy.example.json') (Join-Path $repo '.claude/review-policy.json') -Force
    $guardPath = Join-Path $repo '.github/workflows/review-policy-guard.yml'
    $guard = Get-Content -LiteralPath $guardPath -Raw

    # A primary workflow whose filename ends another filename on the same guard line.
    # Normalising `guard.yml` back to `ci.yml` by raw substring also rewrote
    # `review-policy-guard.yml`, so a correctly adapted guard read as drift.
    $guardNamedPrimary = Join-Path $repo '.github/workflows/guard.yml'
    [IO.File]::WriteAllText($guardNamedPrimary, $workflow.Replace('.github/workflows/ci.yml', '.github/workflows/guard.yml').Replace("`r`n", "`n"))
    $guardPolicy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    $guardPolicy.high = @($guardPolicy.high | ForEach-Object { if ($_ -eq '.github/workflows/ci.yml') { '.github/workflows/guard.yml' } else { $_ } })
    $guardPolicy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $policyPath
    $guardLf = $guard.Replace("`r`n", "`n")
    $adaptedForGuardPrimary = @($guardLf -split "`n" | ForEach-Object {
            if ($_ -match '^\s*\.github/workflows/') { $_.Replace('.github/workflows/ci.yml', '.github/workflows/guard.yml') } else { $_ }
        }) -join "`n"
    if ($adaptedForGuardPrimary -eq $guardLf -or $adaptedForGuardPrimary -notmatch 'workflows/guard\.yml \.github/workflows/review-policy-guard\.yml') {
        throw 'the guard.yml primary fixture does not put both names on one guard line; the case would be vacuous'
    }
    [IO.File]::WriteAllText($guardPath, $adaptedForGuardPrimary)
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { throw "a primary workflow named guard.yml failed the audit (normalisation rewrote review-policy-guard.yml?): $_" }
    # Moved aside, not deleted: a .off file is no workflow.
    Move-Item -LiteralPath $guardNamedPrimary -Destination "$guardNamedPrimary.off"
    Copy-Item (Join-Path $scaffoldRoot 'assets/review-policy.example.json') $policyPath -Force
    [IO.File]::WriteAllText($guardPath, $guardLf)

    # Permitted differences are normalised in the FIELDS that carry them -- the trigger
    # branches and the workflow paths -- not by a global text replace. Replacing every
    # occurrence of the mainline name let an unrelated guard line that swapped `main` for
    # the mainline normalise back to canonical and pass the drift check. (CodeRabbit,
    # public mirror PR #124.)
    function Set-Mainline([string] $branch) {
        [IO.File]::WriteAllText($workflowPath, $workflow.Replace('branches: [main]', "branches: [$branch]").Replace('origin main', "origin $branch").Replace("`r`n", "`n"))
        [IO.File]::WriteAllText($releasePath, $release.Replace('origin main', "origin $branch").Replace("`r`n", "`n"))
        $adapted = $guard.Replace('branches: [main]', "branches: [$branch]")
        if ($adapted -eq $guard) { throw 'the mainline guard fixture mutated nothing; the case would be vacuous' }
        [IO.File]::WriteAllText($guardPath, $adapted.Replace("`r`n", "`n"))
        $adapted
    }
    $trunkGuard = Set-Mainline 'trunk'
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { throw "a trunk-mainline repo with the guard's branch fields adapted failed the audit: $_" }
    $trunkGuardComment = $trunkGuard.Replace('syntax in the main CI workflow', 'syntax in the trunk CI workflow')
    if ($trunkGuardComment -eq $trunkGuard) { throw 'the guard comment fixture mutated nothing; the case would be vacuous' }
    [IO.File]::WriteAllText($guardPath, $trunkGuardComment.Replace("`r`n", "`n"))
    $unrelatedNormalised = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $unrelatedNormalised = $true }
    if (-not $unrelatedNormalised) { throw 'an unrelated guard edit was normalised away by the mainline substitution' }
    # The global replace also fired INSIDE other words: with mainline `develop`, the
    # canonical comment "per developer" became "per mainer" and no adapted guard could
    # ever pass. Field-scoped normalisation leaves the comment alone.
    $null = Set-Mainline 'develop'
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { throw "a develop-mainline repo failed the audit (the substitution reached into 'developer'?): $_" }
    [IO.File]::WriteAllText($workflowPath, $workflow.Replace("`r`n", "`n"))
    [IO.File]::WriteAllText($releasePath, $release.Replace("`r`n", "`n"))

    [IO.File]::WriteAllText($guardPath, $guard.Replace('run: python3 .github/scripts/assert_workflow_hygiene.py', 'run: echo skipped').Replace("`r`n", "`n"))
    $guardFailed = $false
    try { & $contractCheck @contractArguments 2>$null | Out-Null }
    catch { $guardFailed = $true }
    if (-not $guardFailed) { throw 'A guard that skips workflow hygiene passed the audit.' }

    $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
    foreach ($reference in 'inventory.md', 'evaluation.md') {
        $skill += "`n" + (Get-Content -LiteralPath (Join-Path $skillRoot 'references' $reference) -Raw)
    }
    foreach ($required in @('inventory count', 'freshness drift', 'does not change the repository verdict', 'verification timestamp')) {
        if (-not $skill.Contains($required, [StringComparison]::OrdinalIgnoreCase)) {
            throw "audit-ci guidance is missing required contract text: $required"
        }
    }

    # The permitted-difference scope must bind BOTH alternatives to the start of the line.
    # Unanchored, `.github/workflows/` matched inside any comment that mentions a workflow
    # path, so a comment swapping the mainline token would be normalised away (Gitar, #276).
    $contractText = Get-Content -LiteralPath $contractCheck -Raw
    $scope = [regex]::Match($contractText, "(?m)^\s*\`$fieldLine\s*=\s*'([^']+)'").Groups[1].Value
    if (-not $scope) { throw 'could not read $fieldLine from test-scaffold-contract.ps1' }
    foreach ($field in '    branches: [main]', '            .github/workflows/ci.yml .github/workflows/review-policy-guard.yml \') {
        if ($field -notmatch $scope) { throw "the permitted-difference scope no longer matches a real field line: $field" }
    }
    if ('  # the `.github/workflows/**` guard on main' -match $scope) {
        throw 'the permitted-difference scope matches a comment that mentions a workflow path'
    }

    'audit-ci mechanics OK'
}
finally {
    $env:GATE_EXEMPT = $priorGateExempt
    $env:PRIVILEGED_TRIGGER_NO_CHECKOUT = $priorPrivilegedTrigger
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
