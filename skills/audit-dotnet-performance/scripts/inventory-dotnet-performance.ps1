#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepositoryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$maxSourceBytes = 65536

function Get-PrunedFiles {
    param(
        [string] $Root,
        [System.Collections.Generic.List[string]] $Warnings,
        [string] $ScanName,
        [scriptblock] $IncludeFile,
        [int] $MaxFiles,
        [int] $MaxDirectories,
        [ref] $Complete
    )

    $maxDepth = 32
    $files = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($Root)
    $queuedDirectories = 1
    $excluded = '(^|[\\/])(bin|obj|\.git|\.?worktrees|node_modules|\.?venv)([\\/]|$)'
    while ($pending.Count) {
        $directory = $pending.Dequeue()
        $depth = ([IO.Path]::GetRelativePath($Root, $directory) -split '[\\/]').Count
        if ($depth -gt $maxDepth) {
            $Complete.Value = $false
            $Warnings.Add("$ScanName scan stopped below '$directory': maximum depth $maxDepth reached.")
            continue
        }
        $errors = $null
        $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue -ErrorVariable errors)
        # An unreadable directory is UNSCANNED, not empty. Every other truncation branch
        # clears $Complete; this one only warned, so the inventory published
        # projectInventoryComplete = true with no stopping condition over a subtree it
        # never enumerated, and a consumer gated on those fields read "absent" for files
        # that were merely unread.
        # `$readError`, not `$error`: a foreach over $error binds the automatic error
        # variable for the rest of this scope, so any later read of $error here would see
        # the loop's last item rather than the session's error record. (PowerShell allows
        # it - checked, `pwsh -NoProfile -c 'function f { $error = "x"; $error }; f'`
        # prints x - so the hazard is shadowing, not a failure at the assignment.)
        foreach ($readError in @($errors)) {
            $Complete.Value = $false
            $Warnings.Add("$ScanName scan left '$directory' UNSCANNED: $($readError.Exception.Message)")
        }
        foreach ($child in $children) {
            $relative = [IO.Path]::GetRelativePath($Root, $child.FullName)
            if ($relative -match $excluded) { continue }
            if ($child.PSIsContainer) {
                if (-not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    if ($queuedDirectories -ge $MaxDirectories) {
                        $Complete.Value = $false
                        $Warnings.Add("$ScanName scan stopped: maximum directory count $MaxDirectories reached.")
                        return @($files)
                    }
                    $pending.Enqueue($child.FullName)
                    $queuedDirectories++
                }
            }
            else {
                if (-not (& $IncludeFile $child)) { continue }
                if ($MaxFiles -gt 0 -and $files.Count -ge $MaxFiles) {
                    $Complete.Value = $false
                    $Warnings.Add("$ScanName scan stopped: maximum file count $MaxFiles reached.")
                    return @($files)
                }
                $files.Add($child)
            }
        }
    }
    return @($files)
}

function Invoke-CommandProbe {
    param([string] $Name, [string[]] $Arguments)

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    $commandText = (@($Name) + $Arguments) -join ' '
    if (-not $command) {
        return [pscustomobject]@{ command = $commandText; available = $false; exitCode = $null; output = @(); reason = "Command '$Name' was not found." }
    }

    try {
        $output = @(& $command.Source @Arguments 2>&1 | ForEach-Object ToString)
        $exitCode = $LASTEXITCODE
        $reason = if ($exitCode -eq 0) { $null } else { "$commandText exited with exit code $exitCode." }
        return [pscustomobject]@{ command = $commandText; available = $true; exitCode = $exitCode; output = $output; reason = $reason }
    }
    catch {
        return [pscustomobject]@{ command = $commandText; available = $true; exitCode = $null; output = @(); reason = $_.Exception.Message }
    }
}

function Get-ToolEvidence {
    param([string] $Name, [object] $Probe)

    if (-not $Probe) { $Probe = Invoke-CommandProbe -Name $Name -Arguments @('--version') }
    $version = if ($Probe.exitCode -eq 0) { @($Probe.output | Select-Object -First 1)[0] } else { $null }
    [pscustomobject]@{
        name = $Name
        available = $Probe.available
        version = $version
        command = $Probe.command
        exitCode = $Probe.exitCode
        output = @($Probe.output)
        reason = $Probe.reason
    }
}

$warnings = [System.Collections.Generic.List[string]]::new()
$resolved = $null
try { $resolved = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path }
catch {
    [pscustomobject]@{
        schemaVersion = 1; repositoryPath = $RepositoryPath; git = $null; sdk = $null; runtime = $null
        solutions = @(); targetFrameworks = @(); projects = @(); testProjects = @(); benchmarkProjects = @(); benchmarkConfiguration = @(); benchmarkArtifacts = @(); markers = @()
        tools = @(Get-ToolEvidence dotnet); completeness = 'partial'; warnings = @("Repository path could not be resolved: $($_.Exception.Message)")
    } | ConvertTo-Json -Depth 8 -Compress
    exit 0
}

