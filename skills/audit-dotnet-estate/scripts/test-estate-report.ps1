[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $Path
)

$ErrorActionPreference = 'Stop'
$content = Get-Content -Raw -LiteralPath $Path
$sections = @(
    'Executive summary',
    'Verdict distribution',
    'Scope and source-of-truth',
    'Estate conformance matrix',
    'Cross-estate findings',
    'Per-repository evidence',
    'Remediation prompts',
    'Audit actions ledger',
    'Appendix'
)

$offsets = @{}
$lastOffset = -1
foreach ($section in $sections) {
    $matches = [regex]::Matches($content, "(?m)^## $([regex]::Escape($section))\s*$")
    if ($matches.Count -ne 1) { throw "Report must contain exactly one '## $section' section." }
    if ($matches[0].Index -le $lastOffset) { throw "Report section '## $section' is out of order." }
    $offsets[$section] = $matches[0].Index
    $lastOffset = $matches[0].Index
}

$matrixStart = $offsets['Estate conformance matrix']
$matrixEnd = $offsets['Cross-estate findings']
$matrix = $content.Substring($matrixStart, $matrixEnd - $matrixStart)
$tableLines = @($matrix -split '\r?\n' | Where-Object { $_ -match '^\s*\|' })
if ($tableLines.Count -lt 2) { throw 'Estate conformance matrix must contain a Markdown table.' }

function Get-Cells([string] $line) {
    @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
}

$header = @(Get-Cells $tableLines[0])
$requiredColumns = @('Test conformance', 'Performance audit coverage')
foreach ($column in $requiredColumns) {
    if ($header -cnotcontains $column) { throw "Estate conformance matrix is missing '$column'." }
}

foreach ($line in $tableLines | Select-Object -Skip 2) {
    $cells = @(Get-Cells $line)
    if ($cells.Count -ne $header.Count) { throw 'Estate conformance matrix contains a row with the wrong number of fields.' }
    $repository = $cells[0]
    $testConformance = $cells[[array]::IndexOf($header, 'Test conformance')]
    if ([string]::IsNullOrWhiteSpace($testConformance)) {
        throw "Test conformance is empty for repository '$repository'."
    }

    $coverage = $cells[[array]::IndexOf($header, 'Performance audit coverage')]
    if ([string]::IsNullOrWhiteSpace($coverage)) {
        throw "Performance audit coverage is empty for repository '$repository'."
    }
    if ($coverage -notmatch '^Freshness: (Current|Stale|Not found|Not assessed); Depth: (Measured|Characterized|Surveyed|Blocked|Legacy-unspecified|—); Harness: (Retained|Promotion candidate|None|Not assessed)$') {
        throw "Performance audit coverage for repository '$repository' must declare valid Freshness, Depth, and Harness values."
    }
}

"Estate report contract OK: $Path"
