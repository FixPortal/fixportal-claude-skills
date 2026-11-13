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
$script:SecretPropertyPattern = '(?i)(password|passwd|pwd|secret|connectionstring|(?<!public[_-]?)key|token|credentials?|pfx(blob|data)?|certificate(blob|data))$'
# The name of a { name, value } or { key, value } pair.
$script:SecretNamePattern = '(?i)secret|passw|pwd|pass$|token|hmac|api[_-]?keys?|webhook|authorization|keys?$'
# Any string that carries a credential assignment. The trailing class excludes '=' so that a
# comparison in a query (Password == 'x') is not taken for an assignment.
$script:SecretValuePattern = '(?i)\b(password|pwd|accountkey|sharedaccesskey|sharedaccesssignature|accesskey|instrumentationkey|apikey|secret|token|sig|code)\s*=\s*[^;&\s=]'
# user:password@ in a URL.
$script:UriCredentialPattern = '(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^@\s/]+@'
# A command-line flag whose next argument is its secret value.
$script:SecretFlagPattern = '(?i)^-{1,2}[\w-]*(password|passwd|pwd|secret|token|key)$'

# Waits, in seconds, before each retry of a throttled call. Its length is the retry count.
$script:ThrottleRetryDelaysSeconds = @(2, 5, 15)

