$ErrorActionPreference = 'Stop'

$skillRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$skill = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'SKILL.md')
$reader = Join-Path $skillRoot 'scripts/get-editorconfig-assignment.ps1'
$planner = Join-Path $skillRoot 'scripts/get-remediation-plan.ps1'
$reportValidator = Join-Path $skillRoot 'scripts/test-estate-report.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dotnet-audit-contract-' + [guid]::NewGuid().ToString('N'))

function Assert-Equal($actual, $expected, [string] $because) {
    $actualText = @($actual) -join "`n"
    $expectedText = @($expected) -join "`n"
    if ($actualText -ne $expectedText) {
        throw "$because`nExpected: $expectedText`nActual: $actualText"
    }
}

function Assert-Fails([scriptblock] $Action, [string] $expectedPattern, [string] $because) {
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -match $expectedPattern) { return }
        throw "$because`nExpected error matching: $expectedPattern`nActual: $($_.Exception.Message)"
    }
    throw "$because`nExpected the action to fail."
}

try {
    if (-not (Test-Path -LiteralPath $reportValidator)) {
        throw 'The estate report publication validator is missing.'
    }

    $validReport = @'
---
title: Estate audit
---
> Orientation.

## Executive summary
Summary.

## Verdict distribution
Diagram.

## Scope and source-of-truth
Scope.

## Estate conformance matrix
| Repository | Test conformance | Performance audit coverage | Verdict |
|---|---|---|---|
| Sample | Pass | Freshness: Current; Depth: Measured; Harness: Retained | Compliant |

## Cross-estate findings
None.

## Per-repository evidence
Evidence.

## Remediation prompts
None.

## Audit actions ledger
Read-only.

## Appendix
Commands.
'@
    $validReportPath = Join-Path $tempRoot 'valid-report.md'
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Set-Content -LiteralPath $validReportPath -Value $validReport
    & $reportValidator -Path $validReportPath | Out-Null

    $missingCoveragePath = Join-Path $tempRoot 'missing-coverage.md'
    Set-Content -LiteralPath $missingCoveragePath -Value ($validReport -replace '; Depth: Measured', '')
    Assert-Fails { & $reportValidator -Path $missingCoveragePath | Out-Null } 'Depth' 'A report missing a performance coverage field must be rejected.'

    $blankCoveragePath = Join-Path $tempRoot 'blank-coverage.md'
    Set-Content -LiteralPath $blankCoveragePath -Value ($validReport -replace 'Freshness: Current; Depth: Measured; Harness: Retained', '')
    Assert-Fails { & $reportValidator -Path $blankCoveragePath | Out-Null } 'Performance audit coverage.*Sample' 'A report with an empty performance coverage value must be rejected.'

    $dashDepthCurrentPath = Join-Path $tempRoot 'dash-depth-current.md'
    Set-Content -LiteralPath $dashDepthCurrentPath -Value ($validReport -replace 'Depth: Measured', 'Depth: —')
    Assert-Fails { & $reportValidator -Path $dashDepthCurrentPath | Out-Null } 'Performance audit coverage.*Sample' 'A Current or Stale manifest must declare a depth, not an em dash.'

    $notFoundCoveragePath = Join-Path $tempRoot 'not-found-coverage.md'
    Set-Content -LiteralPath $notFoundCoveragePath -Value ($validReport -replace 'Freshness: Current; Depth: Measured', 'Freshness: Not found; Depth: —')
    & $reportValidator -Path $notFoundCoveragePath | Out-Null

    $missingSectionPath =Join-Path $tempRoot 'missing-section.md'
    Set-Content -LiteralPath $missingSectionPath -Value ($validReport -replace '(?ms)^## Appendix\r?\n.*\z', '')
    Assert-Fails { & $reportValidator -Path $missingSectionPath | Out-Null } 'Appendix' 'A report missing a declared section must be rejected.'

    foreach ($requiredPerformanceCoverageContract in @(
        '### Performance audit coverage \(informational, non-graded\)',
        '(?s)Group pairs by the filename timestamp and\s+select the latest minute\. Validate every manifest in that minute; if any fails, classify\s+the coverage `Not assessed` without falling back\.',
        '(?s)select the greatest\s+`audit\.completedUtc`.*breaking an exact tie by ordinal full filename, then compare\s+`repository\.head` with the estate audit''s HEAD',
        '(?s)`Current`.*`Stale`.*`Not found`.*`Not assessed`',
        '(?s)`Audit freshness`.*`Audit depth`.*`Retained harness`',
        '(?s)schema v1.*`Legacy-unspecified`',
        '(?s)retained harness.*independently of audit freshness',
        '(?s)Performance audit coverage never changes a check result, repository verdict, finding, or\s+remediation prompt\.',
        '(?s)Never invoke `audit-dotnet-performance`, build, test, benchmark, or\s+profile to fill a coverage gap'
    )) {
        if ($skill -notmatch $requiredPerformanceCoverageContract) {
            throw "The estate report contract must match '$requiredPerformanceCoverageContract'."
        }
    }
    if ($skill -match 'user-overridden location') {
        throw 'The estate contract must not promise a performance-report location override that the source skill does not define.'
    }

    if ($skill -notmatch '(?s)`Fail` whose only defect is a GitHub\s+SETTING is a settings finding.*never\s+justifies an empty PR') {
        throw 'The estate contract must say a settings-only Fail is a settings finding and never justifies an empty PR.'
    }

    $sourceRoot = Join-Path $tempRoot 'src'
    $nestedRoot = Join-Path $sourceRoot 'Nested'
    New-Item -ItemType Directory -Path $nestedRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tempRoot 'Existing.sln') -Value 'Microsoft Visual Studio Solution File'
    $rootFile = Join-Path $tempRoot 'Root.cs'
    $sourceFile = Join-Path $sourceRoot 'Program.cs'
    $nestedFile = Join-Path $nestedRoot 'Nested.cs'
    Set-Content -LiteralPath $rootFile -Value 'class Root { }'
    Set-Content -LiteralPath $sourceFile -Value 'class Program { }'
    Set-Content -LiteralPath $nestedFile -Value 'class Nested { }'

    $editorConfig = Join-Path $tempRoot '.editorconfig'
    @'
