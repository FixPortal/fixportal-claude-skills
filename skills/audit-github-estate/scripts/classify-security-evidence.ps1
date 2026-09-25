[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EvidencePath,
    [string] $ConfigurationPath
)

$ErrorActionPreference = 'Stop'
$evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
$findings = [Collections.Generic.List[string]]::new()
$gaps = [Collections.Generic.List[string]]::new()

# ONE source for the repository-level paid controls whose private target is `disabled`,
# matching the paid-control table in references/github-evidence.md exactly. The private
# branch previously carried its own shorter list, and the three it omitted were the ones a
# private repo could silently keep enabled.
$PRIVATE_DISABLED_CONTROLS = @(
    'code_security',
    'secret_scanning',
    'secret_scanning_push_protection',
    'secret_scanning_non_provider_patterns',
    'secret_scanning_validity_checks'
)
# Same table, but GitHub returns these only where the plan exposes them, so an absent
# field is not evidence of anything. Validated WHEN PRESENT: an enabled one is drift.
$PRIVATE_DISABLED_CONTROLS_IF_PRESENT = @(
    'secret_scanning_ai_detection',
    'secret_scanning_delegated_alert_dismissal',
    'secret_scanning_delegated_bypass'
)
# The PUBLIC half of the same table, which had drifted the other way: the public branch
# read four fields and the table names eight. `code_security` and
# `secret_scanning_ai_detection` were never checked at all, so a public repository with
# code security switched OFF classified ACCOUNTED_FOR - the exact miss the private list
# was widened to close, in the direction where the control is the protection rather than
# the cost. Split present/if-present on the same rule: GitHub returns the plan-dependent
# ones only where the plan exposes them, so absence is not evidence.
$PUBLIC_ENABLED_CONTROLS = @(
    'secret_scanning',
    'secret_scanning_push_protection',
    'secret_scanning_non_provider_patterns',
    'secret_scanning_validity_checks'
)
# `code_security` is if-present on the PUBLIC side and required-present on the private
# side, which is not an oversight. UNVERIFIED: whether GitHub returns
# security_and_analysis.code_security for a public repository at all; refuted if a live
# `gh api repos/{owner}/{repo} --jq .security_and_analysis` on a public repo shows the
# key. The estate's own public baseline evidence does not carry it. Demanding it would
# make every public repo permanently INCOMPLETE on a field that may never be returned,
# which is the failure mode that gets an audit ignored; treating it as if-present still
# produces a finding the moment a public repo reports it DISABLED, which is the drift
# worth catching.
$PUBLIC_ENABLED_CONTROLS_IF_PRESENT = @('code_security', 'secret_scanning_ai_detection')
$PUBLIC_DISABLED_CONTROLS_IF_PRESENT = @(
    'secret_scanning_delegated_alert_dismissal',
    'secret_scanning_delegated_bypass'
)

