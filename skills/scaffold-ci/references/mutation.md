# Mutation workflow contract

Read this reference whenever Stryker.NET or `mutation.yml` is in scope.

## `mutation.yml` (Stryker.NET) — a SEPARATE workflow

Not part of `ci.yml`. Mutation score is informational, but execution and report failures
are real failures. Use `break: 0`; never use job- or step-level `continue-on-error` to
hide restore failures, tool crashes, invalid baselines, or missing reports.

### Weekly cadence policy

Every mutation workflow has exactly two triggers: `workflow_dispatch` for validation and
ad hoc runs, plus one staggered weekly UTC schedule. Do not add `push` or `pull_request`
triggers: mutation is deliberately outside per-commit CI because Stryker's runtime would
consume disproportionate Blacksmith and GitHub Actions quota.

Choose a repository-specific weekday and time so mutation jobs are spread across the estate;
do not copy one cron value everywhere. Keep the weekly schedule after scope, runner, or tool
changes. Validate a new or repaired lane manually, but do not leave it manual-only.

Use per-ref concurrency to cancel a superseded manual or scheduled run.

```yaml
name: mutation

on:
  workflow_dispatch:
  schedule:
    - cron: '<staggered weekly UTC cron>'

concurrency:
  group: mutation-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  stryker:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - name: Lint workflows (actionlint)
        uses: raven-actions/actionlint@3d39aea434753780c3b3d4a1a31c854b4dbf49d7 # v2
        with:
          shellcheck: true
      - uses: actions/setup-dotnet@v6
        with:
          dotnet-version: 10.0.x
      - name: Restore solution
        run: dotnet restore YourSolution.sln
      - name: Restore local tools
        run: dotnet tool restore
      - name: Run Stryker
        working-directory: tests/Your.Project.Tests
        run: dotnet stryker --config-file ../../stryker-config.json
      - name: Summarize mutation report
        if: always()
        shell: pwsh
        run: |
          $latest = Get-ChildItem tests/Your.Project.Tests/StrykerOutput -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
          if (-not $latest) { throw "No StrykerOutput directory found." }
          $report = Join-Path $latest.FullName 'reports/mutation-report.json'
          $jsonSummary = Join-Path $latest.FullName 'reports/mutation-summary.json'
          $mdSummary = Join-Path $latest.FullName 'reports/mutation-summary.md'
          .\scripts\summarize-stryker.ps1 -ReportPath $report -JsonOutputPath $jsonSummary -MarkdownOutputPath $mdSummary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
      - name: Upload mutation summary
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: mutation-summary
          path: tests/Your.Project.Tests/StrykerOutput/**/reports/mutation-summary.*
      - name: Upload mutation report
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: mutation-report
          path: tests/Your.Project.Tests/StrykerOutput/**
          if-no-files-found: error
```

**Support files** (copy from `templates/`, then adapt names):
- `.config/dotnet-tools.json` — pins `dotnet-stryker` and CSharpier with
  `rollForward: false`. If a manifest already exists, merge missing tools into it rather
  than overwriting. `scaffold-dotnet` owns the CSharpier version and repository config;
  this skill consumes it for CI.
- `stryker-config.json` (repo root) — house defaults: `test-runner: mtp`,
  `mutation-level: Standard`, `coverage-analysis: off`, `concurrency: 4`,
  `thresholds: { high: 80, low: 70, break: 0 }` (break 0 = never fail the run). The default
  template is a single-project lane: set `project` to the project-under-test file name as it
  appears in the test project's `ProjectReference`; omit `solution`, `test-projects`, and
  `test-case-filter`. See the multi-project exception below.
- `scripts/summarize-stryker.ps1` — shipped verbatim; renders the run into a step summary.
  It reports Stryker's own metric — `detected / valid`, where `detected = Killed + Timeout`
  and `valid = detected + Survived + NoCoverage`. CompileError, RuntimeError, Ignored and
  Pending stay out of the denominator. Covered by `test/verify-stryker-summary.ps1`.
  Repositories needing a stricter operational signal may pass `-FailOnInconclusive`; the
  canonical script then fails after writing its artifacts when final statuses are unknown,
  no killed/survived result exists, or timeouts outnumber killed plus survived. Do not fork
  the script to add that gate.

If a repository used the superseded score formula, treat the first corrected score as a
metric correction and re-baseline thresholds against two runs. The measurements and
formula history are recorded in [provenance.md](provenance.md).

### Scope MTP mutation lanes structurally

For the ordinary lane, keep fast mutation tests in one test project and invoke Stryker from
that directory:

```yaml
      - name: Run Stryker
        working-directory: tests/Your.Project.Tests
        run: dotnet stryker --config-file ../../stryker-config.json
```

Stryker resolves the project under test through that test project's `ProjectReference`, and
places `StrykerOutput/` in the working directory. Update the summary and artifact paths when
the test-project path changes.

Do not put `test-case-filter` beside `test-runner: mtp`. Stryker 4.16 accepts the setting but
its MTP runner does not consume it, so the run proceeds unfiltered without a warning. Do not
switch an xunit.v3 executable project to VSTest merely to regain filtering; keep slow or
database-backed tests in a separate project outside the ordinary mutation lane.

When multiple test projects are intentionally part of the mutation lane, use Stryker's
documented `test-projects` option and invoke it from the project-under-test directory instead
of the single-project working directory above. Adapt the config and output paths explicitly;
this is a different lane shape, not an exception to verify after the fact. See Stryker's
[configuration reference](https://stryker-mutator.io/docs/stryker-net/configuration/).

For every new or changed runner setup, read the initial `Number of tests found` line and
compare it with the intended lane's test count. Then target code with known defending tests
and confirm the report contains at least one `Killed` mutant. A fast run and a plausible
score are not evidence that discovery, filtering, or result attribution worked.

**`mtp` prerequisite:** `test-runner: mtp` (Microsoft.Testing.Platform) requires the test
project to build as an MTP executable. For **xunit.v3** the house mechanism is simply
**`<OutputType>Exe</OutputType>`** in the test `.csproj` — that makes xunit.v3 emit an MTP
test host (no `<UseMicrosoftTestingPlatformRunner>` property needed; the engine repo's test
projects use `OutputType=Exe` alone). Keep `Microsoft.NET.Test.Sdk` +
`xunit.runner.visualstudio` alongside it so `dotnet test` (VSTest) still drives CI — the two
runners coexist. Confirm before defaulting to `mtp`: if the test project has no
`OutputType=Exe` (i.e. it runs purely as a VSTest library), either add it or fall back to
`test-runner: vstest`. *(Verified on your-repo 2026-05-29: adding `OutputType=Exe`
flipped Stryker to mtp with `dotnet test` still green.)*
