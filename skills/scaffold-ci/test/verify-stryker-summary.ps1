$ErrorActionPreference = 'Stop'

# summarize-stryker.ps1 must report Stryker's OWN metric, not an invented one.
#
#   detected   = Killed + Timeout
#   undetected = Survived + NoCoverage
#   valid      = detected + undetected
#   score      = detected / valid * 100
#
# CompileError, RuntimeError, Ignored and Pending are NOT valid mutants and must stay
# out of the denominator; Timeout IS detected and must be in the numerator.
# https://stryker-mutator.io/docs/mutation-testing-elements/mutant-states-and-metrics/
#
# The original template computed `killed / (total - ignored)`, which made two errors in
# the same direction — Timeout missing from the numerator, CompileError and RuntimeError
# left in the denominator — so it systematically understated every score in the estate.
# Status spellings below are taken from a real Stryker 4.x report (schemaVersion 2):
# PascalCase, no separators.

$script = Resolve-Path (Join-Path $PSScriptRoot '..' 'templates' 'summarize-stryker.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('stryker-summary-' + [guid]::NewGuid().ToString('N'))

function New-Report([hashtable] $filesToStatuses) {
    $files = [ordered]@{}
    foreach ($name in $filesToStatuses.Keys) {
        $mutants = @()
        $id = 0
        foreach ($status in $filesToStatuses[$name]) {
            $id++
            $mutants += [pscustomobject]@{
                id          = "$name-$id"
                mutatorName = 'BlockStatement'
                status      = $status
            }
        }
        $files[$name] = [pscustomobject]@{ language = 'cs'; source = '// fixture'; mutants = $mutants }
    }
    [pscustomobject]@{ schemaVersion = '2'; thresholds = [pscustomobject]@{ high = 80; low = 70 }; files = [pscustomobject]$files }
}

function Invoke-Summary([object] $report, [string] $tag) {
    $reportPath = Join-Path $root "$tag-report.json"
    $jsonPath = Join-Path $root "$tag-summary.json"
    $mdPath = Join-Path $root "$tag-summary.md"
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding utf8
    $markdown = & $script -ReportPath $reportPath -JsonOutputPath $jsonPath -MarkdownOutputPath $mdPath
    [pscustomobject]@{
        Summary  = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        Markdown = ($markdown -join [Environment]::NewLine)
    }
}

function Invoke-AssuredSummary([object] $report, [string] $tag) {
    $reportPath = Join-Path $root "$tag-report.json"
    $jsonPath = Join-Path $root "$tag-summary.json"
    $mdPath = Join-Path $root "$tag-summary.md"
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding utf8
    & pwsh -NoProfile -File $script -ReportPath $reportPath -JsonOutputPath $jsonPath -MarkdownOutputPath $mdPath -FailOnInconclusive *> $null
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Summary  = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    }
}

function Assert-Value($actual, $expected, [string] $what) {
    if ($actual -ne $expected) { throw "$what : expected $expected, got $actual" }
}

