$ErrorActionPreference = 'Stop'
# Public mirror: aggregate-and-emit.ps1 posts to the observatory when OBSERVATORY_API_KEY
# AND OBSERVATORY_URL are both set; a developer's normal environment would publish these
# fixture rows as real telemetry. Clear both for the whole script and restore in finally.
$savedApiKey = $env:OBSERVATORY_API_KEY
$savedUrl = $env:OBSERVATORY_URL
$env:OBSERVATORY_API_KEY = ''
$env:OBSERVATORY_URL = ''
. (Join-Path $PSScriptRoot 'fixtures' 'preflight-fixture.ps1')
$root = Join-Path $PSScriptRoot '..'
$runReviewAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'run-review.ps1'), [ref]$null, [ref]$null)
$failedCountFunction = $runReviewAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-FailedPhaseCount' }, $true) | Select-Object -First 1
if ($null -eq $failedCountFunction) { throw 'Get-FailedPhaseCount was not found.' }
. ([scriptblock]::Create($failedCountFunction.Extent.Text))
$failedAttempt = [pscustomobject]@{ Id = 'reviewer'; Exit = 9; Out = 'failure' }
if ((Get-FailedPhaseCount -Attempts @($failedAttempt) -ReviewerId reviewer) -ne 1 -or
    (Get-FailedPhaseCount -Attempts @() -ReviewerId reviewer) -ne 0) {
    throw 'failed phase attempts must be counted, while a phase omitted because it was skipped contributes zero.'
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ar-model-telemetry-' + [Guid]::NewGuid().ToString('N'))
$repo = Join-Path $tempRoot 'repo'
$work = Join-Path $tempRoot 'work'
$manifestPath = Join-Path $tempRoot 'reviewers.json'

try {
    New-Item -ItemType Directory -Path $repo | Out-Null
    & git -C $repo init --quiet
    & git -C $repo config user.email fixture@example.com
    & git -C $repo config user.name Fixture
    Set-Content -LiteralPath (Join-Path $repo 'sample.txt') -Value fixture -Encoding utf8
    & git -C $repo add sample.txt
    & git -C $repo -c commit.gpgsign=false commit --quiet -m fixture

    [ordered]@{
        minVendors = 2
        wrappers = [ordered]@{ stub = 'test/fixtures/stub-review.ps1' }
        # A resolves through the registry, which is the v3 default and the only shape
        # that can produce a priceable telemetry row. B stays a LITERAL pin on purpose:
        # a pin bypasses the registry, so it is also the fixture for the unknown-cost
        # path, and asserting both here keeps the two behaviours from merging.
        reviewers = @(
            [ordered]@{ id='A'; label='Anthropic'; wrapper='stub'; vendor='anthropic'; repoAccess=$false; enabled=$true
                        select=[ordered]@{ vendor='anthropic'; tier='workhorse'; channel='cli' }
                        # Public mirror: literal fallback beside select, used only when the
                        # model-registry sibling is absent (run-review.ps1 Resolve-SeatModel).
                        model='claude-fixture-fallback' },
            [ordered]@{ id='B'; label='OpenAI'; wrapper='stub'; model='unpriced-openai-model'; vendor='openai'; repoAccess=$false; enabled=$true }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    # Both WorkDirs sit under $tempRoot; the driver reads pre-flight evidence from
    # WorkDir or its parent.
    Write-PreflightFixture -Dir $tempRoot -ManifestPath $manifestPath

    $rejectOutput = & pwsh -NoProfile -File (Join-Path $root 'run-review.ps1') -RepoPath $repo `
        -Target 123 -Pathspec sample.txt -WorkDir (Join-Path $tempRoot 'reject-work') `
        -ManifestPath $manifestPath 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $rejectOutput -notmatch 'PR targets do not support pathspecs') {
        throw "PR + pathspec must fail before gh invocation, got:`n$rejectOutput"
    }

    & pwsh -NoProfile -File (Join-Path $root 'run-review.ps1') -RepoPath $repo -Target audit `
        -Pathspec sample.txt -WorkDir $work -ManifestPath $manifestPath *> $null
    if ($LASTEXITCODE -ne 0) { throw "run-review fixture exited $LASTEXITCODE" }

    $registryPath = Join-Path $root '..' 'model-registry' 'registry.json'
    $hasRegistry = Test-Path -LiteralPath $registryPath
    if ($hasRegistry) {
        $registry = Get-Content $registryPath -Raw | ConvertFrom-Json -AsHashtable
        # Expected value comes from resolve.py itself, not a reimplementation of its
        # filters here: a private copy of the selection rules in the test is how a test
        # keeps passing while the driver and the registry disagree.
        $expected = @(& python (Join-Path $root '..' 'model-registry' 'resolve.py') `
            --tier workhorse --vendor anthropic --channel cli) |
            Where-Object { $_ -and $_ -notmatch '^note:' } | Select-Object -First 1
    } else {
        Write-Host "SKIP: model-registry not present in this tree - registry resolution and pricing assertions skipped; asserting the literal fallback reaches telemetry instead"
        $expected = 'claude-fixture-fallback'
    }
    $metrics = Get-Content (Join-Path $work 'metrics.json') -Raw | ConvertFrom-Json
    $anthropic = $metrics.participants | Where-Object reviewer -eq anthropic

    if (-not $expected -or $anthropic.model -ne $expected) {
        throw "expected the registry-resolved model '$expected', got '$($anthropic.model)'"
    }
    # The wrapper is handed the CLI vocabulary while telemetry keeps the registry id.
    # Recording the translated selector instead is what fragmented Observatory rows.
    if ($anthropic.model -notmatch '^claude-') {
        throw "telemetry must record the registry id, not a wrapper selector: '$($anthropic.model)'"
    }
    if ($hasRegistry -and ($anthropic.costUsd -le 0 -or -not $anthropic.costEstimated)) {
        throw 'sidecar-less Anthropic telemetry must use current registry prices and remain estimated'
    }

    $openai = $metrics.participants | Where-Object reviewer -eq openai
    if (-not $openai.costUnknown -or $openai.costUsd -ne 0) {
        throw 'an unpriced registry model must remain costUnknown in chunk metrics'
    }

    $aggregateOutput = & pwsh -NoProfile -File (Join-Path $root 'aggregate-and-emit.ps1') `
        -RunRoot $work -Repo fixture 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "aggregate-and-emit fixture exited $LASTEXITCODE`n$aggregateOutput" }
    if ($aggregateOutput -notmatch 'openai \(reviewer\).*UNKNOWN') {
        throw "aggregate display must render unknown cost as UNKNOWN, never numeric zero:`n$aggregateOutput"
    }

    # This case is distinct from the 'unpriced-openai-model' one above: that id is
    # absent from the registry entirely, this one is PRESENT but carries no price
    # record. Derive it rather than naming it - 'gpt-5.6-sol' was hardcoded here
    # and silently stopped testing anything the day the registry gained OpenAI
    # prices, which turned this into a failure rather than a false pass only
    # because the assertion is on UNKNOWN.
    if (-not $hasRegistry) {
        Write-Host 'SKIP: model-registry not present in this tree - exact-id unpriced-judge case needs a registry entry with no price'
        'run-review model telemetry OK (registry-absent subset) - literal fallback reaches telemetry and unknown cost stays unknown through display'
        return
    }
    $unpricedJudge = $registry.models.GetEnumerator() |
        Where-Object { $_.Value.vendor -eq 'openai' -and -not $_.Value.retired -and -not $_.Value.pricing } |
        Sort-Object Key |
        Select-Object -First 1
    if (-not $unpricedJudge) {
        throw 'the registry has no unpriced OpenAI model, so the exact-match unknown-cost path cannot be exercised'
    }

    [ordered]@{
        judge = [ordered]@{
            reviewer = 'openai'; model = $unpricedJudge.Key; inputTokens = 10; outputTokens = 5
            costUsd = 0.0; reviewDurationMs = 1
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $work 'aggregate-verdict.json') -Encoding utf8
    $judgeOutput = & pwsh -NoProfile -File (Join-Path $root 'aggregate-and-emit.ps1') `
        -RunRoot $work -Repo fixture 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "exact-judge aggregate fixture exited $LASTEXITCODE`n$judgeOutput" }
    if ($judgeOutput -notmatch "openai \(judge\).*$([regex]::Escape($unpricedJudge.Key)).*UNKNOWN") {
        throw "an exact unpriced judge model ('$($unpricedJudge.Key)') must remain UNKNOWN through aggregation and display:`n$judgeOutput"
    }

    'run-review model telemetry OK — registry prices resolve and unknown cost stays unknown through display'
}
finally {
    # Assigning $null removes the variable entirely, so an originally-unset var is
    # restored to unset rather than left defined-but-empty.
    $env:OBSERVATORY_API_KEY = $savedApiKey
    $env:OBSERVATORY_URL = $savedUrl
    if ($tempRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
