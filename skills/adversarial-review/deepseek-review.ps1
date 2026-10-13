#Requires -Version 7
<#
.SYNOPSIS
    DeepSeek reviewer for the adversarial-review skill (metered Chat Completions API).
.DESCRIPTION
    Hermetic by construction: a single HTTPS call with every input inlined into the user
    message. No CLI, no tools, no repository access, no working-directory surface. Phase 1
    (-DiffPath) and Phase 2 (-DiffPath + -FindingsPath) are supported; -ContextPath supplies
    repo files as read-only background because this reviewer is repo-blind.
.NOTES
    PREFLIGHT_COMMAND: pwsh -NoProfile -File ~/.agents/skills/adversarial-review/deepseek-review.ps1 -Preflight -Model deepseek-v4-pro
    PREFLIGHT_SUCCESS: exit 0 and stdout is DEEPSEEK_PREFLIGHT_OK (authenticated model response from the requested model).
    Windows credential: Read-Host 'Deepseek API key' -AsSecureString | Export-Clixml -LiteralPath "$env:LOCALAPPDATA/YourOrg/deepseek-trial/deepseek-key.clixml"
    The model id is passed through verbatim and the response's own model field must equal it;
    there is deliberately no release-shaped pattern guard (model-routing-traps.md trap 10).
    Metered: billed per token against the account's balance, peak/off-peak rates per the registry note.
