<#
.SYNOPSIS
Reports which repositories still carry the canonical copy of a shipped-verbatim asset.

.DESCRIPTION
scaffold-ci ships several controls BY COPY -- assert_gate_coverage.py,
assert_workflow_hygiene.py, summarize-stryker.ps1. A copy has no link back to its
source, so canonical moving forward is invisible in every consuming repository: the
2026-09-03 CI audit found SIX repositories running checkers months behind canonical,
two of them with known fail-open bugs still live. Refreshing them by hand fixes the
instance and resets the clock; it does not fix the class. This is the detector.

WHY IT CLASSIFIES INSTEAD OF THROWING. audit-ci already has
scripts/compare-canonical-file.ps1, which throws on any difference. That check could
never be wired estate-wide, because three repositories legitimately EXTEND the assets
they copy -- one with Bicep/ACA deployment-topology assertions,
one with a service-key leak guard,
one with the review-tier exemption. A strict equality check is
permanently red in exactly those three, and a permanently-red check is one nobody
reads. So the question asked here is not "is this file identical" but "does this copy
still contain everything canonical says", which a sanctioned superset answers YES and
a stale copy answers NO.

    current   copy is canonical, byte for byte (line endings normalised)
    extended  every canonical line present, plus local additions -- sanctioned superset
    drifted   canonical has content the copy lacks: stale, or genuinely diverged
    local     would be drifted, but the repository is a DECLARED local implementation
    absent    repository does not carry this asset

Only `drifted` fails. MissingFromCopy/AddedInCopy are reported so a stale plain copy
(missing N, added 0) is distinguishable from an extended copy that has also fallen
behind (missing N, added many) without opening a diff.

LIMITS, stated so a pass is not mistaken for more than it is. This compares CONTENT
PRESENCE, not behaviour, and Compare-Object is a MULTISET diff -- position is ignored.
Three consequences, all of which report `current` or `extended` and pass:

  * a copy holding every canonical line in a DIFFERENT ORDER (a function moved, two
    statements swapped) is indistinguishable from canonical here, even though the
    reorder may change behaviour;
  * a copy that keeps every canonical line while ADDING one that disables it passes as
    `extended`;
  * whitespace-only lines are ignored, so a copy differing only in blank lines is
    `current`.

Rewriting a canonical line IS caught -- the original goes missing. What this answers is
"did this copy receive canonical's content", which is the distribution question. It is
not a review, and it is not a behavioural equivalence check.

    #
    # The INTENT question -- "was this local edit deliberate" -- is answered at PR time in
    # the consuming repo by the canonical-asset manifest (.github/canonical-assets.json)
    # and its verifier, not here.

.EXAMPLE
pwsh -File sweep-canonical-asset-drift.ps1 -Root <estate-root>

.EXAMPLE
pwsh -File sweep-canonical-asset-drift.ps1 -Root <estate-root> -Json | ConvertFrom-Json
#>
# <estate-root> is the parent folder whose immediate children are the repositories to sweep;
# supply it explicitly.
[CmdletBinding()]
param(
    # Directory whose immediate children are the repositories to sweep.
    [Parameter(Mandatory)]
    [string] $Root,

    # A single canonical file to check. Omit to sweep every asset in the default set.
    [string] $CanonicalPath,

    # Where the asset lives inside a consuming repo. Required with -CanonicalPath.
    [string] $RelativePath,

    # Repositories that run their own review-tier classifier; their review-tier.yml copies
    # read local` rather than drifted`.
    [string[]] $LocalTierImplementations = @(),

    # Emit JSON rather than a table, for a scheduled task or another script.
    [switch] $Json
)

$ErrorActionPreference = 'Stop'

# The swept set, read from the inventory so the sweep and the manifest generator can never
# disagree about what ships: every verbatim asset, plus each verbatim:false asset whose
# sanctioned variance is DECLARED below. The other verbatim:false entries
# (review-policy-guard.yml, secret-sweep.yml) carry per-repo cron and env; the manifest
# verifier covers those, and sweeping them would report permitted adaptation as drift.
#
# review-tier.yml IS swept. Leaving it out is how every consumer fell about 55 lines behind
# canonical with nothing noticing. Its variance is declared
# here rather than excusing the whole file:
#
#   Mask                  the trigger's `branches: [...]` line names the repository's
#                         default branch -- some repositories watch `develop`. Masked on
#                         BOTH sides, so a copy with no such line still reads as drifted.
#   LocalImplementations  repositories that run their own tier classifier, supplied by
#                         -LocalTierImplementations (the canonical copy of this script
#                         lists its estate's repositories here). A copy there
#                         that lacks canonical lines reads `local`: named in the output,
#                         never failed, and never compared for equivalence -- the
#                         repository owns it.
$DeclaredVariance = @{
    'review-tier.yml' = @{
        Mask                 = '^\s*branches:\s*\[[^\]]*\]\s*$'
        LocalImplementations = $LocalTierImplementations
    }
}