root = true

[*.cs]
# Adding max_line_length = 120 would reformat the tree.
max_line_length = 100

[*.csproj]
max_line_length = 70

[*.cshtml]
max_line_length = 75

[*{.cs,.vb}]
indent_size = 4

[src/{Program,Other}.cs]
max_line_length = 120

[*.cs]
dotnet_diagnostic.IDE0055.severity = error
'@ | Set-Content -LiteralPath $editorConfig

    @'
[*.cs]
max_line_length = 90
'@ | Set-Content -LiteralPath (Join-Path $sourceRoot '.editorconfig')

    @'
[*.cs]
max_line_length = 80
'@ | Set-Content -LiteralPath (Join-Path $nestedRoot '.editorconfig')

    $sourceWidth = @(& $reader -Path $sourceFile -Key max_line_length)
    Assert-Equal $sourceWidth.Count 1 'A concrete C# file must resolve to one effective assignment.'
    Assert-Equal $sourceWidth[0].Value '90' 'A nearer EditorConfig must override parent sections.'

    $nestedWidth = @(& $reader -Path $nestedFile -Key max_line_length)
    Assert-Equal $nestedWidth.Count 1 'Nested precedence must resolve one effective assignment.'
    Assert-Equal $nestedWidth[0].Value '80' 'The nearest nested EditorConfig must win.'

    $rootWidth = @(& $reader -Path $rootFile -Key max_line_length)
    Assert-Equal $rootWidth.Count 1 'Prefix-collision sections must not apply to a C# file.'
    Assert-Equal $rootWidth[0].Value '100' '*.csproj and *.cshtml must not match Root.cs.'

    $indent = @(& $reader -Path $sourceFile -Key indent_size)
    Assert-Equal $indent.Count 1 'Brace globs must apply to a concrete C# file.'
    Assert-Equal $indent[0].Value '4' 'The brace-glob assignment must be returned.'

    $competingRule = @(& $reader -Path $sourceFile -Key dotnet_diagnostic.IDE0055.severity)
    Assert-Equal $competingRule.Count 1 'The CSharpier migration fixture must retain its separate analyzer finding.'
    Assert-Equal $competingRule[0].Value 'error' 'The separate finding must be collected independently of print width.'

    if (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'Existing.sln'))) {
        throw 'The existing .sln fixture must remain intact while collecting evidence.'
    }

    $slnxRoot = Join-Path $tempRoot 'slnx'
    New-Item -ItemType Directory -Path $slnxRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $slnxRoot 'Current.slnx') -Value '<Solution />'

    # A mid-migration repository: BOTH formats on disk, and CI builds the `.sln` whose path
    # carries a space. Presence detection alone answers 'slnx' here, so this fixture is the
    # one that fails if the workflow scan cannot read a quoted argument.
    $quotedRoot = Join-Path $tempRoot 'quoted'
    New-Item -ItemType Directory -Path (Join-Path $quotedRoot '.github/workflows') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $quotedRoot 'src') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $quotedRoot 'Current.slnx') -Value '<Solution />'
    Set-Content -LiteralPath (Join-Path $quotedRoot 'src/My App.sln') -Value ''
    Set-Content -LiteralPath (Join-Path $quotedRoot '.github/workflows/ci.yml') -Value @'
jobs:
  build:
    steps:
      - run: dotnet test "src/My App.sln" --configuration Release
