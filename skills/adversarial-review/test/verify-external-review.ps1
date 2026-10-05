#requires -Version 7
$ErrorActionPreference = 'Stop'

# external-review.ps1 (Copilot fallback) is repo-blind. Whitelisting each input's
# PARENT directory with --add-dir handed it the repository whenever -ContextPath named a
# repo file. Inputs must be copied into one scratch dir and only that dir whitelisted.

$skillDir = Split-Path $PSScriptRoot -Parent
$wrapper = Join-Path $skillDir 'external-review.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('external-review-test-' + [guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $root 'bin'
$repoDir = Join-Path $root 'repo'
$capture = Join-Path $root 'args.txt'
New-Item -ItemType Directory -Path $fakeBin, $repoDir -Force | Out-Null
$oldPath = $env:PATH

try {
    $diff = Join-Path $root 'diff.txt'
    $context = Join-Path $repoDir 'Service.cs'
    Set-Content $diff '+ fixed'
    Set-Content $context 'class Service {}'
    # One argument per line so the assertions can read each --add-dir value exactly.
    Set-Content (Join-Path $fakeBin 'copilot.ps1') @(
        "Set-Content -LiteralPath '$capture' -Value `$args"
        '$global:LASTEXITCODE = 0'
        "'FAKE REVIEW'"
    )
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
    $resolved = & pwsh -NoProfile -Command '(Get-Command copilot).Source'
    if ($resolved -ne (Join-Path $fakeBin 'copilot.ps1')) { throw "test double not resolved: $resolved" }

    $out = & pwsh -NoProfile -File $wrapper -Instruction 'Review.' -DiffPath $diff -ContextPath $context -Model 'fixture-model' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "wrapper exited $LASTEXITCODE`n$out" }
    $argv = @(Get-Content -LiteralPath $capture)
    $addDirs = @(for ($i = 0; $i -lt $argv.Count - 1; $i++) { if ($argv[$i] -eq '--add-dir') { $argv[$i + 1] } })
    if ($addDirs.Count -ne 1) { throw "exactly one --add-dir (the scratch dir) is allowed, got: $($addDirs -join ' | ')" }
    if ($addDirs[0] -in @($repoDir, $root) -or $addDirs[0].StartsWith($repoDir)) {
        throw "the whitelisted dir must be a private scratch copy, not an input's parent: $($addDirs[0])"
    }
    $prompt = $argv[[array]::IndexOf($argv, '-p') + 1]
    if ($prompt -match [regex]::Escape($context)) { throw 'the prompt must cite the scratch copy of a context file, not its repo path' }
    'external-review.ps1 OK - inputs copied into one scratch dir, only that dir whitelisted'
}
finally {
    $env:PATH = $oldPath
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
