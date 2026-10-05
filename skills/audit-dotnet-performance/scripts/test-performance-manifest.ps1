#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Path,

    [ValidateSet('Publication', 'Finding')]
    [string] $Mode = 'Publication',

    [string] $FindingId,

    [string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string] $Message) {
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Require-Text([object] $Value, [string] $Name) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        Fail "$Name is required."
    }
}

function Require-Property([object] $Object, [string] $Name, [string] $Location) {
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        Fail "$Location.$Name is required."
    }
    $value = $Object.$Name
    if ($null -eq $value) { Fail "$Location.$Name is required." }
    if ($value -is [array]) { return ,$value }
    $value
}

function Require-Object([object] $Value, [string] $Name) {
    if ($Value -isnot [pscustomobject]) { Fail "$Name must be an object." }
    $Value
}

function Require-TextArray([object] $Value, [string] $Name, [bool] $AllowEmpty = $false) {
    if ($Value -isnot [array]) { Fail "$Name must be an array of text." }
    if (-not $AllowEmpty -and $Value.Count -eq 0) { Fail "$Name must be a non-empty array of text." }
    if (@($Value | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        Fail "$Name must be an array of text."
    }
    return ,$Value
}

function Require-IsoTimestamp([System.Text.Json.JsonElement] $Audit, [string] $Name) {
    try { $element = $Audit.GetProperty($Name) }
    catch { Fail "audit.$Name is required." }
    if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "audit.$Name must be an ISO-8601 timestamp with UTC or offset." }
    $value = $element.GetString()
    if ($value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        Fail "audit.$Name must be an ISO-8601 timestamp with UTC or offset."
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref] $parsed)) {
        Fail "audit.$Name must be an ISO-8601 timestamp with UTC or offset."
    }
    $parsed
}

function Test-Report {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "Report '$Path' does not exist." }
    $text = Get-Content -LiteralPath $Path -Raw
    $expectedHeadings = @(
        '## 1. Orientation and executive summary',
        '## 2. Repository, scope, and authority boundaries',
        '## 3. Workload contracts',
        '## 4. Environment and reproducibility ledger',
        '## 5. Tool and source ledger',
        '## 6. Baseline results',
        '## 7. Attributed hotspot map',
        '## 8. Costed findings',
        '## 9. Rejected and inconclusive experiments',
        '## 10. Recommended experiment order',
        '## 11. Unassessed dimensions and fidelity gaps',
        '## 12. Repository-state preservation evidence',
        '## 13. Artifact ledger',
        '## 14. Remediation manifest'
    )
    $actualHeadings = @([regex]::Matches($text, '(?m)^## [^\r\n]+') | ForEach-Object Value)
    if ($actualHeadings.Count -ne 14 -or ($actualHeadings -join "`n") -cne ($expectedHeadings -join "`n")) {
        Fail "Report must contain the 14 required headings exactly once and in order."
    }

    $skillRoot = Split-Path $PSScriptRoot -Parent
    $references = [regex]::Matches($text, '`(?<path>(?:audit-dotnet-performance[\\/])?(?:scripts|references)[\\/][^`\s]+\.(?:ps1|md))`')
    foreach ($reference in $references) {
        $relative = $reference.Groups['path'].Value -replace '^audit-dotnet-performance[\\/]', ''
        $resolvedReference = Join-Path $skillRoot ($relative -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $resolvedReference -PathType Leaf)) {
            Fail "Referenced skill path '$relative' does not exist."
        }
    }
}

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Fail "Manifest '$Path' does not exist."
}

try {
    $manifestJson = Get-Content -LiteralPath $Path -Raw
    $manifest = $manifestJson | ConvertFrom-Json -NoEnumerate
    $manifestDocument = [System.Text.Json.JsonDocument]::Parse($manifestJson)
}
catch {
    Fail "Manifest '$Path' is not valid JSON: $($_.Exception.Message)"
}

