#Requires -Version 7
<#
.SYNOPSIS
    Aggregate a chunked/batched adversarial review into ONE per-participant
    outcome and emit it to the AI Observatory.

.DESCRIPTION
    A large diff is reviewed as N cohesive chunks, each a full panel run (see the
    skill, §0a / §5). Each chunk's run-review.ps1 leaves a `metrics.json` holding
    each reviewer's deterministic outcome (issuesRaised + cost + duration), one
    participant entry per manifest reviewer — summed per vendor here, so the two
    Anthropic reviewers (Fable + Sonnet) collapse into one anthropic row.
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
        "judge": { "reviewer": "anthropic", "model": "resolved-model-id",
                   "inputTokens": 90000, "outputTokens": 0,
                   "costUsd": 2.7, "reviewDurationMs": 140000 }
      }
    Both keys optional. Missing `accepted` → zeros (warned). Missing `judge` → no
    judge row emitted (the run shows as "no judge"). Judge `costUsd` is honoured
    only for an exact model id the registry cannot price; registry pricing wins
    whenever it resolves, and a moving alias nothing resolved stays UNKNOWN. The
    model registry is optional: without it every cost the wrappers did not measure
    is UNKNOWN, never a fabricated price.

.EXAMPLE
    pwsh -NoProfile -File aggregate-and-emit.ps1 -RunRoot <runRoot> -Repo example-app -Summary 'Example final audit'
