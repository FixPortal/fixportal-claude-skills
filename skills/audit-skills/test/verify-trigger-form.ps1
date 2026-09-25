$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach ($name in 'optimise-web', 'web-audit-sweep', 'wolverine-messaging', 'scaffold-ci', 'scaffold-frontend') {
    $path = Join-Path $root $name 'SKILL.md'
    # Public mirror: not every skill this checks is published. Skip an absent one with a
    # stated reason rather than failing on a file the repository does not carry.
    if (-not (Test-Path -LiteralPath $path)) { Write-Host "SKIP: $name not present in this tree"; continue }
    $skill = Get-Content -Raw $path
    if ($skill -notmatch '(?ms)^description:\s*(?:>|[|])?\s*\r?\n?\s*Use when') {
        throw "$name description must start with 'Use when'."
    }
}

Write-Host 'trigger forms OK'
