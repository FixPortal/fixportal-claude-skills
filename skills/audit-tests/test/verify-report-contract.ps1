$ErrorActionPreference = 'Stop'

$skillRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$validator = Join-Path $skillRoot 'scripts/test-audit-report.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('test-audit-report-' + [guid]::NewGuid().ToString('N'))

function Assert-Fails([scriptblock] $Action, [string] $expectedPattern, [string] $because) {
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -match $expectedPattern) { return }
        throw "$because`nExpected error matching: $expectedPattern`nActual: $($_.Exception.Message)"
    }
    throw "$because`nExpected the action to fail."
}

function Write-Report(
    [string] $Name,
    [string] $Status,
    [string] $RequiredAxes,
    [string] $CompletedAxes,
    [string] $FailedAxes,
    [int] $UnverifiedCritical,
    [int] $UnverifiedHigh
) {
    $path = Join-Path $tempRoot $Name
    @"
---
status: $Status
required-evidence-axes: $RequiredAxes
completed-evidence-axes: $CompletedAxes
failed-evidence-axes: $FailedAxes
unverified-critical-items: $UnverifiedCritical
unverified-high-items: $UnverifiedHigh
---

## 1. Test-suite assessment
Assessment.
"@ | Set-Content -LiteralPath $path
    $path
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    if (-not (Test-Path -LiteralPath $validator)) {
        throw 'The test-audit report validator is missing.'
    }

    $complete = Write-Report 'complete.md' 'Complete' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, G, H' 'none' 0 0
    & $validator -Path $complete | Out-Null

    $failedAxis = Write-Report 'failed-axis.md' 'Complete' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, H' 'G' 0 0
    Assert-Fails { & $validator -Path $failedAxis | Out-Null } 'failed evidence axes.*G' 'Complete must be rejected when a required evidence axis failed.'

    $collapsedAxes = Write-Report 'collapsed-axes.md' 'Complete' 'A, B, C, D, E, F, G, H' 'A-G, H' 'none' 0 0
    Assert-Fails { & $validator -Path $collapsedAxes | Out-Null } 'invalid evidence axis|missing completed evidence axes' 'Complete must require each evidence axis independently.'

    $unverifiedCritical = Write-Report 'unverified-critical.md' 'Complete' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, G, H' 'none' 1 0
    Assert-Fails { & $validator -Path $unverifiedCritical | Out-Null } 'unverified Critical' 'Complete must be rejected while a Critical item is unverified.'

    $unverifiedHigh = Write-Report 'unverified-high.md' 'Complete' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, G, H' 'none' 0 1
    Assert-Fails { & $validator -Path $unverifiedHigh | Out-Null } 'unverified High' 'Complete must be rejected while a High item is unverified.'

    $partial = Write-Report 'partial.md' 'Critical tier verified; High tier deferred' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, H' 'G' 0 4
    & $validator -Path $partial | Out-Null

    $unsettledUnderCounted = Write-Report 'unsettled-under-counted.md' 'Critical tier verified; host evidence pending' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, H' 'G' 0 0
    Add-Content -LiteralPath $unsettledUnderCounted -Value "`n## Unsettled — host evidence required`n- **Critical** — downstream check needs host access."
    Assert-Fails { & $validator -Path $unsettledUnderCounted | Out-Null } 'lower than the 1 Critical Unsettled' 'An Unsettled Critical item must be tied to its frontmatter counter.'

    $unsettledCounted = Write-Report 'unsettled-counted.md' 'Critical tier verified; host evidence pending' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, H' 'G' 1 0
    Add-Content -LiteralPath $unsettledCounted -Value "`n## Unsettled — host evidence required`n- **Critical** — downstream check needs host access."
    & $validator -Path $unsettledCounted | Out-Null

    $unsettledSections = Write-Report 'unsettled-sections.md' 'Critical tier verified; host evidence pending' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, H' 'G' 1 0
    Add-Content -LiteralPath $unsettledSections -Value "`n## Unsettled — host evidence required`n- **Critical** — first section.`n`n## Evidence notes`nResolved.`n`n## Unsettled — host evidence required`n- **High** — second section."
    Assert-Fails { & $validator -Path $unsettledSections | Out-Null } 'lower than the 1 High Unsettled' 'Counters must cover every Unsettled section.'

    # Items outside the mandated `- **<Tier>** —` form must be rejected, not counted: an ordered
    # item and a `**Critical path**` bullet both must not slip past (or inflate) the counters.
    $orderedItem = Write-Report 'unsettled-ordered.md' 'Critical tier verified; host evidence pending' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, H' 'G' 0 0
    Add-Content -LiteralPath $orderedItem -Value "`n## Unsettled — host evidence required`n1. **Critical** — downstream check needs host access."
    Assert-Fails { & $validator -Path $orderedItem | Out-Null } 'mandated form' 'An ordered Unsettled item must be rejected, not silently uncounted.'

    $lookalikeTier = Write-Report 'unsettled-lookalike.md' 'Critical tier verified; host evidence pending' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, H' 'G' 1 0
    Add-Content -LiteralPath $lookalikeTier -Value "`n## Unsettled — host evidence required`n- **Critical path** — downstream check needs host access."
    Assert-Fails { & $validator -Path $lookalikeTier | Out-Null } 'mandated form' 'A `**Critical path**` bullet must not be counted as a Critical item.'

    $indentedTier = Write-Report 'unsettled-indented.md' 'Critical tier verified; host evidence pending' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, H' 'G' 0 0
    Add-Content -LiteralPath $indentedTier -Value "`n## Unsettled — host evidence required`n  - Critical — host evidence required."
    Assert-Fails { & $validator -Path $indentedTier | Out-Null } 'mandated form' 'An indented tier-looking Unsettled item must be rejected, not skipped.'

    # ...and the conforming shape, with nested detail and a Medium item, stays valid.
    $conforming = Write-Report 'unsettled-conforming.md' 'Critical tier verified; host evidence pending' 'A, B, C, D, E, F, G, H' 'A, B, C, D, E, F, H' 'G' 0 1
    Add-Content -LiteralPath $conforming -Value "`n## Unsettled — host evidence required`n- **High** — downstream check needs host access.`n  - detail line`n  - High latency was observed on the slow lane.`n- **Medium** — informational."
    & $validator -Path $conforming | Out-Null

    'audit-tests report contract OK'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
