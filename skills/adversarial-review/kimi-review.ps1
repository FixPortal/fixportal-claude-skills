#Requires -Version 7
<#
.SYNOPSIS
    Moonshot reviewer for the adversarial-review skill, via the Kimi Code CLI
    (subscription-backed through the Kimi Allegretto OAuth login).

.DESCRIPTION
    Runs `kimi -p` (non-interactive) so a Kimi model can act as a panel
    reviewer through the SAME subprocess contract as the other wrappers
    (claude-review.ps1, codex-review.ps1, gemini-review.ps1). This is the
    subscription-backed Moonshot vote: Kimi Code authenticates via the Allegretto
    OAuth login (`kimi login`, provider source=oauth), so it draws on the
    flat-rate subscription, not metered API credits. Moonshot has no API-fallback
    wrapper (sub-only).

    READ-ONLY POSTURE. Kimi Code has no per-invocation read-only flag, and its
    global config default_permission_mode is typically "yolo" (auto-approve). This
    wrapper therefore does NOT rely on the CLI to be read-only. Instead it is made
    hermetic structurally:
      * it runs from a throwaway scratch working directory, never the repo, so a
        stray write lands in scratch, not source;
      * the brief / diff / findings / context are COPIED into that scratch dir and
        the model is told to read them there — the repo is NEVER added to the
        workspace;
      * the prompt hard-forbids Edit/Write/Bash and any mutating tool.
    -RepoPath is REFUSED outright: Kimi has no per-invocation read-only mode, so
    --add-dir would mount the live tree under the global yolo permission mode with
    no sandbox at all. Supply the repo files the review needs via -ContextPath.

    Used for Phase 1 (blind review, -DiffPath) and Phase 2 (cross-examination,
    -DiffPath and -FindingsPath). Either phase may also pass -ContextPath.

    Requires: the `kimi` CLI on PATH, logged in (`kimi login`).

.NOTES
    PREFLIGHT_COMMAND: kimi provider list
    PREFLIGHT_SUCCESS: exit 0 and the configured provider line contains source=oauth.

.PARAMETER Model
    Kimi model alias. Mandatory, no default -- the panel seat resolves one from
    the canonical model registry (reviewers.json `select` via
    model-registry/resolve.py), and a direct caller resolves one the same way
    rather than leaning on a pinned id here. The -highspeed selector bills ~3x
    the credits for equivalent review output, so resolve the standard selector
    unless speed is worth the 3x burn.

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

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Model,

    # Declared for contract symmetry and REFUSED (exit 2): see the READ-ONLY POSTURE
    # note. The driver never passes it, because every Kimi seat is repoAccess:false.
    [string] $RepoPath,

    [string] $Effort,           # accepted for contract symmetry; kimi has no per-invocation effort flag

    [string] $OutPath,
    [string] $UsageSidecarPath
)

$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# -Effort is declared for contract symmetry and cannot be honoured: `kimi --help`
# advertises no effort, reasoning or thinking flag. run-review.ps1 introspects
# declared parameters and forwards -Effort to any wrapper that DECLARES one, so
# the Kimi seat's reviewers.json effort arrives here and would otherwise be
# discarded without trace. That is exactly how claude-review.ps1's dropped
# --effort survived review: the declaration convinced the driver the capability
# was real. Kimi has no flag to forward it to, so say so rather than fix it.
if ($Effort) {
    Write-Warning "-Effort '$Effort' ignored: the kimi CLI exposes no per-invocation effort flag, so this seat's declared effort is not applied."
}

# Refuse repo access before anything else (see READ-ONLY POSTURE).
if ($RepoPath) {
    Write-Error '-RepoPath is not supported by this wrapper: Kimi has no read-only mode, so --add-dir would mount the writable live tree. Pass the needed repo files via -ContextPath.'
    exit 2
}

# Kimi Code's installer adds ~/.kimi-code/bin to the interactive shell's PATH, but a
# non-interactive / sandboxed pwsh (e.g. spawned by an agent harness) may not inherit it,
# so `Get-Command kimi` misses even when Kimi is installed and logged in. Fall back to the
# known install location before giving up, so the Moonshot vote isn't silently dropped.
if (-not (Get-Command kimi -ErrorAction SilentlyContinue)) {
    $kimiBin = Join-Path $HOME '.kimi-code/bin'
    if (Test-Path -LiteralPath (Join-Path $kimiBin 'kimi.exe')) {
        $env:PATH = $kimiBin + [IO.Path]::PathSeparator + $env:PATH
    }
}