'@

    $planCases = @(
        @{
            Name = 'quoted solution path with a space'
            Root = $quotedRoot
            MigrationAuthorized = $false
            WidthMigration = $false
            OtherFindings = $true
            ExpectedFormat = 'sln'
            ExpectedSolutionAction = 'PreserveExistingSln'
            ExpectedPrs = @('AllFindings')
        },
        @{
            Name = 'existing sln without authorized migration'
            Root = $tempRoot
            MigrationAuthorized = $false
            WidthMigration = $false
            OtherFindings = $true
            ExpectedSolutionAction = 'PreserveExistingSln'
            ExpectedPrs = @('AllFindings')
        },
        @{
            Name = 'existing sln with authorized migration'
            Root = $tempRoot
            MigrationAuthorized = $true
            WidthMigration = $false
            OtherFindings = $true
            ExpectedSolutionAction = 'MigrateToSlnx'
            ExpectedPrs = @('AllFindings')
        },
        @{
            Name = 'CSharpier migration plus another finding'
            Root = $slnxRoot
            MigrationAuthorized = $false
            WidthMigration = $true
            OtherFindings = $true
            ExpectedSolutionAction = 'PreserveSlnx'
            ExpectedPrs = @('CSharpierFormatting', 'RemainingFindings')
        },
        @{
            Name = 'CSharpier migration plus authorized solution migration'
            Root = $tempRoot
            MigrationAuthorized = $true
            WidthMigration = $true
            OtherFindings = $false
            ExpectedSolutionAction = 'MigrateToSlnx'
            ExpectedPrs = @('CSharpierFormatting', 'RemainingFindings')
        },
        @{
            Name = 'CSharpier migration only'
            Root = $slnxRoot
            MigrationAuthorized = $false
            WidthMigration = $true
            OtherFindings = $false
            ExpectedSolutionAction = 'PreserveSlnx'
            ExpectedPrs = @('CSharpierFormatting')
        },
        @{
            Name = 'non-formatting findings only'
            Root = $slnxRoot
            MigrationAuthorized = $false
            WidthMigration = $false
            OtherFindings = $true
            ExpectedSolutionAction = 'PreserveSlnx'
            ExpectedPrs = @('AllFindings')
        }
    )

    foreach ($case in $planCases) {
        # The format is what CI BUILDS, not whichever file happens to exist. A repository
        # mid-migration carries both a `.sln` and a `.slnx`, and choosing `slnx` on presence
        # alone hands the planner a format the pipeline does not use - so the remediation
        # action is computed for the wrong solution. Read the entry point; fall back to
        # presence only when no workflow names one. (CodeRabbit, PR #135.)
        $ciSolution = $null
        $workflowDir = Join-Path $case.Root '.github/workflows'
        if (Test-Path -LiteralPath $workflowDir -PathType Container) {
            foreach ($workflow in Get-ChildItem -LiteralPath $workflowDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' }) {
                # QUOTED PATHS COUNT. `\S+` cannot match `dotnet test "src/My App.sln"`, so a
                # solution whose path has a space fell through to presence detection - the
                # exact fallback this block exists to avoid, silently, on the repositories
                # most likely to be mid-migration. (CodeRabbit, PR #135.)
                $hit = [regex]::Match((Get-Content -LiteralPath $workflow.FullName -Raw), '(?i)\bdotnet\s+(?:build|test|restore)\s+(?<solution>"[^"\r\n]+\.slnx?"|''[^''\r\n]+\.slnx?''|\S+\.slnx?)(?=\s|$)')
                if ($hit.Success) { $ciSolution = $hit.Groups['solution'].Value.Trim('"', "'"); break }
            }
        }
        $format = if ($ciSolution) {
            if ($ciSolution -match '(?i)\.slnx$') { 'slnx' } else { 'sln' }
        } elseif (Get-ChildItem -LiteralPath $case.Root -Filter '*.slnx' -File) { 'slnx' } else { 'sln' }
        if ($case.ContainsKey('ExpectedFormat')) {
            Assert-Equal $format $case.ExpectedFormat "$($case.Name): the CI entry point's solution format was misread."
        }
        $plan = & $planner -SolutionFormat $format `
            -SolutionMigrationAuthorized $case.MigrationAuthorized `
            -CSharpierWidthMigration $case.WidthMigration `
            -HasOtherFindings $case.OtherFindings

        Assert-Equal $plan.SolutionAction $case.ExpectedSolutionAction "$($case.Name): wrong solution action."
        Assert-Equal @($plan.PullRequests.Purpose) $case.ExpectedPrs "$($case.Name): wrong remediation PR plan."
        if ($case.WidthMigration -and -not @($plan.PullRequests | Where-Object Purpose -eq 'CSharpierFormatting')[0].Standalone) {
            throw "$($case.Name): CSharpier formatting must be standalone."
        }
    }

    'audit-dotnet-estate contract OK'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
