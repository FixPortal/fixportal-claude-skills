#Requires -Version 7
<#
.SYNOPSIS
    Deterministic spine of the adversarial-review panel: resolve the diff, run
    the blind review (Phase 1) and cross-examination (Phase 2) across the
    manifest's reviewers, pool and anonymise findings, and assemble the judge
    packet. Host-agnostic — runnable from Claude Code, Antigravity (`agy`), or a
    bare shell.

.DESCRIPTION
    This script does the mechanical 80% of an adversarial review that is
    identical on every host: it forwards the diff to each reviewer wrapper
    (claude-review.ps1 / codex-review.ps1 / kimi-review.ps1 / agy-review.ps1,
    selected by reviewers.json), captures their findings, strips preamble, pools and
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
    (inclusion `src/Engine`, exclusion `:!**/Migrations/**`). PR targets reject
    pathspecs because `gh pr diff` cannot apply them. Strongly recommended with
    `audit`.

.PARAMETER ContextPath
    Repo files handed to the reviewers as read-only background — the
    contracts/base-types/callers the diff depends on but does not contain. Closes
    the cross-vendor reviewer's repo-blindness (see the skill, §1). Keep tight
    (~3-5 files).

.PARAMETER PreamblePath
    Brief prepended to the Phase 1 brief, replacing the default audit preamble.
    Use `briefs/system-preamble.txt` when the reviewed surface is a normative
    corpus (governance instruments, specifications, procedures) rather than
    code — it redirects the code-shaped defect classes to their corpus
    analogues and opens the engineering-system dimensions (proportion, evidence
    adequacy, executability, coverage). Applies to any target, not just `audit`.

.PARAMETER RepoPath
    Repository root. Defaults to the git toplevel of the current directory.

.PARAMETER WorkDir
    Per-run working directory. Defaults to <temp>/adversarial-review/<UTC stamp>.

.PARAMETER ManifestPath
    reviewers.json. Defaults to the copy beside this script.

.PARAMETER MaxParallel
    Reviewer concurrency. Default 5 (one per default-panel reviewer:
    Sonnet + Fable + Codex + Kimi + Gemini).

.PARAMETER RoundTimeoutSeconds
    Wall-clock ceiling for a single round (Phase 1 or Phase 2). Default 2700 (45
    minutes). Nothing in this script or in the wrappers previously bounded a
    reviewer, so one wedged slot stalled its phase indefinitely with nothing
    marking it unavailable — contrary to the skill's stated degrade-and-continue
    behaviour, and detectable only by a human noticing the run had stopped moving.
    A stopped reviewer produces no output and falls through the existing
    "FAILED — degrading" path, so the round still completes if diversity holds.
    Sized off measurement, not guesswork: the slowest observed reviewer took
    30m30s (2026-08-17 desktop pass, Kimi Phase 1), so 45 minutes is roughly a
    50% margin. Raise it for a very large diff rather than removing it.

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
    [string] $PreamblePath,
    [string] $RepoPath,
    [string] $WorkDir,
    [string] $ManifestPath,
    [int] $MaxParallel = 5,
    [ValidateRange(60, 86400)]
    [int] $RoundTimeoutSeconds = 2700,
    # Proceed with a tree-to-tree target on a dirty working tree, recording the omitted
    # paths instead of stopping. Deliberate scope decision, never a default.
    [switch] $AllowDirty
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

# Set once the durable sidecar exists (below, after run identity is resolved). Until
# then Die has nothing to correct, which is why these are declared rather than assumed.
$script:failureStatusFile = $null
$script:failureRunIdentity = $null

function Die([string] $msg, [int] $code = 1) {
    # A fatal exit must not leave the sidecar claiming `state: running`. It is written
    # before Phase 1 and only replaced at the very end, so every Die in between left a
    # durable file saying the run was still in progress - which a retry, and any sweep
    # over WorkDirs, cannot tell apart from a run that genuinely still is. Guarded on
    # the identity THIS process wrote, so a Die can never rewrite another run's sidecar.
    if ($script:failureStatusFile -and (Test-Path -LiteralPath $script:failureStatusFile)) {
        try {
            $sidecar = Get-Content -LiteralPath $script:failureStatusFile -Raw | ConvertFrom-Json
            if ($sidecar.runIdentity -and $sidecar.runIdentity -ceq $script:failureRunIdentity -and
                $sidecar.state -eq 'running') {
                $sidecar.state = 'failed'
                $sidecar | Add-Member -NotePropertyName failure -NotePropertyValue $msg -Force
                $sidecar | ConvertTo-Json -Depth 6 |
                    Set-Content -LiteralPath $script:failureStatusFile -Encoding utf8
            }
        } catch {
            # A sidecar too damaged to read is not worth failing the failure over; the
            # original message below is the one the operator needs.
        }
    }
    Write-Error $msg -ErrorAction Continue
    exit $code
}

# Normalize and VALIDATE ContextPath before any reviewer is spawned. Two separate
# hazards, both of which have cost a full parallel round:
#
#   1. `pwsh -File` passes arguments as strings, so an inline multi-element array
#      (`-ContextPath 'a','b'`) arrives as the SINGLE token `a,b`. The ';'-join the
#      callers apply is then a no-op on one element, and every wrapper splits on ';'
#      and gets one path that cannot exist. Splitting on ',' as well as ';' recovers
#      the operator's intent instead of propagating it.
#   2. A context file that simply is not there. Each wrapper discovers this on its
#      own, one reviewer at a time, minutes into the run — five identical
#      "Context file not found" failures across four vendors, which reads like a
#      vendor outage rather than a bad argument. One Test-Path here turns that into
#      an immediate, unambiguous exit.
#
# Deliberately AFTER Die is defined and BEFORE the repo/diff resolution below: the
# whole point is to fail before anything expensive or billable starts.
if ($ContextPath) {
    $ContextPath = @(
        $ContextPath |
            Where-Object { $_ } |
            ForEach-Object {
                # The element is tested AS GIVEN before any splitting: a path may
                # legally contain a comma or a semicolon, and splitting first killed
                # such a file while naming only a fragment of it in the error. The
                # separator interpretation is the recovery for the operator-error
                # case below, so it applies only when the whole element is not itself
                # a readable file.
                $whole = $_.Trim().Trim("'", '"')
                if ($whole -and (Test-Path -LiteralPath $whole -PathType Leaf)) {
                    $whole
                } else {
                    $_ -split '[;,]' | ForEach-Object { $_.Trim().Trim("'", '"') }
                }
            } |
            Where-Object { $_ }
    )
    foreach ($contextFile in $ContextPath) {
        if (-not (Test-Path -LiteralPath $contextFile -PathType Leaf)) {
            Die "Context file not found: $contextFile" 2
        }
    }
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

function Test-ReviewerExpired($ExpiresAt, [datetimeoffset] $Now) {
    if ($null -eq $ExpiresAt) { return $false }
    # ConvertFrom-Json may already have decoded an ISO timestamp as DateTime.
    if ($ExpiresAt -is [datetime] -or $ExpiresAt -is [datetimeoffset]) {
        $cutoff = [datetimeoffset]$ExpiresAt
    } elseif ($ExpiresAt -is [string] -and $ExpiresAt -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
        $cutoff = [datetimeoffset]::ParseExact($ExpiresAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    } else { throw 'Invalid expiresAt: use a UTC timestamp such as 2026-11-01T00:00:00Z.' }
    return $Now -ge $cutoff
}
$trialNow = [datetimeoffset](Get-Date -AsUTC)
$expiredReviewers = @()
$reviewers = @(foreach ($candidate in $manifest.reviewers | Where-Object { $_.enabled }) {
    if ($null -ne $candidate.supplemental -and $candidate.supplemental -isnot [bool]) { Die "Reviewer '$($candidate.id)' supplemental must be boolean." 2 }
    try { $expired = Test-ReviewerExpired $candidate.expiresAt $trialNow }
    catch { Die "Invalid expiresAt for reviewer '$($candidate.id)': $($_.Exception.Message)" 2 }
    if ($expired) {
        $expiredReviewers += [string]$candidate.id
        Write-Warning "Reviewer '$($candidate.id)' expired at $($candidate.expiresAt); skipped before model resolution and preflight."
    } else { $candidate }
})
if (-not $reviewers) { Die 'No enabled reviewers in the manifest.' 2 }
$reviewerIds = @($reviewers | ForEach-Object { [string]$_.id })
$duplicateIds = @($reviewerIds | Group-Object { $_.ToUpperInvariant() } | Where-Object Count -gt 1)
if ($reviewerIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }) {
    Die 'Every enabled reviewer needs a non-empty id; the id binds its phase files and sidecars.' 2
}
if ($duplicateIds) {
    Die "Reviewer ids must be unique because each id owns one set of phase files and sidecars: $($duplicateIds.Name -join ', ')" 2
}
# --- Resolve each seat's model from the canonical registry ---------------
# The manifest declares a CONSTRAINT (tier / vendor / family); the concrete id is
# resolved here, per run, so a model release is picked up by triaging it in the
# registry rather than by editing reviewers.json. resolve.py is called rather than
# reimplemented: its exclusions (untriaged tier, wrong-channel availability, a
# `retired` date) are the selection contract, and a second copy of them in
# PowerShell would drift silently -- the failure being a retired model still
# getting picked, which looks like a working run.
$registryDir = Join-Path (Split-Path $scriptDir -Parent) 'model-registry'
$resolveScript = Join-Path $registryDir 'resolve.py'

function Resolve-SeatModel([object] $seat, [string] $what) {
    # The registry is OPTIONAL. A seat with only a literal `model` is a deliberate pin
    # and never touches it. A seat with `select` resolves through the registry when the
    # registry is present; a literal `model` beside `select` is the fallback for a host
    # without one (e.g. the public mirror). A select-only seat with no registry dies by
    # name: running the panel a vendor short reads exactly like a clean review.
    if (-not $seat.select) {
        if ($seat.model) { return [string]$seat.model }
        Die "$what declares neither 'select' nor 'model'; there is nothing to run it with." 2
    }
    if (-not (Test-Path -LiteralPath $resolveScript)) {
        if ($seat.model) {
            Write-Host "${what}: model registry absent ($resolveScript); using the seat's literal 'model' fallback."
            return [string]$seat.model
        }
        Die ("$what declares only 'select', which needs the model registry, but $resolveScript is missing. " +
            "Install the model-registry skill beside this one, or give the seat a literal 'model' to run without it.") 2
    }

    $sel = $seat.select
    # Caught here rather than at argparse, which would report `invalid choice: ''` --
    # true, and no help at all in finding the manifest field that produced it.
    if (-not $sel.tier) {
        Die "$what has a 'select' block with no 'tier'; every constraint needs one." 2
    }
    $argv = @($resolveScript, '--tier', [string]$sel.tier)
    if ($sel.vendor) { $argv += @('--vendor', [string]$sel.vendor) }
    if ($sel.family) { $argv += @('--family', [string]$sel.family) }
    if ($sel.channel) { $argv += @('--channel', [string]$sel.channel) }
    if ($sel.minContext) { $argv += @('--min-context', [string]$sel.minContext) }

    # Resolved explicitly, because a missing interpreter surfaces as a PowerShell
    # CommandNotFoundException whose message is about `python`, not about the seat that
    # needed it - and on Windows the Store's `python.exe` stub RESOLVES and then exits
    # non-zero, which the branch below would report as "resolve.py exited 9009".
    #
    # `python3` FIRST, as everything else in this repo does: a stock Linux or macOS host
    # exposes only `python3`, so a driver hard-coded to `python` reports a working Python
    # installation as absent. The CommandInfo is invoked rather than `.Source`, which is
    # the executable path only for an Application and empty for an alias or function.
    $python = @('python3', 'python') |
        ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $python) {
        Die "$what needs python3 or python on PATH to resolve its seat through the model registry; neither was found." 2
    }
    $out = & $python @argv 2>&1
    if ($LASTEXITCODE -ne 0) {
        Die "$what could not resolve its model: resolve.py exited $LASTEXITCODE.`n$out" 2
    }
    # Validate the survivor, do not just filter `note:` lines out. `2>&1` merges stderr
    # into stdout, and resolve.py prints ids to stdout and diagnostics to stderr -- so ANY
    # other stderr line on an exit-0 run (a Python warning, a deprecation notice) passed
    # the filter and was handed to the wrapper verbatim as -Model and recorded as the
    # seat's telemetry identity. A broken slot then reads as a vendor outage, or a
    # nonexistent model id is attributed to a real run.
    $ids = @($out |
        Where-Object { $_ -and $_ -notmatch '^note:' } |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ -match '^[\w./:-]+$' })
    if (-not $ids) {
        # NEVER degrade to "run without this vendor". A panel silently one vendor
        # short reads exactly like a panel that reviewed and found nothing
        # (model-routing-traps.md traps 2 and 9), and the run would still satisfy
        # minVendors while claiming cross-vendor coverage it did not have.
        Die ("$what resolved to NO model. Constraint: " +
            "tier=$($sel.tier) vendor=$($sel.vendor) family=$($sel.family) channel=$($sel.channel ?? 'cli'). " +
            'Either nothing in the registry matches, or the match is untriaged (tier null), ' +
            "retired, or unavailable on that channel. Triage it in $registryDir/registry.json " +
            '-- do not drop the seat, a panel short a vendor is not this panel.') 2
    }
    return $ids[0]
}

