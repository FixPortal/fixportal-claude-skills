#Requires -Version 7
<#
.SYNOPSIS
    Google reviewer for the adversarial-review skill, via Antigravity CLI.

.DESCRIPTION
    Runs `agy -p` against the user's Google subscription in hard read-only plan
    mode. Inputs are copied to a throwaway workspace so large diffs never hit
    Windows command-line limits and the repository is not exposed by default.

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
    [string] $Model = 'gemini-3.1-pro-high',

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string] $Effort = 'high',

    [string] $RepoPath,
    [string] $OutPath,
    [string] $UsageSidecarPath
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
        for ($i = 0; $i -lt $contextPaths.Count; $i++) {
            $path = $contextPaths[$i]
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-Error "Context file not found: $path"; exit 2
            }
            Copy-Item -LiteralPath $path -Destination (Join-Path $contextDir ('{0:D2}_{1}' -f $i, (Split-Path $path -Leaf))) -Force
        }
    }

    $prompt = @(
        'You are a READ-ONLY code reviewer on an adversarial review panel.'
        'Read brief.txt and follow it exactly.'
        'Review only the change in review-diff.txt.'
        $(if ($FindingsPath) { 'Cross-examine pooled-findings.txt as the brief directs.' })
        $(if ($contextPaths) { 'Use files under context/ only as supporting background; do not raise findings against them.' })
        $(if ($RepoPath) { "You may read the repository at $RepoPath for context; do not modify it." })
        'Output only the review text in the exact format the brief requests. No preamble or narration.'
    ) | Where-Object { $_ }

    $agyEffort = ($Model -match '-(low|medium|high)$') ? $Matches[1] : (($Effort -in @('low', 'medium')) ? $Effort : 'high')
    $agyArgs = @(
        '-p', ($prompt -join "`n")
        '--model', $Model
        '--mode', 'plan'
        '--effort', $agyEffort
        '--print-timeout', '5m'
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
