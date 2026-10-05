#requires -Version 7
<#
.SYNOPSIS
Renders one collector snapshot as a ranked digest with a copy-paste review prompt per scope.
.DESCRIPTION
Mechanical projection of collect.ps1 output. Never overwrites an existing report.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DataFile,
    [Parameter(Mandatory)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutFile) { throw "Output already exists; choose a new run name: $OutFile" }
# A repository with source and no usable review outranks any amount of drift: unreviewed new
# work is the queue's first job, not its last.
$rows = @(Get-Content -LiteralPath $DataFile -Raw | ConvertFrom-Json) | Sort-Object @{Expression = { if ($_.queue -eq 'no-usable-review') { 4 } elseif ($_.queue -eq 'new-source') { 3 } elseif ($_.queue -eq 'drift') { 2 } elseif ($_.queue -eq 'open-review') { 1 } else { 0 } }; Descending = $true }, @{Expression = 'score'; Descending = $true }, @{Expression = 'oldestUnreviewedChange'; Descending = $false }, @{Expression = 'oldestOpenReviewDate'; Descending = $false }, repo
$emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
function Cell($Value) { if ($null -eq $Value -or "$Value" -eq '') { return 'none' } "$Value" -replace '\|', '\|' }
function Link([string]$P) { "[$(Split-Path (Split-Path $P -Parent) -Leaf)](<$($P -replace '\\', '/')>)" }
# ponytail: top-two directory components; names an audit scope when the file set is too long to list.
function Dirs([string[]]$Files) { @($Files | ForEach-Object { (($_ -split '/') | Select-Object -First 2) -join '/' } | Sort-Object -Unique) }

$md = [Collections.Generic.List[string]]::new()
$md.Add('# Review digest')
$md.Add('')
$md.Add("Generated $((Get-Date).ToUniversalTime().ToString('o')) from $DataFile.")
$md.Add('')
$md.Add('Counts in the table start at the newest usable review. Each group section below keeps that group''s own boundary and its own counts.')
$md.Add('')
$md.Add('## Columns')
$md.Add('')
$md.Add('The table is a work queue. Commit, file, and age columns count only what changed after the newest usable review.')
$md.Add('')
$md.Add('- **Repository** — origin name. The three live homes are labelled so they are not confused with another checkout.')
$md.Add('- **Queue** — `no-usable-review` (source and no usable review; ranked first), `new-source` (an uncovered source file changed after the newest review), `drift` (a covered file changed and there is no new source), `open-review`, `exempt` (reported, never queued), or `none`.')
$md.Add('- **Last usable review** — date and scope of the newest usable record. An exempt repository that has a review still shows that date and the exemption reason. No record says `none`.')
$md.Add('- **Review boundary** — that review''s tip. The counts to its right start here.')
$md.Add('- **Covered drift commits** — distinct commits after that tip that touch a file a review still covers. Commits listed in `remediation-commits` are excluded. A commit that only touches new source is not included. A repository with no usable review shows its uncovered source commits.')
$md.Add('- **Changed files** — covered files that differ between that tip and `HEAD`. A repository with no usable review shows its uncovered source file count.')
$md.Add('- **Oldest change age** — age of the oldest post-review change, including new-source commits. `none` when there is no such change. An exempt repository with no review does not use its first commit.')
$md.Add('- **Open reviews (oldest age)** — usable reviews still disposition `open`, and the age of the oldest of those review dates. Separate from file drift.')
$md.Add('- **Own remediation files** — files whose only post-review change is a listed remediation commit. Reported and not scored.')
$md.Add('- **Uncovered source** — source files no usable review''s diff covers. Context only, except a `no-usable-review` row, where this count is the workload.')
$md.Add('- **Unusable records** — records that could not be read. `document-review`, `superseded`, and `coverage-waived` are left out of this count and listed later. A number here means a record is missing from the coverage.')
$md.Add('- **Workload** — changed files plus new-source files. For `no-usable-review`, the uncovered source count. Exempt workload is 0. This orders the table. It is not a risk verdict.')
$md.Add('')
$md.Add('| Repository | Queue | Last usable review | Review boundary | Covered drift commits | Changed files | Oldest change age | Open reviews (oldest age) | Own remediation files | Uncovered source | Unusable records | Workload |')
$md.Add('|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|')
$deliberateReasons = @('document-review', 'superseded', 'coverage-waived')
foreach ($r in $rows) {
    $unreadableCount = @($r.unusable | Where-Object { $_.reason -notin $deliberateReasons }).Count
    $newestGroup = @($r.reviewCoverage | Select-Object -First 1)
    $reset = @($newestGroup | Where-Object historyReset)
    $reviewText = if ($r.vault.exists) {
        "$($r.vault.date) ($($r.vault.scopeKind))$(if ($reset) { "; history reset $($reset[0].historyReset -replace '^(\w{7})\w*', '$1') since" })"
    } else { $null }
    $last = if ($r.queue -eq 'exempt') {
        if ($reviewText) { "$reviewText; exempt$(if ($r.exemptReason) { ": $($r.exemptReason)" })" } else { "none (exempt$(if ($r.exemptReason) { ": $($r.exemptReason)" }))" }
    } elseif ($reviewText) { $reviewText }
    elseif ($r.queue -eq 'no-usable-review') { "**none** ($(if (@($r.unusable).Count) { "$(@($r.unusable).Count) unusable record(s)" } else { 'no review record' }); first commit $($r.firstCommitDate))" }
    else { 'none' }
    $commits = if ($r.queue -eq 'no-usable-review') { $r.uncovered.commits } else { $r.git.sinceReviewCount }
    $changed = if ($r.queue -eq 'no-usable-review') { $r.uncovered.sourceFiles } else { $r.git.sinceReviewFiles }
    $boundaries = if ($r.git.boundarySha) { $r.git.boundarySha.Substring(0, [Math]::Min(7, $r.git.boundarySha.Length)) } else { '' }
    $age = if ($r.oldestUnreviewedChange) { [int]((Get-Date).Date - [datetime]::ParseExact($r.oldestUnreviewedChange, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)).TotalDays } else { 0 }
    $openAge = $r.oldestOpenReviewAgeDays
    $ageText = if (-not $r.oldestUnreviewedChange) { 'none' } elseif ($age -eq 1) { '1 day' } else { "$age days" }
    $md.Add("| $($r.repo) | $($r.queue) | $last | $(Cell $boundaries) | $(Cell $commits) | $(Cell $changed) | $ageText | $($r.openReviewCount)$(if ($null -ne $openAge) { " ($openAge days)" }) | $(@($r.remediationFiles).Count) | $($r.uncovered.sourceFiles) | $unreadableCount | $($r.score) |")
}

