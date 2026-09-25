#requires -Version 7
$ErrorActionPreference = 'Stop'

# rollout-canonical-asset-gate.ps1 is the estate half of the divergence gate: it lands the
# verifier, manifest, ci.yml step and policy entry in ONE consumer repo, and REFUSES --
# with zero edits -- any repo whose shape it cannot vouch for. A rollout that improvises
# on an unexpected ci.yml is how 30 repos get 30 different gates. This pins the adopt
# path, the CRLF preservation, the idempotence, and every refusal.

$rollout = Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'rollout-canonical-asset-gate.ps1')
$skillRoot = Split-Path -Parent (Split-Path -Parent $rollout)
$root = Join-Path ([IO.Path]::GetTempPath()) ('rollout-gate-' + [guid]::NewGuid().ToString('N'))

$python = @('python3', 'python') |
    Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $python) { throw 'no python interpreter on this host - the rollout proof step cannot be checked' }

$ciYaml = @'
name: ci
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  gate-coverage:
    name: Gate coverage
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Assert every job in this workflow is gated
        env:
          GATE_EXEMPT: ''
        run: python3 .github/scripts/assert_gate_coverage.py .github/workflows/ci.yml
  ci-gate:
    name: CI Gate
    if: always()
    needs: [gate-coverage]
    runs-on: ubuntu-latest
    steps:
      - name: Fail if any upstream job did not succeed
        if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@

$policyJson = @'
{
  "version": 1,
  "high": [
    ".claude/review-policy.json",
    ".github/workflows/ci.yml",
    ".github/scripts/**"
  ],
  "low": []
}
'@

# Real git repositories: the rollout runs `git check-ignore` in the target, which an
# empty .git directory cannot answer.
function New-FixtureRepo([string] $Name, [bool] $WithGate = $true, [bool] $Crlf = $false, [string] $CiOverride = '', [string] $PolicyOverride = '') {
    $repo = Join-Path $root $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git init -q $repo 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git init failed for fixture $Name" }
    New-Item -ItemType Directory -Path (Join-Path $repo '.github' 'workflows') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo '.github' 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
    $eol = if ($Crlf) { "`r`n" } else { "`n" }
    if ($WithGate) {
        $chosenCi = if ($CiOverride) { $CiOverride } else { $ciYaml }
        [IO.File]::WriteAllText((Join-Path $repo '.github' 'workflows' 'ci.yml'), ($chosenCi -replace "`r?`n", $eol), [Text.UTF8Encoding]::new($false))
        Copy-Item (Join-Path $skillRoot 'assets' 'assert_gate_coverage.py') (Join-Path $repo '.github' 'scripts' 'assert_gate_coverage.py') -Force
        if ($PolicyOverride -ne 'SKIP') {
            $chosenPolicy = if ($PolicyOverride) { $PolicyOverride } else { $policyJson }
            [IO.File]::WriteAllText((Join-Path $repo '.claude' 'review-policy.json'), ($chosenPolicy -replace "`r?`n", $eol), [Text.UTF8Encoding]::new($false))
        }
    }
    return $repo
}

