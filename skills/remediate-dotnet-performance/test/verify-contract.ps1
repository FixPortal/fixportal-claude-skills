#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-That {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$skillPath = Join-Path $PSScriptRoot '..'
$auditPath = Join-Path $skillPath '..' 'audit-dotnet-performance'
$manifestValidator = Join-Path $auditPath 'scripts' 'test-performance-manifest.ps1'
 $manifestPath = Join-Path $PSScriptRoot 'fixtures' 'current.manifest.json'

foreach ($resource in @(
    (Join-Path $skillPath 'SKILL.md'),
    (Join-Path $skillPath 'references' 'experiment-runbook.md'),
    (Join-Path $skillPath 'references' 'change-record.md'),
    $manifestValidator,
    $manifestPath
)) {
    Assert-That (Test-Path -LiteralPath $resource -PathType Leaf) "Expected linked contract resource '$resource'."
}

$findingJson = & pwsh -NoProfile -File $manifestValidator -Path $manifestPath -Mode Finding -FindingId PERF-001
Assert-That ($LASTEXITCODE -eq 0) 'Expected audit finding validation to pass.'
$finding = $findingJson | ConvertFrom-Json
Assert-That ($finding.finding.id -eq 'PERF-001') 'Expected exactly the selected unresolved finding.'
Assert-That ($finding.repository.head -eq '0123456789abcdef') 'Expected audited repository identity.'
Assert-That ($finding.finding.workload.id -eq 'format') 'Expected selected workload handoff.'
Assert-That ($finding.finding.productBoundary.allowed -eq 'managed-public-api') 'Expected managed product boundary handoff.'

Write-Host 'PASS: remediation manifest handoff verified.'