function Invoke-ManifestValidation {
if ($null -eq $manifest -or $manifest -is [array]) { Fail 'Manifest must be a JSON object.' }
$schemaVersion = Require-Property $manifest 'schemaVersion' 'manifest'
if ($schemaVersion -isnot [long] -or $schemaVersion -notin 1, 2) { Fail 'schemaVersion must be the number 1 or 2.' }

$repository = Require-Property $manifest 'repository' 'manifest'
if ($repository -isnot [pscustomobject]) { Fail 'repository must be an object.' }
Require-Text (Require-Property $repository 'path' 'repository') 'repository.path'
Require-Text (Require-Property $repository 'head' 'repository') 'repository.head'
Require-Text (Require-Property $repository 'branch' 'repository') 'repository.branch'

$audit = Require-Property $manifest 'audit' 'manifest'
if ($audit -isnot [pscustomobject]) { Fail 'audit must be an object.' }
$auditElement = $manifestDocument.RootElement.GetProperty('audit')
if ($auditElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { Fail 'audit must be an object.' }
$startedUtc = Require-IsoTimestamp $auditElement 'startedUtc'
$completedUtc = Require-IsoTimestamp $auditElement 'completedUtc'
if ($completedUtc -lt $startedUtc) { Fail 'audit.completedUtc must be greater than or equal to audit.startedUtc.' }
# `targetStateUnchanged` is a REPOSITORY-mode assertion and cannot exist in artifact mode:
# step 1's captures are repository-mode only, so there is no baseline to compare against
# and SKILL.md tells an artifact-mode run not to assert it. Requiring it unconditionally
# made that instruction unpublishable - the operator either improvised a baseline or
# published a preservation proof that was never constructed. `audit.mode` is what tells
# the two apart, and it is required precisely so absence cannot be read as either one.
# (CodeRabbit, PR #135.)
$auditMode = if ($audit.PSObject.Properties.Name -contains 'mode') { [string]$audit.mode } else { 'repository' }
if (@('repository', 'artifact') -cnotcontains $auditMode) {
    Fail "audit.mode '$auditMode' is invalid; expected 'repository' or 'artifact'."
}
if ($auditMode -eq 'repository') {
    $unchanged = Require-Property $audit 'targetStateUnchanged' 'audit'
    if ($unchanged -isnot [bool]) { Fail 'audit.targetStateUnchanged must be boolean.' }
    if (-not $unchanged) {
        $blocked = [string]$audit.depth -eq 'Blocked'
        $failure = $audit.preservationFailure
        Require-Text $failure 'audit.preservationFailure'
        $findingList = $manifest.findings
        if (-not $blocked -or [string]::IsNullOrWhiteSpace($failure) -or $findingList -isnot [array] -or $findingList.Count -ne 0) {
            Fail 'A failed preservation proof requires depth Blocked, a non-empty preservationFailure, and no findings.'
        }
    }
}
elseif ($audit.PSObject.Properties.Name -contains 'targetStateUnchanged') {
    Fail 'audit.targetStateUnchanged must be absent in artifact mode: there is no captured baseline to compare against, so any value asserts a proof that was never constructed.'
}

if ($schemaVersion -eq 2) {
    $depth = Require-Property $audit 'depth' 'audit'
    Require-Text $depth 'audit.depth'
    if (@('Measured', 'Characterized', 'Surveyed', 'Blocked') -cnotcontains $depth) { Fail "audit.depth '$depth' is invalid." }

    $workloads = Require-Property $manifest 'workloads' 'manifest'
    if ($workloads -isnot [array] -or $workloads.Count -eq 0) { Fail 'workloads must be a non-empty array.' }
    foreach ($workloadOutcome in $workloads) {
        if ($workloadOutcome -isnot [pscustomobject]) { Fail 'Each workload outcome must be an object.' }
        Require-Text (Require-Property $workloadOutcome 'id' 'workload') 'workload.id'
        $status = Require-Property $workloadOutcome 'status' 'workload'
        Require-Text $status 'workload.status'
        if (@('Completed', 'Unstable', 'Unavailable', 'Blocked', 'Not run', 'Not required') -cnotcontains $status) { Fail "workload.status '$status' is invalid." }
        $metrics = Require-TextArray (Require-Property $workloadOutcome 'representativeMetrics' 'workload') 'workload.representativeMetrics' $true
        if ($status -eq 'Completed' -and $metrics.Count -eq 0) { Fail 'workload.representativeMetrics must be non-empty when workload.status is Completed.' }
        $stability = Require-Property $workloadOutcome 'stability' 'workload'
        Require-Text $stability 'workload.stability'
        if (@('Stable', 'Unstable', 'Mixed', 'Not assessed', 'Not required') -cnotcontains $stability) { Fail "workload.stability '$stability' is invalid." }
        $disposition = Require-Property $workloadOutcome 'harnessDisposition' 'workload'
        Require-Text $disposition 'workload.harnessDisposition'
        if (@('Existing', 'Promote', 'Retained external', 'Not needed', 'Rejected') -cnotcontains $disposition) { Fail "workload.harnessDisposition '$disposition' is invalid." }
        if ($disposition -eq 'Promote') {
            $promotion = Require-Object (Require-Property $workloadOutcome 'harnessPromotion' 'workload') 'workload.harnessPromotion'
            Require-Text (Require-Property $promotion 'retainedSource' 'workload.harnessPromotion') 'workload.harnessPromotion.retainedSource'
            Require-TextArray (Require-Property $promotion 'cases' 'workload.harnessPromotion') 'workload.harnessPromotion.cases' | Out-Null
            Require-TextArray (Require-Property $promotion 'fixtureDependencies' 'workload.harnessPromotion') 'workload.harnessPromotion.fixtureDependencies' $true | Out-Null
            Require-TextArray (Require-Property $promotion 'stabilityCaveats' 'workload.harnessPromotion') 'workload.harnessPromotion.stabilityCaveats' $true | Out-Null
            Require-Text (Require-Property $promotion 'proposedDestination' 'workload.harnessPromotion') 'workload.harnessPromotion.proposedDestination'
            Require-Text (Require-Property $promotion 'sourceChangeWorkflow' 'workload.harnessPromotion') 'workload.harnessPromotion.sourceChangeWorkflow'
        }
        else {
            # Every disposition OTHER than Promote states its basis, and until now there
            # was nowhere in the schema to put one: `Promote` was the only answer carrying
            # a mandatory object, which made the three cheap exits - `Not needed`,
            # `Existing`, `Retained external` - the way to avoid filling anything in while
            # still asserting something about the world. report-contract.md says what each
            # must say. (CodeRabbit, PR #135.)
            Require-Text (Require-Property $workloadOutcome 'harnessDispositionBasis' 'workload') 'workload.harnessDispositionBasis'
        }
        # Outside the disposition branch on purpose: nested under the non-Promote arm, a
        # Promote workload skipped both checks, so status Completed with stability
        # Not required - and status Not required with a Promote disposition - validated.
        # (Gitar, PR #281.)
        if ($status -ceq 'Not required') {
            if ($metrics.Count -ne 0 -or $stability -cne 'Not required' -or $disposition -cne 'Not needed' -or
                [string]$workloadOutcome.harnessDispositionBasis -cnotmatch '^No benchmark required: .+') {
                Fail 'A Not required workload must have no metrics, Not required stability, Not needed harness disposition, and a No benchmark required basis.'
            }
            if ($workloadOutcome.PSObject.Properties.Name -contains 'harnessPromotion') {
                Fail 'A Not required workload cannot request harness promotion.'
            }
        }
        elseif ($stability -ceq 'Not required') {
            Fail 'workload.stability may be Not required only when workload.status is Not required.'
        }
    }
}

$findings = Require-Property $manifest 'findings' 'manifest'
if ($findings -isnot [array]) { Fail 'findings must be an array.' }
$classifications = 'Observed bottleneck', 'Benchmarked improvement', 'Production-correlated', 'Static opportunity', 'Unmeasured', 'Rejected experiment'
$confidences = 'High', 'Moderate', 'Low', 'Indeterminate'
$canonicalProductBoundaryExclusions = 'unsafe', 'System.Runtime.Intrinsics', 'DllImport', 'LibraryImport', 'PInvoke', 'native binaries', 'native-dependent packages', 'custom native allocators', 'undocumented runtime switches', 'runtime-private APIs', 'reflection/runtime patching'
$ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($finding in $findings) {
    if ($finding -isnot [pscustomobject]) { Fail 'Each finding must be an object.' }
    $id = Require-Property $finding 'id' 'finding'
    Require-Text $id 'finding.id'
    if ($id -notmatch '^PERF-\d{3}$') { Fail "finding.id '$id' must match PERF-NNN." }
    if (-not $ids.Add($id)) { Fail "finding.id '$id' is duplicate." }
    Require-Text (Require-Property $finding 'title' 'finding') 'finding.title'
    $classification = Require-Property $finding 'classification' 'finding'
    Require-Text $classification 'finding.classification'
    if ($classifications -cnotcontains $classification) { Fail "finding.classification '$classification' is invalid." }
    $confidence = Require-Property $finding 'confidence' 'finding'
    Require-Text $confidence 'finding.confidence'
    if ($confidences -cnotcontains $confidence) { Fail "finding.confidence '$confidence' is invalid." }
    $resolutionState = Require-Property $finding 'resolutionState' 'finding'
    Require-Text $resolutionState 'finding.resolutionState'
    if ($resolutionState -cne 'unresolved') { Fail 'finding.resolutionState must be unresolved.' }
    Require-TextArray (Require-Property $finding 'evidence' 'finding') 'finding.evidence' | Out-Null
    Require-Text (Require-Property $finding 'project' 'finding') 'finding.project'
    Require-TextArray (Require-Property $finding 'files' 'finding') 'finding.files' | Out-Null
    Require-TextArray (Require-Property $finding 'symbols' 'finding') 'finding.symbols' | Out-Null
    $workload = Require-Object (Require-Property $finding 'workload' 'finding') 'finding.workload'
    Require-Text (Require-Property $workload 'id' 'finding.workload') 'finding.workload.id'
    Require-Text (Require-Property $workload 'baseline' 'finding.workload') 'finding.workload.baseline'
    Require-Text (Require-Property $finding 'attributedMechanism' 'finding') 'finding.attributedMechanism'
    Require-Text (Require-Property $finding 'proposedExperiment' 'finding') 'finding.proposedExperiment'
    Require-TextArray (Require-Property $finding 'correctnessInvariants' 'finding') 'finding.correctnessInvariants' | Out-Null
    Require-TextArray (Require-Property $finding 'expectedTradeoffs' 'finding') 'finding.expectedTradeoffs' | Out-Null
    Require-Text (Require-Property $finding 'materialityThreshold' 'finding') 'finding.materialityThreshold'
    $commands = Require-Object (Require-Property $finding 'commands' 'finding') 'finding.commands'
    Require-Text (Require-Property $commands 'baseline' 'finding.commands') 'finding.commands.baseline'
    Require-Text (Require-Property $commands 'candidate' 'finding.commands') 'finding.commands.candidate'
    Require-TextArray (Require-Property $finding 'requiredTools' 'finding') 'finding.requiredTools' $true | Out-Null
    Require-TextArray (Require-Property $finding 'requiredArtifacts' 'finding') 'finding.requiredArtifacts' $true | Out-Null
    $cost = Require-Object (Require-Property $finding 'cost' 'finding') 'finding.cost'
    Require-TextArray (Require-Property $cost 'inputs' 'finding.cost') 'finding.cost.inputs' $true | Out-Null
    Require-TextArray (Require-Property $cost 'missingInputs' 'finding.cost') 'finding.cost.missingInputs' $true | Out-Null
    $productBoundary = Require-Object (Require-Property $finding 'productBoundary' 'finding') 'finding.productBoundary'
    $allowedBoundary = Require-Property $productBoundary 'allowed' 'finding.productBoundary'
    Require-Text $allowedBoundary 'finding.productBoundary.allowed'
    if ($allowedBoundary -cne 'managed-public-api') { Fail 'finding.productBoundary.allowed must be managed-public-api.' }
    $exclusions = Require-TextArray (Require-Property $productBoundary 'exclusions' 'finding.productBoundary') 'finding.productBoundary.exclusions'
    foreach ($exclusion in $canonicalProductBoundaryExclusions) {
        if ($exclusions -cnotcontains $exclusion) { Fail "finding.productBoundary.exclusions must include '$exclusion'." }
    }
    Require-TextArray (Require-Property $finding 'acceptanceConditions' 'finding') 'finding.acceptanceConditions' | Out-Null
    Require-TextArray (Require-Property $finding 'rejectionConditions' 'finding') 'finding.rejectionConditions' | Out-Null
    Require-Text (Require-Property $finding 'rollbackExpectation' 'finding') 'finding.rollbackExpectation'
}

if ($Mode -eq 'Finding') {
    Require-Text $FindingId 'FindingId'
    $finding = @($findings | Where-Object id -ceq $FindingId)
    if ($finding.Count -eq 0) { Fail "FindingId '$FindingId' was not found." }
    [pscustomobject]@{ repository = $repository; finding = $finding[0] } | ConvertTo-Json -Depth 8 -Compress
    exit 0
}

if ($ReportPath) { Test-Report -Path $ReportPath }

[pscustomobject]@{ valid = $true } | ConvertTo-Json -Compress
}

try {
    Invoke-ManifestValidation
}
catch {
    Fail "Manifest '$Path' failed validation: $($_.Exception.Message)"
}
