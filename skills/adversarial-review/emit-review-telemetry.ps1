#Requires -Version 7
<#
.SYNOPSIS
    Emits one adversarial-review outcome event to the AI Observatory.

.DESCRIPTION
    Emits one adversarial-review outcome event per panel participant after Phase 4
    verification completes. Captures review OUTCOMES (findings raised and accepted)
    rather than token economics -- those are captured per-call by wrapper
    sidecars where the underlying CLI exposes them.

    Called by the host agent (Claude Code or any other host) at the end of Phase 4
    in the adversarial-review skill procedure -- one call per participant: one per
    VENDOR represented in the reviewer set, plus one judge. Read the vendors off
    reviewers.json rather than from this comment; the roster is data and the
    ValidateSet below is the only list here that must track it.

    Silently no-ops when OBSERVATORY_API_KEY or OBSERVATORY_URL is absent.
    When both vars are set, HTTP failures surface via Write-Error and exit 1 --
    callers must check $LASTEXITCODE and report failures to the operator.

.PARAMETER RunId
    UTC timestamp slug that ties all five participant events for one run together,
    e.g. "20260614T143022Z". Use the workdir's own timestamp.

.PARAMETER Reviewer
    Vendor id of the reviewer: anthropic | google | openai | moonshot | xai | zai.

    THIS SET MUST TRACK reviewers.json, and nothing fails loudly when it does not.
    aggregate-and-emit.ps1 keys $byReviewer by vendor and passes the key straight
    through as -Reviewer; a vendor missing here fails parameter binding in the
    subprocess, and that caller only Write-Warnings on a non-zero exit, so the run
    completes and that vendor's raised/accepted telemetry is lost permanently and
    silently. Adding a seat of a new vendor to reviewers.json means adding it here
    in the same change.

.PARAMETER Role
    The participant's role in the panel: reviewer | judge. REQUIRED -- the API
    rejects (HTTP 400) any run without a valid role, so omitting it means the
    event is silently dropped. Emit every Phase-1 reviewer as 'reviewer' and the
    Phase-3 adjudicator as 'judge'.

    SAME-VENDOR SEATS MERGE INTO ONE ROW. The key is (runId, reviewer, role) --
    three fields, not two -- so two seats of one vendor both emit as that vendor
    plus 'reviewer' and the second upserts over the first. Emitting them as
    separate calls does not create two rows; merge their counts before emitting.
    The manifest currently seats ONE reviewer per vendor, so nothing merges today
    and the run produces one reviewer row per seat plus one judge row. The rule
    stays because the roster is data: a second same-vendor seat is one `enabled`
    flag away, and it was the live shape until seat B was retired.

    THE OTHER THREE PANEL ROLES ARE NOT EMITTED, and must not be squeezed into
    these two. The manifest also defines judgeAudit (Phase 3.5), verifier (Phase 4)
    and synthesis. Because `role` IS part of the key, the judge does not collide
    with a reviewer of the same vendor -- but a Phase-4 verifier emitted AS
    'reviewer' collides exactly: it upserts over that vendor's Phase-1 reviewer row
    and destroys the reviewing evidence it was meant to sit beside. The verifier
    pool is cross-vendor by design and overlaps the reviewer set, so that is the
    common case, not an edge one.

    UNVERIFIED: whether the API's role enum would accept 'verifier', 'judge-audit'
    or 'synthesis'; refuted if a POST carrying one of those returns 2xx. Until that
    is established the correct action for those phases is to emit NOTHING and leave
    their cost in the run's own artefacts. A missing row is a known gap; a row that
    silently replaced another is a wrong answer.

.PARAMETER Repo
    Repository name under review (basename of the repo root, e.g.
    my-service). Optional; groups runs by repo in the dashboard.

