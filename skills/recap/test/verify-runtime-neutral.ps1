$ErrorActionPreference = 'Stop'
$text = Get-Content (Join-Path $PSScriptRoot '..\SKILL.md') -Raw

if ($text -match '(?i)~[/\\]\.claude') {
    throw 'Shared recap must not read or write Claude-specific paths'
}
foreach ($needle in '~/.agents/recap/', 'active runtime''s user-level instruction file') {
    if ($text -notmatch [regex]::Escape($needle)) {
        throw "Shared recap missing host-neutral contract: $needle"
    }
}

'recap runtime-neutral contract OK'
