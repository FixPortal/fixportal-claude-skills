$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$main = Get-Content (Join-Path $root 'SKILL.md') -Raw
$runbook = Get-Content (Join-Path $root 'references' 'runbook.md') -Raw
$text = $main + "`n" + $runbook
$words = ([regex]::Matches($main, '\b[\w/-]+\b')).Count

if ($words -ge 500) { throw "azure-cost-sweep/SKILL.md is $words words; keep detail in the runbook" }
foreach ($needle in 'Quick Reference', 'properties.nextLink', "currencyCode='GBP'",
                     'APPLIED (live only) — NOT PERSISTED', 'REALISED',
                     'one metrics window', 'prior-sweep/drift reconciliation') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "azure-cost-sweep missing contract: $needle"
    }
}
if ($runbook -match '\$sub\b') {
    throw 'azure-cost-sweep copyable commands must not depend on a variable from another fence'
}

$firstRunBranch = [regex]::Match(
    $runbook,
    '(?ims)^## 0\. Prior runs and drift(?<body>.*?)(?=^## 1\. )'
).Groups['body'].Value
foreach ($needle in 'No prior vault log', 'FIRST RUN — no prior baseline', 'continue') {
    if ($firstRunBranch -notmatch [regex]::Escape($needle)) {
        throw "azure-cost-sweep first-run branch is missing: $needle"
    }
}
if ($firstRunBranch -match '(?is)missing vault log IS a stop') {
    throw 'azure-cost-sweep must not stop a first run merely because no prior vault log exists'
}

$subscriptionCommand = 'az account list --all --query "[?state==''Enabled'' && id!=null && id!='''' && name!=''N/A(tenant level account)''].id" -o tsv'
if ($runbook -notmatch [regex]::Escape($subscriptionCommand)) {
    throw 'azure-cost-sweep must select enabled subscriptions by non-empty ID AND by name, not by ID alone'
}

# The pseudo-account fixture is deliberately built BOTH WAYS. Hard-coding `id = $null`
# alone proved the filter works on the ASSUMED shape and was no evidence the shape is real
# - the circularity the finding names. The name test is correct under both shapes, so the
# second fixture is the one that would have caught a tenant entry carrying an id.
$accounts = @(
    [pscustomobject]@{ id = 'enabled-subscription'; name = 'Real Subscription'; state = 'Enabled' },
    [pscustomobject]@{ id = $null; name = 'N/A(tenant level account)'; state = 'Enabled'; tenantId = 'tenant-pseudo-account' },
    [pscustomobject]@{ id = 'tenant-guid'; name = 'N/A(tenant level account)'; state = 'Enabled'; tenantId = 'tenant-guid' },
    [pscustomobject]@{ id = 'disabled-subscription'; name = 'Disabled Subscription'; state = 'Disabled' }
)
$selectedIds = @($accounts | Where-Object {
    $_.state -eq 'Enabled' -and $null -ne $_.id -and $_.id -ne '' -and $_.name -ne 'N/A(tenant level account)'
} | ForEach-Object id)
if (@($selectedIds).Count -ne 1 -or $selectedIds[0] -ne 'enabled-subscription') {
    throw "tenant pseudo-account or disabled subscription passed the enabled-subscription filter: $($selectedIds -join ', ')"
}

$timestampedOutput = '<YYYY-MM-DDTHH-mm-ss.fffffffZ>.md'
foreach ($needle in $timestampedOutput, 'New-Item -ItemType File') {
    if ($runbook -notmatch [regex]::Escape($needle)) {
        throw "azure-cost-sweep immutable output contract is missing: $needle"
    }
}
if ($runbook -notmatch '(?is)never\s+overwrite') {
    throw 'azure-cost-sweep immutable output contract is missing: never overwrite'
}
if ($runbook -match '(?is)New-Item\s+-ItemType\s+File[^\r\n]*-Force') {
    throw 'azure-cost-sweep output creation must not force-overwrite an existing log'
}

$temp = Join-Path ([IO.Path]::GetTempPath()) "azure-cost-sweep-output-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $first = Join-Path $temp '2026-08-12T12-00-00.0000000Z.md'
    $second = Join-Path $temp '2026-08-12T12-00-01.0000000Z.md'
    New-Item -ItemType File -Path $first | Out-Null
    New-Item -ItemType File -Path $second | Out-Null
    if ($first -eq $second -or -not (Test-Path -LiteralPath $first) -or -not (Test-Path -LiteralPath $second)) {
        throw 'two same-day outputs were not created as distinct files'
    }
    try {
        New-Item -ItemType File -Path $first -ErrorAction Stop | Out-Null
        throw 'immutable output creation overwrote an existing same-timestamp file'
    }
    catch [System.IO.IOException] { }
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

function Assert-SectionLink {
    param([string]$Link)

    $parts = $Link -split '#', 2
    $target = Join-Path $root $parts[0]
    if (-not (Test-Path -LiteralPath $target)) { throw "Broken section link target: $Link" }
    $heading = ($parts[1] -replace '^(\d+)-', '$1. ' -replace '-', ' ')
    $content = Get-Content -LiteralPath $target -Raw
    if ($content -notmatch "(?im)^#+\s+$([regex]::Escape($heading))\s*$") {
        throw "Broken section link anchor: $Link"
    }
}

$firstRunLink = 'references/runbook.md#0-prior-runs-and-drift'
if ($main -notmatch [regex]::Escape("]($firstRunLink)")) {
    throw "azure-cost-sweep must link to the first-run branch: $firstRunLink"
}
Assert-SectionLink $firstRunLink
$brokenLinkRejected = $false
try { Assert-SectionLink 'references/runbook.md#0-prior-run-and-drift' }
catch { $brokenLinkRejected = $_.Exception.Message -like 'Broken section link anchor:*' }
if (-not $brokenLinkRejected) { throw 'broken section link was not rejected' }

"azure-cost-sweep contract OK — $words words"
