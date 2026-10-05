#Requires -Version 7
<#
.SYNOPSIS
    Drive a chunked/batched adversarial review: run the deterministic spine
    (run-review.ps1) once per chunk under one shared run id, at a fixed chunk
    concurrency, so every chunk leaves a metrics.json for aggregation.

.DESCRIPTION
    A large diff cannot be reviewed as one panel run (it overruns the
    cross-vendor reviewers and dilutes findings — see the skill, §0a). The fix is
    to tile the surface into cohesive chunks and run the full three-phase pipeline
    once per chunk, then synthesise (§5). This script standardises that fan-out
    that was previously hand-rolled per audit:

      - one shared RunRoot (<temp>/adversarial-review/<stamp>) and RunId for all
        chunks, so aggregate-and-emit.ps1 groups them as ONE dashboard run;
      - each chunk gets its own subdirectory <RunRoot>/<chunkId> and runs the
        spine with the chunk's pathspec;
      - chunks run -BatchSize at a time (each spine itself runs the manifest's
        enabled reviewers in parallel — currently four, so wall concurrency
        ≈ BatchSize × reviewer count);
      - it STOPS at the judge boundary, exactly like the spine. Adjudication,
        per-chunk reports, §5 synthesis, and the aggregate-verdict.json that feeds
        accepted/judge into aggregate-and-emit.ps1 remain host judgment.

.PARAMETER ChunkManifest
    Path to a JSON array of chunks:
      [ { "id": "L1", "label": "Library: Orders",
          "pathspec": ["src/Orders", ":!**/*.Designer.cs"] }, ... ]
    `id` must be a filesystem-safe slug (becomes the chunk subdir). `pathspec` is
    forwarded to the spine after `--`.

.PARAMETER RepoPath
    Repository root. Defaults to the git toplevel of the current directory.

.PARAMETER RunRoot
    Shared run working directory. Defaults to <temp>/adversarial-review/<UTC stamp>.

.PARAMETER Target
    Spine target for every chunk (default 'audit' — empty tree vs HEAD, the usual
    whole-surface audit). Any spine target is accepted.

.PARAMETER ContextPath
    Repo context file(s) forwarded to every chunk's reviewers (read-only
    background). Keep tight.

.PARAMETER PreamblePath
    Forwarded to every chunk's spine: a brief that replaces the default audit
    preamble. Use `briefs/system-preamble.txt` to review a normative corpus
    (governance instruments, specifications, procedures) as an engineering
    system rather than as code.

.PARAMETER BatchSize
    Chunks run concurrently (default 3).

.PARAMETER ChunkTimeoutSeconds
    Wall-clock ceiling per chunk (default 6000). The spine bounds each ROUND with
    -RoundTimeoutSeconds (default 2700, two rounds), but a hang OUTSIDE the rounds
    -- e.g. an unbounded `gh pr diff` while resolving a PR target -- would otherwise
    stall the whole batch forever. Sized above 2 x the round default so a slow but
    legitimate chunk is not cut off mid-Phase-2. A timed-out chunk is recorded
    distinctly (timedOut: true, exitCode: null in batch-summary.json), and
    aggregate-and-emit.ps1 treats it as failed.

