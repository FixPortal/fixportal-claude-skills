#requires -Version 7
<#
.SYNOPSIS
  Contract check for audit-azure: the prose, the child-reads table and the inventory script
  must agree with each other and with the skill's read-only rules.

.DESCRIPTION
  Plain and throwing. Creates and deletes nothing. CI runs it with every other verify-*.ps1.
#>
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mainPath = Join-Path $root 'SKILL.md'
$runbookPath = Join-Path $root 'references' 'runbook.md'
$main = Get-Content -LiteralPath $mainPath -Raw
$runbook = Get-Content -LiteralPath $runbookPath -Raw
$script = Get-Content -LiteralPath (Join-Path $root 'scripts' 'Get-AzureInventory.ps1') -Raw
$table = Get-Content -LiteralPath (Join-Path $root 'references' 'child-reads.json') -Raw | ConvertFrom-Json
$text = $main + "`n" + $runbook

# --- Frontmatter and shape ---------------------------------------------------------------
$frontmatter = [regex]::Match($main, '(?s)\A---\r?\n(.*?)\r?\n---').Groups[1].Value
if (-not $frontmatter) { throw 'audit-azure/SKILL.md has no frontmatter' }
# A private-only frontmatter pattern is omitted in this mirror.
foreach ($pattern in '(?m)^name:\s*audit-azure\s*$', '(?m)^description:\s*Use when\b') {
    if ($frontmatter -notmatch $pattern) { throw "audit-azure frontmatter does not match: $pattern" }
}

$words = ([regex]::Matches($main, '\b[\w/-]+\b')).Count
if ($words -ge 500) { throw "audit-azure/SKILL.md is $words words; keep detail in the runbook" }
if ($main -notmatch [regex]::Escape('Supporting files:')) { throw 'audit-azure/SKILL.md must list its supporting files' }
if ((($runbook -split '\r?\n') | Select-Object -First 35) -notcontains '## Contents') {
    throw 'audit-azure runbook must open with a contents list'
}

# --- Vocabulary and rules the report depends on ------------------------------------------
foreach ($needle in 'Holds', 'Premise gone', 'Contradicted', 'Inconsistent', 'Unrecorded', 'Not observed',
    'UNVERIFIED:', 'NotObserved', 'FIRST RUN', 'agent proposed, owner approved', 'deploy-and-ci-traps.md',
    'Get-AzureInventory.ps1', 'az rest --method get', 'Claude\Azure Audit\', 'mirror drift',
    'New-Item -ItemType File', 'Backfilled', 'Default applied', 'post-only') {
    if ($text -notmatch [regex]::Escape($needle)) { throw "audit-azure missing contract: $needle" }
}
if ($runbook -notmatch '(?is)never\s+overwrite') { throw 'audit-azure immutable output contract is missing: never overwrite' }
if ($runbook -match '(?is)New-Item\s+-ItemType\s+File[^\r\n]*-Force') {
    throw 'audit-azure report creation must not force-overwrite an existing report'
}

# --- Read-only: no mutating or secret-returning call anywhere a run can reach --------------
$forbidden = [ordered]@{
    'a non-GET method'              = '(?i)--method\s+(post|put|patch|delete)'
    'a key listing'                 = '(?i)list-?keys'
    'a secret listing'              = '(?i)listSecrets|listCredentials'
    'an app-settings listing'       = '(?i)appsettings/list|authsettingsV2/list|az\s+webapp\s+config'
    'a Key Vault data-plane read'   = '(?i)az\s+keyvault\s+(secret|key|certificate)'
    'a Cost Management call'        = '(?i)Microsoft\.CostManagement'
}
function Find-Forbidden {
    param([string] $Text)
    foreach ($name in $forbidden.Keys) { if ($Text -match $forbidden[$name]) { $name } }
}

