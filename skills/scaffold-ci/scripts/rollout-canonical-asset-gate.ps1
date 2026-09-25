#requires -Version 7
<#
.SYNOPSIS
Adopts the canonical-asset divergence gate in ONE consuming repository (filesystem only).

.DESCRIPTION
The estate rollout's per-repo unit. In one pass it: copies the verifier byte-identically
from canonical, runs the generator to write .github/canonical-assets.json, splices the
verification step into ci.yml's gate-coverage job, and adds the manifest to
.claude/review-policy.json's high list (plus a named verifier entry only where no glob
already covers it). It then runs the verifier -- and the repo's gate checker against the
adopted ci.yml, with the anchor step's GATE_EXEMPT / GATE_CONDITIONAL_EXEMPT honored --
as the proof the adoption is green.

It REFUSES -- exit 2, zero edits -- any repository whose shape it cannot vouch for. A
rollout that improvises on an unexpected ci.yml is how thirty repositories get thirty
different gates; a skipped repo gets a human, not a guess. The refusals:

  not a git root; no ci.yml; gate anchor (the assert_gate_coverage.py run line) not
  exactly once; the gate step indented off-convention (the splice derives the new
  step's indent from the anchor's, so an off-convention shape would produce malformed
  YAML -- hand-edit that repo); keys after the anchor's run: line (the splice appends
  there, so a trailing env:/if: key would be re-parented into the inserted step);
  ci.yml carrying continue-on-error or pull_request_target; ci.yml called via
  workflow_call (the caller/callee permissions union is a human review); a new path
  gitignored, or git check-ignore itself failing (the ignore file may be the
  publication allowlist); no review-policy.json, or one with no "high" array; a partial
  adoption -- some but not all of the four artefacts (verifier, manifest, ci.yml step,
  policy entry) present -- which a single-marker idempotence check would bury as
  complete; all four markers present but the verifier failing (presence is not proof).

Already-adopted repos exit 0 unchanged (idempotent -- but the verifier re-runs first, so
a corrupted artefact reads as a refusal, not as adopted). -ReportOnly surveys without
writing. This script never touches git state: no branch, commit, push, or PR -- the
caller drives those, one repo at a time.

.EXAMPLE
pwsh -File scaffold-ci/scripts/rollout-canonical-asset-gate.ps1 -RepoRoot <workdir>\your-repo

.EXAMPLE
pwsh -File scaffold-ci/scripts/rollout-canonical-asset-gate.ps1 -RepoRoot <workdir>\your-mirror -CanonicalRepository YourOrg/your-mirror
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepoRoot,

    # Advisory provenance only, written into the manifest by sync-canonical-asset-manifest.ps1;
    # name the repository this skill checkout was cloned from.
    [string] $CanonicalRepository = 'YourOrg/your-skills-repo',

    [switch] $ReportOnly
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot

$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$name = Split-Path -Leaf $repo
$issues = @()

if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { $issues += 'not a git repository root' }

$ciPath = Join-Path (Join-Path $repo '.github') 'workflows'
$ciPath = Join-Path $ciPath 'ci.yml'
$policyPath = Join-Path (Join-Path $repo '.claude') 'review-policy.json'
$verifierRel = '.github/scripts/assert_canonical_assets.py'
$manifestRel = '.github/canonical-assets.json'
$verifierPath = Join-Path $repo ($verifierRel -replace '/', [IO.Path]::DirectorySeparatorChar)
$manifestPath = Join-Path $repo ($manifestRel -replace '/', [IO.Path]::DirectorySeparatorChar)
$ciText = $null
if (Test-Path -LiteralPath $ciPath -PathType Leaf) { $ciText = [IO.File]::ReadAllText($ciPath) }
$policyText = $null
if (Test-Path -LiteralPath $policyPath -PathType Leaf) { $policyText = [IO.File]::ReadAllText($policyPath) }

