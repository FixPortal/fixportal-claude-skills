#Requires -Version 7
<#
.SYNOPSIS
    Read-only inventory of effective .NET analyzer and code-style configuration.

.DESCRIPTION
    Deterministic sweep for the audit-dotnet-analyzers skill. Emits JSON describing
    SDK selection, target frameworks, language version, analyzer packages (including
    analyzers bundled inside shared CodeStyle packages), the config-file hierarchy,
    and the warnings-as-errors policy.

    READ-ONLY. Writes nothing inside the audited repository. Captures `git status`
    so the caller can prove nothing mutated.

    It reports raw facts. It does not resolve effective severity or judge findings —
    that is the agent's job, and it needs the real overload/provenance evidence the
    skill demands.

.PARAMETER Path
    Repository root, or a workspace folder containing several repos.

.PARAMETER Workspace
    Treat Path as a workspace: discover every git repo beneath it and inventory each.

.EXAMPLE
    ./inventory-dotnet-analysis.ps1 -Path '<estate-root>\<repo>'

.EXAMPLE
    ./inventory-dotnet-analysis.ps1 -Path '<estate-root>' -Workspace | Out-File audit.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Path,

    [switch] $Workspace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Properties whose values decide whether a diagnostic can break a build.
$PolicyProperties = @(
    'TargetFramework', 'TargetFrameworks', 'LangVersion', 'Nullable',
    'TreatWarningsAsErrors', 'WarningsAsErrors', 'WarningsNotAsErrors', 'NoWarn',
    'AnalysisLevel', 'AnalysisMode', 'EnableNETAnalyzers', 'EnforceCodeStyleInBuild'
)

$ProjectFilePattern = '\.(csproj|fsproj|props|targets)$'

$ConfigFileNames = @(
    '.editorconfig', 'global.json', 'NuGet.config', 'nuget.config',
    'Directory.Build.props', 'Directory.Build.targets',
    'Directory.Packages.props', 'Directory.Build.rsp', 'packages.lock.json'
)

function Get-NuGetGlobalPackagesFolder {
    <# The global packages folder is NOT always ~/.nuget/packages. It is overridable by
       the NUGET_PACKAGES environment variable and by `globalPackagesFolder` in a
       NuGet.config -- both common in CI. Getting this wrong makes Get-BundledAnalyzers
       silently report CacheHit=$false, which hides bundled analyzers entirely and drops
       the caller into the very attribution trap this skill exists to catch.

       NuGet.config resolution is DIRECTORY-SENSITIVE: `dotnet` walks up from its working
       directory. So this MUST be called with the working directory set to the repo being
       inventoried -- resolving once from the script's own cwd and reusing that for every
       repo would silently ignore a repo-local globalPackagesFolder. Callers push into the
       repo first. #>
    try {
        $output = & dotnet nuget locals global-packages --list 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            # Format: "global-packages: <user-profile>\.nuget\packages"
            $match = $output | Select-String -Pattern 'global-packages:\s*(.+)$' | Select-Object -First 1
            if ($match) {
                $candidate = $match.Matches[0].Groups[1].Value.Trim()
                if ($candidate) { return $candidate }
            }
        }
        Write-Verbose "dotnet nuget locals returned no usable path (exit $LASTEXITCODE); falling back."
    }
    catch {
        # Never swallow this silently: a wrong cache root makes bundled analyzers
        # invisible, which is the exact failure this function exists to prevent.
        Write-Verbose "dotnet nuget locals failed: $($_.Exception.Message). Falling back."
    }

    if ($env:NUGET_PACKAGES) { return $env:NUGET_PACKAGES }
    return (Join-Path $HOME '.nuget/packages')
}

