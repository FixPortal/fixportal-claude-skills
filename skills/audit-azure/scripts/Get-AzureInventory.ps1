#requires -Version 7
<#
.SYNOPSIS
  Read-only inventory of every resource in the tenant of a named Azure subscription.

.DESCRIPTION
  Writes one JSON evidence file: resource groups (empty ones included), every resource with
  its full properties, and role assignments, for each enabled subscription in the tenant.

  Every Azure read goes through Invoke-AzGet, which can only issue an HTTP GET. Some
  read-shaped Azure calls are POSTs that return secrets (storage account keys, App Service
  app settings); with no other route to Azure in this file, none of them is reachable.

  A read that fails is recorded as notObserved with the error text. It is never recorded as
  an empty list: "could not look" and "looked and found nothing" are different findings.

.EXAMPLE
  pwsh -NoProfile -File Get-AzureInventory.ps1 -SubscriptionName "<subscription-name>" -OutFile "<workdir>/inventory.json"
#>
[CmdletBinding()]
param(
    [string] $SubscriptionName,
    [string] $ChildReadsPath = (Join-Path $PSScriptRoot '..' 'references' 'child-reads.json'),
    # Not declared mandatory: a mandatory parameter would prompt when the tests dot-source this file.
    [string] $OutFile
)

$script:ArmBase = 'https://management.azure.com'

# Redaction. A GET does return secret-bearing values (observed: an Application Insights
# component returns its ConnectionString and InstrumentationKey), and a secret typed straight
# into an environment variable or an argument list comes back as written. That is a finding,
# but the value must not reach the evidence file. A reference to a secret (keyVaultUrl,
# secretRef, clientSecretSettingName) is not a secret and is kept: it is evidence of how the
# secret is supplied.
#
# A property whose name ends in one of these, at any depth. Any name ending in "key" or "token"
# counts, not a list of known ones: a list misses privateKey, masterKey and whatever comes
# next, and a redacted non-secret costs far less than a written secret. A public key is the
# one exception, because it is not a secret and can be evidence.
$script:SecretPropertyPattern = '(?i)(password|passwd|pwd|secret|connectionstring|(?<!public)key|token|credentials?|pfx(blob|data)?|certificate(blob|data))$'
# The name of a { name, value } or { key, value } pair.
$script:SecretNamePattern = '(?i)secret|passw|pwd|pass$|token|hmac|api[_-]?keys?|webhook|authorization|keys?$'
# Any string that carries a credential assignment. The trailing class excludes '=' so that a
# comparison in a query (Password == 'x') is not taken for an assignment.
$script:SecretValuePattern = '(?i)\b(password|pwd|accountkey|sharedaccesskey|sharedaccesssignature|accesskey|instrumentationkey|apikey|secret|token|sig|code)\s*=\s*[^;&\s=]'
# user:password@ in a URL.
$script:UriCredentialPattern = '(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^@\s/]+@'
# A command-line flag whose next argument is its secret value.
$script:SecretFlagPattern = '(?i)^-{1,2}[\w-]*(password|passwd|pwd|secret|token|key)$'

function Invoke-AzGet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Url)

    # az is az.cmd on Windows, and cmd splits an unquoted argument at '&'. Every nextLink has one.
    $urlArgument = $IsWindows ? "`"$Url`"" : $Url
    $errorFile = [IO.Path]::GetTempFileName()
    try {
        $output = az rest --method get --url $urlArgument --output json 2> $errorFile
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $stderr = ((Get-Content -LiteralPath $errorFile) -join ' ').Trim()
            if ($stderr.Length -gt 500) { $stderr = $stderr.Substring(0, 500) }
            throw "AzGet failed ($exitCode): $stderr"
        }
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }

    $text = ($output -join "`n").Trim()
    if (-not $text) { return $null }
    $text | ConvertFrom-Json -Depth 100
}

function Get-AzPaged {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Url)

    $items = [System.Collections.Generic.List[object]]::new()
    while ($Url) {
        $page = Invoke-AzGet -Url $Url
        foreach ($item in @($page.value)) {
            if ($null -ne $item) { $items.Add($item) }
        }
        $Url = $page.nextLink
    }
    , $items.ToArray()
}

function Get-AzAccounts {
    # The one read that is not az rest: it lists the local login and makes no Azure resource call.
    $output = az account list --all --output json 2> $null
    if ($LASTEXITCODE -ne 0) { throw "az account list failed ($LASTEXITCODE). Run: az login" }
    # Emits one account per pipeline item, so callers can filter it directly.
    ($output -join "`n") | ConvertFrom-Json
}

