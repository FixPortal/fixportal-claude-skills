$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\collect.ps1'
$out = Join-Path $env:TEMP 'review-digest-data.test.json'

# Repos-root to exercise collect.ps1 against. This is a placeholder skeleton —
# set it to a real repos-root path before running. The guard below fails with a
# clear message on the un-substituted `<...>` token; without it, collect.ps1 just
# exits non-zero on the bogus path and the later "bad path exits non-zero"
# assertion becomes a tautology of that same failure rather than a real test.
$reposRoot = '<repos-root>'
if ($reposRoot -match '[<>]') {
    throw "verify-collect.ps1: `$reposRoot is still the placeholder '$reposRoot'. Set it to a real repos-root path before running this test."
}

& pwsh -NoProfile -File $script -Path $reposRoot -OutFile $out
if ($LASTEXITCODE -ne 0) { throw "collect.ps1 exited $LASTEXITCODE" }
$data = Get-Content $out -Raw | ConvertFrom-Json

# git side: a reviewed repo must have review commits with a parsed fixer model and a last-review date
$reviewed = $data | Where-Object { $_.repo -eq '<your-reviewed-repo>' }
if (-not $reviewed) { throw "<your-reviewed-repo> absent from output" }
if ($reviewed.git.reviewCommits.Count -lt 1) { throw "<your-reviewed-repo> has no review commits" }
if (-not ($reviewed.git.reviewCommits | Where-Object { $_.fixerModel })) { throw "no fixer model parsed on <your-reviewed-repo>" }
if (-not $reviewed.git.lastReviewDate) { throw "<your-reviewed-repo> missing lastReviewDate" }

# a repo with no ADVERSARIAL review must still appear (coverage gap). Don't also
# require reviewCommits.Count -eq 0: collect.ps1 legitimately sets neverReviewed=true
# while reviewCommits is non-empty when every commit is a web-quality-only marker
# (excluded from boundary candidacy, but still collected) -- requiring zero here
# throws on that valid shape and hard-fails once the estate reaches full coverage.
# Which repo(s) currently have zero ADVERSARIAL reviews is live, mutable state (any
# repo can gain a reviewer-findings commit at any time), so pick one dynamically
# rather than pinning to a repo name — a structural check of the "unreviewed" shape,
# not an assertion about which specific repo is unreviewed today.
# Prefer a never-reviewed repo that DOES carry reviewCommits (web-quality markers)
# when the estate has one: picking a repo with zero commits every time would let the
# old `reviewCommits.Count -eq 0` requirement come back without this test catching
# it. Sort non-empty first rather than requiring it outright, so the test stays
# green (just less discriminating) on a host where no such repo exists yet.
$neverReviewed = @($data | Where-Object { -not $_.outsideScanPath -and $_.git.neverReviewed } |
    Sort-Object -Property @{ Expression = { $_.git.reviewCommits.Count -gt 0 }; Descending = $true })
if ($neverReviewed.Count -eq 0) { throw "no never-reviewed repo found in output (coverage-gap listing not exercised)" }
$gap = $neverReviewed[0]
if ($gap.git.reviewCommits -isnot [array]) { throw "$($gap.repo): reviewCommits must be an array even when empty" }
if (-not $gap.git.neverReviewed) { throw "$($gap.repo): selected by the neverReviewed filter but flag not set" }

# vault side: reviewed repo has a panel + a judge slot + a severity tally parsed from the latest run _index.md.
# NOTE: judge is a shape check (property present, null-or-string), not a truthiness
# check — a real report can legitimately have `reviewers:` with no `judge:` key at
# all (single-model or no-adjudication runs), and collect.ps1 defaults it to $null
# rather than omitting the property.
if (-not $reviewed.vault.exists) { throw "<your-reviewed-repo> vault not detected" }
if ($reviewed.vault.reviewers.Count -lt 1) { throw "<your-reviewed-repo> vault reviewers not parsed" }
if ($null -eq $reviewed.vault.PSObject.Properties['judge']) { throw "<your-reviewed-repo> vault missing judge property" }
if ($null -ne $reviewed.vault.judge -and $reviewed.vault.judge -isnot [string]) { throw "<your-reviewed-repo> vault judge, when present, must be a string" }
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

# a never-reviewed repo: null/empty boundary, flagged neverReviewed, well-typed commit count
if ($gap.git.boundarySha) { throw "$($gap.repo) (unreviewed) must have a null/empty boundarySha" }
if (-not $gap.git.neverReviewed) { throw "$($gap.repo) must be flagged neverReviewed" }
if ($gap.git.sinceReviewCount -isnot [int] -and $gap.git.sinceReviewCount -isnot [long]) {
    $gotType = if ($null -eq $gap.git.sinceReviewCount) { '<null>' } else { $gap.git.sinceReviewCount.GetType().Name }
    throw "$($gap.repo) sinceReviewCount must be an integer (got $gotType)"
}
if ($gap.git.sinceReviewCount -lt 0) { throw "$($gap.repo) sinceReviewCount must be a non-negative int" }
"collect.ps1 scope-side OK — <your-reviewed-repo> since-review: $($reviewed.git.sinceReviewCount) commit(s), $($reviewed.git.daysSinceReview)d stale"

# bad path -> non-zero exit
& pwsh -NoProfile -File $script -Path '<nonexistent-path>' -OutFile $out 2>$null
if ($LASTEXITCODE -eq 0) { throw "bad path should exit non-zero" }

"collect.ps1 git-side OK — $($data.Count) repos"
