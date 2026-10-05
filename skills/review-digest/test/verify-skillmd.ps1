$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..' 'SKILL.md'
$text = Get-Content $path -Raw
$fm = [regex]::Match($text, '(?s)^---(.+?)---')
if (-not $fm.Success) { throw "no frontmatter" }
$block = $fm.Groups[1].Value
if ($block -notmatch '(?im)^name:\s*review-digest\s*$') { throw "name must be review-digest" }
$desc = [regex]::Match($block, '(?im)^description:\s*(.+)$')
if (-not $desc.Success) { throw "no description" }
if ($desc.Groups[1].Value.Length -gt 1024) { throw "description >1024 chars (Copilot limit)" }
foreach ($needle in 'collect.ps1', 'write-report.ps1', 'Review Ledger', 'repo-path', 'reviewed-paths', 'unusable', 'uncovered', 'score', 'state-of-play') {
    if ($text -notmatch [regex]::Escape($needle)) { throw "SKILL.md missing reference: $needle" }
}
if ($text -match '(?i)\.claude[\\/]+skills[\\/]+review-digest') { throw "SKILL.md must resolve support files from its loaded skill directory" }
if ($text -match '(?i)never reviewed') { throw "SKILL.md must not equate missing evidence with never reviewed" }
"SKILL.md OK — description $($desc.Groups[1].Value.Length) chars"
