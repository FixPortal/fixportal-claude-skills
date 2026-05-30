---
name: scaffold-dotnet
description: Use when creating a new .NET project or solution, or when applying standard project preferences to an existing .NET codebase. Triggers include dotnet new, solution restructuring, adding projects to a solution, or when the user asks to set up, scaffold, or normalize a .NET project.
---

# Scaffold .NET

## Overview

Apply standard .NET project and solution preferences when creating new projects or normalizing existing ones. Existing projects should be updated to match these preferences.

## When to Use

- Creating a new .NET solution or project from scratch
- Adding a new project to an existing solution
- Restructuring or normalizing an existing .NET project to match preferred conventions
- When asked to "scaffold", "set up", or "initialize" a .NET project

## Preferences

### Solution Structure

- `src/` folder for production projects
- `tests/` folder for test projects
- Existing projects must be moved into the appropriate folder
- A **Solution Items** solution folder containing:
  - `Directory.Build.props` (common project settings)
  - `Directory.Packages.props` (central package management)
  - `.editorconfig` (copied from `~/.claude\resources\.editorconfig`)
  - `.gitignore` (copied from `~/.claude\resources\.gitignore`)
  - `.github/workflows/` folder
- A `.github/dependabot.yml` file (copied from `~/.claude\resources\dependabot.yml`)

### Project Defaults

- Target framework: `net10.0`
- Existing projects must be updated to `net10.0`
- `Nullable`: enable
- `ImplicitUsings`: enable
- All NuGet packages must be updated to latest release versions that support .NET 10
- These shared settings should be defined in `Directory.Build.props` where possible

### Date and Time

New projects default to NodaTime for date/time handling (see the date/time section of the global `CLAUDE.md`). When scaffolding:

- Add `NodaTime` and `NodaTime.Serialization.SystemTextJson` as `PackageVersion` entries in `Directory.Packages.props` (latest .NET 10-compatible release)
- Add a `PackageReference` only to the projects that actually handle date/time — don't blanket-reference it in `Directory.Build.props`
- Register `IClock` (`SystemClock.Instance`) in DI; never call `DateTime.UtcNow` or `SystemClock.Instance` statically
- For projects using EF Core, also wire NodaTime persistence — see the `ef-core` skill

### Code Style and Analysis

- `.editorconfig` at solution root (source: `~/.claude\resources\.editorconfig` — source-controlled in the `.claude` repo)
- File-scoped namespaces enforced via editorconfig
- Do not rename existing projects

#### Static analysis (SonarAnalyzer)

- Add `SonarAnalyzer.CSharp` as a **`GlobalPackageReference`** in `Directory.Packages.props`
  (latest release) so it applies to every project automatically — CPM treats a
  `GlobalPackageReference` as a private analyzer asset, no per-`csproj` edits needed:

  ```xml
  <ItemGroup>
    <GlobalPackageReference Include="SonarAnalyzer.CSharp" Version="<latest>" />
  </ItemGroup>
  ```

- The full Sonar recommended set runs at its default severities (warnings, **non-blocking** —
  do not set `TreatWarningsAsErrors`). Tune individual rules in `.editorconfig` via
  `dotnet_diagnostic.S####.severity`.
- **Cognitive complexity (`S3776`) is the complexity gate** — already pinned to `warning`
  in the resource `.editorconfig`. Prefer it over cyclomatic complexity, which over-counts
  flat `switch`/ternary dispatch and produces false alarms on idiomatic code.
- Triage the first-run findings by silencing noisy/stylistic rules in `.editorconfig`
  (`= none`) rather than disabling the analyzer.

### Resource Files

The following files are copied into the new solution. All are source-controlled in the `.claude` repo under `~/.claude/resources/`:

| File | Source | Destination |
|------|--------|-------------|
| `.editorconfig` | `~/.claude\resources\.editorconfig` | Solution root |
| `.gitignore` | `~/.claude\resources\.gitignore` | Solution root |
| `dependabot.yml` | `~/.claude\resources\dependabot.yml` | `.github/dependabot.yml` |

## Checklist

When scaffolding or normalizing a .NET project, verify:

- [ ] `src/` and `tests/` folders created; projects moved accordingly
- [ ] Solution Items folder added with `Directory.Build.props`, `Directory.Packages.props`, `.editorconfig`, `.gitignore`
- [ ] `.github/workflows/` folder created and added to Solution Items
- [ ] `.github/dependabot.yml` copied into place
- [ ] All projects target `net10.0`
- [ ] `Nullable` and `ImplicitUsings` enabled (via `Directory.Build.props`)
- [ ] Central package management enabled via `Directory.Packages.props`
- [ ] `SonarAnalyzer.CSharp` added as a `GlobalPackageReference`; `S3776` (cognitive complexity) at `warning`, non-blocking
- [ ] NodaTime packages added to `Directory.Packages.props`; `IClock` registered in DI
- [ ] All NuGet packages updated to latest .NET 10-compatible versions
- [ ] `.editorconfig` copied from resources
- [ ] `.gitignore` copied from resources
- [ ] No projects renamed
