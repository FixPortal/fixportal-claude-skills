#Requires -Version 7
<#
.SYNOPSIS
    OpenAI reviewer for the adversarial-review skill, via the Codex CLI
    (subscription-backed through a ChatGPT login).

.DESCRIPTION
    Runs `codex exec` headless so a GPT model can act as a panel reviewer through
    the SAME subprocess contract as the other wrappers (claude-review.ps1,
    kimi-review.ps1, gemini-review.ps1, openai-review.ps1). This is the
    subscription-backed OpenAI path: Codex authenticates via the user's ChatGPT
    Pro account (`codex login` -> "Logged in using ChatGPT"), so it draws on the
    flat-rate subscription rather than metered API credits. openai-review.ps1
    (direct Chat Completions API) is retained as the fallback for when no
    subscription is available.

    The call is constrained to read-only analysis: `--sandbox read-only` blocks
    all writes, `--skip-git-repo-check` lets it run from a throwaway working
    directory (so the repo's own AGENTS.md / config does not bias the review),
    and it is non-interactive (`codex exec` never prompts). With -RepoPath the
    working directory is the repo instead, so a repo-aware review can read
    surrounding context the diff omits (still read-only); without it the review
    is fully inlined and repo-blind like the diff-only reviewers.

    Inputs are inlined into the prompt and delivered on stdin -- deterministic,
    no command-line length limit, symmetric with the other wrappers.

    Used for Phase 1 (blind review, -DiffPath) and Phase 2 (cross-examination,
    -DiffPath and -FindingsPath). Either phase may also pass -ContextPath.

    Requires: the `codex` CLI on PATH, logged in via ChatGPT (`codex login`).

.PARAMETER Model
    Optional. Codex model id (e.g. gpt-5-codex). Codex model ids differ from the
    Chat Completions API ids, so by default this is passed through only when it
    looks codex-native; otherwise Codex's configured default model is used (the
    best model the ChatGPT subscription serves). The value is still recorded for
    telemetry so the dashboard groups the OpenAI vote consistently.

.OUTPUTS
    The model's review text on stdout (or -OutPath). Non-zero exit on failure.
#>
[CmdletBinding()]
param(
    [string] $Instruction,
    [string] $InstructionPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DiffPath,

    [string] $FindingsPath,
    [string[]] $ContextPath,

    [string] $Model,

    # Optional read-only repository root. When set, the review is repo-aware
    # (Codex may read files the diff omits); when omitted, it is diff-blind.
    [string] $RepoPath,

    [string] $Effort,           # accepted for contract symmetry; codex exec has no clean effort flag

    [string] $OutPath,
    [string] $UsageSidecarPath
)

$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Error 'codex CLI not found on PATH. Install Codex and run `codex login` (ChatGPT), or use openai-review.ps1 (API) as the fallback.'
    exit 2
}

function Read-InputFile([string] $path, [string] $label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "$label not found: $path"; exit 2
    }
    Get-Content -LiteralPath $path -Raw
}

if ($InstructionPath) { $Instruction = Read-InputFile $InstructionPath 'Instruction file' }
if ([string]::IsNullOrWhiteSpace($Instruction)) {
    Write-Error 'Provide the review instruction via -Instruction or -InstructionPath.'; exit 2
}

# --- Compose the prompt (symmetric with openai-review.ps1) -------------------
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine($Instruction)
[void]$sb.AppendLine()
[void]$sb.AppendLine('STYLE REQUIREMENT: Terse output only. No preamble, no summary, no closing remarks. Per finding: severity + location + one-sentence description + one-sentence fix. Skip any finding you cannot substantiate.')
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
    [void]$sb.AppendLine('Supporting repo files the diff refers to but does not contain. Use them to judge whether a defect is real. Do NOT raise findings against these files.')
    foreach ($path in $contextPaths) {
        $resolved = (Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue)?.Path ?? $path
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("### $resolved")
        [void]$sb.AppendLine((Read-InputFile $path 'Context file'))
    }
}
$prompt = $sb.ToString()

# --- Working directory: repo root (repo-aware) or throwaway scratch (blind) ---
# $scratchToClean is set ONLY for the scratch case, so the finally block removes
# the throwaway dir without ever touching a caller-supplied -RepoPath. A -RepoPath
# that is supplied but not a real directory is an error, not a silent fallthrough
# to blind mode (which would hide a mistyped path).
$scratchToClean = $null
$lastMsg = $null
if ($RepoPath) {
    if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
        Write-Error "RepoPath is not an existing directory: $RepoPath"; exit 2
    }
    $workDir = (Resolve-Path -LiteralPath $RepoPath).Path
} else {
    $scratchToClean = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-review-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $scratchToClean | Out-Null
    $workDir = $scratchToClean
}
try {

$lastMsg  = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + '.txt')

# Pass -m only when the model id looks codex-native (codex ids differ from the
# Chat Completions API ids that reviewers.json carries for the fallback wrapper).
$codexArgs = @('exec', '--sandbox', 'read-only', '--skip-git-repo-check',
               '--color', 'never', '-C', $workDir, '-o', $lastMsg, '--json')
