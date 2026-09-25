#requires -Version 7
$ErrorActionPreference = 'Stop'

# assert_canonical_assets.py is the PR-time half of the divergence gate: a repo editing a
# copied canonical asset fails its own CI unless .github/canonical-assets.json is
# regenerated in the same PR, which puts the divergence in the diff. This pins the
# verifier's verdicts, its fail-closed rails, and -- critically -- the hash contract: the
# manifest hashes here are computed in POWERSHELL, so a green run proves the Python reader
# and any PowerShell writer agree byte for byte.

$verifier = Resolve-Path (Join-Path $PSScriptRoot '..' 'assets' 'assert_canonical_assets.py')
$root = Join-Path ([IO.Path]::GetTempPath()) ('canonical-assets-' + [guid]::NewGuid().ToString('N'))

# python3 first, then python -- a stock ubuntu runner ships python3 and may ship no python
# at all (same probe run-skill-tests.ps1 and verify-gate-coverage.ps1 use).
$python = @('python3', 'python') |
    Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $python) { throw 'no python interpreter on this host - the verifier contract cannot be checked' }

# The hash contract, implemented here independently of BOTH the verifier and the
# generator: UTF-8 BOM tolerated, CRLF/CR -> LF, SHA-pinned `uses:` refs masked, UTF-8 no
# BOM, sha256 lowercase hex.
function Get-AssetHash([string] $Path) {
    $text = [IO.File]::ReadAllText($Path) -replace "\r\n?", "`n"
    $text = $text -creplace '(?m)^([ \t]*(?:-[ \t]+)?uses:[ \t]*[^\s@#]+@)[0-9a-f]{40}(?:[ \t]+#.*)?$', '$1<pinned>'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function New-FixtureRepo([string] $Name) {
    $repo = Join-Path $root $Name
    New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo '.github' 'scripts') -Force | Out-Null
    return $repo
}

