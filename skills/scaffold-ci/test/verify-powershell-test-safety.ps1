#Requires -Version 7
# Fixture source is data only. Execute this verifier in a disposable container or VM.
$ErrorActionPreference = 'Stop'
$python = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $python) { throw 'Python is required for the PowerShell safety lint contracts' }
& $python (Join-Path $PSScriptRoot 'powershell_test_safety_test.py')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0
