#Requires -Version 7
<#
.SYNOPSIS
    Deterministic spine of the adversarial-review panel: resolve the diff, run
    the blind review (Phase 1) and cross-examination (Phase 2) across the
    manifest's reviewers, pool and anonymise findings, and assemble the judge
    packet. Host-agnostic — runnable from Claude Code, Antigravity (`agy`), the
    Gemini CLI, or a bare shell.

.DESCRIPTION
    This script does the mechanical 80% of an adversarial review that is
    identical on every host: it forwards the diff to each reviewer wrapper
    (claude-review.ps1 / external-review.ps1 / gemini-review.ps1, selected by
    reviewers.json), captures their findings, strips preamble, pools and
    re-ids them anonymously, then runs the cross-examination round and lays out
    everything a judge needs.

    It deliberately STOPS at the judgment boundary. Adjudication (Phase 3),
    verification (Phase 4), and multi-chunk synthesis are left to the host
    agent, which reads the repo to settle contested mechanisms — that judgment
    is exactly what does not belong in a deterministic script. The host picks up
    from `judge-packet.md` using `briefs/phase3-adjudicate.txt`.

    Chunk-boundary selection (which files form a cohesive chunk) is also host
    judgment: this script reviews ONE diff. For a whole-repo audit the host runs
    it once per chunk, then synthesises with `briefs/synthesis.txt`.

    The vendor-diversity invariant is enforced here: if the enabled reviewer set
    spans fewer than the manifest's `minVendors`, the run aborts — a same-vendor
    panel is self-review, not an adversarial one. A reviewer whose wrapper exits
    non-zero is reported as unavailable and the run degrades (provided diversity
    still holds), never silently collapsing to one model.

.PARAMETER Target
    What to review (mirrors the skill argument before `--`):
      <empty>      current branch vs its merge-base with the default branch
      <PR number>  `gh pr diff <n>`
      audit        current state of the code: diff vs the empty tree (pair with -Pathspec)
      <ref/range>  any git ref or range, e.g. main..HEAD, a branch, a SHA

.PARAMETER Pathspec
    Git pathspec(s) forwarded verbatim to `git diff` after `--` to scope files
    (inclusion `src/Engine`, exclusion `:!**/Migrations/**`). Ignored for a PR
    target. Strongly recommended with `audit`.

.PARAMETER ContextPath
    Repo files handed to the reviewers as read-only background — the
    contracts/base-types/callers the diff depends on but does not contain. Closes
    the cross-vendor reviewer's repo-blindness (see the skill, §1). Keep tight
    (~3-5 files).

.PARAMETER RepoPath
    Repository root. Defaults to the git toplevel of the current directory.

.PARAMETER WorkDir
    Per-run working directory. Defaults to <temp>/adversarial-review/<UTC stamp>.

.PARAMETER ManifestPath
    reviewers.json. Defaults to the copy beside this script.

.PARAMETER MaxParallel
    Reviewer concurrency. Default 5 (one per default-panel reviewer:
    Sonnet + Fable + Codex + Kimi + Gemini).

.OUTPUTS
    Writes all artefacts into WorkDir and prints a JSON status object plus a
    human summary. Exit 0 on a complete spine, non-zero on a fatal error
    (no git repo, empty diff, diversity invariant unmet).

.EXAMPLE
    pwsh -NoProfile -File run-review.ps1 -Target audit -Pathspec 'src/Engine',':!**/*.Designer.cs'
.EXAMPLE
    pwsh -NoProfile -File run-review.ps1            # current branch vs base
#>
[CmdletBinding()]
param(
    [string] $Target = '',
    [string[]] $Pathspec,
    [string[]] $ContextPath,
    [string] $RepoPath,
    [string] $WorkDir,
    [string] $ManifestPath,
    [int] $MaxParallel = 5
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$scriptDir = Split-Path -Parent $PSCommandPath
$emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

# Normalize Pathspec: when called via pwsh -File from a subprocess, multi-element arrays
# can't be passed as separate tokens without binding errors. Callers join with ';' instead.
if ($Pathspec.Count -eq 1 -and $Pathspec[0] -match ';') {
    $Pathspec = $Pathspec[0] -split ';'
}

function Die([string] $msg, [int] $code = 1) {
    Write-Error $msg
    exit $code
}

# --- Resolve repo --------------------------------------------------------
if (-not $RepoPath) {
    $top = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $top) {
        Die 'adversarial-review needs a git repository (could not resolve the repo root).' 2
    }
    $RepoPath = $top.Trim()
}
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
if ((& git -C $RepoPath rev-parse --is-inside-work-tree 2>$null) -ne 'true') {
    Die "Not inside a git work tree: $RepoPath" 2
}
$repoName = Split-Path -Leaf $RepoPath