function Write-Asset([string] $Repo, [string] $Relative, [string[]] $Lines) {
    $path = Join-Path $Repo ($Relative -replace '/', [IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, ($Lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}

function Write-Manifest([string] $Repo, [string[]] $Paths) {
    $entries = @($Paths | ForEach-Object {
        [pscustomobject]@{ path = $_; sha256 = (Get-AssetHash (Join-Path $Repo ($_ -replace '/', [IO.Path]::DirectorySeparatorChar))); verbatim = $true }
    })
    $manifest = [pscustomobject]@{
        schema = 1
        canonical = [pscustomobject]@{ repository = 'test/fixture'; commit = 'fixture'; syncedAt = '2026-09-21' }
        assets = $entries
    }
    $json = ($manifest | ConvertTo-Json -Depth 5) -replace "\r\n?", "`n"
    [IO.File]::WriteAllText((Join-Path $Repo '.github' 'canonical-assets.json'), $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Invoke-Verifier([string] $Repo) {
    $out = (& $python $verifier $Repo 2>&1 | Out-String)
    $code = $LASTEXITCODE
    return @{ Code = $code; Output = $out }
}

$assetA = '.github/scripts/checker_a.py'
$assetB = '.github/scripts/checker_b.py'
$linesA = @('#!/usr/bin/env python3', '"""Checker A."""', 'print("a")')
$linesB = @('#!/usr/bin/env python3', '"""Checker B."""', 'print("b")')

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    # clean: every listed asset matches -> exit 0
    $clean = New-FixtureRepo 'clean'
    Write-Asset $clean $assetA $linesA
    Write-Asset $clean $assetB $linesB
    Write-Manifest $clean @($assetA, $assetB)
    $r = Invoke-Verifier $clean
    if ($r.Code -ne 0) { throw "clean fixture must exit 0; got $($r.Code)`n$($r.Output)" }

    # tampered: one byte differs -> exit 1 naming the DIVERGED asset, with the teaching block
    Write-Asset $clean $assetB @('#!/usr/bin/env python3', '"""Checker B."""', 'print("locally rewritten")')
    $r = Invoke-Verifier $clean
    if ($r.Code -ne 1) { throw "tampered fixture must exit 1; got $($r.Code)`n$($r.Output)" }
    if ($r.Output -notmatch [regex]::Escape("DIVERGED $assetB")) { throw "tampered fixture must name the diverged asset`n$($r.Output)" }
    if ($r.Output -notmatch 'sync-canonical-asset-manifest\.ps1') { throw "failure output must teach the regeneration command`n$($r.Output)" }
    if ($r.Output -notmatch [regex]::Escape("ok       $assetA")) { throw "the untouched asset must still read ok`n$($r.Output)" }
    Write-Asset $clean $assetB $linesB  # restore

    # missing: a listed file deleted -> exit 1 with the MISSING verdict
    Remove-Item -LiteralPath (Join-Path $clean ($assetB -replace '/', [IO.Path]::DirectorySeparatorChar))
    $r = Invoke-Verifier $clean
    if ($r.Code -ne 1) { throw "deleted-asset fixture must exit 1; got $($r.Code)`n$($r.Output)" }
    if ($r.Output -notmatch [regex]::Escape("MISSING  $assetB")) { throw "deleted asset must read MISSING`n$($r.Output)" }
    Write-Asset $clean $assetB $linesB  # restore

    # CRLF: a CRLF checkout of identical content must verify -- git flips line endings per
    # .gitattributes, and a hash that red-lines a CRLF checkout is a false-positive factory.
    $crlfPath = Join-Path $clean ($assetA -replace '/', [IO.Path]::DirectorySeparatorChar)
    [IO.File]::WriteAllText($crlfPath, ($linesA -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
    $r = Invoke-Verifier $clean
    if ($r.Code -ne 0) { throw "CRLF fixture must exit 0; got $($r.Code)`n$($r.Output)" }

    # BOM: a BOM'd asset hashes BOM-less on both sides (Python utf-8-sig, .NET ReadAllText).
    [IO.File]::WriteAllText($crlfPath, ($linesA -join "`n") + "`n", [Text.UTF8Encoding]::new($true))
    $r = Invoke-Verifier $clean
    if ($r.Code -ne 0) { throw "BOM fixture must exit 0; got $($r.Code)`n$($r.Output)" }
    Write-Asset $clean $assetA $linesA  # restore

    # SHA-pinned `uses:` refs: a Dependabot bump (new SHA + new version comment) must
    # verify, while swapping the action or unpinning it to a tag must still diverge.
    $wf = '.github/workflows/pinned.yml'
    $wfLines = @('jobs:', '  s:', '    steps:',
        '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v5.0.0',
        '      - name: scan', '        uses: trufflesecurity/trufflehog@363923b901c911a9164f50b6c423f47c15372b1c # v3.97.4',
        '        with:', '          version: 3.96.0')
    Write-Asset $clean $wf $wfLines
    Write-Manifest $clean @($assetA, $assetB, $wf)
    $bumped = $wfLines.Clone()
    $bumped[3] = '      - uses: actions/checkout@0000000000000000000000000000000000000abc # v5.1.0'
    $bumped[5] = '        uses: trufflesecurity/trufflehog@f714bf454f350590f4a24c3ddb1aef02c35bf5b6 # v3.97.5'
    Write-Asset $clean $wf $bumped
    $r = Invoke-Verifier $clean
    if ($r.Code -ne 0) { throw "a SHA pin bump must verify; got $($r.Code)`n$($r.Output)" }
    foreach ($bad in @(
        '        uses: evil/trufflehog@f714bf454f350590f4a24c3ddb1aef02c35bf5b6 # v3.97.5'
        '        uses: trufflesecurity/trufflehog@v3.97.5'
        '        uses: trufflesecurity/trufflehog@F714BF454F350590F4A24C3DDB1AEF02C35BF5B6 # v3.97.5')) {
        $mutant = $wfLines.Clone(); $mutant[5] = $bad
        Write-Asset $clean $wf $mutant
        $r = Invoke-Verifier $clean
        if ($r.Code -ne 1) { throw "'$bad' must diverge; got $($r.Code)`n$($r.Output)" }
    }
    $unpinnedScanner = $wfLines.Clone(); $unpinnedScanner[7] = '          version: latest'
    Write-Asset $clean $wf $unpinnedScanner
    $r = Invoke-Verifier $clean
    if ($r.Code -ne 1) { throw "a non-uses line edit must still diverge; got $($r.Code)`n$($r.Output)" }
    Remove-Item -LiteralPath (Join-Path $clean ($wf -replace '/', [IO.Path]::DirectorySeparatorChar))
    Write-Manifest $clean @($assetA, $assetB)

    # unlisted extra file: not the manifest's business in v1 -> still exit 0
    Write-Asset $clean '.github/scripts/extra_local.py' @('# purely local, never inventoried')
    $r = Invoke-Verifier $clean
    if ($r.Code -ne 0) { throw "an unlisted file must be ignored; got $($r.Code)`n$($r.Output)" }

    # no manifest at all -> exit 2 (control broken must not read as assets fine)
    $bare = New-FixtureRepo 'bare'
    $r = Invoke-Verifier $bare
    if ($r.Code -ne 2) { throw "missing manifest must exit 2; got $($r.Code)`n$($r.Output)" }

    # unparsable manifest -> exit 2 (may carry a hand-edit; fix or regenerate)
    [IO.File]::WriteAllText((Join-Path $bare '.github' 'canonical-assets.json'),
        "not json`n", [Text.UTF8Encoding]::new($false))
    $r = Invoke-Verifier $bare
    if ($r.Code -ne 2) { throw "an unparsable manifest must exit 2; got $($r.Code)`n$($r.Output)" }

    # unknown schema -> exit 2, fail closed
    Write-Asset $bare $assetA $linesA
    [IO.File]::WriteAllText((Join-Path $bare '.github' 'canonical-assets.json'),
        "{ `"schema`": 99, `"assets`": [] }`n", [Text.UTF8Encoding]::new($false))
    $r = Invoke-Verifier $bare
    if ($r.Code -ne 2) { throw "unknown schema must exit 2; got $($r.Code)`n$($r.Output)" }

    # empty asset list -> exit 2 (refusing to report success over nothing)
    [IO.File]::WriteAllText((Join-Path $bare '.github' 'canonical-assets.json'),
        "{ `"schema`": 1, `"assets`": [] }`n", [Text.UTF8Encoding]::new($false))
    $r = Invoke-Verifier $bare
    if ($r.Code -ne 2) { throw "empty asset list must exit 2; got $($r.Code)`n$($r.Output)" }

    # a manifest entry escaping the repo -> exit 2, fail closed
    [IO.File]::WriteAllText((Join-Path $bare '.github' 'canonical-assets.json'),
        "{ `"schema`": 1, `"assets`": [{ `"path`": `"../outside.py`", `"sha256`": `"00`" }] }`n", [Text.UTF8Encoding]::new($false))
    $r = Invoke-Verifier $bare
    if ($r.Code -ne 2) { throw "an escaping path must exit 2; got $($r.Code)`n$($r.Output)" }

    # ---------------- generator: sync-canonical-asset-manifest.ps1 ----------------
    $generator = Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'sync-canonical-asset-manifest.ps1')
    $skillRoot = Split-Path -Parent (Split-Path -Parent $generator)

    # round-trip: a repo carrying REAL canonical copies gets a manifest the PYTHON
    # verifier accepts -- the cross-implementation proof that matters. The set includes a
    # verbatim:FALSE variance asset, which the sweep cannot cover but the manifest must.
    $gen = New-FixtureRepo 'gen'
    New-Item -ItemType Directory -Path (Join-Path $gen 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $gen '.github' 'workflows') -Force | Out-Null
    foreach ($pair in @(
        @{ From = 'assets/assert_gate_coverage.py'; To = '.github/scripts/assert_gate_coverage.py' }
        @{ From = 'assets/secret-sweep.yml';          To = '.github/workflows/secret-sweep.yml' }
        @{ From = 'templates/summarize-stryker.ps1';  To = 'scripts/summarize-stryker.ps1' }
    )) {
        Copy-Item (Join-Path $skillRoot $pair.From) (Join-Path $gen ($pair.To -replace '/', [IO.Path]::DirectorySeparatorChar)) -Force
    }
    & $generator -RepoRoot $gen | Out-Null
    $manifestPath = Join-Path $gen '.github' 'canonical-assets.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'generator wrote no manifest' }
    $r = Invoke-Verifier $gen
    if ($r.Code -ne 0) { throw "round-trip must verify clean; got $($r.Code)`n$($r.Output)" }

    # the manifest is BOM-less LF JSON with a provenance block naming the canonical HEAD
    $raw = [IO.File]::ReadAllBytes($manifestPath)
    if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
        throw 'manifest must be BOM-less -- a BOM breaks json.load on the Python side'
    }
    $written = [IO.File]::ReadAllText($manifestPath)
    if ($written.Contains("`r")) { throw 'manifest must be LF-only' }
    $parsed = $written | ConvertFrom-Json
    $head = (& git -C $skillRoot rev-parse HEAD 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "could not read the skills repo HEAD for the provenance assertion: $head" }
    if ($parsed.canonical.repository -ne 'YourOrg/your-skills-repo') {
        throw "default provenance repository wrong: $($parsed.canonical.repository)"
    }
    if ($parsed.canonical.commit -ne $head) { throw "provenance commit must be the canonical checkout's HEAD; got $($parsed.canonical.commit)" }
    if ($parsed.canonical.syncedAt -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "syncedAt must be yyyy-MM-dd; got $($parsed.canonical.syncedAt)" }
    if (@($parsed.assets).Count -ne 3) { throw "fixture carries 3 inventoried assets; manifest lists $(@($parsed.assets).Count)" }
    $varianceEntry = @($parsed.assets | Where-Object { $_.path -eq '.github/workflows/secret-sweep.yml' })
    if ($varianceEntry.Count -ne 1 -or $varianceEntry[0].verbatim -ne $false) {
        throw 'the variance asset must be listed with verbatim=false'
    }

    # deliberate-divergence flow: edit -> regenerate -> verifier green again, in one act
    $gateCopy = Join-Path $gen '.github' 'scripts' 'assert_gate_coverage.py'
    Add-Content -LiteralPath $gateCopy -Value '# local hardening, deliberately diverged' -Encoding utf8
    $r = Invoke-Verifier $gen
    if ($r.Code -ne 1) { throw "a post-edit divergence must fail; got $($r.Code)`n$($r.Output)" }
    & $generator -RepoRoot $gen | Out-Null
    $r = Invoke-Verifier $gen
    if ($r.Code -ne 0) { throw "post-regeneration must verify clean; got $($r.Code)`n$($r.Output)" }

    # a variance asset's recorded local adaptation is fine -- a SUBSEQUENT edit is what fails
    $secretCopy = Join-Path $gen '.github' 'workflows' 'secret-sweep.yml'
    Add-Content -LiteralPath $secretCopy -Value '# one more local tweak' -Encoding utf8
    $r = Invoke-Verifier $gen
    if ($r.Code -ne 1) { throw "editing a recorded variance asset must fail; got $($r.Code)`n$($r.Output)" }

    # refusal: not a git repository root
    $noGit = Join-Path $root 'no-git'
    New-Item -ItemType Directory -Path $noGit -Force | Out-Null
    $refused = $false
    try { & $generator -RepoRoot $noGit } catch { $refused = $true }
    if (-not $refused) { throw 'generator must refuse a non-git root' }

    # refusal: a git repo carrying NONE of the inventoried assets
    $empty = New-FixtureRepo 'empty'
    $refused = $false
    try { & $generator -RepoRoot $empty } catch { $refused = $_.Exception.Message -match 'refusing to write a manifest that verifies nothing' }
    if (-not $refused) { throw 'generator must refuse an empty manifest with the stated reason' }

    # refusal: an existing UNPARSABLE manifest may carry a hand-edit -- never overwrite
    [IO.File]::WriteAllText((Join-Path $gen '.github' 'canonical-assets.json'), "not json`n", [Text.UTF8Encoding]::new($false))
    $refused = $false
    try { & $generator -RepoRoot $gen } catch { $refused = $_.Exception.Message -match 'not strict-valid JSON' }
    if (-not $refused) { throw 'generator must refuse to overwrite an unparsable manifest' }

    # a non-UTF-8 asset must be refused at GENERATION time, not hashed as replacement
    # characters (the Python verifier strict-decodes, so such a manifest could never
    # verify). The corrupted file must be a REAL inventoried asset -- an uninventoried
    # path never reaches the hash read -- so: the canonical bytes plus one invalid byte.
    $ansi = New-FixtureRepo 'ansi'
    $ansiAsset = Join-Path $ansi '.github' 'scripts' 'assert_gate_coverage.py'
    $gateBytes = [IO.File]::ReadAllBytes((Join-Path $skillRoot 'assets' 'assert_gate_coverage.py'))
    [IO.File]::WriteAllBytes($ansiAsset, [byte[]] ($gateBytes + 0xFF))
    $refused = $false
    try { & $generator -RepoRoot $ansi } catch { $refused = $_.Exception.Message -match 'not valid UTF-8' }
    if (-not $refused) { throw 'generator must refuse a non-UTF-8 asset, naming it' }

    # a trailing-comma manifest is not strict JSON -- pwsh's ConvertFrom-Json accepts it,
    # so the refusal must use a strict parser or a hand-edit gets silently overwritten
    [IO.File]::WriteAllText((Join-Path $gen '.github' 'canonical-assets.json'), "{`"schema`": 1, `"assets`": [], }`n", [Text.UTF8Encoding]::new($false))
    $refused = $false
    try { & $generator -RepoRoot $gen } catch { $refused = $_.Exception.Message -match 'strict-valid JSON' }
    if (-not $refused) { throw 'generator must refuse a trailing-comma manifest as not strict-valid JSON' }

    'assert_canonical_assets.py + sync-canonical-asset-manifest.ps1 OK - verdicts, CRLF/BOM tolerance, SHA-pin masking, fail-closed rails, generator round-trip, provenance, deliberate-divergence flow, refusals, strict-UTF-8 and trailing-comma refusals'
}
finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