function Convert-Envelope($response, [string] $name, [int[]] $statuses = @(200)) {
    if ($null -eq $response) { return [pscustomobject]@{ Success = $false; Error = "$name response is missing"; Body = $null } }
    if ($response.PSObject.Properties.Name -notcontains 'exit_code') {
        return [pscustomobject]@{ Success = $false; Error = "$name response omitted exit_code"; Body = $null }
    }
    if ($response.PSObject.Properties.Name -notcontains 'http_status') {
        return [pscustomobject]@{ Success = $false; Error = "$name response omitted http_status"; Body = $null }
    }
    # TryParse, not a bare [int] cast. The cast sits outside any try, so a collector that
    # wrote `"exit_code": "n/a"` - or any non-numeric placeholder - threw a terminating
    # error under $ErrorActionPreference = 'Stop' and killed the whole classification,
    # breaking the contract that every repository is classified. `[int] $null` is worse
    # still: it is 0, so a MISSING value read as a successful call.
    $exitCode = 0
    $httpStatus = 0
    if (-not [int]::TryParse([string] $response.exit_code, [ref] $exitCode)) {
        return [pscustomobject]@{ Success = $false; Error = "$name reported a non-numeric exit_code '$($response.exit_code)'"; Body = $null }
    }
    if (-not [int]::TryParse([string] $response.http_status, [ref] $httpStatus)) {
        return [pscustomobject]@{ Success = $false; Error = "$name reported a non-numeric http_status '$($response.http_status)'"; Body = $null }
    }
    if ($exitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Error = "$name gh call failed with exit $exitCode"; Body = $null }
    }
    if ($httpStatus -notin $statuses) {
        return [pscustomobject]@{ Success = $false; Error = "$name returned HTTP $httpStatus"; Body = $null }
    }
    if ($response.PSObject.Properties.Name -notcontains 'body_json' -or $null -eq $response.body_json) {
        return [pscustomobject]@{ Success = $false; Error = "$name response omitted body_json"; Body = $null }
    }
    try {
        $body = if ([string]::Equals(([string] $response.body_json).Trim(), '[]', [StringComparison]::Ordinal)) { @() } else { $response.body_json | ConvertFrom-Json }
        [pscustomobject]@{ Success = $true; Error = ''; Body = $body }
    }
    catch { [pscustomobject]@{ Success = $false; Error = "$name returned malformed JSON"; Body = $null } }
}

function Read-Response($response, [string] $name, [int[]] $statuses = @(200)) {
    $result = Convert-Envelope $response $name $statuses
    if (-not $result.Success) { $gaps.Add($result.Error) }
    $result
}

function Require-State($object, [string] $path, [string] $expected, [string] $surface) {
    $value = $object
    foreach ($part in $path.Split('.')) {
        if ($null -eq $value -or $value.PSObject.Properties.Name -notcontains $part) {
            $gaps.Add("$surface omitted applicable field $path")
            return
        }
        $value = $value.$part
    }
    if ([string] $value -ne $expected) {
        $findings.Add("$surface $path is '$value', expected '$expected'")
    }
}

$hasDefaultSha = $evidence.PSObject.Properties.Name -contains 'default_branch_sha' -and
    -not [string]::IsNullOrWhiteSpace([string] $evidence.default_branch_sha)
if (-not $hasDefaultSha) { $gaps.Add('default_branch_sha is missing') }
$defaultSha = if ($hasDefaultSha) { [string] $evidence.default_branch_sha } else { $null }

$repositoryResponse = Read-Response $evidence.repository 'repository'
$repository = $null
if ($repositoryResponse.Success) {
    $repositoryJson = ([string] $evidence.repository.body_json).TrimStart()
    if (-not $repositoryJson.StartsWith('{', [StringComparison]::Ordinal) -or $repositoryResponse.Body -isnot [pscustomobject]) {
        $gaps.Add('repository response body must be a JSON object')
    }
    else { $repository = $repositoryResponse.Body }
}
$hasFullName = $repository -and $repository.PSObject.Properties.Name -contains 'full_name' -and
    -not [string]::IsNullOrWhiteSpace([string] $repository.full_name)
if ($repository -and -not $hasFullName) { $gaps.Add('repository omitted full_name') }
$hasOwnerType = $repository -and $repository.PSObject.Properties.Name -contains 'owner' -and $null -ne $repository.owner -and
    $repository.owner.PSObject.Properties.Name -contains 'type' -and
    -not [string]::IsNullOrWhiteSpace([string] $repository.owner.type)
if ($repository -and -not $hasOwnerType) { $gaps.Add('repository omitted owner.type') }
$fullName = if ($hasFullName) { [string] $repository.full_name } else { '' }
$visibility = if ($repository) { [string] $repository.visibility } else { '' }
$ownerType = if ($hasOwnerType) { [string] $repository.owner.type } else { '' }