function Get-Tree {
    <# ONE recursive walk, pruned as it goes. Build output and vendored trees are dropped
       during the walk rather than after it, so a large workspace is neither materialised
       nor re-filtered. `.git` entries themselves are KEPT -- they are how repo roots are
       discovered -- but their contents are not.

       The exclusion is tested against the path RELATIVE to $Root, never the absolute
       path. An absolute-path match would prune everything the moment the scanned path
       itself sat under a segment named `bin`, `obj` or `node_modules` (<workdir>\build\bin\repos),
       yielding a silently empty inventory -- the exact quiet failure this skill exists to
       prevent. #>
    param([string] $Root, [System.Collections.Generic.List[string]] $Unreadable)

    $excluded = '(^|[\\/])(obj|bin|node_modules|\.git)([\\/]|$)'
    $items = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($Root)

    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        # -ErrorAction SilentlyContinue alone made an UNREADABLE directory (permissions, a
        # broken junction, a path over MAX_PATH) indistinguishable from an EMPTY one, so an
        # unread subtree reported as "no analyzer configuration found" - an observation the
        # walk never actually made. Errors are captured and surfaced, not swallowed.
        $walkErrors = $null
        $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue -ErrorVariable walkErrors)
        foreach ($e in @($walkErrors)) {
            # TargetObject is only trusted when it is already a plain string. Depending on
            # the error it can be a FileSystemInfo, a child item, or null - all truthy or
            # unhelpful - so a bare [string] cast would record a stringified object in
            # UnreadablePaths instead of a path. $directory is always the thing that
            # actually failed to enumerate.
            $path = if ($e.TargetObject -is [string] -and $e.TargetObject) { $e.TargetObject } else { $directory }
            if ($null -ne $Unreadable -and -not $Unreadable.Contains($path)) { $Unreadable.Add($path) }
        }
        foreach ($entry in $children) {
            # Keep the marker so repo discovery works, but never traverse git internals.
            if ($entry.Name -eq '.git') {
                $items.Add($entry)
                continue
            }

            $relative = [IO.Path]::GetRelativePath($Root, $entry.FullName)
            if ($relative -match $excluded) { continue }

            $items.Add($entry)
            if ($entry.PSIsContainer -and -not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending.Enqueue($entry.FullName)
            }
        }
    }

    return @($items)
}

function Get-RepoRootsFromTree {
    <# A repo root is any directory containing `.git`. That `.git` is a DIRECTORY in a
       normal clone but a FILE (a gitdir pointer) in a submodule or a linked worktree,
       so do not filter to directories only. #>
    param([object[]] $Tree)

    return @(
        $Tree |
            Where-Object { $_.Name -eq '.git' } |
            ForEach-Object { $_.PSParentPath -replace '^.*::', '' } |
            Sort-Object -Unique
    )
}