function Get-TenantSubscriptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $SubscriptionName)

    # az lists a tenant with no subscription as a pseudo-account; it is not a subscription.
    $enabled = @(Get-AzAccounts | Where-Object {
            $_.state -eq 'Enabled' -and $_.id -and $_.name -ne 'N/A(tenant level account)'
        })
    $named = @($enabled | Where-Object name -EQ $SubscriptionName)
    if (-not $named) { throw "no enabled subscription named '$SubscriptionName'. Run: az login" }

    $tenants = @($named.tenantId | Sort-Object -Unique)
    if ($tenants.Count -gt 1) { throw "'$SubscriptionName' matches subscriptions in more than one tenant: $($tenants -join ', ')" }

    , @($enabled | Where-Object tenantId -EQ $tenants[0] | Sort-Object name |
            ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; tenantId = $_.tenantId } })
}

function Get-ProviderIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $SubscriptionId)

    $index = @{}
    $providers = Get-AzPaged -Url "$script:ArmBase/subscriptions/$SubscriptionId/providers?api-version=2021-04-01"
    foreach ($provider in $providers) {
        foreach ($resourceType in @($provider.resourceTypes)) {
            $versions = @($resourceType.apiVersions | Sort-Object -Descending)
            $stable = $versions | Where-Object { $_ -notmatch 'preview' } | Select-Object -First 1
            $version = $resourceType.defaultApiVersion ?? $stable ?? $versions[0]
            if ($version) { $index["$($provider.namespace)/$($resourceType.resourceType)".ToLowerInvariant()] = $version }
        }
    }
    $index
}

function Resolve-ApiVersion {
    # Provider metadata lists few child types (observed: no entry for SQL firewall rules,
    # Container App auth configuration or App Service site config). A child is served by its
    # parent's API, so walk up the type until a version is found.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $ProviderIndex, [Parameter(Mandatory)][string] $Type)

    $segments = $Type.ToLowerInvariant() -split '/'
    for ($count = $segments.Count; $count -ge 2; $count--) {
        $version = $ProviderIndex[($segments[0..($count - 1)] -join '/')]
        if ($version) { return $version }
    }
}

function New-NotObserved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'post-only')][string] $Kind,
        [Parameter(Mandatory)][string] $Reason
    )
    [ordered]@{ notObserved = $true; kind = $Kind; reason = $Reason }
}

function ConvertTo-ArmUrl {
    # Resource names may contain spaces ("Failure Anomalies - app"); escape each path segment.
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $ApiVersion)
    $escaped = ($Path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    "$script:ArmBase$escaped`?api-version=$ApiVersion"
}

function Get-ChildReads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)][hashtable] $ProviderIndex
    )

    $key = $Resource.type.ToLowerInvariant()
    $children = [ordered]@{}

    foreach ($read in $Table.types.$key) {
        $version = Resolve-ApiVersion -ProviderIndex $ProviderIndex -Type $read.type
        $children[$read.name] = if (-not $version) {
            New-NotObserved -Kind error -Reason "no api-version found for $($read.type) in the provider metadata"
        }
        else {
            try {
                $response = Invoke-AzGet -Url (ConvertTo-ArmUrl -Path "$($Resource.id)/$($read.path)" -ApiVersion $version)
                if ($null -eq $response) {
                    # An empty body is not a setting. Stored as null it would be a fifth shape
                    # that no reader checks for.
                    New-NotObserved -Kind error -Reason 'empty response'
                }
                elseif ($response.PSObject.Properties['value']) {
                    # A list: keep the items, and follow any further pages. Wrapped in { items }
                    # so a reader never tests .notObserved across an array: PowerShell returns
                    # an array of nulls for a missing property on two or more items, and that
                    # is truthy.
                    $items = @($response.value)
                    if ($response.nextLink) { $items += Get-AzPaged -Url $response.nextLink }
                    [ordered]@{ items = $items }
                }
                else { $response }
            }
            catch {
                # Some children answer "does not exist" with an error. Only an error text the
                # table lists is read as an absence; any other failure stays NotObserved, so a
                # wrong path in the table cannot pass for "nothing there".
                $message = $_.Exception.Message
                $isAbsent = $false
                # foreach, not a pipeline: an entry with no absentWhen must iterate zero times.
                foreach ($absentText in $read.absentWhen) {
                    # Every string contains the empty string; an empty entry must match nothing.
                    if ($absentText -and $message.Contains($absentText)) { $isAbsent = $true }
                }
                if ($isAbsent) { [ordered]@{ absent = $true; reason = $message } }
                else { New-NotObserved -Kind error -Reason $message }
            }
        }
    }

    # Named so the gap is visible in the evidence. Never read: the only route is a POST.
    foreach ($entry in $Table.postOnly.$key) {
        $children[$entry.name] = New-NotObserved -Kind post-only -Reason $entry.why
    }

    $children
}

