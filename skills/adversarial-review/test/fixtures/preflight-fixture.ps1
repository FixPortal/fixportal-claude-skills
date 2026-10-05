# Shared fixture helper: write the pre-flight evidence run-review.ps1 requires.
#
# The driver refuses to start without preflight.json in the run root (SKILL.md
# pre-flight 2), so every contract test that invokes it must supply one. Dot-source
# this and call Write-PreflightFixture on the directory that holds the WorkDir --
# the driver looks in WorkDir and then its immediate parent, so one file beside a
# test's several work directories covers them all.
function Write-PreflightFixture {
    param(
        [Parameter(Mandatory)][string] $Dir,
        [string] $ManifestPath,
        [string[]] $ReviewerId
    )
    $ids = @()
    if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath)) {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        $ids += @($manifest.reviewers | Where-Object { $_.enabled } | ForEach-Object { [string]$_.id })
    }
    $ids += @($ReviewerId)
    $ids = @($ids | Where-Object { $_ } | Sort-Object -Unique)
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $entries = @($ids | ForEach-Object {
        [ordered]@{ reviewer = $_; wrapper = 'fixture'; command = 'fixture preflight'; result = 'PREFLIGHT_SUCCESS' }
    })
    [ordered]@{ runId = (Split-Path -Leaf $Dir); checked = $entries } |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $Dir 'preflight.json') -Encoding utf8
}