function Group-FilesByOwningRepo {
    <# Assign each file to the DEEPEST repo root that contains it, in a single pass.

       Deepest-root ownership IS the nested-repository boundary rule: a file inside a
       submodule or linked worktree belongs to that child, never to the parent. Doing it
       once here (rather than re-scanning the whole tree per repo) keeps a workspace run
       linear in file count instead of O(repos x files). #>
    param([object[]] $Tree, [string[]] $RepoRoots)

    $sep = [IO.Path]::DirectorySeparatorChar

    # Longest prefix first, so the first match is the deepest owning repo.
    $ordered = @($RepoRoots | Sort-Object -Property Length -Descending |
                 ForEach-Object { [pscustomobject]@{ Root = $_; Prefix = $_.TrimEnd($sep) + $sep } })

    $byRepo = @{}
    foreach ($root in $RepoRoots) { $byRepo[$root] = [System.Collections.Generic.List[object]]::new() }

    foreach ($item in $Tree) {
        if ($item.PSIsContainer -or $item.Name -eq '.git') { continue }
        $full = $item.FullName
        foreach ($candidate in $ordered) {
            if ($full.StartsWith($candidate.Prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $byRepo[$candidate.Root].Add($item)
                break
            }
        }
    }
    return $byRepo
}

function Get-ProjectDocuments {
    <# Enumerate and parse each project/props/targets file ONCE. Package references and
       policy properties are both read from this single parsed set, rather than each
       walking (and re-parsing) the whole tree independently. #>
    param(
        [object[]] $Files,
        [string] $Repo,
        # Mandatory: both are accumulators the caller reads back, and an omitted one is
        # $null, on which the .Add() calls below throw mid-scan under
        # ErrorActionPreference = Stop - a run-ending fault at the point where a single
        # unreadable file was supposed to be recorded and skipped. Every call site passes
        # one today; this is what keeps that true.
        # AllowEmptyCollection is REQUIRED alongside Mandatory here: Mandatory alone
        # rejects an empty list, and an empty accumulator is the normal starting state -
        # binding failed on the first call of a clean run.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $ParseErrors,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $UnreadableFiles
    )

    $docs = [System.Collections.Generic.List[object]]::new()
    foreach ($file in ($Files | Where-Object { $_.Name -match $ProjectFilePattern })) {
        $relative = [IO.Path]::GetRelativePath($Repo, $file.FullName)
        try { $content = Get-Content -LiteralPath $file.FullName -Raw }
        catch {
            $UnreadableFiles.Add([pscustomobject]@{ Path = $relative; Error = $_.Exception.Message })
            Write-Warning "Could not read '$($file.FullName)': $($_.Exception.Message)"
            continue
        }
        # Get-Content -Raw on an EMPTY file yields $null, and `[xml] $xml = $null` does
        # not throw -- so a zero-byte placeholder entered $docs with Xml = $null and
        # Get-PackageRefs then called a method on it under ErrorActionPreference = Stop,
        # killing the whole inventory for every repo in a workspace run. One unparseable
        # file is one ProjectXml error, not a run-ending fault.
        if ([string]::IsNullOrWhiteSpace($content)) {
            $ParseErrors.Add([pscustomobject]@{ Kind = 'ProjectXml'; Path = $relative; Error = 'File is empty or whitespace-only.' })
            Write-Warning "Could not parse '$($file.FullName)': file is empty or whitespace-only."
            continue
        }
        try { [xml] $xml = $content }
        catch {
            $ParseErrors.Add([pscustomobject]@{ Kind = 'ProjectXml'; Path = $relative; Error = $_.Exception.Message })
            Write-Warning "Could not parse '$($file.FullName)': $($_.Exception.Message)"
            continue
        }
        $docs.Add([pscustomobject]@{
            Xml      = $xml
            Relative = $relative
        })
    }
    return $docs
}

function Get-PackageRefs {
    param([object[]] $Documents)

    $refs = [System.Collections.Generic.List[object]]::new()
    foreach ($doc in $Documents) {
        foreach ($kind in 'PackageReference', 'PackageVersion', 'GlobalPackageReference') {
            foreach ($node in $doc.Xml.SelectNodes("//*[local-name()='$kind']")) {
                # Update= matters as much as Include=: under Central Package Management a
                # `PackageReference Update="X" Version="..."` is a version override, and
                # reading Include alone would make those overrides invisible.
                $id = $node.GetAttribute('Include')
                if (-not $id) { $id = $node.GetAttribute('Update') }
                if (-not $id) { continue }
                $refs.Add([pscustomobject]@{
                    Kind    = $kind
                    Id      = $id
                    Version = $node.GetAttribute('Version')
                    File    = $doc.Relative
                })
            }
        }
    }
    return $refs
}

function Get-PolicyProperties {
    param([object[]] $Documents)

    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($doc in $Documents) {
        foreach ($prop in $PolicyProperties) {
            foreach ($node in $doc.Xml.SelectNodes("//*[local-name()='PropertyGroup']/*[local-name()='$prop']")) {
                $found.Add([pscustomobject]@{
                    Property = $prop
                    Value    = $node.InnerText
                    File     = $doc.Relative
                })
            }
        }
    }
    return $found
}

function Get-BundledAnalyzers {
    <# A shared CodeStyle package can ship SonarAnalyzer plus a global AnalyzerConfig.
       Grepping the repo will never reveal this. Look inside the cached package. #>
    param(
        [string] $Id,
        [string] $Version,
        [string] $CacheFolder,
        # Mandatory: both are accumulators the caller reads back, and an omitted one is
        # $null, on which the .Add() calls below throw mid-scan under
        # ErrorActionPreference = Stop - a run-ending fault at the point where a single
        # unreadable file was supposed to be recorded and skipped. Every call site passes
        # one today; this is what keeps that true.
        # AllowEmptyCollection is REQUIRED alongside Mandatory here: Mandatory alone
        # rejects an empty list, and an empty accumulator is the normal starting state -
        # binding failed on the first call of a clean run.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $ParseErrors,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $UnreadableFiles
    )

    $root = Join-Path $CacheFolder (Join-Path $Id.ToLowerInvariant() $Version)
    if (-not (Test-Path -LiteralPath $root)) {
        # ONE shape for both arms. The miss arm used to carry `CacheRoot` and neither
        # `Dependencies` nor `ShippedConfig`, so a consumer reading `.Dependencies` got
        # $null on a miss and an array on a hit - and $null and an empty array are the
        # same thing to `if (...)` and to `.Count` only by accident. Absent on a miss is
        # UNKNOWN, which is what $null says here, but the KEY has to exist so a reader
        # never has to tell "absent" from "not applicable" by probing for the property.
        return [pscustomobject]@{
            Id            = $Id
            Version       = $Version
            CacheHit      = $false
            CachePath     = $null
            CacheRoot     = $CacheFolder
            Dependencies  = $null
            ShippedConfig = $null
        }
    }

    $deps = @()
    $nuspec = Get-ChildItem -LiteralPath $root -Filter '*.nuspec' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nuspec) {
        try {
            $content = Get-Content -LiteralPath $nuspec.FullName -Raw
        }
        catch {
            $UnreadableFiles.Add([pscustomobject]@{ Path = $nuspec.FullName; Error = $_.Exception.Message })
            Write-Warning "Could not read '$($nuspec.FullName)': $($_.Exception.Message)"
            $content = $null
        }
        try {
            if ($null -eq $content) { throw 'Nuspec content was not read.' }
            [xml] $x = $content
            $deps = @($x.SelectNodes("//*[local-name()='dependency']") | ForEach-Object {
                [pscustomobject]@{ Id = $_.GetAttribute('id'); Version = $_.GetAttribute('version') }
            })
        }
        catch {
            if ($null -ne $content) {
                $ParseErrors.Add([pscustomobject]@{ Kind = 'NuspecXml'; Path = $nuspec.FullName; Error = $_.Exception.Message })
                Write-Warning "Could not parse '$($nuspec.FullName)': $($_.Exception.Message)"
            }
            $deps = $null
        }
    }

    $configs = @(
        Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.globalconfig', '.editorconfig' } |
            ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName) }
    )

    return [pscustomobject]@{
        Id            = $Id
        Version       = $Version
        CacheHit      = $true
        CachePath     = $root
        CacheRoot     = $CacheFolder
        Dependencies  = $deps
        ShippedConfig = $configs
    }
}