#>
[CmdletBinding()]
param(
    [string] $RunRoot = '.',
    [string] $RunId,
    [string] $Repo,
    [string] $Summary,
    [string] $VerdictPath,
    [switch] $AllowFailedChunks
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$emit = Join-Path $scriptDir 'emit-review-telemetry.ps1'
$modelRegistryPath = Join-Path (Split-Path $scriptDir -Parent) 'model-registry' 'registry.json'
$modelPriceHelper = Join-Path (Split-Path $modelRegistryPath -Parent) 'price.ps1'
$modelPriceAvailable = Test-Path -LiteralPath $modelPriceHelper
if ($modelPriceAvailable) { . $modelPriceHelper }
$modelPriceOn = $env:MODEL_REGISTRY_EFFECTIVE_DATE ?? (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
# Mirrors run-review.ps1: a missing or corrupt registry must say so. A bare catch made
# the two indistinguishable and left cost recomputation silently unavailable.
$modelRegistry = if (Test-Path -LiteralPath $modelRegistryPath) {
    try { Get-Content -LiteralPath $modelRegistryPath -Raw | ConvertFrom-Json -AsHashtable }
    catch {
        Write-Warning "Model registry at $modelRegistryPath is unreadable ($($_.Exception.Message)); judge/reviewer cost recomputation is unavailable and cost will be recorded as UNKNOWN."
        $null
    }
} else {
    Write-Warning "Model registry not found at $modelRegistryPath; judge/reviewer cost recomputation is unavailable and cost will be recorded as UNKNOWN."
    $null
}

function Resolve-ModelSelector([string] $vendor, [string] $selector) {
    if ($vendor -ne 'anthropic' -or $selector -notin @('opus', 'sonnet', 'haiku', 'fable') -or -not $modelRegistry) {
        return $selector
    }
    $prefix = "claude-$selector-"
    $match = $modelRegistry.models.GetEnumerator() |
        Where-Object { $_.Key.StartsWith($prefix) -and $_.Value.availability.cli -eq 'available' -and -not $_.Value.retired } |
        Sort-Object { [int]($_.Value.rank ?? [int]::MaxValue) }, Key |
        Select-Object -First 1
    return ($match ? [string]$match.Key : $selector)
}

function Get-RegistryCost([string] $model, [long] $inputTokens, [long] $outputTokens) {
    if (-not $modelPriceAvailable -or -not $modelRegistry -or -not $modelRegistry.models.ContainsKey($model)) { return $null }
    $facts = $modelRegistry.models[$model]
    # Get-ModelRegistryCost THROWS on overlapping api pricing records, and this script runs
    # under $ErrorActionPreference = 'Stop' with no guard -- so a registry data error took
    # down the whole aggregation after the review had been produced and paid for. A bad
    # record degrades to UNKNOWN, which is what $null means here.
    try {
        return Get-ModelRegistryCost -Facts $facts -InputTokens $inputTokens -OutputTokens $outputTokens -Channel api -On $modelPriceOn
    }
    catch {
        Write-Warning "Registry pricing for '$model' is unusable ($($_.Exception.Message)); recording cost as UNKNOWN."
        return $null
    }
}
# -ErrorAction Continue on every fatal Write-Error below: $ErrorActionPreference is
# 'Stop', under which Write-Error throws a terminating ActionPreferenceStopException
# and the `exit <n>` after it never runs — so each distinct exit code was dead and
# every failure surfaced as a bare exit 1. Print, then exit with the real code.
if (-not (Test-Path -LiteralPath $emit)) { Write-Error "emit-review-telemetry.ps1 not found beside this script." -ErrorAction Continue; exit 2 }

$RunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
if (-not $RunId)       { $RunId = Split-Path -Leaf $RunRoot }
if (-not $VerdictPath) { $VerdictPath = Join-Path $RunRoot 'aggregate-verdict.json' }

# --- Collect per-chunk metrics ------------------------------------------
# batch-summary.json (written by batch-review.ps1) is the source of truth for
# BOTH which chunks belong to this run and how many there were. Use it to pick
# the exact chunk dirs to aggregate — a blind recursive scan of RunRoot would
# also pull in stale metrics.json left over from a reused run root and inflate
# the totals while ChunkCount came from the newer summary. Fall back to the
# recursive scan only for an ad-hoc batch that did not go through batch-review.ps1.
$batchSummary = Join-Path $RunRoot 'batch-summary.json'
$failedChunkIds = @()
if (Test-Path -LiteralPath $batchSummary) {
    $summaryRows = @(Get-Content -LiteralPath $batchSummary -Raw | ConvertFrom-Json)

    # A run IS its set of distinct chunk ids. Resolve each chunk's metrics.json from
    # <RunRoot>/<chunkId> rather than from the row's persisted workDir: batch-review.ps1
    # does not resolve -RunRoot, so a relative one persists relative workDirs that
    # Test-Path silently misses when aggregation runs from a different directory, and
    # a temp path can be recorded in 8.3 short form. RunRoot is resolved above and a
    # chunkId is a slug (re-validated just below) naming a direct child, so this is
    # exact and path-form independent — while staying bounded by the summary, so a stale chunk
    # dir it does not name is still excluded (that inflation is why the summary is
    # authoritative rather than a blind scan). workDir stays informational only.
    # Keying by id also collapses a duplicate row, which would otherwise double-count
    # both ChunkCount and that chunk's metrics.
    #
    # Match the id comparison to the FILESYSTEM's case rule, not a fixed one. A chunk
    # id both names a summary row and (via Join-Path) a directory on disk, so the two
    # must agree on whether 'c01' and 'C01' are the same chunk exactly when the
    # filesystem does. A fixed OrdinalIgnoreCase is right on Windows/macOS but wrong
    # on a case-sensitive filesystem: it would resolve 'c01' to a 'C01' dir that
    # isn't really there (missing its metrics) while the orphan scan below, keyed by
    # the same set, treats the on-disk 'C01' as named -- so a short run emits instead
    # of being refused.
    #
    # Probe with a FRESH uniquely-named marker, not a case-flip of an existing file:
    # a fixed 'BATCH-SUMMARY.JSON' probe would read as case-insensitive if a distinct
    # all-caps file happened to exist beside the lowercase summary on a case-sensitive
    # volume. A guid name can't pre-exist, and the letter prefix guarantees its upper-
    # and lower-cased forms differ. If the probe can't be written, FAIL CLOSED rather
    # than guess from the OS: macOS can run a case-sensitive volume, so an OS guess of
    # case-insensitive there would collapse c01/C01, suppress the orphan guard, and
    # emit short totals -- exactly the bug this exists to stop. A wrong guess on a
    # correctness-critical comparison is worse than refusing; the operator makes
    # RunRoot writable (it is a live run's working dir) and re-runs.
    $probeName = "caseprobe-$([guid]::NewGuid().ToString('N'))"
    $probePath = Join-Path $RunRoot $probeName
    $fsCaseInsensitive = $null
    try {
        Set-Content -LiteralPath $probePath -Value '' -NoNewline -ErrorAction Stop
        $fsCaseInsensitive = Test-Path -LiteralPath (Join-Path $RunRoot $probeName.ToUpperInvariant())
    } catch {
        Write-Error "Could not determine the filesystem's case rule under $RunRoot ($($_.Exception.Message)). Aggregation compares chunk ids against on-disk directories, and guessing the case rule could collapse c01/C01 and emit short totals. Make RunRoot writable and re-run." -ErrorAction Continue
        exit 6
    } finally {
        if (Test-Path -LiteralPath $probePath) { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue }
    }
    $idComparer = if ($fsCaseInsensitive) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $summaryIds = [System.Collections.Generic.HashSet[string]]::new($idComparer)

    # A row with no chunkId can't be counted or resolved, so SKIPPING it (the old
    # behaviour) silently drops a chunk from ChunkCount with no orphan evidence — a
    # failed chunk left no metrics dir either, so nothing downstream can catch it.
    # Count such rows and reject the whole summary rather than quietly omit them.
    $rowsMissingId = @($summaryRows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.chunkId) }).Count
    foreach ($row in $summaryRows) {
        if (-not [string]::IsNullOrWhiteSpace([string]$row.chunkId)) { [void]$summaryIds.Add([string]$row.chunkId) }
    }

    # Re-validate every id against batch-review.ps1's slug rule before joining it into
    # a path. batch-review.ps1 validates ids it writes, but the skill's repair flow
    # tells operators to REBUILD batch-summary.json by hand, so this file is not a
    # trusted source: a hand-written or corrupted id like '..\other' joins straight
    # into <RunRoot>\..\other\metrics.json, escaping RunRoot to aggregate an unrelated
    # file — and the orphan scan below misses it, because the resolved dir is not a
    # child of RunRoot at all. Same rule as batch-review.ps1 (slug chars, not all
    # dots, no trailing '.'/space -- Windows strips those, collapsing 'C01.' onto 'C01').
    $badIds = @($summaryIds | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+$' -or $_ -match '^\.+$' -or $_ -match '[. ]$' })
    if ($rowsMissingId -gt 0 -or $badIds) {
        $parts = @()
        if ($rowsMissingId -gt 0) { $parts += "$rowsMissingId row(s) with no chunkId" }
        if ($badIds)             { $parts += "invalid chunk id(s): $($badIds -join ', ')" }
        Write-Error "batch-summary.json is malformed ($($parts -join '; ')). Every row must carry a chunkId matching [A-Za-z0-9._-] and not all dots (it names a direct child of RunRoot). Refusing to aggregate — rebuild the summary with valid ids." -ErrorAction Continue
        exit 5
    }

    $chunkCount  = $summaryIds.Count
    $failedChunkIds = @($summaryRows | Where-Object {
        $_.exitCode -ne 0 -or $_.hasMetrics -eq $false -or
        -not (Test-Path -LiteralPath (Join-Path (Join-Path $RunRoot ([string]$_.chunkId)) 'metrics.json'))
    } | ForEach-Object { [string]$_.chunkId })
    $metricFiles = @($summaryIds |
        ForEach-Object { Join-Path (Join-Path $RunRoot $_) 'metrics.json' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Get-Item -LiteralPath $_ })
    if ($chunkCount -gt $metricFiles.Count) {
        Write-Warning "$($chunkCount - $metricFiles.Count) chunk(s) left no metrics.json — counted in ChunkCount but contributing no metrics."
    }

    # A row that DECLARES failure (exitCode != 0 or hasMetrics = false) must have no
    # metrics.json on disk -- metrics are selected purely by chunkId, so a stale file
    # in a failed chunk's dir would otherwise be summed anyway, inflating the totals,
    # and the orphan scan would wave it through because the id IS named. Current runs
    # can't produce this (batch-review clears a chunk's metrics before a retry), but a
    # legacy or hand-repaired RunRoot can. The summary contradicting the disk is not
    # something to silently resolve in the inflating direction: refuse.
    $contradictions = @($summaryRows | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.chunkId) -and
        (($_.hasMetrics -eq $false) -or ($null -ne $_.exitCode -and [int]$_.exitCode -ne 0)) -and
        (Test-Path -LiteralPath (Join-Path (Join-Path $RunRoot ([string]$_.chunkId)) 'metrics.json'))
    })
    if ($contradictions) {
        $names = ($contradictions | ForEach-Object { $_.chunkId }) -join ', '
        Write-Error "batch-summary.json marks these chunk(s) as failed (exitCode != 0 or hasMetrics = false) yet a metrics.json exists in their dir: $names. Counting it would inflate the totals; the summary and the filesystem disagree. Refusing to aggregate — remove the stale metrics.json or correct the row before re-running." -ErrorAction Continue
        exit 7
    }

    # A metrics.json under RunRoot the summary does NOT name means the summary is not
    # describing this run — it was overwritten by a partial re-run (batch-review.ps1
    # now unions, but run roots predating that fix still exist), or a chunk dir was
    # hand-made or backed up inside the RunRoot. Emitting anyway is the failure this
    # guard exists to stop: totals come out short and every `accepted` is clamped down
    # to match, so a broken run reads as a smaller but plausible one. The clamp
    # warnings below do fire, but they describe the consequence, not the cause.
    # Refuse — a confident wrong number is worse than no number. Requiring a direct
    # child AND a known id also catches a chunk dir backed up inside the RunRoot under
    # the id it copied.
    $orphans = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Filter 'metrics.json' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $chunkDir = Split-Path -Parent $_.FullName
            (Split-Path -Parent $chunkDir) -ne $RunRoot -or
            -not $summaryIds.Contains((Split-Path -Leaf $chunkDir))
        })
    if ($orphans) {
        $orphanDirs = ($orphans | ForEach-Object { '  ' + (Split-Path -Parent $_.FullName) }) -join [Environment]::NewLine
        Write-Error @"
batch-summary.json names $chunkCount chunk(s), but $($orphans.Count) further metrics.json exist under this RunRoot that it does not name:
$orphanDirs
The summary is not describing this run, so ChunkCount and every per-vendor total would be short and every accepted count silently clamped to match. Refusing to emit. Fix by ONE of:
  - re-run batch-review.ps1 for the missing chunks into this RunRoot (it unions the summary); or
  - rebuild batch-summary.json from the chunk dirs; or
  - delete batch-summary.json to aggregate every chunk dir under RunRoot instead
    (WARNING: the scan finds only chunks that left a metrics.json, so any FAILED
    chunk is silently dropped -- only do this when every chunk succeeded).
"@ -ErrorAction Continue
        exit 4
    }
    if ($failedChunkIds.Count -gt 0 -and -not $AllowFailedChunks) {
        Write-Error "Chunks failed or lack metrics: $($failedChunkIds -join ', '). Refusing partial totals. Re-run them or explicitly pass -AllowFailedChunks to emit with unknown costs." -ErrorAction Continue
        exit 8
    }
    if ($failedChunkIds.Count -gt 0) {
        Write-Warning "Emitting partial batch with failed chunk(s): $($failedChunkIds -join ', '); every participant cost is UNKNOWN."
    }
} else {
    $metricFiles = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Filter 'metrics.json' -File -ErrorAction SilentlyContinue)
    $chunkCount  = $metricFiles.Count
}
if (-not $metricFiles) {
    Write-Error "No metrics.json found for $RunRoot. Each chunk's run-review.ps1 writes one; nothing to aggregate." -ErrorAction Continue
    exit 3
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
                costUnknown = $false; failedPhases = 0
            }
        }
        $acc = $byReviewer[$key]
        # Two seats can share a vendor key while running DIFFERENT models; keeping the
        # first silently misattributes the summed figures, so the row names every id it sums.
        if (-not $acc.model -and $p.model) { $acc.model = $p.model }
        elseif ($p.model -and $acc.model -cne $p.model) {
            $acc.model = (@($acc.model -split '\+') + $p.model | Sort-Object -Unique) -join '+'
        }
        $acc.inputTokens      += [long]($p.inputTokens      ?? 0)
        $acc.outputTokens     += [long]($p.outputTokens     ?? 0)
        $acc.costUsd          += [double]($p.costUsd         ?? 0)
        $acc.reviewDurationMs += [long]($p.reviewDurationMs ?? 0)
        $acc.issuesRaised     += [int]($p.issuesRaised       ?? 0)
        $acc.failedPhases     += [int]($p.failedPhases       ?? 0)
        if ($p.costEstimated)  { $acc.estimated = $true }
        # Unknown is contagious across a summed row: if any chunk's cost could not be
        # determined, the total is a floor, not a figure.
        if ($p.costUnknown -or $failedChunkIds.Count -gt 0) { $acc.costUnknown = $true }
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
    foreach ($k in $named.Keys) {
        $v = $named[$k]
        # Booleans map to SWITCH parameters and must be rendered as a bare flag, present
        # only when true. Under `pwsh -File` every argument is a string, and a stringified
        # bool cannot bind to either [bool] ("Cannot convert System.String to
        # System.Boolean") or [switch] - so "-Flag False" would fail the whole call, and
        # would mean the opposite of what it says even if it bound.
        if ($v -is [bool]) { if ($v) { $argList += "-$k" }; continue }
        $argList += @("-$k", "$v")
    }
    & pwsh @argList
    if ($LASTEXITCODE -ne 0) { Write-Warning "emit failed for $($named.Reviewer)/$($named.Role) (exit $LASTEXITCODE)" }
}