# Idempotence is ALL FOUR artefacts, not one: a single-marker check reads a
# half-finished adoption as complete and buries it. A partial set is a SKIP for hand
# completion.
$verifierPresent = Test-Path -LiteralPath $verifierPath -PathType Leaf
$manifestPresent = Test-Path -LiteralPath $manifestPath -PathType Leaf
$ciMentions = ($null -ne $ciText) -and $ciText.Contains('assert_canonical_assets.py')
$policyMentions = ($null -ne $policyText) -and $policyText.Contains('".github/canonical-assets.json"')
$presentParts = @(
    if ($verifierPresent) { 'verifier' }
    if ($manifestPresent) { 'manifest' }
    if ($ciMentions) { 'ci.yml step' }
    if ($policyMentions) { 'policy entry' }
)
if ($presentParts.Count -eq 4) {
    # Presence is not proof: verify the manifest and the caller's CI/policy wiring too.
    $adoptPython = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $adoptPython) { throw "no python interpreter on this host -- cannot prove $name verifies" }
    $proofOut = (& $adoptPython $verifierPath $repo 2>&1 | Out-String)
    $coverage = ($LASTEXITCODE -eq 0) -and $ciText.Contains('python3 .github/scripts/assert_canonical_assets.py') -and $policyText.Contains('".github/canonical-assets.json"')
    if (-not $coverage) {
        $issues += "all four artefacts are present but conformance is incomplete (verifier exit $LASTEXITCODE, CI/policy wiring checked) -- inspect by hand`n$proofOut"
    }
    else {
        Write-Host "SKIP $name - already adopted (verified)"
        exit 0
    }
}
elseif ($presentParts.Count -gt 0) {
    $issues += "partial adoption detected ($($presentParts -join ', ') present of verifier+manifest+ci.yml+policy) -- inspect and complete by hand"
}

if ($issues.Count -eq 0) {
    if ($null -eq $ciText) {
        $issues += 'no .github/workflows/ci.yml'
    }
    else {
        $anchorCount = [regex]::Matches($ciText, '(?m)^\s*run:\s*python3\s+\.github/scripts/assert_gate_coverage\.py\b').Count
        if ($anchorCount -ne 1) { $issues += "gate anchor found $anchorCount time(s) in ci.yml (need exactly 1)" }
        $anchorMatch = [regex]::Match($ciText, '(?m)^(?<indent>[ ]*)run:\s*python3\s+\.github/scripts/assert_gate_coverage\.py[^\r\n]*')
        if ($anchorMatch.Success) {
            if ($anchorMatch.Groups['indent'].Value.Length -lt 2) {
                $issues += 'gate anchor indentation is unreadable (less than 2 spaces) -- hand-edit this repo'
            }
            else {
                $openers = [regex]::Matches($ciText.Substring(0, $anchorMatch.Index), '(?m)^(?<indent>[ ]*)- (name|uses):')
                $expectedStepIndent = $anchorMatch.Groups['indent'].Value.Substring(0, $anchorMatch.Groups['indent'].Value.Length - 2)
                if ($openers.Count -eq 0 -or $openers[$openers.Count - 1].Groups['indent'].Value -ne $expectedStepIndent) {
                    $issues += 'gate step indentation is off-convention -- hand-edit this repo'
                }
                # The splice appends after the anchor's run: line, so run: must be the
                # step's last key -- a trailing env:/if:/working-directory: key would be
                # re-parented into the inserted step.
                $tail = $ciText.Substring($anchorMatch.Index + $anchorMatch.Length)
                $nextLine = ($tail -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1)
                if ($nextLine) {
                    $nextIndent = ([regex]::Match($nextLine, '^(?<indent>[ ]*)')).Groups['indent'].Value
                    if ($nextIndent.Length -ge $anchorMatch.Groups['indent'].Value.Length) {
                        $issues += 'the gate anchor step carries keys after run: -- hand-edit this repo'
                    }
                }
            }
        }
        if ($ciText.Contains('continue-on-error: true')) { $issues += 'ci.yml carries continue-on-error: true -- a crashed job reading green is a human review' }
        if ($ciText.Contains('pull_request_target')) { $issues += 'ci.yml runs under pull_request_target -- the PR run will not exercise the new step' }

        $callers = @(
            Get-ChildItem -LiteralPath (Join-Path (Join-Path $repo '.github') 'workflows') -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.yml', '.yaml' } |
                Where-Object { [IO.File]::ReadAllText($_.FullName) -match 'uses:\s*(\./|\$/)\.github/workflows/ci\.yml' } |
                ForEach-Object { $_.Name }
        )
        if ($callers.Count -gt 0) { $issues += "ci.yml is called via workflow_call by $($callers -join ', ') -- the caller/callee permissions union is a human review" }

        foreach ($newPath in $verifierRel, $manifestRel) {
            & git -C $repo check-ignore --no-index -q $newPath
            if ($LASTEXITCODE -eq 0) { $issues += "$newPath is gitignored -- un-ignore it deliberately (the ignore file may be the publication allowlist)" }
            elseif ($LASTEXITCODE -gt 1) { $issues += "git check-ignore failed unexpectedly (exit $LASTEXITCODE) for $newPath -- refusing to guess" }
        }

        if ($null -eq $policyText) {
            $issues += 'no .claude/review-policy.json -- decide tiering deliberately before adopting'
        }
        else {
            try {
                $policyDocument = [System.Text.Json.JsonDocument]::Parse($policyText)
                if ($policyDocument.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                    $issues += 'review-policy.json must contain a high array -- refusing to guess its shape'
                }
                else {
                    $highElement = [System.Text.Json.JsonElement]::new()
                    if (-not $policyDocument.RootElement.TryGetProperty('high', [ref]$highElement) -or
                        $highElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
                        $issues += 'review-policy.json must contain a high array -- refusing to guess its shape'
                    }
                }
                $policyDocument.Dispose()
            }
            catch { $issues += 'review-policy.json is not strict-valid JSON -- refusing to edit it' }
        }
    }
}

