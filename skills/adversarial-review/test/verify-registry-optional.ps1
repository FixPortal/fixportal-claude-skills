#Requires -Version 7
$ErrorActionPreference = 'Stop'

# The model registry (../model-registry) is OPTIONAL. A seat may carry a literal
# `model` beside or instead of its `select` constraint:
#   - registry present + select      -> select resolves through the registry (a
#                                       literal beside it is only a fallback);
#   - registry absent  + literal     -> the literal runs;
#   - registry absent  + select only -> the run dies naming the seat, because a
#                                       panel silently short a vendor reads as clean;
#   - aggregate-and-emit with no registry prices nothing and invents nothing:
#     a moving alias stays UNKNOWN, an exact id honours its transported cost.
# Each case runs against a COPY of the skill with no sibling model-registry (or a
# stub one), so the real registry on this box can neither help nor hurt.

. (Join-Path $PSScriptRoot 'fixtures' 'preflight-fixture.ps1')
$skillRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ar-registry-optional-' + [Guid]::NewGuid().ToString('N'))
$savedApiKey = $env:OBSERVATORY_API_KEY
$savedUrl = $env:OBSERVATORY_URL
$failures = @()

function New-SkillCopy([string] $skillsDir) {
    $dest = Join-Path $skillsDir 'adversarial-review'
    New-Item -ItemType Directory -Path (Join-Path $dest 'test' 'fixtures') -Force | Out-Null
    foreach ($f in 'run-review.ps1', 'aggregate-and-emit.ps1', 'emit-review-telemetry.ps1') {
        Copy-Item -LiteralPath (Join-Path $skillRoot $f) -Destination $dest
    }
    Copy-Item -LiteralPath (Join-Path $skillRoot 'briefs') -Destination $dest -Recurse
    Copy-Item -LiteralPath (Join-Path $skillRoot 'test' 'fixtures' 'stub-capture-review.ps1') -Destination (Join-Path $dest 'test' 'fixtures')
    $dest
}

