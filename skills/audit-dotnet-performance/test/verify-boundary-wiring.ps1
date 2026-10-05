$ErrorActionPreference = 'Stop'

$skill = Get-Content -Raw (Join-Path $PSScriptRoot '..\SKILL.md')
if ($skill -notmatch '(?is)In repository mode only.*test-managed-product-boundary\.ps1') {
    throw 'The managed product boundary guard must be scoped to repository mode.'
}

Write-Host 'managed product boundary wiring OK'
