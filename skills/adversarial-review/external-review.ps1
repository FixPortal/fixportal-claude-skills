#Requires -Version 7
<#
.SYNOPSIS
    Cross-vendor reviewer for the adversarial-review skill.

.DESCRIPTION
    Runs the GitHub Copilot CLI headless so a non-Claude model (via the user's
    GitHub Copilot subscription) can act as an independent code reviewer.

    The Copilot agent is constrained to a read-only analysis call: the shell
    and write tools are denied, built-in MCP servers are disabled, and
    repository custom instructions are not loaded. File access is whitelisted
    (--add-dir) to only the directories holding the input files. The agent can
    read those inputs and emit text -- nothing is executed and nothing is
    modified.

    The Copilot CLI rejects plain-text files as --attachment ("native
    document" only), so inputs are delivered as files the model reads with its
    file tool.

    Used by ~/.claude/skills/adversarial-review for Phase 1 (blind review,
    -DiffPath) and Phase 2 (cross-examination, -DiffPath and -FindingsPath).
    Either phase may also pass -ContextPath to supply repo files the diff
    depends on but does not contain, since this reviewer never sees the repo.

.PARAMETER Instruction
    The review or cross-examination instruction passed to the model. Typically
    supplied as (Get-Content brief.txt -Raw).

.PARAMETER DiffPath
    Path to the diff file under review.

.PARAMETER FindingsPath
    Optional. Path to the pooled-findings file -- supplied in the Phase 2
    cross-examination round, omitted in Phase 1.

.PARAMETER ContextPath
    Optional. One or more repository files supplied as read-only BACKGROUND --
    interfaces, contracts, and callers the diff refers to but does not contain.
    This reviewer never sees the repository, so without context it withholds
    ("needs evidence") on any finding whose mechanism lives outside the diff.
    Context files are labelled as not-under-review and are not a source of
    findings in their own right.

    Pass either a real array (in-process callers: -ContextPath $files) OR, when
    invoking across a `pwsh -File` boundary, a SINGLE ';'-joined token
    (-ContextPath "a.cs;b.cs;c.cs"). Do NOT use repeated -ContextPath flags
    across `-File` -- PowerShell rejects them ("specified more than once"); and a
    bare array variable silently collapses, leaking the second path to the next
    positional parameter. The wrapper splits on ';' so both forms behave.

.PARAMETER Model
    Copilot model id. Must be a non-Claude model so the review adds genuine
    cross-vendor diversity to the panel.

.OUTPUTS
    The model's review text on stdout. Non-zero exit code on failure.

.EXAMPLE
    pwsh -NoProfile -File external-review.ps1 `
        -Instruction (Get-Content brief.txt -Raw) `
        -DiffPath review-diff.txt -Model gpt-5.4
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

    [string] $Model = 'gpt-5.4'
)

if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
    Write-Error 'GitHub Copilot CLI not found on PATH. Install with: npm install -g @github/copilot'
    exit 2
}

# The diff (always) and the pooled findings (Phase 2) are the material under
# review. The optional context files are repo background the cross-vendor
# reviewer would otherwise be blind to -- it never sees the repository.
$reviewPaths  = @($DiffPath)
if ($FindingsPath) { $reviewPaths += $FindingsPath }
# Accept context paths either as a real string[] (in-process callers) OR as a
# single ';'-joined token. The latter is required when crossing a `pwsh -File`
# boundary, where PowerShell's argument binder does NOT accumulate repeated
# -ContextPath flags (it errors "specified more than once") and does NOT split a
# comma-joined token — so the in-process array collapses or leaks to the next
# positional parameter. Splitting every element on ';' normalises both forms.
$contextPaths = @($ContextPath | ForEach-Object { $_ -split ';' } | Where-Object { $_ })

$reviewFiles = foreach ($path in $reviewPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "Input file not found: $path"
        exit 2
    }
    (Resolve-Path -LiteralPath $path).Path
}

$contextFiles = foreach ($path in $contextPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "Context file not found: $path"
        exit 2
    }
    (Resolve-Path -LiteralPath $path).Path
}

$files = @($reviewFiles) + @($contextFiles)

# Whitelist only the directories that hold the input files.
$dirArgs = $files |
    ForEach-Object { Split-Path -Parent $_ } |
    Sort-Object -Unique |
    ForEach-Object { '--add-dir'; $_ }

# The model reads the inputs itself; spell out which files and forbid wandering.
$reviewList = ($reviewFiles | ForEach-Object { "- $_" }) -join "`n"
$prompt = @"
$Instruction

--- FILES TO REVIEW ---
Read each of the following files in full before you respond. They contain the
diff to review (and, in a cross-examination round, the pooled findings). These
are the material under review.
$reviewList
"@

if ($contextFiles) {
    $contextList = ($contextFiles | ForEach-Object { "- $_" }) -join "`n"
    $prompt += @"


--- REPO CONTEXT (read-only background, NOT under review) ---
The following files are supporting context from the repository: interfaces,
contracts, and callers the diff refers to but does not contain. Use them to
judge whether a defect is real -- does the caller exist, does the contract
permit null, is the type reachable. Do NOT raise findings against these files;
they are background, not the change under review.
$contextList
"@
}

# Run from a throwaway working directory for cwd hygiene.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('adv-review-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

# -p                  headless, single-shot run (exits when done)
# --allow-all-tools   required by the CLI for non-interactive mode...
# --deny-tool         ...but shell + write are denied (deny takes precedence),
#                     leaving a read-only analysis call with no side effects.
# --disable-builtin-mcps / --no-custom-instructions  close the repo/MCP
#                     side-channels so the review depends only on the inputs.
$copilotArgs = @(
    '-p', $prompt
    '--model', $Model
    '-C', $scratch
    '--allow-all-tools'
    '--deny-tool=shell'
    '--deny-tool=write'
    '--disable-builtin-mcps'
    '--no-custom-instructions'
    '--no-ask-user'
    '--no-color'
    '--silent'
) + $dirArgs

try {
    $captured = (& copilot @copilotArgs 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($exitCode -ne 0) {
    Write-Error ("copilot exited with code {0}.`n{1}" -f $exitCode, $captured)
    exit $exitCode
}

($captured ?? '').TrimEnd()