# --- Manifest ------------------------------------------------------------
if (-not $ManifestPath) { $ManifestPath = Join-Path $scriptDir 'reviewers.json' }
if (-not (Test-Path -LiteralPath $ManifestPath)) { Die "Manifest not found: $ManifestPath" 2 }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

$reviewers = @($manifest.reviewers | Where-Object { $_.enabled })
if (-not $reviewers) { Die 'No enabled reviewers in the manifest.' 2 }
$vendorCount = ($reviewers.vendor | Sort-Object -Unique).Count
$minVendors = [int]($manifest.minVendors ?? 2)
if ($vendorCount -lt $minVendors) {
    Die ("Vendor-diversity invariant unmet: $vendorCount distinct vendor(s) enabled, $minVendors required. " +
        'A same-vendor panel is self-review, not adversarial. Enable a reviewer from another vendor.') 2
}

function Resolve-Wrapper([object] $reviewer) {
    $file = $manifest.wrappers.($reviewer.wrapper)
    if (-not $file) { Die "Reviewer '$($reviewer.id)' names unknown wrapper '$($reviewer.wrapper)'." 2 }
    $path = Join-Path $scriptDir $file
    if (-not (Test-Path -LiteralPath $path)) { Die "Wrapper not found for '$($reviewer.id)': $path" 2 }
    $path
}

# --- Work dir ------------------------------------------------------------
if (-not $WorkDir) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $WorkDir = Join-Path ([IO.Path]::GetTempPath()) (Join-Path 'adversarial-review' $stamp)
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$diffFile = Join-Path $WorkDir 'review-diff.txt'
$pooledFile = Join-Path $WorkDir 'pooled-findings.txt'

