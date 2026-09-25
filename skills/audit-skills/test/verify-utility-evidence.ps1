$ErrorActionPreference = 'Stop'
<#
  The utility axis is only as good as the invocation count behind it. The 2026-09-25 run
  found two ways the count goes wrong without erroring:
    - matching any `"skill": "<name>"` key counts the audit's own worker JSON, so the
      skills audited most often look the most used;
    - a skill that runs from a hook or is reached through another skill's instructions
      never produces a Skill tool call, so a tool-call count reads it as unused.
  Both rules must stay in the controller.
#>
$skill = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'SKILL.md') -Raw

foreach ($needle in '"name":"Skill"', 'worker JSON', 'hook') {
    if ($skill -notmatch [regex]::Escape($needle)) {
        throw "SKILL.md utility-evidence contract is missing: $needle"
    }
}
if ($skill -notmatch '(?is)single\s+pass') {
    throw 'SKILL.md must require a single-pass scan of the session histories.'
}

'audit-skills utility evidence contract OK'
