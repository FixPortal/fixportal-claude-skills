#requires -Version 7
$ErrorActionPreference = 'Stop'

# kimi-review.ps1 against a fake `kimi` on PATH. Three contracts:
#   1. -RepoPath is REFUSED: Kimi has no per-invocation read-only mode, so --add-dir
#      would mount the live tree under the CLI's global yolo permission mode.
#   2. stream-json assistant frames ACCUMULATE: one frame per assistant turn, so a late
#      frame (a background-task notification) must not replace the whole review.
#   3. No parseable assistant frame fails the call instead of emitting the JSONL
#      protocol itself as the review.

$skillDir = Split-Path $PSScriptRoot -Parent
$wrapper = Join-Path $skillDir 'kimi-review.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kimi-review-test-' + [guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $root 'bin'
New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
$oldPath = $env:PATH
$oldMode = $env:KIMI_FAKE_MODE
$failures = @()

try {
    $diff = Join-Path $root 'diff.txt'
    Set-Content $diff '+ fixed'
    Set-Content (Join-Path $fakeBin 'kimi.ps1') @(
        'if ($env:KIMI_FAKE_MODE -eq ''two'') {'
        '    ''{"role":"assistant","content":"### FIRST_PART of the review"}'''
        '    ''{"role":"assistant","tool_calls":[{"id":"x"}]}'''
        '    ''{"role":"assistant","content":"SECOND_PART late notification"}'''
        '} else {'
        '    ''not json at all'''
        '    ''{"role":"assistant", broken'''
        '}'
        '$global:LASTEXITCODE = 0'
    )
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
    $resolvedKimi = & pwsh -NoProfile -Command '(Get-Command kimi).Source'
    if ($resolvedKimi -ne (Join-Path $fakeBin 'kimi.ps1')) { throw "test double not resolved: $resolvedKimi" }

    # 1. -RepoPath refused, before any CLI call.
    $env:KIMI_FAKE_MODE = 'two'
    $out = & pwsh -NoProfile -File $wrapper -Instruction 'Review.' -DiffPath $diff -Model 'fixture-model' -RepoPath $root 2>&1 | Out-String
    if ($LASTEXITCODE -ne 2 -or $out -notmatch '-RepoPath is not supported') {
        $failures += "-RepoPath must be refused with exit 2, got exit $LASTEXITCODE`n$out"
    }

    # 2. every assistant frame survives.
    $outPath = Join-Path $root 'review.txt'
    $out = & pwsh -NoProfile -File $wrapper -Instruction 'Review.' -DiffPath $diff -Model 'fixture-model' -OutPath $outPath 2>&1 | Out-String
    $review = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '' }
    if ($LASTEXITCODE -ne 0 -or $review -notmatch 'FIRST_PART' -or $review -notmatch 'SECOND_PART') {
        $failures += "every assistant frame must be kept (FIRST_PART and SECOND_PART), got exit $LASTEXITCODE review:`n$review`n$out"
    }

    # 3. no parseable frame is a failure, and nothing is written as the review.
    $env:KIMI_FAKE_MODE = 'none'
    $badOut = Join-Path $root 'bad-review.txt'
    $out = & pwsh -NoProfile -File $wrapper -Instruction 'Review.' -DiffPath $diff -Model 'fixture-model' -OutPath $badOut 2>&1 | Out-String
    if ($LASTEXITCODE -ne 1 -or (Test-Path -LiteralPath $badOut)) {
        $failures += "a stream with no parseable assistant frame must exit 1 and write no review, got exit $LASTEXITCODE`n$out"
    }
}
finally {
    $env:PATH = $oldPath
    $env:KIMI_FAKE_MODE = $oldMode
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    Write-Error "kimi-review.ps1 contract FAILED ($($failures.Count) issue(s))" -ErrorAction Continue
    exit 1
}
$global:LASTEXITCODE = 0
'kimi-review.ps1 OK - -RepoPath refused, assistant frames accumulated, unparseable stream fails'
