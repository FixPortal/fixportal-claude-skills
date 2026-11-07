$ErrorActionPreference = 'Stop'
$contract = Get-Content (Join-Path $PSScriptRoot '..' 'references' 'gate-contract.md') -Raw
$matrixMatch = [regex]::Match($contract, '(?ms)^## Verdict matrix\r?\n(?<matrix>.*?)(?=^## |\z)')
if (-not $matrixMatch.Success) {
    throw 'The contract has no Verdict matrix.'
}
$matrix = $matrixMatch.Groups['matrix'].Value

$cases = [ordered]@{
    'required-negative-reviewer' = 'FAIL'
    'optional-negative-reviewer' = 'FAIL'
    'unresolved-thread' = 'FAIL'
    'policy-absent' = 'PASS'
    'policy-unreadable' = 'FAIL'
    'required-domain-warning' = 'FAIL'
    'accepted-explicit-condition' = 'PASS WITH CONDITIONS'
    'unaccepted-validation-gap' = 'FAIL'
    # CLAUDE.md: a rate-limited CodeRabbit does not hold a HIGH PR; it releases with a
    # named coverage gap the owner accepts or holds. Stale/skipped/verdict-less still FAIL.
    'coderabbit-rate-limited' = 'PASS WITH CONDITIONS'
}

foreach ($case in $cases.GetEnumerator()) {
    $row = "(?m)^\|\s*{0}\s*\|.*\|\s*{1}\s*\|$" -f [regex]::Escape($case.Key), [regex]::Escape($case.Value)
    if ($matrix -notmatch $row) {
        throw "Verdict matrix does not map $($case.Key) to $($case.Value)."
    }
}

if ($contract -match '(?m)^Risk:') {
    throw 'The output template still exposes the undefined Risk field.'
}

$skill = Get-Content (Join-Path $PSScriptRoot '..' 'SKILL.md') -Raw
if ($skill -match 'stale, skipped, rate-limited, or verdict-less required review is a \*\*coverage gap\*\* and blocks') {
    throw 'SKILL.md still blocks PASS on a rate-limited CodeRabbit, contradicting the house rule.'
}

'quality-gate-review verdict matrix OK'
