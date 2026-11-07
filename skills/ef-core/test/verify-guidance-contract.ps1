$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$skill = Get-Content -Raw -LiteralPath (Join-Path $root 'SKILL.md')
$contract = $skill + "`n" + (Get-Content -Raw -LiteralPath (Join-Path $root 'references/nodatime-sql-server.md'))

$required = @(
    'sealed class LocalDateToDateTimeConverter',
    'sealed class InstantToDateTimeConverter',
    'LocalDate → DateTime',
    'active runtime instructions',
    'Do not introduce a repository or specification'
)
$forbidden = @(
    'global `CLAUDE.md`',
    'Implement specifications pattern',
    'isolate data access behind a repository/abstraction',
    'LocalDate → DateOnly'
)

foreach ($value in $required) {
    if (-not $contract.Contains($value)) { throw "Missing EF Core contract: $value" }
}
foreach ($value in $forbidden) {
    if ($skill.Contains($value)) { throw "Stale EF Core contract: $value" }
}

function Get-UnguardedPrimaryConstructorDeclarations([string] $text) {
    $declarations = [regex]::Matches(
        $text,
        '(?m)^[ \t]*(?:(?:file|public|private|protected|internal|static|abstract|sealed|partial|new|readonly|ref|unsafe)\s+)*(?:class|struct)\s+[A-Za-z_]\w*(?:\s*<[^(){}]*>)?\s*\(')

    foreach ($declaration in $declarations) {
        $previousLine = [regex]::Match(
            $text.Substring(0, $declaration.Index),
            '(?<line>[^\r\n]*)\r?\n\z').Groups['line'].Value.Trim()
        $hasAdjacentGate = $previousLine -match '(?i)(?:\bc#\s*12\b|\blangversion\b.*\b12(?:\.0)?\b)'

        if (-not $hasAdjacentGate) { $declaration.Value.Trim() }
    }
}

$primaryConstructorMutations = @(
    @{ Name = 'one-line public sealed class'; Text = 'public sealed class Example(string value) { }'; Violation = $true }
    @{ Name = 'internal class'; Text = 'internal class Example(string value) { }'; Violation = $true }
    @{ Name = 'generic class'; Text = 'public class Example<T>(T value) { }'; Violation = $true }
    @{ Name = 'multiline struct'; Text = "public readonly struct Example`n(`n    string Value`n) { }"; Violation = $true }
    @{ Name = 'file class'; Text = 'file class Example(string value) { }'; Violation = $true }
    @{ Name = 'file struct'; Text = 'file struct Example(string value) { }'; Violation = $true }
    @{ Name = 'adjacent C# 12 gate'; Text = "// Requires C# 12`npublic class Example(string value) { }"; Violation = $false }
    @{ Name = 'adjacent LangVersion gate'; Text = "// <LangVersion>12.0</LangVersion>`ninternal struct Example(int value) { }"; Violation = $false }
    @{ Name = 'non-adjacent C# 12 gate'; Text = "// Requires C# 12`n`npublic class Example(string value) { }"; Violation = $true }
)
foreach ($mutation in $primaryConstructorMutations) {
    $detected = @(Get-UnguardedPrimaryConstructorDeclarations $mutation.Text).Count -gt 0
    if ($detected -ne $mutation.Violation) {
        throw "Primary-constructor mutation contract failed: $($mutation.Name)"
    }
}

if (@(Get-UnguardedPrimaryConstructorDeclarations $contract).Count -gt 0) {
    throw 'EF Core examples must not use unguarded C# 12 primary constructors.'
}

'EF Core guidance contract OK'
