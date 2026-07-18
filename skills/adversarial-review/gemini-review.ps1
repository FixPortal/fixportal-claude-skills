#Requires -Version 7
<#
.SYNOPSIS
    Standalone Gemini reviewer for the adversarial-review skill.

.DESCRIPTION
    Runs the Google Gemini CLI headless so a Google model can act as an
    independent cross-vendor code reviewer -- a sibling to external-review.ps1
    (which routes a non-Claude model through GitHub Copilot). This wrapper does
    NOT go through Copilot: it calls `gemini` directly, so it draws on the
    user's Google/Gemini quota rather than the Copilot premium-request
    allowance.

    The call is constrained to read-only analysis: `--approval-mode plan` puts
    the CLI in read-only mode (no edit/execute tools), and it runs from a
    throwaway working directory so the repository's own GEMINI.md / project
    context does not bias the review. Rather than have the model read files with
    a tool, the inputs are inlined into the prompt and delivered on stdin --
    fully deterministic, no file-access surface.

    Used by ~/.claude/skills/adversarial-review for Phase 1 (blind review,
    -DiffPath) and Phase 2 (cross-examination, -DiffPath and -FindingsPath).
    Either phase may also pass -ContextPath to supply repo files the diff
    depends on but does not contain.

.PARAMETER Instruction
    The review or cross-examination instruction (the brief). Typically supplied
    as (Get-Content brief.txt -Raw).

.PARAMETER DiffPath
    Path to the diff file under review. Inlined into the prompt.

.PARAMETER FindingsPath
    Optional. Path to the pooled-findings file -- supplied in the Phase 2
    cross-examination round, omitted in Phase 1. Inlined into the prompt.

.PARAMETER ContextPath
    Optional. One or more repository files supplied as read-only BACKGROUND --
    interfaces, contracts, and callers the diff refers to but does not contain.
    Inlined into the prompt, clearly labelled as not-under-review.

.PARAMETER Model
    Gemini model id. Defaults to the CLI's current top model. Override to pin a
    different Gemini model. Must remain a Google model -- the point of this
    wrapper is cross-vendor diversity in the panel.

.OUTPUTS
    The model's review text on stdout. Non-zero exit code on failure.

.EXAMPLE
    pwsh -NoProfile -File gemini-review.ps1 `
        -Instruction (Get-Content brief.txt -Raw) `
        -DiffPath review-diff.txt
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

    [string] $Model = 'gemini-2.5-pro',

    # Optional. When set, the review text is written here instead of stdout, so
    # the calling command needs no '> file' redirect (redirects, like inline
    # substitutions, make a command "complex" and bypass static allowlist rules).
    [string] $OutPath,

    # When set, write this reviewer's summed token usage + cost as JSON
    # ({inputTokens,outputTokens,costUsd}) so the host can pass exact figures to
    # emit-review-telemetry.ps1 (the adversarial-review outcome event).
    [string] $UsageSidecarPath
)

# Pipe UTF-8 to the child process so non-ASCII in diffs survives.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# Bootstrap GEMINI_API_KEY from the Windows user-scope env store if the current
# process (e.g. Claude Code) predates the key being set in the registry.
if (-not $env:GEMINI_API_KEY) {
    $storedKey = [System.Environment]::GetEnvironmentVariable('GEMINI_API_KEY', 'User')
    if ($storedKey) { $env:GEMINI_API_KEY = $storedKey }
}