$rows = @()
foreach ($key in $byReviewer.Keys) {
    $r = $byReviewer[$key]
    $acc = if ($accepted.ContainsKey($key)) { $accepted[$key] } else { 0 }
    # The API enforces 0 <= accepted <= raised; clamp defensively at BOTH ends so a
    # verdict-attribution quirk or a malformed/hand-edited accepted map cannot emit a
    # nonsensical count (negative → a 400, or a bogus dashboard number).
    if ($acc -lt 0) {
        Write-Warning "accepted ($acc) < 0 for $key — clamping to 0."
        $acc = 0
    }
    if ($acc -gt $r.issuesRaised) {
        Write-Warning "accepted ($acc) > raised ($($r.issuesRaised)) for $key — clamping to raised."
        $acc = $r.issuesRaised
    }
    $named = @{
        RunId = $RunId; Reviewer = $key; Role = 'reviewer'; Model = $r.model
        InputTokens = $r.inputTokens; OutputTokens = $r.outputTokens
        CostUsd = [Math]::Round($r.costUsd, 6); CostUnknown = [bool]$r.costUnknown
        ReviewDurationMs = $r.reviewDurationMs
        IssuesRaised = $r.issuesRaised; IssuesAccepted = $acc; ChunkCount = $chunkCount
    }
    if ($Repo)    { $named.Repo = $Repo }
    if ($Summary) { $named.Summary = $Summary }
    Invoke-Emit $named
    $displayCost = $r.costUnknown ? 'UNKNOWN' : [string]([Math]::Round($r.costUsd,4))
    $rows += [pscustomobject]@{ Participant = "$key (reviewer)"; Model = $r.model; Raised = $r.issuesRaised; Accepted = $acc; FailedPhases = $r.failedPhases; Cost = $displayCost; DurationMs = $r.reviewDurationMs; CostEst = $r.estimated }
}