if ($issues.Count -gt 0) {
    Write-Host "SKIP $name - $($issues -join '; ')"
    if ($ReportOnly) { exit 0 }
    exit 2
}
if ($ReportOnly) {
    Write-Host "ADOPTABLE $name"
    exit 0
}

# --- adopt ---
New-Item -ItemType Directory -Path (Join-Path (Join-Path $repo '.github') 'scripts') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $skillRoot 'assets' 'assert_canonical_assets.py') `
    -Destination (Join-Path (Join-Path $repo '.github') 'scripts' 'assert_canonical_assets.py') -Force

& (Join-Path $PSScriptRoot 'sync-canonical-asset-manifest.ps1') -RepoRoot $repo -CanonicalRepository $CanonicalRepository

# ci.yml splice: IndexOf-based insertion after the gate anchor line -- never a regex
# replacement (the replacement-string traps are documented in powershell-traps.md).
$anchor = [regex]::Match($ciText, '(?m)^(?<indent>[ ]*)run:\s*python3\s+\.github/scripts/assert_gate_coverage\.py[^\r\n]*')
if (-not $anchor.Success) { throw "gate anchor vanished mid-edit in ${name}: refusing" }
$eol = if ($ciText.Contains("`r`n")) { "`r`n" } else { "`n" }
$runIndent = $anchor.Groups['indent'].Value
if ($runIndent.Length -lt 2) { throw "gate anchor indentation unreadable in ${name}: refusing" }
$stepIndent = $runIndent.Substring(0, $runIndent.Length - 2)
$insert = $eol + $eol +
    "$stepIndent- name: Assert canonical asset copies match the committed manifest" + $eol +
    "${runIndent}run: python3 .github/scripts/assert_canonical_assets.py"
$at = $anchor.Index + $anchor.Length
$ciText = $ciText.Substring(0, $at) + $insert + $ciText.Substring($at)
[IO.File]::WriteAllText($ciPath, $ciText, [Text.UTF8Encoding]::new($false))
$ciReread = [IO.File]::ReadAllText($ciPath)
if ([regex]::Matches($ciReread, 'assert_canonical_assets\.py').Count -ne 1) {
    throw "ci.yml splice verification failed in ${name}"
}

