$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\SKILL.md'
$text = Get-Content $path -Raw
$fm = [regex]::Match($text, '(?s)^---(.+?)---')
if (-not $fm.Success) { throw "no frontmatter" }
$block = $fm.Groups[1].Value
$nameOk = $block -match '(?im)^name:\s*review-digest\s*$'
if (-not $nameOk) { throw "name must be review-digest" }
$desc = [regex]::Match($block, '(?im)^description:\s*(.+)$')
if (-not $desc.Success) { throw "no description" }
if ($desc.Groups[1].Value.Length -gt 1024) { throw "description >1024 chars (Copilot limit)" }
foreach ($needle in 'collect.ps1','themes.json','Review Ledger','propose','coverage gap',
                     'handoff','risk','graphify','boundarySha','since the last review') {
  if ($text -notmatch [regex]::Escape($needle)) { throw "SKILL.md missing reference: $needle" }
}
# sanitisation guard: the public copy must carry no machine-specific path
$driveSlash = [IO.Path]::DirectorySeparatorChar
foreach ($leak in "C:$($driveSlash)Users", "D:$driveSlash", "E:$driveSlash") {
  if ($text.Contains($leak)) { throw "SKILL.md leaks a private path token: $leak" }
}
"SKILL.md OK — description $($desc.Groups[1].Value.Length) chars, no machine paths"