# --- Resolve the diff (§0) ----------------------------------------------
# Context depth: audit and PR reviews use -U15 for rich surrounding context.
# Drift and range reviews default to -U6 — the change is forward-only and
# does not need deep context; heavy context inflates total diff size 2–3×
# and pushes into the cross-vendor reviewers' transport limits (§0a).
$isAudit = $false
$isPR    = $false
$baseDiffArgs = $null   # ref + context args WITHOUT pathspec; stored for compact-diff regeneration
if ($Target -match '^\d+$') {
    $isPR = $true
    Write-Host "Resolving PR #$Target via gh..."
    $raw = (& gh pr diff $Target 2>&1)
    if ($LASTEXITCODE -ne 0) { Die "gh pr diff $Target failed:`n$raw" }
    Set-Content -LiteralPath $diffFile -Value $raw -Encoding utf8
}
else {
    if ($Target -eq 'audit') {
        $isAudit = $true
        if (-not $Pathspec) {
            Write-Warning 'audit with no -Pathspec reviews the WHOLE repo as one diff — this dilutes findings and overruns the cross-vendor reviewer. Scope it to one cohesive area.'
        }
        $baseDiffArgs = @('-U15', $emptyTree, 'HEAD')
    }
    elseif ($Target) {
        $baseDiffArgs = @('-U6', $Target)
    }
    else {
        $defaultBranch = (& git -C $RepoPath symbolic-ref --short refs/remotes/origin/HEAD 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $defaultBranch) {
            $defaultBranch = @('main', 'master') | Where-Object {
                (& git -C $RepoPath rev-parse --verify --quiet $_ 2>$null); $LASTEXITCODE -eq 0
            } | Select-Object -First 1
        }
        if (-not $defaultBranch) { Die 'Could not detect a default branch (no origin/HEAD, no main/master).' }
        $defaultBranch = ($defaultBranch -replace '^origin/', '').Trim()
        $base = (& git -C $RepoPath merge-base $defaultBranch HEAD 2>$null).Trim()
        if (-not $base) { Die "Could not find merge-base of $defaultBranch and HEAD." }
        $baseDiffArgs = @('-U6', $base)
    }

    $diffArgs = if ($Pathspec) { $baseDiffArgs + @('--') + $Pathspec } else { $baseDiffArgs }
    $raw = (& git -C $RepoPath diff @diffArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { Die "git diff failed:`n$raw" }
    Set-Content -LiteralPath $diffFile -Value $raw -Encoding utf8
}

$diffText = Get-Content -LiteralPath $diffFile -Raw
if ([string]::IsNullOrWhiteSpace($diffText)) { Die 'The resolved diff is empty — nothing to review.' 3 }

# --- Size check and compact-diff generation (§0a) -----------------------
$diffLines  = Get-Content -LiteralPath $diffFile
$addedLines = @($diffLines | Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') }).Count
$totalLines = $diffLines.Count
$estTokens  = [int]($totalLines * 12)   # ≈12 tokens/line for code diffs

if ($addedLines -gt 2000) {
    Write-Warning ("Diff has $addedLines added lines (> 2000). The panel degrades past ~2,000 lines. " +
        'Consider splitting into cohesive chunks and running this driver once per chunk, then synthesising.')
}

# Transport gate: OpenAI has a ~30k tokens-per-request cap; Gemini CLI hangs
# on oversized input. Keep 25k as a headroom margin. When over the gate,
# generate a compact (-U4) diff for the repo-blind cross-vendor reviewers;
# Reviewer B (Claude, repo access) keeps the full diff.
$tokenGate      = 25000
$compactDiffFile = $null
if ($estTokens -gt $tokenGate) {
    if ($isPR) {
        Write-Warning ("PR diff ~$estTokens est. tokens exceeds the $tokenGate-token gate. Cannot regenerate " +
            'at lower context. Cross-vendor reviewers will receive the full diff; monitor for 429 / Gemini hang.')
    }
    elseif ($baseDiffArgs) {
        $compactArgs = @('-U4') + $baseDiffArgs[1..($baseDiffArgs.Count - 1)]
        if ($Pathspec) { $compactArgs += @('--') + $Pathspec }
        $compactRaw = (& git -C $RepoPath diff @compactArgs 2>&1)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($compactRaw)) {
            $compactDiffFile = Join-Path $WorkDir 'review-diff-compact.txt'
            Set-Content -LiteralPath $compactDiffFile -Value $compactRaw -Encoding utf8
            Write-Warning ("Diff ~$estTokens est. tokens exceeds $tokenGate-token gate. " +
                'Compact diff (-U4) written to review-diff-compact.txt — G and X will use it; B keeps the full diff.')
        }
    }
}

# --- Compose the Phase 1 brief ------------------------------------------
$briefDir = Join-Path $scriptDir 'briefs'
function Read-Brief([string] $name) {
    $p = Join-Path $briefDir $name
    if (-not (Test-Path -LiteralPath $p)) { Die "Brief not found: $p" 2 }
    Get-Content -LiteralPath $p -Raw
}
$phase1 = Read-Brief 'phase1-review.txt'
if ($isAudit) { $phase1 = (Read-Brief 'audit-preamble.txt') + "`n`n" + $phase1 }
$phase1BriefFile = Join-Path $WorkDir 'phase1-brief.txt'
Set-Content -LiteralPath $phase1BriefFile -Value $phase1 -Encoding utf8

$phase2 = Read-Brief 'phase2-cross-examine.txt'
$phase2BriefFile = Join-Path $WorkDir 'phase2-brief.txt'
Set-Content -LiteralPath $phase2BriefFile -Value $phase2 -Encoding utf8

# Copy the adjudication brief into the work dir so the judge packet is self-contained.
Copy-Item (Join-Path $briefDir 'phase3-adjudicate.txt') (Join-Path $WorkDir 'phase3-brief.txt') -Force

# --- Build a per-reviewer job spec --------------------------------------
# Introspect each wrapper so we only pass -Effort / -RepoPath to wrappers that
# actually declare them (Copilot/Gemini do not expose a reasoning-effort flag).
function Build-Args([object] $r, [string] $wrapper, [string] $instruction, [bool] $withFindings, [string] $phaseLabel) {
    $caps = (Get-Command $wrapper).Parameters.Keys
    # Repo-blind reviewers (G and X) get the compact diff when one was generated;
    # Reviewer B (repo access) always gets the full diff so it can cross-reference the repo.
    $thisDiff = if ($compactDiffFile -and -not $r.repoAccess) { $compactDiffFile } else { $diffFile }
    $a = @('-Instruction', $instruction, '-DiffPath', $thisDiff, '-Model', $r.model)
    if ($withFindings) { $a += @('-FindingsPath', $pooledFile) }
    foreach ($c in @($ContextPath | Where-Object { $_ })) { $a += @('-ContextPath', $c) }
    if ($caps -contains 'Effort' -and $r.effort) { $a += @('-Effort', $r.effort) }
    if ($caps -contains 'RepoPath' -and $r.repoAccess) { $a += @('-RepoPath', $RepoPath) }
    # Wrappers that expose -UsageSidecarPath (G, X) write exact {inputTokens,
    # outputTokens,costUsd} per call; one sidecar per reviewer per phase so the
    # metrics writer can sum P1+P2. Claude (B) has no sidecar — its cost is
    # estimated downstream from the blended rate.
    if ($caps -contains 'UsageSidecarPath') {
        $a += @('-UsageSidecarPath', (Join-Path $WorkDir ("usage-{0}-{1}.json" -f $r.id, $phaseLabel)))
    }
    , $a
}

function Strip-Preamble([string] $text, [string] $startPattern) {
    $lines = $text -split "`r?`n"
    $idx = ($lines | Select-String -Pattern $startPattern | Select-Object -First 1).LineNumber
    if (-not $idx) { return $text.Trim() }
    ($lines[($idx - 1)..($lines.Count - 1)] -join "`n").Trim()
}

function Invoke-Round([string] $phaseLabel, [string] $startPattern, [bool] $withFindings) {
    $jobs = foreach ($r in $reviewers) {
        $wrapper = Resolve-Wrapper $r
        $instruction = if ($withFindings) { $phase2 } else { $phase1 }
        # Subscription-first, API-fallback: if the reviewer declares a
        # fallbackWrapper (e.g. codex -> openai), resolve it and pre-build its
        # args so the parallel round can retry through it when the primary
        # (sub-backed CLI) exits non-zero — sub down / not logged in / lapsed.
        $fbWrapper = $null; $fbArgs = $null
        if ($r.fallbackWrapper) {
            $fbFile = $manifest.wrappers.($r.fallbackWrapper)
            if ($fbFile) {
                $fbPath = Join-Path $scriptDir $fbFile
                if (Test-Path -LiteralPath $fbPath) {
                    $fbWrapper = $fbPath
                    $fbArgs = (Build-Args $r $fbPath $instruction $withFindings $phaseLabel)
                } else {
                    Write-Warning "Reviewer '$($r.id)' fallbackWrapper '$($r.fallbackWrapper)' not found at $fbPath — no fallback."
                }
            }
        }
        [pscustomobject]@{
            Id             = $r.id
            Label          = $r.label
            Vendor         = $r.vendor
            Wrapper        = $wrapper
            Args           = (Build-Args $r $wrapper $instruction $withFindings $phaseLabel)
            FallbackWrapper = $fbWrapper
            FallbackArgs   = $fbArgs
            OutFile        = Join-Path $WorkDir ("{0}-{1}.txt" -f $phaseLabel, $r.id)
        }
    }

    Write-Host "[$phaseLabel] running $($jobs.Count) reviewers: $(($jobs.Label) -join ', ')"
    $results = $jobs | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
        $j = $_
        $a = $j.Args
        # Per-reviewer wall-clock for the metrics sidecar (telemetry duration).
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = (& pwsh -NoProfile -File $j.Wrapper @a 2>&1 | Out-String)
        $ec = $LASTEXITCODE
        $degraded = $false
        # Fall back to the API wrapper if the sub-backed primary failed.
        if (($ec -ne 0 -or [string]::IsNullOrWhiteSpace($out)) -and $j.FallbackWrapper) {
            $fb = $j.FallbackArgs
            $out = (& pwsh -NoProfile -File $j.FallbackWrapper @fb 2>&1 | Out-String)
            $ec = $LASTEXITCODE
            $degraded = $true
        }
        $sw.Stop()
        [pscustomobject]@{ Id = $j.Id; Label = $j.Label; Vendor = $j.Vendor; OutFile = $j.OutFile; Out = $out; Exit = $ec; ElapsedMs = $sw.ElapsedMilliseconds; Degraded = $degraded }
    }

    $ok = @()
    foreach ($res in $results) {
        if ($res.Exit -ne 0 -or [string]::IsNullOrWhiteSpace($res.Out)) {
            Write-Warning "[$phaseLabel] reviewer $($res.Id) ($($res.Label)) FAILED (exit $($res.Exit)) — degrading."
            Set-Content -LiteralPath $res.OutFile -Value "[reviewer unavailable: exit $($res.Exit)]`n$($res.Out)" -Encoding utf8
        }
        else {
            if ($res.Degraded) {
                Write-Warning "[$phaseLabel] reviewer $($res.Id) ($($res.Label)) degraded to API fallback — the subscription-backed CLI failed."
            }
            $clean = Strip-Preamble $res.Out $startPattern
            Set-Content -LiteralPath $res.OutFile -Value $clean -Encoding utf8
            $ok += $res
        }
    }
    , $ok
}