function Write-Manifest([string] $path, [array] $reviewers) {
    [ordered]@{
        minVendors = 2
        wrappers   = [ordered]@{ stub = 'test/fixtures/stub-capture-review.ps1' }
        reviewers  = $reviewers
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
}

function Invoke-Driver([string] $skill, [string] $manifest, [string] $work, [string] $log) {
    $env:AR_TEST_MODEL_LOG = $log
    $out = & pwsh -NoProfile -File (Join-Path $skill 'run-review.ps1') -RepoPath $repo -Target audit -Pathspec sample.txt `
        -WorkDir $work -ManifestPath $manifest 2>&1 | Out-String
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out; Models = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }) }
}

try {
    $env:OBSERVATORY_API_KEY = ''
    $env:OBSERVATORY_URL = ''
    $repo = Join-Path $tempRoot 'repo'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init --quiet
    & git -C $repo config user.email fixture@example.com
    & git -C $repo config user.name Fixture
    Set-Content -LiteralPath (Join-Path $repo 'sample.txt') -Value fixture -Encoding utf8
    & git -C $repo add sample.txt
    & git -C $repo -c commit.gpgsign=false commit --quiet -m fixture
    Write-PreflightFixture -Dir $tempRoot -ReviewerId 'A', 'K'

    $bare = New-SkillCopy (Join-Path $tempRoot 'bare-skills')
    $withSelect = [ordered]@{ vendor = 'anthropic'; tier = 'workhorse'; channel = 'cli' }

    # --- 1. registry absent, literal beside select -> the literal runs ------
    $m1 = Join-Path $tempRoot 'm1.json'
    Write-Manifest $m1 @(
        [ordered]@{ id = 'A'; label = 'Alpha'; wrapper = 'stub'; vendor = 'alpha'; repoAccess = $false; enabled = $true
                    select = $withSelect; model = 'literal-alpha' },
        [ordered]@{ id = 'K'; label = 'Kappa'; wrapper = 'stub'; vendor = 'kappa'; repoAccess = $false; enabled = $true
                    model = 'literal-kappa' }
    )
    $r1 = Invoke-Driver $bare $m1 (Join-Path $tempRoot 'w1') (Join-Path $tempRoot 'log1.txt')
    if ($r1.Exit -ne 0) { $failures += "registry-absent literal seats must run, exited $($r1.Exit)`n$($r1.Out)" }
    elseif ($r1.Models -notcontains 'literal-alpha' -or $r1.Models -notcontains 'literal-kappa') {
        $failures += "registry-absent seats must run their literal models; wrapper saw: $($r1.Models -join ', ')"
    }

    # --- 2. registry absent, select only -> dies naming the seat ------------
    $m2 = Join-Path $tempRoot 'm2.json'
    Write-Manifest $m2 @(
        [ordered]@{ id = 'A'; label = 'Alpha'; wrapper = 'stub'; vendor = 'alpha'; repoAccess = $false; enabled = $true
                    select = $withSelect },
        [ordered]@{ id = 'K'; label = 'Kappa'; wrapper = 'stub'; vendor = 'kappa'; repoAccess = $false; enabled = $true
                    model = 'literal-kappa' }
    )
    $r2 = Invoke-Driver $bare $m2 (Join-Path $tempRoot 'w2') (Join-Path $tempRoot 'log2.txt')
    if ($r2.Exit -ne 2) { $failures += "a select-only seat with no registry must exit 2, got $($r2.Exit)`n$($r2.Out)" }
    if ($r2.Out -notmatch "Reviewer 'A'") { $failures += "the failure must name the seat:`n$($r2.Out)" }
    if ($r2.Out -notmatch "literal 'model'") { $failures += "the failure must say how to run without the registry (a literal 'model'):`n$($r2.Out)" }
    if ($r2.Models.Count -gt 0) { $failures += "no reviewer may run once a seat cannot be resolved; wrapper saw: $($r2.Models -join ', ')" }

    # --- 3. registry present -> select wins over the literal fallback -------
    $withRegistrySkills = Join-Path $tempRoot 'reg-skills'
    $regSkill = New-SkillCopy $withRegistrySkills
    $regDir = Join-Path $withRegistrySkills 'model-registry'
    New-Item -ItemType Directory -Path $regDir -Force | Out-Null
    "print('registry-resolved-id')" | Set-Content -LiteralPath (Join-Path $regDir 'resolve.py') -Encoding utf8
    $r3 = Invoke-Driver $regSkill $m1 (Join-Path $tempRoot 'w3') (Join-Path $tempRoot 'log3.txt')
    if ($r3.Exit -ne 0) { $failures += "registry-present run must succeed, exited $($r3.Exit)`n$($r3.Out)" }
    elseif ($r3.Models -notcontains 'registry-resolved-id' -or $r3.Models -contains 'literal-alpha') {
        $failures += "with the registry present, select must win over the literal fallback; wrapper saw: $($r3.Models -join ', ')"
    }

    # --- 4. aggregate-and-emit without a registry ---------------------------
    $runRoot = Join-Path $tempRoot 'agg'
    New-Item -ItemType Directory -Path (Join-Path $runRoot 'C01') -Force | Out-Null
    [ordered]@{ participants = @([ordered]@{ reviewer = 'alpha'; model = 'literal-alpha'; inputTokens = 10; outputTokens = 5
                costUsd = 0.25; reviewDurationMs = 1; issuesRaised = 1 }) } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runRoot 'C01' 'metrics.json') -Encoding utf8
    function Invoke-Aggregate([hashtable] $judge) {
        [ordered]@{ accepted = [ordered]@{}; judge = $judge } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $runRoot 'aggregate-verdict.json') -Encoding utf8
        $out = & pwsh -NoProfile -File (Join-Path $bare 'aggregate-and-emit.ps1') -RunRoot $runRoot -Repo fixture 2>&1 | Out-String
        [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
    }
    $judgeRow = { param($out) @($out -split "`r?`n" | Where-Object { $_ -match '\(judge\)' })[0] }

    $exact = Invoke-Aggregate @{ reviewer = 'anthropic'; model = 'exact-judge-id'; inputTokens = 1000; outputTokens = 10; costUsd = 1.75; reviewDurationMs = 1 }
    $row = & $judgeRow $exact.Out
    if ($exact.Exit -ne 0) { $failures += "aggregation without a registry must still run, exited $($exact.Exit)`n$($exact.Out)" }
    elseif ($row -notmatch '\b1\.75\b' -or $row -match 'UNKNOWN') {
        $failures += "an exact judge id the registry cannot price must honour its transported costUsd; judge row: $row"
    }

    $alias = Invoke-Aggregate @{ reviewer = 'anthropic'; model = 'opus'; inputTokens = 1000; outputTokens = 10; costUsd = 1.75; reviewDurationMs = 1 }
    $row = & $judgeRow $alias.Out
    if ($row -notmatch 'UNKNOWN' -or $row -match '\b1\.75\b') {
        $failures += "a moving alias the registry cannot resolve must stay UNKNOWN, never trust a caller-side figure; judge row: $row"
    }
}
finally {
    Remove-Item Env:\AR_TEST_MODEL_LOG -ErrorAction SilentlyContinue
    $env:OBSERVATORY_API_KEY = $savedApiKey
    $env:OBSERVATORY_URL = $savedUrl
    if ($tempRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    Write-Error "registry-optional contract FAILED ($($failures.Count) issue(s))" -ErrorAction Continue
    exit 1
}
$global:LASTEXITCODE = 0
'registry-optional OK - literal seats run without a registry, select-only seats fail by name, select wins when the registry is present, aggregation never invents a price'
