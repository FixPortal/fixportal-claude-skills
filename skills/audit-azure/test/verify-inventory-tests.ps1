#requires -Version 7
<#
.SYNOPSIS
  Runs the Pester suite for the inventory script, so this repository's CI gates its behaviour.

.DESCRIPTION
  CI here discovers verify-*.ps1 only. The behavioural tests for the GET-only wrapper,
  redaction, paging and not-observed handling are a Pester 5 suite (Inventory.Tests.ps1), so
  without this file nothing would run them and a regression in redaction could merge green.

  Pester runs only in a disposable lane: a CI runner or Windows Sandbox. Anywhere else this
  verifier skips with a stated reason. On a CI runner a missing Pester 5 is a failure, not a
  skip: a gate that quietly stops running is worse than one that fails.

  This file exists in this mirror only. The canonical copy's test runner executes Pester
  suites directly.
#>
$ErrorActionPreference = 'Stop'

$onCi = $env:CI -eq 'true'
$inSandbox = $env:USERNAME -eq 'WDAGUtilityAccount'
if (-not ($onCi -or $inSandbox)) {
    Write-Host 'SKIP: Pester suites run only on a CI runner or in Windows Sandbox'
    exit 0
}

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    if ($onCi) { throw 'Pester 5 is not installed on this CI runner, so the inventory tests cannot run' }
    Write-Host 'SKIP: Pester 5 is not installed on this host'
    exit 0
}
Import-Module $pester.Path -Force

$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot 'Inventory.Tests.ps1'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$result = Invoke-Pester -Configuration $configuration

if ($result.TotalCount -eq 0) { throw 'Inventory.Tests.ps1 discovered no tests' }
if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) {
    $names = ($result.Failed | Select-Object -First 5 | ForEach-Object ExpandedName) -join '; '
    throw "Inventory.Tests.ps1: $($result.FailedCount) of $($result.TotalCount) failed: $names"
}
"audit-azure inventory tests OK - $($result.PassedCount) passed, $($result.SkippedCount) skipped (Pester $($pester.Version))"
