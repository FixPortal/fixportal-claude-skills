#Requires -Version 7
<#
.SYNOPSIS
    Emits one adversarial-review outcome event to the AI Observatory.

.DESCRIPTION
    Fire-and-forget helper called once per reviewer after Phase 4 verification
    completes. Captures review OUTCOMES (findings raised and accepted) rather
    than token economics -- those are already emitted per-call by the individual
    reviewer wrappers (gemini-review.ps1, openai-review.ps1).

    Called by the host agent (Claude Code or any other host) at the end of
    Phase 4 in the adversarial-review skill procedure -- three calls in parallel,
    one per reviewer. Silently no-ops when OBSERVATORY_API_KEY or OBSERVATORY_URL
    is absent.

.PARAMETER RunId
    UTC timestamp slug that ties all three reviewer events for one run together,
    e.g. "20260614T143022Z". Use the workdir's own timestamp.

.PARAMETER Reviewer
    Vendor id of the reviewer: anthropic | google | openai.

.PARAMETER Model
    Model id as it appears in reviewers.json (e.g. claude-sonnet-4-6, gpt-5.4).

.PARAMETER InputTokens
    Input tokens used by this reviewer's Phase 1 call. Pass 0 when unknown --
    the reviewer wrappers emit per-call token telemetry separately and those
    events are not duplicated here.

.PARAMETER OutputTokens
    Output tokens from this reviewer's Phase 1 call. Pass 0 when unknown.

.PARAMETER CostUsd
    USD cost of this reviewer's Phase 1 call. Pass 0 when unknown.

.PARAMETER ReviewDurationMs
    Wall-clock duration of the Phase 1 call in milliseconds. Pass 0 when not
    measured (the Claude Code Agent path does not expose call duration).

.PARAMETER IssuesRaised
    Count of ### finding blocks in this reviewer's Phase 1 output.

.PARAMETER IssuesAccepted
    Count of surviving (non-REFUTED) findings in the published report attributed
    to this reviewer via consensus tags: [unanimous] = credit all three;
    [majority] = credit all except the named dissenter; [contested] findings
    that survived Phase 4 as CONFIRMED or INDETERMINATE = credit all three.

.EXAMPLE
    pwsh -NoProfile -File emit-review-telemetry.ps1 `
        -RunId 20260614T143022Z -Reviewer anthropic -Model claude-sonnet-4-6 `
        -IssuesRaised 7 -IssuesAccepted 4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunId,

    [Parameter(Mandatory)]
    [ValidateSet('anthropic', 'google', 'openai')]
    [string] $Reviewer,

    [Parameter(Mandatory)]
    [string] $Model,

    [long]   $InputTokens      = 0,
    [long]   $OutputTokens     = 0,
    [double] $CostUsd          = 0,
    [long]   $ReviewDurationMs = 0,

    [Parameter(Mandatory)]
    [int] $IssuesRaised,

    [Parameter(Mandatory)]
    [int] $IssuesAccepted
)

if (-not ($env:OBSERVATORY_API_KEY -and $env:OBSERVATORY_URL)) { exit 0 }

$body = @{
    eventType        = 'adversarial-review-run'
    reviewer         = $Reviewer
    model            = $Model
    inputTokens      = $InputTokens
    outputTokens     = $OutputTokens
    costUsd          = $CostUsd
    reviewDurationMs = $ReviewDurationMs
    issuesRaised     = $IssuesRaised
    issuesAccepted   = $IssuesAccepted
    runId            = $RunId
} | ConvertTo-Json -Compress

try {
    Invoke-RestMethod `
        -Uri "$($env:OBSERVATORY_URL)/api/events" `
        -Method Post `
        -ContentType 'application/json' `
        -Headers @{ 'X-Observatory-Key' = $env:OBSERVATORY_API_KEY } `
        -Body $body `
        -TimeoutSec 5 `
        -ErrorAction SilentlyContinue | Out-Null
} catch { }