# --- Phase 1 -------------------------------------------------------------
$p1ok = Invoke-Round 'p1' '^### ' $false
if (-not $p1ok) { Die 'No reviewer produced Phase 1 findings; cannot continue.' }
$p1Vendors = ($p1ok.Vendor | Sort-Object -Unique).Count
if ($p1Vendors -lt $minVendors) {
    # Below minVendors this is NOT an adversarial panel — a single-vendor round is
    # self-review, and the whole value of the exercise is uncorrelated error across
    # vendors. This used to be a Write-Warning and the script still exited 0, so a
    # batched caller recorded the chunk as clean and the run reported success on a
    # panel that never happened. Fail loudly instead: the caller must be able to
    # tell "reviewed by one vendor" from "reviewed properly".
    Die "Only $p1Vendors vendor(s) produced Phase 1 findings (min $minVendors) — this is not an adversarial panel. Re-run this chunk; do not judge it."
}

# --- Pool + anonymise + assign F-ids ------------------------------------
$findingId = 0
$pool = [System.Text.StringBuilder]::new()
[void]$pool.AppendLine('# Pooled findings (attribution removed)')
[void]$pool.AppendLine()
foreach ($res in $p1ok) {
    $text = Get-Content -LiteralPath $res.OutFile -Raw
    $lines = $text -split "`r?`n"
    $block = [System.Collections.Generic.List[string]]::new()
    $flush = {
        if ($block.Count -gt 0 -and ($block -join '').Trim()) {
            $script:findingId++
            # Trim a trailing horizontal-rule separator a reviewer may have placed
            # between its own findings, so it does not bleed into the pooled block.
            $body = (($block -join "`n").Trim()) -replace '(\r?\n\s*-{3,}\s*)+$', ''
            [void]$pool.AppendLine("## F$script:findingId")
            [void]$pool.AppendLine($body.Trim())
            [void]$pool.AppendLine()
        }
        $block.Clear()
    }
    foreach ($ln in $lines) {
        if ($ln -match '^### ') { & $flush }
        if ($ln -match '^### ' -or $block.Count -gt 0) { $block.Add($ln) }
    }
    & $flush
}
Set-Content -LiteralPath $pooledFile -Value ($pool.ToString().TrimEnd()) -Encoding utf8
Write-Host "Pooled $findingId findings into $(Split-Path -Leaf $pooledFile)"

