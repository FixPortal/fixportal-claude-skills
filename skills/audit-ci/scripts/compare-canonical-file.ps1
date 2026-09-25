[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ActualPath,

    [Parameter(Mandatory)]
    [string] $CanonicalPath,

    [switch] $IgnoreLineEndings
)

$ErrorActionPreference = 'Stop'
$actual = (Resolve-Path -LiteralPath $ActualPath).Path
$canonical = (Resolve-Path -LiteralPath $CanonicalPath).Path

# NOT $matches. That name is PowerShell's automatic regex-capture variable, and every
# `-match`, `-replace` with a script block, or `switch -regex` anywhere between the
# assignment and the read overwrites it with a capture hashtable - which is truthy, so
# the failure direction is a drift check that silently passes. Nothing between these
# lines matches today; the name is the hazard, not the current control flow.
if ($IgnoreLineEndings) {
    $actualContent = ([IO.File]::ReadAllText($actual) -replace "\r\n?|\n", "`n")
    $canonicalContent = ([IO.File]::ReadAllText($canonical) -replace "\r\n?|\n", "`n")
    $isIdentical = $actualContent -ceq $canonicalContent
}
else {
    $actualHash = (Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash
    $canonicalHash = (Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash
    $isIdentical = $actualHash -ceq $canonicalHash
}

if (-not $isIdentical) {
    $actualHash = (Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash
    $canonicalHash = (Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash
    throw "Canonical asset drift: '$actual' ($actualHash) differs from '$canonical' ($canonicalHash)."
}

"Canonical asset matches: $actual"
