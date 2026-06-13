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
    Reviewer concurrency. Default 3 (one per default-panel reviewer).

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
    [int] $MaxParallel = 3
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
$isAudit = $false
$diffArgs = $null
if ($Target -match '^\d+$') {
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
        $diffArgs = @('-U15', $emptyTree, 'HEAD')
    }
    elseif ($Target) {
        $diffArgs = @('-U15', $Target)
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
        $diffArgs = @('-U15', $base)
    }

    if ($Pathspec) { $diffArgs += @('--') + $Pathspec }
    $raw = (& git -C $RepoPath diff @diffArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { Die "git diff failed:`n$raw" }
    Set-Content -LiteralPath $diffFile -Value $raw -Encoding utf8
}

$diffText = Get-Content -LiteralPath $diffFile -Raw
if ([string]::IsNullOrWhiteSpace($diffText)) { Die 'The resolved diff is empty — nothing to review.' 3 }

# --- Size check (§0a) — advisory only; chunking is host judgment ---------
$addedLines = @(Get-Content -LiteralPath $diffFile | Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') }).Count
if ($addedLines -gt 2000) {
    Write-Warning ("Diff has $addedLines added lines (> 2000). The panel degrades past ~2,000 lines. " +
        'Consider splitting into cohesive chunks and running this driver once per chunk, then synthesising.')
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
function Build-Args([object] $r, [string] $wrapper, [string] $instruction, [bool] $withFindings) {
    $caps = (Get-Command $wrapper).Parameters.Keys
    $a = @('-Instruction', $instruction, '-DiffPath', $diffFile, '-Model', $r.model)
    if ($withFindings) { $a += @('-FindingsPath', $pooledFile) }
    foreach ($c in @($ContextPath | Where-Object { $_ })) { $a += @('-ContextPath', $c) }
    if ($caps -contains 'Effort' -and $r.effort) { $a += @('-Effort', $r.effort) }
    if ($caps -contains 'RepoPath' -and $r.repoAccess) { $a += @('-RepoPath', $RepoPath) }
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
        [pscustomobject]@{
            Id      = $r.id
            Label   = $r.label
            Vendor  = $r.vendor
            Wrapper = $wrapper
            Args    = (Build-Args $r $wrapper $instruction $withFindings)
            OutFile = Join-Path $WorkDir ("{0}-{1}.txt" -f $phaseLabel, $r.id)
        }
    }

    Write-Host "[$phaseLabel] running $($jobs.Count) reviewers: $(($jobs.Label) -join ', ')"
    $results = $jobs | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
        $j = $_
        $a = $j.Args
        $out = (& pwsh -NoProfile -File $j.Wrapper @a 2>&1 | Out-String)
        [pscustomobject]@{ Id = $j.Id; Label = $j.Label; Vendor = $j.Vendor; OutFile = $j.OutFile; Out = $out; Exit = $LASTEXITCODE }
    }

    $ok = @()
    foreach ($res in $results) {
        if ($res.Exit -ne 0 -or [string]::IsNullOrWhiteSpace($res.Out)) {
            Write-Warning "[$phaseLabel] reviewer $($res.Id) ($($res.Label)) FAILED (exit $($res.Exit)) — degrading."
            Set-Content -LiteralPath $res.OutFile -Value "[reviewer unavailable: exit $($res.Exit)]`n$($res.Out)" -Encoding utf8
        }
        else {
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
    Write-Warning "Only $p1Vendors vendor(s) produced Phase 1 findings (min $minVendors). The panel is degraded; surface this to the user."
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

# --- Assemble the judge packet ------------------------------------------
$packet = [System.Text.StringBuilder]::new()
[void]$packet.AppendLine("# Judge packet — $repoName")
[void]$packet.AppendLine()
[void]$packet.AppendLine("Target: ``$($Target ? $Target : '(branch vs base)')`` · added lines: $addedLines · audit: $isAudit")
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

# Usage telemetry: real usage is captured per reviewer instead of a
# zero-token marker here -- gemini-review.ps1 posts its own stats, and Copilot
# headless sessions leave full modelMetrics in ~/.copilot/session-state for any
# local sweeper to collect.