if ($repository) {
    if ($visibility -eq 'public') {
        foreach ($field in $PUBLIC_ENABLED_CONTROLS) {
            Require-State $repository "security_and_analysis.$field.status" 'enabled' 'repository'
        }
        $analysisBlock = if ($repository.PSObject.Properties.Name -contains 'security_and_analysis') { $repository.security_and_analysis } else { $null }
        foreach ($entry in @(
            @{ Fields = $PUBLIC_ENABLED_CONTROLS_IF_PRESENT; Expected = 'enabled' },
            @{ Fields = $PUBLIC_DISABLED_CONTROLS_IF_PRESENT; Expected = 'disabled' }
        )) {
            foreach ($field in $entry.Fields) {
                if ($null -ne $analysisBlock -and $analysisBlock.PSObject.Properties.Name -contains $field) {
                    Require-State $repository "security_and_analysis.$field.status" $entry.Expected 'repository'
                }
            }
        }
    }
    elseif ($visibility -in @('private', 'internal')) {
        # EVERY control the skill's paid-control table declares, not the five this list
        # happened to carry. secret_scanning_ai_detection, _delegated_alert_dismissal and
        # _delegated_bypass all have a private target of `disabled` and were never read,
        # so a private repo returning one as `enabled` classified ACCOUNTED_FOR with no
        # finding -- paid-control drift, which is what this audit exists to catch.
        foreach ($field in $PRIVATE_DISABLED_CONTROLS) {
            Require-State $repository "security_and_analysis.$field.status" 'disabled' 'repository'
        }
        foreach ($field in $PRIVATE_DISABLED_CONTROLS_IF_PRESENT) {
            $analysisBlock = if ($repository.PSObject.Properties.Name -contains 'security_and_analysis') { $repository.security_and_analysis } else { $null }
            if ($null -ne $analysisBlock -and $analysisBlock.PSObject.Properties.Name -contains $field) {
                Require-State $repository "security_and_analysis.$field.status" 'disabled' 'repository'
            }
        }
    }
    else { $gaps.Add("repository visibility is unknown: '$visibility'") }
}

