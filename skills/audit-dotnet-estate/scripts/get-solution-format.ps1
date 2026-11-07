#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The format is what CI BUILDS, not whichever file happens to exist. A repository
# mid-migration carries both a `.sln` and a `.slnx`, and choosing `slnx` on presence
# alone hands the planner a format the pipeline does not use. Read the CI entry point;
# fall back to presence only when no workflow names one. Quoted paths count: `\S+` cannot
# match `dotnet test "src/My App.sln"`.
$root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
$ciSolution = $null
$workflowDir = Join-Path $root '.github' 'workflows'
if (Test-Path -LiteralPath $workflowDir -PathType Container) {
    foreach ($workflow in Get-ChildItem -LiteralPath $workflowDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' }) {
        $hit = [regex]::Match((Get-Content -LiteralPath $workflow.FullName -Raw), '(?i)\bdotnet\s+(?:build|test|restore)\b[^\r\n]*?\s(?<solution>"[^"\r\n]+\.slnx?"|''[^''\r\n]+\.slnx?''|\S+\.slnx?)(?=\s|$)')
        if ($hit.Success) { $ciSolution = $hit.Groups['solution'].Value.Trim('"', "'"); break }
    }
}

if ($ciSolution) {
    if ($ciSolution -match '(?i)\.slnx$') { 'slnx' } else { 'sln' }
}
else {
    # A root solution wins; otherwise solutions may sit anywhere in the tracked tree
    # (outside a git work tree, walk the files).
    if (Get-ChildItem -LiteralPath $root -Filter '*.slnx' -File) { 'slnx' }
    elseif (Get-ChildItem -LiteralPath $root -Filter '*.sln' -File) { 'sln' }
    else {
        $tracked = @(& git -C $root ls-files -- '*.slnx' 2>$null)
        if ($LASTEXITCODE -ne 0) {
            $tracked = @(Get-ChildItem -LiteralPath $root -Filter '*.slnx' -File -Recurse -ErrorAction SilentlyContinue)
        }
        if ($tracked.Count -gt 0) { 'slnx' } else { 'sln' }
    }
}
