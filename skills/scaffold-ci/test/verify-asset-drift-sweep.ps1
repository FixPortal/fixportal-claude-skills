$ErrorActionPreference = 'Stop'

# The sweep this exercises exists because a STRICT byte-compare could never be wired
# estate-wide: three repositories legitimately extend assert_workflow_hygiene.py with
# their own assertions, so an equality check is permanently red there and gets ignored.
# An ignored check is not a control. The sweep therefore classifies rather than throws,
# and the classification below is the whole contract:
#
#   current  - copy is canonical, byte for byte (line endings normalised)
#   extended - every canonical line is present, plus local additions (sanctioned superset)
#   drifted  - canonical has content the copy lacks: stale, or genuinely diverged
#   absent   - repo does not carry this asset at all
#
# 'drifted' is the only failing state. 'extended' must NOT fail, or the control is
# unwireable for exactly the repositories that most need it.

$sweep = Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'sweep-canonical-asset-drift.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('asset-drift-' + [guid]::NewGuid().ToString('N'))

# $AssetContent is deliberately UNTYPED: typing it [string] coerces a line array into
# one space-joined line and turns $null into '', which silently writes an empty file
# instead of none at all.
function New-Repo([string] $Name, $AssetContent) {
    $repo = Join-Path $root $Name
    New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
    $scripts = Join-Path $repo '.github/scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    if ($null -ne $AssetContent) {
        Set-Content -LiteralPath (Join-Path $scripts 'checker.py') -Value $AssetContent -Encoding utf8
    }
    return $repo
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    # Canonical asset, in its own directory so the sweep is pointed at a real source.
    $canonicalDir = Join-Path $root '_canonical'
    New-Item -ItemType Directory -Path $canonicalDir -Force | Out-Null
    $canonicalLines = @(
        '#!/usr/bin/env python3'
        '"""Canonical checker."""'
        'import sys'
        ''
        'def main():'
        '    print("canonical")'
        '    return 0'
    )
    $canonicalPath = Join-Path $canonicalDir 'checker.py'
    Set-Content -LiteralPath $canonicalPath -Value $canonicalLines -Encoding utf8

    # current: identical.
    New-Repo 'repo-current' $canonicalLines | Out-Null

    # extended: every canonical line present, plus a local assertion block. This is the
    # shape assert_workflow_hygiene.py takes in <repo> (Bicep/ACA topology)
    # and <repo> (service-key leak guard).
    $extendedLines = $canonicalLines + @(
        ''
        'def local_extension():'
        '    return "repo-specific assertion"'
    )
    New-Repo 'repo-extended' $extendedLines | Out-Null

    # drifted (stale): canonical grew a line this copy never received.
    $staleLines = $canonicalLines | Where-Object { $_ -ne '    return 0' }
    New-Repo 'repo-stale' $staleLines | Out-Null

    # drifted (diverged): a canonical line was locally rewritten, not merely added to.
    $divergedLines = $canonicalLines | ForEach-Object {
        if ($_ -eq '    print("canonical")') { '    print("locally rewritten")' } else { $_ }
    }
    New-Repo 'repo-diverged' $divergedLines | Out-Null

    # absent: a repo that does not ship this asset is not drift, and must not fail.
    New-Repo 'repo-absent' $null | Out-Null

    # CRLF: git normalises line endings on commit and the working tree may not match, so
    # a CRLF copy of identical content must read as current, not as drift. Reporting a
    # whole estate as drifted on line endings alone is how a control gets switched off.
    $crlfRepo = New-Repo 'repo-crlf' $canonicalLines
    $crlfPath = Join-Path $crlfRepo '.github/scripts/checker.py'
    [IO.File]::WriteAllText($crlfPath, (($canonicalLines -join "`r`n") + "`r`n"))

    # A pure REORDER reads as current, because Compare-Object is a multiset diff and
    # ignores position. That is a real limit of what this can answer, and it is pinned
    # here so nobody re-asserts the opposite in the docs: the header used to claim a
    # reorder "reads as drifted (correctly)", which was simply false. Found by Gitar on
    # <repo>#120.
    $reorderedLines = @(
        'def main():'
        '    print("canonical")'
        '    return 0'
        '#!/usr/bin/env python3'
        '"""Canonical checker."""'
        'import sys'
    )
    New-Repo 'repo-reordered' $reorderedLines | Out-Null

    # An EMPTY copy -- a half-finished sync, a bad merge -- is maximally drifted. It used
    # to bind to Compare-Object as $null and kill the whole sweep, so ONE truncated file
    # in one repo meant no verdict about any repo.
    $emptyRepo = New-Repo 'repo-empty' $null
    Set-Content -LiteralPath (Join-Path $emptyRepo '.github/scripts/checker.py') -Value '' -Encoding utf8

    $result = & $sweep -Root $root -CanonicalPath $canonicalPath -RelativePath '.github/scripts/checker.py' -Json | ConvertFrom-Json
    $sweepExit = $LASTEXITCODE

    function Get-Row([string] $Name) {
        $row = $result | Where-Object { $_.Repo -eq $Name }
        if (-not $row) { throw "sweep returned no row for '$Name'; got: $(($result | ForEach-Object Repo) -join ', ')" }
        return $row
    }

    foreach ($case in @(
        @{ Repo = 'repo-current';  Status = 'current' }
        @{ Repo = 'repo-extended'; Status = 'extended' }
        @{ Repo = 'repo-stale';    Status = 'drifted' }
        @{ Repo = 'repo-diverged'; Status = 'drifted' }
        @{ Repo = 'repo-absent';   Status = 'absent' }
        @{ Repo = 'repo-crlf';     Status = 'current' }
        @{ Repo = 'repo-empty';    Status = 'drifted' }
        @{ Repo = 'repo-reordered'; Status = 'current' }
    )) {
        $row = Get-Row $case.Repo
        if ($row.Status -ne $case.Status) {
            throw "$($case.Repo): expected status '$($case.Status)', got '$($row.Status)'"
        }
    }

    # The counts are what let a reader tell a pure stale copy from an extended one that
    # has also fallen behind, without opening a diff.
    $stale = Get-Row 'repo-stale'
    if ($stale.MissingFromCopy -lt 1) { throw "repo-stale must report the canonical line it lacks; got MissingFromCopy=$($stale.MissingFromCopy)" }
    if ($stale.AddedInCopy -ne 0) { throw "repo-stale added nothing locally; got AddedInCopy=$($stale.AddedInCopy)" }

    $extended = Get-Row 'repo-extended'
    if ($extended.MissingFromCopy -ne 0) { throw "repo-extended is a superset and must lack no canonical line; got MissingFromCopy=$($extended.MissingFromCopy)" }
    if ($extended.AddedInCopy -lt 1) { throw "repo-extended must report its local additions; got AddedInCopy=$($extended.AddedInCopy)" }

    # Exit code is the whole point of it being wireable: drift present must be non-zero.
    if ($sweepExit -eq 0) { throw "the sweep found drifted copies and must exit non-zero; got $sweepExit" }

    # ...and a clean estate must exit zero, or nobody can gate on it.
    $cleanRoot = Join-Path $root '_clean'
    New-Item -ItemType Directory -Path $cleanRoot -Force | Out-Null
    foreach ($name in 'clean-a', 'clean-b') {
        $repo = Join-Path $cleanRoot $name
        New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo '.github/scripts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.github/scripts/checker.py') -Value $canonicalLines -Encoding utf8
    }
    & $sweep -Root $cleanRoot -CanonicalPath $canonicalPath -RelativePath '.github/scripts/checker.py' -Json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "a clean estate must exit 0; got $LASTEXITCODE" }

    # THE DEFAULT MULTI-ASSET PATH -- `-Root` alone, which is the invocation SKILL.md
    # documents and the one a scheduled sweep would use. Every case above pins the
    # explicit -CanonicalPath path instead, so the default asset list, its relative
    # paths, and its resolution against the skill directory were entirely unexercised:
    # a typo in $DefaultAssets would have shipped green. Found by Gitar on
    # <repo>#120.
    $skillRoot = Split-Path -Parent (Split-Path -Parent $sweep)
    $defaultRoot = Join-Path $root '_default'
    $defaultRepo = Join-Path $defaultRoot 'repo-real'
    foreach ($relative in '.github/scripts', '.github/workflows', 'scripts') {
        New-Item -ItemType Directory -Path (Join-Path $defaultRepo $relative) -Force | Out-Null
    }
    New-Item -ItemType Directory -Path (Join-Path $defaultRepo '.git') -Force | Out-Null

    # Copy the REAL canonical assets in, so a clean result proves the default list
    # resolves to files that exist at the paths it claims.
    foreach ($pair in @(
        @{ From = 'assets/assert_canonical_assets.py';  To = '.github/scripts/assert_canonical_assets.py' }
        @{ From = 'assets/assert_gate_coverage.py';     To = '.github/scripts/assert_gate_coverage.py' }
        @{ From = 'assets/assert_workflow_hygiene.py';  To = '.github/scripts/assert_workflow_hygiene.py' }
        @{ From = 'templates/summarize-stryker.ps1';    To = 'scripts/summarize-stryker.ps1' }
        @{ From = 'assets/review-tier.yml';             To = '.github/workflows/review-tier.yml' }
    )) {
        Copy-Item (Join-Path $skillRoot $pair.From) (Join-Path $defaultRepo $pair.To) -Force
    }

    $defaultResult = & $sweep -Root $defaultRoot -Json | ConvertFrom-Json
    $defaultExit = $LASTEXITCODE
    if ($defaultExit -ne 0) {
        throw "the default asset sweep must pass over verbatim copies of canonical; exit $defaultExit`n$($defaultResult | ConvertTo-Json -Depth 4)"
    }
    if (@($defaultResult).Count -ne 5) {
        throw "the default sweep must cover the four shipped-verbatim assets and review-tier.yml; got $(@($defaultResult).Count) row(s)"
    }
    foreach ($row in $defaultResult) {
        if ($row.Status -ne 'current') {
            throw "default sweep: $($row.Asset) is a verbatim copy and must read 'current'; got '$($row.Status)'"
        }
    }

    # review-tier.yml's DECLARED variance: the trigger's
    # branch line is masked, and a declared local implementation reads `local`, not
    # drifted. Nothing else is excused: a stale copy, or one with no branch line at all,
    # still fails.
    $tierCanonical = Get-Content -LiteralPath (Join-Path $skillRoot 'assets/review-tier.yml')
    if (@($tierCanonical -match '^\s*branches:\s*\[main\]\s*$').Count -ne 1) {
        throw "canonical review-tier.yml must carry exactly one 'branches: [main]' line for the mask cases to mean anything"
    }
    $tierRoot = Join-Path $root '_tier'
    function New-TierRepo([string] $Name, $Lines) {
        $repo = Join-Path $tierRoot $Name
        New-Item -ItemType Directory -Path (Join-Path $repo '.git'), (Join-Path $repo '.github/workflows') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.github/workflows/review-tier.yml') -Value $Lines -Encoding utf8
    }
    $jobsLine = $tierCanonical | Where-Object { $_ -match '^jobs:' } | Select-Object -First 1
    New-TierRepo 'repo-other-branch' ($tierCanonical -replace '^(\s*branches:\s*)\[main\]\s*$', '$1[develop]')
    New-TierRepo 'repo-local-tier' @('name: Review tier', 'on: pull_request_target', 'jobs: {}')
    New-TierRepo 'repo-tier-stale' ($tierCanonical | Where-Object { $_ -ne $jobsLine })
    New-TierRepo 'repo-no-branches' ($tierCanonical | Where-Object { $_ -notmatch '^\s*branches:' })

    $tierResult = @(& $sweep -Root $tierRoot -LocalTierImplementations 'repo-local-tier' -Json | ConvertFrom-Json | Where-Object Asset -eq 'review-tier.yml')
    $tierExit = $LASTEXITCODE
    foreach ($case in @(
        @{ Repo = 'repo-other-branch'; Status = 'current' }
        @{ Repo = 'repo-local-tier';   Status = 'local' }
        @{ Repo = 'repo-tier-stale';   Status = 'drifted' }
        @{ Repo = 'repo-no-branches';  Status = 'drifted' }
    )) {
        $row = $tierResult | Where-Object Repo -eq $case.Repo
        if ($row.Status -ne $case.Status) {
            throw "review-tier.yml in $($case.Repo): expected '$($case.Status)', got '$($row.Status)'"
        }
    }
    if ($tierExit -eq 0) { throw "drifted review-tier.yml copies must fail the sweep; got exit $tierExit" }

    Remove-Item -LiteralPath (Join-Path $tierRoot 'repo-tier-stale'), (Join-Path $tierRoot 'repo-no-branches') -Recurse -Force
    & $sweep -Root $tierRoot -LocalTierImplementations 'repo-local-tier' -Json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "a masked branch line and a declared local implementation must not fail the sweep; got exit $LASTEXITCODE" }

    'sweep-canonical-asset-drift.ps1 OK - current/extended/drifted/local/absent classification, reorder limit, CRLF tolerance, line counts, exit codes, the default multi-asset path, and review-tier.yml''s declared variance'
}
finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