# --- Phase 2 -------------------------------------------------------------
$p2ok = Invoke-Round 'p2' '^(F\d+:|### )' $true

# --- Per-chunk reviewer metrics (telemetry) -----------------------------
# Write metrics.json so a batched run can be aggregated per participant across
# chunks (aggregate-and-emit.ps1). Covers the THREE reviewers' deterministic
# outcome: issuesRaised (### count) + cost/duration. The judge (synthesis) and
# issuesAccepted are products of adjudication and are recorded separately in
# aggregate-verdict.json at synthesis time. Best-effort: a failure here must
# never fail the review, so the whole block is guarded.
function Get-BlendedRatePerMillion([string] $model) {
    # Putative blend of published Anthropic rates, 75% input / 25% output — the
    # same convention emit telemetry uses. Sonnet $3/$15 → $6/M, Fable $10/$50 →
    # $20/M, Opus $15/$75 → $30/M.
    if ($model -match 'opus')  { return 30.0 }
    if ($model -match 'fable') { return 20.0 }
    return 6.0
}
function Read-UsageSidecar([string] $path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null }
}
try {
    $participants = foreach ($r in $reviewers) {
        $p1res = $p1ok | Where-Object { $_.Id -eq $r.id } | Select-Object -First 1
        $p2res = $p2ok | Where-Object { $_.Id -eq $r.id } | Select-Object -First 1
        $durationMs = [long](($p1res.ElapsedMs ?? 0) + ($p2res.ElapsedMs ?? 0))
        # Record whether this reviewer's sub-backed primary failed and the API
        # fallback carried the phase, in either phase — so degraded-to-API state
        # is durable in metrics.json, not just a transient warning.
        $degraded = [bool](($p1res.Degraded) -or ($p2res.Degraded))

        $p1File = Join-Path $WorkDir ("p1-{0}.txt" -f $r.id)
        $raised = if (Test-Path -LiteralPath $p1File) {
            @(Get-Content -LiteralPath $p1File | Where-Object { $_ -match '^### ' }).Count
        } else { 0 }

        $sidecars = @(
            (Read-UsageSidecar (Join-Path $WorkDir ("usage-{0}-p1.json" -f $r.id)))
            (Read-UsageSidecar (Join-Path $WorkDir ("usage-{0}-p2.json" -f $r.id)))
        ) | Where-Object { $_ }

        # A reviewer that produced NO usable output in either phase ran nothing.
        # It must record zeros, not an estimate. The old code fell straight into
        # the sidecar-less branch below and billed it $estTokens * 2 — the DIFF's
        # own token estimate — so a dead reviewer was indistinguishable from a
        # live one, and a chunk whose OpenAI call 401'd logged the exact same
        # figure as the two Claude reviewers (observed: 23760 three times over).
        # Fabricated metrics for a reviewer that never spoke are worse than no
        # metrics: they make a broken panel read as a working one.
        $phasesRun = @(@($p1res, $p2res) | Where-Object { $_ }).Count

        if ($phasesRun -eq 0) {
            [ordered]@{
                reviewer         = $r.vendor
                role             = 'reviewer'
                model            = $r.model
                inputTokens      = 0
                outputTokens     = 0
                costUsd          = 0.0
                costEstimated    = $false
                failed           = $true
                degraded         = $degraded
                reviewDurationMs = $durationMs
                issuesRaised     = 0
            }
        }
        else {
            if ($sidecars) {
                $inTok  = [long]($sidecars | Measure-Object -Property inputTokens  -Sum).Sum
                $outTok = [long]($sidecars | Measure-Object -Property outputTokens -Sum).Sum
                $cost   = [double]($sidecars | Measure-Object -Property costUsd     -Sum).Sum
                # Exact only when every phase the reviewer ran produced a sidecar. A
                # partial set (a phase failed, or its wrapper wrote none) still sums
                # the real figures it has but is flagged putative rather than exact,
                # so the missing phase's cost is not silently presented as complete.
                $estimated = ($sidecars.Count -lt $phasesRun)
                # A sidecar that reports zero tokens (e.g. Kimi — its stream-json
                # carries no usage) is not exact usage, it is unavailable: flag it
                # estimated so the dashboard does not present a flat-rate ~0 as a
                # measured figure.
                if ($inTok -eq 0 -and $outTok -eq 0) { $estimated = $true }
            } else {
                # No sidecar (Claude wrapper) — estimate from proxies and the blended
                # rate. Input ≈ the diff once per phase ACTUALLY RUN (P1 full, P2 with
                # pooled findings); output ≈ chars in this reviewer's P1+P2 text / 4.
                # Scale by $phasesRun, not a hardcoded 2: a reviewer that only
                # survived P1 must not be billed for a P2 it never made.
                $inTok  = [long]($estTokens * $phasesRun)
                $outChars = 0
                foreach ($f in @($p1res.OutFile, $p2res.OutFile)) {
                    if ($f -and (Test-Path -LiteralPath $f)) { $outChars += (Get-Content -LiteralPath $f -Raw).Length }
                }
                $outTok = [long][Math]::Ceiling($outChars / 4.0)
                $cost   = ($inTok + $outTok) * (Get-BlendedRatePerMillion $r.model) / 1e6
                $estimated = $true
            }

            [ordered]@{
                reviewer         = $r.vendor
                role             = 'reviewer'
                model            = $r.model
                inputTokens      = $inTok
                outputTokens     = $outTok
                costUsd          = [Math]::Round($cost, 6)
                costEstimated    = $estimated
                failed           = $false
                degraded         = $degraded
                reviewDurationMs = $durationMs
                issuesRaised     = $raised
            }
        }
    }
    $metrics = [ordered]@{
        chunkId      = (Split-Path -Leaf $WorkDir)
        repo         = $repoName
        writtenBy    = 'run-review.ps1'
        participants = @($participants)
    }
    $metrics | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $WorkDir 'metrics.json') -Encoding utf8
}
catch {
    Write-Warning "metrics.json not written ($_). Telemetry aggregation will fall back to estimates for this chunk."
}

