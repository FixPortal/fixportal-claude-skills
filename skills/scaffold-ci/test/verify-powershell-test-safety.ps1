#Requires -Version 7
# Fixture source is data only. Execute this verifier in a disposable container or VM.
$ErrorActionPreference = 'Stop'
$python = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $python) { throw 'Python is required for the PowerShell safety lint contracts' }
# CodeRabbit, public mirror PR #142: every fixture directory the suite creates must be removed again.
$tempRoot = & $python -c 'import tempfile; print(tempfile.gettempdir())'
if ($LASTEXITCODE -ne 0) { throw 'Could not read the Python temp directory' }
$fixturePatterns = 'powershell-safety-*', 'not-a-repository-*', 'outside-source-*'
function Get-FixtureDirectories { @($fixturePatterns | ForEach-Object { Get-ChildItem -LiteralPath $tempRoot -Directory -Filter $_ -Force } | ForEach-Object FullName) }
$before = Get-FixtureDirectories
& $python (Join-Path $PSScriptRoot 'powershell_test_safety_test.py')
$suiteExit = $LASTEXITCODE
# Checked even when a test failed: a failing test must not hide a leak.
$leaked = @(Get-FixtureDirectories | Where-Object { $_ -notin $before })
if ($leaked.Count) { throw "The suite (exit $suiteExit) left $($leaked.Count) fixture directories behind: $($leaked -join ', ')" }
if ($suiteExit -ne 0) { exit $suiteExit }
exit 0
