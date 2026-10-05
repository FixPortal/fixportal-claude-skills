#Requires -Version 7
$ErrorActionPreference = 'Stop'

# Strict-where-it-matters admission, reconciled with this driver's deliberately BROAD
# participation (an on-topic prose reply still counts; see verify-judge-input-integrity).
# Three rules, each guarding a way a vendor's vote or a finding can be miscounted silently:
#
#   1. A NO FINDINGS reply that also carries a structured finding field is NOT clean.
#      Reading "the only heading is NO FINDINGS" as clean would drop the finding written
#      beneath it, while the reviewer counted as participating with 0.
#   2. Phase-2 coverage is read off VERDICT LINES (F-id + contract keyword), never off a
#      bare mention. Each reviewer's uncovered pooled ids land as abstentions in
#      status.json and the judge packet, so [unanimous] cannot rest on silence.
#   3. A Phase-2 reply whose verdicts name NO pooled id ('F99: AGREE') is voting outside
#      the pool: off-contract, forwarded unpooled, not a participating vendor. A reply
#      with no verdict lines at all keeps the broad-participation rule.

. (Join-Path $PSScriptRoot 'fixtures' 'preflight-fixture.ps1')
$skillRoot = Join-Path $PSScriptRoot '..'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ar-admission-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'skill'
$repo = Join-Path $root 'repo'
$work = Join-Path $root 'work'
$failures = @()

try {
    New-Item -ItemType Directory -Path $fixture, $repo | Out-Null
    Copy-Item -LiteralPath (Join-Path $skillRoot 'run-review.ps1') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $skillRoot 'briefs') -Destination $fixture -Recurse
    Write-PreflightFixture -Dir $root -ReviewerId 'A', 'B', 'C', 'D'

    @'
