$ErrorActionPreference = 'Stop'

# Windows-only by construction: the fixture CLI is a .cmd batch file and the wrapper under
# test resolves the OAuth credential store through %USERPROFILE%.
if (-not $IsWindows) {
    Write-Host 'SKIP: gemini OAuth shadow test is Windows-only (batch-file fixture CLI)'
    return
}

$root = Join-Path $PSScriptRoot '..'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ar-gemini-oauth-' + [Guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $tempRoot 'home'
$geminiDir = Join-Path $fakeHome '.gemini'
$fakeBin = Join-Path $tempRoot 'bin'
$oldProfile = $env:USERPROFILE
$oldPath = $env:PATH
$oldKey = $env:GEMINI_API_KEY

try {
    New-Item -ItemType Directory -Path $geminiDir, $fakeBin | Out-Null
    $oauth = Join-Path $geminiDir 'oauth_creds.json'
    $fixedCollision = Join-Path $geminiDir 'oauth_creds.json.paused'
    Set-Content -LiteralPath $oauth -Value 'original-oauth' -Encoding utf8
    Set-Content -LiteralPath $fixedCollision -Value 'pre-existing-backup' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fakeBin 'gemini.cmd') -Encoding ascii -Value @(
        '@echo off',
        'if "%FAKE_GEMINI_MODE%"=="reappear" echo interloper> "%USERPROFILE%\.gemini\oauth_creds.json"',
        'if "%FAKE_GEMINI_MODE%"=="priced" echo {"response":"fixture response","stats":{"models":{"gemini-2.5-flash-lite-001":{"tokens":{"prompt":1000000,"candidates":0}}}}}',
        'if "%FAKE_GEMINI_MODE%"=="unpriced" echo {"response":"fixture response","stats":{"models":{"mystery-model":{"tokens":{"prompt":1000000,"candidates":0}}}}}',
        'if not "%FAKE_GEMINI_MODE%"=="priced" if not "%FAKE_GEMINI_MODE%"=="unpriced" echo {"response":"fixture response"}',
        'exit /b 0'
    )
    $diff = Join-Path $tempRoot 'diff.txt'
    $out = Join-Path $tempRoot 'out.txt'
    Set-Content -LiteralPath $diff -Value '+fixture' -Encoding utf8

    $env:USERPROFILE = $fakeHome
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
    $env:GEMINI_API_KEY = 'fixture-key'
    & pwsh -NoProfile -File (Join-Path $root 'gemini-review.ps1') -Instruction 'Review.' -DiffPath $diff -OutPath $out -Model 'gemini-2.5-pro'
    if ($LASTEXITCODE -ne 0) { throw "gemini-review fixture exited $LASTEXITCODE" }

    if ((Get-Content -LiteralPath $oauth -Raw).Trim() -ne 'original-oauth') {
        throw 'OAuth credentials were not restored exactly'
    }
    if ((Get-Content -LiteralPath $fixedCollision -Raw).Trim() -ne 'pre-existing-backup') {
        throw 'pre-existing fixed .paused backup was overwritten'
    }
    if (Get-ChildItem -LiteralPath $geminiDir -Filter 'oauth_creds.json.paused*' -File |
        Where-Object FullName -ne $fixedCollision) {
        throw 'unique per-run OAuth backup remained after successful restore'
    }

    # Credentials that REAPPEAR mid-run must not make the restore throw: a throw in the
    # finally discarded a completed, paid-for review. The interloper is moved aside, the
    # pre-run credentials come back, and the review is still delivered.
    $env:FAKE_GEMINI_MODE = 'reappear'
    $out2 = Join-Path $tempRoot 'out2.txt'
    $run2 = & pwsh -NoProfile -File (Join-Path $root 'gemini-review.ps1') -Instruction 'Review.' -DiffPath $diff -OutPath $out2 -Model 'gemini-2.5-pro' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out2)) {
        throw "a reappeared credentials file must not discard the review (exit $LASTEXITCODE)`n$run2"
    }
    if ((Get-Content -LiteralPath $oauth -Raw).Trim() -ne 'original-oauth') { throw 'pre-run OAuth credentials were not restored after a reappearance' }
    if (-not (Get-ChildItem -LiteralPath $geminiDir -Filter 'oauth_creds.json.reappeared.*' -File)) {
        throw 'the reappeared credentials file must be moved aside, not deleted'
    }
    if ($run2 -notmatch 'reappeared') { throw "the reappearance must be reported as a warning:`n$run2" }

    # Pricing: longest-prefix match, and an unpriced model is costUnknown, never a guess.
    $sidecar = Join-Path $tempRoot 'usage.json'
    $env:FAKE_GEMINI_MODE = 'priced'
    & pwsh -NoProfile -File (Join-Path $root 'gemini-review.ps1') -Instruction 'Review.' -DiffPath $diff -OutPath $out2 -Model 'gemini-2.5-flash-lite' -UsageSidecarPath $sidecar *> $null
    $usage = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json
    if ([Math]::Abs([double]$usage.costUsd - 0.10) -gt 1e-9 -or $usage.costUnknown) {
        throw "gemini-2.5-flash-lite-001 must price at the flash-lite rate (0.10), got $($usage.costUsd) unknown=$($usage.costUnknown)"
    }
    $env:FAKE_GEMINI_MODE = 'unpriced'
    & pwsh -NoProfile -File (Join-Path $root 'gemini-review.ps1') -Instruction 'Review.' -DiffPath $diff -OutPath $out2 -Model 'mystery-model' -UsageSidecarPath $sidecar *> $null
    $usage = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json
    if (-not $usage.costUnknown -or [double]$usage.costUsd -ne 0) {
        throw "an unpriced model must record costUnknown with no fabricated price, got $($usage | ConvertTo-Json -Compress)"
    }

    'gemini-review OAuth shadow OK — fixed collision preserved, unique backup restored, reappearance survived, pricing honest'
}
finally {
    $env:FAKE_GEMINI_MODE = $null
    $env:USERPROFILE = $oldProfile
    $env:PATH = $oldPath
    $env:GEMINI_API_KEY = $oldKey
    if ($tempRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
