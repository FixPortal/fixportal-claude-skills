# Validation checks

Run the relevant checks after changing the guidance or implementation named in
the purpose column; respect the owner's current test constraints. Resolve paths
from the loaded skill directory. PowerShell checks use
`pwsh -NoProfile -File test/<name>.ps1`; Python checks use
`python test/<name>.py`. Pester files use the repository's pinned runner, not
a direct script invocation.

These are skill contract checks, not evidence that a live application, vendor
API or estate audit has passed. Fixtures may write temporary files, start child
processes and temporarily change environment variables; inspect the linked
source before running them. A documented SKIP is unassessed coverage even when
the script exits zero. Record which portion skipped and why. Missing capabilities
without an explicit skip path remain failures.

| Check | Purpose / when relevant | Prerequisites and coverage limits |
|---|---|---|
| [verify-test-contract.ps1](../test/verify-test-contract.ps1) | Test framework, async timing, CI budget and compatibility-example guidance. | PowerShell 7 and shipped timing/budget/example files. Canonical out-of-repository traps note is optional; its absence explicitly skips those assertions. |
