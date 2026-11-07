#Requires -Version 7
<#
.SYNOPSIS
    Moonshot reviewer for the adversarial-review skill (metered Kimi API, Chat Completions).
.DESCRIPTION
    Hermetic by construction: a single HTTPS call with every input inlined into the user
    message. No CLI, no tools, no repository access, no working-directory surface. Phase 1
    (-DiffPath) and Phase 2 (-DiffPath + -FindingsPath) are supported; -ContextPath supplies
    repo files as read-only background because this reviewer is repo-blind.
    This is the API route. kimi-review.ps1 is the subscription route and is retired; the two
    do not share credentials, billing or telemetry.
.NOTES
    PREFLIGHT_COMMAND: pwsh -NoProfile -File ~/.agents/skills/adversarial-review/moonshot-review.ps1 -Preflight -Model kimi-k3.1-pro
    PREFLIGHT_SUCCESS: exit 0 and stdout is MOONSHOT_PREFLIGHT_OK (authenticated model response from the requested model).
    Windows credential: run the one-off script that prompts with Read-Host -AsSecureString and Export-Clixml to "$env:LOCALAPPDATA/YourOrg/moonshot-api/moonshot-key.clixml" (DPAPI, this account and machine only).
    The model id is passed through verbatim and the response's own model field must equal it;
    there is deliberately no release-shaped pattern guard (model-routing-traps.md trap 10).
    Metered: billed per token against the account's balance. K3.1 Pro always reasons; reasoning
    tokens bill as output, and -Effort maps to the top-level reasoning_effort field (low|high|max).
#>
[CmdletBinding(DefaultParameterSetName='Review')]
param(
    [Parameter(Mandatory, ParameterSetName='Review')][string] $Instruction,
    [Parameter(Mandatory, ParameterSetName='Review')][string] $DiffPath,
    [string] $FindingsPath,
    [string[]] $ContextPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Model,
    [string] $Effort,
    [string] $OutPath,
    [string] $UsageSidecarPath,
    [Parameter(Mandatory, ParameterSetName='Preflight')][switch] $Preflight,
    [ValidateRange(30,2700)][int] $TimeoutSeconds = 2400
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$BaseUrl = 'https://api.moonshot.ai/v1'

function ConvertTo-MoonshotReasoningEffort([string]$Effort) {
    switch -Regex ($Effort) {
        '^(low|minimal)$' { 'low'; break }
        '^(max|xhigh)$' { 'max'; break }
        default { 'high' }
    }
}

function New-MoonshotRequestBody([string]$Model, [string]$Prompt, [string]$Effort) {
    # No system message and no tools, symmetric with the other metered wrapper. temperature, top_p, n and the
    # penalties are fixed server-side for K3.x and must be omitted. max_completion_tokens covers the reasoning
    # tokens as well as the answer; 131072 is the documented default, set explicitly so a truncation is ours.
    @{
        model                 = $Model
        messages              = @(@{ role = 'user'; content = $Prompt })
        reasoning_effort      = (ConvertTo-MoonshotReasoningEffort $Effort)
        max_completion_tokens = 131072
        stream                = $false
    } | ConvertTo-Json -Depth 6 -Compress
}

function Read-MoonshotResponse($Response, [string]$Model) {
    if ($Response.model -cne $Model) { throw "Moonshot response model '$($Response.model)' differs from the requested '$Model'." }
    $choice = @($Response.choices)[0]
    if ($null -eq $choice -or $choice.finish_reason -ne 'stop') { throw "Moonshot did not return a complete response (finish_reason: $($choice.finish_reason))." }
    if ([string]::IsNullOrWhiteSpace($choice.message.content)) { throw 'Moonshot returned an empty response.' }
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
if (-not $IsWindows) { throw 'Moonshot credential uses Windows DPAPI; configure this reviewer only on its Windows host.' }

$prompt = if ($Preflight) { 'Reply exactly MOONSHOT_PREFLIGHT_OK.' } else {
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

$credentialPath = Join-Path $env:LOCALAPPDATA 'YourOrg/moonshot-api/moonshot-key.clixml'
$secureKey = Import-Clixml -LiteralPath $credentialPath
if ($secureKey -isnot [Security.SecureString]) { throw 'Expected a DPAPI-encrypted SecureString credential.' }
$key = [Net.NetworkCredential]::new('', $secureKey).Password
if ([string]::IsNullOrWhiteSpace($key)) { throw 'Empty Moonshot credential.' }

try {
    $effortForRequest = if ($Preflight) { 'low' } else { $Effort }
    $body = [Text.Encoding]::UTF8.GetBytes((New-MoonshotRequestBody $Model $prompt $effortForRequest))
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
                throw "Moonshot API call failed ($($null -eq $status ? 'no HTTP response' : "HTTP $status")) after $attempt attempt(s): $detail"
            }
            Start-Sleep -Seconds $backoff
        }
    }
    $text = Read-MoonshotResponse $response $Model
    if ($Preflight) {
        if (($text.Trim() -replace '\.$', '') -ne 'MOONSHOT_PREFLIGHT_OK') { throw "Unexpected Moonshot preflight response: $($text.Trim())" }
        'MOONSHOT_PREFLIGHT_OK'
        return
    }
    if ($UsageSidecarPath) {
        # prompt_tokens includes any cached prefix; report all of it and price all of it at the miss rate (an upper bound).
        $in = [long]$response.usage.prompt_tokens
        $out = [long]$response.usage.completion_tokens
        $cost = Get-RegistryCost $Model $in $out
        @{ vendor = 'moonshot'; model = $Model; inputTokens = $in; outputTokens = $out; costUsd = ($cost ?? 0.0); costUnknown = ($null -eq $cost); costEstimated = ($null -ne $cost); billingRoute = 'api' } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $UsageSidecarPath -Encoding utf8 -NoNewline
    }
    if ($OutPath) { Set-Content -LiteralPath $OutPath -Value $text.TrimEnd() -Encoding utf8 } else { $text.TrimEnd() }
} finally {
    $key = $null
    $secureKey.Dispose()
}