# --- Assemble the judge packet ------------------------------------------
$packet = [System.Text.StringBuilder]::new()
[void]$packet.AppendLine("# Judge packet — $repoName")
[void]$packet.AppendLine()
$compactNote = if ($compactDiffFile) { ' · compact diff: G+X' } else { '' }
[void]$packet.AppendLine("Target: ``$($Target ? $Target : '(branch vs base)')`` · added lines: $addedLines · total lines: $totalLines · est. tokens: $estTokens$compactNote · audit: $isAudit")
[void]$packet.AppendLine("Reviewers (Phase 1): $(($p1ok.Label) -join ', ')")
[void]$packet.AppendLine()
[void]$packet.AppendLine('Adjudicate with `briefs/phase3-adjudicate.txt` (copied here as `phase3-brief.txt`).')
[void]$packet.AppendLine('Then verify Highs + contested findings with `briefs/phase4-verify.txt` (Phase 4) before publishing.')
[void]$packet.AppendLine('The diff under review is `review-diff.txt`; read the repo to settle contested mechanisms.')
[void]$packet.AppendLine()
[void]$packet.AppendLine('---')
[void]$packet.AppendLine('## Phase 1 — blind findings (per reviewer)')
foreach ($res in $p1ok) {
    [void]$packet.AppendLine()
    [void]$packet.AppendLine("### Reviewer $($res.Id) — $($res.Label)")
    [void]$packet.AppendLine()
    [void]$packet.AppendLine((Get-Content -LiteralPath $res.OutFile -Raw).TrimEnd())
}
[void]$packet.AppendLine()
[void]$packet.AppendLine('---')
[void]$packet.AppendLine('## Pooled findings (anonymised, F-ids)')
[void]$packet.AppendLine()
[void]$packet.AppendLine((Get-Content -LiteralPath $pooledFile -Raw).TrimEnd())
[void]$packet.AppendLine()
[void]$packet.AppendLine('---')
[void]$packet.AppendLine('## Phase 2 — cross-examination (per reviewer)')
foreach ($res in $p2ok) {
    [void]$packet.AppendLine()
    [void]$packet.AppendLine("### Reviewer $($res.Id) — $($res.Label)")
    [void]$packet.AppendLine()
    [void]$packet.AppendLine((Get-Content -LiteralPath $res.OutFile -Raw).TrimEnd())
}
$packetFile = Join-Path $WorkDir 'judge-packet.md'
Set-Content -LiteralPath $packetFile -Value ($packet.ToString().TrimEnd()) -Encoding utf8

