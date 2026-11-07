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
| [test_guidance_drift.py](../test/test_guidance_drift.py) | Guidance snapshot drift, refresh behavior and failed-fetch handling with injected responses. | Python standard library and shipped guidance tooling; injected HTTP/subprocess responses. |
| [verify-grade-schema.ps1](../test/verify-grade-schema.ps1) | Report grade schema and runtime-resolved audit paths. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-official-guidance.ps1](../test/verify-official-guidance.ps1) | Rubric alignment with official guidance rather than unrelated skill-writing conventions. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-utility-evidence.ps1](../test/verify-utility-evidence.ps1) | Invocation evidence excludes audit artifacts and recognizes hook-based use. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