function Convert-ToWrapperSelector([string] $modelId, [string] $wrapper) {
    # Registry id -> what this CLI accepts. Absent a rule the id passes through,
    # which is the case for every wrapper whose vendor ids ARE its selectors.
    $rules = $manifest.selectors.$wrapper
    foreach ($rule in @($rules)) {
        if ($rule.match -and $modelId -match $rule.match) { return [string]$rule.use }
    }
    return $modelId
}

foreach ($r in $reviewers) {
    $resolved = Resolve-SeatModel $r "Reviewer '$($r.id)' ($($r.label))"
    # Two values, deliberately: telemetry keys on the REGISTRY id so Observatory rows
    # stay priceable and un-fragmented, while the wrapper gets whatever its CLI takes.
    # Collapsing them is what made the old alias->id reverse lookup necessary.
    $r | Add-Member -NotePropertyName resolvedModel -NotePropertyValue $resolved -Force
    $r | Add-Member -NotePropertyName wrapperModel -NotePropertyValue (Convert-ToWrapperSelector $resolved $r.wrapper) -Force
    $shown = if ($r.wrapperModel -eq $resolved) { $resolved } else { "$resolved (as '$($r.wrapperModel)')" }
    Write-Host "Reviewer $($r.id) ($($r.label)): $shown"
}

$quorumReviewerIds = @($reviewers | Where-Object { -not $_.supplemental } | ForEach-Object id)
$vendorCount = @($reviewers | Where-Object { $_.id -in $quorumReviewerIds } | ForEach-Object vendor | Sort-Object -Unique).Count
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
$pooledMapFile = Join-Path $WorkDir 'pooled-map.json'
$statusFile = Join-Path $WorkDir 'status.json'

# --- Pre-flight evidence gate (§Pre-flight 2) ----------------------------
# The skill states the driver refuses to start without preflight.json, so that
# "pre-flight ran" is evidence rather than recollection. It said so for months
# while no script referenced the filename; this is that gate.
#
# The host runs the wrappers' PREFLIGHT_COMMAND headers -- the driver cannot,
# and does not pretend to. What it CAN do is refuse to spend a paid parallel
# round unless every required reviewer passed. Unverified supplemental seats skip.
#
# Looked for in WorkDir, then in its immediate parent: batch-review.ps1 gives
# each chunk its own <RunRoot>/<chunkId>, and pre-flight is per RUN, not per
# chunk, so one file in the RunRoot covers every chunk under it.
#
# `runId` must equal the leaf of the directory holding the file. Without that
# binding, one stale preflight.json in the shared default parent
# (<temp>/adversarial-review) would silently satisfy every future run on the
# box -- the exact fail-open shape this gate exists to close.
$preflightDir = @($WorkDir, (Split-Path -Parent $WorkDir)) |
    Where-Object { $_ } |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'preflight.json') } |
    Select-Object -First 1
