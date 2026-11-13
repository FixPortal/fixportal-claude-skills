# Validation checks

Run these from the loaded skill directory with PowerShell 7:
`pwsh -NoProfile -File test/<check>.ps1`. Choose the checks affected by the
change, subject to the owner's current test constraints. These check the skill;
they do not replace a scaffolded repository's own gate.

| Check | Purpose and when to run | Prerequisites and effects |
|---|---|---|
| `verify-package-contract.ps1` | After package, framework, migration or analyzer guidance changes: rejects stale package advice and enforces compatibility, existing-project preservation and package-source guidance. | PowerShell and the shipped SKILL.md; reads text, no package installation or network access. |
| `verify-editorconfig-guidance.ps1` | After formatter/editorconfig guidance changes: checks that an active assignment in the applicable C# section is required, rather than accepting comments/examples as evidence. | PowerShell and the shipped SKILL.md; text-only assertions. |
| `verify-scaffold-fixture.ps1` | After skeleton or tool/package contract changes: builds a real class-library/xUnit `.slnx` fixture, formats it, restores, builds and runs its tests. | Not shipped in this mirror, because it needs a package feed this mirror cannot reach; it runs against the canonical copy. .NET 10 SDK, network access to NuGet and the private GitHub Packages feed, `GITHUB_PACKAGES_TOKEN` with read access and `GITHUB_PACKAGES_OWNER`. Installs fixture tools/packages and writes a unique temporary tree; restores location and removes that tree in `finally`. |

The fixture explicitly reports SKIP and returns when either feed environment
variable is missing. That is not a pass or evidence that the generated project
works. Missing SDK, failed authentication or failed tool/build/test commands are
failures, not documented skips. Do not print the token when reporting results.
Record the command, decisive output and any skipped coverage separately.
