$ErrorActionPreference = 'Stop'
$skill = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'SKILL.md') -Raw
$evidence = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'references/github-evidence.md') -Raw
$contract = $skill + "`n" + $evidence
$normalizedSkill = $skill -replace '\s+', ' '
$classifier = Join-Path $PSScriptRoot '..' 'scripts/classify-security-evidence.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'

function Invoke-Classifier([string] $evidence, [string] $configuration = '') {
    $arguments = @{ EvidencePath = (Join-Path $fixtures $evidence) }
    if ($configuration) { $arguments.ConfigurationPath = (Join-Path $fixtures $configuration) }
    @(& $classifier @arguments) -join "`n" | ConvertFrom-Json
}

function Assert-Gaps($result, [string[]] $expected, [string] $because) {
    $actualText = @($result.EvidenceGaps | Sort-Object) -join "`n"
    $expectedText = @($expected | Sort-Object) -join "`n"
    if ($actualText -ne $expectedText) {
        throw "$because`nExpected gaps:`n$expectedText`nActual gaps:`n$actualText"
    }
}

$baselineGaps = @('Code Quality org access is UNVERIFIED')

$public = Invoke-Classifier 'public-responses.json' 'public-configuration-response.json'
if ($public.Status -ne 'INCOMPLETE' -or $public.Findings.Count -ne 0) {
    throw "Sanitized public evidence did not classify cleanly: $($public | ConvertTo-Json -Compress)"
}
Assert-Gaps $public $baselineGaps 'Public baseline evidence gaps changed.'

