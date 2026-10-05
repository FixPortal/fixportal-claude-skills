#requires -Version 7
$ErrorActionPreference = 'Stop'

# openai-review.ps1 honours OPENAI_BASE_URL (an API-compatible gateway), but the key
# rides the Authorization header on every request: an http:// override must be refused
# BEFORE any request is attempted, never sent in the clear.

$skillDir = Split-Path $PSScriptRoot -Parent
$wrapper = Join-Path $skillDir 'openai-review.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('openai-base-url-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$saved = @{ key = $env:OPENAI_API_KEY; url = $env:OPENAI_BASE_URL; obsKey = $env:OBSERVATORY_API_KEY }

try {
    $diff = Join-Path $root 'diff.txt'
    Set-Content $diff '+ fixed'
    $env:OPENAI_API_KEY = 'fixture-key-not-real'
    $env:OBSERVATORY_API_KEY = ''
    # .invalid never resolves, so even a regressed wrapper cannot reach a real host.
    $env:OPENAI_BASE_URL = 'http://example.invalid/v1'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & pwsh -NoProfile -File $wrapper -Instruction 'Review.' -DiffPath $diff -Model 'fixture-model' 2>&1 | Out-String
    $sw.Stop()
    if ($LASTEXITCODE -eq 0 -or $out -notmatch 'https://') {
        throw "a plain-http OPENAI_BASE_URL must be refused naming https://, got exit $LASTEXITCODE`n$out"
    }
    if ($out -match 'attempt \d/\d') { throw "the refusal must come before any request is attempted:`n$out" }

    $source = Get-Content -LiteralPath $wrapper -Raw
    if ($source -notmatch '-Uri "\$openAiBaseUrl/chat/completions"') {
        throw 'the request must be sent to the resolved base URL, not a hard-coded endpoint'
    }
    'openai-review.ps1 OK - OPENAI_BASE_URL honoured, plain http refused before any request'
}
finally {
    $env:OPENAI_API_KEY = $saved.key
    $env:OPENAI_BASE_URL = $saved.url
    $env:OBSERVATORY_API_KEY = $saved.obsKey
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