try {
    New-Item -ItemType Directory -Path $root | Out-Null

    # --- Every state present exactly once in the arithmetic.
    #     Killed 6, Timeout 2, Survived 3, NoCoverage 1, CompileError 4, RuntimeError 2,
    #     Ignored 5, Pending 1  => detected 8, undetected 4, valid 12, score 66.7
    #     The superseded formula returns 6 / (24 - 5) = 31.6 on this same fixture.
    $everyState = New-Report @{
        'Alpha.cs' = @('Killed', 'Killed', 'Killed', 'Timeout', 'Survived', 'CompileError', 'Ignored', 'Pending')
        'Beta.cs'  = @('Killed', 'Killed', 'Timeout', 'Survived', 'Survived', 'NoCoverage', 'CompileError', 'Ignored')
        'Gamma.cs' = @('Killed', 'CompileError', 'CompileError', 'RuntimeError', 'RuntimeError', 'Ignored', 'Ignored', 'Ignored')
    }
    $all = Invoke-Summary $everyState 'every-state'
    $s = $all.Summary

    Assert-Value $s.killed 6 'killed'
    Assert-Value $s.timeout 2 'timeout'
    Assert-Value $s.survived 3 'survived'
    Assert-Value $s.noCoverage 1 'noCoverage'
    Assert-Value $s.compileError 4 'compileError'
    Assert-Value $s.runtimeError 2 'runtimeError'
    Assert-Value $s.ignored 5 'ignored'

    Assert-Value $s.detected 8 'detected (killed + timeout)'
    Assert-Value $s.undetected 4 'undetected (survived + noCoverage)'
    Assert-Value $s.valid 12 'valid (detected + undetected)'
    Assert-Value $s.score 66.7 'score (detected / valid * 100)'

    # --- The invalid and ignored states must be visible in the report even though they
    #     are excluded from the score; silently dropping them hides a broken run.
    Assert-Value $s.statusTotals.Pending 1 'statusTotals.Pending'
    Assert-Value $s.statusTotals.CompileError 4 'statusTotals.CompileError'
    Assert-Value $s.statusTotals.Ignored 5 'statusTotals.Ignored'

    # --- The markdown must not advertise the superseded metric.
    if ($all.Markdown -match 'killed\s*/\s*tested') {
        throw "markdown still labels the score 'killed/tested':`n$($all.Markdown)"
    }
    if ($all.Markdown -notmatch 'detected\s*/\s*valid') {
        throw "markdown must name Stryker's metric as detected/valid:`n$($all.Markdown)"
    }

    # --- Timeout alone must be enough to score 100%: it is detected, not a failure.
    $allTimeout = New-Report @{ 'Only.cs' = @('Timeout', 'Timeout') }
    $timeoutOnly = Invoke-Summary $allTimeout 'timeout-only'
    Assert-Value $timeoutOnly.Summary.detected 2 'timeout-only detected'
    Assert-Value $timeoutOnly.Summary.valid 2 'timeout-only valid'
    Assert-Value $timeoutOnly.Summary.score 100 'timeout-only score'

    # --- No valid mutants must not divide by zero, and must not read as a perfect run.
    $noValid = New-Report @{ 'Broken.cs' = @('CompileError', 'RuntimeError', 'Ignored') }
    $none = Invoke-Summary $noValid 'no-valid'
    Assert-Value $none.Summary.valid 0 'no-valid valid'
    Assert-Value $none.Summary.score 0 'no-valid score'

    # --- Hotspots rank by undetected mutants so the summary stays actionable.
    $hotspots = @($all.Summary.hotspots)
    if ($hotspots.Count -lt 1) { throw 'hotspots must list files with undetected mutants' }
    Assert-Value $hotspots[0].file 'Beta.cs' 'top hotspot'

    # NoCoverage counts against the score even when no mutants survived.
    $gap = Invoke-Summary (New-Report @{
        'Covered.cs' = @('Killed', 'Killed', 'Killed', 'Killed')
        'Uncovered.cs' = @('NoCoverage', 'NoCoverage', 'NoCoverage')
    }) 'coverage-gap'
    $gapHotspots = @($gap.Summary.hotspots)
    if ($gapHotspots.Count -lt 1) { throw 'NoCoverage must be reported as a hotspot' }
    Assert-Value $gapHotspots[0].file 'Uncovered.cs' 'no-coverage hotspot'
    Assert-Value $gapHotspots[0].noCoverage 3 'no-coverage hotspot count'
    Assert-Value $gapHotspots[0].survived 0 'no-coverage hotspot has no survivors'
    if ($gap.Markdown -match 'No surviving mutants|No undetected mutants') {
        throw 'the summary hid the no-coverage hotspot'
    }
    if ($gap.Markdown -notmatch 'No coverage') { throw 'the hotspot table needs its no-coverage column' }

    # --- Optional assurance preserves a client service repo's useful operational gate
    #     while every repository still receives the same canonical metric and script.
    $conclusive = Invoke-AssuredSummary (New-Report @{ 'Assured.cs' = @('Killed', 'Survived', 'Timeout', 'CompileError', 'Ignored') }) 'assured'
    Assert-Value $conclusive.ExitCode 0 'conclusive assurance exit code'
    Assert-Value $conclusive.Summary.assurancePassed $true 'conclusive assurance verdict'
    Assert-Value $conclusive.Summary.score 66.7 'assurance must retain official detected/valid score'

    $timeoutDominated = Invoke-AssuredSummary (New-Report @{ 'Slow.cs' = @('Killed', 'Timeout', 'Timeout') }) 'timeout-dominated'
    Assert-Value $timeoutDominated.ExitCode 1 'timeout-dominated assurance exit code'
    Assert-Value $timeoutDominated.Summary.assurancePassed $false 'timeout-dominated assurance verdict'

    # RuntimeError is a non-viable final status, treated like CompileError.
    $runtimeError = Invoke-AssuredSummary (New-Report @{ 'Broken.cs' = @('Killed', 'RuntimeError') }) 'runtime-error'
    Assert-Value $runtimeError.ExitCode 0 'runtime-error assurance exit code'
    Assert-Value $runtimeError.Summary.assurancePassed $true 'runtime-error assurance verdict'

    'summarize-stryker.ps1 OK - detected/valid score, timeout counted, compile/runtime/ignored/pending excluded'
}
finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The exit-1 assurance children above are asserted, not fatal — clear the native status
# so a caller that checks $LASTEXITCODE after a PASS does not read a child's failure.
$global:LASTEXITCODE = 0
