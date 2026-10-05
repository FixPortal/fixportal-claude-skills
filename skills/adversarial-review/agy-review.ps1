#Requires -Version 7
<#
.SYNOPSIS
    Google reviewer for the adversarial-review skill, via Antigravity CLI.

.DESCRIPTION
    Runs `agy -p` against the user's Google subscription in hard read-only plan
    mode. Inputs are copied to a throwaway workspace so large diffs never hit
    Windows command-line limits and the repository is not exposed by default.

.NOTES
    PREFLIGHT_COMMAND: agy models
    PREFLIGHT_SUCCESS: exit 0 and output contains the reviewer's configured model.

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
    # Mandatory, no default: the driver supplies a registry-resolved agy selector,
    # and a direct caller resolves one the same way (model-registry/resolve.py
    # --tier <tier> --host agy) rather than leaning on a pinned id here. agy fuses
    # reasoning effort into the selector, so the id carries it and -Effort below
    # is read back off the suffix rather than appended.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Model,

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string] $Effort = 'high',

    [string] $RepoPath,
    [string] $OutPath,
    [string] $UsageSidecarPath,

    # agy's ceiling on waiting for a response. 5m killed slots that a 20m ceiling
    # recovered on the FIRST attempt in two separate runs (20260816T095922Z C6,
    # 20260816T214504Z G), while four identical retries at 5m recovered nothing.
    # Payload size is not the variable: a 125KB chunk succeeded while 45KB and 53KB
    # chunks failed. Retrying a wrapper timeout without raising this is wasted spend.
    # See ~/.agents/notes/model-routing-traps.md trap 8.
    [ValidatePattern('^\d+[smh]$')]
    [string] $PrintTimeout = '20m'
)