if (-not $preflightDir) {
    Die (@"
No preflight.json found in the run root, so pre-flight cannot be evidenced.
Looked in: $WorkDir
       and: $(Split-Path -Parent $WorkDir)
Run each enabled wrapper's PREFLIGHT_COMMAND: header, then write, in the run root:
  { "runId": "<leaf of that directory>",
    "checked": [ { "reviewer": "<id>", "wrapper": "<file>", "command": "<command run>",
                   "result": "PREFLIGHT_SUCCESS" } ] }
One entry per enabled reviewer. A wrapper declaring no PREFLIGHT_COMMAND: is
unverified, not passing -- record it as such and disable it, do not invent a pass.
"@) 2
}
$preflightFile = Join-Path $preflightDir 'preflight.json'
try { $preflight = Get-Content -LiteralPath $preflightFile -Raw | ConvertFrom-Json }
catch { Die "preflight.json is not readable JSON: $preflightFile" 2 }
$preflightLeaf = Split-Path -Leaf $preflightDir
if ($preflight.runId -cne $preflightLeaf) {
    Die ("preflight.json records runId '$($preflight.runId)' but sits in '$preflightLeaf'. " +
        'The run id must match the directory holding the file, so evidence from one run cannot ' +
        "stand in for another: $preflightFile") 2
}
# -eq against an array FILTERS in PowerShell rather than comparing, so build the
# passing-id set explicitly and test membership with -contains.
$preflightPassed = @($preflight.checked |
    Where-Object { $_.result -eq 'PREFLIGHT_SUCCESS' } |
    ForEach-Object { [string]$_.reviewer })
$skippedSupplementalIds = @($reviewers | Where-Object { $_.supplemental -and $preflightPassed -notcontains [string]$_.id } | ForEach-Object id)
if ($skippedSupplementalIds.Count) {
    Write-Warning "Supplemental reviewers without PREFLIGHT_SUCCESS skipped: $($skippedSupplementalIds -join ', ')."
    $reviewers = @($reviewers | Where-Object { $_.id -notin $skippedSupplementalIds })
}
$supplementalIds = @($reviewers | Where-Object supplemental | ForEach-Object id)
$repoBlindIds = @($reviewers | Where-Object { -not $_.repoAccess } | ForEach-Object id)
$repoAwareIds = @($reviewers | Where-Object repoAccess | ForEach-Object id)
$preflightMissing = @($reviewers | Where-Object { $preflightPassed -notcontains [string]$_.id } | ForEach-Object id)
if ($preflightMissing.Count -gt 0) {
    Die ("preflight.json has no PREFLIGHT_SUCCESS entry for enabled reviewer(s): " +
        "$($preflightMissing -join ', '). An unverified wrapper is not a passing one; " +
        "re-run pre-flight or disable the reviewer in the manifest. Evidence: $preflightFile") 2
}
Write-Host "Pre-flight evidence: $preflightFile ($($preflightPassed.Count) wrapper(s) recorded PREFLIGHT_SUCCESS)"

# Put the routing traps at the point of use. Headings are enough to trigger the
# operator's lookup without dumping the long corpus into every run transcript.
$routingTrapFile = Join-Path $HOME '.agents' 'notes' 'model-routing-traps.md'
if (Test-Path -LiteralPath $routingTrapFile -PathType Leaf) {
    $trapHeadings = @(Get-Content -LiteralPath $routingTrapFile | Where-Object { $_ -match '^## ' })
    $trapNumbers = [System.Collections.Generic.HashSet[string]]::new()
    [void]$trapNumbers.Add('2')
    [void]$trapNumbers.Add('9')
    foreach ($wrapperName in @($reviewers | ForEach-Object { $_.wrapper; $_.fallbackWrapper } | Where-Object { $_ } | Sort-Object -Unique)) {
        switch ($wrapperName) {
            'codex'  { [void]$trapNumbers.Add('1') }
            'kimi'   { [void]$trapNumbers.Add('5') }
            'agy'    { [void]$trapNumbers.Add('8'); [void]$trapNumbers.Add('11') }
            'gemini' { [void]$trapNumbers.Add('11') }
            'copilot' { [void]$trapNumbers.Add('3') }
            'claude' { [void]$trapNumbers.Add('4') }
        }
    }
    $selectedTrapHeadings = @($trapHeadings | Where-Object {
        $heading = $_
        $trapNumbers | Where-Object { $heading -match "^## $([regex]::Escape($_))\." }
    })
    if ($selectedTrapHeadings) {
        Write-Host "Routing trap reminders: $($selectedTrapHeadings -join ' | ')"
    }
}

# --- Resolve the diff (§0) ----------------------------------------------
# Context depth: audit and PR reviews use -U15 for rich surrounding context.
# Drift and range reviews default to -U6 — the change is forward-only and
# does not need deep context; heavy context inflates total diff size 2–3×
# and pushes into the cross-vendor reviewers' transport limits (§0a).
$isAudit = $false
$isPR    = $false
$isTreeToTree = $false
$resolvedTargetIdentity = $null
# Uncommitted paths deliberately excluded from a tree-to-tree target. Recorded in
# status.json and the judge packet so "reviewed" never silently means "reviewed except
# for whatever was uncommitted at the time".
$dirtyPaths = @()
$baseDiffArgs = $null   # ref + context args WITHOUT pathspec; stored for compact-diff regeneration
if ($Target -match '^\d+$') {
    if ($Pathspec) { Die 'PR targets do not support pathspecs; review the PR as-is or use an explicit git ref/range with -Pathspec.' 2 }
    $isPR = $true
    Write-Host "Resolving PR #$Target via gh..."
    $originUrl = (& git -C $RepoPath remote get-url origin 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $originUrl) { Die "Cannot resolve origin for PR #$Target in $RepoPath." }
    $repoSlug = [regex]::Match($originUrl, '(?:[:/])([^/:]+/[^/:]+?)(?:\.git)?$')
    if (-not $repoSlug.Success) { Die "Cannot derive GitHub owner/repo from origin '$originUrl'." }
    $raw = (& gh pr diff $Target --repo $repoSlug.Groups[1].Value 2>&1)
    if ($LASTEXITCODE -ne 0) { Die "gh pr diff $Target failed:`n$raw" }
    $resolvedTargetIdentity = "pr:$Target"
}
else {
    # SKILL.md pre-flight step 4 mandates a deliberate scope decision on a dirty tree.
    # Nothing enforced it, so an `audit` or an explicit A..B range - both tree-to-tree -
    # excluded uncommitted work with no warning, and the run then reported coverage of a
    # target the reviewers had never fully seen. A bare branch/SHA target diffs against
    # the working tree and does pick it up, so only the tree-to-tree shapes are gated.
    # Classify by what git ACTUALLY expands the target to, not by spotting '..' in the
    # string. Observed: `git diff HEAD^!` shows only the committed change and NOT an
    # uncommitted edit, so it is tree-to-tree while matching no '..' pattern. rev-parse
    # emits one revision for a working-tree-inclusive target and two or more (the second
    # negated) for a tree-to-tree one.
    $targetRevisions = @(& git -C $RepoPath rev-parse --revs-only --no-flags $Target 2>$null | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { Die "git rev-parse failed for target '$Target'; cannot establish review scope." }
    $isTreeToTree = ($Target -eq 'audit') -or ($targetRevisions.Count -gt 1)
    if ($isTreeToTree) {
        # Scoped to -Pathspec when one is given: the review's scope IS the pathspec, so
        # unrelated local hygiene elsewhere in the repo is not "uncommitted work excluded
        # from this review". An unscoped check reported vendor-wide failure for a stray
        # edit in a directory the run never looked at.
        # -z, not the newline form. Porcelain v1 renders a rename as `R  old -> new`
        # and QUOTES any path containing a space, a quote or a non-ASCII byte, so the
        # old Substring(3) wrote `"src/caf\303\251.cs"` and `old -> new` into
        # status.json and into the operator's error as though they were filenames. -z
        # emits every path raw and gives a rename's source its own NUL-terminated
        # field.
        $statusArgs = @('-C', $RepoPath, 'status', '--porcelain', '-z')
        if ($Pathspec) { $statusArgs += @('--') + $Pathspec }
        # Joined with a newline, not the empty string: -z output contains no line
        # breaks of its own, so this is a no-op EXCEPT for a path that genuinely
        # contains a newline, where it puts back the character PowerShell split on.
        $rawStatus = (& git @statusArgs 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { Die 'git status --porcelain failed; cannot establish whether the tree is clean.' }
        $porcelain = @()
        $statusFields = @($rawStatus -split "`0" | Where-Object { $_ })
        for ($i = 0; $i -lt $statusFields.Count; $i++) {
            $field = $statusFields[$i]
            if ($field.Length -lt 4) { continue }
            $porcelain += $field.Substring(3)
            # A rename or copy is followed by its ORIGIN path in a field of its own.
            # That field carries no status prefix, so reading it as an entry would
            # report a path three characters short of its real name.
            if ("$($field[0])$($field[1])" -cmatch '[RC]') { $i++ }
        }
        # This status call and the `git diff` that produces the reviewed patch are two
        # separate invocations with no lock between them, so an edit landing in the gap
        # is in one and not the other. What that can corrupt is bounded: `$dirtyPaths`
        # is advisory - it names paths for the warning and for status.json - while the
        # patch's own sha256 is taken from the bytes actually reviewed, so the evidence
        # identity cannot drift out from under the run. Taking a lock over a
        # multi-minute panel to tighten an advisory list would cost far more than the
        # imprecision it removes.
        if ($porcelain.Count -gt 0) {
            $script:dirtyPaths = $porcelain
            if (-not $AllowDirty) {
                Die (
                    "Working tree is dirty ($($porcelain.Count) path(s)) and the '$Target' target is " +
                    "tree-to-tree, so none of it would reach a reviewer:`n  " +
                    (($dirtyPaths | Select-Object -First 20) -join "`n  ") +
                    "`nCommit or stash it, or re-run with -AllowDirty to review the committed tree " +
                    'and have the omitted paths recorded in status.json and the judge packet.'
                ) 4
            }
            Write-Warning "Reviewing a DIRTY tree with a tree-to-tree target: $($dirtyPaths.Count) uncommitted path(s) are NOT under review."
        }
    }

    if ($Target -eq 'audit') {
        $isAudit = $true
        $resolvedTargetIdentity = "audit:$((& git -C $RepoPath rev-parse HEAD).Trim())"
        if (-not $Pathspec) {
            Write-Warning 'audit with no -Pathspec reviews the WHOLE repo as one diff — this dilutes findings and overruns the cross-vendor reviewer. Scope it to one cohesive area.'
        }
        $baseDiffArgs = @('-U15', $emptyTree, 'HEAD')
    }
    elseif ($Target) {
        $baseDiffArgs = @('-U6', $Target)
        $resolvedTargetIdentity = "git:$($targetRevisions -join ',')"
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
        $resolvedTargetIdentity = "branch:$base..$((& git -C $RepoPath rev-parse HEAD).Trim())"
    }

    $diffArgs = if ($Pathspec) { $baseDiffArgs + @('--') + $Pathspec } else { $baseDiffArgs }
    $raw = (& git -C $RepoPath diff @diffArgs 2>$null)
    if ($LASTEXITCODE -ne 0) { Die "git diff failed:`n$raw" }
}

# Working-tree-inclusive targets include tracked edits in their diff, but git
# never includes untracked files. Refuse those omissions for every non-PR target.
if (-not $isPR -and -not $isTreeToTree) {
    $statusArgs = @('-C', $RepoPath, 'status', '--porcelain', '-z')
    if ($Pathspec) { $statusArgs += @('--') + $Pathspec }
    $rawStatus = (& git @statusArgs 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { Die 'git status --porcelain failed; cannot establish whether untracked files are in scope.' }
    $untracked = @($rawStatus -split "`0" | Where-Object { $_ -cmatch '^\?\? ' } | ForEach-Object { $_.Substring(3) })
    if ($untracked.Count -gt 0) {
        $script:dirtyPaths = $untracked
        if (-not $AllowDirty) {
            Die ("Working tree contains $($untracked.Count) in-scope untracked path(s), which git diff omits:`n  " +
                (($untracked | Select-Object -First 20) -join "`n  ") +
                "`nCommit or remove them, or re-run with -AllowDirty to record the omissions.") 4
        }
        Write-Warning "Reviewing with $($untracked.Count) in-scope untracked path(s) omitted from the diff."
    }
}

$diffIdentityText = @($raw) -join "`n"
if ([string]::IsNullOrWhiteSpace($diffIdentityText)) { Die 'The resolved diff is empty — nothing to review.' 3 }
$diffSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($diffIdentityText))).ToLowerInvariant()

# --- Working-tree snapshot identity (§4) --------------------------------
# A working-tree-inclusive target reviews bytes no commit contains. Phase 4 may
# hand a repoAccess:false verifier a DETACHED-COMMIT worktree, which structurally
# cannot hold those bytes -- so the verifier reads code that is simply absent and
# refutes a real finding on "no such path exists".
#
# Capture the uncommitted delta as an applicable patch and hash it, so the
# worktree route has something to be brought level with and the verdict can say
# which tree it read. `git diff HEAD` is the exact delta by which the review diff
# exceeds HEAD; untracked files appear in neither, which is why pre-flight 4
# stops rather than pretending they were reviewed.
$workingTreePatchFile = $null
$workingTreeSha256 = $null
if (-not $isPR -and -not $isTreeToTree) {
    $wtArgs = @('--binary', '-U6', 'HEAD')
    if ($Pathspec) { $wtArgs += @('--') + $Pathspec }
    $wtRaw = (& git -C $RepoPath diff @wtArgs 2>$null)
    if ($LASTEXITCODE -ne 0) { Die "git diff HEAD failed; cannot establish the working-tree delta:`n$wtRaw" }
    $wtText = @($wtRaw) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($wtText)) {
        $workingTreePatchFile = Join-Path $WorkDir 'working-tree.patch'
        Write-Warning ("Reviewed content includes UNCOMMITTED work; no commit identifies it. " +
            "Snapshot: $workingTreePatchFile. A Phase-4 detached " +
            'worktree must have this patch applied before it can verify anything, and _index.md ' +
            'records the hash beside the target range.')
    }
}

$identityInput = "$RepoPath`n$resolvedTargetIdentity`n$diffSha256"
$runIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identityInput))).ToLowerInvariant()

