#Requires -Version 7
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path $PSScriptRoot -Parent
$inventory = Join-Path $skillRoot 'scripts/inventory-dotnet-analysis.ps1'
$tokens = $null
$parseErrors = $null
$inventoryAst = [System.Management.Automation.Language.Parser]::ParseFile($inventory, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$fingerprintFunction = $inventoryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ContentFingerprint' }, $true) | Select-Object -First 1
if ($null -eq $fingerprintFunction) { throw 'Get-ContentFingerprint was not found.' }
. ([scriptblock]::Create($fingerprintFunction.Extent.Text))
$mutationFunction = $inventoryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-MutationState' }, $true) | Select-Object -First 1
if ($null -eq $mutationFunction) { throw 'Get-MutationState was not found.' }
. ([scriptblock]::Create($mutationFunction.Extent.Text))
$sameStatus = [pscustomobject]@{ Success = $true; Status = @(' M file.txt') }
$otherStatus = [pscustomobject]@{ Success = $true; Status = @(' D file.txt') }
if ($null -ne (Get-MutationState $sameStatus $sameStatus $null $null)) { throw 'Unknown fingerprints with unchanged Git status must remain Unknown.' }
if ((Get-MutationState $sameStatus $otherStatus $null $null) -ne $true) { throw 'An observed Git status change must remain Changed even if fingerprints are unavailable.' }
if ((Get-MutationState $sameStatus $sameStatus 'same' 'same') -ne $false) { throw 'Matching available evidence must remain Unchanged.' }
if ((Get-MutationState $sameStatus $sameStatus 'before' 'after') -ne $true) { throw 'Different available fingerprints must be Changed.' }
function Invoke-FixtureGit {
    $output = & git @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture git command failed (exit $LASTEXITCODE): $output" }
    return $output
}
$tempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) "audit-dotnet-evidence-$([guid]::NewGuid())"))
$oldPackages = $env:NUGET_PACKAGES

try {
    $fingerprintRepo = Join-Path $tempRoot 'fingerprint-repo'
    New-Item -ItemType Directory -Path $fingerprintRepo -Force | Out-Null
    $null = Invoke-FixtureGit -C $fingerprintRepo init --quiet
    $null = Invoke-FixtureGit -C $fingerprintRepo config user.email fixture@example.com
    $null = Invoke-FixtureGit -C $fingerprintRepo config user.name Fixture
    $fingerprintFile = Join-Path $fingerprintRepo 'tracked.txt'
    [IO.File]::WriteAllText($fingerprintFile, 'baseline')
    $null = Invoke-FixtureGit -C $fingerprintRepo add tracked.txt
    $null = Invoke-FixtureGit -C $fingerprintRepo -c commit.gpgsign=false commit --quiet -m baseline
    [IO.File]::WriteAllText($fingerprintFile, 'changed A')
    $null = Invoke-FixtureGit -C $fingerprintRepo add tracked.txt
    $statusA = Invoke-FixtureGit -C $fingerprintRepo status --porcelain
    $fingerprintA = Get-ContentFingerprint -Repo $fingerprintRepo
    [IO.File]::WriteAllText($fingerprintFile, 'changed B')
    $null = Invoke-FixtureGit -C $fingerprintRepo add tracked.txt
    $statusB = Invoke-FixtureGit -C $fingerprintRepo status --porcelain
    $fingerprintB = Get-ContentFingerprint -Repo $fingerprintRepo
    if (($statusA -join "`n") -ne ($statusB -join "`n") -or $fingerprintA -ceq $fingerprintB) {
        throw 'Content fingerprint must detect changed bytes when Git status text is unchanged.'
    }
    $deletedPath = Join-Path $fingerprintRepo 'zz-deleted.txt'
    [IO.File]::WriteAllText($deletedPath, 'gone')
    $null = Invoke-FixtureGit -C $fingerprintRepo add zz-deleted.txt
    Remove-Item -LiteralPath $deletedPath -Force
    if ($null -ne (Get-ContentFingerprint -Repo $fingerprintRepo)) {
        throw 'A listed file that is missing after earlier files hashed must make the whole fingerprint null, not a partial array.'
    }
    $null = Invoke-FixtureGit -C $fingerprintRepo rm --cached --quiet zz-deleted.txt
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $newlinePath = Join-Path $fingerprintRepo "line`nbreak.txt"
        [IO.File]::WriteAllText($newlinePath, 'first')
        $null = Invoke-FixtureGit -C $fingerprintRepo add --all
        $newlineFingerprintA = Get-ContentFingerprint -Repo $fingerprintRepo
        [IO.File]::WriteAllText($newlinePath, 'second')
        $null = Invoke-FixtureGit -C $fingerprintRepo add --all
        $newlineFingerprintB = Get-ContentFingerprint -Repo $fingerprintRepo
        if ($newlineFingerprintA -ceq $newlineFingerprintB) {
            throw 'Content fingerprint must safely include Git paths containing newlines.'
        }
        Remove-Item -LiteralPath $newlinePath -Force
        if ($null -ne (Get-ContentFingerprint -Repo $fingerprintRepo)) {
            throw 'A listed Git path that cannot be hashed must make the fingerprint unknown.'
        }
    } else {
        Write-Host 'SKIP: Windows filesystems do not allow newline characters in file names.'
    }

    New-Item -ItemType Directory -Path (Join-Path $tempRoot '.git'), (Join-Path $tempRoot 'src') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tempRoot 'Directory.Build.props') -Value '<Project><PropertyGroup>'
    Set-Content -LiteralPath (Join-Path $tempRoot 'src/Test.csproj') -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="Broken.Analyzer" Version="1.0.0" />
  </ItemGroup>