if ($judge) {
    $judgeInput = [long]($judge.inputTokens ?? 0)
    $judgeOutput = [long]($judge.outputTokens ?? 0)
    $judgeModel = Resolve-ModelSelector ([string]$judge.reviewer) ([string]$judge.model)
    $judgeCost = [double]($judge.costUsd ?? 0)
    $judgeCostEstimated = $false
    # Incoming unknown is contagious; an absent registry price must not turn the
    # transport zero into "free".
    $judgeCostUnknown = [bool]($judge.costUnknown ?? $false)
    if ($failedChunkIds.Count -gt 0) { $judgeCostUnknown = $true }
    # Still a bare CLI alias after Resolve-ModelSelector means nothing resolved it (no
    # registry, or no match). A caller-side cost for a MOVING alias was priced against
    # whatever it pointed at then, so it is untrusted; an EXACT id's cost is attributable.
    $judgeAliasUnresolved = $judgeModel -in @('opus', 'sonnet', 'haiku', 'fable')
    # Recompute ONLY when there are tokens to price. Both counts default to 0 and the
    # lookup was unconditional, so for a priced model it returned 0.0 -- not $null -- the
    # UNKNOWN branch never ran, and the transported costUsd was discarded in favour of a
    # confident zero. That is exactly the UNKNOWN-versus-0.0 conflation the rest of this
    # emitter exists to prevent. SKILL.md does not document the judge row's token fields,
    # so an absent count is the expected shape, not an exotic one.
    if ($judgeInput -gt 0 -or $judgeOutput -gt 0) {
        $resolvedCost = Get-RegistryCost $judgeModel $judgeInput $judgeOutput
        if ($null -ne $resolvedCost) {
            # Registry pricing owns exact ids and resolved aliases alike, and a fresh
            # price CLEARS a verdict-seeded unknown -- only a failed chunk keeps it.
            $judgeCost = [double]$resolvedCost
            $judgeCostEstimated = $true
            $judgeCostUnknown = $failedChunkIds.Count -gt 0
        }
        elseif (-not $judgeAliasUnresolved -and $null -ne $judge.costUsd -and [double]$judge.costUsd -gt 0) {
            # An exact id the registry cannot price (or no registry at all): the verdict
            # documents costUsd as an input, so honour it rather than discard a real figure.
            $judgeCost = [double]$judge.costUsd
        }
        else {
            Write-Warning "Judge model '$judgeModel' is absent or unpriced in $modelRegistryPath; recording cost as UNKNOWN, not zero."
            $judgeCost = 0.0
            $judgeCostUnknown = $true
        }
    }
    elseif ($judgeAliasUnresolved -and $null -ne $judge.costUsd -and [double]$judge.costUsd -gt 0) {
        Write-Warning "Judge model '$judgeModel' is an unresolved moving alias; its transported costUsd is untrusted, recording cost as UNKNOWN."
        $judgeCost = 0.0
        $judgeCostUnknown = $true
    }
    elseif (-not $judgeCostUnknown -and $null -eq $judge.costUsd) {
        # ABSENT costUsd, not a zero VALUE. Testing `$judgeCost -eq 0` also caught an
        # explicit `costUsd: 0.0` with `costUnknown: false` - a transported known zero,
        # which a subscription-backed judge legitimately produces - and rewrote it as
        # unknown. That is the same UNKNOWN-versus-0.0 conflation this emitter exists to
        # prevent, running in the other direction. (CodeRabbit, PR #135.)
        #
        # No tokens and no transported cost is still not evidence that the judge was free.
        Write-Warning 'aggregate-verdict.json carries no judge token counts and no costUsd; recording judge cost as UNKNOWN, not zero.'
        $judgeCostUnknown = $true
    }
    $named = @{
        RunId = $RunId; Reviewer = $judge.reviewer; Role = 'judge'; Model = $judgeModel
        InputTokens = $judgeInput; OutputTokens = $judgeOutput
        CostUsd = [Math]::Round($judgeCost, 6); CostUnknown = $judgeCostUnknown
        ReviewDurationMs = [long]($judge.reviewDurationMs ?? 0)
        IssuesRaised = 0; IssuesAccepted = 0; ChunkCount = $chunkCount
    }
    if ($Repo)    { $named.Repo = $Repo }
    if ($Summary) { $named.Summary = $Summary }
    Invoke-Emit $named
    $displayCost = $judgeCostUnknown ? 'UNKNOWN' : [string]([Math]::Round($judgeCost,4))
    $rows += [pscustomobject]@{ Participant = "$($judge.reviewer) (judge)"; Model = $judgeModel; Raised = 0; Accepted = 0; Cost = $displayCost; DurationMs = [long]($judge.reviewDurationMs ?? 0); CostEst = $judgeCostEstimated }
}

Write-Host ""
Write-Host "==== aggregate-and-emit: $RunId ($chunkCount chunks) ===="
$rows | Format-Table -AutoSize | Out-String | Write-Host
if (-not $judge) { Write-Warning "No judge row — run shows as 'no judge' until aggregate-verdict.json carries a judge." }