#>
[CmdletBinding(DefaultParameterSetName='Review')]
param(
    [Parameter(Mandatory, ParameterSetName='Review')][string] $Instruction,
    [Parameter(Mandatory, ParameterSetName='Review')][string] $DiffPath,
    [string] $FindingsPath,
    [string[]] $ContextPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Model,
    [string] $OutPath,
    [string] $UsageSidecarPath,
    [Parameter(Mandatory, ParameterSetName='Preflight')][switch] $Preflight,
    [ValidateRange(30,2700)][int] $TimeoutSeconds = 2400
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$BaseUrl = 'https://api.deepseek.com'

function New-DeepseekRequestBody([string]$Model, [string]$Prompt) {
    # No system message and no tools, symmetric with the other metered wrapper. max_tokens covers the model's
    # thinking tokens as well as the answer: 64000 returned finish_reason "length" on a 108KB diff (2026-10-13),
    # so the cap sits well under the 384K ceiling but is not the binding limit; the timeout is.
    @{ model = $Model; messages = @(@{ role = 'user'; content = $Prompt }); max_tokens = 160000; stream = $false } |
        ConvertTo-Json -Depth 6 -Compress
}

function Read-DeepseekResponse($Response, [string]$Model) {
    if ($Response.model -cne $Model) { throw "DeepSeek response model '$($Response.model)' differs from the requested '$Model'." }
    $choice = @($Response.choices)[0]
    if ($null -eq $choice -or $choice.finish_reason -ne 'stop') { throw "DeepSeek did not return a complete response (finish_reason: $($choice.finish_reason))." }
    if ([string]::IsNullOrWhiteSpace($choice.message.content)) { throw 'DeepSeek returned an empty response.' }
    $choice.message.content
}

function Get-RegistryCost([string]$Model, [long]$InTok, [long]$OutTok) {
    $registryPath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'model-registry') 'registry.json'
    $priceHelper = Join-Path (Split-Path $registryPath -Parent) 'price.ps1'
    if (-not (Test-Path -LiteralPath $registryPath) -or -not (Test-Path -LiteralPath $priceHelper)) { return $null }
    . $priceHelper
    try {
        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -AsHashtable
        if (-not $registry.models.ContainsKey($Model)) { return $null }
        $on = $env:MODEL_REGISTRY_EFFECTIVE_DATE ?? (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        $cost = Get-ModelRegistryCost -Facts $registry.models[$Model] -InputTokens $InTok -OutputTokens $OutTok -Channel api -On $on
    } catch { return $null }
    if ($null -ne $cost) { [Math]::Round($cost, 8) }
}

function Read-InputFile([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found: $Path" }
    Get-Content -LiteralPath $Path -Raw
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $IsWindows) { throw 'DeepSeek credential uses Windows DPAPI; configure this reviewer only on its Windows host.' }

$prompt = if ($Preflight) { 'Reply exactly DEEPSEEK_PREFLIGHT_OK.' } else {
    $parts = @($Instruction)
    if (-not $FindingsPath) {
        $parts += 'STYLE REQUIREMENT: Terse output only. No preamble, no summary, no closing remarks. Per finding: severity + location + one-sentence description + one-sentence fix. Skip any finding you cannot substantiate from the diff.'
    }
    $parts += @('--- DIFF UNDER REVIEW ---', (Read-InputFile $DiffPath 'Diff file'))
    if ($FindingsPath) { $parts += @('--- POOLED FINDINGS (attribution removed) ---', (Read-InputFile $FindingsPath 'Findings file')) }
    foreach ($path in @($ContextPath | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $parts += @("--- CONTEXT: $path (background, not under review; raise no findings against it) ---", (Read-InputFile $path 'Context file'))
    }
    $parts -join "`n`n"
}

$credentialPath = Join-Path $env:LOCALAPPDATA 'YourOrg/deepseek-trial/deepseek-key.clixml'
$secureKey = Import-Clixml -LiteralPath $credentialPath
if ($secureKey -isnot [Security.SecureString]) { throw 'Expected a DPAPI-encrypted SecureString credential.' }
$key = [Net.NetworkCredential]::new('', $secureKey).Password
if ([string]::IsNullOrWhiteSpace($key)) { throw 'Empty DeepSeek credential.' }

try {
    $body = [Text.Encoding]::UTF8.GetBytes((New-DeepseekRequestBody $Model $prompt))
    $retryable = @(408, 429, 500, 502, 503, 504)
    $maxAttempts = 3
    $response = $null
    # TimeoutSeconds is a TOTAL budget across attempts, so the wrapper fails on its own before the driver's
    # 2700s round ceiling instead of letting three full-length attempts run past it.
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
        try {
            $response = Invoke-RestMethod -Uri "$BaseUrl/chat/completions" -Method Post -ContentType 'application/json; charset=utf-8' `
                -Headers @{ Authorization = "Bearer $key" } -Body $body -TimeoutSec ([Math]::Max(1, $remaining))
            break
        } catch {
            $status = $_.Exception.Response?.StatusCode.value__
            $detail = "$($_.Exception.Message) $($_.ErrorDetails.Message)".Replace($key, '[REDACTED]')
            $backoff = [Math]::Pow(2, $attempt) + (Get-Random -Minimum 0.0 -Maximum 1.0)
            if ($attempt -eq $maxAttempts -or ($null -ne $status -and $retryable -notcontains $status) -or ([DateTime]::UtcNow.AddSeconds($backoff + 30) -gt $deadline)) {
                throw "DeepSeek API call failed ($($null -eq $status ? 'no HTTP response' : "HTTP $status")) after $attempt attempt(s): $detail"
            }
            Start-Sleep -Seconds $backoff
        }
    }
    $text = Read-DeepseekResponse $response $Model
    if ($Preflight) {
        if (($text.Trim() -replace '\.$', '') -ne 'DEEPSEEK_PREFLIGHT_OK') { throw "Unexpected DeepSeek preflight response: $($text.Trim())" }
        'DEEPSEEK_PREFLIGHT_OK'
        return
    }
    if ($UsageSidecarPath) {
        # prompt_tokens = cache hit + cache miss; report all of it and price all of it at the miss rate (an upper bound).
        $in = [long]$response.usage.prompt_tokens
        $out = [long]$response.usage.completion_tokens
        $cost = Get-RegistryCost $Model $in $out
        @{ vendor = 'deepseek'; model = $Model; inputTokens = $in; outputTokens = $out; costUsd = ($cost ?? 0.0); costUnknown = ($null -eq $cost); costEstimated = ($null -ne $cost); billingRoute = 'api' } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $UsageSidecarPath -Encoding utf8 -NoNewline
    }
    if ($OutPath) { Set-Content -LiteralPath $OutPath -Value $text.TrimEnd() -Encoding utf8 } else { $text.TrimEnd() }
} finally {
    $key = $null
    $secureKey.Dispose()
}
