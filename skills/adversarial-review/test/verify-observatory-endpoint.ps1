#requires -Version 7
$ErrorActionPreference = 'Stop'
<#
  The per-call telemetry in the vendor drivers must take its endpoint from
  OBSERVATORY_URL and skip the post when it is unset, as emit-review-telemetry.ps1
  already does. A hard-coded host fallback posts to one private deployment from
  every machine and discloses that host to every runtime that mounts this skill.
#>

function Assert-ObservatoryEndpoint([string] $name, [string] $text) {
    if ($text -match 'OBSERVATORY_URL\s*\?\?') {
        throw "$name falls back to a hard-coded Observatory host when OBSERVATORY_URL is unset"
    }
    if ($text -match 'https?://[^\s''"]*azurewebsites\.net') {
        throw "$name names an azurewebsites.net host"
    }
    $gate = [regex]::Match($text, '(?m)^\s*if \(\$env:OBSERVATORY_API_KEY[^\r\n]*\)\s*\{')
    # Public mirror: the gemini driver gates on $observatoryUrl, a local assigned only from
    # $env:OBSERVATORY_URL (the assignment check below enforces that), so accept either form.
    if (-not $gate.Success -or $gate.Value -notmatch '\$env:OBSERVATORY_URL|\$observatoryUrl') {
        throw "$name does not gate its telemetry post on OBSERVATORY_URL"
    }

    # The gate alone proved nothing about WHERE the post goes: a driver gating on
    # OBSERVATORY_URL and posting to a literal host passed. Every /api/events Uri must be
    # the env var (directly or through $observatoryUrl), and $observatoryUrl itself may only
    # ever be assigned from it.
    $allowedHosts = '$observatoryUrl', '$env:OBSERVATORY_URL'
    # Either quote style is read. A single-quoted Uri is a literal -- '$observatoryUrl/...'
    # never expands -- so only the double-quoted form can carry the env var; anything
    # single-quoted is a hard-coded host by construction of the language.
    $posts = [regex]::Matches($text, '(?m)(?:-Uri|\bUri\s*=)\s*(?<q>["''])(?<host>[^"'']*)/api/events\k<q>')
    if ($posts.Count -eq 0) { throw "$name has no /api/events post to check" }
    foreach ($post in $posts) {
        if ($post.Groups['q'].Value -ne '"' -or $post.Groups['host'].Value -notin $allowedHosts) {
            throw "$name posts telemetry to '$($post.Groups['host'].Value)' rather than OBSERVATORY_URL"
        }
    }
    foreach ($assignment in [regex]::Matches($text, '(?m)\$observatoryUrl\s*=\s*([^\r\n]*)')) {
        if ($assignment.Groups[1].Value.Trim() -ne '$env:OBSERVATORY_URL') {
            throw "$name assigns `$observatoryUrl from something other than `$env:OBSERVATORY_URL: $($assignment.Value.Trim())"
        }
    }
    if ($text -match '\$obsReq(?:\.Uri|\[[''"]Uri[''"]\])\s*=') {
        throw "$name reassigns the request Uri after building it"
    }
}

$drivers = 'codex-review.ps1', 'gemini-review.ps1', 'openai-review.ps1'
foreach ($name in $drivers) {
    $path = Join-Path $PSScriptRoot '..' $name
    if (-not (Test-Path -LiteralPath $path)) { throw "driver not found: $path" }
    Assert-ObservatoryEndpoint $name (Get-Content -LiteralPath $path -Raw)
}

# RED CHECK: a driver that still gates on OBSERVATORY_URL but posts somewhere else
# entirely must be rejected. The gate check alone accepted this, because it never tied
# the post URL to the variable it gates on.
$codex = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'codex-review.ps1') -Raw
$mutated = $codex.Replace('"$observatoryUrl/api/events"', '"https://collector.example.net/api/events"')
if ($mutated -eq $codex) { throw 'red check did not mutate the codex driver' }
$rejected = $false
try { Assert-ObservatoryEndpoint 'mutated codex-review.ps1' $mutated } catch { $rejected = $true }
if (-not $rejected) { throw 'a driver posting to a host other than OBSERVATORY_URL was accepted' }

# RED CHECK: the valid post retained, plus a SECOND post whose Uri is single-quoted. The
# Uri regex only read double-quoted URIs, so this literal host was never inspected and the
# driver passed on the strength of the post it kept. (CodeRabbit, public mirror PR #124.)
$singleQuoted = $codex + "`nInvoke-RestMethod -Uri 'https://collector.example.net/api/events' -Method Post`n"
$rejected = $false
try { Assert-ObservatoryEndpoint 'single-quoted codex-review.ps1' $singleQuoted } catch { $rejected = $true }
if (-not $rejected) { throw 'a driver adding a single-quoted literal-host post beside the valid one was accepted' }

'adversarial-review observatory endpoint contract OK'