if ($visibility -eq 'public') {
    # `status`, not `state`, and identity under `configuration`. The API returns
    # { "status": "attached" | "enforced" | ..., "configuration": { "id", "name", ... } }
    # (live: gh api repos/<org>/<public-repo>/code-security-configuration ->
    # {"status":"enforced",...}). Reading `state` meant every real public repository
    # gapped on an absent field and classified INCOMPLETE permanently, while a genuinely
    # wrong attachment could never be identified. The fixture had been authored to the
    # classifier rather than to the API, so the test could not catch it. Both `attached`
    # and `enforced` are an attachment; any other status is drift.
    $attachment = Read-Response $evidence.code_security_configuration 'code-security configuration attachment'
    if ($attachment.Success) {
        if ($attachment.Body.PSObject.Properties.Name -notcontains 'status') {
            $gaps.Add('code-security configuration attachment omitted applicable field status')
        }
        elseif ([string] $attachment.Body.status -notin @('attached', 'enforced')) {
            $findings.Add("code-security configuration attachment status is '$($attachment.Body.status)', expected 'attached' or 'enforced'")
        }
    }
    $attachedConfiguration = if ($attachment.Success -and
        $attachment.Body.PSObject.Properties.Name -contains 'configuration') { $attachment.Body.configuration } else { $null }

    $defaultSetup = Read-Response $evidence.code_scanning_default_setup 'Code Scanning default setup'
    if ($defaultSetup.Success) { Require-State $defaultSetup.Body 'state' 'configured' 'Code Scanning default setup' }

    $analysis = Read-Response $evidence.code_scanning_analysis 'Code Scanning analysis'
    if ($analysis.Success) {
        if ($analysis.Body.PSObject.Properties.Name -notcontains 'commit_sha' -or [string]::IsNullOrWhiteSpace([string] $analysis.Body.commit_sha)) {
            $gaps.Add('Code Scanning analysis omitted commit_sha')
        }
        elseif ($hasDefaultSha -and [string] $analysis.Body.commit_sha -ne $defaultSha) {
            $gaps.Add('Code Scanning analysis commit_sha is stale')
        }
    }

    if (-not $ConfigurationPath) { $gaps.Add('public security configuration response is missing') }
    else {
        $configurationEnvelope = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
        $configuration = Read-Response $configurationEnvelope 'public security configuration'
        if ($configuration.Success) {
            if ($null -ne $attachedConfiguration) {
                # EVERY comparable field must match, and `id` must be one of them when it
                # is available. Starting $false and setting $true on the first match meant
                # a mismatch never cleared it, so the wrong configuration was accepted
                # whenever it merely shared the required one's display NAME.
                $comparableIdentity = $false
                $matchingIdentity = $true
                $comparedId = $false
                foreach ($field in 'id', 'name') {
                    $attachmentHasField = $attachedConfiguration.PSObject.Properties.Name -contains $field -and
                        -not [string]::IsNullOrWhiteSpace([string] $attachedConfiguration.$field)
                    $configurationHasField = $configuration.Body.PSObject.Properties.Name -contains $field -and
                        -not [string]::IsNullOrWhiteSpace([string] $configuration.Body.$field)
                    if ($attachmentHasField -and $configurationHasField) {
                        $comparableIdentity = $true
                        if ($field -eq 'id') { $comparedId = $true }
                        if ([string] $attachedConfiguration.$field -cne [string] $configuration.Body.$field) { $matchingIdentity = $false }
                    }
                }
                if (-not $comparableIdentity) { $gaps.Add('Public configuration attachment identity cannot be correlated') }
                elseif (-not $matchingIdentity) { $findings.Add('Attached code-security configuration does not match the required public configuration') }
                elseif (-not $comparedId) { $gaps.Add('Public configuration attachment matched on name only; id was not comparable') }
            }
            elseif ($attachment.Success) {
                $gaps.Add('code-security configuration attachment carried no configuration object to correlate')
            }

            $targets = [ordered]@{
                code_scanning_default_setup = 'enabled'
                code_scanning_delegated_alert_dismissal = 'disabled'
                secret_scanning = 'enabled'
                secret_scanning_push_protection = 'enabled'
                secret_scanning_validity_checks = 'enabled'
                secret_scanning_non_provider_patterns = 'enabled'
                secret_scanning_generic_secrets = 'enabled'
                secret_scanning_delegated_alert_dismissal = 'disabled'
                secret_scanning_extended_metadata = 'enabled'
                secret_scanning_delegated_bypass = 'disabled'
                private_vulnerability_reporting = 'enabled'
            }
            foreach ($target in $targets.GetEnumerator()) {
                Require-State $configuration.Body $target.Key $target.Value 'public security configuration'
            }
        }
    }

    $secretAlerts = $null
    $repoAlerts = Convert-Envelope $evidence.secret_scanning_repository_alerts 'repository secret-scanning alerts'
    if ($repoAlerts.Success) { $secretAlerts = @($repoAlerts.Body).Count }
    elseif ($ownerType -eq 'Organization') {
        $orgAlerts = Convert-Envelope $evidence.secret_scanning_organization_alerts 'organization secret-scanning alerts'
        if ($orgAlerts.Success) {
            $secretAlerts = @($orgAlerts.Body | Where-Object { $_.repository.full_name -eq $fullName }).Count
        }
    }
    if ($null -eq $secretAlerts) { $gaps.Add('Secret scanning alert inventory is unavailable after capability probes') }
}
elseif ($visibility -in @('private', 'internal')) {
    $attachment = $evidence.code_security_configuration
    $attachmentExitCode = 0
    $attachmentHttpStatus = 0
    if ($null -eq $attachment) { $gaps.Add('code-security configuration attachment response is missing') }
    elseif ($attachment.PSObject.Properties.Name -notcontains 'exit_code') { $gaps.Add('code-security configuration attachment response omitted exit_code') }
    elseif ($attachment.PSObject.Properties.Name -notcontains 'http_status') { $gaps.Add('code-security configuration attachment response omitted http_status') }
    elseif (-not ([int]::TryParse([string] $attachment.exit_code, [ref] $attachmentExitCode) -and
        [int]::TryParse([string] $attachment.http_status, [ref] $attachmentHttpStatus))) {
        $gaps.Add('code-security configuration attachment response has non-numeric exit_code/http_status')
    }
    elseif ($attachmentExitCode -eq 0 -and $attachmentHttpStatus -eq 204) { }
    elseif ($attachmentExitCode -eq 0 -and $attachmentHttpStatus -eq 200) {
        $findings.Add('Private/internal repository has a code-security configuration attached')
    }
    else { $gaps.Add("code-security configuration attachment probe failed with exit $($attachment.exit_code), HTTP $($attachment.http_status)") }
    $secretAlerts = 0
}
else { $secretAlerts = 0 }

