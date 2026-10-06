$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot '../assets/assert_gate_coverage.py'
$python = Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { throw 'Python is required for flow job regressions' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('gate-flow-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scratch | Out-Null
$cases = @(
    @{ Name='nextline-quoted'; Reason='unsupported flow mapping value'; Body="  build:`n    {if: `"github.ref == 'refs/heads/main'`", runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Accepted=$false },
    @{ Name='nextline-unquoted'; Reason='unsupported flow mapping value'; Body="  build:`n    {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Accepted=$false },
    @{ Name='multiline-quoted'; Reason='unsupported flow mapping value'; Body="  build:`n    {`n      if: `"github.ref == 'refs/heads/main'`",`n      runs-on: ubuntu-latest,`n      steps: [{run: 'echo check'}]`n    }"; Accepted=$false },
    @{ Name='multiline-unquoted'; Reason='unsupported flow mapping value'; Body="  build:`n    {`n      if: github.ref == 'refs/heads/main',`n      runs-on: ubuntu-latest,`n      steps: [{run: 'echo check'}]`n    }"; Accepted=$false },
    @{ Name='same-line'; Reason='unparsable line at job indentation'; Body="  build: {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Accepted=$false },
    @{ Name='block-conditional'; Reason='job-level ''if:'''; Body="  build:`n    if: github.ref == 'refs/heads/main'`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo check"; Accepted=$false },
    @{ Name='block-unconditional'; Body="  build:`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo check"; Accepted=$true },
    @{ Name='anchor-flow'; Reason='unsupported flow mapping value'; Body="  build:`n    &build_definition`n    {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Aliased=$true; Accepted=$false },
    @{ Name='anchor-same-line-flow'; Reason='unsupported flow mapping value'; Body="  build:`n    &build_definition {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Aliased=$true; Accepted=$false },
    @{ Name='tag-flow'; Reason='unsupported flow mapping value'; Body="  build:`n    !!map`n    {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Accepted=$false },
    @{ Name='tag-same-line-flow'; Reason='unsupported flow mapping value'; Body="  build:`n    !!map {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Accepted=$false },
    @{ Name='anchor-tag-flow'; Reason='unsupported flow mapping value'; Body="  build:`n    &build_definition !!map`n    {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Aliased=$true; Accepted=$false },
    @{ Name='anchor-block-positive'; Body="  build:`n    &build_definition`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo check"; Aliased=$true; Accepted=$true },
    @{ Name='anchor-block-conditional'; Reason='job-level ''if:'''; Body="  build:`n    &build_definition`n    if: github.ref == 'refs/heads/main'`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo check"; Aliased=$true; Accepted=$false },
    @{ Name='tag-block-positive'; Body="  build:`n    !!map`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo check"; Accepted=$true },
    @{ Name='hash-anchor-flow'; Reason='unsupported flow mapping value'; Body="  build:`n    &build_definition#v1 {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Aliased=$true; Anchor='build_definition#v1'; Accepted=$false },
    @{ Name='hash-anchor-tag-flow'; Reason='unsupported flow mapping value'; Body="  build:`n    &build_definition#v1 !!map {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Aliased=$true; Anchor='build_definition#v1'; Accepted=$false },
    @{ Name='hash-tag-flow'; Reason='unsupported flow mapping value'; Body="  build:`n    !<tag:example.org,2026:job#v1> {if: github.ref == 'refs/heads/main', runs-on: ubuntu-latest, steps: [{run: 'echo check'}]}"; Accepted=$false },
    @{ Name='hash-anchor-block-positive'; Body="  build:`n    &build_definition#v1`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo check"; Aliased=$true; Anchor='build_definition#v1'; Accepted=$true },
    @{ Name='name-block-literal-positive'; Body="  build:`n    name: |`n      { example # literal`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo check"; Accepted=$true },
    @{ Name='name-block-folded-positive'; Body="  build:`n    name: >-`n      { example # literal`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo check"; Accepted=$true },
    @{ Name='tag-block-conditional'; Reason='job-level ''if:'''; Body="  build:`n    !!map`n    if: github.ref == 'refs/heads/main'`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo check"; Accepted=$false }
)
$failures = @()
try {
    foreach ($case in $cases) {
        $path = Join-Path $scratch ($case.Name + '.yml')
        $anchorName = if ($case.Anchor) { $case.Anchor } else { 'build_definition' }
        $alias = if ($case.Aliased) { "`n  repeated:`n    *$anchorName" } else { '' }
        $needs = if ($case.Aliased) { '[build, repeated]' } else { '[build]' }
        $yaml = "name: fixture`non: push`njobs:`n$($case.Body)$alias`n  ci-gate:`n    runs-on: ubuntu-latest`n    if: always()`n    needs: $needs`n    steps:`n      - if: always() && (contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled'))`n        run: exit 1`n"
        [IO.File]::WriteAllText($path, $yaml, [Text.UTF8Encoding]::new($false))
        $output = & $python.Source $checker $path ci-gate 2>&1
        $exitCode = $LASTEXITCODE
        if (($exitCode -eq 0) -ne $case.Accepted) { $failures += "$($case.Name): exit=$exitCode; $output" }
        elseif (-not $case.Accepted -and (-not $case.Reason -or -not "$output".Contains($case.Reason))) {
            $failures += "$($case.Name): rejected for the wrong reason; $output"
        }
        Write-Output "$($case.Name): exit=$exitCode expectedAccepted=$($case.Accepted)"
    }
    if ($failures.Count) { throw ($failures -join "`n") }
} finally {
    $resolvedScratch = (Resolve-Path -LiteralPath $scratch).ProviderPath
    if ([IO.Path]::GetFullPath($resolvedScratch) -ne [IO.Path]::GetFullPath($scratch)) {
        throw 'Refusing cleanup outside the explicitly created fixture directory'
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
'Gate flow job-value regressions OK (22 cases).'