.PARAMETER Summary
    Operator-assigned run name shown as the dashboard card title. Optional —
    only set when the invocation gave a naming directive (e.g. "...name it
    'Verifying adjusted formatting'"). Same value on all five calls of a run.
    Capped at 80 chars server-side.

.PARAMETER Model
    Actual invoked model id when resolvable; otherwise the configured selector.

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

.PARAMETER ChunkCount
    Number of chunks aggregated into this participant row for a chunked/batched
    review (large diff split into cohesive chunks, each a full panel run, summed
    per participant). Omit (or 0) for a single-diff run — the field is then sent
    as null and the dashboard shows no aggregate badge. Same value on all five
    calls of a run. Normally set by aggregate-and-emit.ps1, not by hand.

.PARAMETER IssuesRaised
    Count of ### finding blocks in this reviewer's Phase 1 output.

.PARAMETER IssuesAccepted
    Count of this vendor's own Phase-1 findings that survive adjudication and
    verification. Derive provenance from the pooled finding map, never from
    consensus tags; accepted must not exceed this vendor's IssuesRaised.

.EXAMPLE
    pwsh -NoProfile -File emit-review-telemetry.ps1 -RunId 20260614T143022Z -Reviewer anthropic -Role reviewer -Model claude-sonnet-current -IssuesRaised 7 -IssuesAccepted 4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunId,

    [Parameter(Mandatory)]
    [ValidateSet('anthropic', 'google', 'openai', 'moonshot', 'xai', 'zai')]
    [string] $Reviewer,

    [Parameter(Mandatory)]
    [ValidateSet('reviewer', 'judge')]
    [string] $Role,

    [string] $Repo = $null,

    [string] $Summary = $null,

    [Parameter(Mandatory)]
    [string] $Model,

    [long]   $InputTokens      = 0,
    [long]   $OutputTokens     = 0,
    [double] $CostUsd          = 0,
    # "Cost could not be determined" is a different fact from "cost was measured as 0",
    # and a bare 0.0 renders identically to a genuinely free subscription-backed call.
    #
    # [switch], NOT [bool]. Callers invoke this through `pwsh -File`, where every argument
    # arrives as a string, and a [bool] parameter REFUSES a string outright: "Cannot
    # convert value System.String to type System.Boolean" - for "False", "True", "1" and
    # "0" alike (verified 2026-08-08). A [bool] here would have hard-failed every emit
    # call the moment a caller passed the flag.
    [switch] $CostUnknown,
    [long]   $ReviewDurationMs = 0,

    # 0 = single-diff run (sent as null); a positive count flags an aggregated
    # batch run. Negative is rejected here rather than silently coerced to null.
    [ValidateRange(0, [int]::MaxValue)]
    [int]    $ChunkCount       = 0,

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
    costUnknown      = [bool]$CostUnknown
    reviewDurationMs = $ReviewDurationMs
    issuesRaised     = $IssuesRaised
    issuesAccepted   = $IssuesAccepted
    runId            = $RunId
    role             = $Role
    repo             = $Repo
    summary          = $Summary
    # null for a single-diff run; a positive count flags an aggregated batch run.
    chunkCount       = ($ChunkCount -gt 0 ? $ChunkCount : $null)
} | ConvertTo-Json -Compress

try {
    # Adversarial-review OUTCOME events go to the dedicated runs endpoint, NOT
    # /api/events. /api/events parses a UsageEventRequest (provider/model/tokens);
    # this payload (eventType/reviewer/issuesRaised/...) has no provider, so it
    # 400s there and the catch swallows it -- which is why the dashboard's
    # adversarial-review section stayed empty. The body already matches
    # AdversarialReviewRunRequest exactly.
    Invoke-RestMethod `
        -Uri "$($env:OBSERVATORY_URL)/api/adversarial-review/runs" `
        -Method Post `
        -ContentType 'application/json' `
        -Headers @{ 'X-Observatory-Key' = $env:OBSERVATORY_API_KEY } `
        -Body $body `
        -TimeoutSec 5 `
        -ErrorAction Stop | Out-Null
} catch {
    Write-Error "Observatory emit failed [$Reviewer/$Role]: $_"
    exit 1
}
