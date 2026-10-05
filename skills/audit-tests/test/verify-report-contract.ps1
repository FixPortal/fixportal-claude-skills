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

    'audit-tests report contract OK'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