$actions = Read-Response $evidence.actions_run 'Actions run'
if ($actions.Success) {
    if ($actions.Body.PSObject.Properties.Name -notcontains 'head_sha' -or [string]::IsNullOrWhiteSpace([string] $actions.Body.head_sha)) {
        $gaps.Add('Actions run omitted head_sha')
    }
    elseif ($hasDefaultSha -and [string] $actions.Body.head_sha -ne $defaultSha) { $gaps.Add('Actions run head_sha is stale') }
    if ([string] $actions.Body.conclusion -ne 'success') { $gaps.Add("Actions run is $($actions.Body.conclusion)") }
}

$orgAccessPresent = $evidence.PSObject.Properties.Name -contains 'code_quality_org_access' -and
    -not [string]::IsNullOrWhiteSpace([string] $evidence.code_quality_org_access)
if (-not $orgAccessPresent) { $gaps.Add('Code Quality org access evidence is missing') }
elseif ([string] $evidence.code_quality_org_access -eq 'UNVERIFIED') { $gaps.Add('Code Quality org access is UNVERIFIED') }
elseif ([string] $evidence.code_quality_org_access -eq 'VERIFIED_NO_REPOSITORIES' -and $visibility -eq 'public') {
    $gaps.Add('Code Quality org access claims no repositories despite this public repository')
}
elseif ([string] $evidence.code_quality_org_access -notin @('VERIFIED_NO_REPOSITORIES', 'VERIFIED_APPROVED')) {
    $gaps.Add("Code Quality org access evidence is unknown: '$($evidence.code_quality_org_access)'")
}

$codeQuality = Read-Response $evidence.code_quality_setup 'Code Quality setup'
if ($codeQuality.Success) {
    $state = [string] $codeQuality.Body.state
    if ($visibility -eq 'public') {
        if ($state -eq 'configured') { Require-State $codeQuality.Body 'ai_findings_option' 'disabled' 'Code Quality setup' }
        elseif ($state -ne 'not-configured') { $gaps.Add("Code Quality setup has unknown state '$state'") }
        else { $findings.Add('Code Quality is disabled on a public repository') }
    }
    elseif ($visibility -in @('private', 'internal')) {
        if ($state -eq 'configured') {
            $approved = $evidence.PSObject.Properties.Name -contains 'code_quality_paid_approved' -and
                $evidence.code_quality_paid_approved -eq $true -and
                [string] $evidence.code_quality_org_access -eq 'VERIFIED_APPROVED'
            if ($approved) { Require-State $codeQuality.Body 'ai_findings_option' 'disabled' 'Code Quality setup' }
            else { $findings.Add('Code Quality is configured without approved paid use') }
        }
        elseif ($state -ne 'not-configured') { $gaps.Add("Code Quality setup has unknown state '$state'") }
    }
}

$status = if ($findings.Count) { 'NONCOMPLIANT' } elseif ($gaps.Count) { 'INCOMPLETE' } else { 'ACCOUNTED_FOR' }
[pscustomobject]@{
    Status = $status
    Findings = @($findings)
    EvidenceGaps = @($gaps)
    SecretAlerts = $secretAlerts
} | ConvertTo-Json -Depth 5