# status.json is the existing durable run sidecar. Refuse cross-run reuse before
# replacing any evidence in WorkDir; a retry of the same resolved inputs is allowed.
if (Test-Path -LiteralPath $statusFile) {
    try { $priorStatus = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json }
    catch { Die "WorkDir contains an unreadable status.json; its evidence identity cannot be trusted: $statusFile" 5 }
    if (-not $priorStatus.runIdentity -or $priorStatus.runIdentity -cne $runIdentity) {
        Die "WorkDir contains evidence for a different run identity; use a fresh WorkDir instead of mixing repo/ref/diff evidence: $WorkDir" 5
    }
}

# Do not overwrite a prior run's evidence until its identity has been accepted.
foreach ($stale in 'metrics.json', 'judge-packet.md', 'pooled-findings.txt', 'pooled-map.json') {
    Remove-Item -LiteralPath (Join-Path $WorkDir $stale) -Force -ErrorAction SilentlyContinue
}
foreach ($reviewer in $reviewers) {
    foreach ($phase in 'p1', 'p2') {
        Remove-Item -LiteralPath (Join-Path $WorkDir ("$phase-$($reviewer.id).txt")) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $WorkDir ("usage-$($reviewer.id)-$phase.json")) -Force -ErrorAction SilentlyContinue
    }
}
if ($workingTreePatchFile) {
    & git -C $RepoPath diff --output=$workingTreePatchFile @wtArgs 2>$null
    if ($LASTEXITCODE -ne 0) { Die 'git diff could not write the working-tree patch.' }
    $patchBytes = [IO.File]::ReadAllBytes($workingTreePatchFile)
    $workingTreeSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($patchBytes)).ToLowerInvariant()
}