$projectScanComplete = $true
$projectFilesAndConfiguration = Get-PrunedFiles -Root $resolved -Warnings $warnings -ScanName 'Project inventory' -IncludeFile {
    param($file)
    $file.Extension -in '.csproj', '.fsproj', '.vbproj', '.sln', '.slnx' -or
        $file.Name -in 'global.json', 'Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'nuget.config' -or
        $file.Name -match '(?i)benchmark.*\.(json|md)$|\.benchmarks\.json$'
} -MaxFiles 0 -MaxDirectories 512 -Complete ([ref]$projectScanComplete)
$sourceScanComplete = $true
$sourceFiles = Get-PrunedFiles -Root $resolved -Warnings $warnings -ScanName 'Source-marker' -IncludeFile {
    param($file)
    $file.Extension -in '.cs', '.fs', '.vb'
} -MaxFiles 64 -MaxDirectories 64 -Complete ([ref]$sourceScanComplete)
$projectFiles = @($projectFilesAndConfiguration | Where-Object { $_.Extension -in '.csproj', '.fsproj', '.vbproj' })
$projects = [System.Collections.Generic.List[object]]::new()
$tests = [System.Collections.Generic.List[object]]::new()
$benchmarks = [System.Collections.Generic.List[object]]::new()
$frameworks = [System.Collections.Generic.List[string]]::new()

foreach ($file in $projectFiles) {
    $relative = [IO.Path]::GetRelativePath($resolved, $file.FullName)
    try { [xml] $xml = Get-Content -LiteralPath $file.FullName -Raw }
    catch { $warnings.Add("Could not parse project '$relative': $($_.Exception.Message)"); continue }
    $tfms = @($xml.SelectNodes("//*[local-name()='TargetFramework' or local-name()='TargetFrameworks']") | ForEach-Object { $_.InnerText -split ';' } | Where-Object { $_ })
    foreach ($tfm in $tfms) { if (-not $frameworks.Contains($tfm)) { $frameworks.Add($tfm) } }
    $packages = @($xml.SelectNodes("//*[local-name()='PackageReference']") | ForEach-Object { $_.GetAttribute('Include') })
    $isTest = (($xml.SelectNodes("//*[local-name()='IsTestProject']") | ForEach-Object InnerText) -contains 'true') -or ($packages -match '(?i)^(xunit|nunit|mstest)')
    $isBenchmark = $packages -match '(?i)^BenchmarkDotNet$'
    $sdkNode = $xml.SelectSingleNode("/*[local-name()='Project']/@Sdk")
    $projectSdk = if ($sdkNode) { $sdkNode.Value } else { $null }
    $outputNode = $xml.SelectNodes("//*[local-name()='OutputType']") | Select-Object -First 1
    $outputType = if ($outputNode) { $outputNode.InnerText } else { $null }
    $role = if ($isBenchmark) { 'benchmark' } elseif ($isTest) { 'test' } elseif ($projectSdk -match '(?i)\.Web$') { 'web' } elseif ($projectSdk -match '(?i)\.Worker$') { 'worker' } elseif ($outputType -match '(?i)exe|winexe') { 'executable' } else { 'library' }
    $project = [pscustomobject]@{ path = $relative; targetFrameworks = @($tfms); role = $role; sdk = $projectSdk; outputType = $outputType }
    $projects.Add($project)
    if ($isTest) { $tests.Add($project) }
    if ($isBenchmark) { $benchmarks.Add($project) }
}

$markers = [System.Collections.Generic.List[object]]::new()
$maxMarkers = 500
$markerPatterns = [ordered]@{ DbContext = '\bDbContext\b'; HttpClient = '\bHttpClient\b'; BackgroundService = '\bBackgroundService\b'; 'Parallel.ForEachAsync' = '\bParallel\.ForEachAsync\b' }
# A file SKIPPED or UNREAD here is a file whose markers were never looked at, which is the
# same evidentiary state as a truncated enumeration - so it clears the same flag.
# `$sourceScanComplete` was set only by the directory walk, so an oversized or unreadable
# source file left the inventory claiming a complete marker scan over content it never
# opened, and "no DbContext found" then read as proven absence. (CodeRabbit, PR #135.)
:markerScan foreach ($file in $sourceFiles) {
    if ($file.Length -gt $maxSourceBytes) { $warnings.Add("Source file exceeds $maxSourceBytes bytes and was skipped: '$([IO.Path]::GetRelativePath($resolved, $file.FullName))'."); $sourceScanComplete = $false; continue }
    try { $lines = @(Get-Content -LiteralPath $file.FullName) }
    catch { $warnings.Add("Could not read source '$([IO.Path]::GetRelativePath($resolved, $file.FullName))': $($_.Exception.Message)"); $sourceScanComplete = $false; continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($marker in $markerPatterns.Keys) {
            if ($lines[$i] -match $markerPatterns[$marker]) {
                if ($markers.Count -ge $maxMarkers) { $warnings.Add("Marker scan stopped: maximum marker count $maxMarkers reached."); $sourceScanComplete = $false; break markerScan }
                $markers.Add([pscustomobject]@{ marker = $marker; file = [IO.Path]::GetRelativePath($resolved, $file.FullName); line = $i + 1 })
            }
        }
    }
}

