$ErrorActionPreference = 'Stop'

function Test-TriggerForm([string] $skill) {
    # Frontmatter only. Matched against the whole file, a `description:` line anywhere in
    # the body satisfied the check while the real description said something else.
    $frontmatter = [regex]::Match($skill, '(?s)\A---\r?\n(.*?)\r?\n---')
    if (-not $frontmatter.Success) { return $false }
    return $frontmatter.Groups[1].Value -match '(?ms)^description:\s*(?:>|[|])?\s*\r?\n?\s*Use when'
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach ($name in 'optimise-web', 'web-audit-sweep', 'wolverine-messaging', 'scaffold-ci', 'scaffold-frontend') {
    $path = Join-Path $root $name 'SKILL.md'
    # Public mirror: not every skill this checks is published. Skip an absent one with a
    # stated reason rather than failing on a file the repository does not carry.
    if (-not (Test-Path -LiteralPath $path)) { Write-Host "SKIP: $name not present in this tree"; continue }
    $skill = Get-Content -Raw $path
    if (-not (Test-TriggerForm $skill)) {
        throw "$name description must start with 'Use when'."
    }
}

# RED CHECK: only the FRONTMATTER description is the trigger. A body that quotes
# `description: Use when` (a skill that documents the convention, say) must not pass a
# frontmatter description that does not start with it.
$synthetic = @'
---
name: synthetic
description: Audits things. Triggers include /synthetic.
---

# Synthetic

Write the frontmatter as:

description: Use when the user asks for a synthetic audit.
'@
if (Test-TriggerForm $synthetic) {
    throw "a 'description: Use when' line in the body was accepted in place of the frontmatter description"
}

Write-Host 'trigger forms OK'
