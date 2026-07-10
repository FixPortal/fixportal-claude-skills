#Requires -Version 7
<#
.SYNOPSIS
    OpenAI reviewer for the adversarial-review skill (direct Chat Completions API).

.DESCRIPTION
    Posts to the OpenAI Chat Completions endpoint so a GPT model can act as an
    independent cross-vendor code reviewer -- a direct-API alternative to
    external-review.ps1, which routes through the GitHub Copilot CLI.

    Inputs are inlined into the user message, symmetric with gemini-review.ps1.
    No CLI dependency; no file-tool surface. The API response contains usage
    directly, so Observatory telemetry is posted inline rather than swept
    post-hoc from Copilot session state.

    Used by ~/.claude/skills/adversarial-review for Phase 1 (blind review,
    -DiffPath) and Phase 2 (cross-examination, -DiffPath and -FindingsPath).
    Either phase may also pass -ContextPath to supply repo files the diff
    depends on but does not contain, since this reviewer is repo-blind.

    Requires:
      $env:OPENAI_API_KEY  -- an OpenAI API key with Chat Completions access.

.PARAMETER Instruction
    The review or cross-examination instruction (the brief). Typically supplied
    as (Get-Content brief.txt -Raw).

.PARAMETER DiffPath
    Path to the diff file under review. Inlined into the user message.

.PARAMETER FindingsPath
    Optional. Path to the pooled-findings file -- supplied in the Phase 2
    cross-examination round, omitted in Phase 1. Inlined into the user message.

.PARAMETER ContextPath
    Optional. One or more repository files supplied as read-only BACKGROUND --
    interfaces, contracts, and callers the diff refers to but does not contain.
    Inlined into the user message, clearly labelled as not-under-review.

.PARAMETER Model
    OpenAI model id for the Chat Completions API. Note: Copilot-internal aliases
    (e.g. gpt-5.4) may differ from the canonical API model id -- verify against
    https://api.openai.com/v1/models before setting.

.PARAMETER UsageSidecarPath
    Optional. When set, the script writes a JSON sidecar with the API usage
    (inputTokens, outputTokens, costUsd) so the host agent can pass accurate
    metrics to emit-review-telemetry.ps1 rather than defaulting to zero.
    Pass only for Phase 1 (the blind review call).

.OUTPUTS
    The model's review text on stdout. Non-zero exit code on failure.

.EXAMPLE
    pwsh -NoProfile -File openai-review.ps1 `
        -Instruction (Get-Content brief.txt -Raw) `
        -DiffPath review-diff.txt -Model gpt-4o
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Instruction,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DiffPath,

    [string] $FindingsPath,

    [string[]] $ContextPath,

    [string] $Model = 'gpt-4o',

    # Optional. When set, the script writes a JSON sidecar with the API usage
    # (inputTokens, outputTokens, costUsd) so the host agent can pass accurate
    # metrics to emit-review-telemetry.ps1 rather than defaulting to zero.
    [string] $UsageSidecarPath
)

$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not $env:OPENAI_API_KEY) {
    Write-Error 'OPENAI_API_KEY environment variable not set. Obtain a key at https://platform.openai.com/api-keys'
    exit 2
}

function Read-InputFile([string] $path, [string] $label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "$label not found: $path"
        exit 2
    }
    Get-Content -LiteralPath $path -Raw
}

# Compose the full prompt inline -- same pattern as gemini-review.ps1.
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine($Instruction)
[void]$sb.AppendLine()
[void]$sb.AppendLine('STYLE REQUIREMENT: Terse output only. No preamble, no summary, no closing remarks. Per finding: severity + location + one-sentence description + one-sentence fix. Skip any finding you cannot substantiate from the diff.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('--- DIFF UNDER REVIEW ---')
[void]$sb.AppendLine((Read-InputFile $DiffPath 'Diff file'))

if ($FindingsPath) {
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('--- POOLED FINDINGS (attribution removed) ---')
    [void]$sb.AppendLine((Read-InputFile $FindingsPath 'Findings file'))
}

$contextPaths = @($ContextPath | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($contextPaths) {
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('--- REPO CONTEXT (read-only background, NOT under review) ---')
    [void]$sb.AppendLine('The following are supporting repo files: interfaces, contracts, and')
    [void]$sb.AppendLine('callers the diff refers to but does not contain. Use them to judge whether')
    [void]$sb.AppendLine('a defect is real. Do NOT raise findings against these files.')
    foreach ($path in $contextPaths) {
        $resolved = (Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue)?.Path ?? $path
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("### $resolved")
        [void]$sb.AppendLine((Read-InputFile $path 'Context file'))
    }
}

$userMessage = $sb.ToString()

# --- Call the OpenAI Chat Completions API -----------------------------------
# No system message -- keeps this symmetric with the other wrappers and avoids
# compatibility issues with reasoning models (o1/o3/o4-mini) that restrict or
# ignore system-role content.
$requestBody = @{
    model    = $Model
    messages = @(
        @{ role = 'user'; content = $userMessage }
    )
} | ConvertTo-Json -Depth 10 -Compress

try {
    $response = Invoke-RestMethod `
        -Uri 'https://api.openai.com/v1/chat/completions' `
        -Method Post `
        -ContentType 'application/json; charset=utf-8' `
        -Headers @{ 'Authorization' = "Bearer $env:OPENAI_API_KEY" } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($requestBody)) `
        -TimeoutSec 300
}
catch {
    $statusCode = $_.Exception.Response?.StatusCode.value__
    $detail = ''
    try { $detail = $_.ErrorDetails.Message } catch {}
    Write-Error ("OpenAI API call failed (HTTP $statusCode): $($_.Exception.Message)`n$detail")
    exit 1
}

$text = $response.choices[0].message.content
if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Error "OpenAI returned an empty response. Finish reason: $($response.choices[0].finish_reason)"
    exit 1
}

