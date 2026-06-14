$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\collect.ps1'
$out = Join-Path $env:TEMP 'review-digest-data.test.json'
& pwsh -NoProfile -File $script -Path '<repos-root>' -OutFile $out
if ($LASTEXITCODE -ne 0) { throw "collect.ps1 exited $LASTEXITCODE" }
$data = Get-Content $out -Raw | ConvertFrom-Json

# git side: a reviewed repo must have review commits with a parsed fixer model and a last-review date
$reviewed = $data | Where-Object { $_.repo -eq '<your-reviewed-repo>' }
if (-not $reviewed) { throw "<your-reviewed-repo> absent from output" }
if ($reviewed.git.reviewCommits.Count -lt 1) { throw "<your-reviewed-repo> has no review commits" }
if (-not ($reviewed.git.reviewCommits | Where-Object { $_.fixerModel })) { throw "no fixer model parsed on <your-reviewed-repo>" }
if (-not $reviewed.git.lastReviewDate) { throw "<your-reviewed-repo> missing lastReviewDate" }

# a repo with no reviews must still appear (coverage gap), with empty reviewCommits
$unreviewed = $data | Where-Object { $_.repo -eq '<your-unreviewed-repo>' }
if (-not $unreviewed) { throw "<your-unreviewed-repo> absent (must list unreviewed repos)" }
if ($unreviewed.git.reviewCommits.Count -ne 0) { throw "<your-unreviewed-repo> should have zero review commits" }

# vault side: reviewed repo has a panel + judge + a severity tally parsed from the latest run _index.md
if (-not $reviewed.vault.exists) { throw "<your-reviewed-repo> vault not detected" }
if ($reviewed.vault.reviewers.Count -lt 1) { throw "<your-reviewed-repo> vault reviewers not parsed" }
if (-not $reviewed.vault.judge) { throw "<your-reviewed-repo> vault judge not parsed" }
if ($null -eq $reviewed.vault.tally.High) { throw "<your-reviewed-repo> vault tally.High not parsed" }
"collect.ps1 vault-side OK — panel: $($reviewed.vault.reviewers -join ', ') | judge: $($reviewed.vault.judge)"

# a repo whose _index.md uses a Markdown-table tally format must still parse a High count
$tableRepo = $data | Where-Object { $_.repo -eq '<your-table-format-repo>' }
if (-not $tableRepo) { throw "<your-table-format-repo> absent" }
if (-not $tableRepo.vault.exists) { throw "<your-table-format-repo> vault not detected" }
if ($null -eq $tableRepo.vault.tally) { throw "<your-table-format-repo> tally not parsed (table format)" }
if ($null -eq $tableRepo.vault.tally.High) { throw "<your-table-format-repo> tally.High not parsed (table format)" }

# vault-only repos that live outside the scanned path must appear flagged (e.g. a retired repo)
$vaultOnly = $data | Where-Object { $_.repo -eq '<your-vault-only-repo>' }
if (-not $vaultOnly) { throw "<your-vault-only-repo> (vault-only, outside path) absent" }
if ($vaultOnly.git.reviewCommits.Count -ne 0) { throw "<your-vault-only-repo> should have no git commits in this folder" }
if (-not $vaultOnly.vault.exists) { throw "<your-vault-only-repo> should carry vault data" }
if (-not $vaultOnly.outsideScanPath) { throw "<your-vault-only-repo> should be flagged outsideScanPath" }

# --- forward-looking scope fields (commits since last review) ---
# a reviewed repo carries a boundary sha, a since-review commit list, counts, age, and graphify flag
if ($null -eq $reviewed.git.PSObject.Properties['boundarySha']) { throw "<your-reviewed-repo> missing git.boundarySha" }
if (-not $reviewed.git.boundarySha) { throw "<your-reviewed-repo> (reviewed) must have a non-null boundarySha" }
if ($null -eq $reviewed.git.PSObject.Properties['sinceReview']) { throw "<your-reviewed-repo> missing git.sinceReview" }
if ($null -eq $reviewed.git.PSObject.Properties['sinceReviewCount']) { throw "<your-reviewed-repo> missing git.sinceReviewCount" }
if ($reviewed.git.sinceReviewCount -lt 0) { throw "<your-reviewed-repo> sinceReviewCount must be >= 0" }
if ($reviewed.git.neverReviewed) { throw "<your-reviewed-repo> should NOT be flagged neverReviewed" }
if ($null -eq $reviewed.git.PSObject.Properties['daysSinceReview']) { throw "<your-reviewed-repo> missing git.daysSinceReview" }
if ($reviewed.git.daysSinceReview -lt 0) { throw "<your-reviewed-repo> daysSinceReview must be >= 0" }
if ($null -eq $reviewed.PSObject.Properties['hasGraphify']) { throw "<your-reviewed-repo> missing hasGraphify flag" }

# a never-reviewed repo: null boundary, flagged neverReviewed, full-scope commit count
if ($unreviewed.git.boundarySha) { throw "<your-unreviewed-repo> (unreviewed) must have a null boundarySha" }
if (-not $unreviewed.git.neverReviewed) { throw "<your-unreviewed-repo> must be flagged neverReviewed" }
if ($unreviewed.git.sinceReviewCount -lt 1) { throw "<your-unreviewed-repo> full-scope commit count must be >= 1" }
"collect.ps1 scope-side OK — <your-reviewed-repo> since-review: $($reviewed.git.sinceReviewCount) commit(s), $($reviewed.git.daysSinceReview)d stale"

# bad path -> non-zero exit
& pwsh -NoProfile -File $script -Path '<nonexistent-path>' -OutFile $out 2>$null
if ($LASTEXITCODE -eq 0) { throw "bad path should exit non-zero" }

"collect.ps1 git-side OK — $($data.Count) repos"