[IO.File]::WriteAllText($diffFile, $diffIdentityText, [Text.UTF8Encoding]::new($false))
$diffText = Get-Content -LiteralPath $diffFile -Raw
[ordered]@{
    state = 'running'; runIdentity = $runIdentity; repoPath = $RepoPath
    target = $Target; resolvedTarget = $resolvedTargetIdentity; diffSha256 = $diffSha256
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $statusFile -Encoding utf8
# From here on a fatal Die records `state: failed` on this sidecar rather than
# abandoning it mid-'running'.
$script:failureStatusFile = $statusFile
$script:failureRunIdentity = $runIdentity

# --- Size check and compact-diff generation (§0a) -----------------------
$diffLines  = Get-Content -LiteralPath $diffFile
$addedLines = @($diffLines | Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') }).Count
$totalLines = $diffLines.Count
$estTokens  = [int]($totalLines * 12)   # ≈12 tokens/line for code diffs

if ($addedLines -gt 2000) {
    Write-Warning ("Diff has $addedLines added lines (> 2000). The panel degrades past ~2,000 lines. " +
        'Consider splitting into cohesive chunks and running this driver once per chunk, then synthesising.')
}

# Transport gate: OpenAI has a ~30k tokens-per-request cap. Keep 25k as a
# headroom margin and a comprehension bound. When over the gate,
# generate a compact (-U4) diff for manifest-declared repo-blind reviewers;
# repo-aware reviewers keep the full diff.
$tokenGate      = 25000
$compactDiffFile = $null
$compactDiffSha256 = $null
if ($estTokens -gt $tokenGate) {
    if ($isPR) {
        Write-Warning ("PR diff ~$estTokens est. tokens exceeds the $tokenGate-token gate. Cannot regenerate " +
            'at lower context. Cross-vendor reviewers will receive the full diff; monitor for 429 / Gemini hang.')
    }
    elseif ($baseDiffArgs) {
        $compactArgs = @('-U4') + $baseDiffArgs[1..($baseDiffArgs.Count - 1)]
        if ($Pathspec) { $compactArgs += @('--') + $Pathspec }
        $compactRaw = (& git -C $RepoPath diff @compactArgs 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($compactRaw)) {
            $compactDiffFile = Join-Path $WorkDir 'review-diff-compact.txt'
            $compactText = @($compactRaw) -join "`n"
            [IO.File]::WriteAllText($compactDiffFile, $compactText, [Text.UTF8Encoding]::new($false))
            $compactDiffSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($compactText))).ToLowerInvariant()
            Write-Warning ("Diff ~$estTokens est. tokens exceeds $tokenGate-token gate. " +
                "Compact diff (-U4) written to review-diff-compact.txt — $($repoBlindIds -join '+') will use it; $($repoAwareIds -join '+') keep the full diff.")
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
# An explicit -PreamblePath REPLACES the audit preamble (a corpus is not code, so
# the code-shaped calibration would be the wrong frame) and applies to any target.
# Unlike the audit preamble it also fronts Phase 2: the gap task there ("what did
# the pooled set miss") is exactly where the wider system dimensions surface, and a
# reviewer handed only the code-shaped brief in Phase 2 reverts to hunting code.
$preamble = $null
if ($PreamblePath) {
    # Resolve against $scriptDir, NOT the ambient CWD: the documented form is
    # `briefs/<name>.txt`, and batch-review.ps1 forwards this verbatim into parallel
    # runspaces whose working directory is not ours to assume.
    $p = if ([System.IO.Path]::IsPathRooted($PreamblePath)) { $PreamblePath }
         else { Join-Path $scriptDir $PreamblePath }
    if (-not (Test-Path -LiteralPath $p)) { Die "Preamble not found: $p" 2 }
    $preamble = Get-Content -LiteralPath $p -Raw
}
elseif ($isAudit) { $preamble = Read-Brief 'audit-preamble.txt' }

$phase1 = Read-Brief 'phase1-review.txt'
if ($preamble) { $phase1 = $preamble + "`n`n" + $phase1 }
$phase1BriefFile = Join-Path $WorkDir 'phase1-brief.txt'
Set-Content -LiteralPath $phase1BriefFile -Value $phase1 -Encoding utf8

$phase2 = Read-Brief 'phase2-cross-examine.txt'
if ($PreamblePath) { $phase2 = $preamble + "`n`n" + $phase2 }
$phase2BriefFile = Join-Path $WorkDir 'phase2-brief.txt'
Set-Content -LiteralPath $phase2BriefFile -Value $phase2 -Encoding utf8

# Copy the adjudication brief into the work dir so the judge packet is self-contained.
Copy-Item (Join-Path $briefDir 'phase3-adjudicate.txt') (Join-Path $WorkDir 'phase3-brief.txt') -Force

# --- Build a per-reviewer job spec --------------------------------------
# Introspect each wrapper so we only pass -Effort / -RepoPath to wrappers that
# declare them (Copilot/Gemini do not expose a reasoning-effort flag at all).
#
# This tests the DECLARATION, not the capability, and the two do not always
# agree: codex-review.ps1 and kimi-review.ps1 declare -Effort for contract
# symmetry over CLIs that have no effort flag, so they receive their seat's
# effort and cannot apply it. Both now warn when that happens rather than
# discarding it in silence. Do not read a forwarded -Effort as evidence the
# seat ran at that effort - read the wrapper's warnings.
function Build-Args([object] $r, [string] $wrapper, [string] $instruction, [bool] $withFindings, [string] $phaseLabel) {
    $caps = (Get-Command $wrapper).Parameters.Keys
    # A reviewer marked repoAccess:false gets the compact diff; a repo-aware one keeps the
    # full diff. But the decision follows the EFFECTIVE wrapper, not the manifest entry -
    # which describes the PRIMARY only. A wrapper that cannot even accept -RepoPath is
    # repo-blind by construction, so deriving it from the wrapper's own signature stays
    # correct for any future fallback without a second flag to keep in sync.
    #
    # Degrading from a repo-aware CLI to a repo-blind metered API used to keep sending the
    # full -U15 diff, on the one path most likely to hit a non-retryable 429 - turning an
    # outage into a lost vendor.
    $repoAware = [bool]$r.repoAccess -and ($caps -contains 'RepoPath')
    $thisDiff = if ($compactDiffFile -and -not $repoAware) { $compactDiffFile } else { $diffFile }
    $a = @('-Instruction', $instruction, '-DiffPath', $thisDiff, '-Model', $r.wrapperModel)
    if ($withFindings) { $a += @('-FindingsPath', $pooledFile) }
    # One ';'-joined token, never a repeated flag: the child runs under `pwsh -File`,
    # whose binder rejects a parameter named twice ("specified more than once").
    # Every wrapper splits -ContextPath on ';'.
    $ctx = @($ContextPath | Where-Object { $_ }) -join ';'
    if ($ctx) { $a += @('-ContextPath', $ctx) }
    if ($caps -contains 'Effort' -and $r.effort) { $a += @('-Effort', $r.effort) }
    if ($caps -contains 'RepoPath' -and $repoAware) {
        $a += @('-RepoPath', $RepoPath)
        if ($caps -contains 'AllowRepoCommands' -and $r.allowRepoCommands) { $a += '-AllowRepoCommands' }
    }
    # Wrappers that expose -UsageSidecarPath (G, X) write exact {inputTokens,
    # outputTokens,costUsd} per call; one sidecar per reviewer per phase so the
    # metrics writer can sum P1+P2. Claude (B) has no sidecar — its cost is
    # estimated downstream from the blended rate.
    if ($caps -contains 'UsageSidecarPath') {
        $a += @('-UsageSidecarPath', (Join-Path $WorkDir ("usage-{0}-{1}.json" -f $r.id, $phaseLabel)))
    }
    , $a
}

function Get-ReviewHeadingLineNumbers([string[]] $Lines, [string] $Pattern) {
    $indices = @()
    $fenceChar = $null
    $fenceLength = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = [string]$Lines[$i]
        if ($fenceChar) {
            if ($line -match "^\s*$([regex]::Escape($fenceChar)){$fenceLength,}\s*$") { $fenceChar = $null; $fenceLength = 0 }
            continue
        }
        if ($line -match '^\s*(`{3,}|~{3,})') {
            $fenceChar = $Matches[1].Substring(0, 1)
            $fenceLength = $Matches[1].Length
            continue
        }
        if ($line -match $Pattern) { $indices += $i }
    }
    return $indices
}

function Strip-Preamble([string] $text, [string] $startPattern) {
    # Returns the stripped body AND whether the reply participates in this phase.
    # A heading is the pooling signal, not the participation signal: a reviewer can
    # return a clean, on-topic prose verdict and still be a real vendor response.
    $lines = $text -split "`r?`n"
    $headingIndices = @(Get-ReviewHeadingLineNumbers -Lines $lines -Pattern $startPattern)
    if ($headingIndices.Count -eq 0) {
        $body = $text.Trim()
        # ponytail: a small topic-word heuristic is enough to reject arbitrary wrapper
        # noise; semantic validation belongs to the judge, not a second review parser.
        $refusal = $body -match '(?i)\b(?:cannot|can''t|unable|refus(?:e|ed|ing)|will\s+not|won''t|decline(?:d)?\s+to|not\s+going\s+to|failed)\b.{0,100}\b(?:review|inspect|read|access|analy[sz]e|examine|be\s+reviewed)\b'
        $onTopic = $body -match '(?i)\b(?:review|diff|defect|finding|issue|code|change|examined|inspected|substantive|nothing|no|severity|location|trigger|impact|fix)\b'
        return [pscustomobject]@{
            Matched        = -not [string]::IsNullOrWhiteSpace($body) -and $onTopic -and -not $refusal
            HeadingMatched = $false
            Text           = $body
        }
    }
    [pscustomobject]@{
        Matched        = $true
        HeadingMatched = $true
        Text           = ($lines[$headingIndices[0]..($lines.Count - 1)] -join "`n").Trim()
    }
}

# Reviewer output that failed participation or had no pooling heading. Kept SEPARATE
# from the pooled set so an unheaded substantive reply reaches the judge without buying
# a finding id or consensus vote.
# Withholding it from the JUDGE is a different question, and the answer is no — measured
# 2026-08-16, a run
# discarded three substantive anthropic reviews on formatting alone (prose lead-in, and
# verdicts written `**F1** ... AGREE` instead of line-initial `F1:`), which left that
# chunk's cross-examination with no anthropic vote at all. The judge gets the text,
# clearly labelled and excluded from every tally.
$script:offContract = @()
$script:roundAttempts = @{}
# Per participating Phase-2 reviewer: pooled ids it verdicted, and the ids it abstained on.
$script:p2Coverage = @{}

function Get-FailedPhaseCount([object[]] $Attempts, [string] $ReviewerId) {
    @($Attempts | Where-Object {
        $_.Id -eq $ReviewerId -and ($_.Exit -ne 0 -or [string]::IsNullOrWhiteSpace($_.Out))
    }).Count
}

function Invoke-Round([string] $phaseLabel, [string] $startPattern, [bool] $withFindings, [string[]] $ExpectedFIds = @()) {
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
            RunIdentity    = $runIdentity
            PhaseLabel     = $phaseLabel
        }
    }

    # A reused WorkDir must not lend this round evidence from an earlier attempt.
    foreach ($j in $jobs) {
        Remove-Item -LiteralPath $j.OutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $WorkDir ("usage-{0}-{1}.json" -f $j.Id, $phaseLabel)) -Force -ErrorAction SilentlyContinue
    }

    Write-Host "[$phaseLabel] running $($jobs.Count) reviewers: $(($jobs.Label) -join ', ') (timeout ${RoundTimeoutSeconds}s)"
    # -TimeoutSeconds bounds the round. Reviewers that have already returned are kept; any still
    # running when it expires are stopped, produce no output, and fall through the existing
    # "FAILED - degrading" branch below. Errors from stopped iterations are collected rather than
    # thrown so one wedged slot degrades to unavailable instead of aborting the whole phase.
    # -ErrorAction is NOT accepted in the Parallel parameter set (nor WarningAction,
    # InformationAction or PipelineVariable), so the script-level 'Stop' has to be relaxed around
    # the call instead: a timeout raises a non-terminating error that would otherwise abort the
    # whole phase, which is the opposite of degrade-and-continue.
    $timeoutErrors = @()
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $results = $jobs | ForEach-Object -ThrottleLimit $MaxParallel -TimeoutSeconds $RoundTimeoutSeconds -ErrorVariable +timeoutErrors -Parallel {
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
        $evidenceInput = "$($j.RunIdentity)`n$($j.Id)`n$($j.Vendor)`n$($j.PhaseLabel)`n$($j.OutFile)`n$out"
        $evidenceFingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($evidenceInput))).ToLowerInvariant()
        [pscustomobject]@{ Id = $j.Id; Label = $j.Label; Vendor = $j.Vendor; OutFile = $j.OutFile; Out = $out; Exit = $ec; ElapsedMs = $sw.ElapsedMilliseconds; Degraded = $degraded; RunIdentity = $j.RunIdentity; EvidenceFingerprint = $evidenceFingerprint }
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $script:roundAttempts[$phaseLabel] = @($results)

    # Say so loudly. A timed-out reviewer is indistinguishable downstream from one that failed
    # fast, and the difference matters: it means the round was cut short, not that a vendor
    # declined. Name the slots that never reported so the shortfall is attributable.
    # FILTERED to the timeout record. `-ErrorVariable +timeoutErrors` collects every
    # non-terminating error raised inside the parallel block, and $ErrorActionPreference
    # is relaxed to Continue around the call -- so any unrelated non-terminating error
    # produced a timeout warning naming "reviewers that did not report" when the round had
    # not timed out at all.
    # `PSTaskException` is what `ForEach-Object -Parallel` actually records for a
    # -TimeoutSeconds stop; nothing in that FQID says "timeout". Matching only on the word
    # meant a REAL timeout fell through to the branch below and was reported as "N
    # non-terminating error(s) ... none of them a timeout", while the warning that names
    # the reviewers which never reported never fired - the one message this block exists
    # to produce. (CodeRabbit, PR #135.)
    $realTimeouts = @($timeoutErrors | Where-Object {
        $_.FullyQualifiedErrorId -match '(?i)timeout|PSTaskException' -or
        $_.Exception.Message -match '(?i)\btimed? ?out\b'
    })
    if ($timeoutErrors.Count -gt 0 -and $realTimeouts.Count -eq 0) {
        Write-Warning ("[$phaseLabel] $($timeoutErrors.Count) non-terminating error(s) inside the parallel " +
            "round, none of them a timeout: $(($timeoutErrors | ForEach-Object { $_.Exception.Message }) -join ' | ')")
    }
    if ($realTimeouts.Count -gt 0) {
        $reported = @($results | ForEach-Object { $_.Id })
        $missing = @($jobs | Where-Object { $_.Id -notin $reported } | ForEach-Object { "$($_.Id) ($($_.Label))" })
        Write-Warning ("[$phaseLabel] round hit the ${RoundTimeoutSeconds}s timeout; " +
            "$($missing.Count) reviewer(s) did not report: $($missing -join ', '). " +
            'They are treated as unavailable. Raise -RoundTimeoutSeconds if the diff is genuinely large.')
    }

    $ok = @()
    foreach ($res in $results) {
        $owner = @($jobs | Where-Object { $_.Id -ceq $res.Id -and $_.Vendor -ceq $res.Vendor })
        $expectedOutFile = Join-Path $WorkDir ("{0}-{1}.txt" -f $phaseLabel, $res.Id)
        # What this fingerprint does and does not prove, stated because the shape
        # invites over-reading: it is recomputed from the fields it compares, so it can
        # NEVER detect a lying reviewer or a doctored output file - the reviewer's own
        # text is one of the inputs. Its whole scope is the runspace boundary. The two
        # inputs that are not the result's own are $runIdentity and $phaseLabel, taken
        # from THIS scope while the producer used the job's ($j.RunIdentity,
        # $j.PhaseLabel), so a record built for another run or another phase fails here.
        # Everything else it covers is redundant with the explicit comparisons below and
        # is kept only because a single hash is cheaper than restating them.
        $evidenceInput = "$runIdentity`n$($res.Id)`n$($res.Vendor)`n$phaseLabel`n$($res.OutFile)`n$($res.Out)"
        $expectedEvidenceFingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($evidenceInput))).ToLowerInvariant()
        if ($owner.Count -ne 1 -or $res.OutFile -cne $expectedOutFile -or
            $res.RunIdentity -cne $runIdentity -or $res.EvidenceFingerprint -cne $expectedEvidenceFingerprint) {
            Write-Warning "[$phaseLabel] rejected output with mismatched run/reviewer/vendor/phase provenance: $($res.Id)/$($res.Vendor) -> $($res.OutFile)"
            continue
        }
        if ($res.Exit -ne 0 -or [string]::IsNullOrWhiteSpace($res.Out)) {
            Write-Warning "[$phaseLabel] reviewer $($res.Id) ($($res.Label)) FAILED (exit $($res.Exit)) — degrading."
            Set-Content -LiteralPath $res.OutFile -Value "[reviewer unavailable: exit $($res.Exit)]`n$($res.Out)" -Encoding utf8
        }
        else {
            if ($res.Degraded) {
                Write-Warning "[$phaseLabel] reviewer $($res.Id) ($($res.Label)) degraded to API fallback — the subscription-backed CLI failed."
            }
            $stripped = Strip-Preamble $res.Out $startPattern
            Set-Content -LiteralPath $res.OutFile -Value $stripped.Text -Encoding utf8
            if (-not $stripped.Matched) {
                Write-Warning ("[$phaseLabel] reviewer $($res.Id) ($($res.Label)) produced output with no '$startPattern' " +
                    'section and no non-empty on-topic reply — refusal or off-contract. NOT counted as a participating vendor; ' +
                    'text still forwarded to the judge as unpooled.')
                Set-Content -LiteralPath $res.OutFile -Value "[reviewer off-contract: no '$startPattern' match]`n$($stripped.Text)" -Encoding utf8
                $script:offContract += [pscustomobject]@{
                    Phase = $phaseLabel; Id = $res.Id; Label = $res.Label
                    Vendor = $res.Vendor; Participating = $false; Text = $stripped.Text
                }
                continue
            }
            # Phase 2 coverage is read off VERDICT LINES (F-id + contract keyword), never a
            # bare mention: "F12 and F13 both look right" is not a vote, and counting it
            # would read silence as coverage. Coverage stays advisory (a verdict-less
            # on-topic reply keeps the broad participation rule), but each uncovered id
            # becomes an explicit per-reviewer abstention in status.json and the judge
            # packet, so a consensus tag cannot rest on one vote plus untracked silence.
            if ($ExpectedFIds -and $ExpectedFIds.Count -gt 0) {
                $verdictedIds = @([regex]::Matches($stripped.Text, "(?im)$script:P2VerdictLine") |
                    ForEach-Object { ([regex]::Match($_.Value, '(?i)F\d+')).Value.ToUpperInvariant() } |
                    Sort-Object -Unique)
                $coveredIds = @($ExpectedFIds | Where-Object { $_ -in $verdictedIds })
                # Verdicts that name NO pooled id ('F99: AGREE') vote on nothing in this
                # pool: positive evidence the reply is about something else. Off-contract.
                if ($verdictedIds.Count -gt 0 -and $coveredIds.Count -eq 0) {
                    Write-Warning ("[$phaseLabel] reviewer $($res.Id) ($($res.Label)) verdicts named no pooled finding id " +
                        "(got $($verdictedIds -join ', '); expected $($ExpectedFIds -join ', ')). NOT counted as a participating vendor; " +
                        'text still forwarded to the judge as unpooled.')
                    Set-Content -LiteralPath $res.OutFile -Value "[reviewer off-contract: no verdict for any pooled finding id]`n$($stripped.Text)" -Encoding utf8
                    $script:offContract += [pscustomobject]@{
                        Phase = $phaseLabel; Id = $res.Id; Label = $res.Label
                        Vendor = $res.Vendor; Participating = $false; Text = $stripped.Text
                    }
                    continue
                }
                $script:p2Coverage[$res.Id] = [ordered]@{
                    covered   = $coveredIds
                    abstained = @($ExpectedFIds | Where-Object { $_ -notin $coveredIds })
                }
                if ($coveredIds.Count -lt [math]::Ceiling($ExpectedFIds.Count / 2)) {
                    Write-Warning "[$phaseLabel] reviewer $($res.Id) ($($res.Label)) verdicted only $($coveredIds.Count) of $($ExpectedFIds.Count) pooled findings."
                }
            }
            if (-not $stripped.HeadingMatched) {
                Write-Warning "[$phaseLabel] reviewer $($res.Id) ($($res.Label)) returned a non-empty on-topic reply without a pooling heading — counted as participating, forwarded unpooled."
                $script:offContract += [pscustomobject]@{
                    Phase = $phaseLabel; Id = $res.Id; Label = $res.Label
                    Vendor = $res.Vendor; Participating = $true; Text = $stripped.Text
                }
            }
            $ok += $res
        }
    }
    , $ok
}

