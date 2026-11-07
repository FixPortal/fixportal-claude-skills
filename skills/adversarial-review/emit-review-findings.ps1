#Requires -Version 7
<#
.SYNOPSIS
    Emit the host-adjudicated full finding set after participant telemetry.
.DESCRIPTION
    Reads the optional findings array documented in docs/run-artefacts.md.
    Silently skips when either Observatory environment variable is unset or the
    verdict has no findings property. Invalid enums fail before any request.
    HTTP failures are reported and return a nonzero exit code.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RunId,
    [string] $Repo = $null,
    [Parameter(Mandatory)] [string] $VerdictPath
)
$ErrorActionPreference = 'Stop'
if (-not ($env:OBSERVATORY_API_KEY -and $env:OBSERVATORY_URL)) { exit 0 }

$verdict = Get-Content -LiteralPath $VerdictPath -Raw | ConvertFrom-Json -AsHashtable
if (-not $verdict.Contains('findings')) { exit 0 }
if ($verdict.findings -isnot [array]) { throw 'findings must be an array.' }
foreach ($finding in $verdict.findings) {
    if ($finding.severity -cnotin @('critical', 'high', 'medium', 'low', 'unknown')) {
        throw 'Invalid finding severity.'
    }
    if ($finding.outcome -cnotin @('accepted', 'refuted', 'dropped', 'indeterminate')) {
        throw 'Invalid finding outcome.'
    }
    foreach ($assessment in $finding.assessments) {
        if ($assessment.verdict -cnotin @('agree', 'false-positive', 'needs-evidence', 'needs-repo', 'abstained')) {
            throw 'Invalid assessment verdict.'
        }
    }
}
$body = @{ runId = $RunId; repo = $Repo; findings = $verdict.findings } | ConvertTo-Json -Depth 20 -Compress
try {
    Invoke-RestMethod -Uri "$($env:OBSERVATORY_URL)/api/adversarial-review/findings" `
        -Method Post -ContentType 'application/json' `
        -Headers @{ 'X-Observatory-Key' = $env:OBSERVATORY_API_KEY } `
        -Body $body -TimeoutSec 5 -ErrorAction Stop | Out-Null
} catch {
    Write-Error "Observatory findings emit failed: $_" -ErrorAction Continue
    exit 1
}