function Protect-SecretValues {
    <#
    .SYNOPSIS
      Replaces secret-bearing values with '[REDACTED]', in place, and returns the object.
    .NOTES
      Expects the tree ConvertFrom-Json produces (PSCustomObject and arrays).
    #>
    [CmdletBinding()]
    param($InputObject, [switch] $InSecretsArray)

    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }

    if ($InputObject -is [System.Collections.IList]) {
        # By index, so a string element can be replaced: container args and commands are arrays.
        for ($index = 0; $index -lt $InputObject.Count; $index++) {
            $item = $InputObject[$index]
            if ($item -is [string]) {
                $previous = if ($index -gt 0) { $InputObject[$index - 1] }
                $followsSecretFlag = $previous -is [string] -and $previous -match $script:SecretFlagPattern -and $item -notmatch '^-'
                if ($item -ne '' -and ($followsSecretFlag -or (Test-SecretString $item))) { $InputObject[$index] = '[REDACTED]' }
            }
            else { $null = Protect-SecretValues -InputObject $item -InSecretsArray:$InSecretsArray }
        }
        return
    }

    # A pair is { name, value } (an environment variable) or { key, value } (a header).
    $names = @($InputObject.PSObject.Properties.Name)
    $pairName = if ($names -contains 'value') {
        if ($names -contains 'name') { $InputObject.name } elseif ($names -contains 'key') { $InputObject.key }
    }
    $isSecretPair = $pairName -is [string] -and $pairName -match $script:SecretNamePattern

    foreach ($property in $InputObject.PSObject.Properties) {
        $value = $property.Value
        if ($value -is [string]) {
            # In a { key, value } pair the property called "key" holds the entry's name.
            $isPairKey = $property.Name -eq 'key' -and $names -contains 'value'
            $isSecret = ($property.Name -match $script:SecretPropertyPattern -and -not $isPairKey) -or
                ($property.Name -eq 'value' -and ($InSecretsArray -or $isSecretPair)) -or
                (Test-SecretString $value)
            # An empty value stays empty: "nothing is set here" is evidence, and not a secret.
            if ($isSecret -and $value -ne '') { $property.Value = '[REDACTED]' }
        }
        else {
            $null = Protect-SecretValues -InputObject $value -InSecretsArray:($property.Name -eq 'secrets')
        }
    }
    $InputObject
}

function Test-SecretString {
    param([string] $Value)
    $Value -match $script:SecretValuePattern -or $Value -match $script:UriCredentialPattern
}