# --- Phase 1 -------------------------------------------------------------
# Pooling patterns tolerate leading whitespace, list markers and markdown emphasis. The strict
# line-initial forms discarded substantive reviews on formatting alone -- twice now. The comment
# above $offContract records 2026-08-16 (three anthropic reviews, `**F1** ... AGREE`); it happened
# again on 2026-08-17, when a reviewer wrote `**F1: FALSE POSITIVE**` and its whole
# repository-backed cross-examination was excluded from the participating-vendor count, leaving
# status.json reporting four Phase-2 vendors where five reviewers had taken part. Forwarding the
# text to the judge limited the damage but left every consensus tally wrong for that chunk.
#
# ONE parser for pooling and issuesRaised. Participation is deliberately broader: any
# non-empty non-refusal reply counts, while this pattern decides which text becomes a
# pooled finding. That separates "vendor answered" from "vendor raised a finding".
$script:FindingHeading = '(?:^\s*(?:[-*+]\s+)?(?:\*\*|__)?|[.!?]\s*)(?:\*\*|__)?#{1,6}\s'
# The brief tells a reviewer with nothing to report to say so under this heading. A
# clean review is a RESULT; without a recognised form for it the panel was structurally
# unable to return "clean" and an all-clean round died on "no reviewer produced Phase 1
# findings", making a defect-free diff indistinguishable from a broken run.
#
# The heading must BE the phrase, not merely start with it. `\b` alone matched
# `### NO FINDINGS in the parser, but the writer leaks` - a finding - and the pooler then
# discarded the reviewer's entire reply while still counting it as participating. Silence
# is the wrong direction to fail in here: a "no findings" note pooled as a finding is
# visible to the judge, a discarded reviewer is not. Trailing emphasis and a full stop are
# allowed because reviewers write both.
$script:NoFindingsHeading = '\s*(?:[-*+]\s+)?(?:\*\*|__)?#{1,6}\s+(?:\*\*|__)?NO FINDINGS(?:\*\*|__)?\s*[.!]?\s*$'
# A structured Phase-1 finding field. A NO FINDINGS reply carrying one is MIXED, not
# clean: reading it as clean would drop the finding written beneath the heading while the
# reviewer counted as participating with 0 raised. Mixed replies pool instead.
$script:FindingField = '(?im)^\s*(?:[-*+]\s+)?\*\*(?:Severity|Location|Trigger|Issue):\*\*'
$p1ok = Invoke-Round 'p1' $script:FindingHeading $false
if (-not $p1ok) { Die 'No reviewer produced Phase 1 findings; cannot continue.' }
$p1Vendors = ($p1ok.Vendor | Sort-Object -Unique).Count
$p1QuorumVendors = @($p1ok | Where-Object { $_.Id -in $quorumReviewerIds } | ForEach-Object Vendor | Sort-Object -Unique).Count
if ($p1QuorumVendors -lt $minVendors) {
    # Below minVendors this is NOT an adversarial panel — a single-vendor round is
    # self-review, and the whole value of the exercise is uncorrelated error across
    # vendors. This used to be a Write-Warning and the script still exited 0, so a
    # batched caller recorded the chunk as clean and the run reported success on a
    # panel that never happened. Fail loudly instead: the caller must be able to
    # tell "reviewed by one vendor" from "reviewed properly".
    Die "Only $p1QuorumVendors vendor(s) produced Phase 1 findings (min $minVendors) — supplemental seats do not satisfy quorum. Re-run this chunk; do not judge it."
}