$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not (Get-Command agy -ErrorAction SilentlyContinue) -and $env:LOCALAPPDATA) {
    $agyBin = Join-Path $env:LOCALAPPDATA 'agy\bin'
    if (Test-Path -LiteralPath (Join-Path $agyBin 'agy.exe')) {
        $env:PATH = $agyBin + [IO.Path]::PathSeparator + $env:PATH
    }
}
if (-not (Get-Command agy -ErrorAction SilentlyContinue)) {
    Write-Error 'Antigravity CLI not found on PATH or under LOCALAPPDATA\agy\bin.'
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

$work = Join-Path ([IO.Path]::GetTempPath()) ('agy-review-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $work 'brief.txt') -Value $Instruction -Encoding utf8
    if (-not (Test-Path -LiteralPath $DiffPath -PathType Leaf)) {
        Write-Error "Input file not found: $DiffPath"; exit 2
    }
    Copy-Item -LiteralPath $DiffPath -Destination (Join-Path $work 'review-diff.txt') -Force
    if ($FindingsPath) {
        if (-not (Test-Path -LiteralPath $FindingsPath -PathType Leaf)) {
            Write-Error "Findings file not found: $FindingsPath"; exit 2
        }
        Copy-Item -LiteralPath $FindingsPath -Destination (Join-Path $work 'pooled-findings.txt') -Force
    }

    $contextPaths = @($ContextPath | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($contextPaths) {
        $contextDir = Join-Path $work 'context'
        New-Item -ItemType Directory -Path $contextDir -Force | Out-Null
        $contextIndex = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $contextPaths.Count; $i++) {
            $path = $contextPaths[$i]
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-Error "Context file not found: $path"; exit 2
            }
            $copyName = '{0:D2}_{1}' -f $i, (Split-Path $path -Leaf)
            Copy-Item -LiteralPath $path -Destination (Join-Path $contextDir $copyName) -Force
            $contextIndex.Add("$copyName`t$((Resolve-Path -LiteralPath $path).Path)")
        }
        Set-Content -LiteralPath (Join-Path $contextDir 'INDEX.txt') -Value $contextIndex -Encoding utf8
    }

    # ABSOLUTE paths, and an explicit ban on searching. agy does NOT resolve a bare
    # `brief.txt` against its working directory - it SEARCHES the filesystem and reads
    # whichever match it picks ("I am currently locating `brief.txt` on your system",
    # run 20260816T214504Z). The wrapper's file placement and Push-Location below are
    # correct and are not the defect; the bare filenames here were, and they poisoned the
    # Google axis across at least four runs with findings from other repositories. The
    # hazard is the whole of %TEMP%, where this wrapper's own workspace also lives, so no
    # amount of stale-directory sweeping bounds it. See model-routing-traps.md trap 8.
    $prompt = @(
        'You are a READ-ONLY code reviewer on an adversarial review panel.'
        "Read the brief at $(Join-Path $work 'brief.txt') and follow it exactly."
        "Review ONLY the change in $(Join-Path $work 'review-diff.txt')."
        $(if ($FindingsPath) { "Cross-examine $(Join-Path $work 'pooled-findings.txt') as the brief directs." })
        $(if ($contextPaths) { "Original supporting paths are in $(Join-Path $work 'context/INDEX.txt'); files are not under review." })
        $(if ($RepoPath) { "You may read the repository at $RepoPath for context; do not modify it." })
        'Do NOT search the filesystem for these files. Use exactly the absolute paths given above.'
        'If a path above cannot be read, stop and say so; never substitute another file.'
        'Output only the review text in the exact format the brief requests. No preamble or narration.'
    ) | Where-Object { $_ }

    # agy --effort accepts low|medium|high ONLY (verified against `agy --help`), while
    # the shared wrapper contract carries Claude's wider vocabulary, which also has
    # xhigh and max. Clamping those to high is required - passing them through makes
    # agy reject the invocation - but doing it SILENTLY means a seat configured for
    # max runs at high and the run record never says so.
    if ($Model -match '-(low|medium|high)$') {
        # agy fuses reasoning effort into the model selector, so a suffixed model
        # already carries it and the suffix wins. Deliberate precedence.
        $agyEffort = $Matches[1]
        if ($Effort -and $Effort -ne $agyEffort) {
            Write-Warning "-Effort '$Effort' ignored: the model selector '$Model' already pins effort to '$agyEffort'."
        }
    }
    elseif ($Effort -in @('low', 'medium')) {
        $agyEffort = $Effort
    }
    else {
        $agyEffort = 'high'
        if ($Effort -and $Effort -ne 'high') {
            Write-Warning "agy has no '$Effort' effort level (it accepts low|medium|high); clamped to 'high'."
        }
    }
    $agyArgs = @(
        '-p', ($prompt -join "`n")
        '--model', $Model
        '--mode', 'plan'
        '--effort', $agyEffort
        '--print-timeout', $PrintTimeout
    )
    if ($RepoPath) {
        if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
            Write-Error "Repository path not found: $RepoPath"; exit 2
        }
        $agyArgs += @('--add-dir', (Resolve-Path -LiteralPath $RepoPath).Path)
    }

    $errFile = Join-Path $work 'stderr.txt'
    Push-Location -LiteralPath $work
    try {
        $text = (& agy @agyArgs 2>$errFile | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally { Pop-Location }

    if ($exitCode -ne 0) {
        $stderr = (Test-Path -LiteralPath $errFile) ? (Get-Content -LiteralPath $errFile -Raw) : ''
        Write-Error ("agy exited with code {0}.`n{1}" -f $exitCode, $stderr); exit $exitCode
    }
    if ([string]::IsNullOrWhiteSpace($text)) { Write-Error 'agy returned an empty review.'; exit 1 }

    if ($UsageSidecarPath) {
        @{ inputTokens = 0; outputTokens = 0; costUsd = 0 } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $UsageSidecarPath -Encoding utf8 -NoNewline
    }

    if ($OutPath) {
        try { $text | Set-Content -LiteralPath $OutPath -Encoding utf8 -ErrorAction Stop }
        catch { Write-Error "Failed to write review output to '$OutPath': $($_.Exception.Message)"; exit 1 }
    }
    else { $text }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
