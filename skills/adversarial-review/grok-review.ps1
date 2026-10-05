#Requires -Version 7
<#
.SYNOPSIS
    xAI reviewer for the adversarial-review / audit-ai-quality panels, via the
    Grok CLI.

.DESCRIPTION
    Runs `grok --prompt-file` (single-turn headless mode) so a Grok model can act
    as a panel seat through the SAME subprocess contract as the other wrappers
    (claude-review.ps1, codex-review.ps1, kimi-review.ps1, agy-review.ps1).

    HEADLESS ENTRY POINT. `grok` is a TUI first: invoking it with a bare prompt
    argument hangs waiting on a terminal, which on this box was observed to sit
    past 100 seconds producing nothing. `--prompt-file <path>` is the single-turn
    form and `--output-format json` returns one object carrying `.text`, `.usage`
    and `.total_cost_usd`.

    READ-ONLY POSTURE. Grok has no per-invocation read-only mode, and
    `--always-approve` auto-approves every tool execution. This wrapper therefore
    does NOT rely on the CLI to be read-only. It is made hermetic structurally,
    exactly as kimi-review.ps1 is:
      * it runs from a throwaway scratch working directory, never the repo, so a
        stray write lands in scratch rather than source;
      * the brief / diff / findings / context are COPIED into that scratch dir and
        the model is told to read them there;
      * the prompt hard-forbids any mutating tool.
    A repo-aware run (-RepoPath) is NOT offered: without a sandbox flag there is
    nothing to make it safe beyond a prompt, and the seat ships repoAccess:false.

    COST NOTE. Measured 2026-09-18: a single-turn prompt of one sentence reported
    51,559 input tokens and USD 0.035. Grok loads substantial context of its own
    before it sees the prompt, so per-call overhead rides on top of the payload.

