#Requires -Version 7
<#
.SYNOPSIS
    Aggregate a chunked/batched adversarial review into ONE per-participant
    outcome and emit it to the AI Observatory.

.DESCRIPTION
    A large diff is reviewed as N cohesive chunks, each a full panel run (see the
    skill, §0a / §5). Each chunk's run-review.ps1 leaves a `metrics.json` holding
    the three reviewers' deterministic outcome (issuesRaised + cost + duration).
    Adjudication/synthesis is host judgment; its products — issuesAccepted per
    reviewer and the synthesis (judge) participant's cost — are recorded in an
    `aggregate-verdict.json` the host writes at §5 synthesis time.

    This script sums every chunk's `metrics.json` per participant, folds in the
    verdict, and calls emit-review-telemetry.ps1 ONCE per participant with the run
    totals and `-ChunkCount N`. The result is a single dashboard run whose four
    rows carry real summed numbers instead of placeholder zeros.

    Idempotent: re-running overwrites the same run's rows in place (the API upserts
    on (runId, reviewer, role)), so a run can be re-aggregated after more chunks
    complete or after the verdict is filled in.

    Silently no-ops emitting when OBSERVATORY_API_KEY / OBSERVATORY_URL are absent
    (emit-review-telemetry.ps1 handles that) but still prints the aggregate table.

.PARAMETER RunRoot
    The run's top working directory — the parent holding the per-chunk
    subdirectories (each with a metrics.json). Defaults to the current directory.

