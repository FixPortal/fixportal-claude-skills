[CmdletBinding()]
param(
  [string]$Path = (Get-Location).Path,
  [string]$OutFile = (Join-Path $env:TEMP 'review-digest-data.json'),
  [string]$VaultRoot = (Join-Path $HOME 'Obsidian Vault\Claude\Adversarial Review'),
  # Extra roots searched to resolve a vault folder whose code lives OUTSIDE $Path (e.g. a repo in
  # another working directory). Only used as a fallback when the report carries no file:/// links.
  # Default empty: pass your own repo-parent directories if reviews live outside the scan path.
  [string[]]$RepoRoots = @()
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Path -PathType Container)) {
  Write-Error "Path not a folder: $Path"; exit 2
}

# Markers that identify a review/remediation commit (case-insensitive).
$markerRegex = 'adversarial|reviewer-findings|reviewer findings|adversarial-audit|fix\(review\)|cross-vendor'

# Web-quality sweeps (react-doctor / optimise-web / a11y) are committed with the same
# reviewer-findings marker but are NOT adversarial reviews. They must never anchor the
# review boundary, or a repo with real unreviewed feature work reports a false sinceReview=0.
$webQualityRegex = 'react-doctor|optimi[sz]e-web|web-quality|a11y|accessibilit|lighthouse|perf micro'

# Enumerate top-level git repos under $Path.
$repos = Get-ChildItem $Path -Directory | Where-Object {
  Test-Path (Join-Path $_.FullName '.git')
}
if (-not $repos) { Write-Error "No git repos under $Path"; exit 3 }

