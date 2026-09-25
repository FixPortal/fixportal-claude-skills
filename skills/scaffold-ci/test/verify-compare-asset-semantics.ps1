#requires -Version 7
$ErrorActionPreference = 'Stop'

# scaffold-ci/test_compare_asset_semantics.py sits at the SKILL ROOT, and the CI runner
# (.github/scripts/run-skill-tests.ps1) discovers only <skill>/test/verify-*.ps1,
# verify-*.mjs and test_*.py -- so that unittest suite never ran and gated nothing. This
# runs it from here so it does. python3 first, then python: a stock ubuntu runner may
# ship no `python` (the same order verify-rollout-canonical-asset-gate.ps1 uses).

$skillRoot = Split-Path -Parent $PSScriptRoot
$suite = Join-Path $skillRoot 'test_compare_asset_semantics.py'
if (-not (Test-Path -LiteralPath $suite -PathType Leaf)) { throw "unittest suite not found: $suite" }

$python = @('python3', 'python') |
    Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $python) { throw 'no python interpreter on this host - compare-asset-semantics.py is unchecked' }

# No __pycache__ left inside the skill directory. -B and the env var both ask for that,
# and a run under run-skill-tests.ps1 still left scaffold-ci/__pycache__ behind once
# (observed 2026-09-25, not reproduced standalone), so the directory is removed after the
# run as well. The skill root holds exactly one Python module -- this suite -- so that
# directory can only ever contain its bytecode.
$env:PYTHONDONTWRITEBYTECODE = '1'
Push-Location -LiteralPath $skillRoot
try {
    $output = & $python -B -m unittest -v test_compare_asset_semantics 2>&1 | Out-String
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
    Remove-Item -LiteralPath (Join-Path $skillRoot '__pycache__') -Recurse -Force -ErrorAction SilentlyContinue
}

if ($code -ne 0) { throw "compare-asset-semantics unit tests failed (exit $code):`n$output" }

'scaffold-ci compare-asset-semantics unit tests OK'