if (-not (Get-Command kimi -ErrorAction SilentlyContinue)) {
    Write-Error 'kimi CLI not found on PATH or at ~/.kimi-code/bin. Install Kimi Code and run `kimi login`. Moonshot has no API fallback.'
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

# --- Hermetic scratch workspace: copy the inputs in, point Kimi at them ------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("kimi-review-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $work 'brief.txt') -Value $Instruction -Encoding utf8
    # Fail fast: a bad -DiffPath must NOT launch Kimi against a missing diff.
    Copy-Item -LiteralPath $DiffPath -Destination (Join-Path $work 'review-diff.txt') -Force -ErrorAction Stop
    if ($FindingsPath) { Copy-Item -LiteralPath $FindingsPath -Destination (Join-Path $work 'pooled-findings.txt') -Force -ErrorAction Stop }

    $contextPaths = @($ContextPath | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $ctxDir = Join-Path $work 'context'
    if ($contextPaths) {
        New-Item -ItemType Directory -Force -Path $ctxDir | Out-Null
        $contextIndex = [System.Collections.Generic.List[string]]::new()
        $i = 0
        foreach ($p in $contextPaths) {
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $copyName = "{0:D2}_{1}" -f $i, (Split-Path $p -Leaf)
                Copy-Item -LiteralPath $p -Destination (Join-Path $ctxDir $copyName) -Force
                $contextIndex.Add("$copyName`t$((Resolve-Path -LiteralPath $p).Path)")
                $i++
            }
            else { throw "Context file not found: $p" }
        }
        Set-Content -LiteralPath (Join-Path $ctxDir 'INDEX.txt') -Value $contextIndex -Encoding utf8
    }

    # --- Build the short driving prompt (Kimi reads the files itself) --------
    $pb = [System.Text.StringBuilder]::new()
    [void]$pb.AppendLine('You are a READ-ONLY code reviewer on an adversarial review panel.')
    [void]$pb.AppendLine('Do NOT use Edit, Write, Bash, or any tool that modifies files or runs shell commands. Use only Read/Grep/Glob to inspect. Output findings only.')
    [void]$pb.AppendLine()
    [void]$pb.AppendLine('Read brief.txt in the current directory and follow it EXACTLY as your instructions.')
    [void]$pb.AppendLine('The change under review is review-diff.txt in the current directory.')
    if ($FindingsPath) { [void]$pb.AppendLine('The pooled findings to cross-examine are in pooled-findings.txt in the current directory.') }
    if ($contextPaths)  { [void]$pb.AppendLine('Supporting context paths map to their original locations in context/INDEX.txt; they are NOT under review.') }
    [void]$pb.AppendLine()
    [void]$pb.AppendLine('Output ONLY the findings in the exact format the brief requires. No preamble, no narration.')
    $prompt = $pb.ToString()

    $kimiArgs = @('-p', $prompt, '--model', $Model, '--output-format', 'stream-json')

    Push-Location $work
    try {
        $maxAttempts = 3
        $jsonl = $null
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $jsonl = & kimi @kimiArgs 2>&1
            if ($LASTEXITCODE -eq 0) { break }
            if ($attempt -eq $maxAttempts) {
                Write-Error ("kimi -p failed after $attempt attempt(s) (exit $LASTEXITCODE).`n" + ($jsonl | Out-String))
                exit 1
            }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
        }
    } finally {
        Pop-Location
    }

    # --- Extract the assistant messages from the stream-json ------------------
    # ACCUMULATE, do not assign: stream-json emits one frame per assistant turn, and
    # assigning would let a late frame with content (a background-task notification)
    # replace the whole review with a stub. Mirrors claude-review.ps1's append.
    # Tool-call frames carry no content.
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($jsonl)) {
        $s = [string]$line
        if ($s -notmatch '"role"\s*:\s*"assistant"') { continue }
        try {
            $evt = $s | ConvertFrom-Json -ErrorAction Stop
            if ($evt.content -and -not [string]::IsNullOrWhiteSpace([string]$evt.content)) { $parts.Add([string]$evt.content) }
        } catch {}
    }
    $text = ($parts -join "`n`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        $stream = $jsonl -join [Environment]::NewLine
        Write-Error "kimi returned no assistant content. Raw stream:`n$stream"
        exit 1
    }

    # Strip any <think>...</think> reasoning blocks (K3 is always-thinking).
    $text = [regex]::Replace($text, '(?s)<think>.*?</think>', '').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-Error 'kimi returned an empty review.'; exit 1
    }

    # --- Cost/tokens: stream-json carries no usage; report putative from 0 ---
    # (subscription is flat-rate; per-token spend is ~0). Kept for contract parity.
    if ($UsageSidecarPath) {
        @{ inputTokens = 0; outputTokens = 0; costUsd = 0 } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $UsageSidecarPath -Encoding utf8 -NoNewline
    }

    if ($OutPath) {
        try { $text.TrimEnd() | Set-Content -LiteralPath $OutPath -Encoding utf8 -ErrorAction Stop }
        catch { Write-Error "Failed to write review output to '$OutPath': $($_.Exception.Message)"; exit 1 }
    } else {
        $text.TrimEnd()
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