$inventoryPath = Join-Path $PSScriptRoot 'canonical-assets.json'
if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
    throw "canonical asset inventory not found at $inventoryPath -- refusing to guess the asset set."
}
$DefaultAssets = @(
    (Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json).assets |
        Where-Object { $_.verbatim -or $DeclaredVariance.ContainsKey((Split-Path -Leaf $_.canonical)) } |
        ForEach-Object { @{ Canonical = $_.canonical; Relative = $_.relative } }
)
if ($DefaultAssets.Count -eq 0) {
    throw "inventory at $inventoryPath lists no verbatim assets -- refusing to report a clean sweep over nothing."
}

function Get-ContentLines([string] $Path, [string] $Mask) {
    # Normalise line endings before splitting: git normalises on commit and the working
    # tree may not match, so a CRLF checkout of identical content must not read as drift.
    # Whitespace-only lines are dropped -- they carry no assertion, and letting a blank
    # line count as a missing canonical line would report the whole estate as drifted.
    # A line matching the asset's declared Mask becomes one placeholder, not nothing.
    $text = [IO.File]::ReadAllText($Path) -replace "\r\n?", "`n"
    return @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object {
        if ($Mask -and $_ -cmatch $Mask) { '<declared variance>' } else { $_ }
    })
}

function Compare-AgainstCanonical([string[]] $CanonicalLines, [string[]] $CopyLines) {
    # An EMPTY array binds to Compare-Object as $null and throws. A truncated or empty
    # asset is a real shape -- a half-written sync, a bad merge -- and it is maximally
    # drifted, not a reason for the sweep to die and report nothing about any repo.
    if ($CopyLines.Count -eq 0) {
        return [pscustomobject]@{
            Status = 'drifted'; MissingFromCopy = $CanonicalLines.Count; AddedInCopy = 0
        }
    }
    if ($CanonicalLines.Count -eq 0) {
        throw 'The canonical asset is empty -- refusing to report every copy as conformant against nothing.'
    }

    # -SyncWindow must span the file: the default of 5 silently mis-pairs lines in a
    # 600-line checker and would invent both missing and added lines.
    $diff = @(Compare-Object -ReferenceObject $CanonicalLines -DifferenceObject $CopyLines `
        -CaseSensitive -SyncWindow ([int]::MaxValue))

    $missing = @($diff | Where-Object SideIndicator -eq '<=').Count
    $added = @($diff | Where-Object SideIndicator -eq '=>').Count

    $status = if ($missing -gt 0) { 'drifted' } elseif ($added -gt 0) { 'extended' } else { 'current' }
    return [pscustomobject]@{
        Status          = $status
        MissingFromCopy = $missing
        AddedInCopy     = $added
    }
}

# A SANITISED REPUBLICATION is not a consumer, and the question this sweep asks is wrong
# for it. The public mirror republishes these same assets with citations generalised --
# private repository slugs and pull-request numbers cannot be published -- so its comments
# and docstrings differ from canonical BY DESIGN and permanently. Measured 2026-09-22 on
# assert_gate_coverage.py: 41 canonical lines "missing", every one of them a comment or a
# docstring line, and `compare-asset-semantics.py` reported all 81 definitions identical
# in body. The copy is correct; the comparison is not applicable.
#
# Left in this sweep the mirror is drifted forever, and the scheduled check that reads this
# script can never go green -- which is the failure this file's own header warns about: a
# permanently-red control is one nobody reads. It went red on 2026-09-20 and stayed red.
#
# Excluded here, checked THERE. `compare-asset-semantics.py` asserts that the mirror's
# copies are behaviourally identical to canonical, which is the question that actually
# matters for a published checker. Removing it from this sweep without that would be
# silence bought by deletion.
# The canonical copy of this script names its sanitised public republication here; this
# public copy has none to exclude.
$SanitisedRepublications = @()

function Get-Repositories([string] $RootPath) {
    # A linked worktree's .git is a FILE, not a directory. Sweeping worktrees would
    # double-count a repo and report a mid-pass review branch as the estate's state.
    return @(
        Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction Stop |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container } |
            Where-Object { $_.Name -notin $SanitisedRepublications } |
            Sort-Object Name
    )
}

$skillRoot = Split-Path -Parent $PSScriptRoot

if ($CanonicalPath) {
    if (-not $RelativePath) { throw '-RelativePath is required when -CanonicalPath is given.' }
    $assets = @(@{ Canonical = (Resolve-Path -LiteralPath $CanonicalPath).Path; Relative = $RelativePath })
}
else {
    $assets = $DefaultAssets | ForEach-Object {
        @{ Canonical = (Resolve-Path -LiteralPath (Join-Path $skillRoot $_.Canonical)).Path; Relative = $_.Relative }
    }
}

$repos = Get-Repositories $Root
if ($repos.Count -eq 0) {
    throw "$Root contains no git repositories -- refusing to report a clean sweep over nothing."
}

$rows = foreach ($asset in $assets) {
    $assetName = Split-Path -Leaf $asset.Canonical
    $variance = $DeclaredVariance[$assetName]
    $canonicalLines = Get-ContentLines $asset.Canonical $variance.Mask

    foreach ($repo in $repos) {
        $copyPath = Join-Path $repo.FullName $asset.Relative

        if (-not (Test-Path -LiteralPath $copyPath -PathType Leaf)) {
            [pscustomobject]@{
                Repo = $repo.Name; Asset = $assetName; Status = 'absent'
                MissingFromCopy = 0; AddedInCopy = 0; Path = $copyPath
            }
            continue
        }

        $comparison = Compare-AgainstCanonical $canonicalLines (Get-ContentLines $copyPath $variance.Mask)
        $status = $comparison.Status
        if ($status -eq 'drifted' -and $repo.Name -in $variance.LocalImplementations) { $status = 'local' }
        [pscustomobject]@{
            Repo = $repo.Name; Asset = $assetName; Status = $status
            MissingFromCopy = $comparison.MissingFromCopy
            AddedInCopy = $comparison.AddedInCopy
            Path = $copyPath
        }
    }
}

$rows = @($rows)
$drifted = @($rows | Where-Object Status -eq 'drifted')

if ($Json) {
    $rows | ConvertTo-Json -Depth 4
}
else {
    $rows | Where-Object Status -ne 'absent' | Sort-Object Asset, Status, Repo |
        Format-Table Repo, Asset, Status, MissingFromCopy, AddedInCopy -AutoSize

    $counts = $rows | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host "Canonical asset sweep over $($repos.Count) repo(s), $($assets.Count) asset(s): $($counts -join ' ')"

    # NAME WHAT WAS NOT SWEPT. An exclusion nobody can see in the output is the same thing
    # as no coverage: the count reads as the estate and is not. Printed whether or not the
    # repository is present in this root, so a rename cannot make the line quietly vanish
    # along with the check it is pointing at.
    foreach ($excluded in $SanitisedRepublications) {
        Write-Host "Not swept (sanitised republication, comments differ by design): $excluded -- behavioural equivalence is asserted by compare-asset-semantics.py instead."
    }
    foreach ($row in @($rows | Where-Object Status -eq 'local')) {
        Write-Host "Not failed (declared local implementation, owned by the repository): $($row.Repo) $($row.Asset) -- see DeclaredVariance."
    }

    foreach ($row in $drifted) {
        Write-Host "::warning::$($row.Repo) carries a $($row.Asset) missing $($row.MissingFromCopy) canonical line(s). Re-sync it, reapplying any documented local extension on top."
    }

    # NAME THE REPOSITORIES CARRYING NONE OF THE ASSETS.
    #
    # `absent` is deliberately not a failure -- plenty of repositories have no CI to gate
    # and requiring the assets everywhere would be noise. But absent rows are filtered out
    # of the table above, so a repository holding NONE of them appears nowhere in this
    # output at all: it is not in the table, it is not in the warnings, and the counts
    # summarise it as a number. The sweep then reads as an estate-wide verdict while
    # saying nothing whatsoever about that repository.
    #
    # This does not fail, because "has no CI" is a legitimate state and only the operator
    # knows which repositories are meant to be scaffolded. It is printed so the question
    # can be asked at all. A repository appearing here that SHOULD carry the controls is a
    # gap the sweep would otherwise never surface -- which is how a newly created
    # repository joins the estate carrying nothing and nothing says so.
    $bare = $rows | Group-Object Repo | Where-Object {
        @($_.Group | Where-Object Status -ne 'absent').Count -eq 0
    } | ForEach-Object { $_.Name }

    if ($bare) {
        Write-Host "Carrying none of the swept assets ($($bare.Count)): $($bare -join ', ')"
        Write-Host "  Not a failure -- a repository with no CI has nothing to gate. Confirm each is meant to have none."
    }
}

exit ($(if ($drifted.Count -gt 0) { 1 } else { 0 }))