# review-policy.json splice: entries become the first elements of "high" (valid JSON,
# minimal diff). The manifest entry always; the verifier named entry only where the
# .github/scripts/** glob (or a prior named entry) does not already cover it. Operates
# on the preflight-read $policyText -- a concurrent edit mid-run is not the threat model.
$policyEol = if ($policyText.Contains("`r`n")) { "`r`n" } else { "`n" }
$additions = @()
if (-not $policyText.Contains('".github/canonical-assets.json"')) { $additions += '".github/canonical-assets.json"' }
$verifierCovered = $policyText.Contains('".github/scripts/**"') -or $policyText.Contains('".github/scripts/assert_canonical_assets.py"')
if (-not $verifierCovered) { $additions += '".github/scripts/assert_canonical_assets.py"' }
if ($additions.Count -gt 0) {
    $highMatch = [regex]::Match($policyText, '"high"\s*:\s*\[')
    if (-not $highMatch.Success) { throw "no `"high`" array in ${name}'s review-policy.json: refusing" }
    $afterOpen = $policyText.Substring($highMatch.Index + $highMatch.Length)
    # Trailing commas are invalid strict JSON and pwsh's ConvertFrom-Json is lenient
    # enough to hide them: an EMPTY high array takes the entries with NO trailing comma
    # on the last one. The re-read parse cannot be the only rail against this. Entry
    # detection is scoped to the array body -- past the closing bracket the next key's
    # lines (e.g. "low") would read as entries and reintroduce the trailing comma.
    $arrayEnd = $afterOpen.IndexOf(']')
    $arrayBody = if ($arrayEnd -ge 0) { $afterOpen.Substring(0, $arrayEnd) } else { $afterOpen }
    $hasEntries = $arrayBody -match '"'
    $entryIndentMatch = [regex]::Match($arrayBody, '(?m)^(?<indent>[ \t]+)"')
    $entryIndent = if ($entryIndentMatch.Success) { $entryIndentMatch.Groups['indent'].Value } else { '    ' }
    $policyInsert = ''
    for ($i = 0; $i -lt $additions.Count; $i++) {
        $comma = if ($hasEntries -or $i -lt $additions.Count - 1) { ',' } else { '' }
        $policyInsert += $policyEol + $entryIndent + $additions[$i] + $comma
    }
    $policyAt = $highMatch.Index + $highMatch.Length
    $policyText = $policyText.Substring(0, $policyAt) + $policyInsert + $policyText.Substring($policyAt)
    [IO.File]::WriteAllText($policyPath, $policyText, [Text.UTF8Encoding]::new($false))
    $policyReread = [IO.File]::ReadAllText($policyPath)
    try { $null = [System.Text.Json.JsonDocument]::Parse($policyReread) }
    catch { throw "policy splice produced unparsable JSON in ${name}: $_" }
    foreach ($addition in $additions) {
        if (-not $policyReread.Contains($addition)) { throw "policy splice verification failed in ${name}: $addition missing" }
    }
}

# The proof: the adopted repo verifies clean, or this adoption did not happen.
$python = @('python3', 'python') |
    Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $python) { throw "no python interpreter on this host -- cannot prove $name verifies" }
$verifyOut = (& $python (Join-Path (Join-Path $repo '.github') 'scripts' 'assert_canonical_assets.py') $repo 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw "post-adoption verification failed in ${name}:`n$verifyOut" }

# The checker-conformance proof: the refreshed gate checker must accept the adopted
# ci.yml, with the anchor step's own env honored -- a repo the checker rejects needs a
# conformance migration BEFORE adoption, not a surprise in its local gate after. Extract
# GATE_EXEMPT / GATE_CONDITIONAL_EXEMPT from the anchor step block (its opener line
# through the run: line); values may be quoted ('') or bare (docker); an empty value
# exports nothing. The proof runs AFTER the writes: a throw here leaves all four
# artefacts spliced, so the follow-up run takes the already-adopted branch -- migrate
# the repo by hand; its own CI is the conformance enforcement from there.
$proofAnchor = [regex]::Match($ciReread, '(?m)^(?<indent>[ ]*)run:\s*python3\s+\.github/scripts/assert_gate_coverage\.py[^\r\n]*')
$proofOpeners = [regex]::Matches($ciReread.Substring(0, $proofAnchor.Index), '(?m)^(?<indent>[ ]*)- (name|uses):')
$stepOpener = $proofOpeners[$proofOpeners.Count - 1]
$stepBlock = $ciReread.Substring($stepOpener.Index, $proofAnchor.Index - $stepOpener.Index)
$gateEnv = @{}
foreach ($key in 'GATE_EXEMPT', 'GATE_CONDITIONAL_EXEMPT') {
    $envMatch = [regex]::Match($stepBlock, "(?m)^[ ]*$key[ \t]*:[ \t]*(?<v>.*?)[ \t]*\r?$")
    if ($envMatch.Success) {
        $envValue = $envMatch.Groups['v'].Value
        if ($envValue.Length -ge 2 -and (($envValue.StartsWith("'") -and $envValue.EndsWith("'")) -or ($envValue.StartsWith('"') -and $envValue.EndsWith('"')))) {
            $envValue = $envValue.Substring(1, $envValue.Length - 2)
        }
        $gateEnv[$key] = $envValue
    }
}
$previousGateEnv = @{}
foreach ($key in 'GATE_EXEMPT', 'GATE_CONDITIONAL_EXEMPT') {
    $previousGateEnv[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    foreach ($key in 'GATE_EXEMPT', 'GATE_CONDITIONAL_EXEMPT') {
        $proofValue = $null
        if ($gateEnv.ContainsKey($key)) { $proofValue = $gateEnv[$key] }
        if ([string]::IsNullOrEmpty($proofValue)) { $proofValue = $null }
        [Environment]::SetEnvironmentVariable($key, $proofValue)
    }
    $checkerOut = (& $python (Join-Path (Join-Path $repo '.github') 'scripts' 'assert_gate_coverage.py') $ciPath 2>&1 | Out-String)
    $checkerExit = $LASTEXITCODE
}
finally {
    foreach ($key in 'GATE_EXEMPT', 'GATE_CONDITIONAL_EXEMPT') {
        [Environment]::SetEnvironmentVariable($key, $previousGateEnv[$key])
    }
}
if ($checkerExit -ne 0) {
    throw "the refreshed gate checker rejects this repo's ci.yml -- migrate first (see the output), then re-run the rollout:`n$checkerOut"
}

Write-Host "ADOPT $name - verifier copied, manifest generated, ci.yml + review-policy spliced, verified clean"
exit 0
