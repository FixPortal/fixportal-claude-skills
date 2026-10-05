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

    Used by ~/.agents/skills/adversarial-review for Phase 1 (blind review,
    -DiffPath) and Phase 2 (cross-examination, -DiffPath and -FindingsPath).
    Either phase may also pass -ContextPath to supply repo files the diff
    depends on but does not contain, since this reviewer is repo-blind.

    Requires:
      $env:OPENAI_API_KEY  -- an OpenAI API key with Chat Completions access.
    Optional:
      $env:OPENAI_BASE_URL -- override the API base URL (default
                              https://api.openai.com/v1), e.g. an API-compatible
                              gateway. Must be https://; plain http is refused.

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
    OpenAI model id for the Chat Completions API. Mandatory, no default --
    resolve one through model-registry (resolve.py --tier <tier> --vendor openai
    --channel api) rather than leaning on a pinned id here. Note:
    Copilot-internal aliases (e.g. gpt-5.4) may differ from the canonical API
    model id -- verify against https://api.openai.com/v1/models before setting.

.NOTES
    PREFLIGHT_COMMAND: pwsh -NoProfile -Command 'exit [int][string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)'
    PREFLIGHT_SUCCESS: exit 0. The command prints no credential value.

    The inner command MUST stay single-quoted. Double-quoted, the INVOKING shell
    expands $env:OPENAI_API_KEY before the child ever runs, so with a key set the
    child receives `IsNullOrWhiteSpace(sk-...)` -- a ParserError, with the literal
    key on the child's command line and therefore in process listings -- and with
    no key set it fails overload resolution. Both states exit non-zero, so the only
    declared OpenAI fallback was permanently reported unavailable, and it leaked the
    credential in exactly the case where one was present. Observed on 2026-08-08:
    double-quoted with a key set gives `ParserError ... IsNullOrWhiteSpace(sk-...)`;
    single-quoted gives exit 0 with a key and exit 1 without.

.OUTPUTS
    The model's review text on stdout. Non-zero exit code on failure.

.EXAMPLE
    pwsh -NoProfile -File openai-review.ps1 -InstructionPath brief.txt -DiffPath review-diff.txt -Model gpt-5.5
#>
[CmdletBinding()]
param(
    # Instruction text. Either pass it inline (-Instruction) or, to keep the
    # calling command free of shell command-substitution (which defeats a static
    # allowlist rule and drops the call to the auto-mode classifier), point
    # -InstructionPath at a file and the script reads it.
    [string] $Instruction,

    [string] $InstructionPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DiffPath,

    [string] $FindingsPath,

    [string[]] $ContextPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Model,

    # Optional. When set, the review text is written here instead of stdout, so
    # the calling command needs no '> file' redirect (redirects, like inline
    # substitutions, make a command "complex" and bypass static allowlist rules).
    [string] $OutPath,

    # Optional. When set, the script writes a JSON sidecar with the API usage
    # (inputTokens, outputTokens, costUsd, costUnknown) so the host agent can pass
    # measured usage without presenting an absent registry price as zero.
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

# Resolve the instruction: -InstructionPath (file) takes precedence over inline
# -Instruction. Exactly one source is required.
if ($InstructionPath) {
    $Instruction = Read-InputFile $InstructionPath 'Instruction file'
}
if ([string]::IsNullOrWhiteSpace($Instruction)) {
    Write-Error 'Provide the review instruction via -Instruction or -InstructionPath.'
    exit 2
}

# Compose the full prompt inline -- same pattern as gemini-review.ps1.
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine($Instruction)
[void]$sb.AppendLine()
if (-not $FindingsPath) {
    # Phase-1 style directive only: in Phase 2 (-FindingsPath) the brief owns the
    # verdict format, and a per-finding directive appended AFTER it contradicts it.
    [void]$sb.AppendLine('STYLE REQUIREMENT: Terse output only. No preamble, no summary, no closing remarks. Per finding: severity + location + one-sentence description + one-sentence fix. Skip any finding you cannot substantiate from the diff.')
    [void]$sb.AppendLine()
}
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

# Transient failures here silently cost the panel an entire vendor for the whole
# chunk: the caller records "[reviewer unavailable]" and the run reads as a valid
# 2-vendor degrade. Observed 401 "insufficient permissions" firing intermittently
# on payloads that succeed unchanged on retry -- bisected: an identical 62,822-byte
# diff failed twice, then succeeded at 14,577 prompt tokens, while a smaller 15k
# slice failed. Not size-related, not deterministic. So retry the retryable codes
# before giving up. 401 is included deliberately: it is normally an auth error
# (and a real one still fails after the retries), but this account also emits it
# spuriously under load.
$retryableStatus = @(401, 408, 429, 500, 502, 503, 504)
$maxAttempts = 4
$response = $null

# Endpoint override for API-compatible gateways; defaults to the public endpoint. The
# key rides the Authorization header on EVERY request below, so anything but an
# absolute https:// URI is refused before a request is attempted.
$openAiBaseUrl = [string]::IsNullOrWhiteSpace($env:OPENAI_BASE_URL) ? 'https://api.openai.com/v1' : $env:OPENAI_BASE_URL.TrimEnd('/')
$openAiBaseUri = $null
if (-not [System.Uri]::TryCreate($openAiBaseUrl, [System.UriKind]::Absolute, [ref] $openAiBaseUri) -or
    $openAiBaseUri.Scheme -ne 'https') {
    Write-Error ("OPENAI_BASE_URL must be an absolute https:// URI (got '$openAiBaseUrl'); " +
        'the API key is sent on every request, so plain HTTP would expose it.')
    exit 1
}

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        $response = Invoke-RestMethod `
            -Uri "$openAiBaseUrl/chat/completions" `
            -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Headers @{ 'Authorization' = "Bearer $env:OPENAI_API_KEY" } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($requestBody)) `
            -TimeoutSec 300
        break
    }
    catch {
        $statusCode = $_.Exception.Response?.StatusCode.value__
        $detail = ''
        try { $detail = $_.ErrorDetails.Message } catch {}

        # A null status code means no HTTP response arrived at all — a timeout
        # (past -TimeoutSec), DNS failure, or connection reset. Those are the most
        # common transient failures of the lot, so they must retry too; keying the
        # decision on the status code alone would exclude exactly the class this
        # retry exists for.
        $isRetryable = ($null -eq $statusCode) -or ($retryableStatus -contains $statusCode)
        if (-not $isRetryable -or $attempt -eq $maxAttempts) {
            $where = if ($null -eq $statusCode) { 'no HTTP response' } else { "HTTP $statusCode" }
            Write-Error ("OpenAI API call failed ($where) after $attempt attempt(s): $($_.Exception.Message)`n$detail")
            exit 1
        }

        # Exponential backoff with jitter, so concurrent chunks do not retry in lockstep.
        $backoff = [Math]::Pow(2, $attempt) + (Get-Random -Minimum 0.0 -Maximum 1.0)
        $what = if ($null -eq $statusCode) { 'no HTTP response' } else { "HTTP $statusCode" }
        Write-Warning ("OpenAI $what (attempt $attempt/$maxAttempts) — retrying in $([Math]::Round($backoff,1))s")
        Start-Sleep -Seconds $backoff
    }
}

