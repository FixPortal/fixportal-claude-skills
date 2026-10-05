[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $Path
)

$ErrorActionPreference = 'Stop'
$content = Get-Content -Raw -LiteralPath $Path
if ($content -notmatch '(?s)\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)') {
    throw 'Report must begin with YAML frontmatter.'
}
$frontmatter = $Matches.frontmatter

function Get-Field([string] $name) {
    $matches = [regex]::Matches($frontmatter, "(?m)^$([regex]::Escape($name)):\s*(.*?)\s*$")
    if ($matches.Count -ne 1 -or [string]::IsNullOrWhiteSpace($matches[0].Groups[1].Value)) {
        throw "Report frontmatter must contain exactly one non-empty '$name' field."
    }
    $matches[0].Groups[1].Value.Trim()
}

function Get-Axes([string] $field, [bool] $allowNone) {
    $value = Get-Field $field
    if ($allowNone -and $value -ieq 'none') { return @() }
    $axes = @($value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($axes.Count -eq 0) { throw "'$field' must name at least one evidence axis." }
    foreach ($axis in $axes) {
        if (@('A', 'B', 'C', 'D', 'E', 'F', 'G', 'H') -cnotcontains $axis) {
            throw "'$field' contains invalid evidence axis '$axis'."
        }
    }
    @($axes | Select-Object -Unique)
}

function Get-Count([string] $field) {
    $value = Get-Field $field
    $number = 0
    if (-not [int]::TryParse($value, [ref] $number) -or $number -lt 0) {
        throw "'$field' must be a non-negative integer."
    }
    $number
}

$status = Get-Field 'status'
$required = @(Get-Axes 'required-evidence-axes' $false)
$completed = @(Get-Axes 'completed-evidence-axes' $false)
$failed = @(Get-Axes 'failed-evidence-axes' $true)
$unverifiedCritical = Get-Count 'unverified-critical-items'
$unverifiedHigh = Get-Count 'unverified-high-items'
$unsettled = [regex]::Matches($content, '(?ms)^## Unsettled — host evidence required\s*\r?\n(?<body>.*?)(?=^##\s|\z)') |
    ForEach-Object { $_.Groups['body'].Value }
$unsettledText = $unsettled -join "`n"
$unsettledCritical = [regex]::Matches($unsettledText, '(?im)^\s*[-*]\s+\*{0,2}Critical\*{0,2}(?=\s|—|:)').Count
$unsettledHigh = [regex]::Matches($unsettledText, '(?im)^\s*[-*]\s+\*{0,2}High\*{0,2}(?=\s|—|:)').Count
if ($unverifiedCritical -lt $unsettledCritical) {
    throw "unverified-critical-items ($unverifiedCritical) is lower than the $unsettledCritical Critical Unsettled item(s)."
}
if ($unverifiedHigh -lt $unsettledHigh) {
    throw "unverified-high-items ($unverifiedHigh) is lower than the $unsettledHigh High Unsettled item(s)."
}

foreach ($axis in $failed) {
    if ($required -cnotcontains $axis) { throw "Failed evidence axis '$axis' is not required by this audit." }
}

if ($status -ieq 'Complete') {
    if ($failed.Count -gt 0) { throw "Complete is invalid because failed evidence axes remain: $($failed -join ', ')." }
    $missing = @($required | Where-Object { $completed -cnotcontains $_ })
    if ($missing.Count -gt 0) { throw "Complete is invalid because it is missing completed evidence axes: $($missing -join ', ')." }
    if ($unverifiedCritical -gt 0) { throw "Complete is invalid with $unverifiedCritical unverified Critical item(s)." }
    if ($unverifiedHigh -gt 0) { throw "Complete is invalid with $unverifiedHigh unverified High item(s)." }
}

"Test-audit report contract OK: $Path"
