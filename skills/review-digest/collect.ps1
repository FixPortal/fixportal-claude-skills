[CmdletBinding()]
param(
  [string]$Path = (Get-Location).Path,
  [string]$OutFile = (Join-Path $env:TEMP 'review-digest-data.json'),
  [string]$VaultRoot = (Join-Path $HOME 'Obsidian Vault\Claude\Adversarial Review')
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
  $empty = [pscustomobject]@{ exists = $false; indexPath = $null; reviewers = @(); judge = $null; date = $null; reviewType = $null; tally = $null; reportFiles = @() }
  $repoDir = Join-Path $VaultRoot $RepoName
  if (-not (Test-Path $repoDir)) { return $empty }
  # Each run is a timestamped subfolder holding _index.md. Pick the run with the newest frontmatter date (fallback: folder mtime).
  $runs = Get-ChildItem $repoDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName '_index.md') }
  if (-not $runs) { return $empty }
  $best = $null; $bestDate = [datetime]::MinValue
  foreach ($run in $runs) {
    $idx = Join-Path $run.FullName '_index.md'
    [datetime]$fmDate = [datetime]::MinValue
    $head = Get-Content $idx -TotalCount 12
    $dm = ($head | Select-String -Pattern '^date:\s*(\d{4}-\d{2}-\d{2})').Matches
    if ($dm.Count) { [datetime]::TryParse($dm[0].Groups[1].Value, [ref]$fmDate) | Out-Null }
    $effective = if ($fmDate -gt [datetime]::MinValue) { $fmDate } else { $run.LastWriteTime }
    if ($effective -gt $bestDate) { $bestDate = $effective; $best = $run }
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
  [pscustomobject]@{ exists = $true; indexPath = $idx; reviewers = $reviewers; judge = $judge; date = $date; reviewType = $reviewType; tally = $tally; reportFiles = $reports }
}

$results = foreach ($r in $repos) {
  $repoPath = $r.FullName
  # Vault first — its adversarial-review date is the preferred boundary (the tree a panel saw).
  $vault = Get-VaultData -RepoName $r.Name -VaultRoot $VaultRoot
  # One git call: full log with body, ISO date, and author trailers, NUL-delimited records.
  $fmt = '%H%x1f%cI%x1f%s%x1f%b%x1e'
  $raw = & git -C $repoPath log --all "--format=$fmt" 2>$null
  if ($LASTEXITCODE -ne 0) { $raw = '' }
  $records = ($raw -join "`n") -split "`u{1e}" | Where-Object { $_.Trim() }

  $reviewCommits = foreach ($rec in $records) {
    $parts = $rec -split "`u{1f}"
    $sha = $parts[0].Trim(); $date = $parts[1].Trim(); $subject = $parts[2].Trim(); $body = if ($parts.Count -gt 3) { $parts[3] } else { '' }
    if ("$subject`n$body" -notmatch $markerRegex) { continue }
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
  if ($vault.exists -and $vault.date) {
    # Tree the panel reviewed = last commit on/before the vault review date.
    $bs = & git -C $repoPath log --until="$($vault.date) 23:59:59" -1 --format='%H' 2>$null
    if ($LASTEXITCODE -eq 0 -and $bs -and "$bs".Trim()) {
      $boundarySha = "$bs".Trim(); $lastReviewDate = $vault.date; $boundarySource = 'vault-date'
    } else {
      # Vault review predates the repo's earliest commit (e.g. an OSS re-init history squash):
      # the whole current tree is adversarially unreviewed. Anchor at the root commit.
      $rootSha = & git -C $repoPath rev-list --max-parents=0 HEAD 2>$null | Select-Object -First 1
      if ($rootSha) { $boundarySha = "$rootSha".Trim() }
      $lastReviewDate = $vault.date; $boundarySource = 'vault-predates-history'; $vaultPredatesHistory = $true
    }
  } else {
    # No vault report: fall back to git markers, excluding web-quality sweeps from boundary candidacy.
    $adversarialCommits = @($reviewCommits | Where-Object { $_.subject -notmatch $webQualityRegex })
    $lastReviewCommit = if ($adversarialCommits) { $adversarialCommits | Sort-Object date -Descending | Select-Object -First 1 } else { $null }
    if ($lastReviewCommit) { $boundarySha = $lastReviewCommit.sha; $lastReviewDate = $lastReviewCommit.date; $boundarySource = 'git-marker' }
  }
  $neverReviewed = [bool](-not $boundarySha)

  # Forward-looking scope: commits since the last review (the next review's candidate scope).
  $sinceReview = @(); $sinceFiles = 0; $sinceIns = 0; $sinceDel = 0; $sinceCount = 0
  if ($boundarySha) {
    $rangeFmt = '%H%x1f%cI%x1f%s%x1e'
    $rawSince = & git -C $repoPath log "$boundarySha..HEAD" "--format=$rangeFmt" 2>$null
    if ($LASTEXITCODE -eq 0 -and $rawSince) {
      $srecs = ($rawSince -join "`n") -split "`u{1e}" | Where-Object { $_.Trim() }
      $sinceReview = @(foreach ($rec in $srecs) {
        $p = $rec -split "`u{1f}"
        $sd = $p[1].Trim(); $sd = if ($sd.Length -ge 10) { $sd.Substring(0,10) } else { $sd }
        [pscustomobject]@{ sha = $p[0].Trim(); date = $sd; subject = $p[2].Trim() }
      })
      $stat = & git -C $repoPath diff --shortstat "$boundarySha..HEAD" 2>$null
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
    $rc = & git -C $repoPath rev-list --count HEAD 2>$null
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

  $hasGraphify = [bool](Test-Path (Join-Path $repoPath 'graphify-out'))

  [pscustomobject]@{
    repo = $r.Name
    git  = [pscustomobject]@{
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
    vault = $vault
    hasGraphify = $hasGraphify
    outsideScanPath = $false
  }
}

# Repos with a vault review folder but NOT under $Path (reviewed from a different repos-root).
$scanned = @($results | ForEach-Object { $_.repo })
if (Test-Path $VaultRoot) {
  $vaultOnly = Get-ChildItem $VaultRoot -Directory | Where-Object { $scanned -notcontains $_.Name }
  $extra = @(foreach ($v in $vaultOnly) {
    $vd = Get-VaultData -RepoName $v.Name -VaultRoot $VaultRoot
    if (-not $vd.exists) { continue }
    [pscustomobject]@{
      repo = $v.Name
      git  = [pscustomobject]@{
        reviewCommits = @(); lastReviewDate = $null; batchMarkers = @()
        boundarySha = $null; boundarySource = 'outside-scan-path'; vaultPredatesHistory = $false
        neverReviewed = $false; sinceReview = @()
        sinceReviewCount = 0; sinceReviewFiles = 0; sinceReviewIns = 0; sinceReviewDel = 0
        daysSinceReview = $null
      }
      vault = $vd
      hasGraphify = $false
      outsideScanPath = $true
    }
  })
  $results = @($results) + @($extra)
}

$results | ConvertTo-Json -Depth 8 | Set-Content $OutFile -Encoding utf8
Write-Output "wrote $OutFile ($(@($results).Count) repos)"