.PARAMETER RunId
    Shared run id for all participants (the run-root's UTC stamp). Defaults to the
    leaf name of RunRoot.

.PARAMETER Repo
    Repository name (basename of the repo root). Same value on every row.

.PARAMETER Summary
    Optional operator-assigned run name → dashboard card title.

.PARAMETER VerdictPath
    Path to aggregate-verdict.json. Defaults to <RunRoot>/aggregate-verdict.json.
    Shape:
      {
        "accepted": { "anthropic": 6, "google": 3, "openai": 4 },
        "judge": { "reviewer": "anthropic", "model": "claude-opus-4-8",
                   "inputTokens": 90000, "outputTokens": 0,
                   "costUsd": 2.7, "reviewDurationMs": 140000 }
      }
    Both keys optional. Missing `accepted` → zeros (warned). Missing `judge` → no
    judge row emitted (the run shows as "no judge").

.EXAMPLE
    pwsh -NoProfile -File aggregate-and-emit.ps1 -RunRoot <runRoot> -Repo your-repo -Summary 'Whole-repo audit'
#>
[CmdletBinding()]
param(
    [string] $RunRoot = '.',
    [string] $RunId,
    [string] $Repo,
    [string] $Summary,
    [string] $VerdictPath
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$emit = Join-Path $scriptDir 'emit-review-telemetry.ps1'
if (-not (Test-Path -LiteralPath $emit)) { Write-Error "emit-review-telemetry.ps1 not found beside this script."; exit 2 }

$RunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
if (-not $RunId)       { $RunId = Split-Path -Leaf $RunRoot }
if (-not $VerdictPath) { $VerdictPath = Join-Path $RunRoot 'aggregate-verdict.json' }

# --- Collect per-chunk metrics ------------------------------------------
$metricFiles = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Filter 'metrics.json' -File -ErrorAction SilentlyContinue)
if (-not $metricFiles) {
    Write-Error "No metrics.json found under $RunRoot. Each chunk's run-review.ps1 writes one; nothing to aggregate."
    exit 3
}

# Chunk count = ALL chunks in the batch, including any that failed and left no
# metrics.json. batch-review.ps1 records every chunk in batch-summary.json, so
# prefer it as the source of truth; fall back to the metrics.json count only for
# an ad-hoc batch run that did not go through batch-review.ps1.
$batchSummary = Join-Path $RunRoot 'batch-summary.json'
if (Test-Path -LiteralPath $batchSummary) {
    $chunkCount = @(Get-Content -LiteralPath $batchSummary -Raw | ConvertFrom-Json).Count
    if ($chunkCount -gt $metricFiles.Count) {
        Write-Warning "$($chunkCount - $metricFiles.Count) chunk(s) left no metrics.json — counted in ChunkCount but contributing no metrics."
    }
} else {
    $chunkCount = $metricFiles.Count
}

# Sum per reviewer vendor across chunks.
$byReviewer = @{}
foreach ($mf in $metricFiles) {
    $m = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json
    foreach ($p in @($m.participants)) {
        $key = $p.reviewer
        if (-not $byReviewer.ContainsKey($key)) {
            $byReviewer[$key] = [ordered]@{
                reviewer = $key; model = $p.model
                inputTokens = 0L; outputTokens = 0L; costUsd = 0.0
                reviewDurationMs = 0L; issuesRaised = 0; estimated = $false
            }
        }
        $acc = $byReviewer[$key]
        if (-not $acc.model -and $p.model) { $acc.model = $p.model }
        $acc.inputTokens      += [long]($p.inputTokens      ?? 0)
        $acc.outputTokens     += [long]($p.outputTokens     ?? 0)
        $acc.costUsd          += [double]($p.costUsd         ?? 0)
        $acc.reviewDurationMs += [long]($p.reviewDurationMs ?? 0)
        $acc.issuesRaised     += [int]($p.issuesRaised       ?? 0)
        if ($p.costEstimated)  { $acc.estimated = $true }
    }
}

# --- Verdict (accepted per reviewer + judge participant) ----------------
$accepted = @{}
$judge = $null
if (Test-Path -LiteralPath $VerdictPath) {
    $v = Get-Content -LiteralPath $VerdictPath -Raw | ConvertFrom-Json
    if ($v.accepted) {
        foreach ($prop in $v.accepted.PSObject.Properties) { $accepted[$prop.Name] = [int]$prop.Value }
    }
    if ($v.judge) { $judge = $v.judge }
} else {
    Write-Warning "No aggregate-verdict.json at $VerdictPath — issuesAccepted will be 0 and no judge row will be emitted. Write it at synthesis time (see the skill, §5)."
}

# --- Emit one participant at a time --------------------------------------
function Invoke-Emit([hashtable] $named) {
    $argList = @('-NoProfile', '-File', $emit)
    foreach ($k in $named.Keys) { $argList += @("-$k", "$($named[$k])") }
    & pwsh @argList
    if ($LASTEXITCODE -ne 0) { Write-Warning "emit failed for $($named.Reviewer)/$($named.Role) (exit $LASTEXITCODE)" }
}

$rows = @()
foreach ($key in $byReviewer.Keys) {
    $r = $byReviewer[$key]
    $acc = if ($accepted.ContainsKey($key)) { $accepted[$key] } else { 0 }
    # The API enforces accepted <= raised; clamp defensively so a verdict
    # attribution quirk cannot 400 the whole emit.
    if ($acc -gt $r.issuesRaised) {
        Write-Warning "accepted ($acc) > raised ($($r.issuesRaised)) for $key — clamping to raised."
        $acc = $r.issuesRaised
    }
    $named = @{
        RunId = $RunId; Reviewer = $key; Role = 'reviewer'; Model = $r.model
        InputTokens = $r.inputTokens; OutputTokens = $r.outputTokens
        CostUsd = [Math]::Round($r.costUsd, 6); ReviewDurationMs = $r.reviewDurationMs
        IssuesRaised = $r.issuesRaised; IssuesAccepted = $acc; ChunkCount = $chunkCount
    }
    if ($Repo)    { $named.Repo = $Repo }
    if ($Summary) { $named.Summary = $Summary }
    Invoke-Emit $named
    $rows += [pscustomobject]@{ Participant = "$key (reviewer)"; Model = $r.model; Raised = $r.issuesRaised; Accepted = $acc; Cost = [Math]::Round($r.costUsd,4); DurationMs = $r.reviewDurationMs; CostEst = $r.estimated }
}

if ($judge) {
    $named = @{
        RunId = $RunId; Reviewer = $judge.reviewer; Role = 'judge'; Model = $judge.model
        InputTokens = [long]($judge.inputTokens ?? 0); OutputTokens = [long]($judge.outputTokens ?? 0)
        CostUsd = [Math]::Round([double]($judge.costUsd ?? 0), 6); ReviewDurationMs = [long]($judge.reviewDurationMs ?? 0)
        IssuesRaised = 0; IssuesAccepted = 0; ChunkCount = $chunkCount
    }
    if ($Repo)    { $named.Repo = $Repo }
    if ($Summary) { $named.Summary = $Summary }
    Invoke-Emit $named
    $rows += [pscustomobject]@{ Participant = "$($judge.reviewer) (judge)"; Model = $judge.model; Raised = 0; Accepted = 0; Cost = [Math]::Round([double]($judge.costUsd ?? 0),4); DurationMs = [long]($judge.reviewDurationMs ?? 0); CostEst = $false }
}

Write-Host ""
Write-Host "==== aggregate-and-emit: $RunId ($chunkCount chunks) ===="
$rows | Format-Table -AutoSize | Out-String | Write-Host
if (-not $judge) { Write-Warning "No judge row — run shows as 'no judge' until aggregate-verdict.json carries a judge." }
