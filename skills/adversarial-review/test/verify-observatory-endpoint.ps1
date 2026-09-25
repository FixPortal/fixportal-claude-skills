#requires -Version 7
$ErrorActionPreference = 'Stop'
<#
  The per-call telemetry in the vendor drivers must take its endpoint from
  OBSERVATORY_URL and skip the post when it is unset, as emit-review-telemetry.ps1
  already does. A hard-coded host fallback posts to one private deployment from
  every machine and discloses that host to every runtime that mounts this skill.
#>

$drivers = 'codex-review.ps1', 'gemini-review.ps1', 'openai-review.ps1'
foreach ($name in $drivers) {
    $path = Join-Path $PSScriptRoot '..' $name
    if (-not (Test-Path -LiteralPath $path)) { throw "driver not found: $path" }
    $text = Get-Content -LiteralPath $path -Raw

    if ($text -match 'OBSERVATORY_URL\s*\?\?') {
        throw "$name falls back to a hard-coded Observatory host when OBSERVATORY_URL is unset"
    }
    if ($text -match 'https?://[^\s''"]*azurewebsites\.net') {
        throw "$name names an azurewebsites.net host"
    }
    $gate = [regex]::Match($text, '(?m)^\s*if \(\$env:OBSERVATORY_API_KEY[^\r\n]*\)\s*\{')
    # The gate may test the variable directly, or a local assigned from it and nothing else.
    $fromEnvOnly = $text -match '(?m)^\s*\$observatoryUrl\s*=\s*\$env:OBSERVATORY_URL\s*$'
    $gated = $gate.Success -and ($gate.Value -match '\$env:OBSERVATORY_URL' -or ($fromEnvOnly -and $gate.Value -match '\$observatoryUrl'))
    if (-not $gated) {
        throw "$name does not gate its telemetry post on OBSERVATORY_URL"
    }
}

'adversarial-review observatory endpoint contract OK'