# --- Pool + anonymise + assign F-ids ------------------------------------
# pooled-findings.txt is attribution-stripped BY DESIGN -- Phase 2 must not know
# who raised what. Telemetry still needs the mapping to credit IssuesAccepted to
# the vendor that raised the finding, so the driver writes it to a separate file
# the judge never sees. The skill named pooled-map.json as that source while
# nothing wrote it, which is why per-vendor IssuesAccepted was published as zero.
$findingId = 0
$pooledMap = [ordered]@{}
$pool = [System.Text.StringBuilder]::new()
[void]$pool.AppendLine('# Pooled findings (attribution removed)')
[void]$pool.AppendLine()
foreach ($res in $p1ok) {
    $text = Get-Content -LiteralPath $res.OutFile -Raw
    $lines = $text -split "`r?`n"
    $block = [System.Collections.Generic.List[string]]::new()
    $flush = {
        # A NO FINDINGS block with no finding field is a clean note, not a finding: it
        # never buys an F-id, even beside real findings in a mixed reply.
        $cleanNote = $block.Count -gt 0 -and $block[0] -match $script:NoFindingsHeading -and
            ($block -join "`n") -notmatch $script:FindingField
        if ($block.Count -gt 0 -and ($block -join '').Trim() -and -not $cleanNote) {
            $script:findingId++
            # Trim a trailing horizontal-rule separator a reviewer may have placed
            # between its own findings, so it does not bleed into the pooled block.
            $body = (($block -join "`n").Trim()) -replace '(\r?\n\s*-{3,}\s*)+$', ''
            [void]$pool.AppendLine("## F$script:findingId")
            [void]$pool.AppendLine($body.Trim())
            [void]$pool.AppendLine()
            $script:pooledMap["F$script:findingId"] = [ordered]@{
                reviewer = $res.Id
                label    = $res.Label
                vendor   = $res.Vendor
            }
        }
        $block.Clear()
    }
    # An explicit "no findings" reply is PARTICIPATION with zero findings, not a finding.
    # The brief asks for it as a heading precisely so it passes the participation gate;
    # pooling it would send "I found nothing" to cross-examination as F1.
    # The NO FINDINGS heading must be the ONLY heading in the reply. Matching it anywhere
    # discarded every finding a reviewer raised whenever one of its own headings happened
    # to begin with that phrase - `### NO FINDINGS in the parser, but the writer leaks` is
    # a finding, and `-match` is case-insensitive and needs only the prefix. The reviewer
    # still counted as participating and pooled-map.json got no entry for it, so the whole
    # contribution vanished with nothing but a "0 findings" line to show for it. Silent
    # evidence loss in the one direction this pooler exists to prevent. (CodeRabbit, #135.)
    $headingIndices = @(Get-ReviewHeadingLineNumbers -Lines $lines -Pattern $script:FindingHeading)
    $headings = @($headingIndices | ForEach-Object { $lines[$_] })
    $noFindingsHeadings = @($headings | Where-Object { $_ -match $script:NoFindingsHeading })
    $noFindings = $noFindingsHeadings.Count -gt 0 -and $noFindingsHeadings.Count -eq $headings.Count -and
        $text -notmatch $script:FindingField
    if ($noFindingsHeadings.Count -gt 0 -and -not $noFindings) {
        Write-Warning "[pool] reviewer $($res.Id) ($($res.Label)) mixed NO FINDINGS with finding content — pooled as findings, not counted clean."
    }
    if ($noFindings) {
        Write-Host "[pool] reviewer $($res.Id) ($($res.Label)) reported NO FINDINGS - counted as participating with 0 findings."
        continue
    }
    # Everything between one heading and the next belongs to the first, so narration a
    # reviewer writes BETWEEN its findings ("that's the last one - want me to go
    # deeper?") is pooled as part of the preceding finding. That is markdown's own
    # rule, and it is left alone deliberately: the heading is the only signal
    # available, so any heuristic that trimmed trailing prose would sooner or later
    # trim a finding's Impact or Suggested fix. Cosmetic noise inside one finding is a
    # cheaper failure than evidence deleted before the judge ever sees it. Preamble
    # BEFORE the first heading is a different case, and Strip-Preamble handles it.
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $ln = $lines[$lineIndex]
        $isHeading = $lineIndex -in $headingIndices
        if ($isHeading) { & $flush }
        if ($isHeading -or $block.Count -gt 0) { $block.Add($ln) }
    }
    & $flush
}
Set-Content -LiteralPath $pooledFile -Value ($pool.ToString().TrimEnd()) -Encoding utf8
# ConvertTo-Json on an EMPTY ordered dictionary emits '{}', which is the honest
# record of a pool with no findings -- not an omitted file the aggregator would
# then have to guess about.
[ordered]@{ runId = (Split-Path -Leaf $WorkDir); findings = $pooledMap } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pooledMapFile -Encoding utf8
Write-Host "Pooled $findingId findings into $(Split-Path -Leaf $pooledFile) (attribution in $(Split-Path -Leaf $pooledMapFile))"

# --- Phase 2 -------------------------------------------------------------
# `1..0` is a DESCENDING range in PowerShell, not an empty one, so an empty pool would
# yield @('F1','F0') and warn about findings that do not exist.
$expectedFIds = if ($findingId -gt 0) { @(1..$findingId | ForEach-Object { "F$_" }) } else { @() }
# A BARE F-number must be followed by punctuation (`F1:`, `F3.`, `F9)`); only an EMPHASISED one
# may be separated by whitespace, which is what `**F12** ... AGREE` needs. Allowing bare
# `F\d+\s` matched prose such as "F12 and F13 both agree" and "F5 findings were raised", which
# would admit narration as though it were a verdict block.
# An all-clean panel has nothing to cross-examine, and that is a RESULT: every reviewer
# participated and none found a defect. Running Phase 2 over an empty pool would spend a
# paid round on nothing and then die on "no reviewer produced cross-examinations",
# reporting a clean diff as a broken run.
if ($findingId -eq 0) {
    Write-Host ''
    Write-Host "CLEAN: $($p1ok.Count) reviewer(s) across $p1Vendors vendor(s) participated in Phase 1 and none raised a finding."
    Write-Host 'Phase 2 skipped: there is nothing to cross-examine. This is a clean result, not a failure.'
    $p2ok = @()
    $p2Vendors = $p1Vendors
    $p2QuorumVendors = $p1QuorumVendors
}
else {
# The verdict START (a line-initial, optionally emphasised F-id) is also the first
# alternative of the Phase-2 start pattern below; verify-start-patterns.ps1 pins the two
# together. A verdict LINE additionally carries a contract keyword from
# briefs/phase2-cross-examine.txt (NEEDS REPO is the brief's no-repo-access answer),
# word-bounded so 'disagree' never reads as AGREE.
$script:P2VerdictStart = '^\s*(?:[-*+]\s+)?(?:\*\*|__|\*|_)?F\d+(?:(?:\*\*|__|\*|_)\s*[:.\)\s]|\s*[:.\)])'
$script:P2VerdictLine = "$script:P2VerdictStart[^\r\n]*?\b(?:AGREE|FALSE\s+POSITIVE|NEEDS\s+EVIDENCE|NEEDS\s+REPO)\b"
$p2ok = Invoke-Round 'p2' '^\s*(?:[-*+]\s+)?(?:\*\*|__|\*|_)?F\d+(?:(?:\*\*|__|\*|_)\s*[:.\)\s]|\s*[:.\)])|^\s*(?:[-*+]\s+)?(?:\*\*|__)?#{1,6}\s' $true $expectedFIds
if (-not $p2ok) { Die 'No reviewer produced Phase 2 cross-examinations; cannot continue.' }
$p2Vendors = ($p2ok.Vendor | Sort-Object -Unique).Count
$p2QuorumVendors = @($p2ok | Where-Object { $_.Id -in $quorumReviewerIds } | ForEach-Object Vendor | Sort-Object -Unique).Count
if ($p2QuorumVendors -lt $minVendors) {
    Die "Only $p2QuorumVendors vendor(s) produced Phase 2 cross-examinations (min $minVendors) — supplemental seats do not satisfy quorum. Re-run this chunk; do not judge it."
}
}

