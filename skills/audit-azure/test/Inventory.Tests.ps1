#Requires -Version 7
BeforeAll {
    $script:skill = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # Defined before the script is loaded so `Mock az` works on a host with no Azure CLI.
    function az { }
    . (Join-Path $skill 'scripts' 'Get-AzureInventory.ps1')

    $script:fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures' 'estate.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $script:responses = @{}
    foreach ($key in $fixture.responses.Keys) { $responses[$key.ToLowerInvariant()] = $fixture.responses[$key] }
    $script:alpha = '11111111-1111-1111-1111-111111111111'
    $script:sibling = '22222222-2222-2222-2222-222222222222'
    $script:arm = 'https://management.azure.com'
    # A test table, not the shipped one, so these tests do not move when the real table gains a type.
    $script:table = Join-Path $PSScriptRoot 'fixtures' 'child-reads.json'
    # No waiting in tests: the retry schedule keeps its length and loses its delays.
    $script:ThrottleRetryDelaysSeconds = @(0, 0, 0)

    # Serves a fixture response for a URL the way Invoke-AzGet would: parsed JSON, or the
    # same exception text a failed az call raises.
    function Get-FixtureResponse {
        param([string] $Url)
        $path = ([uri] $Url).AbsolutePath.ToLowerInvariant()
        if (-not $script:responses.ContainsKey($path)) { throw "AzGet failed (1): ERROR: fixture has no response for $path" }
        $response = $script:responses[$path]
        if ($response -is [System.Collections.IDictionary] -and $response.Contains('__fail')) {
            throw "AzGet failed (1): $($response['__fail'])"
        }
        $response | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    }

    function Get-FixtureAccounts { $script:fixture.accounts | ForEach-Object { [pscustomobject] $_ } }

    function New-TestInventory {
        param([string] $SubscriptionName = 'Alpha')
        $out = Join-Path $TestDrive "$([guid]::NewGuid()).json"
        Get-AzureInventory -SubscriptionName $SubscriptionName -ChildReadsPath $script:table -OutFile $out
    }

    function Get-TestResource {
        param($Inventory, [string] $Name)
        $Inventory.subscriptions | ForEach-Object resources | Where-Object name -EQ $Name
    }
}