</Project>
'@

    $env:NUGET_PACKAGES = Join-Path $tempRoot 'packages'
    $packageRoot = Join-Path $env:NUGET_PACKAGES 'broken.analyzer/1.0.0'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $packageRoot 'broken.analyzer.nuspec') -Value '<package><metadata>'

    $result = & $inventory -Path $tempRoot | ConvertFrom-Json
    $repo = $result.Repositories[0]

    foreach ($probeName in 'GitStatusBefore', 'GitStatusAfter') {
        $probe = $repo.$probeName
        if ($probe.Success -ne $false -or $probe.ExitCode -eq 0 -or [string]::IsNullOrWhiteSpace($probe.Error)) {
            throw "$probeName must preserve failed Git evidence with success, exit code, and error."
        }
        if ($null -eq $probe.Status) {
            throw "$probeName must expose a Status field even when the probe fails."
        }
    }
    if ($null -ne $repo.Mutated -or $repo.MutationState -ne 'Unknown') {
        throw 'Mutation must remain unknown when either Git status probe fails.'
    }

    $parseErrors = @($repo.ParseErrors)
    if ($parseErrors.Count -ne 2) {
        throw "Expected project XML and nuspec parse errors; got $($parseErrors.Count)."
    }
    foreach ($errorRecord in $parseErrors) {
        if ([string]::IsNullOrWhiteSpace($errorRecord.Path) -or [string]::IsNullOrWhiteSpace($errorRecord.Error)) {
            throw 'Every parse error must retain its path and error.'
        }
    }
    if (-not (@($parseErrors.Kind) -contains 'ProjectXml') -or -not (@($parseErrors.Kind) -contains 'NuspecXml')) {
        throw "Expected ProjectXml and NuspecXml gaps; got $(@($parseErrors.Kind) -join ', ')."
    }

    $brokenAnalyzer = @($repo.BundledAnalyzers | Where-Object Id -eq 'Broken.Analyzer')
    if ($brokenAnalyzer.Count -ne 1) {
        throw "Expected one Broken.Analyzer result; got $($brokenAnalyzer.Count)."
    }
    if ($null -ne $brokenAnalyzer[0].Dependencies) {
        throw 'Malformed nuspec dependencies must remain unknown, not become an empty list.'
    }

    Write-Host 'Evidence-gap verification passed.'
}
finally {
    $env:NUGET_PACKAGES = $oldPackages
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
