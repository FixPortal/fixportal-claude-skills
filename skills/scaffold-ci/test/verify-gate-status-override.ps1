$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot '../assets/assert_gate_coverage.py'
$python = Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { throw 'Python is required for gate status override regressions' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('gate-status-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scratch | Out-Null
$bad = "contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')"
$cases = @(
    @{ Name='implicit-success'; Condition=$bad; Accepted=$false },
    @{ Name='explicit-success-mask'; Condition="success() && ($bad)"; Accepted=$false },
    @{ Name='failure-only'; Condition="failure() && ($bad)"; Accepted=$false },
    @{ Name='cancelled-only'; Condition="cancelled() && ($bad)"; Accepted=$false },
    # GitHub suppresses implicit success for a real status function anywhere in if.
    # The other OR branch remains reachable despite the dead status branch.
    @{ Name='dead-status-branch'; Condition="($bad) || (always() && false)"; Accepted=$true },
    @{ Name='literal-status'; Condition="($bad) && 'always()' == 'always()'"; Accepted=$false },
    @{ Name='always-override'; Condition="always() && ($bad)"; Accepted=$true },
    @{ Name='fresh-success-masks'; Condition="(failure() || cancelled()) && ($bad)"; Accepted=$false },
    @{ Name='complete-current-status-partition'; Condition="(success() || failure() || cancelled()) && ($bad)"; Accepted=$true },
    @{ Name='negated-cancelled-mask'; Condition="!cancelled() && ($bad)"; Accepted=$false },
    @{ Name='both-statuses'; Condition="(failure() && contains(needs.*.result, 'failure')) || (cancelled() && contains(needs.*.result, 'cancelled'))"; Accepted=$false },
    @{ Name='failure-or-complete'; Condition="failure() || ($bad)"; Accepted=$true },
    @{ Name='cancelled-or-complete'; Condition="cancelled() || ($bad)"; Accepted=$true },
    # success() is true on every healthy run, so the step fires with nothing upstream wrong.
    @{ Name='success-or-complete'; Condition="success() || ($bad)"; Accepted=$false },
    @{ Name='failure-or-incomplete'; Condition="failure() || contains(needs.*.result, 'cancelled')"; Accepted=$false },
    @{ Name='all-true-no-dependencies'; Condition='always()'; Accepted=$false },
    @{ Name='all-true-masks-dependencies'; Condition="always() || ($bad)"; Accepted=$false },
    @{ Name='unknown-conjunct'; Condition="failure() || (($bad) && github.ref == 'refs/heads/main')"; Accepted=$false },
    @{ Name='unknown-or-branch'; Condition="failure() || contains(needs.*.result, 'failure') || (contains(needs.*.result, 'cancelled') && github.ref == 'refs/heads/main')"; Accepted=$false },
    @{ Name='unknown-or'; Condition="failure() || github.ref == 'refs/heads/main' || ($bad)"; Accepted=$false }
)
try {
    foreach ($case in $cases) {
        $path = Join-Path $scratch ($case.Name + '.yml')
        @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: $($case.Condition)
        run: exit 1
"@ | Set-Content -LiteralPath $path
        $output = & $python.Source -S $checker $path 2>&1 | Out-String
        $accepted = $LASTEXITCODE -eq 0
        if ($accepted -ne $case.Accepted) { throw "$($case.Name): expected accepted=$($case.Accepted), actual=$accepted`n$output" }
    }
    "Gate status override: $($cases.Count) cases passed"
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
