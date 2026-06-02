#Requires -Version 7
<#
.SYNOPSIS
    Claude reviewer for the adversarial-review skill (headless `claude -p`).

.DESCRIPTION
    Runs the Claude Code CLI headless so a Claude model can act as a panel
    reviewer through the SAME subprocess contract as the cross-vendor wrappers
    (external-review.ps1 for GPT via Copilot, gemini-review.ps1 for Gemini).

    The point is portability. Under Claude Code the orchestrator can spawn the
    Claude tiers in-process via the Agent tool, but no other host (Antigravity's
    `agy`, the Gemini CLI, a bare shell) has that tool. This wrapper makes the
    Claude reviewers reachable as an ordinary subprocess, so the whole panel can
    be driven uniformly from any host -- which is what makes the skill
    cross-agent.

    The call is constrained to read-only analysis: `--permission-mode plan`
    blocks edit/execute tools, the allowed tool set is read-only (Read, and --
    only when -RepoPath is supplied -- Grep/Glob), and it runs from a throwaway
    working directory so the repository's own CLAUDE.md / project context does
    not bias the review. (--bare would fully sandbox context, but it forces
    API-key-only auth and would break the user's OAuth subscription, so it is
    deliberately NOT used; the scratch cwd is the hermeticity lever instead. The
    global ~/.claude/CLAUDE.md still loads -- there is no flag short of --bare to
    skip it.)

    Inputs are inlined into the prompt and delivered on stdin -- deterministic,
    no command-line length limit, symmetric with the other wrappers. With
    -RepoPath the reviewer additionally gets read-only repo access (--add-dir)
    so a Claude tier can pull surrounding context the diff omits; without it the
    review is fully inlined and repo-blind like the cross-vendor reviewers.

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
    Claude model id (e.g. opus, sonnet). The two Claude tiers in the panel
    differ only by this value.

.PARAMETER Effort
    Reasoning effort: low | medium | high | xhigh | max (maps to `--effort`).
    Defaults to high -- a review panel wants depth, not a cheap scan. Dial down
    only for a deliberately fast pass.

.PARAMETER RepoPath
    Optional. Repository root. When supplied, the reviewer gets read-only
    (Read/Grep/Glob) access to it via --add-dir, so a Claude tier can read
    surrounding context the diff omits. Omit for a fully-inlined, repo-blind
    review symmetric with the cross-vendor wrappers.

.OUTPUTS
    The model's review text on stdout. Non-zero exit code on failure.

.EXAMPLE
    pwsh -NoProfile -File claude-review.ps1 `
        -Instruction (Get-Content brief.txt -Raw) `
        -DiffPath review-diff.txt -Model sonnet
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

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Model,

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string] $Effort = 'high',

    [string] $RepoPath
)

# Pipe UTF-8 to the child process so non-ASCII in diffs survives.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Error 'Claude Code CLI not found on PATH. Install from https://claude.com/claude-code'
    exit 2
}

function Read-InputFile([string] $path, [string] $label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "$label not found: $path"
        exit 2
    }
    Get-Content -LiteralPath $path -Raw
}

# Compose the full prompt and deliver it on stdin (dodges command-line length
# limits on large diffs; symmetric with the other wrappers).
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine($Instruction)
[void]$sb.AppendLine()
[void]$sb.AppendLine('--- DIFF UNDER REVIEW ---')
[void]$sb.AppendLine((Read-InputFile $DiffPath 'Input file'))

if ($FindingsPath) {
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('--- POOLED FINDINGS (attribution removed) ---')
    [void]$sb.AppendLine((Read-InputFile $FindingsPath 'Findings file'))
}

$contextPaths = @($ContextPath | Where-Object { $_ })
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

# Run from a throwaway working directory so the repo's own CLAUDE.md / project
# context cannot bias the review. --permission-mode plan = read-only (no edit,
# no execute). Tools stay read-only; repo access is opt-in via -RepoPath.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('claude-review-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$errFile = Join-Path $scratch 'stderr.txt'

$claudeArgs = @(
    '-p'
    '--model', $Model
    '--effort', $Effort
    '--output-format', 'text'
    '--permission-mode', 'plan'
)

if ($RepoPath) {
    $repoResolved = (Resolve-Path -LiteralPath $RepoPath -ErrorAction SilentlyContinue)?.Path
    if (-not $repoResolved) {
        Write-Error "RepoPath not found: $RepoPath"
        exit 2
    }
    # Read-only repo access: the reviewer may read surrounding context but the
    # plan permission mode still forbids any mutation.
    $claudeArgs += @('--add-dir', $repoResolved, '--allowedTools', 'Read', 'Grep', 'Glob')
}
else {
    # Fully inlined, repo-blind: nothing to read in the scratch dir.
    $claudeArgs += @('--allowedTools', 'Read')
}

Push-Location -LiteralPath $scratch
try {
    $stdout = ($stdin | & claude @claudeArgs 2>$errFile) | Out-String
    $exitCode = $LASTEXITCODE
    $stderr = (Test-Path $errFile) ? (Get-Content -LiteralPath $errFile -Raw) : ''
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($exitCode -ne 0) {
    Write-Error ("claude exited with code {0}.`n{1}" -f $exitCode, $stderr)
    exit $exitCode
}

$response = ($stdout ?? '').Trim()
if ([string]::IsNullOrWhiteSpace($response)) {
    Write-Error ("claude returned an empty response.`nSTDERR:`n{0}" -f $stderr)
    exit 1
}

$response.TrimEnd()
