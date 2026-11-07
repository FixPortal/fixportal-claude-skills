$ErrorActionPreference = 'Stop'

$skill = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'SKILL.md')
if ($skill -notmatch '(?is)In repository mode only.*test-managed-product-boundary\.ps1') {
    throw 'The managed product boundary guard must be scoped to repository mode.'
}

# R05: "No benchmark required" must be gated on the source-scan flag, not only on the
# project-scan flag; the marker scan truncates at 64 files/directories.
if ($skill -notmatch '(?s)No benchmark required\*\*.{0,400}sourceInventoryComplete') {
    throw '"No benchmark required" must be conditioned on sourceInventoryComplete (or a cited full manual read).'
}

# CX17: the publisher's path-case rule must come from a probe of the volume, not from the OS
# alone. No case-insensitive non-Windows volume exists on this host to drive it end to end,
# so the wiring is pinned instead.
$publisher = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'scripts' 'publish-performance-audit.ps1')
if ($publisher -notmatch 'volumeIgnoresCase' -or $publisher -match '\$pathComparison = if \(\[OperatingSystem\]::IsWindows\(\)\)') {
    throw 'publish-performance-audit.ps1 must derive its path-case rule from the volume (probe), not IsWindows alone.'
}

Write-Host 'managed product boundary wiring OK'
