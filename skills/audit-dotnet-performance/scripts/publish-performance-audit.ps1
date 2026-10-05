#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $StagingDirectory,

    [Parameter(Mandatory)]
    [string] $DestinationDirectory,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*performance-audit$')]
    [string] $Stem
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string] $Message) {
    [Console]::Error.WriteLine($Message)
    exit 1
}

$lock = $null
$lockHeld = $false
$failure = $null
try {
    $staging = (Resolve-Path -LiteralPath $StagingDirectory -ErrorAction Stop).Path
    $destination = (Resolve-Path -LiteralPath $DestinationDirectory -ErrorAction Stop).Path
    # Case rule taken from the PLATFORM, the way the sibling boundary script does it. A
    # fixed `-cne` refused a perfectly valid pair on Windows whenever the caller's spelling
    # of the destination differed in case from the staging path's resolved parent - the
    # publisher then reported the audit as unpublishable, and on a case-sensitive
    # filesystem an ignore-case comparison would accept two genuinely different
    # directories, which is why neither rule can be hard-coded.
    $pathComparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not ([string](Split-Path $staging -Parent)).Equals($destination, $pathComparison) -or
        (Split-Path $staging -Leaf) -notlike '.staging-*') {
        throw 'StagingDirectory must be a .staging-* child of DestinationDirectory.'
    }

    $report = Join-Path $staging 'report.md'
    $manifest = Join-Path $staging 'report.manifest.json'
    $entries = @(Get-ChildItem -LiteralPath $staging -Force)
    if ($entries.Count -ne 2 -or -not (Test-Path -LiteralPath $report -PathType Leaf) -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw 'StagingDirectory must contain only report.md and report.manifest.json.'
    }

    $validator = Join-Path $PSScriptRoot 'test-performance-manifest.ps1'
    $validation = [Diagnostics.ProcessStartInfo]::new()
    $validation.FileName = (Get-Command pwsh).Source
    $validation.UseShellExecute = $false
    $validation.RedirectStandardOutput = $true
    $validation.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $validator, '-Path', $manifest, '-ReportPath', $report)) {
        $validation.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($validation)
    # BOTH streams read concurrently. Sequential ReadToEnd is the textbook pipe deadlock:
    # this side blocks on stdout while the child blocks writing a full stderr buffer, and
    # neither moves again. Latent at one stderr line, reachable the moment the validator
    # reports a manifest with many violations - the publication then hangs forever rather
    # than failing, holding its lock. Started before WaitForExit so both drain while the
    # child runs.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        $validationFailure = "$stderr`n$stdout".Trim()
        if (-not $validationFailure) { $validationFailure = "Manifest validation exited with code $($process.ExitCode)." }
        throw $validationFailure
    }

    $lock = Join-Path $destination '.performance-audit-publish.lock'
    try {
        New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
        $lockHeld = $true
    }
    catch {
        if (Test-Path -LiteralPath $lock -PathType Container) {
            # A hard-killed publisher leaves this directory behind, and the old message
            # named neither the path nor the possibility - so the operator was told a
            # publication was "in progress" that had died hours earlier, with nothing to
            # act on. The lock is NOT broken automatically: the one thing worse than a
            # stale lock is two publishers moving files into the same destination. Say
            # where it is and how old, and let a person decide.
            $held = try { (Get-Item -LiteralPath $lock).CreationTime } catch { $null }
            $age = if ($held) { " held since $($held.ToString('u')) ($([int]((Get-Date) - $held).TotalMinutes) minute(s) ago)" } else { '' }
            throw ("Another performance-audit publication is already in progress for '$destination': " +
                "lock '$lock'$age. If no publisher is running, this lock is stale - remove that " +
                'directory and re-run.')
        }
        throw
    }

    $suffix = 1
    do {
        $candidateStem = if ($suffix -eq 1) { $Stem } else { '{0}-{1:D2}' -f $Stem, $suffix }
        $reportTarget = Join-Path $destination "$candidateStem.md"
        $manifestTarget = Join-Path $destination "$candidateStem.manifest.json"
        $collision = (Test-Path -LiteralPath $reportTarget) -or (Test-Path -LiteralPath $manifestTarget)
        $suffix++
    } while ($collision)

    Move-Item -LiteralPath $report -Destination $reportTarget -ErrorAction Stop
    try {
        Move-Item -LiteralPath $manifest -Destination $manifestTarget -ErrorAction Stop
    }
    catch {
        $manifestFailure = $_.Exception.Message
        try {
            Move-Item -LiteralPath $reportTarget -Destination $report -ErrorAction Stop
        }
        catch {
            throw "Manifest publication failed ('$manifestFailure') and report rollback also failed ('$($_.Exception.Message)'). Destination '$reportTarget' and staging are inconsistent."
        }
        throw "Manifest publication failed; report rollback succeeded: $manifestFailure"
    }
    try {
        Remove-Item -LiteralPath $staging -Force -ErrorAction Stop
    }
    catch {
        [Console]::Error.WriteLine("Warning: publication succeeded but staging cleanup failed: $($_.Exception.Message)")
    }

    [pscustomobject]@{
        report = $reportTarget
        manifest = $manifestTarget
    } | ConvertTo-Json -Compress
}
catch {
    $failure = $_.Exception.Message
}
finally {
    if ($lockHeld) {
        try {
            Remove-Item -LiteralPath $lock -Force -ErrorAction Stop
        }
        catch {
            [Console]::Error.WriteLine("Warning: could not remove publication lock '$lock': $($_.Exception.Message)")
        }
    }
}
if ($failure) { Fail $failure }
