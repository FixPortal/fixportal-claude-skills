#requires -Version 7
<#
.SYNOPSIS
Collects adversarial-review coverage per repository: usable reviews, the files each still covers,
commits since each, and a DRIFT score. Read-only over repositories and the vault.
Score counts commits since a usable review, weighted by its age (changed files, after a history
reset). Source no usable run covers is reported but not scored while the repository has some
usable review: reviews here are targeted at new work. A repository with source and NO usable
review is queued first unless it is on the exemption list (vendored forks and the like).
.DESCRIPTION
A vault run (<VaultRoot>\<folder>\<run>\_index.md) attaches to a scanned repository when the folder
name equals the repository folder name or the index carries `repo-path:` naming it. A run is USABLE
when its frontmatter has `date: yyyy-MM-dd`, `target: <base>..<tip>` (a `..HEAD` right side is
allowed only with `head: <sha>`), a tip on the repository's HEAD ancestry, `scope-kind` of
repository or subsystem (missing means repository unless paths are declared), and for subsystem a
`reviewed-paths:` (or legacy `subsystem:`) list matching files at the tip. A run covers the files
its target range changed within its paths; an empty-tree base covers every file at the tip.
Each tracked file belongs to the newest usable run covering it. Everything else is `unusable`
with a reason or `uncovered`; neither is evidence of no review. A run carrying a
`coverage-waiver: <reason>` is `coverage-waived` - its author read it, found its coverage
unreconstructable, and said so in the record; it is reported apart from the unreadable ones.
A waived record that would otherwise be usable is `coverage-waiver-conflicts-with-target`.
#>
[CmdletBinding()]
param(
    # No hardcoded default: the estate root is machine-local and must be supplied explicitly.
    [string[]]$Path,
    # Mandatory: $env:TEMP is unset off Windows, and a fixed name lets one run overwrite another's snapshot.
    [Parameter(Mandatory)][string]$OutFile,
    # No hardcoded default: the vault path is machine-local and must be supplied explicitly.
    [string]$VaultRoot,
    # Repositories (canonical origin name or folder name) deliberately never reviewed: vendored
    # forks, generated databases, second checkouts. They are scanned and reported but never
    # ranked as missing a review.
    [string[]]$Exempt = @(),
    # JSON { paths, vaultRoot, exempt: [{ repo, reason }] } holding the estate's scope once, so
    # the scan roots and exemptions are not retyped per run. Explicit parameters win.
    [string]$EstateFile
)
$exemptReason = @{}
if ($PSBoundParameters.ContainsKey('Exempt')) { foreach ($e in $Exempt) { $exemptReason[$e] = '' } }
if ($EstateFile) {
    $estate = Get-Content -LiteralPath $EstateFile -Raw | ConvertFrom-Json
    if (-not $Path) { $Path = @($estate.paths | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }) }
    if (-not $VaultRoot) { $VaultRoot = $estate.vaultRoot }
    if (-not $PSBoundParameters.ContainsKey('Exempt')) { foreach ($e in @($estate.exempt)) { if ($e.repo) { $exemptReason[$e.repo] = "$($e.reason)" } } }
}
if (-not $Path) { throw "Path is required: pass the repository or estate-root folder(s) to scan." }
if (-not $VaultRoot) { throw "VaultRoot is required: pass the vault's 'Claude\Adversarial Review' folder." }
$ErrorActionPreference = 'Stop'
$emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
# state-of-play reads this variable by name to classify source paths. Keep the name.
# Generated designer and EF model-snapshot files are not review workload.
$sourceExtRegex = '^(?!.*(?:\.Designer\.cs|ModelSnapshot\.cs)$).*(?:\.(cs|ts|tsx|js|jsx|mjs|cjs|py|go|java|rb|rs|cpp|cc|c|h|hpp|kt|swift|php|scala|sql|ps1|psm1|sh|bicep|vue|svelte|fs|fsx|razor|cshtml|xaml|tf|proto|css|scss|sass|less)$|(?:^|/)Dockerfile(?:\..+)?$|(?:^|/)\.github/workflows/[^/]+\.ya?ml$)'