function Get-GitStatus {
    param([string] $Repo)
    # stderr goes to a FILE, not `2>&1`. Merging the streams put git's diagnostics into
    # $output, and on a SUCCESSFUL run every warning line ("warning: LF will be replaced
    # by CRLF...") then became a porcelain entry - a repo with no modifications read as
    # dirty, which is enough to flip Mutated to Changed on evidence git never reported.
    # `$message`, not `$error`: assigning $error inside a function shadows the automatic
    # error variable for the whole scope, so any later `$error[0]` here would read this
    # string instead of the last error record. (Checked: PowerShell does allow the
    # assignment - `pwsh -NoProfile -c 'function f { $error = "x"; $error }; f'` prints x -
    # so the hazard is shadowing, not a failure at the assignment.)
    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        $output = @(& git -C $Repo status --porcelain 2>$stderrPath)
        $exitCode = $LASTEXITCODE
        $stderrText = ''
        if (Test-Path -LiteralPath $stderrPath) {
            # An empty stderr file reads back as $null, and `([string]$null).Trim()` throws
            # - which turned every successful, silent `git status` into a failed probe.
            $stderrRaw = Get-Content -LiteralPath $stderrPath -Raw
            if ($stderrRaw) { $stderrText = $stderrRaw.Trim() }
        }
        if ($exitCode -ne 0) {
            $message = $stderrText
            if (-not $message) { $message = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim() }
            if (-not $message) { $message = "git status exited with code $exitCode." }
            return [pscustomobject]@{
                Success  = $false
                Status   = @()
                ExitCode = $exitCode
                Error    = $message
            }
        }
        return [pscustomobject]@{
            Success  = $true
            Status   = @($output | ForEach-Object { $_.ToString() })
            ExitCode = 0
            # A warning on a successful run is not a failure and must not empty Status,
            # but it is not nothing either - carried so a caller can report it.
            Error    = if ($stderrText) { $stderrText } else { $null }
        }
    }
    catch {
        return [pscustomobject]@{
            Success  = $false
            Status   = @()
            ExitCode = -1
            Error    = $_.Exception.Message
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-ContentFingerprint {
    param([string] $Repo)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-C', $Repo, 'ls-files', '-z', '--cached', '--others', '--exclude-standard')) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $process) { return $null }
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $pathStream = [IO.MemoryStream]::new()
        try {
            $process.StandardOutput.BaseStream.CopyTo($pathStream)
            $process.WaitForExit()
            $null = $stderrTask.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { return $null }
            $pathText = [Text.Encoding]::UTF8.GetString($pathStream.ToArray())
        }
        finally { $pathStream.Dispose() }
    }
    finally { $process.Dispose() }
    $paths = @($pathText.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique)
    $records = foreach ($path in $paths) {
        $file = Join-Path $Repo $path
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
        try { $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash }
        catch { return $null }
        "$path`0$hash`0"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($records -join ''))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash($bytes)) }
    finally { $sha.Dispose() }
}