if (-not $response) {
    Write-Error 'OpenAI API call failed: no response after retries.'
    exit 1
}

$text = $response.choices[0].message.content
if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Error "OpenAI returned an empty response. Finish reason: $($response.choices[0].finish_reason)"
    exit 1
}

# --- Canonical registry pricing (shared by telemetry and usage sidecar) -----
function Get-RegistryCost([long] $inTok, [long] $outTok) {
    $registryPath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'model-registry') 'registry.json'
    $priceHelper = Join-Path (Split-Path $registryPath -Parent) 'price.ps1'
    if (-not (Test-Path -LiteralPath $registryPath)) { return $null }
    if (-not (Test-Path -LiteralPath $priceHelper)) { return $null }
    . $priceHelper
    try { $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -AsHashtable }
    catch { return $null }
    if (-not $registry.models.ContainsKey($Model)) { return $null }
    $facts = $registry.models[$Model]
    $on = $env:MODEL_REGISTRY_EFFECTIVE_DATE ?? (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    # Guarded: Get-ModelRegistryCost throws on overlapping api pricing records, and only
    # ConvertFrom-Json sat inside a try. A registry DATA error must degrade to UNKNOWN,
    # not fail a wrapper whose model call has already completed and been paid for.
    try {
        $cost = Get-ModelRegistryCost -Facts $facts -InputTokens $inTok -OutputTokens $outTok -Channel api -On $on
    }
    catch {
        Write-Warning "Registry pricing for '$Model' is unusable ($($_.Exception.Message)); cost recorded as UNKNOWN."
        return $null
    }
    if ($null -ne $cost) { [Math]::Round($cost, 8) }
}

$usage      = $response.usage
$cached     = [long]($usage.prompt_tokens_details?.cached_tokens ?? 0)
$inTok      = [Math]::Max(0L, [long]($usage.prompt_tokens ?? 0) - $cached)
$outTok     = [long]($usage.completion_tokens ?? 0)
$reasoning  = [long]($usage.completion_tokens_details?.reasoning_tokens ?? 0)
$cost       = Get-RegistryCost $inTok $outTok
$costUnknown = $null -eq $cost
if ($costUnknown) { $cost = 0.0 }

# --- Usage sidecar (for outcome telemetry) ----------------------------------
# Write measured tokens plus registry-derived cost state. Bypasses the Observatory
# guard so these figures are captured even without Observatory credentials.
if ($UsageSidecarPath -and $response.usage) {
    @{ inputTokens = $inTok; outputTokens = $outTok; costUsd = $cost; costUnknown = $costUnknown } |
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
    if ($inTok -gt 0 -or $outTok -gt 0) {
        $obsBody = @{
            provider         = 'OpenAI'
            model            = $Model
            inputTokens      = $inTok
            outputTokens     = $outTok
            cacheReadTokens  = $cached
            cacheWriteTokens = $reasoning
            costUsd          = $cost
            eventKey         = "openai:$sessionId`:$Model"
            rawPayload       = (@{
                source  = 'openai-review'
                session = $sessionId
                role    = 'adversarial-review external reviewer'
                costUnknown = $costUnknown
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

if ($OutPath) {
    try {
        $text.TrimEnd() | Set-Content -LiteralPath $OutPath -Encoding utf8 -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to write review output to '$OutPath': $($_.Exception.Message)"
        exit 1
    }
} else {
    $text.TrimEnd()
}