param([string] $Instruction, [string] $DiffPath, [string] $FindingsPath, [string] $Model)
if ($FindingsPath) {
    $ids = @([regex]::Matches((Get-Content -LiteralPath $FindingsPath -Raw), '(?m)^## (F\d+)') | ForEach-Object { $_.Groups[1].Value })
    switch ($Model) {
        'all'     { $ids | ForEach-Object { "${_}: AGREE - fixture" } }
        'one'     { 'F1: AGREE - fixture' }
        'outside' { 'F99: AGREE - a finding that is not in this pool' }
        'prose'   { 'Having read the change, F1 and F2 both look right to me and nothing else stands out.' }
    }
    exit 0
}
switch ($Model) {
    'outside' {
        "### NO FINDINGS`n`nExamined sample.txt.`n- **Severity:** High`n- **Location:** sample.txt:1`n- **Issue:** HIDDEN_UNDER_SENTINEL"
    }
    'prose' { "### NO FINDINGS`n`nExamined sample.txt; nothing substantive." }
    default {
        "### Finding from $Model`n- **Severity:** Low`n- **Location:** sample.txt:1`n- **Trigger:** fixture`n- **Issue:** fixture`n- **Impact:** fixture`n- **Suggested fix:** fixture"
    }
}
'@ | Set-Content -LiteralPath (Join-Path $fixture 'stub-review.ps1') -Encoding utf8

    [ordered]@{
        minVendors = 2
        wrappers = [ordered]@{ stub = 'stub-review.ps1' }
        reviewers = @(
            [ordered]@{ id = 'A'; label = 'Alpha'; wrapper = 'stub'; model = 'all';     vendor = 'alpha'; enabled = $true; repoAccess = $false },
            [ordered]@{ id = 'B'; label = 'Beta';  wrapper = 'stub'; model = 'one';     vendor = 'beta';  enabled = $true; repoAccess = $false },
            [ordered]@{ id = 'C'; label = 'Gamma'; wrapper = 'stub'; model = 'outside'; vendor = 'gamma'; enabled = $true; repoAccess = $false },
            [ordered]@{ id = 'D'; label = 'Delta'; wrapper = 'stub'; model = 'prose';   vendor = 'delta'; enabled = $true; repoAccess = $false }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'reviewers.json') -Encoding utf8

    & git -C $repo init --quiet
    & git -C $repo config user.email fixture@example.com
    & git -C $repo config user.name Fixture
    'fixture' | Set-Content -LiteralPath (Join-Path $repo 'sample.txt') -Encoding utf8
    & git -C $repo add sample.txt
    & git -C $repo -c commit.gpgsign=false commit --quiet -m fixture

    $output = & pwsh -NoProfile -File (Join-Path $fixture 'run-review.ps1') `
        -RepoPath $repo -Target audit -Pathspec sample.txt -WorkDir $work `
        -ManifestPath (Join-Path $fixture 'reviewers.json') 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "fixture run exited $LASTEXITCODE`n$output" }

    $status = Get-Content -LiteralPath (Join-Path $work 'status.json') -Raw | ConvertFrom-Json
    $map = (Get-Content -LiteralPath (Join-Path $work 'pooled-map.json') -Raw | ConvertFrom-Json).findings
    $pooled = Get-Content -LiteralPath (Join-Path $work 'pooled-findings.txt') -Raw
    $metrics = Get-Content -LiteralPath (Join-Path $work 'metrics.json') -Raw | ConvertFrom-Json
    $packet = Get-Content -LiteralPath (Join-Path $work 'judge-packet.md') -Raw
    $owners = @($map.PSObject.Properties | ForEach-Object { $_.Value.reviewer })

    # --- 1. NO FINDINGS plus a finding field is not clean ------------------
    if ($pooled -notmatch 'HIDDEN_UNDER_SENTINEL' -or $owners -notcontains 'C') {
        $failures += 'a NO FINDINGS reply carrying a **Severity:** field must pool that finding, not discard it as clean'
    }
    if ($owners -contains 'D') { $failures += 'a pure NO FINDINGS reply must pool nothing' }
    if ($pooled -match '(?m)^###\s+NO FINDINGS\s*$' -and $pooled -notmatch 'HIDDEN_UNDER_SENTINEL') {
        $failures += 'a NO FINDINGS block with no finding field must never pool as a finding'
    }
    $raisedOf = { param($v) [int](@($metrics.participants | Where-Object reviewer -eq $v)[0].issuesRaised) }
    if ((& $raisedOf 'gamma') -ne 1) { $failures += "issuesRaised must equal the pooled count for C (expected 1, got $(& $raisedOf 'gamma'))" }
    if ((& $raisedOf 'delta') -ne 0) { $failures += "a clean reviewer raised nothing (expected 0, got $(& $raisedOf 'delta'))" }
    if (@($status.phase1Reviewers | Where-Object { $_.id -eq 'D' }).Count -ne 1) {
        $failures += 'a pure NO FINDINGS reply is participation and must count in Phase 1'
    }

    # --- 2. coverage from verdict lines; abstentions recorded --------------
    $expected = @($map.PSObject.Properties.Name)
    $abst = @{}
    foreach ($a in @($status.phase2Abstentions | Where-Object { $_ })) { $abst[$a.id] = @($a.abstained) }
    if (-not $abst.ContainsKey('A') -or $abst['A'].Count -ne 0) { $failures += "a reviewer that verdicted every id abstained on nothing, got: $($abst['A'] -join ',')" }
    $bExpected = @($expected | Where-Object { $_ -ne 'F1' })
    if (-not $abst.ContainsKey('B') -or (@($abst['B']) -join ',') -ne ($bExpected -join ',')) {
        $failures += "B verdicted only F1, so it abstained on $($bExpected -join ','); got: $($abst['B'] -join ',')"
    }
    if (-not $abst.ContainsKey('D') -or $abst['D'] -notcontains 'F1') {
        $failures += "a prose MENTION of F1 is not a verdict; D must be recorded as abstaining on F1, got: $($abst['D'] -join ',')"
    }
    if ($packet -notmatch 'Abstained \(no verdict recorded\)') {
        $failures += 'the judge packet must carry each reviewer''s explicit abstentions'
    }

    # --- 3. verdicts outside the pool are off-contract ---------------------
    if (@($status.phase2Reviewers | Where-Object { $_.id -eq 'C' }).Count -ne 0) {
        $failures += 'a Phase-2 reply whose only verdict names an id outside the pool must not count as a participating vendor'
    }
    if (@($status.offContract | Where-Object { $_.id -eq 'C' -and $_.phase -eq 'p2' }).Count -ne 1) {
        $failures += 'the outside-the-pool reply must be recorded as off-contract in status.json'
    }
    if (@($status.phase2Reviewers | Where-Object { $_.id -eq 'D' }).Count -ne 1) {
        $failures += 'a verdict-less on-topic prose reply keeps the broad participation rule in Phase 2'
    }
}
finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    Write-Error "phase admission contract FAILED ($($failures.Count) issue(s))" -ErrorAction Continue
    exit 1
}
'phase admission OK - sentinel-plus-finding pools, coverage reads verdict lines, abstentions recorded, out-of-pool verdicts off-contract'
