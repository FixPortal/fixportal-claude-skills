# Validation checks

Run from the loaded skill directory with PowerShell 7:
`pwsh -NoProfile -File test/<check>.ps1`. Respect current owner test constraints.
These validate the scaffold, not the application's own tests.

| Check | Purpose and when to run | Prerequisites and effects |
|---|---|---|
| `verify-template-contract.ps1` | After template/gate changes: asserts template configuration and dependency contracts, then resolves packages and inspects TypeScript configuration. | Shipped templates and SKILL.md for initial static checks; Node/npm and registry access for later fixture work. Writes and removes its own temporary tree. |
| `verify-version-floor.ps1` | After dependency-floor changes: checks template versions against the sibling scaffold-typescript table, then resolves the exact documented floors together. | The sibling scaffold-typescript SKILL.md must exist; Node, npm 11 or newer and registry access for resolution. Writes and removes a temporary package fixture. |
| `verify-build-gate.ps1` | After build-script or TypeScript template changes: builds valid sources through the real template, then injects a type-only error and requires build failure before a bundle is produced. | Node/npm, registry access and shipped templates. Installs fixture dependencies and runs builds; writes and removes its temporary generated application. |

Missing npm or a registry that remains unreachable after retries causes explicit
SKIP for the network-dependent portions. The version-floor check also skips
resolution on npm below 11 because of the recorded peer-set crash. Its static
floor comparison runs before those guards. The template contract runs initial
static assertions before its guards and can report a no-input tsconfig skip
while still checking strictness from raw JSON. Genuine dependency-resolution,
configuration or build failures must fail rather than be treated as network
skips. Report the portion skipped; exit zero alone does not establish full
fixture coverage.