function Get-VaultData {
  param([string]$RepoName, [string]$VaultRoot)
  $empty = [pscustomobject]@{ exists = $false; indexPath = $null; reviewers = @(); judge = $null; date = $null; reviewType = $null; tally = $null; reportFiles = @(); reviewTarget = $null; isDocumentReview = $false }
  $repoDir = Join-Path $VaultRoot $RepoName
  if (-not (Test-Path $repoDir)) { return $empty }
  # Each run is a timestamped subfolder holding _index.md. Pick the run with the newest frontmatter date (fallback: folder mtime).
  $runs = Get-ChildItem $repoDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName '_index.md') }
  if (-not $runs) { return $empty }
  $best = $null; $bestDate = [datetime]::MinValue; $bestName = ''
  foreach ($run in $runs) {
    $idx = Join-Path $run.FullName '_index.md'
    [datetime]$fmDate = [datetime]::MinValue
    $head = Get-Content $idx -TotalCount 12
    $dm = ($head | Select-String -Pattern '^date:\s*(\d{4}-\d{2}-\d{2})').Matches
    if ($dm.Count) { [datetime]::TryParse($dm[0].Groups[1].Value, [ref]$fmDate) | Out-Null }
    $effective = if ($fmDate -gt [datetime]::MinValue) { $fmDate } else { $run.LastWriteTime }
    # Frontmatter dates are day-granular, so two same-day runs of one repo tie. Break the tie
    # toward the later run FOLDER NAME (a sortable UTC timestamp, e.g. 20260528T221207Z) so the
    # newest run wins — not whichever Get-ChildItem happened to return first. Missing this picked
    # an earlier run whose report lacked the later run's scope sha, defeating sha resolution.
    if ($effective -gt $bestDate -or ($effective -eq $bestDate -and $run.Name -gt $bestName)) {
      $bestDate = $effective; $best = $run; $bestName = $run.Name
    }
  }
  if (-not $best) { return $empty }
  $idx = Join-Path $best.FullName '_index.md'
  $text = Get-Content $idx -Raw
  $reviewers = @(); $judge = $null; $date = $null; $reviewType = $null
  $rm = [regex]::Match($text, '(?im)^reviewers:\s*\[([^\]]*)\]')
  if ($rm.Success) { $reviewers = @($rm.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
  $jm = [regex]::Match($text, '(?im)^judge:\s*(.+)$');        if ($jm.Success) { $judge = $jm.Groups[1].Value.Trim() }
  $dm2 = [regex]::Match($text, '(?im)^date:\s*(\d{4}-\d{2}-\d{2})'); if ($dm2.Success) { $date = $dm2.Groups[1].Value }
  $tm = [regex]::Match($text, '(?im)^review-type:\s*(.+)$');  if ($tm.Success) { $reviewType = $tm.Groups[1].Value.Trim() }
  # A review's TARGET distinguishes a code review from a DOCUMENT review. A document review's
  # report carries e.g. `target: some-document.html` — a document, not code. Without recording
  # this, the resolver credits a document review as code coverage and the ledger keeps ranking a
  # reviewed document as an unreviewed code repo. A target ending in a document extension is not
  # code coverage.
  $reviewTarget = $null; $isDocumentReview = $false
  $gm = [regex]::Match($text, '(?im)^target:\s*(.+)$'); if ($gm.Success) { $reviewTarget = $gm.Groups[1].Value.Trim() }
  # Strip a surrounding matched YAML quote so `target: "report.pdf"` still hits the extension test.
  if ($reviewTarget -match '^([''"])(.*)\1$') { $reviewTarget = $Matches[2] }
  if ($reviewTarget -and $reviewTarget -match '\.(html?|pdf|docx?|md|txt|rtf|odt)\s*$') { $isDocumentReview = $true }
  # Tally: prefer a "## Tally" section; support inline "Label: N" and table "| Label | N |" forms.
  $tallyScope = if ($text -match '(?s)##\s*Tally[^\n]*\n(.*?)(?=\n##|\z)') { $Matches[1] } else { $text }
  $tally = $null
  $sev = @{}
  foreach ($label in 'Critical','High','Medium','Low') {
    $sm = [regex]::Match($tallyScope, "(?im)^\s*\|\s*$label\s*\|\s*(\d+)\s*\|")   # table row
    if (-not $sm.Success) { $sm = [regex]::Match($tallyScope, "(?im)$label\s*:\s*(\d+)") }  # inline
    if ($sm.Success) { $sev[$label] = [int]$sm.Groups[1].Value }
  }
  if ($sev.Count) { $tally = [pscustomobject]$sev }
  $reports = @(Get-ChildItem $best.FullName -Filter 'report*.md' | Select-Object -ExpandProperty Name)
  [pscustomobject]@{ exists = $true; indexPath = $idx; reviewers = $reviewers; judge = $judge; date = $date; reviewType = $reviewType; tally = $tally; reportFiles = $reports; reviewTarget = $reviewTarget; isDocumentReview = $isDocumentReview }
}

# Resolve a vault folder to the code it actually reviewed, via the file:/// links its
# report carries. A vault folder is NOT proof of a repo: it may name a SUBSYSTEM of one
# (e.g. a vault folder 'foo-svc' whose review covered host-repo/path/to/FooSvc). Without this,
# such a row gets an empty git side, remediation becomes undetectable, and it freezes at its
# original tally forever — reporting long-fixed findings as still outstanding. Returns the
# enclosing git repo + the subsystem sub-path within it.
function Resolve-VaultTarget {
  param([string]$IndexPath, [string]$FolderName, [string[]]$RepoRoots, [string]$ScanPath)
  $miss = [pscustomobject]@{ resolved = $false; repoPath = $null; repoName = $null; subsystemPath = $null }
  if (-not $IndexPath) { return $miss }
  $dir = Split-Path $IndexPath -Parent
  $files = @($IndexPath) + @(Get-ChildItem $dir -Filter 'report*.md' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
  $texts = foreach ($f in $files) { $x = Get-Content $f -Raw -ErrorAction SilentlyContinue; if ($x) { $x } }

  $paths = foreach ($t in $texts) {
    # Percent-decode: a standard file:/// link encodes a space as %20, which would otherwise
    # survive into the path, fail Test-Path, and mark a valid folder unresolved. The capture
    # stops at ')', whitespace and '#' so a markdown link and its #L40-L56 fragment resolve to
    # the file itself, and a URI mentioned in prose does not swallow the sentence after it.
    foreach ($m in [regex]::Matches($t, 'file:///([A-Za-z]:/[^)\s#]+)')) {
      ([Uri]::UnescapeDataString($m.Groups[1].Value) -replace '/', '\')
    }
  }
  $paths = @($paths | Where-Object { $_ } | Select-Object -Unique)

  # (1) file:/// links → walk each up to its nearest enclosing git repo; the most-linked repo wins.
  # Strongest signal: the link points at a file the review actually touched. A stale link whose
  # path no longer exists on disk simply finds no .git and drops through to the sha/name fallback.
  if ($paths) {
    $hits = foreach ($p in $paths) {
      $cur = $p
      while ($cur -and -not (Test-Path (Join-Path $cur '.git'))) {
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { $cur = $null; break }
        $cur = $parent
      }
      if ($cur) { $cur }
    }
    $hits = @($hits)
    if ($hits) { return (Get-SubsystemTarget -Paths $paths -Hits $hits) }
  }

  # (2) scope-sha resolution — falsifiable, so preferred over a name guess. The report's
  # `scope: <sha>..HEAD` names the boundary the panel reviewed; that commit resolves in the repo
  # whose history contains it, or in NONE. This is what survives a PREFIX rename (old-name ->
  # prefixed-old-name) that both the file:/// walk-up and the name search miss: the sha does not
  # care what the folder or the repo is called. The all-zero empty-tree sha of a first-commit
  # `0000000..x` diff is ignored — it resolves in every repo and proves nothing.
  $candidates = @(
    foreach ($root in @(@($ScanPath) + @($RepoRoots) | Where-Object { $_ -and (Test-Path $_) })) {
      Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName '.git') }
    }
  )
  $scopeSha = $null
  foreach ($tx in $texts) {
    $sm = [regex]::Match($tx, '(?im)scope:\**\s*`?([0-9a-f]{7,40})\.\.')
    if ($sm.Success -and ($sm.Groups[1].Value -notmatch '^0+$')) { $scopeSha = $sm.Groups[1].Value; break }
  }
  if ($scopeSha) {
    foreach ($c in $candidates) {
      & git -C $c.FullName cat-file -e "$scopeSha^{commit}" 2>$null
      if ($LASTEXITCODE -eq 0) {
        return [pscustomobject]@{ resolved = $true; repoPath = $c.FullName; repoName = $c.Name; subsystemPath = $null }
      }
    }
  }

  # (3) name search — weakest, a plausible guess not a proof. Normalised so a de-hyphenated
  # variant matches ('quickfixn' finds 'quickfix-n'); and suffix/substring so a PREFIX rename
  # resolves too ('old-name' finds 'prefixed-old-name'). Staged exact -> suffix -> contains,
  # closest first. The length guard keeps a short folder name from spuriously containing itself
  # in an unrelated repo.
  $want = ($FolderName -replace '[^a-z0-9]', '').ToLowerInvariant()
  if ($want.Length -ge 4) {
    foreach ($mode in 'eq', 'suffix', 'contains') {
      $byName = $candidates | Where-Object {
        $n = ($_.Name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        switch ($mode) {
          'eq'       { $n -eq $want }
          'suffix'   { $want.Length -ge 5 -and $n.EndsWith($want) }
          'contains' { $want.Length -ge 5 -and $n.Contains($want) }
        }
      } | Select-Object -First 1
      if ($byName) {
        return [pscustomobject]@{ resolved = $true; repoPath = $byName.FullName; repoName = $byName.Name; subsystemPath = $null }
      }
    }
  }
  return $miss
}

# Derive the enclosing repo + subsystem sub-path from file:/// walk-up hits. Split out of
# Resolve-VaultTarget so the file-link branch can return early while the sha/name fallbacks stay
# flat below it.
function Get-SubsystemTarget {
  param([string[]]$Paths, [string[]]$Hits)
  $repoPath = ($hits | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
  # Deepest common directory of the linked files, relative to the repo root = the subsystem.
  # The separator boundary is load-bearing: a bare StartsWith($repoPath) also swallows SIBLING
  # repos whose name merely extends this one — e.g. a repo 'svc' that is a strict prefix of a
  # sibling 'svc-extended', two repos that link to each other. Without the boundary a sibling's
  # path yields a relative segment like '-extended\src\x.cs', which corrupts the common-prefix
  # walk and the derived subsystem.
  $repoPrefix = $repoPath.TrimEnd('\') + '\'
  $rels = @($paths | Where-Object {
      $_.Equals($repoPath, [StringComparison]::OrdinalIgnoreCase) -or
      $_.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)
    } |
    ForEach-Object { $_.Substring($repoPath.Length).TrimStart('\') } | Where-Object { $_ })
  $sub = $null
  if ($rels) {
    $segs = @($rels | ForEach-Object { , @($_ -split '\\') })
    $common = @()
    for ($i = 0; $i -lt ($segs | ForEach-Object { $_.Count } | Measure-Object -Minimum).Minimum; $i++) {
      $seg = $segs[0][$i]
      if (@($segs | Where-Object { $_[$i] -ne $seg }).Count) { break }
      $common += $seg
    }
    # Drop a trailing file name (a leaf with an extension is not a directory). The Count -gt 1
    # guard is load-bearing: for a single segment, $common[0..($common.Count - 2)] is
    # $common[0..-1], and PowerShell expands 0..-1 to the range 0,-1 — indexing element 0 AND
    # the last element, which DUPLICATES the sole segment instead of dropping it. That yielded
    # subsystemPath='Program.cs\Program.cs' and isSubsystem=$true — a false subsystem, the exact
    # misclassification this function exists to prevent. Reachable whenever a report's only
    # file:/// links point at a repo-root file.
    if ($common.Count -and $common[-1] -match '\.\w+$') {
      $common = if ($common.Count -gt 1) { $common[0..($common.Count - 2)] } else { @() }
    }
    if ($common.Count) { $sub = ($common -join '\') }
  }
  [pscustomobject]@{
    resolved = $true; repoPath = $repoPath
    repoName = (Split-Path $repoPath -Leaf); subsystemPath = $sub
  }
}

# Compute the git side (review commits, boundary, forward scope) for a repo working tree.
# Used for both in-path repos and resolved vault-only targets, so remediation is detectable
# in BOTH cases — an outsideScanPath row must never be silently unfalsifiable.
function Get-GitSide {
  param([string]$RepoPath, $Vault, [string]$MarkerRegex, [string]$WebQualityRegex, [string]$SubsystemPath)
  # When the review covered a SUBSYSTEM, every evidence query must be scoped to it by pathspec.
  # Otherwise the host repo's unrelated activity is attributed to the subsystem: a subsystem row
  # would report ALL of the host repo's post-boundary commits as subsystem work, and any unrelated
  # reviewer-findings commit elsewhere in the host would read as subsystem remediation. Detecting
  # remediation is worthless if the number attached to it is the wrong repo's.
  $pathspec = @()
  if ($SubsystemPath) { $pathspec = @('--', $SubsystemPath) }
  # One git call: full log with body, ISO date, and author trailers, NUL-delimited records.
  $fmt = '%H%x1f%cI%x1f%s%x1f%b%x1e'
  $raw = & git -C $RepoPath log --all "--format=$fmt" @pathspec 2>$null
  if ($LASTEXITCODE -ne 0) { $raw = '' }
  $records = ($raw -join "`n") -split "`u{1e}" | Where-Object { $_.Trim() }

  $reviewCommits = foreach ($rec in $records) {
    $parts = $rec -split "`u{1f}"
    $sha = $parts[0].Trim(); $date = $parts[1].Trim(); $subject = $parts[2].Trim(); $body = if ($parts.Count -gt 3) { $parts[3] } else { '' }
    if ("$subject`n$body" -notmatch $MarkerRegex) { continue }
    $fixer = ''
    $m = [regex]::Match("$body", '(?im)^Co-Authored-By:\s*(Claude [^<]+?)\s*<')
    if ($m.Success) { $fixer = $m.Groups[1].Value.Trim() }
    $dateShort = if ($date.Length -ge 10) { $date.Substring(0,10) } else { $date }
    [pscustomobject]@{ sha = $sha; date = $dateShort; subject = $subject; body = $body.Trim(); fixerModel = $fixer }
  }
  $reviewCommits = @($reviewCommits | Group-Object sha | ForEach-Object { $_.Group[0] })

  # Raw batch markers (deduped, order-preserving) from subjects.
  $batchMarkers = @($reviewCommits | ForEach-Object {
    $bm = [regex]::Match($_.subject, '(?i)(batch\s*\d+|reviewer-findings batch\s*\d+|audit batch\s*\d+|B\d+)')
    if ($bm.Success) { $bm.Value }
  } | Group-Object { ($_ -replace '\s+','').ToLowerInvariant() } | ForEach-Object { $_.Group[0] })

  # Boundary selection — the last point a genuine ADVERSARIAL review saw this tree.
  # Priority: (1) the vault adversarial-review date; (2) the newest non-web-quality git
  # review/remediation commit. A web-quality reviewer-findings commit never anchors the boundary.
  $boundarySha = $null; $lastReviewDate = $null; $boundarySource = 'none'; $vaultPredatesHistory = $false
  if ($Vault.exists -and $Vault.date) {
    # Tree the panel reviewed = last commit on/before the vault review date.
    $bs = & git -C $RepoPath log --until="$($Vault.date) 23:59:59" -1 --format='%H' @pathspec 2>$null
    if ($LASTEXITCODE -eq 0 -and $bs -and "$bs".Trim()) {
      $boundarySha = "$bs".Trim(); $lastReviewDate = $Vault.date; $boundarySource = 'vault-date'
    } else {
      # Vault review predates the repo's earliest commit (e.g. an OSS re-init history squash):
      # the whole current tree is adversarially unreviewed. Anchor at the root commit.
      $rootSha = & git -C $RepoPath rev-list --max-parents=0 HEAD 2>$null | Select-Object -First 1
      if ($rootSha) { $boundarySha = "$rootSha".Trim() }
      $lastReviewDate = $Vault.date; $boundarySource = 'vault-predates-history'; $vaultPredatesHistory = $true
    }
  } else {
    # No vault report: fall back to git markers, excluding web-quality sweeps from boundary candidacy.
    $adversarialCommits = @($reviewCommits | Where-Object { $_.subject -notmatch $WebQualityRegex })
    $lastReviewCommit = if ($adversarialCommits) { $adversarialCommits | Sort-Object date -Descending | Select-Object -First 1 } else { $null }
    if ($lastReviewCommit) { $boundarySha = $lastReviewCommit.sha; $lastReviewDate = $lastReviewCommit.date; $boundarySource = 'git-marker' }
  }
  $neverReviewed = [bool](-not $boundarySha)

  # Forward-looking scope: commits since the last review (the next review's candidate scope).
  $sinceReview = @(); $sinceFiles = 0; $sinceIns = 0; $sinceDel = 0; $sinceCount = 0
  if ($boundarySha) {
    $rangeFmt = '%H%x1f%cI%x1f%s%x1e'
    $rawSince = & git -C $RepoPath log "$boundarySha..HEAD" "--format=$rangeFmt" @pathspec 2>$null
    if ($LASTEXITCODE -eq 0 -and $rawSince) {
      $srecs = ($rawSince -join "`n") -split "`u{1e}" | Where-Object { $_.Trim() }
      $sinceReview = @(foreach ($rec in $srecs) {
        $p = $rec -split "`u{1f}"
        $sd = $p[1].Trim(); $sd = if ($sd.Length -ge 10) { $sd.Substring(0,10) } else { $sd }
        [pscustomobject]@{ sha = $p[0].Trim(); date = $sd; subject = $p[2].Trim() }
      })
      $stat = & git -C $RepoPath diff --shortstat "$boundarySha..HEAD" @pathspec 2>$null
      if ($stat) {
        $statStr = "$stat"
        $fm2 = [regex]::Match($statStr, '(\d+) files? changed'); if ($fm2.Success) { $sinceFiles = [int]$fm2.Groups[1].Value }
        $im2 = [regex]::Match($statStr, '(\d+) insertion');      if ($im2.Success) { $sinceIns   = [int]$im2.Groups[1].Value }
        $dm3 = [regex]::Match($statStr, '(\d+) deletion');       if ($dm3.Success) { $sinceDel   = [int]$dm3.Groups[1].Value }
      }
    }
    $sinceCount = $sinceReview.Count
  } else {
    # Never reviewed: don't dump the whole history — record full-scope commit count only.
    $rc = & git -C $RepoPath rev-list --count HEAD @pathspec 2>$null
    if ($LASTEXITCODE -eq 0 -and $rc) { $sinceCount = [int]("$rc".Trim()) }
  }

  # Staleness in whole days (script clock; report is day-granular).
  $daysSinceReview = $null
  if ($lastReviewDate) {
    [datetime]$lrd = [datetime]::MinValue
    if ([datetime]::TryParse($lastReviewDate, [ref]$lrd)) {
      $daysSinceReview = [int]((Get-Date).Date - $lrd.Date).TotalDays
    }
  }

  [pscustomobject]@{
    reviewCommits   = $reviewCommits
    lastReviewDate  = $lastReviewDate
    batchMarkers    = $batchMarkers
    boundarySha     = $boundarySha
    boundarySource  = $boundarySource
    vaultPredatesHistory = $vaultPredatesHistory
    neverReviewed   = $neverReviewed
    sinceReview     = $sinceReview
    sinceReviewCount = $sinceCount
    sinceReviewFiles = $sinceFiles
    sinceReviewIns  = $sinceIns
    sinceReviewDel  = $sinceDel
    daysSinceReview = $daysSinceReview
  }
}

# Does the repo (or, for a subsystem row, its reviewed sub-path) track any source file? A repo
# with ZERO tracked source — a docs/spec repo, a playbook repo, a CV/resume repo — is not
# code-reviewable, so the never-reviewed floor of 100 must not float it above a genuinely
# unreviewed code repo. Exposed as hasTrackedSource; SKILL.md section 4 voids the floor when false.
# When a SubsystemPath is given the query is pathspec-scoped to it, so a docs-only subsystem of a
# code-bearing host is not credited with the host's unrelated source.
$sourceExtRegex = '\.(cs|ts|tsx|js|jsx|mjs|cjs|py|go|java|rb|rs|cpp|cc|c|h|hpp|kt|swift|php|scala|sql|ps1|psm1|sh|bicep|vue|svelte|fs|fsx)$'
function Get-HasTrackedSource {
  param([string]$RepoPath, [string]$SubsystemPath)
  if (-not $RepoPath) { return $false }
  $pathspec = if ($SubsystemPath) { @('--', $SubsystemPath) } else { @() }
  $out = & git -C $RepoPath ls-files @pathspec 2>$null | Where-Object { $_ -match $sourceExtRegex } | Select-Object -First 1
  if ($LASTEXITCODE -ne 0) { return $false }
  return [bool]$out
}

$results = foreach ($r in $repos) {
  $repoPath = $r.FullName
  # Vault first — its adversarial-review date is the preferred boundary (the tree a panel saw).
  $vault = Get-VaultData -RepoName $r.Name -VaultRoot $VaultRoot
  $git = Get-GitSide -RepoPath $repoPath -Vault $vault -MarkerRegex $markerRegex -WebQualityRegex $webQualityRegex

  [pscustomobject]@{
    repo = $r.Name
    git  = $git
    vault = $vault
    hasGraphify = [bool](Test-Path (Join-Path $repoPath 'graphify-out'))
    hasTrackedSource = Get-HasTrackedSource -RepoPath $repoPath
    outsideScanPath = $false
    resolvedPath = $repoPath
    isSubsystem = $false
    subsystemPath = $null
    unresolved = $false
  }
}

# Vault review folders with no matching repo under $Path. A folder here is NOT proof of a
# repo — it may name a SUBSYSTEM of one. Resolve each to real code via its report's file:///
# links and compute a genuine git side against that repo, so remediation is DETECTABLE.
# Anything that will not resolve is emitted as unresolved=true, never as a silent frozen row.
$scanned = @($results | ForEach-Object { $_.repo })
if (Test-Path $VaultRoot) {
  $vaultOnly = Get-ChildItem $VaultRoot -Directory | Where-Object { $scanned -notcontains $_.Name }
  # Track outside targets already emitted THIS pass, keyed on repo + subsystem, so two differently
  # named vault folders resolving to the same outside repo (a de-hyphen + a suffix match, or an old
  # and a current folder) do not both emit and double-count it. Distinct subsystems of one host
  # stay distinct (the key includes the sub-path).
  $resolvedThisPass = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $extra = @(foreach ($v in $vaultOnly) {
    $vd = Get-VaultData -RepoName $v.Name -VaultRoot $VaultRoot
    if (-not $vd.exists) { continue }
    $target = Resolve-VaultTarget -IndexPath $vd.indexPath -FolderName $v.Name -RepoRoots $RepoRoots -ScanPath $Path
    if ($target.resolved) {
      # A WHOLE-REPO resolution (no subsystemPath) onto an already-scanned in-path repo is a stale
      # pre-rename duplicate (old-name -> prefixed-old-name): drop it — but if that in-path row
      # carries no vault of its own, backfill it first, so a repo whose ONLY review lives under the
      # old folder name is not left falsely never-reviewed. A resolution WITH a subsystemPath is a
      # DISTINCT subsystem of that host and must still emit its own row, never be swallowed here.
      if (-not $target.subsystemPath) {
        $inPath = $results | Where-Object { $_.repo -eq $target.repoName -and -not $_.outsideScanPath } | Select-Object -First 1
        if ($inPath) {
          if (-not $inPath.vault.exists -and $vd.exists) {
            $inPath.vault = $vd
            $inPath.git = Get-GitSide -RepoPath $inPath.resolvedPath -Vault $vd -MarkerRegex $markerRegex -WebQualityRegex $webQualityRegex
            $inPath.hasTrackedSource = Get-HasTrackedSource -RepoPath $inPath.resolvedPath
          }
          continue
        }
      }
      # Second (and later) vault folder resolving to the same outside repo+subsystem: skip.
      if (-not $resolvedThisPass.Add("$($target.repoName)|$($target.subsystemPath)")) { continue }
      $git = Get-GitSide -RepoPath $target.repoPath -Vault $vd -MarkerRegex $markerRegex -WebQualityRegex $webQualityRegex -SubsystemPath $target.subsystemPath
      [pscustomobject]@{
        repo = $v.Name
        git  = $git
        vault = $vd
        hasGraphify = [bool](Test-Path (Join-Path $target.repoPath 'graphify-out'))
        hasTrackedSource = Get-HasTrackedSource -RepoPath $target.repoPath -SubsystemPath $target.subsystemPath
        outsideScanPath = $true
        resolvedPath = $target.repoPath
        # A SUBSYSTEM row is one whose reviewed code is a sub-path of the host repo
        # (a vault folder whose review covered host-repo/path/to/subsystem). A mere name variance
        # (vault 'quickfixn' -> repo 'quickfix-n') is NOT a subsystem — same tree, so keying this
        # off the sub-path rather than the name keeps the two apart.
        isSubsystem = [bool]$target.subsystemPath
        subsystemPath = $target.subsystemPath
        unresolved = $false
      }
    } else {
      [pscustomobject]@{
        repo = $v.Name
        git  = [pscustomobject]@{
          reviewCommits = @(); lastReviewDate = $vd.date; batchMarkers = @()
          boundarySha = $null; boundarySource = 'unresolved-vault-folder'; vaultPredatesHistory = $false
          # neverReviewed stays $false DESPITE the null boundarySha, and the exception is
          # deliberate. Elsewhere a null boundary means "no review ever happened"; here a review
          # demonstrably DID happen (vault.exists) — we simply cannot place the code it covered.
          # Flagging it $true would assert a falsehood and, worse, score it 100 + commits, floating
          # an unknown straight to the top of the risk rank. The state is UNKNOWN, not "never".
          # SKILL.md qualifies the neverReviewed contract accordingly and excludes unresolved rows
          # from ranking outright.
          neverReviewed = $false; sinceReview = @()
          sinceReviewCount = 0; sinceReviewFiles = 0; sinceReviewIns = 0; sinceReviewDel = 0
          daysSinceReview = $null
        }
        vault = $vd
        hasGraphify = $false
        hasTrackedSource = $false
        outsideScanPath = $true
        resolvedPath = $null
        isSubsystem = $false
        subsystemPath = $null
        unresolved = $true
      }
    }
  })
  $results = @($results) + @($extra)
}

# A DOCUMENT review (a report whose `target:` is a document, e.g. some-document.html) that
# resolves to no code repo is EXPECTED to be unresolved — it reviewed a document, not a tree — so
# it is not a collector defect and must not share the unfalsifiable-tally warning. Split the two so
# a genuine resolution failure (a code review whose repo could not be placed) still stands out.
$unresolvedRows = @($results | Where-Object { $_.unresolved -and -not $_.vault.isDocumentReview })
$docReviewRows  = @($results | Where-Object { $_.unresolved -and $_.vault.isDocumentReview })
if ($unresolvedRows) {
  Write-Warning ("UNRESOLVED vault folders (no repo found via file:/// links, scope sha, or name) — " +
    "their tallies are UNFALSIFIABLE and must NOT be reported as outstanding: " +
    (($unresolvedRows | ForEach-Object { $_.repo }) -join ', '))
}
if ($docReviewRows) {
  Write-Warning ("DOCUMENT reviews (reviewed a document, NOT code — confer no code coverage, do not " +
    "credit as a reviewed repo): " +
    (($docReviewRows | ForEach-Object { "$($_.repo) [$($_.vault.reviewTarget)]" }) -join ', '))
}

$results | ConvertTo-Json -Depth 8 | Set-Content $OutFile -Encoding utf8
Write-Output "wrote $OutFile ($(@($results).Count) repos)"