function Invoke-AzGet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Url)

    # az is az.cmd on Windows, and cmd splits an unquoted argument at '&'. Every nextLink has one.
    $urlArgument = $IsWindows ? "`"$Url`"" : $Url
    $errorFile = [IO.Path]::GetTempFileName()
    try {
        # A throttled call is retried on a short fixed schedule. Any other failure is not: it
        # is reported at once, so a permission failure never waits out a retry.
        for ($attempt = 0; ; $attempt++) {
            $output = az rest --method get --url $urlArgument --output json 2> $errorFile
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) { break }

            $stderr = ((Get-Content -LiteralPath $errorFile) -join ' ').Trim()
            if ($stderr.Length -gt 500) { $stderr = $stderr.Substring(0, 500) }
            # The status forms only. A bare number in an error text is not a status code.
            $throttled = $stderr -match '(?i)too many requests|\(429\)|status code:? 429|throttl'
            if (-not $throttled -or $attempt -ge $script:ThrottleRetryDelaysSeconds.Count) {
                throw "AzGet failed ($exitCode): $stderr"
            }
            Start-Sleep -Seconds $script:ThrottleRetryDelaysSeconds[$attempt]
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
    # The one read that is not az rest. --refresh asks Azure for the current subscriptions
    # instead of trusting the local login cache, so one created since the last login is seen.
    $output = az account list --all --refresh --output json 2> $null
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

function Select-ReadFields {
    # Shapes the items of a list read as its table entry asks. `select` keeps only the named
    # fields, each under its last path segment: a workspace's tables come with their whole
    # schema, and only the plan and retention are decisions. `drop` removes named properties
    # at any depth: a budget comes with spend figures and contact addresses, which are not
    # this audit's to hold.
    param($Items, $Read)

    $shaped = @(foreach ($item in $Items) {
            if ($Read.select) {
                $kept = [ordered]@{}
                foreach ($path in $Read.select) {
                    $value = $item
                    foreach ($segment in ($path -split '\.')) { $value = $value.$segment }
                    $kept[($path -split '\.')[-1]] = $value
                }
                $kept
            }
            else { $item }
        })
    if ($Read.drop) { foreach ($item in $shaped) { Remove-NamedProperties -InputObject $item -Names $Read.drop } }
    , $shaped
}

function Remove-NamedProperties {
    # In place, at any depth. Expects the tree ConvertFrom-Json produces.
    param($InputObject, [string[]] $Names)

    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject -is [ValueType]) { return }
    if ($InputObject -is [System.Collections.IList]) {
        foreach ($item in $InputObject) { Remove-NamedProperties -InputObject $item -Names $Names }
        return
    }
    foreach ($name in @($InputObject.PSObject.Properties.Name)) {
        if ($Names -contains $name) { $InputObject.PSObject.Properties.Remove($name) }
        else { Remove-NamedProperties -InputObject $InputObject.$name -Names $Names }
    }
}

function Get-TableReads {
    # Makes each read a table lists, below one base id: a resource's children, or the reads
    # made once for a subscription. Every result is one of the four shapes the runbook names.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BaseId,
        $Reads,
        [Parameter(Mandatory)][hashtable] $ProviderIndex
    )

    $results = [ordered]@{}
    foreach ($read in $Reads) {
        # An entry may pin its api-version. The metadata is the default, but it can mislead:
        # diagnostic settings are listed with no default and one old stable version that does
        # not serve this read (observed: 404 OperationNotFound at 2016-09-01).
        $version = $read.apiVersion ?? (Resolve-ApiVersion -ProviderIndex $ProviderIndex -Type $read.type)
        $results[$read.name] = if (-not $version) {
            New-NotObserved -Kind error -Reason "no api-version found for $($read.type) in the provider metadata"
        }
        else {
            try {
                $response = Invoke-AzGet -Url (ConvertTo-ArmUrl -Path "$BaseId/$($read.path)" -ApiVersion $version)
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
                    [ordered]@{ items = (Select-ReadFields -Items $items -Read $read) }
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
    $results
}

function Get-ChildReads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)][hashtable] $ProviderIndex
    )

    $key = $Resource.type.ToLowerInvariant()
    # The reads for this resource's type, then the reads made on every resource.
    $reads = @($Table.types.$key) + @($Table.allResources) | Where-Object { $null -ne $_ }
    $children = Get-TableReads -BaseId $Resource.id -Reads $reads -ProviderIndex $ProviderIndex

    # Named so the gap is visible in the evidence. Never read: the only route is a POST.
    foreach ($entry in $Table.postOnly.$key) {
        $children[$entry.name] = New-NotObserved -Kind post-only -Reason $entry.why
    }

    $children
}

function Assert-ChildReadsTable {
    # A postOnly name equal to a read's name for the same type would replace that read's
    # result with "not observed", silently. Refuse the table instead.
    param([Parameter(Mandatory)] $Table, [Parameter(Mandatory)][string] $Path)

    if ($Table.schema -ne 1) { throw "child-reads table has schema '$($Table.schema)', expected 1: $Path" }
    foreach ($type in $Table.postOnly.PSObject.Properties) {
        $readNames = @($Table.types.($type.Name).name) + @($Table.allResources.name)
        foreach ($entry in $type.Value) {
            if ($readNames -contains $entry.name) {
                throw "child-reads table: postOnly '$($entry.name)' for $($type.Name) collides with a read of the same name: $Path"
            }
        }
    }
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
            # In a { key, value } pair with no "name" beside it, the property called "key" holds
            # the entry's name. With a name present, key is just another property and is redacted.
            # Either way the string itself is still checked by Test-SecretString below.
            $isPairKey = $property.Name -eq 'key' -and $names -contains 'value' -and $names -notcontains 'name'
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

    # Everything that can stop the write is checked before the first Azure read, so a bad
    # output path costs nothing and never follows a hundred reads.
    $outFolder = Split-Path -Parent $OutFile
    if ($outFolder -and -not (Test-Path -LiteralPath $outFolder -PathType Container)) {
        throw "output folder does not exist: $outFolder"
    }
    foreach ($target in $OutFile, "$OutFile.sha256") {
        if (Test-Path -LiteralPath $target) { throw "refusing to overwrite existing output: $target" }
    }

    $table = Get-Content -LiteralPath $ChildReadsPath -Raw | ConvertFrom-Json
    Assert-ChildReadsTable -Table $table -Path $ChildReadsPath
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

        # Role assignments are always read. The table adds the other once-per-subscription
        # reads (management locks, budgets), which no resource listing returns.
        $subscriptionId = "/subscriptions/$($subscription.id)"
        $roleRead = [pscustomobject]@{ name = 'roleAssignments'; path = 'providers/Microsoft.Authorization/roleAssignments'; type = 'Microsoft.Authorization/roleAssignments' }
        $roleAssignments = (Get-TableReads -BaseId $subscriptionId -Reads @($roleRead) -ProviderIndex $index)['roleAssignments']

        $inventory.subscriptions += [ordered]@{
            id              = $subscription.id
            name            = $subscription.name
            resourceGroups  = @($groups | ForEach-Object { [ordered]@{ name = $_.name; location = $_.location; managedBy = $_.managedBy } })
            resources       = @($resources)
            roleAssignments = $roleAssignments
            reads           = Get-TableReads -BaseId $subscriptionId -Reads $table.subscription -ProviderIndex $index
        }
    }

    # A live type with no table entry was never reviewed for child settings. Report it.
    $inventory.unmappedTypes = @($liveTypes | Sort-Object | Where-Object { -not $table.types.PSObject.Properties[$_] })

    $redacted = Protect-SecretValues -InputObject ($inventory | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
    $json = $redacted | ConvertTo-Json -Depth 100
    # New-Item without -Force fails if a file appeared since the check above: no overwrite, ever.
    $created = New-Item -ItemType File -Path $OutFile -ErrorAction Stop
    try {
        [IO.File]::WriteAllText($created.FullName, $json)
        $hash = (Get-FileHash -LiteralPath $created.FullName -Algorithm SHA256).Hash
        $sidecar = New-Item -ItemType File -Path "$($created.FullName).sha256" -ErrorAction Stop
        [IO.File]::WriteAllText($sidecar.FullName, "$hash  $($created.Name)")
    }
    catch {
        # Neither path existed when this run started (checked above), so whatever is at them
        # now this run created. A half-written evidence file or sha256 file would block the
        # rerun and could pass for evidence. Remove those two files and report the failure.
        foreach ($written in $created.FullName, "$($created.FullName).sha256") {
            Remove-Item -LiteralPath $written -Force -ErrorAction SilentlyContinue
        }
        throw
    }

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
