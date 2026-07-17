$ErrorActionPreference = 'Stop'
<#
  batch-summary.json is the source of truth for WHICH chunks belong to a run.
  These tests pin the two halves of that contract:

    batch-review.ps1        must let a RunRoot accumulate chunks across repeated
                            invocations (a repair re-runs a subset into the same
                            RunRoot, and must not shrink the run to that subset);
    aggregate-and-emit.ps1  must refuse to emit when the summary does not name
                            every chunk on disk, rather than emitting short
                            totals with every accepted count clamped to match.

  No reviewer API calls and no cost: run-review.ps1 exits 2 at its git-work-tree
  check when handed a non-git -RepoPath, so each chunk fails fast while
  batch-review.ps1 still records its row and writes the summary — which is the
  code under test. Telemetry env vars are cleared so emit cannot post anywhere.
#>

$batch = Join-Path $PSScriptRoot '..\batch-review.ps1'
$agg   = Join-Path $PSScriptRoot '..\aggregate-and-emit.ps1'
foreach ($s in @($batch, $agg)) {
    if (-not (Test-Path -LiteralPath $s)) { throw "script under test not found: $s" }
}

$env:OBSERVATORY_API_KEY = ''
$env:OBSERVATORY_URL     = ''

$root = Join-Path ([IO.Path]::GetTempPath()) ('ar-batch-summary-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fakeRepo = Join-Path $root 'not-a-repo'
New-Item -ItemType Directory -Path $fakeRepo -Force | Out-Null

try {
    function New-Manifest([string] $path, [string[]] $ids, [string] $labelPrefix = 'chunk') {
        @($ids | ForEach-Object { [pscustomobject]@{ id = $_; label = "$labelPrefix $_" } }) |
            ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath $path -Encoding utf8
    }
    function Get-SummaryIds([string] $runRoot) {
        $p = Join-Path $runRoot 'batch-summary.json'
        if (-not (Test-Path -LiteralPath $p)) { return @() }
        @(Get-Content -LiteralPath $p -Raw | ConvertFrom-Json | ForEach-Object { $_.chunkId } | Sort-Object)
    }

    # --- batch-review.ps1 unions the summary across invocations ---------------
    $runRoot = Join-Path $root 'run1'
    $m1 = Join-Path $root 'm1.json'; New-Manifest $m1 @('C01', 'C02', 'C03')
    # The repair labels C02 differently so the merge's last-write-wins half is
    # observable: with identical payloads, keeping the STALE C02 row looks the same
    # as replacing it, and only the id set would be checked.
    $m2 = Join-Path $root 'm2.json'; New-Manifest $m2 @('C02') 'repair'

    & pwsh -NoProfile -File $batch -ChunkManifest $m1 -RepoPath $fakeRepo -RunRoot $runRoot -BatchSize 3 *>$null
    if ($LASTEXITCODE -ne 0) { throw "first batch invocation exited $LASTEXITCODE" }
    $ids = Get-SummaryIds $runRoot
    if (($ids -join ',') -ne 'C01,C02,C03') { throw "first invocation should record all 3 chunks, got '$($ids -join ',')'" }

    # The repair: re-run ONLY C02 into the same RunRoot, keeping the good chunks.
    # Wholesale-writing the summary here shrank a 15-chunk audit to its last retry
    # of 4, and aggregate-and-emit then reported that as the whole run.
    # The exit-code check is load-bearing, not ceremony: if this invocation died
    # before writing, the summary would still hold the first run's C01,C02,C03 and
    # the assertion below would pass without the merge ever running.
    & pwsh -NoProfile -File $batch -ChunkManifest $m2 -RepoPath $fakeRepo -RunRoot $runRoot -BatchSize 1 *>$null
    if ($LASTEXITCODE -ne 0) { throw "repair batch invocation exited $LASTEXITCODE" }
    $ids = Get-SummaryIds $runRoot
    if (($ids -join ',') -ne 'C01,C02,C03') { throw "repair re-run must keep the untouched chunks, got '$($ids -join ',')'" }

    # ...and the retried chunk must be the REPAIRED row, exactly once.
    $rows = @(Get-Content -LiteralPath (Join-Path $runRoot 'batch-summary.json') -Raw | ConvertFrom-Json)
    $c02  = @($rows | Where-Object { $_.chunkId -eq 'C02' })
    if ($c02.Count -ne 1) { throw "the union must leave C02 exactly once, got $($c02.Count) row(s)" }
    if ($c02[0].label -ne 'repair C02') { throw "the repair invocation must win for C02, got label '$($c02[0].label)'" }
    "batch-review.ps1 OK — a repair re-run preserves the run's other chunks and wins for the one it retried"

    # --- aggregate-and-emit.ps1 refuses a summary that misses chunks ----------
    $runRoot2 = Join-Path $root 'run2'
    foreach ($id in @('C01', 'C02', 'C03')) {
        $d = Join-Path $runRoot2 $id
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [ordered]@{
            participants = @(
                [ordered]@{ reviewer = 'anthropic'; model = 'claude-opus-4-8'; inputTokens = 1000
                            outputTokens = 100; costUsd = 0.5; reviewDurationMs = 1000; issuesRaised = 8 }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $d 'metrics.json') -Encoding utf8
    }
    function New-Summary([string] $runRoot, [string[]] $ids) {
        @($ids | ForEach-Object {
            [pscustomobject]@{ chunkId = $_; label = "chunk $_"; exitCode = 0; elapsedSec = 1
                               workDir = (Join-Path $runRoot $_); hasMetrics = $true }
        }) | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath (Join-Path $runRoot 'batch-summary.json') -Encoding utf8
    }

    New-Summary $runRoot2 @('C03')
    $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot2 -Repo test-repo 2>&1 | Out-String)
    # Assert the SPECIFIC code, not merely non-zero: under $ErrorActionPreference
    # 'Stop' a bare Write-Error throws before its `exit <n>` runs, which silently
    # collapses every distinct exit code to 1. A -ne 0 check cannot see that.
    if ($LASTEXITCODE -ne 4) { throw "a summary naming 1 of 3 chunks on disk must refuse with exit 4, got $LASTEXITCODE`n$out" }
    if ($out -notmatch 'does not name') { throw "refusal should name the unlisted chunks, got:`n$out" }
    # Pin the orphan SET, not just the phrase: 'does not name' appears whichever
    # chunks the guard picked, so on its own it cannot tell a correct refusal from
    # one reporting the wrong dirs. C01/C02 are unlisted; C03 the summary does name
    # and must not be reported -- that exclusion is what makes the set exact.
    foreach ($orphan in @('C01', 'C02')) {
        if ($out -notmatch "\b$orphan\b") { throw "refusal must name the unlisted chunk $orphan, got:`n$out" }
    }
    if ($out -match '\bC03\b') { throw "C03 is named by the summary and must not be reported unlisted, got:`n$out" }

    # And the honest case still emits, with the run's true totals (3 chunks x 8 raised).
    New-Summary $runRoot2 @('C01', 'C02', 'C03')
    $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot2 -Repo test-repo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "a summary naming every chunk must emit, exited $LASTEXITCODE`n$out" }
    if ($out -notmatch '\(3 chunks\)') { throw "ChunkCount must be the true number of chunks, got:`n$out" }
    if ($out -notmatch '\b24\b') { throw "issuesRaised must sum across chunks (3 x 8 = 24), got:`n$out" }
    "aggregate-and-emit.ps1 OK — refuses a truncated summary, sums the true run when honest"

    # --- the summary's workDir path form must not decide what is found --------
    # batch-review.ps1 does not resolve -RunRoot, so a relative one persists
    # relative workDirs (a temp path can also be recorded 8.3-short). Selecting
    # metrics via workDir then resolves them against the AGGREGATOR's working
    # directory, finding nothing when it differs. Chunk ids are resolved against
    # the resolved RunRoot instead, so path form cannot matter.
    $runRoot3 = Join-Path $root 'run3'
    foreach ($id in @('C01', 'C02', 'C03')) {
        $d = Join-Path $runRoot3 $id
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [ordered]@{
            participants = @(
                [ordered]@{ reviewer = 'anthropic'; model = 'claude-opus-4-8'; inputTokens = 1000
                            outputTokens = 100; costUsd = 0.5; reviewDurationMs = 1000; issuesRaised = 8 }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $d 'metrics.json') -Encoding utf8
    }
    @('C01', 'C02', 'C03' | ForEach-Object {
        [pscustomobject]@{ chunkId = $_; label = "chunk $_"; exitCode = 0; elapsedSec = 1
                           workDir = ".\run3\$_"; hasMetrics = $true }
    }) | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath (Join-Path $runRoot3 'batch-summary.json') -Encoding utf8

    # Aggregate from a directory those relative workDirs cannot resolve against.
    $elsewhere = Join-Path $root 'elsewhere'
    New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
    Push-Location $elsewhere
    try {
        $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot3 -Repo test-repo 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    if ($code -ne 0) { throw "relative workDirs must not stop the run being found, exited $code`n$out" }
    if ($out -notmatch '\(3 chunks\)') { throw "expected all 3 chunks despite relative workDirs, got:`n$out" }
    if ($out -notmatch '\b24\b') { throw "expected summed raised=24 despite relative workDirs, got:`n$out" }
    "aggregate-and-emit.ps1 OK — chunk ids resolve against RunRoot, so workDir path form is irrelevant"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
