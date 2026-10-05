#requires -Version 7
# Drives collect.ps1 and write-report.ps1 over fixture repos and a fixture vault.
$ErrorActionPreference = 'Stop'
$skill = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('review-digest-' + [guid]::NewGuid().ToString('N'))
$repos = Join-Path $root 'repos'
$vault = Join-Path $root 'vault'
$failures = [Collections.Generic.List[string]]::new()
function Check($Condition, [string]$Message) { if (-not $Condition) { $failures.Add($Message) } }
function Invoke-FixtureGit([string]$Repo, [string[]]$Arguments) {
    $output = @(& git -C $Repo @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "fixture git $($Arguments -join ' ') failed: $($output -join ' ')" }
    return $output
}
function Commit([string]$Repo, [string]$File, [string]$Text) {
    $destination = Join-Path $Repo $File
    New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
    Set-Content -LiteralPath $destination -Value $Text
    $null = Invoke-FixtureGit $Repo @('add', '--', $File)
    $null = Invoke-FixtureGit $Repo @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', $Text)
    (@(Invoke-FixtureGit $Repo @('rev-parse', 'HEAD'))[0]).Trim()
}
function CommitAt([string]$Repo, [string]$File, [string]$Text, [string]$Date) {
    $authorDate = $env:GIT_AUTHOR_DATE
    $committerDate = $env:GIT_COMMITTER_DATE
    $env:GIT_AUTHOR_DATE = "$Date 12:00:00 +0000"
    $env:GIT_COMMITTER_DATE = "$Date 12:00:00 +0000"
    try { Commit $Repo $File $Text }
    finally {
        if ($null -eq $authorDate) { Remove-Item Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue } else { $env:GIT_AUTHOR_DATE = $authorDate }
        if ($null -eq $committerDate) { Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue } else { $env:GIT_COMMITTER_DATE = $committerDate }
    }
}
function CommitPair([string]$Repo, [string]$FileA, [string]$TextA, [string]$FileB, [string]$TextB) {
    foreach ($file in @($FileA, $FileB)) {
        $destination = Join-Path $Repo $file
        New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
        Set-Content -LiteralPath $destination -Value $(if ($file -eq $FileA) { $TextA } else { $TextB })
    }
    $null = Invoke-FixtureGit $Repo @('add', '--', $FileA, $FileB)
    $null = Invoke-FixtureGit $Repo @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'shared-scope drift')
    (@(Invoke-FixtureGit $Repo @('rev-parse', 'HEAD'))[0]).Trim()
}
function CoreText([string]$FirstLine) { @($FirstLine, 'stable line 2', 'stable line 3', 'stable line 4', 'stable line 5', 'stable line 6', 'stable line 7', 'stable line 8', 'stable line 9', 'stable line 10') -join "`n" }
function RunIndex([string]$Folder, [string]$Run, [string[]]$Lines) {
    $dir = Join-Path $vault $Folder $Run
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @('---') + $Lines + @('---', '# fixture') | Set-Content -LiteralPath (Join-Path $dir '_index.md')
}
# Writes an _index.md verbatim, for shapes RunIndex's leading `---` wrapper cannot express.
function RunIndexRaw([string]$Folder, [string]$Run, [string[]]$Lines) {
    $dir = Join-Path $vault $Folder $Run
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Lines | Set-Content -LiteralPath (Join-Path $dir '_index.md')
}
try {
    $widget = Join-Path $repos 'widget'
    $docs = Join-Path $repos 'docsonly'
    $fresh = Join-Path $repos 'fresh'
    $reset = Join-Path $repos 'reset'
    $deleted = Join-Path $repos 'deleted'
    $sourceOld = Join-Path $repos 'source-old'
    $remediatedOffHead = Join-Path $repos 'remediated-offhead'
    $emptyRepo = Join-Path $repos 'emptygit'
    $renameCollision = Join-Path $repos 'renamecollision'
    foreach ($repo in @($widget, $docs, $fresh, $reset, $deleted, $sourceOld, $remediatedOffHead, $emptyRepo, $renameCollision)) { New-Item -ItemType Directory -Force -Path $repo | Out-Null; $null = Invoke-FixtureGit $repo @('init', '-q') }

    $oldRenameTip = Commit $renameCollision 'src/A.cs' (CoreText 'original A')
    $null = Invoke-FixtureGit $renameCollision @('rm', '-q', 'src/A.cs')
    $null = Invoke-FixtureGit $renameCollision @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'remove original A')
    $newRenameBase = (@(Invoke-FixtureGit $renameCollision @('rev-parse', 'HEAD'))[0]).Trim()
    $newRenameTip = Commit $renameCollision 'src/B.cs' (CoreText 'original B')
    $null = Invoke-FixtureGit $renameCollision @('mv', '--', 'src/B.cs', 'src/Shared.cs')
    $null = Invoke-FixtureGit $renameCollision @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'rename B to shared')
    RunIndex 'renamecollision' '20260101T000000Z' @('date: 2026-01-01', 'scope-kind: repository', "target: 4b825dc642cb6eb9a060e54bf8d69288fbee4904..$oldRenameTip")
    RunIndex 'renamecollision' '20260102T000000Z' @('date: 2026-01-02', 'scope-kind: repository', "target: $newRenameBase..$newRenameTip")

    $reviewBase = Commit $remediatedOffHead 'src/Base.cs' 'base'
    $null = Invoke-FixtureGit $remediatedOffHead @('switch', '-q', '-c', 'reviewed-branch')
    $offHeadTip = Commit $remediatedOffHead 'src/Reviewed.cs' 'reviewed branch'
    $null = Invoke-FixtureGit $remediatedOffHead @('switch', '-q', '-')
    $null = Commit $remediatedOffHead 'src/Main.cs' 'mainline moved'
    $remediationTip = Commit $remediatedOffHead 'src/Reviewed.cs' 'remediated output'
    RunIndex 'remediated-offhead' '20260101T000000Z' @('date: 2026-01-01', 'scope-kind: repository', "target: $reviewBase..$offHeadTip", 'disposition: remediated', "remediation-tip: $remediationTip", 'remediation-commits:', "  - $remediationTip")

    $deletedTip = Commit $deleted 'src/Gone.cs' 'reviewed before deletion'
    $null = Invoke-FixtureGit $deleted @('rm', '-q', 'src/Gone.cs')
    $null = Invoke-FixtureGit $deleted @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'delete reviewed source')
    RunIndex 'deleted' '20260101T000000Z' @('date: 2026-01-01', 'scope-kind: repository', "target: 4b825dc642cb6eb9a060e54bf8d69288fbee4904..$deletedTip", 'disposition: remediated')

    $sourceTip = Commit $sourceOld 'src/App.cs' 'reviewed source'
    $docsTip = Commit $sourceOld 'docs/readme.md' 'later docs-only review'
    RunIndex 'source-old' '20260101T000000Z' @('date: 2026-01-01', 'scope-kind: repository', "target: 4b825dc642cb6eb9a060e54bf8d69288fbee4904..$sourceTip", 'disposition: remediated')
    RunIndex 'source-old' '20260102T000000Z' @('date: 2026-01-02', 'scope-kind: subsystem', "target: $sourceTip..$docsTip", 'reviewed-paths:', '  - docs/readme.md', 'disposition: open')
    $null = Commit $sourceOld 'src/App.cs' 'older group drift after docs-only review'

    $c0 = Commit $widget 'src/Core.cs' (CoreText 'core')
    $null = Commit $widget 'docs/readme.md' 'docs'
    $t1 = Commit $widget 'src/UI/View.cs' 'ui'
    $t2 = Commit $widget 'src/UI/View.cs' 'ui reviewed change'
    # The panel reviewed a branch tip that rebase-merge later rewrote: same tree, different commit.
    $t2Tree = (@(Invoke-FixtureGit $widget @('rev-parse', "$t2^{tree}"))[0]).Trim()
    $reviewedTip = (@(Invoke-FixtureGit $widget @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit-tree', $t2Tree, '-p', $t1, '-m', 'branch tip before rebase'))[0]).Trim()
    $null = Invoke-FixtureGit $widget @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-qm', 'same reviewed tree')
    $reviewedBoundary = (@(Invoke-FixtureGit $widget @('rev-parse', 'HEAD'))[0]).Trim()
    $fix = Commit $widget 'src/UI/View.cs' 'ui remediation'
    $null = Commit $widget 'src/Core.cs' (CoreText 'core drift')
    $null = Commit $widget 'src/UI/View.cs' 'ui drift'
    $null = CommitPair $widget 'src/Core.cs' (CoreText 'shared core drift') 'src/UI/View.cs' 'shared ui drift'
    $null = Invoke-FixtureGit $widget @('mv', '--', 'src/Core.cs', 'src/RenamedCore.cs')
    $null = Invoke-FixtureGit $widget @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'rename covered core')
    $null = Commit $widget 'src/Billing/Pay.cs' 'never reviewed'
    $null = Commit $widget 'src/Billing/Pay.Designer.cs' 'generated, never reviewed'
    $newSourceFix = Commit $widget 'src/Billing/AlreadyFixed.cs' 'remediation-only source'
    $head = (@(Invoke-FixtureGit $widget @('rev-parse', 'HEAD'))[0]).Trim()
    $null = Commit $docs 'README.md' 'docs only'
    $null = Commit $fresh 'src/App.cs' 'fresh source'
    $oldRoot = CommitAt $reset 'src/legacy.txt' 'legacy root' '2026-01-20'
    $null = Invoke-FixtureGit $reset @('branch', 'old-history')
    $null = Invoke-FixtureGit $reset @('checkout', '-q', '-b', 'review-branch')
    $reviewTip = Commit $reset 'src/legacy.txt' 'reviewed legacy change'
    $resetFix = Commit $reset 'src/legacy.txt' 'remediated legacy change'
    $null = Invoke-FixtureGit $reset @('checkout', '-q', '--orphan', 'replacement')
    $null = Invoke-FixtureGit $reset @('rm', '-r', '-q', '-f', '--ignore-unmatch', '.')
    $newRoot = CommitAt $reset 'src/replacement.txt' 'Initial OSS release' '2026-01-10'
    $null = Invoke-FixtureGit $reset @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'merge', '-q', '--allow-unrelated-histories', 'old-history', '-m', 'join histories')
    RunIndex 'reset' '20260105T000000Z' @('date: 2026-01-05', 'scope-kind: repository', "target: 4b825dc642cb6eb9a060e54bf8d69288fbee4904..$reviewTip", 'disposition: remediated', "remediation-tip: $resetFix")
    # A vendored fork: source, no review, and deliberately never queued.
    $vendored = Join-Path $repos 'vendored'
    New-Item -ItemType Directory -Force -Path $vendored | Out-Null; $null = Invoke-FixtureGit $vendored @('init', '-q')
    $null = Commit $vendored 'src/Upstream.cs' 'upstream engine'
    # Legacy audit shapes: `audit ...` with a stated tip, and `X..X` with a Full-state audit note.
    $legacyRepo = Join-Path $repos 'legacy'
    New-Item -ItemType Directory -Force -Path $legacyRepo | Out-Null; $null = Invoke-FixtureGit $legacyRepo @('init', '-q')
    $l1 = Commit $legacyRepo 'src/A.cs' 'a'
    $l2 = Commit $legacyRepo 'src/B.cs' 'b'
    RunIndex 'legacy' '20260101T000000Z' @('date: 2026-01-01', 'target: audit -- src', "head: $l1", 'subsystem: src')
    RunIndex 'legacy' '20260102T000000Z' @('date: 2026-01-02', "target: $l2..$l2", 'scope-kind: subsystem', 'reviewed-paths:', '  - src', 'scope-note: Full-state audit of src at the target commit.')
    RunIndex 'legacy' '20260103T000000Z' @('date: 2026-01-03', 'target: audit -- src')
    RunIndex 'legacy' '20260104T000000Z' @('date: 2026-01-04', "target: audit:$l2")
    RunIndex 'legacy' '20260105T000000Z' @('date: 2025-12-30', "target: audit -- src (range $l1..$l2)", 'subsystem: src')
    RunIndex 'legacy' '20260106T000000Z' @('date: 2025-12-29', "target: audit -- src after $l1 then $l2", 'subsystem: src')

    RunIndex 'widget' '20260101T000000Z' @('date: 2026-01-01', 'scope-kind: repository', "target: 4b825dc642cb6eb9a060e54bf8d69288fbee4904..$t1", 'disposition: reviewed', "remediation-tip: $c0  # older than the reviewed tip; the reviewed tip stands")
    RunIndex 'widget' '20260102T000000Z' @('date: 2026-01-02', "target: $t1..HEAD", "head: $reviewedTip", 'subsystem:', '  - src/UI/**', 'excluded-paths:', '  - src/UI/Gen.cs  # generated, not reviewed', 'disposition: remediated', "remediation-tip: $fix", 'remediation-commits:', "  - $fix", "  - $newSourceFix")
    RunIndex 'widget' '20260103T000000Z' @('date: 2026-01-03', 'scope-kind: document', "target: $t2..$t2")
    RunIndex 'widget' '20260104T000000Z' @('date: 2026-01-04', 'reviewers: [a, b]')
    RunIndex 'widget-alias' '20251231T000000Z' @("repo-path: $widget", 'date: 2025-12-31', "target: $t1..$t2", 'subsystem: src/UI')
    RunIndex 'widget-alias' '20260105T000000Z' @("repo-path: $widget", 'date: 2026-01-05', 'scope-kind: subsystem', "target: $t1..$t2", 'reviewed-paths:', '  - src/Nope', '  - src/UI')
    RunIndex 'fresh' '20260111T000000Z' @("repo-path: $widget", 'date: 2026-01-11', 'scope-kind: repository', 'target: not-a-range')
    RunIndex 'unrelated' '20260106T000000Z' @('date: 2026-01-06', 'scope-kind: repository', "target: $t1..$t2")

    # A record that opens with a heading and carries its metadata in a fenced ```yaml block must
    # be read, and a leading `---` block must still win over any fence later in the same report --
    # otherwise a yaml example quoted in the prose could displace the record's own metadata.
    $fenced = Join-Path $repos 'fenced'
    New-Item -ItemType Directory -Force -Path $fenced | Out-Null; $null = Invoke-FixtureGit $fenced @('init', '-q')
    $f1 = Commit $fenced 'src/One.cs' 'one'
    $f2 = Commit $fenced 'src/Two.cs' 'two'
    RunIndexRaw 'fenced' '20260107T000000Z' @(
        '# Adversarial review - fenced fixture', '', '```yaml',
        'date: 2026-01-07', 'scope-kind: repository', "target: $f1..$f2", 'disposition: remediated', '```')
    # An incomplete run is usually a re-run of the same scope, so it carries the same target and
    # paths as its replacement. Left usable it competes with the good run, and on a same-date tie
    # can displace it. It must be excluded on the record's own declaration.
    RunIndex 'fenced' '20260109T000000Z' @(
        'date: 2026-01-09', 'scope-kind: repository', "target: $f1..$f2",
        'superseded-by: 20260107T000000Z', 'disposition: reviewed')
    RunIndexRaw 'fenced' '20260108T000000Z' @(
        '---', 'date: 2026-01-08', 'scope-kind: repository', "target: $f1..$f2", 'disposition: reviewed', '---',
        '# fixture', '', 'A quoted example, not this record''s metadata:', '', '```yaml',
        'date: 2020-01-01', 'target: deadbeef..deadbeef', '```')
    # A legacy record whose coverage was read and found unreconstructable. It must classify as
    # `coverage-waived` rather than `no-exact-target`, and it must NOT be dated: the waiver is
    # checked before the date so that a record too malformed to date can still carry one.
    RunIndex 'fenced' '20260110T000000Z' @(
        'coverage-waiver: predates the base..tip contract; no target recorded and no resolvable sha in the body')

    # An older group's commits from before the newest review must not enter the row total.
    # The one commit after the newest boundary still must, even though the older group owns the file.
    $split = Join-Path $repos 'split'
    New-Item -ItemType Directory -Force -Path $split | Out-Null
    $null = Invoke-FixtureGit $split @('init', '-q')
    $splitA = CommitAt $split 'src/A.cs' 'reviewed A' '2026-01-01'
    RunIndex 'split' '20260101T000000Z' @('date: 2026-01-01', 'scope-kind: repository', "target: 4b825dc642cb6eb9a060e54bf8d69288fbee4904..$splitA")
    $null = CommitAt $split 'src/A.cs' 'drift before later review' '2026-01-02'
    $splitBeforeB = (@(Invoke-FixtureGit $split @('rev-parse', 'HEAD'))[0]).Trim()
    $splitB = CommitAt $split 'src/B.cs' 'reviewed B' '2026-01-03'
    RunIndex 'split' '20260103T000000Z' @('date: 2026-01-03', 'scope-kind: subsystem', "target: $splitBeforeB..$splitB", 'reviewed-paths:', '  - src/B.cs')
    $null = CommitAt $split 'src/A.cs' 'drift after newest review' '2026-01-04'
    # Same shape as split, stopped before the post-boundary commit. The Jan 2 edit is
    # owned by the older review and is already in the tree the newer subsystem review saw.
    $splitStale = Join-Path $repos 'splitstale'
    New-Item -ItemType Directory -Force -Path $splitStale | Out-Null
    $null = Invoke-FixtureGit $splitStale @('init', '-q')
    $splitStaleA = CommitAt $splitStale 'src/A.cs' 'reviewed A' '2026-01-01'
    RunIndex 'splitstale' '20260101T000000Z' @('date: 2026-01-01', 'scope-kind: repository', "target: 4b825dc642cb6eb9a060e54bf8d69288fbee4904..$splitStaleA")
    $null = CommitAt $splitStale 'src/A.cs' 'drift before later review' '2026-01-02'
    $splitStaleBeforeB = (@(Invoke-FixtureGit $splitStale @('rev-parse', 'HEAD'))[0]).Trim()
    $splitStaleB = CommitAt $splitStale 'src/B.cs' 'reviewed B' '2026-01-03'
    RunIndex 'splitstale' '20260103T000000Z' @('date: 2026-01-03', 'scope-kind: subsystem', "target: $splitStaleBeforeB..$splitStaleB", 'reviewed-paths:', '  - src/B.cs')

    $data = Join-Path $root 'data.json'
    # Scope comes from an estate file, so its paths, vault root and exemptions are all exercised.
    $estateFile = Join-Path $root 'estate.json'
    @{ paths = @($repos); vaultRoot = $vault; exempt = @(@{ repo = 'vendored'; reason = 'vendored fixture fork' }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $estateFile
    & pwsh -NoProfile -File (Join-Path $skill 'collect.ps1') -EstateFile $estateFile -OutFile $data | Out-Null
    if ($LASTEXITCODE) { throw 'collector failed on fixture' }
    $rows = @(Get-Content -LiteralPath $data -Raw | ConvertFrom-Json)
    Check ($rows.Count -eq 14) 'one row per scanned repository, including empty and rename-collision Git repositories'
    $emptyVault = Join-Path $root 'empty-vault'
    New-Item -ItemType Directory -Force -Path $emptyVault | Out-Null
    & pwsh -NoProfile -File (Join-Path $skill 'collect.ps1') -Path $repos -VaultRoot $emptyVault -OutFile (Join-Path $root 'empty-data.json') 2>$null | Out-Null
    Check ($LASTEXITCODE -ne 0) 'a missing or empty vault cannot masquerade as zero review records'
    $overrideData = Join-Path $root 'override.json'
    & pwsh -NoProfile -File (Join-Path $skill 'collect.ps1') -EstateFile $estateFile -Exempt widget -OutFile $overrideData | Out-Null
    if ($LASTEXITCODE) { throw 'collector failed on explicit exemption override fixture' }
    $overrideRows = @(Get-Content -LiteralPath $overrideData -Raw | ConvertFrom-Json)
    Check (@($overrideRows | Where-Object repo -EQ 'widget')[0].queue -eq 'exempt' -and -not (@($overrideRows | Where-Object repo -EQ 'vendored')[0].exempt)) 'explicit exemption list replaces estate exemptions'
    $rescued = @($rows | Where-Object repo -EQ 'remediated-offhead')[0]
    Check (@($rescued.reviewCoverage).Count -eq 1 -and $rescued.reviewCoverage[0].boundarySha -eq $offHeadTip -and $rescued.reviewCoverage[0].files -eq 1 -and @($rescued.reviewCoverage[0].remediationFiles) -contains 'src/Reviewed.cs') "review boundary stays fixed and explicit remediation is reported separately: $(ConvertTo-Json $rescued.reviewCoverage -Compress)"
    $deletedRow = @($rows | Where-Object repo -EQ 'deleted')[0]
    Check ($deletedRow.reviewCoverage[0].files -eq 1 -and $deletedRow.reviewCoverage[0].commits -eq 1 -and @($deletedRow.reviewCoverage[0].changedFiles) -contains 'src/Gone.cs') 'deleted reviewed source remains in the drift count'
    $sourceOldRow = @($rows | Where-Object repo -EQ 'source-old')[0]
    Check ($sourceOldRow.hasTrackedSource -and $sourceOldRow.git.sinceReviewCount -eq 1 -and $sourceOldRow.reviewCoverage[0].commits -eq 0 -and $sourceOldRow.reviewCoverage[1].commits -eq 1) 'row totals keep an older group''s change when it landed after the newest boundary'
    Check ($sourceOldRow.openReviewCount -eq 1 -and $sourceOldRow.oldestOpenReviewDate -eq '2026-01-02') 'open review disposition and its filing date are included'
    $collision = @($rows | Where-Object repo -EQ 'renamecollision')[0]
    Check ($collision.reviewCoverage[0].date -eq '2026-01-02' -and $collision.reviewCoverage[0].files -eq 1 -and $collision.reviewCoverage[1].files -eq 0) 'the newest review owns a final path claimed through two older rename histories'

    $fx = @($rows | Where-Object repo -EQ 'fenced')[0]
    Check ($fx.vault.date -eq '2026-01-08' -and $fx.vault.disposition -eq 'reviewed') 'a leading --- block wins over a yaml fence later in the same report'
    Check (@($fx.reviewCoverage | Where-Object { $_.date -eq '2026-01-07' }).Count -eq 1) 'a record whose metadata is only in a fenced yaml block is read, not dropped as no-date'
    Check (@($fx.unusable | Where-Object reason -EQ 'no-date').Count -eq 0) 'neither fenced-fixture record is unusable'
    Check (@($fx.unusable | Where-Object reason -EQ 'superseded').Count -eq 1) 'a run declaring superseded-by is excluded on that declaration'
    Check (@($fx.reviewCoverage | Where-Object { $_.date -eq '2026-01-09' }).Count -eq 0) 'a superseded run never becomes coverage, even though it is the newest by date'
    $waived = @($fx.unusable | Where-Object reason -EQ 'coverage-waived')
    Check ($waived.Count -eq 1) 'a record carrying coverage-waiver classifies as coverage-waived, not no-exact-target'
    Check (@($fx.unusable | Where-Object reason -EQ 'no-date').Count -eq 0) 'a waiver is read before the date, so a record too malformed to date can still carry one'
    Check ($waived[0].waiver -match 'predates the base\.\.tip contract') 'the waiver reason reaches the report, so a reader sees WHY rather than only that it was waived'
    $l = @($rows | Where-Object repo -EQ 'legacy')[0]
    Check ($l.vault.date -eq '2026-01-02' -and $l.git.boundarySha -eq $l2 -and @($l.reviewCoverage).Count -eq 3) 'audit targets with a stated tip and Full-state tip..tip audits are snapshots on the empty tree'
    Check (@($l.reviewCoverage | Where-Object { $_.date -eq '2025-12-30' -and $_.boundarySha -eq $l2 }).Count -eq 1) 'an audit target naming a range takes its right-hand sha as the tip'
    Check (@($l.unusable | Where-Object reason -EQ 'audit-tip-ambiguous').Count -eq 1) 'an audit naming several shas and no range is ambiguous, not guessed'
    $snapshot = @($l.reviewCoverage | Where-Object boundarySha -EQ $l2)[0]
    Check ($snapshot.files -eq 2 -and $snapshot.commits -eq 0) 'a full-state audit covers every file at its tip'
    Check (@($l.unusable | Where-Object reason -EQ 'no-exact-target').Count -eq 1 -and @($l.unusable | Where-Object reason -EQ 'audit-scope-undeclared').Count -eq 1) 'an audit with no tip, or no declared scope, stays unusable'

    $w = @($rows | Where-Object repo -EQ 'widget')[0]
    Check ($w.headSha -eq $head -and $w.resolvedPath -eq $widget -and -not $w.unresolved -and -not $w.outsideScanPath) 'row identity is the scanned repository'
    Check ($w.vault.exists -and $w.vault.date -eq '2026-01-02' -and $w.vault.scopeKind -eq 'subsystem' -and $w.vault.disposition -eq 'remediated') 'newest usable run is the primary review'
    Check ($w.git.boundarySha -eq $reviewedBoundary -and $w.git.boundarySource -eq 'vault-target') 'the reviewed tree, including duplicate-tree resolution, remains the boundary'
    Check ($w.git.sinceReviewCount -eq 4 -and $w.git.sinceReviewFiles -eq 2 -and -not $w.git.neverReviewed -and -not $w.git.effectiveNeverReviewed) "row totals count changes after the newest boundary: $($w.git.sinceReviewCount)/$($w.git.sinceReviewFiles)"
    Check ($w.git.daysSinceReview -ge 0) 'days since review is measured'
    Check ($w.scopeValidation -eq 'invalid' -and $w.isSubsystem -and @($w.subsystemPaths) -contains 'src/Nope' -and $w.hasTrackedSource) 'a partly unmatched newest scope is invalid for consumers'
    $groups = @($w.reviewCoverage)
    Check ($groups.Count -eq 3) 'three usable runs give three coverage groups'
    $legacy = @($groups | Where-Object indexPath -Like '*widget-alias*20251231*')[0]
    Check ($legacy.files -eq 0 -and @($legacy.paths) -join ',' -eq 'src/UI') 'a legacy inline subsystem path is split correctly, and a newer run owns its files'
    $ui = @($groups | Where-Object indexPath -Like '*widget*20260102*')[0]
    $core = @($groups | Where-Object boundarySha -EQ $t1)[0]
    Check ($ui -and $core -and $ui.boundarySha -ne $fix) 'a rebased reviewed tip resolves to its matching tree; remediation does not move the boundary'
    Check ($ui.files -eq 1 -and $ui.commits -eq 2 -and @($ui.changedFiles) -join ',' -eq 'src/UI/View.cs' -and @($ui.remediationFiles).Count -eq 0) 'only the explicitly listed remediation commit is excluded from newer-scope drift'
    Check (@($ui.excludedPaths) -join ',' -eq 'src/UI/Gen.cs') 'list items drop trailing comments'
    Check ($core.files -eq 2 -and $core.commits -eq 3 -and @($core.changedFiles) -join ',' -eq 'src/RenamedCore.cs') "older ownership follows a renamed file and counts the shared commit once within its group: $($core.commits)/$($core.files)/$(@($core.changedFiles) -join ',')"
    Check (@($w.uncovered.files) -join ',' -eq 'src/Billing/AlreadyFixed.cs,src/Billing/Pay.Designer.cs,src/Billing/Pay.cs' -and @($w.uncovered.source) -join ',' -eq 'src/Billing/AlreadyFixed.cs,src/Billing/Pay.cs' -and $w.uncovered.sourceFiles -eq 2) 'files no usable review covered are reported, not certified; generated files are not source'
    $unusable = @($w.unusable)
    Check ($unusable.Count -eq 3) 'unusable runs are listed instead of silently dropped'
    Check (@($unusable | Where-Object reason -EQ 'no-exact-target').Count -eq 2) 'runs with no base..tip target are unusable'
    Check (@($unusable | Where-Object { $_.reason -eq 'reviewed-paths-unmatched' -and $_.indexPath -like '*widget-alias*' }).Count -eq 1) 'every reviewed-paths entry must match, even when a sibling entry matches'
    # Drift only. The uncovered floor (`100 + commits`) was removed 2026-09-13: it encoded an
    # assumption this estate does not hold, that every source file ought eventually to be
    # reviewed. It supplied 769 of one repository's 825 -- vendored upstream engine code
    # and DDTool output -- and ranked four repositories that had no commits at all since their
    # last review.
    $expected = 3
    Check ($w.score -eq $expected -and $w.git.sinceReviewCount -eq 4 -and $w.git.sinceReviewFiles -eq 2 -and $w.queue -eq 'new-source' -and @($w.newSource) -join ',' -eq 'src/Billing/Pay.cs' -and @($w.remediationFiles) -contains 'src/Billing/AlreadyFixed.cs') "workload excludes remediation-only source and counts distinct changed files plus new source (expected $expected, got $($w.score))"
    Check ($w.uncovered.sourceFiles -gt 0) 'uncovered source is still reported while contributing nothing to the score'

    $d = @($rows | Where-Object repo -EQ 'docsonly')[0]
    Check (-not $d.vault.exists -and $d.git.neverReviewed -and $d.git.effectiveNeverReviewed -and $d.scopeValidation -eq 'none' -and $d.hasTrackedSource -eq $false -and @($d.subsystemPaths).Count -eq 0 -and $d.score -eq 0) 'a repo with no source scores nothing and emits an empty path array'
    $f = @($rows | Where-Object repo -EQ 'fresh')[0]
    # A repository with source and no usable review is queued and scored, not sunk to zero beside
    # the vendored forks. Scoring it zero hid personal-tts's 48 unreviewed commits.
    Check ($f.git.neverReviewed -and $f.hasTrackedSource -and $f.queue -eq 'no-usable-review' -and $f.score -eq 1 -and $f.uncovered.sourceFiles -eq 1 -and $f.firstCommitDate) "source with no usable review is queued by distinct files (queue $($f.queue), score $($f.score))"
    Check (@($f.unusable).Count -eq 0) 'a repo-path record is not attached to the checkout named by its folder alone'
    $v = @($rows | Where-Object repo -EQ 'vendored')[0]
    Check ($v.queue -eq 'exempt' -and $v.exempt -and $v.exemptReason -eq 'vendored fixture fork' -and $v.score -eq 0 -and $v.uncovered.sourceFiles -eq 1) 'an exempt repository is reported with its reason and never queued'
    Check (-not $v.oldestUnreviewedChange) 'an exempt repository with no review does not report its first commit as a change age'
    $splitRow = @($rows | Where-Object repo -EQ 'split')[0]
    $splitOlder = @($splitRow.reviewCoverage | Where-Object date -EQ '2026-01-01')[0]
    $splitNewer = @($splitRow.reviewCoverage | Where-Object date -EQ '2026-01-03')[0]
    Check ($splitOlder.commits -eq 2 -and $splitNewer.commits -eq 0 -and $splitRow.git.sinceReviewCount -eq 1 -and $splitRow.git.sinceReviewFiles -eq 1 -and $splitRow.oldestUnreviewedChange -eq '2026-01-04' -and $splitRow.queue -eq 'drift' -and $splitRow.score -eq 1) "commits from before the newest review stay in their group and out of the row total: $(ConvertTo-Json $splitRow.git -Compress)"
    $stale = @($rows | Where-Object repo -EQ 'splitstale')[0]
    $staleOlder = @($stale.reviewCoverage | Where-Object date -EQ '2026-01-01')[0]
    $staleNewer = @($stale.reviewCoverage | Where-Object date -EQ '2026-01-03')[0]
    Check ($staleOlder.commits -eq 1 -and @($staleOlder.changedFiles) -contains 'src/A.cs' -and $staleNewer.commits -eq 0 -and $stale.git.sinceReviewCount -eq 0 -and $stale.git.sinceReviewFiles -eq 0 -and $stale.score -eq 0 -and $stale.queue -eq 'drift') "a change an older group owns, made before the newest boundary, stays out of the headline and still queues as drift: $(ConvertTo-Json $stale.git -Compress)"
    $emptyRow = @($rows | Where-Object repo -EQ 'emptygit')[0]
    Check ($emptyRow.queue -eq 'collector-error' -and $emptyRow.collectorError -eq 'No HEAD commit') 'a repo with no HEAD is reported as a collection error'
    Check ($d.queue -eq 'none') 'a repository with no source is not queued'
    $r = @($rows | Where-Object repo -EQ 'reset')[0]
    # A review whose history was replaced afterwards stays visible: its boundary is the remediated
    # state in the replaced history and drift is the tree diff from there, scored by changed files.
    Check (@($r.unusable | Where-Object reason -EQ 'history-reset-after-review').Count -eq 0) 'a reset review whose objects survive is not dropped as unusable'
    $rg = @($r.reviewCoverage)
    Check ($rg.Count -eq 1 -and $rg[0].historyReset -match "$newRoot \(2026-01-10\)") 'history reset detection searches every reachable root, including a non-first OSS-release root'
    Check ($rg[0].boundarySha -eq $reviewTip -and $r.git.boundarySha -eq $reviewTip) 'remediation tip does not move the reviewed boundary across a reset'
    Check (@($rg[0].changedFiles) -join ',' -eq 'src/legacy.txt' -and $rg[0].score -eq 1) "reset drift is the tree diff and workload counts changed files: $(ConvertTo-Json $rg[0] -Compress)"
    Check (@($r.uncovered.files) -contains 'src/replacement.txt') 'a file the replaced history never had is uncovered, not credited'

    $report = Join-Path $root 'digest.md'
    & pwsh -NoProfile -File (Join-Path $skill 'write-report.ps1') -DataFile $data -OutFile $report | Out-Null
    if ($LASTEXITCODE) { throw 'writer failed' }
    $md = Get-Content -LiteralPath $report -Raw
    foreach ($name in 'widget', 'docsonly', 'fresh') { Check ($md -match "(?m)^\| $name \|") "digest has a table row for $name" }
    Check ($md.Contains('## Columns') -and $md.Contains('| Repository | Queue | Last usable review | Review boundary |')) 'the digest opens with the column key and then the ranked table'
    Check ($md.Contains('- **Workload** — changed files plus new-source files.') -and $md.Contains('- **Uncovered source** —')) 'the column key states what workload and uncovered source count'
    $order = @($md -split "`n" | Where-Object { $_ -match '^\| (widget|docsonly|fresh|vendored) \|' } | ForEach-Object { ($_ -split '\|')[1].Trim() })
    Check (($order -join ',') -eq 'fresh,widget,docsonly,vendored' -or ($order -join ',') -eq 'fresh,widget,vendored,docsonly') "no-usable-review rows rank first, then drift by score: $($order -join ',')"
    Check ($md -match '(?m)^\| vendored \| exempt \| none \(exempt: vendored fixture fork\)') 'an exempt row shows its reason'
    $overrideReport = Join-Path $root 'override.md'
    & pwsh -NoProfile -File (Join-Path $skill 'write-report.ps1') -DataFile $overrideData -OutFile $overrideReport | Out-Null
    if ($LASTEXITCODE) { throw 'writer failed on the exemption override' }
    $overrideMd = Get-Content -LiteralPath $overrideReport -Raw
    Check ($overrideMd -match '(?m)^\| widget \| exempt \| 2026-01-02 \(subsystem\); exempt \|') 'an exempt row with a review and no reason does not print a dangling colon'
    Check ($md.Contains('### No usable review (ranked first)')) 'a no-usable-review repository gets a ranked review prompt, not the not-scored audit note'
    Check ($md.Contains("Target: $reviewTip..") -and $md.Contains("review the tree diff (git diff $reviewTip")) 'a reset review gets a tree-diff prompt from the reviewed boundary'
    Check ($md.Contains("Target: $reviewedBoundary..$head") -and $md.Contains('src/UI/View.cs')) 'the handoff prompt names the reviewed boundary and changed files'
    Check ($md.Contains('queued: new or changed since the newest review') -and $md.Contains('Reviewed-paths: src/Billing/Pay.cs')) 'new source gets a narrow, queued prompt'
    Check ($md.Contains("Target: 4b825dc642cb6eb9a060e54bf8d69288fbee4904..$head") -and $md.Contains('Reviewed-paths: src/Billing/Pay.cs')) 'uncovered source gets an audit prompt naming the exact files'
    Check ($md -notmatch '(?i)never reviewed') 'unusable evidence is never rendered as never reviewed'
    Check ($md.Contains('no-exact-target')) 'unusable records and their reasons are visible'
    # The waived record must be rendered apart from the unreadable ones, WITH its stated reason.
    # Without these three the whole write-report change is untested: dropping 'coverage-waived'
    # from $deliberateReasons leaves every other assertion here green while the headline goes
    # back to counting a decided record as a defect.
    # Assert against the REASON TABLE, not the whole section: `coverage-waived` legitimately
    # appears a few lines below it in the "Excluded on purpose" sentence, so a section-wide
    # -notmatch fails on correct output. Caught by running it.
    Check ($md -notmatch '(?m)^\| `coverage-waived` \|') 'a waived record is not listed in the unreadable reason table'
    $fencedRow = @($md -split "`n" | Where-Object { $_ -like '| fenced |*' })[0]
    Check (($fencedRow -split '\|')[11].Trim() -eq '0') 'superseded and waived records do not inflate the per-repository unreadable count'
    Check ($md -match '(?m)^Excluded on purpose and not counted above:.*coverage-waived') 'a waived record is counted as a deliberate exclusion'
    Check ($md.Contains('### Coverage waived') -and $md -match 'predates the base\.\.tip contract') 'the waived record gets its own heading and its stated reason reaches the digest'
    & pwsh -NoProfile -File (Join-Path $skill 'write-report.ps1') -DataFile $data -OutFile $report 2>$null | Out-Null
    Check ($LASTEXITCODE -ne 0 -and (Get-Content -LiteralPath $report -Raw) -ceq $md) 'a published digest is never overwritten'

    if ($failures.Count) { throw ($failures -join "`n") }
    'review-digest OK: coverage assignment, drift, unusable records, score, digest and prompts'
} finally {
    $full = [IO.Path]::GetFullPath($root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'fixture cleanup escaped temp' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