.OUTPUTS
    Writes <RunRoot>/<chunkId>/* per chunk (including metrics.json), a
    <RunRoot>/batch-summary.json roll-up, and prints the RunRoot + next steps.

.EXAMPLE
    pwsh -NoProfile -File batch-review.ps1 -ChunkManifest chunks.json -Target audit
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ChunkManifest,
    [string] $RepoPath,
    [string] $RunRoot,
    [string] $Target = 'audit',
    [string[]] $ContextPath,
    [string] $PreamblePath,

    [ValidateRange(1, [int]::MaxValue)]
    [int] $BatchSize = 3,

    # ponytail: floor of 1, not 60 -- the floor only blocks nonsense, and the contract
    # test needs a seconds-scale timeout to exercise the wedge path.
    [ValidateRange(1, 86400)]
    [int] $ChunkTimeoutSeconds = 6000,

    # Passed through to every chunk. Batch mode is the documented shape for an audit, and
    # without this the deliberate-scope decision the dirty-tree gate exists to force could
    # not be made from here at all: the run just exited 4 on local hygiene.
    [switch] $AllowDirty
)

$ErrorActionPreference = 'Stop'
# NB: these fatal guards use `Write-Error -ErrorAction Continue; exit 2` on purpose.
# With $ErrorActionPreference='Stop', a bare Write-Error is TERMINATING — it throws
# before the explicit `exit 2` runs, so the intended exit code 2 never surfaces
# (callers see an exception / exit 1 instead). -ErrorAction Continue keeps the
# message non-terminating so `exit 2` is what actually determines the exit code.
$scriptDir = Split-Path -Parent $PSCommandPath
$spine = Join-Path $scriptDir 'run-review.ps1'
if (-not (Test-Path -LiteralPath $spine)) { Write-Error "run-review.ps1 not found beside this script." -ErrorAction Continue; exit 2 }

if (-not (Test-Path -LiteralPath $ChunkManifest)) { Write-Error "Chunk manifest not found: $ChunkManifest" -ErrorAction Continue; exit 2 }
try {
    $chunks = @(Get-Content -LiteralPath $ChunkManifest -Raw | ConvertFrom-Json)
} catch {
    # ConvertFrom-Json throws (terminating under Stop) on malformed JSON — catch it
    # so a bad manifest surfaces as the same exit 2 as the missing/empty cases, not
    # an unhandled exception.
    Write-Error "Chunk manifest is not valid JSON: $($_.Exception.Message)" -ErrorAction Continue; exit 2
}
if (-not $chunks) { Write-Error "Chunk manifest is empty." -ErrorAction Continue; exit 2 }

# Validate ids BEFORE any per-chunk work: each becomes a directory name joined to
# RunRoot. A separator or '..' would let a chunk write outside the run root; a
# duplicate id would make two chunks race on the same directory. Reject both.
$ids = @($chunks | ForEach-Object { $_.id })
# Slug-safe AND not a pure-dot id: '.' / '..' pass the character class but are
# directory-traversal handles ('..' would escape RunRoot), so reject them too. Also
# reject a trailing '.' or space: Windows silently strips those from a path segment,
# so 'C01.' and 'C01' would resolve to the SAME directory while reading as two
# distinct ids -- two chunks racing one dir, or a double-counted metrics.json.
$bad = @($ids | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+$' -or $_ -match '^\.+$' -or $_ -match '[. ]$' })
if ($bad) { Write-Error "Invalid chunk id(s) — must match [A-Za-z0-9._-], not be all dots, and not end in '.' or space: $($bad -join ', ')" -ErrorAction Continue; exit 2 }
$dupes = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($dupes) { Write-Error "Duplicate chunk id(s): $($dupes -join ', ')" -ErrorAction Continue; exit 2 }

if (-not $RepoPath) {
    $top = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $top) { Write-Error 'Not in a git repo and no -RepoPath given.' -ErrorAction Continue; exit 2 }
    $RepoPath = $top.Trim()
}
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path

if (-not $RunRoot) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $RunRoot = Join-Path ([IO.Path]::GetTempPath()) (Join-Path 'adversarial-review' $stamp)
}
New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
$RunId = Split-Path -Leaf $RunRoot

Write-Host "Batch review: $($chunks.Count) chunks, batch-size $BatchSize"
Write-Host "RunRoot: $RunRoot"

# Clear each target chunk's previous metrics.json BEFORE any chunk runs. The chunk
# dir is reused (New-Item -Force below), which is exactly what a repair re-run hits:
# if a previous attempt left a metrics.json and this attempt dies before writing its
# own, the chunk would contribute the OLD attempt's numbers under a summary row that
# records THIS attempt's failure — and the "failed chunk(s) contribute no metrics"
# warning would be false (observed: a failed retry still contributing raised=99).
#
# Deliberately here, in the main scope, and NOT swallowed: $ErrorActionPreference is
# 'Stop', so a delete that cannot proceed (a locked file) aborts the batch before any
# expensive work, rather than leaving stale numbers to be counted. Skipping just the
# chunk would not be enough — the union below would keep its previous summary row and
# aggregate the stale file anyway. This is also why a chunk dir worth keeping must be
# backed up OUTSIDE the RunRoot before a retry, per the skill.
#
# Read every target's bytes into memory BEFORE deleting any of them, then restore
# whatever this loop already deleted if a later one fails. Deleting sequentially with
# no rollback meant a LATER locked file aborted the batch (correctly) but AFTER earlier
# chunks' stale metrics were already gone — destroying their data without this
# invocation ever getting to the fan-out that would have regenerated it.
$staleBackups = [ordered]@{}
foreach ($c in $chunks) {
    $stale = Join-Path (Join-Path $RunRoot $c.id) 'metrics.json'
    if (Test-Path -LiteralPath $stale) { $staleBackups[$stale] = [System.IO.File]::ReadAllBytes($stale) }
}
try {
    foreach ($stale in $staleBackups.Keys) { Remove-Item -LiteralPath $stale -Force }
} catch {
    # Attempt EVERY restore, don't stop at the first that fails: a later still-restorable
    # backup must not be abandoned because an earlier one couldn't be written. Collect any
    # restore failures and surface them alongside the original cleanup error, so the
    # operator sees the full picture (which chunks are now unrecoverable) rather than just
    # the first fault.
    $cleanupError = $_
    $restoreFailures = @()
    foreach ($stale in $staleBackups.Keys) {
        if (-not (Test-Path -LiteralPath $stale)) {
            try { [System.IO.File]::WriteAllBytes($stale, $staleBackups[$stale]) }
            catch { $restoreFailures += "$stale ($($_.Exception.Message))" }
        }
    }
    if ($restoreFailures) {
        throw "Stale-metrics cleanup failed ($($cleanupError.Exception.Message)) and these backups could NOT be restored: $($restoreFailures -join '; '). Those chunks' previous metrics are lost; recover them before aggregating."
    }
    throw $cleanupError
}

# Each worker runs its spine under its OWN clock (see .PARAMETER ChunkTimeoutSeconds).
# ForEach-Object's -TimeoutSeconds is not used: it is one clock for the whole
# invocation, so later throttled waves would be killed for time earlier waves spent.
# -ErrorAction is NOT accepted in the Parallel parameter set, so the script-level 'Stop'
# is relaxed around the call: one worker's error must not abort the whole batch. A chunk
# that reports no row gets a synthesised failed row below.
$chunkTimeoutErrors = @()
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
$results = $chunks | ForEach-Object -ThrottleLimit $BatchSize -ErrorVariable +chunkTimeoutErrors -Parallel {
    $c = $_
    $spine      = $using:spine
    $RunRoot    = $using:RunRoot
    $RepoPath   = $using:RepoPath
    $Target     = $using:Target
    $ContextPath = $using:ContextPath
    $PreamblePath = $using:PreamblePath
    $AllowDirty = $using:AllowDirty
    $timeoutMs  = [int][Math]::Min([int]::MaxValue, [long]$using:ChunkTimeoutSeconds * 1000)
    $drainMs    = 30000

    $chunkDir = Join-Path $RunRoot $c.id
    New-Item -ItemType Directory -Path $chunkDir -Force | Out-Null

    $a = @('-NoProfile', '-File', $spine, '-Target', $Target, '-RepoPath', $RepoPath, '-WorkDir', $chunkDir)
    if ($c.pathspec) { $a += @('-Pathspec', ((@($c.pathspec)) -join ';')) }
    # One ';'-joined token, never a repeated flag: the spine runs under `pwsh -File`,
    # whose binder rejects a parameter named twice ("specified more than once").
    $ctx = @($ContextPath | Where-Object { $_ }) -join ';'
    if ($ctx) { $a += @('-ContextPath', $ctx) }
    if ($PreamblePath) { $a += @('-PreamblePath', $PreamblePath) }
    # A switch must be a BARE flag under `pwsh -File`: every argument arrives as a string
    # there, and a stringified bool binds to neither [bool] nor [switch].
    if ($AllowDirty) { $a += '-AllowDirty' }

    # ArgumentList quotes each element, so paths with spaces survive. Both streams are
    # drained asynchronously so a full pipe cannot deadlock the wait.
    $psi = [System.Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($arg in $a) { $psi.ArgumentList.Add([string]$arg) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $finished = $proc.WaitForExit($timeoutMs)
    if (-not $finished) {
        # Only the exit-between-wait-and-kill race is expected; any other failure to
        # kill the tree would leave a wedged spine running, so it must surface.
        try { $proc.Kill($true) }
        catch [System.InvalidOperationException] { Write-Verbose "chunk $($c.id) exited before it could be stopped" }
        [void]$proc.WaitForExit($drainMs)
    }
    $sw.Stop()
    $exit = if ($finished) { $proc.ExitCode } else { $null }
    # Bounded too: a surviving grandchild that inherited the pipes would otherwise hold
    # the reads open and re-hang the worker the ceiling just freed.
    $drained = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdout, $stderr), $drainMs)
    $out = if ($drained) { $stdout.Result + $stderr.Result }
           else { "batch-review: output streams still open ${drainMs}ms after the spine ended; output not captured." }
    Set-Content -LiteralPath (Join-Path $chunkDir 'run-output.txt') -Value $out -Encoding utf8

    # A clean chunk (panel convened, zero findings) exits 0 exactly like a chunk with
    # findings; status.json's pooledCount is what tells them apart.
    $pooledCount = $null
    $chunkStatus = Join-Path $chunkDir 'status.json'
    if ($exit -eq 0 -and (Test-Path -LiteralPath $chunkStatus)) {
        try { $pooledCount = [int]((Get-Content -LiteralPath $chunkStatus -Raw | ConvertFrom-Json).pooledCount) }
        catch { $pooledCount = $null }
    }

    [pscustomobject]@{
        chunkId = $c.id; label = $c.label; exitCode = $exit; timedOut = (-not $finished)
        pooledCount = $pooledCount
        elapsedSec = [int]($sw.Elapsed.TotalSeconds); workDir = $chunkDir
        hasMetrics = (Test-Path -LiteralPath (Join-Path $chunkDir 'metrics.json'))
    }
}
}
finally {
    $ErrorActionPreference = $previousErrorAction
}

$results = @($results)
$reportedChunks = @($results | ForEach-Object { $_.chunkId })
# A worker that errored before writing its row: recorded as failed, never as timed out.
$unreported = @($chunks | Where-Object { $_.id -notin $reportedChunks })
foreach ($m in $unreported) {
    $results += [pscustomobject]@{
        chunkId = $m.id; label = $m.label; exitCode = $null; timedOut = $false
        pooledCount = $null
        elapsedSec = $null; workDir = (Join-Path $RunRoot $m.id)
        hasMetrics = $false
    }
}
if ($chunkTimeoutErrors.Count -gt 0) {
    Write-Warning "$($chunkTimeoutErrors.Count) non-terminating error(s) inside the chunk fan-out: $(($chunkTimeoutErrors | ForEach-Object { $_.Exception.Message }) -join ' | ')"
}
$wedged = @($results | Where-Object { $_.timedOut })
if ($wedged) {
    Write-Warning ("$($wedged.Count) chunk(s) hit the ${ChunkTimeoutSeconds}s chunk timeout and were stopped: " +
        "$(@($wedged | ForEach-Object { $_.chunkId }) -join ', '). The stall is outside the spine's bounded rounds " +
        '(check target resolution, e.g. gh pr diff). They contribute no metrics.')
}

$results = @($results) | Sort-Object chunkId

# Repairing a run means re-running this script into the SAME RunRoot with a subset
# manifest, so the chunks that already went well are kept. Writing the summary
# wholesale silently shrank the run to that subset: aggregate-and-emit.ps1 reads
# this file as the source of truth for WHICH chunks belong to the run, so a
# 15-chunk audit repaired in three retries (11, then 5, then 4) emitted as a
# 4-chunk run, with every per-vendor total short and every `accepted` clamped down
# to match — a plausible, wrong run. Union by chunkId instead, this invocation
# winning per chunk, so a RunRoot accumulates chunks across invocations.
$summaryPath = Join-Path $RunRoot 'batch-summary.json'
$merged = [ordered]@{}
if (Test-Path -LiteralPath $summaryPath) {
    try {
        foreach ($row in @(Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json)) {
            # A row with no chunkId can't be keyed or carried forward. Skipping it
            # would silently drop that chunk (a failed one left no metrics dir either,
            # so nothing downstream catches it). Treat it as a malformed summary and
            # fall into the preserve-aside path rather than quietly losing the row.
            if ([string]::IsNullOrWhiteSpace([string]$row.chunkId)) { throw "summary contains a row with no chunkId" }
            $merged[$row.chunkId] = $row
        }
    } catch {
        # Don't blindly proceed: the prior summary may name FAILED chunks that left no
        # metrics.json -- those exist only as summary rows, so overwriting the file
        # would erase them with no way to rediscover them (the fallback scan only finds
        # metrics.json). Move the unreadable/malformed file aside first so its bytes
        # survive for recovery, THEN write this invocation's rows. But if that move
        # itself fails, do NOT fall through to the overwrite -- that would destroy the
        # only record. Let the move throw and abort the run instead; the per-chunk
        # metrics.json dirs are all still on disk, so nothing this run computed is lost.
        $reason = $_.Exception.Message
        $preserved = "$summaryPath.unreadable-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Move-Item -LiteralPath $summaryPath -Destination $preserved -Force
        Write-Warning "Existing batch-summary.json is unusable ($reason) — moved to $preserved and writing this invocation's $($results.Count) chunk(s) only. Any earlier FAILED chunks (no metrics.json) live only in the preserved file; recover their rows from it before aggregating, or aggregate-and-emit.ps1 will under-count them."
        $merged = [ordered]@{}
    }
}
$carried = @($merged.Keys | Where-Object { $_ -notin @($results.chunkId) })
foreach ($row in @($results)) { $merged[$row.chunkId] = $row }
$summaryRows = @($merged.Values) | Sort-Object chunkId
# -AsArray: a single-chunk invocation would otherwise serialise as a bare object,
# and the merge above reads this file back.
#
# Write to a temp file in the SAME directory, then atomically replace the real
# path, rather than Set-Content directly on it. Set-Content truncates then writes;
# a process killed mid-write leaves invalid JSON, and the merge's own catch block
# above would then discard every chunk this file previously named -- the exact
# "repair shrinks the run" failure this whole union exists to prevent, just
# triggered by a crash instead of an overwrite. A same-directory temp path keeps
# the replace on one volume.
#
# [System.IO.File]::Move($src, $dst, $true), not Move-Item -Force: the cmdlet's
# own overwrite handling is not documented as atomic and its behaviour under a
# blocked overwrite ("Cannot create a file when that file already exists") is not
# the same guarantee as calling the framework's own overwrite-aware overload
# directly. File.Move's 3-arg form is the documented atomic same-volume replace
# (.NET Core 3.0+, so present on any PowerShell 7 runtime) and needs no separate
# "destination doesn't exist yet" branch -- it handles both.
$tempSummaryPath = "$summaryPath.tmp-$PID"
try {
    $summaryRows | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath $tempSummaryPath -Encoding utf8
    [System.IO.File]::Move($tempSummaryPath, $summaryPath, $true)
} catch {
    Remove-Item -LiteralPath $tempSummaryPath -Force -ErrorAction SilentlyContinue
    throw
}

$timedOutChunks = @($results | Where-Object { $_.timedOut })
$failed  = @($results | Where-Object { -not $_.timedOut -and $_.exitCode -ne 0 })
$noMetrics = @($results | Where-Object { $_.exitCode -eq 0 -and -not $_.hasMetrics })
# Panel convened, zero findings: a deliberate, visible outcome -- neither a failure nor
# a chunk with findings.
$clean = @($results | Where-Object { $_.exitCode -eq 0 -and $null -ne $_.pooledCount -and $_.pooledCount -eq 0 })

Write-Host ""
Write-Host "==== batch complete: $RunId ===="
$results | Format-Table chunkId, label, exitCode, timedOut, pooledCount, elapsedSec, hasMetrics -AutoSize | Out-String | Write-Host
if ($carried) {
    Write-Host "Kept $($carried.Count) chunk(s) already in this RunRoot ($($carried -join ', ')) — the run now has $($summaryRows.Count) chunk(s) in total."
}
if ($clean)     { Write-Host "$($clean.Count) chunk(s) CLEAN (panel convened, zero findings): $($clean.chunkId -join ', ')." }
if ($failed)    { Write-Warning "$($failed.Count) chunk(s) failed: $($failed.chunkId -join ', ') — they contribute no metrics." }
if ($noMetrics) { Write-Warning "$($noMetrics.Count) chunk(s) left no metrics.json: $($noMetrics.chunkId -join ', ')." }
Write-Host ""
Write-Host "Next (host judgment, per the skill):"
Write-Host "  1. Adjudicate + verify each chunk -> report-<id>.md."
Write-Host "  2. §5 synthesise across chunks -> report.md; write $RunRoot\aggregate-verdict.json"
Write-Host "     (accepted per reviewer + judge participant)."
Write-Host "  3. pwsh -NoProfile -File `"$scriptDir\aggregate-and-emit.ps1`" -RunRoot `"$RunRoot`" -Repo <repo> [-Summary <name>]"
# `chunks` is what THIS invocation ran; `runChunks` is what the RunRoot now holds
# in total, which is the number aggregate-and-emit.ps1 will emit as ChunkCount.
[pscustomobject]@{ runRoot = $RunRoot; runId = $RunId; chunks = $results.Count; runChunks = $summaryRows.Count; failed = $failed.Count; timedOut = $timedOutChunks.Count; clean = $clean.Count } | ConvertTo-Json -Compress