if ($Model -and ($Model -match '^(gpt-5|o3|o4|codex)')) { $codexArgs += @('-m', $Model) }

# --- Invoke, with a couple of retries on transient CLI failure --------------
$maxAttempts = 3
$jsonl = $null
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $jsonl = $prompt | & codex @codexArgs 2>&1
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $lastMsg)) { break }
    if ($attempt -eq $maxAttempts) {
        Write-Error ("codex exec failed after $attempt attempt(s) (exit $LASTEXITCODE).`n" + ($jsonl | Out-String))
        exit 1
    }
    Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
}

$text = (Get-Content -LiteralPath $lastMsg -Raw -ErrorAction SilentlyContinue)
if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Error 'codex returned an empty review.'; exit 1
}

# --- Usage: parse the turn.completed event from the JSONL stream ------------
# codex --json emits one JSON object per line; the final turn.completed carries
# usage { input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens }.
$inTok = 0L; $outTok = 0L; $reasoning = 0L
foreach ($line in @($jsonl)) {
    $s = [string]$line
    if ($s -notmatch '"turn\.completed"') { continue }
    try {
        $evt = $s | ConvertFrom-Json -ErrorAction Stop
        if ($evt.usage) {
            $cached    = [long]($evt.usage.cached_input_tokens ?? 0)
            $inTok     = [Math]::Max(0L, [long]($evt.usage.input_tokens ?? 0) - $cached)
            $outTok    = [long]($evt.usage.output_tokens ?? 0)
            $reasoning = [long]($evt.usage.reasoning_output_tokens ?? 0)
        }
    } catch {}
}

# Putative cost only (subscription is flat-rate; per-token spend is ~0). Keyed on
# the recorded model where known, else 0. USD per million tokens: @(input, output).
$pricing = @{
    'gpt-5-codex'  = @( 5.00, 30.00)
    'gpt-5.6-sol'  = @( 5.00, 30.00)
    'gpt-5.6-terra'= @( 2.50, 15.00)
    'gpt-5.6-luna' = @( 1.00,  6.00)
    'gpt-5.5'      = @( 5.00, 30.00)
}
function Get-PutativeCost([long] $i, [long] $o) {
    $key = ($pricing.Keys | Where-Object { $Model -and $Model.StartsWith($_) } | Sort-Object Length -Descending | Select-Object -First 1)
    $r = $key ? $pricing[$key] : @(0.0, 0.0)
    [Math]::Round((($i * $r[0]) + ($o * $r[1])) / 1000000.0, 8)
}
$cost = Get-PutativeCost $inTok $outTok

if ($UsageSidecarPath) {
    @{ inputTokens = $inTok; outputTokens = $outTok; costUsd = $cost } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $UsageSidecarPath -Encoding utf8 -NoNewline
}

# --- Observatory per-call telemetry (fire-and-forget) -----------------------
# Vendor stays OpenAI (Codex is the OpenAI vote); cost is putative under the sub.
if ($env:OBSERVATORY_API_KEY -and ($inTok -gt 0 -or $outTok -gt 0)) {
    $observatoryUrl = $env:OBSERVATORY_URL ?? 'https://fpaiobs-api.azurewebsites.net'
    $sessionId = [Guid]::NewGuid().ToString()
    $obsBody = @{
        provider         = 'OpenAI'
        model            = ($Model ? $Model : 'codex-default')
        inputTokens      = $inTok
        outputTokens     = $outTok
        cacheWriteTokens = $reasoning
        costUsd          = $cost
        eventKey         = "codex:$sessionId`:$($Model ? $Model : 'default')"
        rawPayload       = (@{ source = 'codex-review'; session = $sessionId; role = 'adversarial-review reviewer'; billing = 'subscription' } | ConvertTo-Json -Compress)
    } | ConvertTo-Json -Compress
    $obsReq = @{
        Uri         = "$observatoryUrl/api/events"
        Method      = 'Post'
        ContentType = 'application/json'
        Headers     = @{ 'X-Observatory-Key' = $env:OBSERVATORY_API_KEY }
        Body        = $obsBody
        TimeoutSec  = 5
        ErrorAction = 'SilentlyContinue'
    }
    try { Invoke-RestMethod @obsReq | Out-Null } catch {}
}

if ($OutPath) {
    try { $text.TrimEnd() | Set-Content -LiteralPath $OutPath -Encoding utf8 -ErrorAction Stop }
    catch { Write-Error "Failed to write review output to '$OutPath': $($_.Exception.Message)"; exit 1 }
} else {
    $text.TrimEnd()
}
}
finally {
    # Always remove the temp last-message file (even on retry exhaustion / empty
    # review), and the throwaway scratch dir we created (never a caller -RepoPath).
    if ($lastMsg) { Remove-Item -LiteralPath $lastMsg -ErrorAction SilentlyContinue }
    if ($scratchToClean) { Remove-Item -LiteralPath $scratchToClean -Recurse -Force -ErrorAction SilentlyContinue }
}