.NOTES
    PREFLIGHT_COMMAND: grok models
    PREFLIGHT_SUCCESS: exit 0 and at least one model id on stdout.

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

    # Mandatory, no default: the driver supplies a registry-resolved id, and a
    # direct caller resolves one the same way (model-registry/resolve.py
    # --tier <tier> --vendor xai --channel cli) rather than leaning on a pinned
    # id here.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Model,

    [string] $Effort,

    [string] $OutPath,
    [string] $UsageSidecarPath
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not (Get-Command grok -ErrorAction SilentlyContinue)) {
    $grokBin = Join-Path $HOME '.grok/bin'
    if (Test-Path -LiteralPath (Join-Path $grokBin 'grok.exe')) {
        $env:PATH = $grokBin + [IO.Path]::PathSeparator + $env:PATH
    }
}
if (-not (Get-Command grok -ErrorAction SilentlyContinue)) {
    Write-Error 'grok CLI not found on PATH or at ~/.grok/bin. Install Grok and run `grok login`.'
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

# --- Hermetic scratch workspace: copy the inputs in, point Grok at them ------
$work = Join-Path ([IO.Path]::GetTempPath()) ('grok-review-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $work 'brief.txt') -Value $Instruction -Encoding utf8
    # Fail fast: a bad -DiffPath must NOT launch Grok against a missing diff.
    Copy-Item -LiteralPath $DiffPath -Destination (Join-Path $work 'review-diff.txt') -Force -ErrorAction Stop
    if ($FindingsPath) { Copy-Item -LiteralPath $FindingsPath -Destination (Join-Path $work 'pooled-findings.txt') -Force }

    $contextPaths = @($ContextPath | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $ctxDir = Join-Path $work 'context'
    if ($contextPaths) {
        New-Item -ItemType Directory -Force -Path $ctxDir | Out-Null
        $contextIndex = [System.Collections.Generic.List[string]]::new()
        $i = 0
        foreach ($p in $contextPaths) {
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $copyName = '{0:D2}_{1}' -f $i, (Split-Path $p -Leaf)
                Copy-Item -LiteralPath $p -Destination (Join-Path $ctxDir $copyName) -Force
                $contextIndex.Add("$copyName`t$((Resolve-Path -LiteralPath $p).Path)")
                $i++
            }
            else { throw "Context file not found: $p" }
        }
        Set-Content -LiteralPath (Join-Path $ctxDir 'INDEX.txt') -Value $contextIndex -Encoding utf8
    }

    $pb = [System.Text.StringBuilder]::new()
    [void]$pb.AppendLine('You are a READ-ONLY reviewer on a multi-vendor panel.')
    [void]$pb.AppendLine('Do NOT use any tool that modifies files or runs shell commands. Inspect only. Output findings only.')
    [void]$pb.AppendLine()
    [void]$pb.AppendLine('Read brief.txt in the current directory and follow it EXACTLY as your instructions.')
    [void]$pb.AppendLine('The change under review is review-diff.txt in the current directory.')
    if ($FindingsPath) { [void]$pb.AppendLine('The pooled findings to cross-examine are in pooled-findings.txt in the current directory.') }
    if ($contextPaths) { [void]$pb.AppendLine('Supporting context paths map to their original locations in context/INDEX.txt; they are NOT under review.') }
    [void]$pb.AppendLine()
    [void]$pb.AppendLine('Output ONLY what the brief requires. No preamble, no narration.')

    $promptFile = Join-Path $work 'prompt.txt'
    Set-Content -LiteralPath $promptFile -Value $pb.ToString() -Encoding utf8

    $grokArgs = @('--prompt-file', $promptFile, '--output-format', 'json', '--always-approve', '-m', $Model)
    if ($Effort) { $grokArgs += @('--reasoning-effort', $Effort) }

    Push-Location $work
    try {
        $maxAttempts = 3
        $raw = $null
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $raw = & grok @grokArgs 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) { break }
            if ($raw -match '(?i)(?:HTTP\s*|status(?:\s+code)?\s*)402\b') {
                Write-Error ("grok returned non-retryable HTTP 402.`n" + $raw)
                exit 1
            }
            if ($attempt -eq $maxAttempts) {
                Write-Error ("grok --prompt-file failed after $attempt attempt(s) (exit $LASTEXITCODE).`n" + $raw)
                exit 1
            }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
        }
    }
    finally {
        Pop-Location
    }

    # --- Extract the reply from the single JSON object ----------------------
    # Prose can precede the object (startup notices), so find the first balanced
    # one rather than parsing the whole stream -- the same failure that broke the
    # audit driver's seat parsing on real CLI output.
    $text = $null
    $usage = $null
    $start = $raw.IndexOf('{')
    while ($start -ge 0 -and $null -eq $text) {
        $depth = 0; $inString = $false; $escaped = $false
        for ($i = $start; $i -lt $raw.Length; $i++) {
            $ch = $raw[$i]
            if ($inString) {
                if ($escaped) { $escaped = $false }
                elseif ($ch -eq '\') { $escaped = $true }
                elseif ($ch -eq '"') { $inString = $false }
                continue
            }
            if ($ch -eq '"') { $inString = $true; continue }
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    try {
                        $obj = $raw.Substring($start, $i - $start + 1) | ConvertFrom-Json
                        if ($obj.PSObject.Properties.Name -contains 'text') { $text = [string]$obj.text; $usage = $obj }
                    }
                    catch { }
                    break
                }
            }
        }
        $start = $raw.IndexOf('{', $start + 1)
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-Error ("grok returned no usable reply.`n" + $raw)
        exit 1
    }

    if ($UsageSidecarPath -and $usage) {
        [ordered]@{
            model       = $Model
            inputTokens = $usage.usage.input_tokens
            outputTokens = $usage.usage.output_tokens
            totalTokens = $usage.usage.total_tokens
            costUsd     = $usage.total_cost_usd
            sessionId   = $usage.sessionId
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $UsageSidecarPath -Encoding utf8
    }

    if ($OutPath) { Set-Content -LiteralPath $OutPath -Value $text -Encoding utf8 }
    else { Write-Output $text }
    exit 0
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