Describe 'Invoke-AzGet' {
    It 'issues az rest with method get' {
        Mock az { $global:LASTEXITCODE = 0; '{"value":[]}' }
        $null = Invoke-AzGet -Url "$arm/x?api-version=1"
        Should -Invoke az -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'rest' -and ($args -join ' ') -match '--method get' }
    }

    It 'returns the parsed response' {
        Mock az { $global:LASTEXITCODE = 0; '{"value":[{"name":"a"}]}' }
        (Invoke-AzGet -Url "$arm/x?api-version=1").value[0].name | Should -Be 'a'
    }

    It 'throws with the exit code and the stderr text when az fails' {
        Mock az { $global:LASTEXITCODE = 3; Write-Error 'ERROR: boom' -ErrorAction Continue }
        { Invoke-AzGet -Url "$arm/x?api-version=1" } | Should -Throw '*AzGet failed (3)*boom*'
    }

    It 'wraps the URL in quotes on Windows so cmd does not split it at an ampersand' -Skip:(-not $IsWindows) {
        Mock az { $global:LASTEXITCODE = 0; '{}' }
        $null = Invoke-AzGet -Url "$arm/x?api-version=1&b=2"
        Should -Invoke az -Times 1 -Exactly -ParameterFilter { $args -contains "`"$arm/x?api-version=1&b=2`"" }
    }
}

Describe 'Get-AzPaged' {
    BeforeEach { Mock Invoke-AzGet { Get-FixtureResponse -Url $Url } }

    It 'merges every nextLink page' {
        (Get-AzPaged -Url "$arm/subscriptions/$alpha/resources?api-version=2021-04-01").Count | Should -Be 9
    }

    It 'returns an empty array for an empty listing' {
        (Get-AzPaged -Url "$arm/subscriptions/$sibling/resources?api-version=2021-04-01").Count | Should -Be 0
    }
}

Describe 'Get-ProviderIndex' {
    BeforeEach {
        Mock Invoke-AzGet { Get-FixtureResponse -Url $Url }
        $script:index = Get-ProviderIndex -SubscriptionId $alpha
    }

    It 'prefers the default api-version' { $index['microsoft.sql/servers'] | Should -Be '2021-11-01' }
    It 'takes the newest stable version when there is no default' { $index['microsoft.sql/servers/firewallrules'] | Should -Be '2021-11-01' }
    It 'falls back to a preview version when no stable one exists' { $index['microsoft.keyvault/vaults'] | Should -Be '2024-01-01-preview' }
    It 'has no entry for a type the metadata does not list' { $index.ContainsKey('microsoft.example/widgets') | Should -BeFalse }
}

Describe 'Get-TenantSubscriptions' {
    BeforeEach { Mock Get-AzAccounts { Get-FixtureAccounts } }

    It 'returns every enabled subscription in the named subscription''s tenant' {
        (Get-TenantSubscriptions -SubscriptionName 'Alpha').name | Should -Be @('Alpha', 'Alpha Sibling')
    }

    It 'skips disabled subscriptions and the tenant pseudo-account' {
        $names = (Get-TenantSubscriptions -SubscriptionName 'Alpha').name
        $names | Should -Not -Contain 'Alpha Disabled'
        $names | Should -Not -Contain 'N/A(tenant level account)'
    }

    It 'throws when the name matches nothing' {
        { Get-TenantSubscriptions -SubscriptionName 'Missing' } | Should -Throw "*no enabled subscription named 'Missing'*"
    }

    It 'throws when the name matches subscriptions in two tenants' {
        { Get-TenantSubscriptions -SubscriptionName 'Twin' } | Should -Throw '*more than one tenant*'
    }
}

Describe 'Get-AzureInventory' {
    BeforeEach {
        Mock Get-AzAccounts { Get-FixtureAccounts }
        Mock Invoke-AzGet { Get-FixtureResponse -Url $Url }
    }

    It 'covers every subscription in the tenant, including one with no resources' {
        $inventory = New-TestInventory
        $inventory.subscriptions.name | Should -Be @('Alpha', 'Alpha Sibling')
        @($inventory.subscriptions[1].resources).Count | Should -Be 0
    }

    It 'names the subscriptions in the tenant that it skipped, with their state' {
        $skipped = (New-TestInventory).skippedSubscriptions
        $skipped.name | Should -Be 'Alpha Disabled'
        $skipped.state | Should -Be 'Disabled'
    }

    It 'records a resource''s tags' {
        (Get-TestResource (New-TestInventory) 'sql-one').tags.purpose | Should -Be 'demo'
    }

    It 'lists an empty resource group' {
        (New-TestInventory).subscriptions[0].resourceGroups.name | Should -Contain 'rg-empty'
    }

    It 'marks resources in a managedBy group as platformManaged' {
        $inventory = New-TestInventory
        (Get-TestResource $inventory 'lb-managed').platformManaged | Should -BeTrue
        (Get-TestResource $inventory 'sql-one').platformManaged | Should -BeFalse
    }

    It 'records the api-version used for each read' {
        (Get-TestResource (New-TestInventory) 'sql-one').apiVersion | Should -Be '2021-11-01'
    }

    It 'records a failed resource read as NotObserved, not as empty' {
        $broken = Get-TestResource (New-TestInventory) 'site-broken'
        $broken.properties.notObserved | Should -BeTrue
        $broken.properties.kind | Should -Be 'error'
        $broken.properties.reason | Should -BeLike '*AuthorizationFailed*'
    }

    It 'records NotObserved when no api-version resolves, and continues' {
        $inventory = New-TestInventory
        (Get-TestResource $inventory 'widget-one').properties.notObserved | Should -BeTrue
        (Get-TestResource $inventory 'kv-one').properties.enableRbacAuthorization | Should -BeTrue
    }

    It 'reads a resource whose name has a space at an escaped URL' {
        $inventory = New-TestInventory
        (Get-TestResource $inventory 'Smart Detection').properties.enabled | Should -BeTrue
        Should -Invoke Invoke-AzGet -ParameterFilter { $Url -like '*/actiongroups/Smart%20Detection?*' }
    }

    It 'records a failed role-assignment read as NotObserved' {
        $inventory = New-TestInventory
        $inventory.subscriptions[1].roleAssignments.notObserved | Should -BeTrue
        $inventory.subscriptions[0].roleAssignments.items.name | Should -Be 'ra-one'
    }

    It 'throws when the top-level resource listing fails' {
        Mock Invoke-AzGet { throw 'AzGet failed (1): ERROR: throttled' } -ParameterFilter { $Url -like '*/resources?*' }
        { New-TestInventory } | Should -Throw '*throttled*'
    }

    It 'refuses to overwrite an existing output file' {
        $out = Join-Path $TestDrive 'existing.json'
        [IO.File]::WriteAllText($out, 'keep')
        { Get-AzureInventory -SubscriptionName 'Alpha' -OutFile $out } | Should -Throw '*refusing to overwrite*'
        [IO.File]::ReadAllText($out) | Should -Be 'keep'
    }

    It 'writes a sha256 file that matches the output' {
        $out = Join-Path $TestDrive 'hashed.json'
        $null = Get-AzureInventory -SubscriptionName 'Alpha' -OutFile $out
        (Get-Content -LiteralPath "$out.sha256" -Raw) | Should -BeLike "$((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash)*"
    }

    It 'throws when the subscription name matches nothing' {
        { New-TestInventory -SubscriptionName 'Missing' } | Should -Throw "*no enabled subscription named 'Missing'*"
    }
}

Describe 'Child reads' {
    BeforeEach {
        Mock Get-AzAccounts { Get-FixtureAccounts }
        Mock Invoke-AzGet { Get-FixtureResponse -Url $Url }
        $script:inventory = New-TestInventory
    }

    It 'reads each child the table names for the type' {
        (Get-TestResource $inventory 'sql-one').children.firewallRules.items.name | Should -Be @('AllowAllWindowsAzureIps', 'office', 'vpn')
    }

    # Provider metadata lists few child types; observed live, it has no entry for firewall
    # rules, auth configuration or site config. A child is served by its parent's API.
    It 'reads a child whose type the metadata does not list at the parent''s api-version' {
        Should -Invoke Invoke-AzGet -ParameterFilter { $Url -like '*/sites/site-ok/config/web?api-version=2023-12-01' }
    }

    # A list is wrapped in { items } so that .notObserved is never read across an array:
    # in PowerShell a missing property read across two or more items is an array of nulls,
    # which is truthy, and an observed list would then pass for one that was not observed.
    It 'records an empty child list as empty items, not as NotObserved' {
        $child = (Get-TestResource $inventory 'sql-one').children.virtualNetworkRules
        $child.PSObject.Properties.Name | Should -Be @('items')
        @($child.items).Count | Should -Be 0
    }

    It 'stores a child response that is not a list whole' {
        (Get-TestResource $inventory 'site-ok').children.webConfig.properties.alwaysOn | Should -BeTrue
    }

    It 'records a failed child read as NotObserved, not as an empty list' {
        $child = (Get-TestResource $inventory 'site-broken').children.webConfig
        $child.notObserved | Should -BeTrue
        $child.kind | Should -Be 'error'
    }

    # Observed live: a Container App with no platform auth answers its auth-configuration
    # read with 404 AuthConfigNotFound. That is "looked, nothing there", not "could not look".
    It 'records a failure the table declares as an absence as absent, not as NotObserved' {
        $child = (Get-TestResource $inventory 'site-ok').children.authConfig
        $child.absent | Should -BeTrue
        $child.reason | Should -BeLike '*AuthConfigNotFound*'
        $child.PSObject.Properties.Name | Should -Not -Contain 'notObserved'
    }

    It 'keeps any other failure of the same child as NotObserved' {
        (Get-TestResource $inventory 'site-broken').children.authConfig.notObserved | Should -BeTrue
    }

    # The test table gives webConfig an empty absentWhen text. Every string contains the empty
    # string, so without a guard one bad table entry turns any failure into "nothing there".
    It 'does not read an empty absentWhen text as an absence' {
        $child = (Get-TestResource $inventory 'site-broken').children.webConfig
        $child.PSObject.Properties.Name | Should -Not -Contain 'absent'
        $child.notObserved | Should -BeTrue
    }

    It 'records an empty response as NotObserved, not as null' {
        $child = (Get-TestResource $inventory 'sql-one').children.administrators
        $child.notObserved | Should -BeTrue
        $child.reason | Should -BeLike '*empty response*'
    }

    It 'records a postOnly entry as NotObserved with kind post-only, without reading it' {
        (Get-TestResource $inventory 'site-ok').children.appSettings.kind | Should -Be 'post-only'
        Should -Invoke Invoke-AzGet -Times 0 -Exactly -ParameterFilter { $Url -like '*appsettings*' }
    }

    It 'gives a type with an empty list only the all-resources read' {
        (Get-TestResource $inventory 'kv-one').children.PSObject.Properties.Name | Should -Be @('diagnosticSettings')
    }

    It 'reads no children for a platform-managed resource' {
        @((Get-TestResource $inventory 'lb-managed').children.PSObject.Properties).Count | Should -Be 0
    }
}

Describe 'Unmapped types' {
    BeforeEach {
        Mock Get-AzAccounts { Get-FixtureAccounts }
        Mock Invoke-AzGet { Get-FixtureResponse -Url $Url }
    }

    # One assertion covers four cases: a type with no entry is reported; a type with an empty
    # list is not; a table key in another case still matches; a type seen only in a
    # platform-managed group is not reported.
    It 'reports exactly the live types that have no table entry' {
        (New-TestInventory).unmappedTypes | Should -Be @('microsoft.example/widgets')
    }
}

Describe 'Protect-SecretValues' {
    BeforeEach {
        Mock Get-AzAccounts { Get-FixtureAccounts }
        Mock Invoke-AzGet { Get-FixtureResponse -Url $Url }
        $script:out = Join-Path $TestDrive "$([guid]::NewGuid()).json"
        $script:inventory = Get-AzureInventory -SubscriptionName 'Alpha' -ChildReadsPath $table -OutFile $out
    }

    It 'redacts a named property' {
        (Get-TestResource $inventory 'ai-one').properties.ConnectionString | Should -Be '[REDACTED]'
        (Get-TestResource $inventory 'sql-one').properties.administratorLoginPassword | Should -Be '[REDACTED]'
    }

    It 'redacts the value of a secrets entry and keeps its name' {
        $secret = (Get-TestResource $inventory 'ai-one').properties.configuration.secrets[0]
        $secret.value | Should -Be '[REDACTED]'
        $secret.name | Should -Be 'db-connection'
    }

    It 'leaves references to secrets untouched' {
        $configuration = (Get-TestResource $inventory 'ai-one').properties.configuration
        $configuration.secrets[0].keyVaultUrl | Should -Be 'https://example.invalid/secrets/db-connection'
        $configuration.registries[0].passwordSecretRef | Should -Be 'registry-password'
    }

    It 'leaves ordinary values untouched' {
        (Get-TestResource $inventory 'ai-one').properties.RetentionInDays | Should -Be 30
    }

    # A secret typed straight into an environment variable, not referenced from a vault.
    It 'redacts a literal value in a name/value pair when the name looks secret: <name>' -TestCases @(
        @{ name = 'DEMO_ADMIN_TOKEN' }
        @{ name = 'Venue__HmacSecret' }
        @{ name = 'Ci__AdminKey' }
    ) {
        $pair = (Get-TestResource $inventory 'ai-one').properties.template.containers[0].env | Where-Object name -EQ $name
        $pair.value | Should -Be '[REDACTED]'
    }

    It 'redacts a connection string that carries a password' {
        $pair = (Get-TestResource $inventory 'ai-one').properties.template.containers[0].env | Where-Object name -EQ 'Legacy__Db'
        $pair.value | Should -Be '[REDACTED]'
    }

    It 'keeps a name/value pair that is not a secret: <name>' -TestCases @(
        @{ name = 'Db__ConnectionString'; expected = 'Server=example.invalid;Authentication=Active Directory Default' }
        @{ name = 'Tls__KeyVaultUri'; expected = 'https://example.invalid/' }
    ) {
        $pair = (Get-TestResource $inventory 'ai-one').properties.template.containers[0].env | Where-Object name -EQ $name
        $pair.value | Should -Be $expected
    }

    # Shapes a whole-branch review planted and found unredacted: a string inside an array, a
    # property or pair name not on the list, a credential in a URL, and a header pair.
    It 'writes no planted secret to the evidence file: <marker>' -TestCases @(
        @{ marker = 'fixture-env-args-password' }      # a string inside an args array
        @{ marker = 'fixture-env-flag-value' }         # the value after a --api-key flag
        @{ marker = 'fixture-env-ikey' }               # InstrumentationKey= in an env value
        @{ marker = 'fixture-env-db-pass' }            # pair named DB_PASS
        @{ marker = 'fixture-env-api-keys' }           # pair named Auth__ApiKeys__0
        @{ marker = 'fixture-env-webhook' }            # pair named ALERT_WEBHOOK_URL
        @{ marker = 'fixture-env-uri-password' }       # user:password@ in a URL
        @{ marker = 'fixture-env-dapr-connection' }    # property daprAIConnectionString
        @{ marker = 'fixture-env-account-key' }        # property accountKey
        @{ marker = 'fixture-env-api-key-property' }   # property apiKey
        @{ marker = 'fixture-env-shared-key' }         # property sharedKey
        @{ marker = 'fixture-env-service-uri' }        # token= in a webhook URL
        @{ marker = 'fixture-env-bearer' }             # { key: Authorization, value }
        # Raised in review of the public port: a fixed list of key names misses most of them.
        @{ marker = 'fixture-env-private-key' }        # property privateKey
        @{ marker = 'fixture-env-master-key' }         # property masterKey
        @{ marker = 'fixture-env-repository-token' }   # property repositoryToken
        @{ marker = 'fixture-env-admin-credentials' }  # property adminCredentials
        @{ marker = 'fixture-env-pfx-blob' }           # property pfxBlob
        @{ marker = 'fixture-env-named-pair-key' }     # { name, key, value }: key is not the name here
        @{ marker = 'fixture-env-lonely-key' }         # a key property with no value beside it
    ) {
        (Get-Content -LiteralPath $out -Raw).Contains($marker) | Should -BeFalse
    }

    It 'keeps the rest of an array when it redacts one element' {
        $container = (Get-TestResource $inventory 'ai-one').properties.template.containers[0]
        $container.args | Should -Be @('--conn', '[REDACTED]')
        $container.command | Should -Be @('app', '--api-key', '[REDACTED]', '--verbose')
    }

    It 'keeps a value that names a secret without holding one: <property>' -TestCases @(
        @{ property = 'clientSecretSettingName'; expected = 'PROVIDER_AUTHENTICATION_SECRET' }
        @{ property = 'query'; expected = "requests | where Password == 'x'" }
        @{ property = 'sshPublicKey'; expected = 'ssh-ed25519 AAAAfixturePublicKeyMaterial' }   # a public key is not a secret
        @{ property = 'public_key'; expected = 'ssh-ed25519 AAAAfixturePublicUnderscore' }      # nor in snake case
        @{ property = 'public-key'; expected = 'ssh-ed25519 AAAAfixturePublicHyphen' }          # nor in kebab case
    ) {
        (Get-TestResource $inventory 'ai-one').properties.$property | Should -Be $expected
    }

    # In a { key, value } pair the key is the entry's name. Redacting it because the property
    # is called "key" would hide which header or setting the redacted value belongs to.
    It 'keeps the name of a key/value pair while redacting its value' {
        $header = (Get-TestResource $inventory 'ai-one').properties.headers[0]
        $header.key | Should -Be 'Authorization'
        $header.value | Should -Be '[REDACTED]'
    }

    # With a name beside it, "key" is not the entry's name, so the exemption does not apply.
    It 'redacts key in a { name, key, value } object and keeps its ordinary value' {
        $pair = (Get-TestResource $inventory 'ai-one').properties.namedPairs[0]
        $pair.key | Should -Be '[REDACTED]'
        $pair.name | Should -Be 'signing'
        $pair.value | Should -Be 'plain'
    }

    It 'keeps a pair that references a secret and has no value' {
        $pair = (Get-TestResource $inventory 'ai-one').properties.template.containers[0].env | Where-Object name -EQ 'Simbot__ServiceKey'
        $pair.secretRef | Should -Be 'simbot-service-key'
    }

    It 'writes no secret value to the evidence file' {
        $written = Get-Content -LiteralPath $out -Raw
        # Contains, not -Match: a failing -Match prints the whole evidence file into the report.
        $written.Contains('fixture-secret-value') | Should -BeFalse
        $written.Contains('fixture-not-a-real-password') | Should -BeFalse
        $written.Contains('InstrumentationKey=fixture') | Should -BeFalse
        $written.Contains('fixture-env-') | Should -BeFalse
    }
}

Describe 'GET only' {
    It 'never calls az with anything but rest and method get across a full inventory' {
        Mock Get-AzAccounts { Get-FixtureAccounts }
        Mock az {
            $global:LASTEXITCODE = 0
            $url = ([string] $args[[array]::IndexOf($args, '--url') + 1]).Trim('"')
            try { Get-FixtureResponse -Url $url | ConvertTo-Json -Depth 50 }
            catch { $global:LASTEXITCODE = 1 }
        }
        $inventory = New-TestInventory
        @($inventory.subscriptions[0].resources).Count | Should -Be 9
        Should -Invoke az -Times 0 -Exactly -ParameterFilter { $args[0] -ne 'rest' -or ($args -join ' ') -notmatch '--method get' }
    }
}

Describe 'Throttling' {
    BeforeEach { $script:calls = 0 }

    It 'retries a throttled call and returns the eventual response' {
        Mock az {
            $script:calls++
            if ($script:calls -le 2) { $global:LASTEXITCODE = 1; Write-Error 'ERROR: (429) Too Many Requests' -ErrorAction Continue }
            else { $global:LASTEXITCODE = 0; '{"value":[{"name":"a"}]}' }
        }
        (Invoke-AzGet -Url "$arm/x?api-version=1").value[0].name | Should -Be 'a'
        Should -Invoke az -Times 3 -Exactly
    }

    It 'does not retry a failure that is not throttling' {
        Mock az { $global:LASTEXITCODE = 1; Write-Error 'ERROR: (AuthorizationFailed) no' -ErrorAction Continue }
        { Invoke-AzGet -Url "$arm/x?api-version=1" } | Should -Throw '*AuthorizationFailed*'
        Should -Invoke az -Times 1 -Exactly
    }

    # A number in an error is not a status code. Only the status forms count as throttling.
    It 'does not retry an error that merely contains the number 429' {
        Mock az { $global:LASTEXITCODE = 1; Write-Error 'ERROR: (NotFound) rule 429 was not found' -ErrorAction Continue }
        { Invoke-AzGet -Url "$arm/x?api-version=1" } | Should -Throw '*NotFound*'
        Should -Invoke az -Times 1 -Exactly
    }

    It 'gives up after the configured retries and reports the throttle' {
        Mock az { $global:LASTEXITCODE = 1; Write-Error 'ERROR: (429) Too Many Requests' -ErrorAction Continue }
        { Invoke-AzGet -Url "$arm/x?api-version=1" } | Should -Throw '*Too Many Requests*'
        Should -Invoke az -Times (1 + $script:ThrottleRetryDelaysSeconds.Count) -Exactly
    }
}

Describe 'Get-AzAccounts' {
    It 'asks az for a refreshed account list, not the local cache' {
        Mock az { $global:LASTEXITCODE = 0; '[]' }
        $null = Get-AzAccounts
        Should -Invoke az -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'list' -and $args -contains '--refresh' }
    }

    It 'throws and says to log in when az fails' {
        Mock az { $global:LASTEXITCODE = 1 }
        { Get-AzAccounts } | Should -Throw '*az account list failed*az login*'
    }
}

Describe 'Table reads' {
    BeforeEach {
        Mock Get-AzAccounts { Get-FixtureAccounts }
        Mock Invoke-AzGet { Get-FixtureResponse -Url $Url }
        $script:inventory = New-TestInventory
    }

    It 'records NotObserved for a read whose type has no api-version anywhere up its path' {
        $reads = @([pscustomobject]@{ name = 'things'; path = 'things'; type = 'Microsoft.Example/widgets/things' })
        $result = Get-TableReads -BaseId '/subscriptions/x/resourceGroups/r/providers/Microsoft.Example/widgets/w' -Reads $reads -ProviderIndex @{}
        $result.things.notObserved | Should -BeTrue
        $result.things.reason | Should -BeLike '*no api-version*'
    }

    It 'keeps only the selected fields of a list read' {
        $tables = (Get-TestResource $inventory 'law-one').children.tables.items
        $tables[0].PSObject.Properties.Name | Should -Be @('name', 'plan', 'retentionInDays', 'totalRetentionInDays')
        $tables.plan | Should -Be @('Basic', 'Analytics')
        $tables[1].totalRetentionInDays | Should -Be 90
    }

    It 'makes the all-resources read on a resource that is not platform-managed' {
        (Get-TestResource $inventory 'sql-one').children.diagnosticSettings.items.name | Should -Be 'to-law'
    }

    # Observed live: the metadata lists diagnostic settings with no default version and one old
    # stable version, 2016-09-01, which answers this read with 404 OperationNotFound.
    It 'uses the api-version a table entry pins, over the one the metadata would give' {
        Should -Invoke Invoke-AzGet -ParameterFilter { $Url -like '*/sql-one/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview' }
        Should -Invoke Invoke-AzGet -Times 0 -Exactly -ParameterFilter { $Url -like '*diagnosticSettings?api-version=2016-09-01' }
    }

    It 'records a type that does not support the all-resources read as absent' {
        (Get-TestResource $inventory 'ai-one').children.diagnosticSettings.absent | Should -BeTrue
    }

    It 'reads management locks for the subscription, and an empty list is an observed empty list' {
        $locks = $inventory.subscriptions[0].reads.locks
        $locks.PSObject.Properties.Name | Should -Be @('items')
        @($locks.items).Count | Should -Be 0
    }

    It 'reads budgets for the subscription without spend figures or contact addresses' {
        $budget = $inventory.subscriptions[0].reads.budgets.items[0]
        $budget.properties.amount | Should -Be 250
        $budget.properties.PSObject.Properties.Name | Should -Not -Contain 'currentSpend'
        $budget.properties.PSObject.Properties.Name | Should -Not -Contain 'forecastSpend'
        $budget.properties.notifications.actual80.threshold | Should -Be 80
        $budget.properties.notifications.actual80.PSObject.Properties.Name | Should -Not -Contain 'contactEmails'
    }

    It 'records a subscription read that fails as NotObserved' {
        $inventory.subscriptions[1].reads.locks.notObserved | Should -BeTrue
    }
}

Describe 'Output file' {
    BeforeEach {
        Mock Get-AzAccounts { Get-FixtureAccounts }
        Mock Invoke-AzGet { Get-FixtureResponse -Url $Url }
    }

    It 'throws for a missing output folder before making any Azure read' {
        $out = Join-Path $TestDrive 'no-such-folder' 'inventory.json'
        { Get-AzureInventory -SubscriptionName 'Alpha' -ChildReadsPath $table -OutFile $out } | Should -Throw '*output folder does not exist*'
        Should -Invoke Invoke-AzGet -Times 0 -Exactly
    }

    It 'refuses to overwrite an existing sha256 file' {
        $out = Join-Path $TestDrive 'has-sidecar.json'
        [IO.File]::WriteAllText("$out.sha256", 'keep')
        { Get-AzureInventory -SubscriptionName 'Alpha' -ChildReadsPath $table -OutFile $out } | Should -Throw '*refusing to overwrite*'
        [IO.File]::ReadAllText("$out.sha256") | Should -Be 'keep'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    # A failed write must leave nothing behind: a partial file would block the rerun and
    # could pass for evidence.
    It 'leaves neither file when hashing the evidence fails' {
        Mock Get-FileHash { throw 'hash failed' }
        $out = Join-Path $TestDrive 'hash-fails.json'
        { Get-AzureInventory -SubscriptionName 'Alpha' -ChildReadsPath $table -OutFile $out } | Should -Throw '*hash failed*'
        Test-Path -LiteralPath $out | Should -BeFalse
        Test-Path -LiteralPath "$out.sha256" | Should -BeFalse
    }

    It 'leaves neither file when the sha256 file is created and its write then fails' {
        Mock New-Item { [IO.File]::WriteAllText($Path, 'partial'); throw 'disk full' } -ParameterFilter { $Path -like '*.sha256' }
        $out = Join-Path $TestDrive 'sidecar-fails.json'
        { Get-AzureInventory -SubscriptionName 'Alpha' -ChildReadsPath $table -OutFile $out } | Should -Throw '*disk full*'
        Test-Path -LiteralPath $out | Should -BeFalse
        Test-Path -LiteralPath "$out.sha256" | Should -BeFalse
    }

    It 'writes neither spend figures nor contact addresses to the evidence file' {
        $out = Join-Path $TestDrive 'budgets.json'
        $null = Get-AzureInventory -SubscriptionName 'Alpha' -ChildReadsPath $table -OutFile $out
        $written = Get-Content -LiteralPath $out -Raw
        $written.Contains('12345.67') | Should -BeFalse
        $written.Contains('23456.78') | Should -BeFalse
        $written.Contains('owner@example.invalid') | Should -BeFalse
    }
}

Describe 'Child-reads table' {
    BeforeEach {
        Mock Get-AzAccounts { Get-FixtureAccounts }
        Mock Invoke-AzGet { Get-FixtureResponse -Url $Url }
    }

    It 'loads the shipped table and maps every fixture type but the invented one' {
        $out = Join-Path $TestDrive 'shipped.json'
        (Get-AzureInventory -SubscriptionName 'Alpha' -OutFile $out).unmappedTypes | Should -Be @('microsoft.example/widgets')
    }

    It 'refuses a table where a postOnly name would replace a real read' {
        $colliding = Join-Path $TestDrive 'colliding.json'
        '{ "schema": 1, "types": { "microsoft.web/sites": [ { "name": "webConfig", "path": "config/web", "type": "Microsoft.Web/sites/config" } ] }, "postOnly": { "microsoft.web/sites": [ { "name": "webConfig", "why": "x" } ] } }' |
            Set-Content -LiteralPath $colliding
        { Get-AzureInventory -SubscriptionName 'Alpha' -ChildReadsPath $colliding -OutFile (Join-Path $TestDrive 'c.json') } |
            Should -Throw '*postOnly*webConfig*'
    }
}
