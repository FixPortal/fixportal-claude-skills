[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$workflowRoot = Join-Path $root '.github/workflows'
if (-not (Test-Path -LiteralPath $workflowRoot -PathType Container)) { return }

# Deduped with an ORDINAL set, not `Sort-Object -Unique`, which compares
# case-insensitively regardless of platform. On a case-sensitive checkout `ci.yml` and
# `CI.yml` are two different workflows, and the case-folding version dropped one of them
# from the inventory silently - a whole workflow that no audit step then looks at.
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
@(
    Get-ChildItem -LiteralPath $workflowRoot -File -Filter '*.yml'
    Get-ChildItem -LiteralPath $workflowRoot -File -Filter '*.yaml'
) |
    Sort-Object FullName |
    ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') } |
    Where-Object { $seen.Add($_) }
