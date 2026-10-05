#Requires -Version 7
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path $PSScriptRoot -Parent
$inventory = Join-Path $skillRoot 'scripts/inventory-dotnet-analysis.ps1'
# Extract Get-Tree via the AST, not a regex window. `(?s)function Get-Tree \{.*?\n\}`
# stops at the first line beginning with '}' in column 0, so it only ever worked because
# every internal brace happened to be indented: reformat the function, or put a closing
# brace at column 0 inside it (a here-string, a nested scriptblock), and the window either
# truncates - hiding a -Recurse that IS there - or swallows the rest of the file. A guard
# whose scope depends on formatting is not a guard.
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($inventory, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "inventory-dotnet-analysis.ps1 does not parse: $($parseErrors[0].Message)" }
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-Tree' }, $true)
if (-not $fn) { throw 'Get-Tree function not found in inventory-dotnet-analysis.ps1' }
$getTree = $fn.Extent.Text
if ($getTree -match 'Get-ChildItem[^\r\n]*-Recurse') {
    throw 'Get-Tree must prune excluded directories before descent.'
}

$tempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) "audit-dotnet-prune-$([guid]::NewGuid())"))
if (-not $tempRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unsafe temporary path: $tempRoot"
}

try {
    New-Item -ItemType Directory -Path (Join-Path $tempRoot '.git'), (Join-Path $tempRoot 'node_modules/ignored') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tempRoot 'Directory.Build.props') -Value '<Project><PropertyGroup><LangVersion>latest</LangVersion></PropertyGroup></Project>'
    Set-Content -LiteralPath (Join-Path $tempRoot 'node_modules/ignored/Directory.Build.props') -Value '<Project><PropertyGroup><LangVersion>should-not-appear</LangVersion></PropertyGroup></Project>'

    $result = & $inventory -Path $tempRoot | ConvertFrom-Json
    $values = @($result.Repositories[0].PolicyProperties.Value)
    if ('latest' -notin $values -or 'should-not-appear' -in $values) {
        throw "Traversal did not prune node_modules before inventory: $($values -join ', ')"
    }

    # The fixture's .git is an empty directory, so `git status` FAILS there by design.
    $failedRepo = $result.Repositories[0]
    if ($failedRepo.GitStatusBefore.Success -ne $false -or $null -ne $failedRepo.Mutated -or $failedRepo.MutationState -ne 'Unknown') {
        throw 'A repo whose git status cannot be read must report a failed status probe and Mutated=$null / Unknown, never false proof.'
    }

    # A REAL clean repo: `git status --porcelain` exits 0 with NO output. That must read
    # as success (Mutated=false, Unchanged), not collapse into the failed-capture shape.
    # It also carries a Central Package Management override: `PackageReference Update=`
    # has no Include attribute, and reading Include alone made those overrides invisible.
    $cleanRepo = Join-Path $tempRoot 'clean-repo'
    New-Item -ItemType Directory -Path (Join-Path $cleanRepo 'src') | Out-Null
    git -C $cleanRepo init --quiet
    if ($LASTEXITCODE -ne 0) { throw "fixture git init failed (exit $LASTEXITCODE)" }
    git -C $cleanRepo config user.email 'fixture@example.test'
    git -C $cleanRepo config user.name 'Prune Fixture'
    Set-Content -LiteralPath (Join-Path $cleanRepo 'Directory.Build.props') -Value '<Project><PropertyGroup><LangVersion>latest</LangVersion></PropertyGroup></Project>'
    Set-Content -LiteralPath (Join-Path $cleanRepo 'src/App.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Update="Override.Analyzer" Version="2.0.0" /></ItemGroup></Project>'
    git -C $cleanRepo add --all
    if ($LASTEXITCODE -ne 0) { throw "fixture git add failed (exit $LASTEXITCODE)" }
    git -C $cleanRepo -c commit.gpgsign=false commit --quiet -m 'chore: fixture'
    if ($LASTEXITCODE -ne 0) { throw "fixture git commit failed (exit $LASTEXITCODE)" }

    $clean = (& $inventory -Path $cleanRepo 3>$null | ConvertFrom-Json).Repositories[0]
    if ($clean.GitStatusBefore.Success -ne $true) {
        throw 'A CLEAN repo must not report a failed git status probe - empty status output is success'
    }
    if ($clean.Mutated -ne $false -or $clean.MutationState -ne 'Unchanged') {
        throw "A clean repo must report Mutated=`$false / Unchanged, got '$($clean.Mutated)' / '$($clean.MutationState)'"
    }
    if ('Override.Analyzer' -notin @($clean.AllPackageRefs.Id)) {
        throw 'PackageReference Update= (Central Package Management override) must be inventoried'
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host 'Pruned traversal verification passed.'

# The inventory child runs git inside a fixture with an empty .git - asserted, not
# fatal. Clear its native status so a caller that checks $LASTEXITCODE after a PASS does
# not read the child's failure.
$global:LASTEXITCODE = 0