$globalJson = $projectFilesAndConfiguration | Where-Object Name -eq 'global.json' | Select-Object -First 1
$global = $null
if ($globalJson) {
    try { $global = Get-Content -LiteralPath $globalJson.FullName -Raw | ConvertFrom-Json }
    catch { $warnings.Add("Could not parse global.json: $($_.Exception.Message)") }
}

$git = $null
try {
    $topLevel = & git -C $resolved rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0) {
        $git = [pscustomobject]@{ root = $topLevel; commit = (& git -C $resolved rev-parse HEAD 2>$null | Select-Object -First 1); branch = (& git -C $resolved branch --show-current 2>$null | Select-Object -First 1) }
    }
    else { $warnings.Add('Git identity unavailable: path is not a Git repository.') }
}
catch { $warnings.Add("Git identity unavailable: $($_.Exception.Message)") }

$sdkProbe = Invoke-CommandProbe -Name dotnet -Arguments @('--version')
$runtimeProbe = Invoke-CommandProbe -Name dotnet -Arguments @('--list-runtimes')
$dotnet = Get-ToolEvidence -Name dotnet -Probe $sdkProbe
$sdkVersion = if ($sdkProbe.exitCode -eq 0) { @($sdkProbe.output | Select-Object -First 1)[0] } else { $null }
$runtime = @($runtimeProbe.output)
if ($sdkProbe.reason) { $warnings.Add("Could not read dotnet SDK version: $($sdkProbe.reason)") }
if ($runtimeProbe.reason) { $warnings.Add("Could not list dotnet runtimes: $($runtimeProbe.reason)") }
$stoppingConditions = @()
if (-not $projectScanComplete) { $stoppingConditions += 'Project inventory is incomplete; stop before selecting measurement depth.' }
# $sourceScanComplete was computed and discarded. Truncation is the NORMAL case here --
# the source scan stops at 64 files and 64 directories -- so "no BenchmarkDotNet
# configuration found" routinely meant "stopped at 64 files" with nothing saying so.
if (-not $sourceScanComplete) { $stoppingConditions += 'Source-marker scan is incomplete; absent markers are unread, not proven absent.' }

[pscustomobject]@{
    schemaVersion = 1
    repositoryPath = $resolved
    git = $git
    sdk = [pscustomobject]@{ globalJson = if ($global -and $global.PSObject.Properties['sdk']) { $global.sdk } else { $null }; installedVersion = $sdkVersion }
    runtime = @($runtime)
    probes = [pscustomobject]@{ sdk = $sdkProbe; runtime = $runtimeProbe }
    solutions = @($projectFilesAndConfiguration | Where-Object { $_.Extension -in '.sln', '.slnx' } | ForEach-Object { [IO.Path]::GetRelativePath($resolved, $_.FullName) })
    targetFrameworks = @($frameworks)
    projects = @($projects)
    testProjects = @($tests)
    benchmarkProjects = @($benchmarks)
    benchmarkConfiguration = @($sourceFiles | Where-Object { $_.Length -le $maxSourceBytes } | ForEach-Object {
        $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match '\b(ManualConfig|IConfig|SimpleJob|MemoryDiagnoser)\b') {
            [pscustomobject]@{ file = [IO.Path]::GetRelativePath($resolved, $_.FullName); kind = 'source' }
        }
    })
    benchmarkArtifacts = @($projectFilesAndConfiguration | Where-Object { $_.Name -match '(?i)benchmark.*\.(json|md)$|\.benchmarks\.json$' } | ForEach-Object { [IO.Path]::GetRelativePath($resolved, $_.FullName) })
    markers = @($markers)
    tools = @($dotnet, (Get-ToolEvidence dotnet-trace), (Get-ToolEvidence dotnet-counters), (Get-ToolEvidence perfcollect), (Get-ToolEvidence perf), (Get-ToolEvidence wpr), (Get-ToolEvidence xperf))
    projectInventoryComplete = $projectScanComplete
    sourceInventoryComplete = $sourceScanComplete
    stoppingConditions = $stoppingConditions
    completeness = if ($warnings.Count) { 'partial' } else { 'complete' }
    warnings = @($warnings)
} | ConvertTo-Json -Depth 8 -Compress