function Invoke-Rollout([string] $Repo, [switch] $ReportOnly) {
    if ($ReportOnly) {
        $out = (& pwsh -NoProfile -File $rollout -RepoRoot $Repo -ReportOnly 2>&1 | Out-String)
    } else {
        $out = (& pwsh -NoProfile -File $rollout -RepoRoot $Repo 2>&1 | Out-String)
    }
    $code = $LASTEXITCODE
    return @{ Code = $code; Output = $out }
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    # adopt: clean-shaped repo, CRLF files -- full adoption, endings preserved
    $adopt = New-FixtureRepo 'adopt' -Crlf $true
    $r = Invoke-Rollout $adopt
    if ($r.Code -ne 0) { throw "adoption must exit 0; got $($r.Code)`n$($r.Output)" }

    $verifierCopy = Join-Path $adopt '.github' 'scripts' 'assert_canonical_assets.py'
    if (-not (Test-Path -LiteralPath $verifierCopy -PathType Leaf)) { throw 'verifier was not copied' }
    $canonicalBytes = [IO.File]::ReadAllBytes((Join-Path $skillRoot 'assets' 'assert_canonical_assets.py'))
    $copyBytes = [IO.File]::ReadAllBytes($verifierCopy)
    if (-not [System.Linq.Enumerable]::SequenceEqual($canonicalBytes, $copyBytes)) { throw 'verifier copy must be byte-identical to canonical' }

    $r = & $python $verifierCopy $adopt 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "post-adoption manifest must verify clean:`n$r" }

    $ciAfter = [IO.File]::ReadAllText((Join-Path $adopt '.github' 'workflows' 'ci.yml'))
    if ([regex]::Matches($ciAfter, 'assert_canonical_assets\.py').Count -ne 1) { throw 'ci.yml must reference the verifier exactly once' }
    if (-not $ciAfter.Contains("`r`n")) { throw 'ci.yml CRLF endings were not preserved' }
    if ($ciAfter.Contains("`n") -and $ciAfter.Replace("`r`n", '').Contains("`n")) { throw 'ci.yml has mixed line endings after the splice' }

    $policyAfter = [IO.File]::ReadAllText((Join-Path $adopt '.claude' 'review-policy.json'))
    $null = $policyAfter | ConvertFrom-Json -ErrorAction Stop
    if (-not $policyAfter.Contains('".github/canonical-assets.json"')) { throw 'policy must gain the manifest entry' }
    if ($policyAfter.Contains('".github/scripts/assert_canonical_assets.py"')) { throw 'the glob already covers the verifier -- no named entry should have been added' }

    # idempotence: a second run is a clean SKIP, not a second splice
    $r = Invoke-Rollout $adopt
    if ($r.Code -ne 0) { throw "re-adoption must exit 0 (already adopted); got $($r.Code)`n$($r.Output)" }
    if ([regex]::Matches([IO.File]::ReadAllText((Join-Path $adopt '.github' 'workflows' 'ci.yml')), 'assert_canonical_assets\.py').Count -ne 1) {
        throw 'a second run must not double-splice ci.yml'
    }

    # refusal: no gate anchor -- SKIP, and ci.yml is byte-for-byte untouched
    $noAnchor = New-FixtureRepo 'no-anchor'
    $ciPath = Join-Path $noAnchor '.github' 'workflows' 'ci.yml'
    [IO.File]::WriteAllText($ciPath, "name: ci`non: push`n", [Text.UTF8Encoding]::new($false))
    $before = [IO.File]::ReadAllBytes($ciPath)
    $r = Invoke-Rollout $noAnchor
    if ($r.Code -ne 2) { throw "no-anchor repo must exit 2; got $($r.Code)`n$($r.Output)" }
    if (-not [System.Linq.Enumerable]::SequenceEqual($before, [IO.File]::ReadAllBytes($ciPath))) { throw 'a refused repo must not be edited' }

    # refusal: ci.yml called via workflow_call -- the permissions union needs human review
    $caller = New-FixtureRepo 'caller'
    [IO.File]::WriteAllText((Join-Path $caller '.github' 'workflows' 'release.yml'),
        "name: release`non:`n  push:`n    tags: ['v*']`njobs:`n  ci:`n    uses: ./.github/workflows/ci.yml`n", [Text.UTF8Encoding]::new($false))
    $r = Invoke-Rollout $caller
    if ($r.Code -ne 2) { throw "workflow_call repo must exit 2; got $($r.Code)`n$($r.Output)" }
    if ($r.Output -notmatch 'workflow_call') { throw "the refusal must name the reason`n$($r.Output)" }

    # refusal: a new path is gitignored (allow-list ignore file)
    $ignored = New-FixtureRepo 'ignored'
    [IO.File]::WriteAllText((Join-Path $ignored '.gitignore'), "*`n", [Text.UTF8Encoding]::new($false))
    $r = Invoke-Rollout $ignored
    if ($r.Code -ne 2) { throw "gitignored repo must exit 2; got $($r.Code)`n$($r.Output)" }
    if ($r.Output -notmatch 'gitignored') { throw "the refusal must name the gitignore reason`n$($r.Output)" }

    # ReportOnly: surveys without editing
    $survey = New-FixtureRepo 'survey'
    $r = Invoke-Rollout $survey -ReportOnly
    if ($r.Code -ne 0) { throw "ReportOnly must exit 0; got $($r.Code)`n$($r.Output)" }
    if (Test-Path -LiteralPath (Join-Path $survey '.github' 'canonical-assets.json')) { throw 'ReportOnly must not write' }

    # every refusal rail, with the reason named and nothing written
    $noGit = Join-Path $root 'no-git'
    New-Item -ItemType Directory -Path $noGit -Force | Out-Null
    $r = Invoke-Rollout $noGit
    if ($r.Code -ne 2 -or $r.Output -notmatch 'not a git repository root') { throw "non-git root must exit 2 naming the reason`n$($r.Output)" }

    $noCi = New-FixtureRepo 'no-ci' -WithGate $false
    $r = Invoke-Rollout $noCi
    if ($r.Code -ne 2 -or $r.Output -notmatch 'no .github/workflows/ci.yml') { throw "missing ci.yml must exit 2 naming the reason`n$($r.Output)" }

    $coe = New-FixtureRepo 'coe' -CiOverride ($ciYaml.Replace('    name: Gate coverage', "    name: Gate coverage`n    continue-on-error: true"))
    $r = Invoke-Rollout $coe
    if ($r.Code -ne 2 -or $r.Output -notmatch 'continue-on-error') { throw "continue-on-error must exit 2 naming the reason`n$($r.Output)" }

    $prt = New-FixtureRepo 'prt' -CiOverride $ciYaml.Replace('  pull_request:', '  pull_request_target:')
    $r = Invoke-Rollout $prt
    if ($r.Code -ne 2 -or $r.Output -notmatch 'pull_request_target') { throw "pull_request_target must exit 2 naming the reason`n$($r.Output)" }

    $noPol = New-FixtureRepo 'no-pol' -PolicyOverride 'SKIP'
    Remove-Item -LiteralPath (Join-Path $noPol '.claude' 'review-policy.json') -ErrorAction SilentlyContinue
    $r = Invoke-Rollout $noPol
    if ($r.Code -ne 2 -or $r.Output -notmatch 'no .claude/review-policy.json') { throw "missing policy must exit 2 naming the reason`n$($r.Output)" }

    # partial adoption: only the verifier file present -> exit 2, named, and ci.yml untouched
    $partial = New-FixtureRepo 'partial'
    Copy-Item (Join-Path $skillRoot 'assets' 'assert_canonical_assets.py') (Join-Path $partial '.github' 'scripts' 'assert_canonical_assets.py') -Force
    $partialCi = Join-Path $partial '.github' 'workflows' 'ci.yml'
    $partialBefore = [IO.File]::ReadAllBytes($partialCi)
    $r = Invoke-Rollout $partial
    if ($r.Code -ne 2 -or $r.Output -notmatch 'partial adoption') { throw "a partial adoption must exit 2 naming it`n$($r.Output)" }
    if (-not [System.Linq.Enumerable]::SequenceEqual($partialBefore, [IO.File]::ReadAllBytes($partialCi))) { throw 'a partial-adoption SKIP must not edit' }

    # empty "high" array: the splice must still produce STRICT-valid JSON (python's parser is strict).
    # Such a policy is not checker-conformant (no HIGH tier for the gate checker itself), so the
    # adoption now THROWS at the conformance proof -- after the splice. The strict-JSON rail is
    # pinned against the on-disk file the throw leaves behind.
    $emptyHigh = New-FixtureRepo 'empty-high' -PolicyOverride ('{' + "`n" + '  "version": 1,' + "`n" + '  "high": [],' + "`n" + '  "low": []' + "`n" + '}' + "`n")
    $r = Invoke-Rollout $emptyHigh
    if ($r.Code -eq 0 -or $r.Output -notmatch 'gate checker rejects') { throw "empty-high must splice, then fail checker conformance; got $($r.Code)`n$($r.Output)" }
    $emptyPolicyPath = Join-Path $emptyHigh '.claude' 'review-policy.json'
    & $python -c "import json,sys; json.load(open(sys.argv[1]))" $emptyPolicyPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'empty-high policy must be strict-valid JSON (pwsh ConvertFrom-Json is trailing-comma lenient and cannot be the rail)' }
    if (-not ([IO.File]::ReadAllText($emptyPolicyPath)).Contains('".github/canonical-assets.json"')) { throw 'empty-high policy must gain the manifest entry' }

    $wrongHighType = New-FixtureRepo 'wrong-high-type' -PolicyOverride '{"version":1,"high":"not-an-array","low":[]}'
    $beforeWrongType = [IO.File]::ReadAllText((Join-Path $wrongHighType '.github' 'workflows' 'ci.yml'))
    $r = Invoke-Rollout $wrongHighType
    if ($r.Code -ne 2 -or $r.Output -notmatch 'high array') { throw "a non-array high value must be refused during preflight`n$($r.Output)" }
    if ([IO.File]::ReadAllText((Join-Path $wrongHighType '.github' 'workflows' 'ci.yml')) -cne $beforeWrongType) { throw 'invalid high type must be refused before writing CI files' }

    $missingHigh = New-FixtureRepo 'missing-high' -PolicyOverride '{"version":1,"low":[]}'
    $beforeMissingHigh = [IO.File]::ReadAllText((Join-Path $missingHigh '.github' 'workflows' 'ci.yml'))
    $r = Invoke-Rollout $missingHigh
    if ($r.Code -ne 2 -or $r.Output -notmatch 'high array') { throw "a missing high property must be refused during preflight`n$($r.Output)" }
    if ([IO.File]::ReadAllText((Join-Path $missingHigh '.github' 'workflows' 'ci.yml')) -cne $beforeMissingHigh) { throw 'missing high property must be refused before writing CI files' }

    # glob-absent policy: the verifier gets a NAMED entry, not just the manifest
    $namedPol = New-FixtureRepo 'named-pol' -PolicyOverride ('{' + "`n" + '  "version": 1,' + "`n" + '  "high": [' + "`n" + '    ".claude/review-policy.json",' + "`n" + '    ".github/workflows/ci.yml",' + "`n" + '    ".github/scripts/assert_gate_coverage.py"' + "`n" + '  ],' + "`n" + '  "low": []' + "`n" + '}' + "`n")
    $r = Invoke-Rollout $namedPol
    if ($r.Code -ne 0) { throw "named-entry adoption must exit 0; got $($r.Code)`n$($r.Output)" }
    $namedPolicy = [IO.File]::ReadAllText((Join-Path $namedPol '.claude' 'review-policy.json'))
    if (-not $namedPolicy.Contains('".github/scripts/assert_canonical_assets.py"')) { throw 'a glob-absent policy must gain the named verifier entry' }
    if (-not $namedPolicy.Contains('".github/canonical-assets.json"')) { throw 'a glob-absent policy must gain the manifest entry' }

    # A policy that ALREADY names the verifier (and has no glob) must not gain a second
    # copy. The prior-entry probe looked for `"assert_canonical_assets.py"` -- a bare
    # basename that no named entry ever contains, since entries are repo-relative paths --
    # so every such repo got the entry twice.
    $priorNamed = New-FixtureRepo 'prior-named' -PolicyOverride ('{' + "`n" + '  "version": 1,' + "`n" + '  "high": [' + "`n" + '    ".claude/review-policy.json",' + "`n" + '    ".github/workflows/ci.yml",' + "`n" + '    ".github/scripts/assert_gate_coverage.py",' + "`n" + '    ".github/scripts/assert_canonical_assets.py"' + "`n" + '  ],' + "`n" + '  "low": []' + "`n" + '}' + "`n")
    $r = Invoke-Rollout $priorNamed
    if ($r.Code -ne 0) { throw "prior-named adoption must exit 0; got $($r.Code)`n$($r.Output)" }
    $priorNamedPolicy = [IO.File]::ReadAllText((Join-Path $priorNamed '.claude' 'review-policy.json'))
    $verifierEntries = [regex]::Matches($priorNamedPolicy, 'assert_canonical_assets\.py').Count
    if ($verifierEntries -ne 1) { throw "a policy already naming the verifier must keep exactly one entry; found $verifierEntries" }
    if (-not $priorNamedPolicy.Contains('".github/canonical-assets.json"')) { throw 'a prior-named policy must still gain the manifest entry' }

    # The coverage probe read the WHOLE policy text, so a `.github/scripts/**` glob sitting
    # in `low` counted as covering the verifier and the rollout omitted the named entry
    # from `high` -- then failed its own conformance proof with all four artefacts already
    # written. Coverage is decided inside the high array. (CodeRabbit, public mirror PR #124.)
    $lowGlob = New-FixtureRepo 'low-glob' -PolicyOverride ('{' + "`n" + '  "version": 1,' + "`n" + '  "high": [' + "`n" + '    ".claude/review-policy.json",' + "`n" + '    ".github/workflows/ci.yml",' + "`n" + '    ".github/scripts/assert_gate_coverage.py"' + "`n" + '  ],' + "`n" + '  "low": [' + "`n" + '    ".github/scripts/**"' + "`n" + '  ]' + "`n" + '}' + "`n")
    $r = Invoke-Rollout $lowGlob
    if ($r.Code -ne 0) { throw "a glob only in low must not count as high coverage; got $($r.Code)`n$($r.Output)" }
    $lowGlobPolicy = [IO.File]::ReadAllText((Join-Path $lowGlob '.claude' 'review-policy.json'))
    $lowGlobHigh = [regex]::Match($lowGlobPolicy, '(?s)"high"\s*:\s*\[(?<body>.*?)\]').Groups['body'].Value
    if (-not $lowGlobHigh.Contains('".github/scripts/assert_canonical_assets.py"')) { throw 'a policy whose only verifier glob is in low must gain the named verifier entry in high' }

    # policy splice preserves CRLF too (the adopt fixture is CRLF)
    $policyAfterCrlf = [IO.File]::ReadAllText((Join-Path $adopt '.claude' 'review-policy.json'))
    if (-not $policyAfterCrlf.Contains("`r`n")) { throw 'review-policy.json CRLF endings were not preserved' }

    # refusal: off-convention gate-step indentation would produce malformed YAML
    $weirdYaml = $ciYaml.Replace('        run: python3', '            run: python3')
    $weird = New-FixtureRepo 'weird-indent' -CiOverride $weirdYaml
    $r = Invoke-Rollout $weird
    if ($r.Code -ne 2 -or $r.Output -notmatch 'off-convention') { throw "off-convention indentation must exit 2 naming the reason`n$($r.Output)" }

    # review-driven rails: short-indent anchor, keys after run:, .yaml caller, $/ caller
    $shortIndent = New-FixtureRepo 'short-indent' -CiOverride ($ciYaml -replace '(?m)^        run: python3', ' run: python3')
    $r = Invoke-Rollout $shortIndent
    if ($r.Code -ne 2 -or $r.Output -notmatch 'unreadable') { throw "a short-indent anchor must exit 2 naming the reason`n$($r.Output)" }

    $tailKey = New-FixtureRepo 'tail-key' -CiOverride ($ciYaml -replace "(?m)^(        run: python3 .github/scripts/assert_gate_coverage.py .github/workflows/ci.yml)$", "`$1`n        if: github.event_name == 'pull_request'")
    $r = Invoke-Rollout $tailKey
    if ($r.Code -ne 2 -or $r.Output -notmatch 'keys after run:') { throw "a key after run: must exit 2 naming the reason`n$($r.Output)" }

    $yamlCaller = New-FixtureRepo 'yaml-caller'
    [IO.File]::WriteAllText((Join-Path $yamlCaller '.github' 'workflows' 'release.yaml'), "name: release`non:`n  workflow_dispatch:`njobs:`n  ci:`n    uses: `$/.github/workflows/ci.yml`n", [Text.UTF8Encoding]::new($false))
    $r = Invoke-Rollout $yamlCaller
    if ($r.Code -ne 2 -or $r.Output -notmatch 'workflow_call') { throw "a `$/ .yaml caller must exit 2 naming the reason`n$($r.Output)" }

    # adopted-but-broken: all four markers present, verifier fails -> refusal, not SKIP-0
    $broken = New-FixtureRepo 'broken-adopt'
    $r = Invoke-Rollout $broken
    if ($r.Code -ne 0) { throw "setup adoption must succeed; got $($r.Code)`n$($r.Output)" }
    Add-Content -LiteralPath (Join-Path $broken '.github' 'scripts' 'assert_gate_coverage.py') -Value '# corrupted after adoption' -Encoding utf8
    $r = Invoke-Rollout $broken
    if ($r.Code -ne 2 -or $r.Output -notmatch 'conformance is incomplete') { throw "a broken adoption must exit 2 naming it`n$($r.Output)" }
    if ($r.Output -match 'partial adoption') { throw "the verification-fails refusal must not also claim a partial adoption`n$($r.Output)" }

    # checker-conformance proof: the rollout runs the repo's REAL gate checker against
    # its (spliced) ci.yml, honoring the anchor step's GATE_EXEMPT env.

    # an ungated job with no exemption: the checker rejects the repo mid-adopt
    $ungatedYaml = $ciYaml.Replace('  ci-gate:', "  docker:`n    name: Docker`n    runs-on: ubuntu-latest`n    steps:`n      - run: docker build .`n  ci-gate:")
    $ungated = New-FixtureRepo 'ungated-job' -CiOverride $ungatedYaml
    $r = Invoke-Rollout $ungated
    if ($r.Code -eq 0) { throw "an ungated-job repo must not adopt clean`n$($r.Output)" }
    if ($r.Output -notmatch 'gate checker rejects') { throw "the refusal must name the checker failure`n$($r.Output)" }

    # the anchor step's env is honored: same ungated job, exempted -> adopts clean
    $exemptYaml = $ungatedYaml.Replace("          GATE_EXEMPT: ''", "          GATE_EXEMPT: 'docker'")
    $exempt = New-FixtureRepo 'env-exempt' -CiOverride $exemptYaml
    $r = Invoke-Rollout $exempt
    if ($r.Code -ne 0) { throw "an exempted repo must adopt clean; got $($r.Code)`n$($r.Output)" }

    # load-bearing proof: without GATE_EXEMPT the fixture's checker fails this ci.yml
    $checkerPath = Join-Path $exempt '.github' 'scripts' 'assert_gate_coverage.py'
    $exemptCi = Join-Path $exempt '.github' 'workflows' 'ci.yml'
    $env:GATE_EXEMPT = $null
    $env:GATE_CONDITIONAL_EXEMPT = $null
    $null = & $python $checkerPath $exemptCi 2>&1 | Out-String
    $bareExit = $LASTEXITCODE
    $env:GATE_EXEMPT = 'docker'
    $null = & $python $checkerPath $exemptCi 2>&1 | Out-String
    $withEnvExit = $LASTEXITCODE
    $env:GATE_EXEMPT = $null
    if ($bareExit -eq 0 -or $withEnvExit -ne 0) { throw 'env-exempt fixture is not load-bearing: the checker must fail without GATE_EXEMPT and pass with it' }

    'rollout-canonical-asset-gate.ps1 OK - adopt path (byte-identical verifier, verifying manifest, single splice, CRLF preserved, glob-aware policy edit), idempotence, and the no-anchor / workflow_call / gitignored / ReportOnly rails -- plus empty-high strict-JSON, named-entry branch, and every refusal rail, and the off-convention-indent refusal, and the review-driven rails, checker-conformance proof'
}
finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
