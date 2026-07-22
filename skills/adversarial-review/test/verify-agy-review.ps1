$ErrorActionPreference = 'Stop'

$skillDir = Split-Path $PSScriptRoot -Parent
$wrapper = Join-Path $skillDir 'agy-review.ps1'
if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { throw "wrapper not found: $wrapper" }

$expectedParameters = @(
    'Instruction', 'InstructionPath', 'DiffPath', 'FindingsPath', 'ContextPath',
    'Model', 'Effort', 'RepoPath', 'OutPath', 'UsageSidecarPath'
)
$actualParameters = (Get-Command $wrapper).Parameters.Keys
foreach ($name in $expectedParameters) {
    if ($actualParameters -notcontains $name) { throw "wrapper is missing -$name" }
}

$manifest = Get-Content (Join-Path $skillDir 'reviewers.json') -Raw | ConvertFrom-Json
$google = $manifest.reviewers | Where-Object id -eq 'G'
if ($manifest.wrappers.agy -ne 'agy-review.ps1') { throw 'manifest must map agy to agy-review.ps1' }
if ($google.wrapper -ne 'agy') { throw 'reviewer G must use the agy wrapper' }
if ($google.model -ne 'gemini-3.1-pro-high') { throw 'reviewer G must pin gemini-3.1-pro-high' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('agy-review-test-' + [guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $root 'bin'
New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null

try {
    $brief = Join-Path $root 'brief.txt'
    $diff = Join-Path $root 'diff.txt'
    $context1 = Join-Path $root 'one.cs'
    $context2 = Join-Path $root 'two.cs'
    $out = Join-Path $root 'review.txt'
    $usage = Join-Path $root 'usage.json'
    $capture = Join-Path $root 'args.txt'

    Set-Content $brief 'Review the diff.'
    Set-Content $diff '+ fixed'
    Set-Content $context1 'interface IOne {}'
    Set-Content $context2 'interface ITwo {}'
    Set-Content (Join-Path $fakeBin 'agy.ps1') @(
        "if (-not (Test-Path brief.txt)) { exit 31 }"
        "if (-not (Test-Path review-diff.txt)) { exit 32 }"
        "if (-not (Test-Path 'context\00_one.cs')) { exit 33 }"
        "if (-not (Test-Path 'context\01_two.cs')) { exit 34 }"
        "Set-Content '$capture' (`$args -join ' ')"
        '$global:LASTEXITCODE = 0'
        "'FAKE REVIEW'"
    )

    $oldPath = $env:PATH
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
    $resolvedAgy = & pwsh -NoProfile -Command '(Get-Command agy).Source'
    if ($resolvedAgy -ne (Join-Path $fakeBin 'agy.ps1')) { throw "test double not resolved: $resolvedAgy" }
    & pwsh -NoProfile -File $wrapper -InstructionPath $brief -DiffPath $diff `
        -ContextPath "$context1;$context2" -Model 'gemini-3.1-pro-high' -Effort low `
        -OutPath $out -UsageSidecarPath $usage
    if ($LASTEXITCODE -ne 0) { throw "wrapper exited $LASTEXITCODE" }

    if (-not (Test-Path -LiteralPath $capture)) {
        throw "test double did not capture args; review output: $((Get-Content $out -Raw).Trim())"
    }
    $argsText = Get-Content $capture -Raw
    foreach ($fragment in @('--mode plan', '--model gemini-3.1-pro-high', '--effort high')) {
        if ($argsText -notlike "*$fragment*") { throw "agy invocation missing '$fragment': $argsText" }
    }
    if ((Get-Content $out -Raw).Trim() -ne 'FAKE REVIEW') { throw 'wrapper did not write the review text' }
    $usageJson = Get-Content $usage -Raw | ConvertFrom-Json
    if ($usageJson.inputTokens -ne 0 -or $usageJson.outputTokens -ne 0 -or $usageJson.costUsd -ne 0) {
        throw 'agy usage sidecar must report unknown usage as zero'
    }

    'agy-review.ps1 OK'
}
finally {
    $env:PATH = $oldPath
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