function Get-AzureInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SubscriptionName,
        [string] $ChildReadsPath = (Join-Path $PSScriptRoot '..' 'references' 'child-reads.json'),
        [Parameter(Mandatory)][string] $OutFile
    )
    $ErrorActionPreference = 'Stop'

    if (Test-Path -LiteralPath $OutFile) { throw "refusing to overwrite existing output: $OutFile" }

    $table = Get-Content -LiteralPath $ChildReadsPath -Raw | ConvertFrom-Json
    if ($table.schema -ne 1) { throw "child-reads table has schema '$($table.schema)', expected 1: $ChildReadsPath" }
    $liveTypes = [System.Collections.Generic.HashSet[string]]::new()

    $subscriptions = Get-TenantSubscriptions -SubscriptionName $SubscriptionName
    $inventory = [ordered]@{
        schema        = 1
        observedAt    = [DateTime]::UtcNow.ToString('o')
        tenantId      = $subscriptions[0].tenantId
        subscriptions = @()
        # A subscription that is not Enabled (Warned, PastDue, Disabled) can still hold
        # resources. It is out of scope, and named here so that it is not silently missing.
        skippedSubscriptions = @(Get-AzAccounts | Where-Object {
                $_.tenantId -eq $subscriptions[0].tenantId -and $_.state -ne 'Enabled' -and $_.name -ne 'N/A(tenant level account)'
            } | ForEach-Object { [ordered]@{ name = $_.name; state = $_.state } })
        unmappedTypes = @()
    }

    foreach ($subscription in $subscriptions) {
        $root = "$script:ArmBase/subscriptions/$($subscription.id)"
        # A failure of any of these three listings throws: without them the inventory is not complete.
        $index = Get-ProviderIndex -SubscriptionId $subscription.id
        $groups = Get-AzPaged -Url "$root/resourcegroups?api-version=2021-04-01"
        $listed = Get-AzPaged -Url "$root/resources?api-version=2021-04-01"

        $managedGroups = @{}
        foreach ($group in $groups) {
            if ($group.managedBy) { $managedGroups[$group.name.ToLowerInvariant()] = $true }
        }

        $resources = foreach ($resource in $listed) {
            $groupName = if ($resource.id -match '(?i)/resourceGroups/([^/]+)/') { $Matches[1] } else { $null }
            $version = Resolve-ApiVersion -ProviderIndex $index -Type $resource.type
            $detail = $null
            $properties = if (-not $version) {
                New-NotObserved -Kind error -Reason "no api-version found for $($resource.type) in the provider metadata"
            }
            else {
                try {
                    $detail = Invoke-AzGet -Url (ConvertTo-ArmUrl -Path $resource.id -ApiVersion $version)
                    if ($null -eq $detail) { New-NotObserved -Kind error -Reason 'empty response' } else { $detail.properties }
                }
                catch { New-NotObserved -Kind error -Reason $_.Exception.Message }
            }

            # A platform-managed group (a Container Apps environment's ME_ group) holds resources
            # Azure created; they carry no decisions, so their children are not read.
            $platformManaged = [bool]($groupName -and $managedGroups[$groupName.ToLowerInvariant()])
            if (-not $platformManaged) { $null = $liveTypes.Add($resource.type.ToLowerInvariant()) }

            [ordered]@{
                id              = $resource.id
                type            = $resource.type
                name            = $resource.name
                resourceGroup   = $groupName
                location        = $resource.location
                kind            = $detail.kind ?? $resource.kind
                sku             = $detail.sku ?? $resource.sku
                identity        = $detail.identity ?? $resource.identity
                tags            = $detail.tags ?? $resource.tags
                platformManaged = $platformManaged
                apiVersion      = $version
                properties      = $properties
                children        = $platformManaged ? @{} : (Get-ChildReads -Resource $resource -Table $table -ProviderIndex $index)
            }
        }

        $roleVersion = $index['microsoft.authorization/roleassignments']
        $roleAssignments = if (-not $roleVersion) {
            New-NotObserved -Kind error -Reason 'no api-version found for Microsoft.Authorization/roleAssignments in the provider metadata'
        }
        else {
            try { [ordered]@{ items = Get-AzPaged -Url "$root/providers/Microsoft.Authorization/roleAssignments?api-version=$roleVersion" } }
            catch { New-NotObserved -Kind error -Reason $_.Exception.Message }
        }

        $inventory.subscriptions += [ordered]@{
            id              = $subscription.id
            name            = $subscription.name
            resourceGroups  = @($groups | ForEach-Object { [ordered]@{ name = $_.name; location = $_.location; managedBy = $_.managedBy } })
            resources       = @($resources)
            roleAssignments = $roleAssignments
        }
    }

    # A live type with no table entry was never reviewed for child settings. Report it.
    $inventory.unmappedTypes = @($liveTypes | Sort-Object | Where-Object { -not $table.types.PSObject.Properties[$_] })

    $redacted = Protect-SecretValues -InputObject ($inventory | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
    $json = $redacted | ConvertTo-Json -Depth 100
    # New-Item without -Force fails if the file appeared since the check above: no overwrite, ever.
    $created = New-Item -ItemType File -Path $OutFile -ErrorAction Stop
    [IO.File]::WriteAllText($created.FullName, $json)
    $hash = (Get-FileHash -LiteralPath $created.FullName -Algorithm SHA256).Hash
    [IO.File]::WriteAllText("$($created.FullName).sha256", "$hash  $($created.Name)")

    $redacted
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $SubscriptionName) { throw '-SubscriptionName is required' }
    if (-not $OutFile) { throw '-OutFile is required' }
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $result = Get-AzureInventory -SubscriptionName $SubscriptionName -ChildReadsPath $ChildReadsPath -OutFile $OutFile
    $resourceCount = @($result.subscriptions | ForEach-Object resources).Count
    "inventory written: $OutFile ($(@($result.subscriptions).Count) subscription(s), $resourceCount resource(s))"
}