function Get-MutationState {
    param($Before, $After, $BeforeFingerprint, $AfterFingerprint)
    if (-not $Before.Success -or -not $After.Success) { return $null }
    if (($Before.Status -join "`n") -ne ($After.Status -join "`n")) { return $true }
    if ($null -eq $BeforeFingerprint -or $null -eq $AfterFingerprint) { return $null }
    return ($BeforeFingerprint -cne $AfterFingerprint)
}

function Get-RepoInventory {
    param([object[]] $Files, [string] $Repo)

    $before = Get-GitStatus -Repo $Repo
    $beforeFingerprint = Get-ContentFingerprint -Repo $Repo
    $parseErrors = [System.Collections.Generic.List[object]]::new()
    $unreadableFiles = [System.Collections.Generic.List[object]]::new()

    # Both `dotnet` calls must run FROM the repo: NuGet.config and global.json are
    # resolved by walking up from the working directory, so a repo-local
    # globalPackagesFolder or SDK pin is only honoured if we are standing in the repo.
    $cacheFolder = $null
    $sdk         = $null

    # Push OUTSIDE the try: if Push-Location itself fails there is nothing to pop, and a
    # Pop-Location in `finally` would unwind someone else's location instead.
    Push-Location $Repo
    try {
        $cacheFolder = Get-NuGetGlobalPackagesFolder
        $sdk = (& dotnet --version 2>$null)
        if ($LASTEXITCODE -ne 0) { $sdk = $null }
    }
    catch {
        # Same rule as Get-NuGetGlobalPackagesFolder: never swallow this silently. A null
        # SDK or cache root is a reportable gap in the evidence, not a shrug.
        Write-Verbose "SDK/cache probe failed in '$Repo': $($_.Exception.Message)"
    }
    finally { Pop-Location }

    $configFiles = @(
        $files |
            Where-Object { $_.Name -in $ConfigFileNames -or $_.Extension -in '.globalconfig', '.ruleset' } |
            ForEach-Object { [IO.Path]::GetRelativePath($Repo, $_.FullName) }
    )

    $documents = Get-ProjectDocuments -Files $files -Repo $Repo -ParseErrors $parseErrors -UnreadableFiles $unreadableFiles
    $refs      = Get-PackageRefs -Documents $documents

    # Anything that plausibly ships analyzers, plus every GlobalPackageReference:
    # a shared style package is the usual carrier and rarely name-matches.
    $analyzerish = @($refs | Where-Object {
        $_.Kind -eq 'GlobalPackageReference' -or
        $_.Id -match '(?i)analyz|sonar|stylecop|roslynator|meziantou|codestyle'
    })

    $bundled = @(
        $analyzerish |
            Where-Object { $_.Version } |
            Sort-Object Id, Version -Unique |
            ForEach-Object {
                Get-BundledAnalyzers -Id $_.Id -Version $_.Version -CacheFolder $CacheFolder `
                    -ParseErrors $parseErrors -UnreadableFiles $unreadableFiles
            }
    )

    $after = Get-GitStatus -Repo $Repo
    $afterFingerprint = Get-ContentFingerprint -Repo $Repo
    $mutated = Get-MutationState -Before $before -After $after `
        -BeforeFingerprint $beforeFingerprint -AfterFingerprint $afterFingerprint

    return [pscustomobject]@{
        Repository          = $Repo
        SelectedSdk         = $sdk
        NuGetGlobalPackages = $cacheFolder
        ConfigFiles         = $configFiles
        PolicyProperties    = Get-PolicyProperties -Documents $documents
        AnalyzerPackages    = $analyzerish
        BundledAnalyzers    = $bundled
        AllPackageRefs      = $refs
        ParseErrors         = @($parseErrors)
        UnreadableFiles     = @($unreadableFiles)
        GitStatusBefore     = $before
        GitStatusAfter      = $after
        ContentFingerprintBefore = $beforeFingerprint
        ContentFingerprintAfter  = $afterFingerprint
        Mutated             = $mutated
        MutationState       = if ($null -eq $mutated) { 'Unknown' } elseif ($mutated) { 'Changed' } else { 'Unchanged' }
    }
}

$resolved = (Resolve-Path -LiteralPath $Path).Path

# Single pruned recursive walk; everything below is derived from it.
# $unreadable collects directories the walk could not enumerate, so "nothing found" can be
# told apart from "not looked at" downstream.
$unreadable = [System.Collections.Generic.List[string]]::new()
$tree = Get-Tree -Root $resolved -Unreadable $unreadable
foreach ($u in $unreadable) { Write-Warning "Could not enumerate '$u'; anything beneath it is UNSCANNED, not absent." }

# Every repo root under the scanned path. Needed even for a single-repo run, so a repo
# containing its own linked worktree or submodule does not absorb that child's config.
#
# Both operands MUST be wrapped in @(). A single-element result unrolls to a bare string,
# and `<string> + <string>` is CONCATENATION, not array append -- which silently produced
# one nonsense key ("<path><path>") and an empty inventory for every repo that had no
# nested worktree.
$allRoots = @(
    @(Get-RepoRootsFromTree -Tree $tree) + @($resolved) | Sort-Object -Unique
)

# One pass to assign every file to its deepest owning repo.
$filesByRepo = Group-FilesByOwningRepo -Tree $tree -RepoRoots $allRoots

# Wrap in @(): PowerShell unrolls a single-element array assigned from an `if`.
$repos = @(
    if ($Workspace) { Get-RepoRootsFromTree -Tree $tree }
    else { $resolved }
)

if (-not $repos) { throw "No repository found under '$resolved'." }

$result = [pscustomobject]@{
    ScannedPath  = $resolved
    WorkspaceRun = [bool] $Workspace
    # Non-empty means part of the tree was never read. A consumer must not report this
    # inventory as complete while it has entries.
    UnreadablePaths = @($unreadable)
    RepoCount    = $repos.Count
    Repositories = @(
        $repos | ForEach-Object {
            $owned = if ($filesByRepo.ContainsKey($_)) { @($filesByRepo[$_]) } else { @() }
            Get-RepoInventory -Files $owned -Repo $_
        }
    )
}

$result | ConvertTo-Json -Depth 8