$fences = @([regex]::Matches($runbook + "`n" + $main, '(?s)```[a-z0-9]*\r?\n(.*?)```') | ForEach-Object { $_.Groups[1].Value })
# Every check below that reads fences would pass over nothing if the fences were not found.
if ($fences.Count -lt 10) { throw "audit-azure prose has $($fences.Count) fenced commands; expected at least 10, so the fence scan is not seeing them" }
$scanned = [ordered]@{
    'scripts/Get-AzureInventory.ps1'        = $script
    'references/child-reads.json (types)'   = ($table.types | ConvertTo-Json -Depth 10)
    'fenced commands in the prose'          = ($fences -join "`n")
}
foreach ($where in $scanned.Keys) {
    $hits = @(Find-Forbidden $scanned[$where])
    if ($hits) { throw "audit-azure $where contains $($hits -join ', ')" }
}
# A matcher that accepts everything would pass silently forever. One plant per pattern.
foreach ($planted in 'az rest --method post --url x', 'x/listKeys?api-version=1', 'x/listSecrets', 'x/config/appsettings/list',
    'az keyvault secret show --name x', 'providers/Microsoft.CostManagement/query') {
    if (-not (Find-Forbidden $planted)) { throw "forbidden-call matcher did not reject a planted call: $planted" }
}