if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) {
    Write-Error 'Gemini CLI not found on PATH. Install with: npm install -g @google/gemini-cli'
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

# Compose the full prompt and deliver it on stdin (dodges command-line length
# limits on large diffs; keeps the call hermetic -- no file tool needed).
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine($Instruction)
[void]$sb.AppendLine()
[void]$sb.AppendLine('STYLE REQUIREMENT: Terse output only. No preamble, no summary, no closing remarks. Per finding: severity + location + one-sentence description + one-sentence fix. Skip any finding you cannot substantiate from the diff.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('--- DIFF UNDER REVIEW ---')
[void]$sb.AppendLine((Read-InputFile $DiffPath 'Input file'))

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

$stdin = $sb.ToString()

# A short final directive (appended after stdin by the CLI). The brief at the
# top already says "output only the findings"; this just triggers the review.
$directive = 'The text above is your input. Follow the instruction at the very top and review the DIFF UNDER REVIEW. Terse output only — findings in the requested format, no preamble, no narration, no summary.'

# Run from a throwaway working directory so the repo's own GEMINI.md / project
# context cannot bias the review. --approval-mode plan = read-only.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('gem-review-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$errFile = Join-Path $scratch 'stderr.txt'

# The Gemini CLI has no cwd flag; it uses the process working directory and
# loads any GEMINI.md it finds there. Run from the throwaway dir so the repo's
# own project context cannot bias the review.
$geminiArgs = @(
    '-p', $directive
    '-m', $Model
    '--approval-mode', 'plan'
    '--skip-trust'
    '-o', 'json'
)

# Shadow OAuth creds so the CLI uses GEMINI_API_KEY (PAYG) instead of free-tier OAuth.
# When both exist the CLI prefers OAuth, which hits the free-tier daily quota rather
# than the PAYG API key. Rename-and-restore is safe: the CLI reads the file at startup,
# so concurrent interactive sessions are unaffected once already running.
$oauthCreds  = Join-Path $HOME '.gemini\oauth_creds.json'
$hiddenCreds = Join-Path $HOME '.gemini\oauth_creds.json.paused'
$movedOAuth  = $false
if ($env:GEMINI_API_KEY -and (Test-Path $oauthCreds)) {
    Rename-Item $oauthCreds $hiddenCreds
    $movedOAuth = $true
}

Push-Location -LiteralPath $scratch
try {
    $stdout = ($stdin | & gemini @geminiArgs 2>$errFile) | Out-String
    $exitCode = $LASTEXITCODE
    $stderr = (Test-Path $errFile) ? (Get-Content -LiteralPath $errFile -Raw) : ''
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    if ($movedOAuth) { Rename-Item $hiddenCreds $oauthCreds -ErrorAction SilentlyContinue }
}

if ($exitCode -ne 0) {
    Write-Error ("gemini exited with code {0}.`n{1}" -f $exitCode, $stderr)
    exit $exitCode
}

# stdout is a JSON envelope; the review text is the .response field.
try {
    $start = $stdout.IndexOf('{')
    $json = ($start -ge 0 ? $stdout.Substring($start) : $stdout) | ConvertFrom-Json
}
catch {
    Write-Error ("Could not parse gemini JSON output.`nSTDOUT:`n{0}`nSTDERR:`n{1}" -f $stdout, $stderr)
    exit 1
}

$response = $json.response
if ([string]::IsNullOrWhiteSpace($response)) {
    Write-Error ("gemini returned an empty response.`nSTDERR:`n{0}" -f $stderr)
    exit 1
}

# --- Observatory telemetry (fire-and-forget) -------------------------------
# The JSON envelope's stats block carries real per-model token usage; without
# this post, headless gemini reviews are invisible to the AI Observatory (no
# hook covers the plain gemini CLI).
# Accumulate this call's usage so it can be written to the sidecar (host reads
# it for the adversarial-review outcome event) regardless of Observatory posting.
# Computed and written OUTSIDE the `stats.models` gate below: a retry whose
# response lacks stats must overwrite a stale sidecar from the previous call
# with zeros, not leave it un-touched (the sidecar has no other invalidation).
$sumIn = 0L; $sumOut = 0L; $sumCost = 0.0

if ($json.stats?.models) {
    # USD per million tokens: input / output / thoughts (0.00 = no thinking tier)
    # Rates from https://ai.google.dev/gemini-api/docs/pricing (2025-06-19)
    # Tiered models use the ≤200k rate; thought tokens billed at rates[2].
    $gemPricing = @{
        'gemini-3.5-flash'       = @( 1.50,  9.00, 0.00)
        'gemini-3.1-pro-preview' = @( 2.00, 12.00, 0.00)
        'gemini-3.1-flash-lite'  = @( 0.25,  1.50, 0.00)
        'gemini-3-flash-preview' = @( 0.50,  3.00, 0.00)
        'gemini-2.5-pro'         = @( 1.25, 10.00, 3.50)
        'gemini-2.5-flash-lite'  = @( 0.10,  0.40, 0.00)
        'gemini-2.5-flash'       = @( 0.30,  2.50, 3.50)
    }
    $observatoryUrl = $env:OBSERVATORY_URL
    $sessionId = $json.session_id ?? [Guid]::NewGuid().ToString()

    foreach ($mProp in $json.stats.models.PSObject.Properties) {
        try {
            $tokens = $mProp.Value.tokens
            if (-not $tokens) { continue }
            $cached   = [long]($tokens.cached ?? 0)
            $inTok    = [Math]::Max(0L, [long]($tokens.prompt ?? 0) - $cached)
            $outTok   = [long]($tokens.candidates ?? 0)
            $thoughts = [long]($tokens.thoughts ?? 0)
            if ($inTok -eq 0 -and $outTok -eq 0) { continue }

            $rateKey = ($gemPricing.Keys | Where-Object { $mProp.Name.StartsWith($_) } | Select-Object -First 1)
            $rates = $rateKey ? $gemPricing[$rateKey] : @(2.50, 10.0, 3.50)
            $costUsd = [Math]::Round((
                ($inTok * $rates[0]) + ($outTok * $rates[1]) + ($thoughts * $rates[2])
            ) / 1000000.0, 8)

            $sumIn += $inTok; $sumOut += $outTok; $sumCost += $costUsd

            # Post to the general usage pipeline (Overview) only when configured;
            # the sidecar below is written independently for the adv-review event.
            if ($env:OBSERVATORY_API_KEY -and $observatoryUrl) {
                # cacheWriteTokens carries thinking tokens (observatory hook convention).
                $obsBody = @{
                    provider         = 'Google'
                    model            = $mProp.Name
                    inputTokens      = $inTok
                    outputTokens     = $outTok
                    cacheReadTokens  = $cached
                    cacheWriteTokens = $thoughts
                    costUsd          = $costUsd
                    eventKey         = "gemini:$sessionId`:$($mProp.Name)"
                    rawPayload       = (@{
                        source     = 'gemini-review'
                        session_id = $sessionId
                        role       = 'adversarial-review external reviewer'
                    } | ConvertTo-Json -Compress)
                } | ConvertTo-Json -Compress

                Invoke-RestMethod `
                    -Uri "$observatoryUrl/api/events" `
                    -Method Post `
                    -ContentType 'application/json' `
                    -Headers @{ 'X-Observatory-Key' = $env:OBSERVATORY_API_KEY } `
                    -Body $obsBody `
                    -TimeoutSec 5 `
                    -ErrorAction SilentlyContinue | Out-Null
            }
        } catch { }
    }
}

if ($UsageSidecarPath) {
    try {
        @{ inputTokens = $sumIn; outputTokens = $sumOut; costUsd = [Math]::Round($sumCost, 8) } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $UsageSidecarPath -Encoding UTF8
    } catch { }
}

# Emit the review: to -OutPath when set (keeps the caller free of a '> file'
# redirect), otherwise to stdout.
if ($OutPath) {
    $response.TrimEnd() | Set-Content -LiteralPath $OutPath -Encoding utf8
}
else {
    $response.TrimEnd()
}