# Emits git's non-empty output lines. Success with no output and failure both emit nothing;
# a caller that must tell them apart reads $LASTEXITCODE immediately after the call.
function Invoke-Git([string]$Repo, [string[]]$Arguments) {
    & git -C $Repo -c core.quotepath=false @Arguments 2>$null | Where-Object { $_ }
}
function Normalize([string]$P) { if (-not $P) { return '' } ([IO.Path]::GetFullPath($P)).TrimEnd('\', '/').ToLowerInvariant() }
function Canonical-Label([string]$Repo, [string]$Fallback) {
    $origin = @(Invoke-Git $Repo @('remote', 'get-url', 'origin'))[0]
    $name = if ($origin) { (($origin -replace '^.*[\\/]', '') -replace '\.git$', '') } else { $Fallback }
    $n = Normalize $Repo
    if ($n -eq (Normalize (Join-Path $HOME '.claude')) -or $n -eq (Normalize (Join-Path $HOME '.agents/skills'))) {
        return "$name (live home)"
    }
    if ($n -eq (Normalize (Join-Path $HOME '.agents/docs'))) { return "$name (live home; notes backing checkout)" }
    return $name
}

# A record's metadata is normally a leading `---` block. A minority of runs instead open with
# a markdown heading and carry the same keys in the first fenced ```yaml block; the writer is
# hand-driven per session, so that shape recurs. Read it as a FALLBACK, never as a preference:
# when a leading block is present it wins outright, so a yaml example quoted later in a report
# can never displace the record's own metadata. Measured 2026-09-16 over 269 vault records:
# 260 leading, 2 fenced, 7 neither. Both fenced ones were one repository's 2026-09-15 runs - the
# newest and largest review that repo has had, dropped as `no-date` and therefore invisible to
# every coverage report while sitting complete on disk.
function Read-Frontmatter([string]$File) {
    $text = Get-Content -LiteralPath $File -Raw
    $m = [regex]::Match($text, '(?s)\A\s*---\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { $m = [regex]::Match($text, '(?s)(?:\A|\r?\n)```yaml[ \t]*\r?\n(.*?)\r?\n```') }
    $fm = @{}
    if (-not $m.Success) { return $fm }
    $key = $null
    foreach ($line in $m.Groups[1].Value -split '\r?\n') {
        $line = $line -replace '\s+#.*$', ''
        if ($line -match '^([A-Za-z][\w-]*):\s*(.*)$') {
            $key = $Matches[1]; $value = $Matches[2].Trim()
            if ($value -match '^\[(.*)\]$') { $fm[$key] = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'", '`') } | Where-Object { $_ }) }
            elseif ($value) {
                # A quoted scalar is one literal value; `quoted:` cannot collide with a key, which starts with a letter.
                if ($value -match '^(["''`]).*\1$') { $fm["quoted:$key"] = $true }
                $fm[$key] = $value.Trim('"', "'", '`')
            }
            else { $fm[$key] = @() }
        } elseif ($key -and $line -match '^\s*-\s*(.*)$') {
            $fm[$key] = @($fm[$key]) + @($Matches[1].Trim().Trim('"', "'", '`'))
        }
    }
    $fm
}

# The commit a recorded sha names on HEAD's history. Rebase-merge rewrites a reviewed branch
# tip, so a sha off HEAD resolves to the one commit on HEAD with the identical tree; anything
# less exact is 'off-head'. Nothing is returned when the repository has no such object.
function Resolve-OnHead([string]$Repo, [string]$Head, [string]$Sha) {
    $commit = @(Invoke-Git $Repo @('rev-parse', '--verify', "$Sha^{commit}"))[0]
    if (-not $commit) { return }
    $null = Invoke-Git $Repo @('merge-base', '--is-ancestor', $commit, $Head)
    if ($LASTEXITCODE -eq 0) { return $commit }
    $tree = @(Invoke-Git $Repo @('rev-parse', "$commit^{tree}"))[0]
    $same = @(Invoke-Git $Repo @('log', '--format=%H %T', $Head) | Where-Object { $_.EndsWith(" $tree") })
    if (-not $same.Count) { return 'off-head' }
    ($same[0] -split ' ')[0]
}

# The rebased copy of an off-HEAD commit: the commit on HEAD's history since the two forked
# whose patch-id equals its own. Nothing is returned when there is no such commit.
function Find-PatchTwin([string]$Repo, [string]$Head, [string]$Commit) {
    $forked = @(Invoke-Git $Repo @('merge-base', $Commit, $Head))[0]
    if (-not $forked) { return }
    $id = @(& git -C $Repo -c core.quotepath=false show --no-color $Commit 2>$null | & git -C $Repo patch-id --stable 2>$null)[0]
    if (-not $id) { return }
    $id = ($id -split ' ')[0]
    # Newest first; the oldest match is the first application of the patch.
    $twins = @(& git -C $Repo -c core.quotepath=false log -p --no-color --no-merges "$forked..$Head" 2>$null | & git -C $Repo patch-id --stable 2>$null | Where-Object { $_ -like "$id *" })
    if ($twins.Count) { ($twins[-1] -split ' ')[1] }
}

# True when EVERY reviewed commit off HEAD has a patch-id copy on HEAD since the fork: the whole
# reviewed branch reached mainline by rebase. A `reviewed` record has no remediation-tip to prove
# the merge, so its tip's copy alone is not enough; a lone cherry-pick would credit history the
# panel never saw. Mirrored by Test-RangeTwins in adversarial-review/validate-report.ps1.
function Test-RangeTwins([string]$Repo, [string]$Head, [string]$Base, [string]$Tip) {
    $exclude = @(if ($Base -ne $emptyTree) { "^$Base" })
    $offHead = @(Invoke-Git $Repo (@('rev-list', '--no-merges', $Tip) + $exclude + @("^$Head")))
    if (-not $offHead.Count) { return $false }
    $forked = @(Invoke-Git $Repo @('merge-base', $Tip, $Head))[0]
    if (-not $forked) { return $false }
    $onHead = [Collections.Generic.HashSet[string]]::new([string[]]@(& git -C $Repo -c core.quotepath=false log -p --no-color --no-merges "$forked..$Head" 2>$null | & git -C $Repo patch-id --stable 2>$null | ForEach-Object { ($_ -split ' ')[0] }))
    foreach ($commit in $offHead) {
        $id = @(& git -C $Repo -c core.quotepath=false show --no-color $commit 2>$null | & git -C $Repo patch-id --stable 2>$null)[0]
        if (-not $id -or -not $onHead.Contains(($id -split ' ')[0])) { return $false }
    }
    $true
}

function Get-Run([string]$Repo, [string]$Head, [string]$Index, [hashtable]$Fm) {
    $run = Get-RunEvidence $Repo $Head $Index $Fm
    # A run whose author has read it, decided its coverage cannot be reconstructed, and said so in
    # the record.
    #
    # It exists because the alternative is worse. Measured across the estate 2026-09-19: 269 vault
    # records, 167 of them unreadable here, 110 dated 2026-06 alone - and only FOUR were newer than
    # a usable run their repository already had, so repairing the rest would have moved no date and
    # no score. Left unmarked they are a permanent 167-record headline that a reader learns to skip,
    # which is how a genuinely broken NEW record hides among them.
    #
    # The waiver is deliberately PER RECORD and carries its reason. A date cutoff in this script
    # would have silenced the same records without any of them saying so, and would have silenced
    # a real defect written inside the same window along with them.
    #
    # It is decided AFTER the record is fully resolved, never before: a waiver conflicts only with a
    # record that would otherwise be usable. Deciding it first rejected waivers on off-HEAD tips and
    # unresolvable bases, and let a `..HEAD` target skip the conflict check. A record too malformed
    # to date is still waived, because any unusable outcome becomes `coverage-waived`.
    $waiver = "$($Fm['coverage-waiver'])"
    if (-not $waiver -or $run.reason -in @('document-review', 'superseded')) { return $run }
    if ($run.usable) {
        $run.usable = $false; $run.reason = 'coverage-waiver-conflicts-with-target'
        $run.detail = 'the target resolves to usable coverage; remove the waiver or the target'
        return $run
    }
    $run.detail = "$($run.reason)$(if ($run.detail) { ": $($run.detail)" })"
    $run.reason = 'coverage-waived'; $run.waiver = $waiver
    $run
}

function Get-RunEvidence([string]$Repo, [string]$Head, [string]$Index, [hashtable]$Fm) {
    $run = [ordered]@{
        indexPath = $Index; date = $null; scopeKind = $null; boundarySha = $null; baseSha = $null
        paths = @(); excludedPaths = @(); remediationCommits = @(); disposition = "$($Fm['disposition'])"; usable = $false; reason = $null; detail = $null; waiver = $null; files = @(); historyReset = $null
    }
    $fail = { param($Reason, $Detail) $run.reason = $Reason; $run.detail = $Detail; [pscustomobject]$run }
    $kind = "$($Fm['scope-kind'])"
    if ($kind -eq 'document') { return & $fail 'document-review' }
    # A run the author has retracted in favour of a later one. Checked BEFORE `date`, because a
    # superseded run need not be well-formed enough to date. An incomplete run is usually a re-run
    # of the same scope, so it carries the same `target` and `reviewed-paths` as its replacement:
    # left usable it competes with the good run and, on a same-date tie, can displace it. Excluding
    # it on the record's own declaration beats relying on it being too malformed to parse.
    if ("$($Fm['superseded-by'])") { return & $fail 'superseded' }
    # `coverage-waiver:` is decided by Get-Run once this evidence is resolved.
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact("$($Fm['date'])", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$date)) { return & $fail 'no-date' }
    # UTC calendar day, as the validator compares: run ids and their `date:` are written in UTC.
    if ($date.Date -gt [datetime]::UtcNow.Date) { return & $fail 'future-date' }
    $run.date = $date.ToString('yyyy-MM-dd')
    $target = "$($Fm['target'])"; if (-not $target) { $target = "$($Fm['range'])" }
    # Legacy audit shapes are snapshots based on the empty tree: an `audit ...` target whose tip
    # is `head:` or the sha it names, or `X..X` declared by a `scope-note: Full-state audit`.
    $identical = [regex]::Match($target, '^([0-9a-f]{7,40})\.\.\1\b')
    $auditTip = $null
    if ($target -match '^audit\b') {
        $shas = @([regex]::Matches($target, '(?<![0-9a-f])[0-9a-f]{7,40}(?![0-9a-f])') | ForEach-Object { $_.Value })
        $auditRange = [regex]::Match($target, '(?<![0-9a-f])[0-9a-f]{7,40}\.\.([0-9a-f]{7,40})(?![0-9a-f])')
        if ("$($Fm['head'])" -match '^[0-9a-f]{7,40}$') { $auditTip = $Fm['head'] }
        elseif ($auditRange.Success) { $auditTip = $auditRange.Groups[1].Value }
        elseif ($shas.Count -gt 1) { return & $fail 'audit-tip-ambiguous' }
        elseif ($shas.Count -eq 1) { $auditTip = $shas[0] }
    } elseif ($identical.Success -and "$($Fm['scope-note'])" -match '^Full-state audit') { $auditTip = $identical.Groups[1].Value }
    if ($auditTip) {
        # An audit without declared paths is repository-wide only when it says so.
        $wholeRepo = "$($Fm['scope-kind'])" -eq 'repository' -or $target -match '(?i)\b(full|whole)[- ](repo|repository|tree)\b'
        if (-not $wholeRepo -and -not @($Fm['reviewed-paths'] | Where-Object { $_ }).Count -and -not @($Fm['subsystem'] | Where-Object { $_ }).Count) { return & $fail 'audit-scope-undeclared' }
        $target = "$emptyTree..$auditTip"
    }
    $m = [regex]::Match($target, '^([0-9a-f]{7,40})\.\.([0-9a-f]{7,40}|HEAD)\b')
    if (-not $m.Success) { return & $fail 'no-exact-target' }
    $tip = if ($m.Groups[2].Value -eq 'HEAD') { "$($Fm['head'])" } else { $m.Groups[2].Value }
    if ($tip -notmatch '^[0-9a-f]{7,40}$') { return & $fail 'symbolic-head-without-head-key' }
    $tipSha = Resolve-OnHead $Repo $Head $tip
    if (-not $tipSha) { return & $fail 'tip-not-in-repo' }
    $reviewTipSha = $tipSha
    if ($tipSha -eq 'off-head') {
        $originalCommit = @(Invoke-Git $Repo @('rev-parse', '--verify', "$tip^{commit}"))[0]
        if ($originalCommit) { $reviewTipSha = $originalCommit }
    }
    $boundarySha = $tipSha
    if ($tipSha -eq 'off-head') {
        $merged = $false
        if ("$($Fm['disposition'])" -eq 'remediated' -and "$($Fm['remediation-tip'])" -match '^[0-9a-f]{7,40}$') {
            $fixed = Resolve-OnHead $Repo $Head $Fm['remediation-tip']
            $merged = $fixed -and $fixed -ne 'off-head'
        } elseif ("$($Fm['disposition'])" -eq 'reviewed') {
            # A pass that merged no fix leaves its record `reviewed`; its rebase-merged branch is
            # rescued only when the whole reviewed range has copies on HEAD.
            $merged = Test-RangeTwins $Repo $Head $m.Groups[1].Value $reviewTipSha
        }
        # The boundary is the reviewed tip's rebased copy on HEAD, so the copies of the reviewed
        # commits fall before it and never count as drift. No copy means the reviewed work never
        # reached HEAD: `tip-not-on-head`, below.
        if ($merged) {
            $twin = Find-PatchTwin $Repo $Head $reviewTipSha
            if ($twin) { $boundarySha = $twin }
        }
    }
    if ($boundarySha -eq 'off-head') {
        foreach ($rootSha in @(Invoke-Git $Repo @('rev-list', '--max-parents=0', $Head))) {
            $root = @(Invoke-Git $Repo @('show', '-s', '--format=%H%x09%ad%x09%s', '--date=short', $rootSha))[0]
            if ($root -match '^([0-9a-f]{40})\t(\d{4}-\d{2}-\d{2})\tInitial OSS (?:release|commit)$' -and $Matches[2] -ge $run.date) {
                $run.historyReset = "$($Matches[1]) ($($Matches[2]))"
                break
            }
        }
        if (-not $run.historyReset) { return & $fail 'tip-not-on-head' }
        # History replaced after the review (a squashed OSS release). The review is NOT carried to
        # the new root - an empty-tree credit would certify files the panel never saw. Instead the
        # boundary stays at the reviewed tip in the replaced history, which is still in the
        # object store, and drift is the TREE diff from there to HEAD. Dropping these runs as
        # unusable hid four real fixatdl-wpf reviews and the 46 files that changed between
        # their remediated state and the public release.
    }
    # remediation-tip records provenance only; only the explicit commit set is excluded from drift.
    $base = $m.Groups[1].Value
    $baseSha = if ($emptyTree.StartsWith($base)) { $emptyTree } else { @(Invoke-Git $Repo @('rev-parse', '--verify', "$base^{commit}"))[0] }
    if (-not $baseSha) { return & $fail 'base-not-in-repo' }
    $declared = @($Fm['reviewed-paths'] | Where-Object { $_ })
    # Legacy `subsystem: a;b;c` inline form, written by the 2026-08 driver. A quoted value is
    # one path and is not split: `subsystem: "src/One,Two.cs"` names a single file.
    if (-not $declared.Count) {
        $declared = if ($Fm['quoted:subsystem']) { @("$($Fm['subsystem'])".Trim() | Where-Object { $_ }) }
        else { @($Fm['subsystem'] | Where-Object { $_ } | ForEach-Object { $_ -split '[;,]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    }
    if (-not $kind) { $kind = if ($declared.Count) { 'subsystem' } else { 'repository' } }
    if ($kind -notin @('repository', 'subsystem')) { return & $fail "scope-kind-$kind" }
    $paths = @()
    if ($kind -eq 'subsystem') { $paths = @($declared) }
    if ($kind -eq 'subsystem' -and -not $paths.Count) { return & $fail 'subsystem-without-paths' }
    $run.scopeKind = $kind; $run.paths = @($paths)
    $excluded = @($Fm['excluded-paths'] | Where-Object { $_ })
    # Exclusion magic inverts a coverage pathspec: `:/!foo/**` matches everything outside foo.
    # Short form is `:` plus magic symbols from `/!^`; `!` or `^` anywhere in that run excludes.
    # Same rule as audit-ai-quality/detect.ps1 and adversarial-review/validate-report.ps1.
    # Long form excludes only with an `exclude` token, so `:(attr:exclude=x)` is not an exclusion.
    $inverted = @(@($paths) + @($excluded) | Where-Object { $_ -match '^:(?:[/!^]*[!^]|\((?:[^)]*,)?exclude(?:,[^)]*)?\))' })
    if ($inverted.Count) { $run.detail = "pathspec exclusions are not allowed in coverage lists: $($inverted -join ', ')"; return & $fail 'pathspec-exclusion' $run.detail }
    $pathspec = @()
    if ($paths.Count -or $excluded.Count) { $pathspec = @('--') + $(if ($paths.Count) { $paths } else { @('.') }) + @($excluded | ForEach-Object { ":(exclude)$_" }) }
    $scopeTipSha = $reviewTipSha
    $files = @(Invoke-Git $Repo (@('diff', '--name-only', $baseSha, $scopeTipSha) + $pathspec))
    if ($LASTEXITCODE -ne 0) { return & $fail 'diff-failed' }
    # An entry must match a file at the reviewed tip or a file the reviewed range changed, as the
    # validator requires: a reviewed deletion leaves nothing at the tip to match.
    $unmatchedPaths = @($paths | Where-Object { -not @(Invoke-Git $Repo (@('diff', '--name-only', $emptyTree, $scopeTipSha, '--', $_))).Count -and -not @(Invoke-Git $Repo (@('diff', '--name-only', $baseSha, $scopeTipSha, '--', $_))).Count })
    if ($unmatchedPaths.Count) { return & $fail 'reviewed-paths-unmatched' "reviewed-paths entries match no tracked file at the reviewed tip and no file the reviewed range changed: $($unmatchedPaths -join ', ')" }
    # Pathspecs may be globs, so validate them the same way the diff reads them.
    if ($paths.Count -and -not $files.Count -and -not @(Invoke-Git $Repo (@('diff', '--name-only', $emptyTree, $scopeTipSha) + $pathspec)).Count) { return & $fail 'paths-unmatched' }
    # A rescued remediated run takes its on-HEAD copy; every other run keeps its reviewed tip.
    $run.scopeKind = $kind; $run.boundarySha = $(if ($boundarySha -ne 'off-head') { $boundarySha } else { $reviewTipSha }); $run.baseSha = $baseSha
    # Each entry must name a commit on HEAD; anything else is reported, not silently counted as drift.
    $fixes = @(); $unresolvedFixes = @()
    foreach ($id in @($Fm['remediation-commits'] | Where-Object { $_ })) {
        $fix = if ("$id" -match '^[0-9a-f]{7,40}$') { @(Invoke-Git $Repo @('rev-parse', '--verify', "$id^{commit}"))[0] }
        if ($fix) { $null = Invoke-Git $Repo @('merge-base', '--is-ancestor', $fix, $Head); if ($LASTEXITCODE -ne 0) { $fix = $null } }
        if ($fix) { $fixes += $fix } else { $unresolvedFixes += "$id" }
    }
    $run.remediationCommits = @($fixes)
    if ($unresolvedFixes.Count) { $run.detail = "remediation-commits entries not resolved on HEAD, so not excluded from drift: $($unresolvedFixes -join ', ')" }
    $run.paths = $paths; $run.excludedPaths = $excluded; $run.files = @($files); $run.usable = $true
    [pscustomobject]$run
}

# Commits and diff stats for literal paths. Batch log attribution; --follow only works for one
# file, so isolate that slower path for files Git detects as renamed. ponytail: `:(literal)` only;
# a file that became a directory of the same name would be counted with its children.
# Paths are keyed ordinally throughout: git paths are case-sensitive and PowerShell's `@{}`,
# `-contains` and `Sort-Object -Unique` are not.
# After a history reset, $ResetRoot is the replacement root: a file that differs between the
# reviewed tip and that root is drift with no commit to attribute, and anything later is
# attributed to its commits like any other range, so listed remediation commits still count.
function Measure-Files([string]$Repo, [string]$Boundary, [string[]]$Files, [string[]]$RemediationCommits = @(), [string]$LogBoundary = $Boundary, [string]$ResetRoot) {
    $shas = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $changed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $remediated = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $resetChanged = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $fixes = [Collections.Generic.HashSet[string]]::new([string[]]@($RemediationCommits), [StringComparer]::Ordinal)
    $followFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $byFile = [Collections.Generic.Dictionary[string, Collections.Generic.HashSet[string]]]::new([StringComparer]::Ordinal)
    if ($ResetRoot) { $LogBoundary = $ResetRoot }
    $range = if ($LogBoundary -eq $emptyTree) { @('--root', 'HEAD') } else { @("$LogBoundary..HEAD") }
    if ($LogBoundary) {
        $fileSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in $Files) { [void]$fileSet.Add($file) }
        foreach ($change in @(Invoke-Git $Repo @('diff', '--find-renames', '--name-status', $LogBoundary, 'HEAD'))) {
            $parts = $change -split "`t"
            if ($parts[0] -match '^R\d+$' -and $fileSet.Contains($parts[2])) { [void]$followFiles.Add($parts[2]) }
        }
        # Once per call, not once per batch: each is a whole-history walk for one file.
        foreach ($path in $followFiles) {
            $byFile[$path] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($line in @(Invoke-Git $Repo (@('log', '--follow', '--format=COMMIT:%H') + $range + @('--', ":(literal)$path")))) { if ($line -match '^COMMIT:([0-9a-f]{40})$') { [void]$byFile[$path].Add($Matches[1]) } }
        }
    }
    $ins = 0; $del = 0
    for ($i = 0; $i -lt $Files.Count; $i += 200) {
        $batch = @($Files[$i..([Math]::Min($i + 199, $Files.Count - 1))] | ForEach-Object { ":(literal)$_" })
        if ($LogBoundary) {
            $regular = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($file in $Files[$i..([Math]::Min($i + 199, $Files.Count - 1))]) { if (-not $followFiles.Contains($file)) { [void]$regular.Add($file) } }
            if ($regular.Count) {
                # `-c` lists a merge's files that differ from every parent, so a change made only in
                # a merge (an evil merge) is attributed to that merge instead of to no commit.
                $logArgs = @('log', '-c', '--find-renames', '--format=COMMIT:%H', '--name-only') + $range + @('--') + @($regular | ForEach-Object { ":(literal)$_" })
                $commit = $null
                foreach ($line in @(Invoke-Git $Repo $logArgs)) {
                    if ($line -match '^COMMIT:([0-9a-f]{40})$') { $commit = $Matches[1]; continue }
                    if ($commit -and $line -and $regular.Contains($line)) {
                        if (-not $byFile.ContainsKey($line)) { $byFile[$line] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
                        [void]$byFile[$line].Add($commit)
                    }
                }
            }
        }
        if ($ResetRoot) { foreach ($f in @(Invoke-Git $Repo (@('diff', '--name-only', $Boundary, $ResetRoot, '--') + $batch))) { [void]$resetChanged.Add($f) } }
        $batchChanged = [Collections.Generic.List[string]]::new()
        foreach ($f in @(Invoke-Git $Repo (@('diff', '--name-only', $Boundary, 'HEAD', '--') + $batch))) {
            if (-not $f) { continue }
            if ($resetChanged.Contains($f)) { [void]$changed.Add($f); $batchChanged.Add($f); continue }
            $fileCommits = if ($byFile.ContainsKey($f)) { @($byFile[$f]) } else { @() }
            $ownCommits = @($fileCommits | Where-Object { -not $fixes.Contains($_) })
            foreach ($sha in $ownCommits) { [void]$shas.Add($sha) }
            if (-not $LogBoundary -or $ownCommits.Count -or -not $fileCommits.Count) { [void]$changed.Add($f); $batchChanged.Add($f) }
            else { [void]$remediated.Add($f) }
        }
        # Diff stats cover drift only, so a file changed only by listed remediation adds nothing.
        if ($batchChanged.Count) {
            $stat = @(Invoke-Git $Repo (@('diff', '--shortstat', $Boundary, 'HEAD', '--') + @($batchChanged | ForEach-Object { ":(literal)$_" }))) -join ' '
            if ($stat -match '(\d+) insertion') { $ins += [int]$Matches[1] }
            if ($stat -match '(\d+) deletion') { $del += [int]$Matches[1] }
        }
    }
    [pscustomobject]@{ commits = $shas.Count; commitIds = @($shas); changedFiles = @($changed | Sort-Object -CaseSensitive); remediationFiles = @($remediated | Sort-Object -CaseSensitive); resetChanged = @($resetChanged); insertions = $ins; deletions = $del }
}
function Error-Row([string]$Label, [string]$Repo, [string]$Reason) {
    [pscustomobject]@{
        repo = $Label; resolvedPath = $Repo; headSha = $null; outsideScanPath = $false; unresolved = $false
        vault = [pscustomobject]@{ exists = $false; indexPath = $null; date = $null; scopeKind = $null; disposition = $null; isDocumentReview = $false }
        git = [pscustomobject]@{ boundarySha = $null; boundarySource = 'none'; neverReviewed = $null; effectiveNeverReviewed = $null; sinceReviewCount = $null; sinceReviewFiles = $null; sinceReviewIns = $null; sinceReviewDel = $null; daysSinceReview = $null }
        subsystemPaths = @(); isSubsystem = $false; scopeValidation = 'unknown'; hasTrackedSource = $null; hasCoveredSource = $null
        queue = 'collector-error'; exempt = $false; exemptReason = $null; firstCommitDate = $null
        reviewCoverage = @(); unusable = @()
        uncovered = [pscustomobject]@{ files = @(); source = @(); sourceFiles = 0; commits = 0 }
        score = 0; newSource = @(); remediationFiles = @(); oldestUnreviewedChange = $null; openReviewCount = 0; oldestOpenReviewDate = $null; collectorError = $Reason
    }
}
function Oldest-CommitDate([string]$Repo, [string[]]$Commits) {
    if (-not @($Commits).Count) { return $null }
    # One git process for the whole set; ids go on stdin, so no command-line length limit applies.
    $dates = @($Commits | & git -C $Repo log --no-walk --stdin --format=%cs 2>$null | Where-Object { $_ } | Sort-Object)
    if ($dates.Count) { return $dates[0] }
    return $null
}

$repos = @(foreach ($scan in $Path) {
    if (-not (Test-Path -LiteralPath $scan -PathType Container)) { throw "Path not a folder: $scan" }
    if (Test-Path (Join-Path $scan '.git')) { Get-Item -LiteralPath $scan -Force }
    else { Get-ChildItem -LiteralPath $scan -Directory -Force | Where-Object { Test-Path (Join-Path $_.FullName '.git') } }
}) | Sort-Object FullName -Unique
if (-not $repos) { throw "No git repositories under $($Path -join ', ')" }

# Parse every index once; attach per repository below.
if (-not (Test-Path -LiteralPath $VaultRoot -PathType Container)) { throw "VaultRoot is not a folder: $VaultRoot" }
$indexes = @(
    foreach ($folder in Get-ChildItem -LiteralPath $VaultRoot -Directory) {
        foreach ($run in Get-ChildItem -LiteralPath $folder.FullName -Directory) {
            $index = Join-Path $run.FullName '_index.md'
            if (Test-Path -LiteralPath $index) {
                $fm = Read-Frontmatter $index
                [pscustomobject]@{ folder = $folder.Name; run = $run.Name; index = $index; fm = $fm; repoPath = Normalize "$($fm['repo-path'])" }
            }
        }
    }
)
if (-not $indexes.Count) { throw "VaultRoot contains no _index.md review records: $VaultRoot" }

$today = (Get-Date).Date
$scannedKeys = [Collections.Generic.HashSet[string]]::new([string[]]@($repos | ForEach-Object { Normalize $_.FullName }), [StringComparer]::Ordinal)
$results = foreach ($r in $repos) {
    $repo = $r.FullName
    $label = Canonical-Label $repo $r.Name
    $head = @(Invoke-Git $repo @('rev-parse', '--verify', 'HEAD'))[0]
    if (-not $head) { Error-Row $label $repo 'No HEAD commit'; continue }
    $tracked = @(Invoke-Git $repo @('ls-tree', '-r', '--name-only', 'HEAD'))
    if ($LASTEXITCODE -ne 0) { Error-Row $label $repo 'Could not read tracked files at HEAD'; continue }
    $key = Normalize $repo
    $runs = @($indexes | Where-Object { if ($_.repoPath) { $_.repoPath -eq $key } else { $_.folder -eq $r.Name } } | ForEach-Object { Get-Run $repo $head $_.index $_.fm })
    # A `repo-path` naming no scanned checkout (a worktree, a moved clone) falls back to its folder
    # name and is listed, so it cannot vanish from every list.
    $runs += @($indexes | Where-Object { $_.repoPath -and -not $scannedKeys.Contains($_.repoPath) -and $_.folder -eq $r.Name } | ForEach-Object {
            $waiver = "$($_.fm['coverage-waiver'])"
            [pscustomobject]@{ indexPath = $_.index; date = $null; usable = $false; reason = $(if ($waiver) { 'coverage-waived' } else { 'repo-path-unscanned' }); detail = "repo-path names no scanned repository: $($_.fm['repo-path'])"; waiver = $(if ($waiver) { $waiver } else { $null }); paths = @() }
        })
    $usable = @($runs | Where-Object usable | Sort-Object @{Expression = 'date'; Descending = $true }, @{Expression = 'indexPath'; Descending = $true })
    $owner = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $trackedSet = [Collections.Generic.HashSet[string]]::new([string[]]$tracked, [StringComparer]::Ordinal)
    $allRemediationCommits = @($usable | ForEach-Object { @($_.remediationCommits) } | Sort-Object -Unique)
    foreach ($run in $usable) {
        # A two-tree diff without -B never chains renames, so one lookup maps a file.
        $renameMap = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        foreach ($change in @(Invoke-Git $repo @('diff', '--find-renames', '--name-status', $run.boundarySha, 'HEAD'))) {
            $parts = $change -split "`t"
            if ($parts[0] -match '^R\d+$') { $renameMap[$parts[1]] = $parts[2] }
        }
        $run | Add-Member -NotePropertyName coveredFiles -NotePropertyValue @($run.files | ForEach-Object { if ($renameMap.ContainsKey($_)) { $renameMap[$_] } else { $_ } }) -Force
        $runLogBoundary = $run.boundarySha
        $run | Add-Member -NotePropertyName resetRoot -NotePropertyValue $(if ($run.historyReset) { ($run.historyReset -split ' ')[0] } else { $null }) -Force
        if ($run.historyReset) { $runLogBoundary = $null }
        else {
            & git -C $repo merge-base --is-ancestor $run.boundarySha HEAD 2>$null
            if ($LASTEXITCODE -ne 0) {
                & git -C $repo merge-base --is-ancestor $run.baseSha HEAD 2>$null
                $runLogBoundary = if ($LASTEXITCODE -eq 0) { $run.baseSha } else { $null }
            }
        }
        $run | Add-Member -NotePropertyName logBoundary -NotePropertyValue $runLogBoundary -Force
        foreach ($file in $run.coveredFiles) { if (-not $owner.ContainsKey($file)) { $owner[$file] = $run } }
    }
    $newestResetChanged = 0
    $coverage = @(foreach ($run in $usable) {
        $files = @($run.coveredFiles | Where-Object { [object]::ReferenceEquals($owner[$_], $run) })
        $measure = if ($files.Count) { Measure-Files $repo $run.boundarySha $files $allRemediationCommits $run.logBoundary $run.resetRoot } else { [pscustomobject]@{ commits = 0; commitIds = @(); changedFiles = @(); remediationFiles = @(); resetChanged = @(); insertions = 0; deletions = 0 } }
        $reviewAgeDays = [int]($today - [datetime]::ParseExact($run.date, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)).TotalDays
        $oldestGroupChange = Oldest-CommitDate $repo $measure.commitIds
        # A file the reset itself changed has no commit; its change is dated by the new root.
        if ($run.historyReset -and @($measure.resetChanged).Count) { $oldestGroupChange = [regex]::Match($run.historyReset, '\((\d{4}-\d{2}-\d{2})\)$').Groups[1].Value }
        if ([object]::ReferenceEquals($run, $usable[0])) { $newestResetChanged = @($measure.resetChanged).Count }
        $days = if ($oldestGroupChange) { [Math]::Max(0, [int]($today - [datetime]::ParseExact($oldestGroupChange, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)).TotalDays) } else { 0 }
        [pscustomobject]@{
            indexPath = $run.indexPath; date = $run.date; scopeKind = $run.scopeKind; disposition = $run.disposition
            boundarySha = $run.boundarySha; baseSha = $run.baseSha; paths = $run.paths; excludedPaths = $run.excludedPaths
            files = $files.Count; commits = $measure.commits; commitIds = $measure.commitIds; changedFiles = $measure.changedFiles; remediationFiles = $measure.remediationFiles
            insertions = $measure.insertions; deletions = $measure.deletions; days = $days; oldestChangeDate = $oldestGroupChange
            hasTrackedSource = [bool]@($files | Where-Object { $_ -match $sourceExtRegex }).Count
            historyReset = $run.historyReset
            # The scope a follow-up review names: changed files under their current names that
            # still exist at HEAD. `paths` stays as the record's declared scope, for provenance.
            reviewPaths = @($measure.changedFiles | Where-Object { $trackedSet.Contains($_) })
            detail = $run.detail
            # A squashed history has one commit touching everything, so after a reset the unit of
            # drift is the changed file, not the commit.
            score = $measure.changedFiles.Count
        }
    })
    $uncoveredFiles = @($tracked | Where-Object { -not $owner.ContainsKey($_) })
    $uncoveredSource = @($uncoveredFiles | Where-Object { $_ -match $sourceExtRegex })
    $uncoveredMeasure = if ($uncoveredSource.Count) { Measure-Files $repo $emptyTree $uncoveredSource } else { [pscustomobject]@{ commits = 0; commitIds = @() } }
    $uncoveredCommits = $uncoveredMeasure.commits
    $newest = if ($usable.Count) { $usable[0] } else { $null }
    $invalidScope = @($runs | Where-Object { $_.reason -eq 'reviewed-paths-unmatched' } | Sort-Object @{Expression = 'date'; Descending = $true } | Select-Object -First 1)
    # Workload counts changed files and new source. Older uncovered source is context only;
    # explicit remediation commits are removed before a path enters either workload.
    #
    # It used to add `100 + $uncoveredCommits` as an audit floor, which encoded an assumption
    # this estate does not hold -- that every source file ought eventually to be reviewed.
    # Reviews here are targeted at new work, and some repositories are vendored third-party
    # forks whose upstream code is deliberately never reviewed. Measured 2026-09-13 the floor
    # supplied 769 of one vendored-fork repo's 825 (its uncovered surface is upstream engine
    # code plus generated codegen output), 914 of another repo's 1171, and ranked four
    # repositories with ZERO commits since their review. One of them had been reviewed the
    # previous day, nothing had changed, and it still ranked seventh in the estate.
    # A queue that ranks unchanged repositories is not a queue.
    # Headline counts start at the newest usable review. Each reviewCoverage row
    # still lists that group's own boundary, including changes that predate the
    # latest review. Folding those rows into the headline counted them as if they
    # were drift since the last review: on 2026-10-01 a live-home repository
    # showed 200 commits beside tip c85af4a, and git rev-list of that tip was 34.
    $newSourceCandidates = if ($newest) { @((Invoke-Git $repo @('diff', '--name-only', '--diff-filter=d', $newest.boundarySha, 'HEAD')) | Where-Object { $_ -match $sourceExtRegex -and -not $owner.ContainsKey($_) }) } else { @($uncoveredSource) }
    $newestLogBoundary = if ($usable.Count) { $usable[0].logBoundary } else { $null }
    $newSourceMeasure = if ($newest -and $newSourceCandidates.Count) { Measure-Files $repo $newest.boundarySha $newSourceCandidates $allRemediationCommits $newestLogBoundary $newest.resetRoot } else { [pscustomobject]@{ commitIds = @(); changedFiles = $newSourceCandidates; remediationFiles = @(); resetChanged = @(); insertions = 0; deletions = 0 } }
    $newSource = @($newSourceMeasure.changedFiles)
    $remediationFiles = @(@($coverage | ForEach-Object { @($_.remediationFiles) }) + @($newSourceMeasure.remediationFiles) | Sort-Object -Unique -CaseSensitive)
    $changedFiles = @()
    $commitIds = @()
    $sinceIns = [int]$newSourceMeasure.insertions
    $sinceDel = [int]$newSourceMeasure.deletions
    if ($newest -and ($newest.historyReset -or -not $newest.logBoundary)) {
        # No commit range exists. The newest group's tree diff is the headline;
        # older groups stay in reviewCoverage.
        $changedFiles = @($coverage[0].changedFiles)
        $commitIds = @($coverage[0].commitIds)
        $sinceIns += [int]$coverage[0].insertions
        $sinceDel += [int]$coverage[0].deletions
    } elseif ($newest) {
        $ownedSince = @((Invoke-Git $repo @('diff', '--name-only', '--diff-filter=d', $newest.boundarySha, 'HEAD')) | Where-Object { $owner.ContainsKey($_) })
        if ($ownedSince.Count) {
            $headline = Measure-Files $repo $newest.boundarySha $ownedSince $allRemediationCommits $newest.logBoundary
            $changedFiles = @($headline.changedFiles)
            $commitIds = @($headline.commitIds)
            $sinceIns += [int]$headline.insertions
            $sinceDel += [int]$headline.deletions
        }
    }
    $firstCommit = @(Invoke-Git $repo @('log', '--max-parents=0', '--format=%ad', '--date=short', 'HEAD') | Sort-Object)[0]
    $changeDates = @()
    if ($commitIds.Count) { $changeDates += Oldest-CommitDate $repo $commitIds }
    if ($newSourceMeasure.commitIds.Count) { $changeDates += Oldest-CommitDate $repo $newSourceMeasure.commitIds }
    # A file the reset itself changed, covered or new source, is dated by the replacement root.
    if ($newest -and $newest.historyReset -and ($newestResetChanged -or @($newSourceMeasure.resetChanged | Where-Object { $newSource -ccontains $_ }).Count)) { $changeDates += [regex]::Match($newest.historyReset, '\((\d{4}-\d{2}-\d{2})\)$').Groups[1].Value }
    $isExempt = $exemptReason.ContainsKey($label) -or $exemptReason.ContainsKey($r.Name)
    $hasSource = [bool]@($tracked | Where-Object { $_ -match $sourceExtRegex }).Count
    # A repository with no review dates its unreviewed source. An exempt repository
    # with no review does not: its first commit is not an unreviewed change.
    if (-not $newest -and -not $isExempt -and $hasSource -and $uncoveredMeasure.commitIds.Count) { $changeDates += Oldest-CommitDate $repo $uncoveredMeasure.commitIds }
    $oldestChange = @($changeDates | Where-Object { $_ } | Sort-Object | Select-Object -First 1)[0]
    $openReviews = @($coverage | Where-Object disposition -EQ 'open')
    $oldestOpenDate = if ($openReviews.Count) { ($openReviews | Sort-Object date | Select-Object -First 1).date } else { $null }
    $oldestOpenAge = if ($oldestOpenDate) { [Math]::Max(0, [int]($today - [datetime]::ParseExact($oldestOpenDate, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)).TotalDays) } else { $null }
    $score = $changedFiles.Count + $newSource.Count
    # An older group owns a file only when the newest review did not cover it. A change to
    # that file before the newest boundary is absent from the headline diff, and it is still
    # unreviewed. The headline counts stay newest-boundary-only. The queue does not.
    $groupDrift = [bool]@($coverage | Where-Object { @($_.changedFiles).Count }).Count
    #
    # Except for a repository with source and NO usable review at all. Scoring it zero sank new
    # work to the bottom beside the vendored forks: personal-tts, first committed 2026-09-21 with
    # 48 unreviewed commits, ranked level with a fork nobody will ever review. The two are told
    # apart by an explicit exemption list, not by the score: an exempt repository is reported
    # and never queued, and everything else with no usable review is queued FIRST by its
    # distinct uncovered source-file count.
    $hasCoveredSource = [bool]@($coverage | Where-Object hasTrackedSource).Count
    # Covered source that changed is drift even when no source is left at HEAD: deleting a
    # repository's last reviewed source file is a change nobody has reviewed.
    $coveredSourceDrift = [bool]@($coverage | ForEach-Object { @($_.changedFiles) } | Where-Object { $_ -match $sourceExtRegex }).Count
    $queue = if ($isExempt) { 'exempt' } elseif (-not $hasSource -and -not $coveredSourceDrift) { 'none' } elseif (-not $coverage.Count) { 'no-usable-review' } elseif ($newSource.Count) { 'new-source' } elseif ($changedFiles.Count -or $groupDrift) { 'drift' } elseif ($openReviews.Count) { 'open-review' } else { 'none' }
    if ($queue -eq 'no-usable-review') {
        $score = $uncoveredSource.Count
    }
    if ($isExempt) { $score = 0 }
    if (@(Invoke-Git $repo @('rev-parse', 'HEAD'))[0] -ne $head) { Error-Row $label $repo 'Repository changed during collection'; continue }
    $rowPaths = @()
    # One recency rule for every scope field: an invalid scope counts only when it is at least
    # as new as the newest usable review.
    $scopeInvalid = [bool]($invalidScope.Count -and (-not $newest -or $invalidScope[0].date -ge $newest.date))
    if ($scopeInvalid) { $rowPaths = @($invalidScope[0].paths) }
    elseif ($newest) { $rowPaths = @($newest.paths) }
    [pscustomobject]@{
        repo = $label; resolvedPath = $repo; headSha = $head; outsideScanPath = $false; unresolved = $false
        vault = [pscustomobject]@{
            exists = [bool]$newest; indexPath = $newest.indexPath; date = $newest.date; scopeKind = $newest.scopeKind
            disposition = $newest.disposition; isDocumentReview = $false
        }
        git = [pscustomobject]@{
            boundarySha = $newest.boundarySha; boundarySource = $(if ($newest) { 'vault-target' } else { 'none' })
            neverReviewed = -not $newest; effectiveNeverReviewed = -not $newest
            sinceReviewCount = $(if ($coverage.Count) { $commitIds.Count } else { $null })
            sinceReviewFiles = $(if ($coverage.Count) { $changedFiles.Count } else { $null })
            sinceReviewIns = $sinceIns; sinceReviewDel = $sinceDel; daysSinceReview = $(if ($oldestChange) { [int]($today - [datetime]::ParseExact($oldestChange, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)).TotalDays } else { 0 })
        }
        subsystemPaths = $rowPaths; isSubsystem = [bool](($newest -and $newest.paths.Count) -or $scopeInvalid)
        scopeValidation = $(if ($scopeInvalid) { 'invalid' } elseif ($newest -and $newest.paths.Count) { 'valid' } else { 'none' })
        hasTrackedSource = $hasSource; hasCoveredSource = $hasCoveredSource
        queue = $queue; exempt = $isExempt; exemptReason = $(if ($isExempt) { $exemptReason[$(if ($exemptReason.ContainsKey($label)) { $label } else { $r.Name })] } else { $null })
        firstCommitDate = $firstCommit
        reviewCoverage = $coverage
        unusable = @($runs | Where-Object { -not $_.usable -and $_.reason -ne 'document-review' } | ForEach-Object { [pscustomobject]@{ indexPath = $_.indexPath; reason = $_.reason; detail = $_.detail; waiver = $_.waiver } })
        uncovered = [pscustomobject]@{ files = $uncoveredFiles; source = $uncoveredSource; sourceFiles = $uncoveredSource.Count; commits = $uncoveredCommits }
        score = [int]$score; newSource = $newSource; remediationFiles = $remediationFiles
        oldestUnreviewedChange = $oldestChange; openReviewCount = $openReviews.Count
        oldestOpenReviewDate = $oldestOpenDate; oldestOpenReviewAgeDays = $oldestOpenAge
    }
}
$results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding utf8
Write-Output "wrote $OutFile ($(@($results).Count) repos)"