# --- Per-chunk reviewer metrics (telemetry) -----------------------------
# Write metrics.json so a batched run can be aggregated per participant across
# chunks (aggregate-and-emit.ps1). Covers the THREE reviewers' deterministic
# outcome: issuesRaised (### count) + cost/duration. The judge (synthesis) and
# issuesAccepted are products of adjudication and are recorded separately in
# aggregate-verdict.json at synthesis time. Best-effort: a failure here must
# never fail the review, so the whole block is guarded.
$modelRegistryPath = Join-Path (Split-Path $scriptDir -Parent) 'model-registry' 'registry.json'
$modelPriceHelper = Join-Path (Split-Path $modelRegistryPath -Parent) 'price.ps1'
$modelPriceAvailable = Test-Path -LiteralPath $modelPriceHelper
if ($modelPriceAvailable) { . $modelPriceHelper }
$modelPriceOn = $env:MODEL_REGISTRY_EFFECTIVE_DATE ?? (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
# Every resolution failure below WARNS naming the model, vendor and registry path. Each
# one used to fail silently, so a stale, corrupt or unpriced registry reproduced the
# fragmenting-alias dashboard bug this resolution exists to fix, with no log line saying
# why. The contract permits these outcomes; it does not permit the silence.
$modelRegistry = if (Test-Path -LiteralPath $modelRegistryPath) {
    try { Get-Content -LiteralPath $modelRegistryPath -Raw | ConvertFrom-Json -AsHashtable }
    catch {
        # A corrupt registry must not read as an absent one.
        Write-Warning "Model registry at $modelRegistryPath is unreadable ($($_.Exception.Message)); cost will be recorded as UNKNOWN."
        $null
    }
} else {
    Write-Warning "Model registry not found at $modelRegistryPath; cost will be recorded as UNKNOWN."
    $null
}
function Resolve-TelemetryModel([object] $reviewer) {
    # Seat resolution already produced the canonical registry id; telemetry uses it
    # directly. This used to run the mapping BACKWARDS, guessing an id from the bare
    # alias the manifest carried, and it could only ever guess for Anthropic - every
    # other vendor's row fragmented on whatever string reviewers.json happened to hold.
    # A pinned seat still yields its literal, which may be unpriceable; that is the
    # pin's cost, and Get-BlendedRatePerMillion says so out loud.
    return [string]($reviewer.resolvedModel ?? $reviewer.model)
}
function Get-BlendedRatePerMillion([string] $model) {
    if (-not $modelPriceAvailable -or -not $modelRegistry) { return $null }
    if (-not $modelRegistry.models.ContainsKey($model)) {
        Write-Warning "Model '$model' is absent from $modelRegistryPath; cost is UNKNOWN, not zero."
        return $null
    }
    $facts = $modelRegistry.models[$model]
    $price = Get-ModelRegistryPrice -Facts $facts -Channel api -On $modelPriceOn
    if ($null -eq $price) {
        Write-Warning "Model '$model' has no sourced API price effective $modelPriceOn in $modelRegistryPath; cost is UNKNOWN, not zero."
        return $null
    }
    return (0.75 * [double]$price.price_in) + (0.25 * [double]$price.price_out)
}
# Exact where the split is KNOWN. A blended rate is a stand-in for an unknown in/out mix;
# applying it to ($inTok + $outTok) when both are tracked separately charges every input
# token at 0.25 x price_out. Returns $null when the model is unpriced so the caller can
# record unknown rather than 0.0.
function Get-ExactCostUsd([string] $model, [long] $inTok, [long] $outTok) {
    if (-not $modelPriceAvailable -or -not $modelRegistry -or -not $modelRegistry.models.ContainsKey($model)) { return $null }
    $facts = $modelRegistry.models[$model]
    try {
        return Get-ModelRegistryCost -Facts $facts -InputTokens $inTok -OutputTokens $outTok -Channel api -On $modelPriceOn
    }
    catch {
        Write-Warning "Registry pricing for '$model' is unusable ($($_.Exception.Message)); cost is UNKNOWN and metrics will still be written."
        return $null
    }
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

        # Raised = what this reviewer actually POOLED, read off pooled-map provenance.
        # Re-counting headings in the phase file disagreed with the pooler whenever a
        # NO FINDINGS reply was mixed with finding content (pooled 1, counted 0).
        $raised = @($pooledMap.Values | Where-Object { $_.reviewer -eq $r.id }).Count

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
        $telemetryModel = Resolve-TelemetryModel $r

        if ($phasesRun -eq 0) {
            [ordered]@{
                reviewer         = $r.vendor
                role             = 'reviewer'
                model            = $telemetryModel
                inputTokens      = 0
                outputTokens     = 0
                costUsd          = 0.0
                costEstimated    = $false
                costUnknown      = $true
                failed           = $true
                failedPhases     = 2
                participation    = 'failed'
                degraded         = $degraded
                reviewDurationMs = $durationMs
                issuesRaised     = 0
            }
        }
        else {
            # "Cost unknown" and "cost measured as ~0" are different facts and must not
            # both render as 0.0. Sidecars measure tokens; registry pricing may be unknown.
            $costUnknown = $false
            if ($sidecars) {
                $inTok  = [long]($sidecars | Measure-Object -Property inputTokens  -Sum).Sum
                $outTok = [long]($sidecars | Measure-Object -Property outputTokens -Sum).Sum
                $cost   = [double]($sidecars | Measure-Object -Property costUsd     -Sum).Sum
                $costUnknown = @($sidecars | Where-Object { $_.costUnknown }).Count -gt 0
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
                # Both counts are proxies, but they ARE tracked separately, so price them
                # separately. The blended rate is only a stand-in for an unknown split.
                $cost = Get-ExactCostUsd $telemetryModel $inTok $outTok
                if ($null -eq $cost) {
                    $rate = Get-BlendedRatePerMillion $telemetryModel
                    if ($null -ne $rate) { $cost = ($inTok + $outTok) * $rate / 1e6 }
                }
                $costUnknown = ($null -eq $cost)
                if ($costUnknown) { $cost = 0.0 }
                $estimated = $true
            }

            [ordered]@{
                reviewer         = $r.vendor
                role             = 'reviewer'
                model            = $telemetryModel
                inputTokens      = $inTok
                outputTokens     = $outTok
                costUsd          = [Math]::Round($cost, 6)
                costEstimated    = $estimated
                costUnknown      = $costUnknown
                failed           = $false
                failedPhases     = Get-FailedPhaseCount -Attempts (@($script:roundAttempts['p1']) + @($script:roundAttempts['p2'])) -ReviewerId $r.id
                participation    = if (@(@($p1res, $p2res) | Where-Object { $_ -and $_.Exit -eq 0 }).Count -gt 0) { 'partial or complete' } else { 'failed' }
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
$compactNote = if ($compactDiffFile) { " · compact diff: $($repoBlindIds -join '+')" } else { '' }
[void]$packet.AppendLine("Target: ``$($Target ? $Target : '(branch vs base)')`` · added lines: $addedLines · total lines: $totalLines · est. tokens: $estTokens$compactNote · audit: $isAudit")
if ($dirtyPaths.Count -gt 0) {
    $omission = if ($isTreeToTree) { 'excluded by this tree-to-tree target' } else { 'untracked and omitted from this working-tree-inclusive target' }
    [void]$packet.AppendLine("NOT REVIEWED — $($dirtyPaths.Count) uncommitted path(s) $($omission): $(($dirtyPaths | Select-Object -First 30) -join ', ')")
}
[void]$packet.AppendLine("Reviewers (Phase 1): $(($p1ok.Label) -join ', ')")
[void]$packet.AppendLine()
[void]$packet.AppendLine('Adjudicate with `briefs/phase3-adjudicate.txt` (copied here as `phase3-brief.txt`).')
[void]$packet.AppendLine('Then verify every Critical, every High and every contested finding with `briefs/phase4-verify.txt` (Phase 4) before publishing; each verdict goes in the finding''s **Verification** line.')
[void]$packet.AppendLine('The diff under review is `review-diff.txt`; read the repo to settle contested mechanisms.')
if ($supplementalIds.Count) {
    [void]$packet.AppendLine("Supplemental reviewers: $($supplementalIds -join ', '). Their evidence participates in review, but they do not satisfy the required vendor quorum or serve as judge/verifier.")
}
if ($skippedSupplementalIds.Count) {
    [void]$packet.AppendLine("Supplemental reviewers skipped after missing or unsuccessful preflight: $($skippedSupplementalIds -join ', ').")
}
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
    $cov = $script:p2Coverage[$res.Id]
    if ($cov -and $cov.abstained.Count -gt 0) {
        # Considered silence, recorded: do not read a [unanimous]/[majority] tag as
        # carrying this vendor's vote on these ids.
        [void]$packet.AppendLine()
        [void]$packet.AppendLine("Abstained (no verdict recorded): $($cov.abstained -join ', ')")
    }
    [void]$packet.AppendLine()
    [void]$packet.AppendLine((Get-Content -LiteralPath $res.OutFile -Raw).TrimEnd())
}
if ($script:offContract.Count -gt 0) {
    [void]$packet.AppendLine()
    [void]$packet.AppendLine('---')
    [void]$packet.AppendLine('## Unpooled — off-contract reviewer output')
    [void]$packet.AppendLine()
    [void]$packet.AppendLine('These replies were not pooled because they lacked a finding heading or voted only on ids outside the pool.')
    [void]$packet.AppendLine('Non-empty on-topic replies still count as participating vendors; refusals')
    [void]$packet.AppendLine('and other off-contract replies do not. None of these replies carry F-ids.')
    [void]$packet.AppendLine('Read them, weigh them on their merits, and fold anything substantive into')
    [void]$packet.AppendLine('the adjudication — but never promote unpooled text to a pooled consensus vote.')
    foreach ($oc in $script:offContract) {
        [void]$packet.AppendLine()
        [void]$packet.AppendLine("### Unpooled $($oc.Phase) — Reviewer $($oc.Id) ($($oc.Label), $($oc.Vendor))")
        [void]$packet.AppendLine()
        [void]$packet.AppendLine($oc.Text.TrimEnd())
    }
}
$packetFile = Join-Path $WorkDir 'judge-packet.md'
Set-Content -LiteralPath $packetFile -Value ($packet.ToString().TrimEnd()) -Encoding utf8

# --- Status --------------------------------------------------------------
$status = [ordered]@{
    state           = 'complete'
    runIdentity     = $runIdentity
    resolvedTarget  = $resolvedTargetIdentity
    diffSha256      = $diffSha256
    compactDiffSha256 = $compactDiffSha256
    repo            = $repoName
    repoPath        = $RepoPath
    target          = $Target
    audit           = $isAudit
    uncommittedExcluded = $dirtyPaths
    workingTreePatch    = $workingTreePatchFile
    workingTreeSha256   = $workingTreeSha256
    preflightEvidence   = $preflightFile
    addedLines      = $addedLines
    totalLines      = $totalLines
    estTokens       = $estTokens
    compactDiff     = $compactDiffFile
    workDir         = $WorkDir
    diffFile        = $diffFile
    pooledFile      = $pooledFile
    pooledMapFile   = $pooledMapFile
    judgePacket     = $packetFile
    pooledCount     = $findingId
    offContract     = @($script:offContract | ForEach-Object { @{ phase = $_.Phase; id = $_.Id; vendor = $_.Vendor } })
    phase1Reviewers = @($p1ok | ForEach-Object { @{ id = $_.Id; label = $_.Label; vendor = $_.Vendor } })
    phase2Reviewers = @($p2ok | ForEach-Object { @{ id = $_.Id; label = $_.Label; vendor = $_.Vendor } })
    # Per participating Phase-2 reviewer, the pooled ids it recorded NO verdict on.
    phase2Abstentions = @($p2ok | ForEach-Object {
            $cov = $script:p2Coverage[$_.Id]
            @{ id = $_.Id; vendor = $_.Vendor; abstained = @($cov ? $cov.abstained : @()) }
        })
    vendorsP1       = $p1Vendors
    vendorsP2       = $p2Vendors
    quorumVendorsP1 = $p1QuorumVendors
    quorumVendorsP2 = $p2QuorumVendors
    supplementalReviewers = $supplementalIds
    skippedSupplementalReviewers = $skippedSupplementalIds
    expiredReviewers = $expiredReviewers
    nextSteps       = @('adjudicate (phase3-brief.txt)', 'verify every Critical, High and contested finding (phase4-verify.txt)', 'synthesise if multi-chunk', 'persist to vault')
}
$status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusFile -Encoding utf8

Write-Host ''
Write-Host '==== adversarial-review spine complete ===='
Write-Host "Work dir:     $WorkDir"
Write-Host "Pooled:       $findingId findings ($pooledFile)"
Write-Host "Judge packet: $packetFile"
Write-Host "Next: adjudicate -> verify -> [synthesise] -> persist (see status.json / SKILL.md)."
$status | ConvertTo-Json -Depth 6

# Observatory telemetry: wrapper sidecars carry usage where available and
# explicit zeros where a subscription CLI (agy/kimi) does not expose it.