# --- Status --------------------------------------------------------------
$status = [ordered]@{
    repo            = $repoName
    repoPath        = $RepoPath
    target          = $Target
    audit           = $isAudit
    addedLines      = $addedLines
    totalLines      = $totalLines
    estTokens       = $estTokens
    compactDiff     = $compactDiffFile
    workDir         = $WorkDir
    diffFile        = $diffFile
    pooledFile      = $pooledFile
    judgePacket     = $packetFile
    pooledCount     = $findingId
    phase1Reviewers = @($p1ok | ForEach-Object { @{ id = $_.Id; label = $_.Label; vendor = $_.Vendor } })
    phase2Reviewers = @($p2ok | ForEach-Object { @{ id = $_.Id; label = $_.Label; vendor = $_.Vendor } })
    vendorsP1       = $p1Vendors
    nextSteps       = @('adjudicate (phase3-brief.txt)', 'verify Highs+contested (phase4-verify.txt)', 'synthesise if multi-chunk', 'persist to vault')
}
$statusFile = Join-Path $WorkDir 'status.json'
$status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusFile -Encoding utf8

Write-Host ''
Write-Host '==== adversarial-review spine complete ===='
Write-Host "Work dir:     $WorkDir"
Write-Host "Pooled:       $findingId findings ($pooledFile)"
Write-Host "Judge packet: $packetFile"
Write-Host "Next: adjudicate -> verify -> [synthesise] -> persist (see status.json / SKILL.md)."
$status | ConvertTo-Json -Depth 6

# Observatory telemetry: real usage is captured per reviewer instead of a
# zero-token marker here -- gemini-review.ps1 posts its own stats, and Copilot
# headless sessions are swept from ~/.copilot/session-state by
# ~/.claude/hooks/observe-sweep.ps1.