# The script reaches Azure through az alone. Any other way to make a web request, or to start
# az by another name, would bypass the GET-only wrapper.
$bypass = '(?i)Invoke-RestMethod|Invoke-WebRequest|Start-Process|HttpClient|az\.cmd|\baz\s+@'
# Code only: a comment in the script explains that az is az.cmd on Windows.
$scriptCode = (($script -replace '(?s)<#.*?#>', '') -split '\r?\n' | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
if ($scriptCode -match $bypass) { throw "audit-azure script has a route to the network other than the az wrapper: $($Matches[0])" }
if ('Invoke-RestMethod -Method Post' -notmatch $bypass) { throw 'bypass matcher did not reject a planted Invoke-RestMethod' }

# Every az call in the script is `az rest --method get` or `az account list`. `az login` is
# named only in an error message that tells the user what to run.
function Find-DisallowedAz {
    param([string] $Text)
    $code = ($Text -replace '(?s)<#.*?#>', '') -split '\r?\n' | Where-Object { $_ -notmatch '^\s*#' }
    foreach ($line in $code) {
        foreach ($match in [regex]::Matches($line, '(?<![\w.$-])az\s+([a-z][\w-]*)(?:\s+([a-z][\w-]*))?')) {
            $verb = $match.Groups[1].Value
            $allowed = switch ($verb) {
                'rest' { $line -match 'az\s+rest\s+--method\s+get\b' }
                'account' { $match.Groups[2].Value -eq 'list' }
                'login' { $true }
                default { $false }
            }
            if (-not $allowed) { $match.Value.Trim() }
        }
    }
}
$disallowed = @(Find-DisallowedAz $script)
if ($disallowed) { throw "audit-azure script makes an az call other than 'az rest --method get' or 'az account list': $($disallowed -join '; ')" }

# The same allowlist binds every az command in the prose. Only lines that start with az are
# commands; a line that merely names az inside a search pattern is not one.
$azFenceLines = @($fences | ForEach-Object { $_ -split '\r?\n' } | Where-Object { $_ -match '^\s*az\s' })
if ($azFenceLines.Count -lt 3) { throw "audit-azure prose has $($azFenceLines.Count) az command lines; expected at least 3, so the az scan is not seeing them" }
$disallowedInProse = @(Find-DisallowedAz ($azFenceLines -join "`n"))
if ($disallowedInProse) { throw "audit-azure prose has an az command other than 'az rest --method get' or 'az account list': $($disallowedInProse -join '; ')" }

foreach ($planted in 'az group delete --name x', '$x = az rest --url y', 'az rest -m post --url y', 'az rest --method=post --url y',
    'az storage account keys list --account-name x', 'az account set --subscription x') {
    if (-not (Find-DisallowedAz $planted)) { throw "az-call matcher did not reject a planted call: $planted" }
}

# Commands in the prose stand alone: a variable set in another fence does not exist when a
# command is pasted on its own. A fence may use automatic variables and what it assigns itself.
function Find-ForeignVariable {
    param([string] $Fence)
    $own = @('_', 'HOME', 'null', 'true', 'false') +
        @([regex]::Matches($Fence, '\$([A-Za-z_]\w*)\s*=(?!=)') | ForEach-Object { $_.Groups[1].Value }) +
        @([regex]::Matches($Fence, 'foreach\s*\(\s*\$([A-Za-z_]\w*)\s+in\b') | ForEach-Object { $_.Groups[1].Value })
    [regex]::Matches($Fence, '\$([A-Za-z_]\w*)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $own -notcontains $_ } | Select-Object -Unique
}
foreach ($fence in $fences) {
    $foreign = @(Find-ForeignVariable $fence)
    if ($foreign) { throw "audit-azure fenced command depends on a variable from elsewhere: `$$($foreign -join ', $')" }
}
if (-not (Find-ForeignVariable 'az rest --url "https://x/$subscriptionId"')) { throw 'foreign-variable matcher did not reject a planted outside variable' }

# --- The child-reads table ---------------------------------------------------------------
# An absentWhen text turns a failed read into "looked, nothing there". A text that is empty or
# generic would do that for a permission failure or a wrong path, so each must be specific.
function Find-UnsafeAbsentText {
    param($Texts)
    foreach ($text in $Texts) {
        $generic = $text -match '(?i)^\s*(not\s*found|resource\s*not\s*found|authorization\s*failed|forbidden|bad\s*request|error)\s*$'
        # Quoted, so an empty text still produces output a caller can test for.
        if ($text -isnot [string] -or $text.Trim().Length -lt 12 -or $generic) { "'$text'" }
    }
}
if ($table.schema -ne 1) { throw "child-reads.json schema is '$($table.schema)', expected 1" }
foreach ($block in 'types', 'postOnly') {
    foreach ($property in $table.$block.PSObject.Properties) {
        if ($property.Name -cne $property.Name.ToLowerInvariant()) { throw "child-reads.json $block key is not lower-case: $($property.Name)" }
    }
}
foreach ($property in $table.types.PSObject.Properties) {
    foreach ($read in $property.Value) {
        foreach ($field in 'name', 'path', 'type') {
            if (-not $read.$field) { throw "child-reads.json types['$($property.Name)'] has an entry with no $field" }
        }
        if ($read.path -match '(?i)(^|/)list') { throw "child-reads.json types['$($property.Name)'] reads a list action: $($read.path)" }
        $unsafe = @(Find-UnsafeAbsentText $read.absentWhen)
        if ($unsafe) { throw "child-reads.json types['$($property.Name)'].$($read.name) has an absentWhen text that is too broad: $($unsafe -join ', ')" }
    }
}
foreach ($planted in '', 'NotFound', 'Not Found', 'AuthorizationFailed', 'short') {
    if (-not (Find-UnsafeAbsentText @($planted))) { throw "absentWhen check did not reject a planted text: '$planted'" }
}
if (Find-UnsafeAbsentText @('AuthConfigNotFound', 'Azure AD authentication is not enabled')) { throw 'absentWhen check rejected the two texts observed live' }
foreach ($property in $table.postOnly.PSObject.Properties) {
    foreach ($entry in $property.Value) {
        if (-not $entry.name -or -not $entry.why) { throw "child-reads.json postOnly['$($property.Name)'] needs a name and a why" }
    }
}

# --- Links -------------------------------------------------------------------------------
function ConvertTo-Anchor {
    param([string] $Heading)
    (($Heading.ToLowerInvariant() -replace '[^\w\s-]', '') -replace '\s', '-')
}
function Assert-Link {
    param([string] $FromFile, [string] $Link)
    $parts = $Link -split '#', 2
    $target = if ($parts[0]) { Join-Path (Split-Path -Parent $FromFile) $parts[0] } else { $FromFile }
    if (-not (Test-Path -LiteralPath $target)) { throw "Broken link target in $(Split-Path -Leaf $FromFile): $Link" }
    if ($parts.Count -eq 2 -and $parts[1]) {
        $anchors = Get-Content -LiteralPath $target | Where-Object { $_ -match '^#+\s+(.*\S)\s*$' } |
            ForEach-Object { ConvertTo-Anchor ($_ -replace '^#+\s+', '') }
        if ($anchors -notcontains $parts[1]) { throw "Broken link anchor in $(Split-Path -Leaf $FromFile): $Link" }
    }
}
foreach ($file in $mainPath, $runbookPath) {
    $content = Get-Content -LiteralPath $file -Raw
    foreach ($match in [regex]::Matches($content, '\]\(([^)\s]+)\)')) {
        $link = $match.Groups[1].Value
        if ($link -notmatch '^(https?:|mailto:)') { Assert-Link -FromFile $file -Link $link }
    }
}
$brokenRejected = $false
try { Assert-Link -FromFile $mainPath -Link 'references/runbook.md#no-such-heading' }
catch { $brokenRejected = $_.Exception.Message -like 'Broken link anchor*' }
if (-not $brokenRejected) { throw 'a broken link anchor was not rejected' }

"audit-azure contract OK - $words words"
