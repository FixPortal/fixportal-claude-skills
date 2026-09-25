#requires -Version 7
<#
.SYNOPSIS
Writes a repository's .github/canonical-assets.json from the inventory and the assets present.

.DESCRIPTION
The divergence gate's write half. assert_canonical_assets.py (the CI verifier) reads this
file; this script writes it. A repository that deliberately edits a canonical asset
regenerates the manifest and commits both in the same PR -- the manifest diff is what
makes the divergence an explicit, reviewable act instead of a silent one.

Hash contract (shared with the verifier, asserted cross-implementation by
scaffold-ci/test/verify-canonical-assets.ps1): UTF-8 with BOM tolerated, CRLF/CR -> LF,
UTF-8 no BOM, sha256 lowercase hex. Line endings and BOM are normalised -- git flips
those per .gitattributes. On a `uses: owner/repo@<40-hex sha>` line the SHA and any
trailing `# vX` comment are masked, so a Dependabot pin bump in a consuming repo does not
read as divergence; the action name and any non-SHA ref stay hashed. Everything else is
exact.

The provenance block is ADVISORY -- consumer CI cannot verify it (no network, by design).
It records which canonical checkout the repo last synced from: the repository name (the
-CanonicalRepository argument) and the HEAD of the checkout THIS SCRIPT runs from. Run
from a mirror's own scaffold-ci copy with -CanonicalRepository naming the mirror, so the
public artefact never names the private repo.

Rails, each fail-closed: not a git repository root; zero inventoried assets present (a
manifest that verifies nothing reads as success over nothing); an existing manifest that
is not strict-valid JSON (it may carry a hand-edit -- never overwrite one blindly, and
pwsh's ConvertFrom-Json is trailing-comma-lenient, so the check uses a strict parser); an
asset that is not valid UTF-8 (the Python verifier strict-decodes, so a hash recorded over
replacement characters could never verify). This script writes ONLY the manifest: it
never edits assets, ci.yml, or the review policy.

.EXAMPLE
pwsh -File scaffold-ci/scripts/sync-canonical-asset-manifest.ps1 -RepoRoot <workdir>\your-repo
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepoRoot,

    # Advisory provenance only (see above); name the repository this skill checkout was cloned from.
    [string] $CanonicalRepository = 'YourOrg/your-skills-repo'
)

$ErrorActionPreference = 'Stop'

$target = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $target '.git'))) {
    throw "$target is not a git repository root -- refusing to write a manifest outside one."
}

$inventoryPath = Join-Path $PSScriptRoot 'canonical-assets.json'
$inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json

# The hash contract, PowerShell side. utf8-sig tolerance comes free: ReadAllText consumes
# a BOM when one is present and reads BOM-less UTF-8 by default. The decode is STRICT
# (throwOnInvalidBytes): the Python verifier strict-decodes, so a hash recorded over
# U+FFFD replacement characters could never verify -- refuse at generation time instead.
# Must stay equivalent to the verifier's PINNED_USES pattern -- both sides of the contract.
$PinnedUses = '(?m)^([ \t]*(?:-[ \t]+)?uses:[ \t]*[^\s@#]+@)[0-9a-f]{40}(?:[ \t]+#.*)?$'
function Get-AssetHash([string] $Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)) -replace "\r\n?", "`n"
    $text = $text -creplace $PinnedUses, '$1<pinned>'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$assets = @(
    foreach ($entry in $inventory.assets) {
        $copyPath = Join-Path $target ($entry.relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $copyPath -PathType Leaf) {
            $copyHash = $null
            try { $copyHash = Get-AssetHash $copyPath }
            catch { throw "$($entry.relative) is not valid UTF-8 -- re-encode it deliberately; refusing to record a hash of replacement characters." }
            [pscustomobject]@{
                path = $entry.relative
                sha256 = $copyHash
                verbatim = [bool] $entry.verbatim
            }
            # Advisory only: the manifest records the COPY's hash either way. This note is
            # so an operator recording a divergence notices that is what they are doing.
            $canonicalPath = Join-Path (Split-Path -Parent $PSScriptRoot) ($entry.canonical -replace '/', [IO.Path]::DirectorySeparatorChar)
            if ($entry.verbatim -and (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
                $canonicalHash = $null
                try { $canonicalHash = Get-AssetHash $canonicalPath }
                catch { throw "$canonicalPath is not valid UTF-8 -- re-encode it deliberately; refusing to record a hash of replacement characters." }
                if ($canonicalHash -ne $copyHash) {
                    Write-Host "note: $($entry.relative) differs from canonical (expected for a sanctioned extension; otherwise confirm deliberate)"
                }
            }
        }
    }
)
if ($assets.Count -eq 0) {
    throw "$target carries none of the inventoried canonical assets -- refusing to write a manifest that verifies nothing."
}

$manifestPath = Join-Path (Join-Path $target '.github') 'canonical-assets.json'
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $null = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($manifestPath))
    }
    catch {
        throw "$manifestPath exists and is not strict-valid JSON -- it may carry a hand-edit. Fix or remove it deliberately; refusing to overwrite."
    }
}

$headOut = (& git -C $PSScriptRoot rev-parse HEAD 2>&1 | Out-String).Trim()
$head = ($headOut -split "`n" | Where-Object { $_ -match '^[0-9a-f]{40}$' } | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0 -or -not $head) {
    throw "could not resolve the canonical checkout's HEAD for the provenance block: $headOut"
}

$manifest = [pscustomobject]@{
    schema = 1
    canonical = [pscustomobject]@{
        repository = $CanonicalRepository
        commit = $head
        syncedAt = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
    }
    assets = @($assets | Sort-Object path)
}
$json = ($manifest | ConvertTo-Json -Depth 5) -replace "\r\n?", "`n"
New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force | Out-Null
[IO.File]::WriteAllText($manifestPath, $json + "`n", [Text.UTF8Encoding]::new($false))

Write-Host "wrote $manifestPath ($($assets.Count) asset(s), canonical ${CanonicalRepository}@$($head.Substring(0, 7)))"
foreach ($asset in $assets) { Write-Host "  $($asset.path)" }