# --- Pricing table (shared by Observatory telemetry and usage sidecar) ------
# USD per million tokens: @(input, output).
# Update when new models ship or pricing changes.
$openAiPricing = @{
    'gpt-4o'       = @( 2.50, 10.00)
    'gpt-4o-mini'  = @( 0.15,  0.60)
    'o1'           = @(15.00, 60.00)
    'o1-mini'      = @( 1.10,  4.40)
    'o3'           = @(10.00, 40.00)
    'o3-mini'      = @( 1.10,  4.40)
    'o4-mini'      = @( 1.10,  4.40)
    'gpt-5.4'      = @( 2.50, 15.00)
    'gpt-5.4-mini' = @( 0.75,  4.50)
    'gpt-5.5'      = @( 5.00, 30.00)
    'gpt-5.6-luna' = @( 1.00,  6.00)
    'gpt-5.6-terra'= @( 2.50, 15.00)
    'gpt-5.6-sol'  = @( 5.00, 30.00)
}

function Get-OpenAiCost([long] $inTok, [long] $outTok) {
    $rateKey = ($openAiPricing.Keys |
        Where-Object { $Model.StartsWith($_) } |
        Sort-Object Length -Descending |
        Select-Object -First 1)
    $rates = $rateKey ? $openAiPricing[$rateKey] : @(0.00, 0.00)
    [Math]::Round((($inTok * $rates[0]) + ($outTok * $rates[1])) / 1000000.0, 8)
}

# --- Usage sidecar (for outcome telemetry) ----------------------------------
# Write accurate token + cost figures so the host agent can pass real values to
# emit-review-telemetry.ps1 instead of zeros. Bypasses the Observatory guard so
# these figures are captured even without Observatory credentials.
if ($UsageSidecarPath -and $response.usage) {
    $usage   = $response.usage
    $cached  = [long]($usage.prompt_tokens_details?.cached_tokens ?? 0)
    $inTok   = [Math]::Max(0L, [long]($usage.prompt_tokens ?? 0) - $cached)
    $outTok  = [long]($usage.completion_tokens ?? 0)
    @{ inputTokens = $inTok; outputTokens = $outTok; costUsd = (Get-OpenAiCost $inTok $outTok) } |
        ConvertTo-Json -Compress |
        Set-Content -LiteralPath $UsageSidecarPath -Encoding utf8 -NoNewline
}

# --- Observatory telemetry (fire-and-forget) --------------------------------
# Usage is in the response body directly -- no post-hoc session-state sweep.
# Reasoning tokens (o1/o3/o4) are stored in cacheWriteTokens by convention,
# matching the Gemini wrapper's treatment of thinking tokens.
if ($env:OBSERVATORY_API_KEY -and $env:OBSERVATORY_URL -and $response.usage) {
    $observatoryUrl = $env:OBSERVATORY_URL
    $sessionId      = [Guid]::NewGuid().ToString()
    $usage          = $response.usage

    $cached    = [long]($usage.prompt_tokens_details?.cached_tokens ?? 0)
    $inTok     = [Math]::Max(0L, [long]($usage.prompt_tokens ?? 0) - $cached)
    $outTok    = [long]($usage.completion_tokens ?? 0)
    $reasoning = [long]($usage.completion_tokens_details?.reasoning_tokens ?? 0)

    if ($inTok -gt 0 -or $outTok -gt 0) {
        $obsBody = @{
            provider         = 'OpenAI'
            model            = $Model
            inputTokens      = $inTok
            outputTokens     = $outTok
            cacheReadTokens  = $cached
            cacheWriteTokens = $reasoning
            costUsd          = (Get-OpenAiCost $inTok $outTok)
            eventKey         = "openai:$sessionId`:$Model"
            rawPayload       = (@{
                source  = 'openai-review'
                session = $sessionId
                role    = 'adversarial-review external reviewer'
            } | ConvertTo-Json -Compress)
        } | ConvertTo-Json -Compress

        try {
            Invoke-RestMethod `
                -Uri "$observatoryUrl/api/events" `
                -Method Post `
                -ContentType 'application/json' `
                -Headers @{ 'X-Observatory-Key' = $env:OBSERVATORY_API_KEY } `
                -Body $obsBody `
                -TimeoutSec 5 `
                -ErrorAction SilentlyContinue | Out-Null
        } catch { }
    }
}

$text.TrimEnd()