# An estate rollup of records the collector could not read. The per-repository lists below
# already hold these, but a count buried under thirty headings is one nobody reads: a complete
# review sat invisible in one repository for a day because its only symptom was `no-date` in an
# array. `document-review`, `superseded` and `coverage-waived` are DELIBERATE exclusions, so they
# are reported apart from the rest - folding them in would make the headline cry wolf on healthy
# records. `coverage-waived` is the newest of the three and the one that carries the whole legacy
# backlog: each of those records says in its own frontmatter that its coverage was read and found
# unreconstructable, which is a decision, not a defect.
# A literal backtick, held in a variable: inside a double-quoted string the backtick is
# PowerShell's own escape character, so writing the markdown code fence inline is a parse error.
$tick = [char]0x60
$allUnusable = @($rows | ForEach-Object { $repo = $_.repo; @($_.unusable) | ForEach-Object { [pscustomobject]@{ repo = $repo; reason = $_.reason; indexPath = $_.indexPath } } })
$dropped = @($allUnusable | Where-Object { $_.reason -notin $deliberateReasons })
$deliberate = @($allUnusable | Where-Object { $_.reason -in $deliberateReasons })
$md.Add('')
$md.Add('## Unreadable records')
$md.Add('')
if (-not $dropped.Count) {
    $md.Add('Every review record in scope parsed. No run was dropped for an unreadable shape.')
} else {
    $repoCount = @($dropped | Group-Object repo).Count
    $md.Add("**$($dropped.Count) record(s) across $repoCount repositor$(if ($repoCount -eq 1) { 'y' } else { 'ies' }) could not be read, and contribute to no coverage figure anywhere in this report.** A dropped record is not evidence that no review happened - it is evidence that the evidence is unreadable, which is the more expensive of the two.")
    $md.Add('')
    $md.Add('| Reason | Count | Repositories |')
    $md.Add('|---|---:|---|')
    foreach ($g in @($dropped | Group-Object reason | Sort-Object Count -Descending)) {
        $where = (@($g.Group | Group-Object repo | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')
        $md.Add("| $tick$($g.Name)$tick | $($g.Count) | $where |")
    }
}
if ($deliberate.Count) {
    $md.Add('')
    $parts = @($deliberate | Group-Object reason | ForEach-Object { "$($_.Count) $tick$($_.Name)$tick" })
    $md.Add("Excluded on purpose and not counted above: $($parts -join ', ').")
}

foreach ($r in $rows) {
    $md.Add(''); $md.Add("## $($r.repo)"); $md.Add('')
    $md.Add("Path: ``$($r.resolvedPath)``. HEAD: ``$($r.headSha)``. Workload: $($r.score).$(if ($r.collectorError) { " Collector error: $($r.collectorError)." })")
    foreach ($g in @($r.reviewCoverage | Where-Object { $_.files -and -not $r.exempt })) {
        $md.Add('')
        $md.Add("### $($g.date) $($g.scopeKind) review, $(Link $g.indexPath)")
        $md.Add('')
        $md.Add("Boundary ``$($g.boundarySha)``; covers $($g.files) tracked files; $($g.commits) non-remediation commits and $(@($g.changedFiles).Count) files changed since; disposition $(Cell $g.disposition).")
        if (@($g.remediationFiles).Count) { $md.Add("Own remediation (unscored): $(@($g.remediationFiles) -join ', ')") }
        if ($g.historyReset) {
            $md.Add('')
            $md.Add("History was replaced after this review (new root $($g.historyReset)). The boundary is the reviewed state in the replaced history, still in the object store; drift is the tree diff from it to HEAD, so the commit count is not meaningful.")
        }
        if (-not $g.commits -and -not @($g.changedFiles).Count) { continue }
        $md.Add(''); $md.Add('```text')
        $md.Add("Run /adversarial-review on $($r.resolvedPath).")
        $md.Add("Target: $($g.boundarySha)..$($r.headSha)")
        if ($g.historyReset) { $md.Add("Note: $($g.boundarySha) is from the history replaced at $($g.historyReset); review the tree diff (git diff $($g.boundarySha) $($r.headSha)), not the commit log.") }
        $md.Add("Scope-kind: $($g.scopeKind)")
        if (@($g.paths).Count) { $md.Add("Reviewed-paths: $(@($g.paths) -join '; ')") }
        if (@($g.excludedPaths).Count) { $md.Add("Excluded-paths: $(@($g.excludedPaths) -join '; ')") }
        $md.Add('Review only these files, which changed since the boundary and are not covered by a newer review:')
        foreach ($f in @($g.changedFiles)) { $md.Add("  $f") }
        $md.Add('```')
    }
    if ($r.uncovered.sourceFiles -and $r.queue -eq 'no-usable-review' -and -not $r.exempt) {
        $md.Add(''); $md.Add("### No usable review (ranked first): $($r.uncovered.sourceFiles) source files, $($r.uncovered.commits) commits since $($r.firstCommitDate)"); $md.Add('')
        $md.Add('This repository has source and no review record the collector can use. If an unusable record below did cover it, repairing that record is cheaper than the review; otherwise this is the review to run.')
        $md.Add(''); $md.Add('```text')
        $md.Add("Run /adversarial-review on $($r.resolvedPath).")
        $md.Add("Target: $emptyTree..$($r.headSha)")
        $md.Add('Scope-kind: repository')
        $md.Add('```')
    } elseif ($r.uncovered.sourceFiles -and -not $r.exempt) {
        $isNewSource = $r.queue -eq 'new-source'
        $sourceFiles = if ($isNewSource) { @($r.newSource) } else { @($r.uncovered.source) }
        $md.Add(''); $md.Add("### Uncovered source$(if ($isNewSource) { ' (queued: new or changed since the newest review)' } else { ' (not queued)' }): $($sourceFiles.Count) files"); $md.Add('')
        if ($isNewSource) { $md.Add('These source files were added or changed after the newest usable review boundary and have no coverage group. Review this new source. Older uncovered files remain unqueued.') }
        else { $md.Add('No usable review record covers these files. That is a statement about the records, not a backlog: it includes vendored third-party code, generated output, and anything simply never targeted by a review. It is listed for context and is not a recommendation to audit it.') }
        $md.Add(''); $md.Add('```text')
        $md.Add("Run /adversarial-review on $($r.resolvedPath).")
        $md.Add("Target: $emptyTree..$($r.headSha)")
        $md.Add('Scope-kind: subsystem')
        $specs = if ($sourceFiles.Count -le 100) { $sourceFiles } else { Dirs $sourceFiles }
        $md.Add("Reviewed-paths: $($specs -join '; ')")
        $md.Add('```')
    }
    # Waived records are listed separately from the rest, and BELOW them, because the two ask
    # different things of the reader: the unusable ones are a repair job, a waived one has already
    # been read and decided and needs nothing. Listing them together restores the haystack this
    # section exists to remove, one heading further down.
    $repair = @($r.unusable | Where-Object { $_.reason -ne 'coverage-waived' })
    $waived = @($r.unusable | Where-Object { $_.reason -eq 'coverage-waived' })
    if ($repair.Count) {
        $md.Add(''); $md.Add('### Unusable review records'); $md.Add('')
        $md.Add('Not evidence either way. Fix the index frontmatter (`target: <base>..<tip>`, `head:`, `scope-kind`, `reviewed-paths`, `repo-path`) and recollect.')
        $md.Add('')
        foreach ($u in $repair) { $md.Add("- $($u.reason): $(Link $u.indexPath)") }
    }
    if ($waived.Count) {
        $md.Add(''); $md.Add('### Coverage waived'); $md.Add('')
        $md.Add("$($waived.Count) record(s) whose coverage was read and found unreconstructable. Each states its own reason; none is a repair job. Remove its ``coverage-waiver:`` line to put one back in scope.")
        $md.Add('')
        foreach ($u in $waived) { $md.Add("- $(Link $u.indexPath): $($u.waiver)") }
    }
}
$md | Set-Content -LiteralPath $OutFile -Encoding utf8
Write-Output "wrote $OutFile"