$private = Invoke-Classifier 'private-responses.json'
if ($private.Status -ne 'INCOMPLETE' -or $private.Findings.Count -ne 0) {
    throw "Omitted non-applicable private fields were misclassified: $($private | ConvertTo-Json -Compress)"
}
Assert-Gaps $private $baselineGaps 'Private baseline evidence gaps changed.'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('audit-github-estate-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $noOrgRepos = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
    $noOrgRepos.code_quality_org_access = 'VERIFIED_NO_REPOSITORIES'
    $noOrgReposPath = Join-Path $temp 'public-no-org-repositories.json'
    $noOrgRepos | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $noOrgReposPath
    $noOrgReposResult = @(& $classifier -EvidencePath $noOrgReposPath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
    if ($noOrgReposResult.EvidenceGaps -notcontains 'Code Quality org access claims no repositories despite this public repository') {
        throw 'Public repository evidence must reject VERIFIED_NO_REPOSITORIES org access.'
    }

    $failedProbe = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
    $failedProbe.repository.exit_code = 1
    $failedProbe.repository.body_json = '{not json'
    $failedPath = Join-Path $temp 'failed-probe.json'
    $failedProbe | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $failedPath
    $failedResult = @(& $classifier -EvidencePath $failedPath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
    if ($failedResult.Status -ne 'INCOMPLETE') { throw 'A failed gh call must fail closed before JSON parsing.' }
    Assert-Gaps $failedResult @($baselineGaps + 'repository gh call failed with exit 1') 'Failed repository probe produced the wrong gaps.'

    foreach ($case in @(
        @{ Name = 'missing exit status'; Mutate = {
                param($item) $item.actions_run.PSObject.Properties.Remove('exit_code')
            }; Expected = @($baselineGaps + 'Actions run response omitted exit_code') },
        @{ Name = 'missing default branch SHA'; Mutate = {
                param($item) $item.PSObject.Properties.Remove('default_branch_sha')
            }; Expected = @($baselineGaps + 'default_branch_sha is missing') },
        @{ Name = 'repository array body'; Mutate = {
                param($item) $item.repository.body_json = '[]'
            }; Expected = @($baselineGaps + 'repository response body must be a JSON object') },
        @{ Name = 'missing repository full name'; Mutate = {
                param($item)
                $body = $item.repository.body_json | ConvertFrom-Json
                $body.PSObject.Properties.Remove('full_name')
                $item.repository.body_json = $body | ConvertTo-Json -Depth 10 -Compress
            }; Expected = @($baselineGaps + 'repository omitted full_name') },
        @{ Name = 'missing repository owner type'; Mutate = {
                param($item)
                $body = $item.repository.body_json | ConvertFrom-Json
                $body.owner.PSObject.Properties.Remove('type')
                $item.repository.body_json = $body | ConvertTo-Json -Depth 10 -Compress
            }; Expected = @($baselineGaps + 'repository omitted owner.type') },
        @{ Name = 'missing Code Quality org access'; Mutate = {
                param($item) $item.PSObject.Properties.Remove('code_quality_org_access')
            }; Expected = @('Code Quality org access evidence is missing') },
        @{ Name = 'missing Actions head SHA'; Mutate = {
                param($item)
                $body = $item.actions_run.body_json | ConvertFrom-Json
                $body.PSObject.Properties.Remove('head_sha')
                $item.actions_run.body_json = $body | ConvertTo-Json -Compress
            }; Expected = @($baselineGaps + 'Actions run omitted head_sha') },
        @{ Name = 'stale Actions head SHA'; Mutate = {
                param($item)
                $body = $item.actions_run.body_json | ConvertFrom-Json
                $body.head_sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                $item.actions_run.body_json = $body | ConvertTo-Json -Compress
            }; Expected = @($baselineGaps + 'Actions run head_sha is stale') },
        @{ Name = 'missing Code Scanning commit SHA'; Mutate = {
                param($item)
                $body = $item.code_scanning_analysis.body_json | ConvertFrom-Json
                $body.PSObject.Properties.Remove('commit_sha')
                $item.code_scanning_analysis.body_json = $body | ConvertTo-Json -Compress
            }; Expected = @($baselineGaps + 'Code Scanning analysis omitted commit_sha') },
        @{ Name = 'missing public attachment'; Mutate = {
                param($item) $item.PSObject.Properties.Remove('code_security_configuration')
            }; Expected = @($baselineGaps + 'code-security configuration attachment response is missing') }
    )) {
        $item = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
        & $case.Mutate $item
        $casePath = Join-Path $temp (($case.Name -replace ' ', '-') + '.json')
        $item | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $casePath
        $result = @(& $classifier -EvidencePath $casePath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
        if ($result.Status -ne 'INCOMPLETE') { throw "$($case.Name) must classify INCOMPLETE." }
        Assert-Gaps $result $case.Expected "$($case.Name) produced the wrong evidence-gap delta."
    }

    # A non-numeric envelope field must be a GAP, not a crash. `[int] 'n/a'` threw a
    # terminating error under $ErrorActionPreference = 'Stop', which killed the whole
    # classification and broke the contract that every repository gets a verdict; and
    # `[int] $null` is 0, so a missing value read as a SUCCESSFUL call.
    foreach ($field in 'exit_code', 'http_status') {
        $nonNumeric = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
        $nonNumeric.actions_run.$field = 'n/a'
        $nonNumericPath = Join-Path $temp "non-numeric-$field.json"
        $nonNumeric | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $nonNumericPath
        $nonNumericResult = @(& $classifier -EvidencePath $nonNumericPath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
        if ($nonNumericResult.Status -ne 'INCOMPLETE') { throw "A non-numeric $field must classify INCOMPLETE, not abort." }
        Assert-Gaps $nonNumericResult @($baselineGaps + "Actions run reported a non-numeric $field 'n/a'") "A non-numeric $field produced the wrong gaps."
    }

    # The PUBLIC half of the paid-control table. These two were read on the private
    # branch and on no other, so a public repository reporting them off classified
    # ACCOUNTED_FOR - a missing control, not a surplus cost.
    foreach ($case in @(
        @{ Field = 'secret_scanning_ai_detection'; Value = 'disabled'; Expected = 'enabled' },
        @{ Field = 'code_security'; Value = 'disabled'; Expected = 'enabled' },
        @{ Field = 'secret_scanning_delegated_bypass'; Value = 'enabled'; Expected = 'disabled' }
    )) {
        $drift = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
        $body = $drift.repository.body_json | ConvertFrom-Json
        $body.security_and_analysis | Add-Member -NotePropertyName $case.Field `
            -NotePropertyValue ([pscustomobject]@{ status = $case.Value }) -Force
        $drift.repository.body_json = $body | ConvertTo-Json -Depth 10 -Compress
        $driftPath = Join-Path $temp "public-drift-$($case.Field).json"
        $drift | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $driftPath
        $driftResult = @(& $classifier -EvidencePath $driftPath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
        $expectedFinding = "repository security_and_analysis.$($case.Field).status is '$($case.Value)', expected '$($case.Expected)'"
        if ($driftResult.Findings -notcontains $expectedFinding) {
            throw "a public repository reporting $($case.Field) as '$($case.Value)' produced no finding: $($driftResult | ConvertTo-Json -Compress)"
        }
        if ($driftResult.Status -ne 'NONCOMPLIANT') { throw "public $($case.Field) drift must classify NONCOMPLIANT." }
    }

    $stale = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
    $analysis = $stale.code_scanning_analysis.body_json | ConvertFrom-Json
    $analysis.commit_sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $stale.code_scanning_analysis.body_json = $analysis | ConvertTo-Json -Compress
    $stalePath = Join-Path $temp 'stale.json'
    $stale | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stalePath
    $staleResult = @(& $classifier -EvidencePath $stalePath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
    if ($staleResult.Status -ne 'INCOMPLETE') { throw 'Stale Code Scanning commit_sha must fail closed.' }
    Assert-Gaps $staleResult @($baselineGaps + 'Code Scanning analysis commit_sha is stale') 'Stale Code Scanning evidence produced the wrong gaps.'

    $fallback = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
    $fallback.secret_scanning_repository_alerts.exit_code = 1
    $fallback.secret_scanning_repository_alerts.http_status = 404
    $fallback.secret_scanning_repository_alerts.body_json = '{not json'
    $fallback | Add-Member -NotePropertyName secret_scanning_organization_alerts -NotePropertyValue ([pscustomobject]@{
        exit_code = 0
        http_status = 200
        body_json = '[]'
    })
    $fallbackPath = Join-Path $temp 'fallback.json'
    $fallback | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fallbackPath
    $fallbackResult = @(& $classifier -EvidencePath $fallbackPath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
    if ($fallbackResult.Status -ne 'INCOMPLETE' -or $fallbackResult.SecretAlerts -ne 0) {
        throw 'A successful empty organization response must prove zero secret alerts.'
    }
    Assert-Gaps $fallbackResult $baselineGaps 'Successful organization fallback must close the repository-probe gap.'

    $malformed = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
    $malformed.secret_scanning_repository_alerts.body_json = '{not json'
    $malformed | Add-Member -NotePropertyName secret_scanning_organization_alerts -NotePropertyValue ([pscustomobject]@{
        exit_code = 0
        http_status = 200
        body_json = '[]'
    })
    $malformedPath = Join-Path $temp 'malformed-repository-secret.json'
    $malformed | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $malformedPath
    $malformedResult = @(& $classifier -EvidencePath $malformedPath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
    if ($malformedResult.SecretAlerts -ne 0) { throw 'Malformed repository secret JSON must fall back to the organization response.' }
    Assert-Gaps $malformedResult $baselineGaps 'Successful fallback must replace malformed repository secret evidence.'

    $missingBody = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
    $missingBody.secret_scanning_repository_alerts.PSObject.Properties.Remove('body_json')
    $missingBody | Add-Member -NotePropertyName secret_scanning_organization_alerts -NotePropertyValue ([pscustomobject]@{
        exit_code = 0
        http_status = 200
        body_json = '[]'
    })
    $missingBodyPath = Join-Path $temp 'missing-repository-secret-body.json'
    $missingBody | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingBodyPath
    $missingBodyResult = @(& $classifier -EvidencePath $missingBodyPath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
    if ($missingBodyResult.SecretAlerts -ne 0) { throw 'Missing repository secret JSON must fall back to the organization response.' }
    Assert-Gaps $missingBodyResult $baselineGaps 'Successful fallback must replace missing repository secret evidence.'

    $attachedPrivate = Get-Content -LiteralPath (Join-Path $fixtures 'private-responses.json') -Raw | ConvertFrom-Json
    $attachedPrivate.code_security_configuration.exit_code = 0
    $attachedPrivate.code_security_configuration.http_status = 200
    $attachedPrivate.code_security_configuration.body_json = '{"state":"attached","configuration":{"id":54321,"name":"Paid private"}}'
    $attachedPrivatePath = Join-Path $temp 'attached-private.json'
    $attachedPrivate | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $attachedPrivatePath
    $attachedPrivateResult = @(& $classifier -EvidencePath $attachedPrivatePath) -join "`n" | ConvertFrom-Json
    if ($attachedPrivateResult.Status -ne 'NONCOMPLIANT' -or $attachedPrivateResult.Findings -notcontains 'Private/internal repository has a code-security configuration attached') {
        throw 'A paid configuration attached to a private repository must be executable policy drift.'
    }
    Assert-Gaps $attachedPrivateResult $baselineGaps 'Private attachment drift produced unrelated evidence gaps.'

    $malformedPrivate = Get-Content -LiteralPath (Join-Path $fixtures 'private-responses.json') -Raw | ConvertFrom-Json
    $malformedPrivate.code_security_configuration.exit_code = 'not-a-number'
    $malformedPrivate.code_security_configuration.http_status = 'also-not-a-number'
    $malformedPrivatePath = Join-Path $temp 'malformed-private-status.json'
    $malformedPrivate | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $malformedPrivatePath
    $malformedPrivateResult = @(& $classifier -EvidencePath $malformedPrivatePath) -join "`n" | ConvertFrom-Json
    if ($malformedPrivateResult.Status -ne 'INCOMPLETE') {
        throw 'Malformed private attachment status must fail closed as incomplete evidence.'
    }
    Assert-Gaps $malformedPrivateResult @($baselineGaps + 'code-security configuration attachment response has non-numeric exit_code/http_status') `
        'Malformed private attachment status produced the wrong evidence gap.'

    $mismatchedAttachment = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
    # Real API shape: `state` at the top level, identity under `configuration`. The old
    # fixtures were authored to the classifier rather than to the API, so the classifier
    # could read the wrong level indefinitely with every test green.
    $mismatchedAttachment.code_security_configuration.body_json = '{"state":"attached","configuration":{"id":99999,"name":"Different public policy"}}'
    $mismatchedAttachmentPath = Join-Path $temp 'mismatched-public-attachment.json'
    $mismatchedAttachment | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mismatchedAttachmentPath
    $mismatchedAttachmentResult = @(& $classifier -EvidencePath $mismatchedAttachmentPath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
    if ($mismatchedAttachmentResult.Status -ne 'NONCOMPLIANT' -or
        $mismatchedAttachmentResult.Findings -notcontains 'Attached code-security configuration does not match the required public configuration') {
        throw 'A public repository attached to a different configuration must be policy drift.'
    }
    Assert-Gaps $mismatchedAttachmentResult $baselineGaps 'Attachment identity drift produced unrelated evidence gaps.'

    $internal = Get-Content -LiteralPath (Join-Path $fixtures 'private-responses.json') -Raw | ConvertFrom-Json
    $repository = $internal.repository.body_json | ConvertFrom-Json
    $repository.visibility = 'internal'
    $internal.repository.body_json = $repository | ConvertTo-Json -Compress
    $internalPath = Join-Path $temp 'internal-responses.json'
    $internal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $internalPath
    $internalResult = @(& $classifier -EvidencePath $internalPath) -join "`n" | ConvertFrom-Json
    if ($internalResult.Status -ne 'INCOMPLETE' -or $internalResult.Findings.Count -ne 0) {
        throw 'An unattached internal repository must follow the private paid-security policy.'
    }
    Assert-Gaps $internalResult $baselineGaps 'Internal unattached evidence produced unrelated evidence gaps.'

    $approved = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
    $approved.code_quality_org_access = 'VERIFIED_APPROVED'
    $approved | Add-Member -NotePropertyName code_quality_paid_approved -NotePropertyValue $true
    $approved.code_quality_setup.body_json = '{"state":"configured","ai_findings_option":"disabled"}'
    $approvedPath = Join-Path $temp 'approved-code-quality.json'
    $approved | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $approvedPath
    $approvedResult = @(& $classifier -EvidencePath $approvedPath -ConfigurationPath (Join-Path $fixtures 'public-configuration-response.json')) -join "`n" | ConvertFrom-Json
    if ($approvedResult.Status -ne 'ACCOUNTED_FOR' -or $approvedResult.Findings.Count -ne 0 -or $approvedResult.EvidenceGaps.Count -ne 0) {
        throw 'Explicitly approved configured Code Quality with AI disabled must be accounted for.'
    }

    $disabled = Get-Content -LiteralPath (Join-Path $fixtures 'public-responses.json') -Raw | ConvertFrom-Json
    $disabled.code_quality_setup.body_json = '{"state":"not-configured"}'
    $disabledPath = Join-Path $temp 'disabled-public-code-quality.json'
    $disabled | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $disabledPath
    $disabledResult = @(& $classifier -EvidencePath $disabledPath) -join "`n" | ConvertFrom-Json
    if ($disabledResult.Status -ne 'NONCOMPLIANT' -or $disabledResult.Findings -notcontains 'Code Quality is disabled on a public repository') {
        throw 'A public repository without Code Quality must be noncompliant.'
    }
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

$controls = [ordered]@{
    code_security                              = @{ Configuration = 'code_security'; Public = 'enabled';  Private = 'disabled' }
    secret_scanning                            = @{ Configuration = 'secret_scanning'; Public = 'enabled';  Private = 'disabled' }
    secret_scanning_push_protection            = @{ Configuration = 'secret_scanning_push_protection'; Public = 'enabled';  Private = 'disabled' }
    secret_scanning_ai_detection               = @{ Configuration = 'secret_scanning_generic_secrets'; Public = 'enabled';  Private = 'disabled' }
    secret_scanning_non_provider_patterns      = @{ Configuration = 'secret_scanning_non_provider_patterns'; Public = 'enabled';  Private = 'disabled' }
    secret_scanning_validity_checks            = @{ Configuration = 'secret_scanning_validity_checks'; Public = 'enabled';  Private = 'disabled' }
    secret_scanning_delegated_alert_dismissal  = @{ Configuration = 'secret_scanning_delegated_alert_dismissal'; Public = 'disabled'; Private = 'disabled' }
    secret_scanning_delegated_bypass            = @{ Configuration = 'secret_scanning_delegated_bypass'; Public = 'disabled'; Private = 'disabled' }
}

foreach ($entry in $controls.GetEnumerator()) {
    $row = '| `{0}` | `{1}` | `{2}` | `{3}` |' -f
        $entry.Key, $entry.Value.Configuration, $entry.Value.Public, $entry.Value.Private
    if ($contract -notmatch [regex]::Escape($row)) {
        throw "The paid-control table is missing its exact mapping/targets row: $row"
    }
}

$configurationOnly = [ordered]@{
    secret_protection                         = @{ Public = 'enabled';  Private = 'not attached' }
    code_scanning_default_setup               = @{ Public = 'enabled';  Private = 'not attached' }
    code_scanning_delegated_alert_dismissal   = @{ Public = 'disabled'; Private = 'not attached' }
    secret_scanning_extended_metadata         = @{ Public = 'enabled';  Private = 'not attached' }
    private_vulnerability_reporting           = @{ Public = 'enabled';  Private = 'not attached' }
}

foreach ($entry in $configurationOnly.GetEnumerator()) {
    $row = '| `{0}` | `{1}` | `{2}` |' -f $entry.Key, $entry.Value.Public, $entry.Value.Private
    if ($contract -notmatch [regex]::Escape($row)) {
        throw "The configuration-only target table is missing: $row"
    }
}
if ($contract -notmatch [regex]::Escape('do not use `advanced_security` as a substitute for the individual `code_security` and `secret_protection` fields')) {
    throw 'The legacy advanced_security aggregate must not replace individual product readback.'
}

# Regression: code_security=disabled is not enough when any Secret Protection child
# remains enabled. Driven through the REAL CLASSIFIER on a mutated fixture, one control at
# a time -- the previous version defined both the drift function and its control table in
# this file, so the loop proved only that the table listed the control while
# classify-security-evidence.ps1 was never invoked with any of the three enabled. It was
# green while the classifier had exactly the hole it claimed to guard.
$driftTemp = Join-Path ([IO.Path]::GetTempPath()) "audit-github-estate-drift-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Path $driftTemp | Out-Null
try {
    foreach ($secretControl in @($controls.Keys | Where-Object { $_ -like 'secret_scanning*' })) {
        $drift = Get-Content -LiteralPath (Join-Path $fixtures 'private-responses.json') -Raw | ConvertFrom-Json
        $repositoryBody = $drift.repository.body_json | ConvertFrom-Json
        $repositoryBody.security_and_analysis | Add-Member -NotePropertyName $secretControl `
            -NotePropertyValue ([pscustomobject]@{ status = 'enabled' }) -Force
        $drift.repository.body_json = $repositoryBody | ConvertTo-Json -Compress -Depth 8
        $driftPath = Join-Path $driftTemp "drift-$secretControl.json"
        $drift | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $driftPath
        $driftResult = @(& $classifier -EvidencePath $driftPath) -join "`n" | ConvertFrom-Json
        $expectedFinding = "repository security_and_analysis.$secretControl.status is 'enabled', expected 'disabled'"
        if ($driftResult.Status -ne 'NONCOMPLIANT' -or $driftResult.Findings -notcontains $expectedFinding) {
            throw "The classifier did not report private drift for '$secretControl'. Findings: $($driftResult.Findings -join '; ')"
        }
    }
}
finally {
    Remove-Item -LiteralPath $driftTemp -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($needle in '.visibility', '.owner.type', '.security_and_analysis', 'GET /repos/{owner}/{repo}') {
    if ($skill -notmatch [regex]::Escape($needle)) {
        throw "Live repository identity/readback guidance is missing: $needle"
    }
}
# The private copy also asserts that one specific stale account name never returns to
# SKILL.md. That literal is machine-specific and is omitted from this public mirror; the
# live-derivation check below carries the same contract in general form.
if ($skill -notmatch '(?is)visibility.*owner\.type.*each (repository|run)') {
    throw 'Visibility and owner type must be derived live for each repository.'
}
if ($skill -notmatch '(?is)after every approved repository `PATCH`.*GET /repos/\{owner\}/\{repo\}.*every\s+applicable paid control') {
    throw 'Repository mutation must be followed by an explicit readback of every paid control.'
}
if ([regex]::Matches($skill, '(?is)after (every|each).*`PATCH`.*?GET /repos/\{owner\}/\{repo\}').Count -ne 1) {
    throw 'One controller rule must own repository PATCH readback.'
}
# The GATE is asserted, and so are the shapes -- but which shape is COMPLIANT moved when
# Code Quality became free on public repositories. It used to be `No repositories` with
# enforcement on, an approved paid exception being the only reason to widen it; now the
# public repositories are expected to be in the set, and `No repositories` is a verified
# reading rather than a compliant one. What did NOT move is that access and enforcement
# are UI-only, so they can still be unverified whatever the product costs -- which is why
# classify-security-evidence.ps1 still raises `Code Quality org access is UNVERIFIED`.
if ($skill -notmatch '(?is)before any Code Quality\s+mutation.*Selected repositories.*Enforce access.*No repositories') {
    throw 'Organization access evidence must gate Code Quality mutations.'
}
if ($skill -match '(?is)before any repository\s+mutation') {
    throw 'Missing Code Quality UI evidence must not gate unrelated repository mutations.'
}
if ($skill -notmatch '(?is)otherwise record.*UNVERIFIED.*continue every other\s+surface') {
    throw 'A Code Quality evidence gap must not stop unrelated security remediation.'
}
$validityBoundary = [regex]::Match(
    $skill,
    '(?ms)^### Unsupported repository mutation\s*\r?\n(?<body>.*?)(?=^###? |\z)'
).Groups['body'].Value
foreach ($needle in 'secret_scanning_validity_checks', 'NONCOMPLIANT', 'UNKNOWN', 'open', 'automation boundary') {
    if ($validityBoundary -notmatch [regex]::Escape($needle)) {
        throw "Unsupported validity-check mutation contract is missing: $needle"
    }
}
if ($validityBoundary -match '(?is)remains enabled.*classify it `UNKNOWN`') {
    throw 'A known enabled validity-check state must not be reclassified as UNKNOWN.'
}
if ($validityBoundary -notmatch '(?is)enabled.*NONCOMPLIANT.*open.*unsupported mutation.*automation boundary') {
    throw 'Known enabled validity-check drift must stay open while mutation alone is unsupported.'
}
if ($validityBoundary -notmatch '(?is)(omitted field|read failure).*UNKNOWN') {
    throw 'UNKNOWN must be reserved for omitted validity-check state or read failure.'
}

'audit-github-estate security controls OK'
