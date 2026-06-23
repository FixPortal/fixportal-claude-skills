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

- Use `.slnx` format (XML-based, SDK 9+) for new solutions. Migrate existing `.sln` files with `dotnet solution <file>.sln migrate`.
- `src/` folder for production projects
- `tests/` folder for test projects
- Existing projects must be moved into the appropriate folder
- A **Solution Items** solution folder containing:
  - `Directory.Build.props` (common project settings)
  - `Directory.Packages.props` (central package management)
  - `.editorconfig` — thin **formatter-only** stub (copied from `~/.claude/resources/.editorconfig`); all analyzer/style **rules** come from the `<YourOrg.CodeStyle>` package, not this file
  - `.gitignore` (copied from `~/.claude/resources/.gitignore`)
  - `nuget.config` (maps the <your-org> GitHub Packages feed — see Code Style and Analysis)
  - `.github/workflows/` folder
- A `.github/dependabot.yml` file (copied from `~/.claude/resources/dependabot.yml`)

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
- Register `IClock` (`SystemClock.Instance`) in DI; never call `DateTime.UtcNow` or `SystemClock.Instance` statically. For projects that don't use NodaTime, inject .NET `TimeProvider` instead — same rule, never read the clock statically
- Wire NodaTime JSON serialization at scaffold time so the boundary plumbing is in place from the start — `ConfigureForNodaTime(DateTimeZoneProviders.Tzdb)` on the relevant `JsonSerializerOptions` (e.g. via `ConfigureHttpJsonOptions` / `AddJsonOptions`)
- For projects using EF Core, also wire NodaTime persistence — see the `ef-core` skill

### Code Style and Analysis

Code style and analyzers are delivered by a shared **`<YourOrg.CodeStyle>`** NuGet
package (repo: `<your-org>/<your-codestyle-repo>`), **not** by copying an `.editorconfig`.
The package ships a global AnalyzerConfig (every rule + severity), sets
`EnforceCodeStyleInBuild=true`, and bundles `SonarAnalyzer.CSharp` (pinned). One
reference makes the whole house style build-enforced, and a rule change ships as a
package version bump instead of N hand-edits to drift-prone copies.

- Add to `Directory.Build.props` so it applies to every project:

  ```xml
  <ItemGroup>
    <PackageReference Include="<YourOrg.CodeStyle>" PrivateAssets="all" />
  </ItemGroup>
  ```

  Do not specify a literal `Version="<latest>"` — `<latest>` is not a valid NuGet version
  string and will fail restore. Instead, add the package without a version attribute (central
  package management via `Directory.Packages.props` controls the version), or look up the
  current release on NuGet.org and pin a concrete version (e.g. `Version="1.2.3"`). To pick
  up the newest release automatically during development, run:
  `dotnet add package <YourOrg.CodeStyle>` — this resolves and pins the latest.

- Keep only a **thin formatter-only `.editorconfig`** at the solution root (indent,
  charset, newline/spacing, file-type sections) — copy `~/.claude/resources/.editorconfig`
  to the project root as `.editorconfig`. This is the authoritative source; do **not** use
  `<YourOrg.CodeStyle>`'s `assets/consumer.editorconfig` instead — if the two ever differ,
  `~/.claude/resources/.editorconfig` wins. Do **not** copy the rule set back into it; a
  local copy re-drifts, which is exactly what the package eliminates. Add a local rule
  override only for a genuine project-specific need, with a comment why (e.g. re-enabling
  culture rules CA1304/1307/1308/1309/1311 in a service that serves localized text).
- **Do not** add `SonarAnalyzer.CSharp` separately — the package bundles it. The `S3776`
  cognitive-complexity gate (prefer cognitive over cyclomatic, which over-counts flat
  `switch`/ternary dispatch) and the full CA/IDE/Sonar suppression set all live in the
  package's global config.
- File-scoped namespaces, always-brace (IDE0011), no-redundant-parens (IDE0047), etc. are
  enforced at `error` severity — they fail the build via `EnforceCodeStyleInBuild`,
  independent of `TreatWarningsAsErrors`. Sonar S-rules stay advisory (warning,
  non-blocking). Do not rename existing projects.
- After adding the package to an **existing** project, run `dotnet format` once to apply
  the rules mechanically, then build + test before committing.

#### GitHub Packages auth (required to restore)

The package is **private** on the <your-org> GitHub Packages feed, so a token is
needed even to *restore* it — not only to publish. Add a `nuget.config` at the solution
root mapping the feed, with a `read:packages` PAT (or `GITHUB_TOKEN` in CI) supplied via
an env var — never a committed literal:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="YourOrg" value="https://nuget.pkg.github.com/YourOrg/index.json" />
  </packageSources>
  <packageSourceCredentials>
    <YourOrg>
      <add key="Username" value="YourOrg" />
      <add key="ClearTextPassword" value="%GITHUB_PACKAGES_TOKEN%" />
    </YourOrg>
  </packageSourceCredentials>
  <packageSourceMapping>
    <packageSource key="YourOrg"><package pattern="YourOrg.*" /></packageSource>
    <packageSource key="nuget.org"><package pattern="*" /></packageSource>
  </packageSourceMapping>
</configuration>
```

Use `YourOrg.*` in the source mapping, not an exact package name like `YourOrg.CodeStyle`.
Exact matches break as soon as a second package is added (e.g. `YourOrg.CodeStyle.ArchRules`
falls through to nuget.org and fails). The wildcard covers all current and future packages from
the private feed.

#### Path handling (`Path.Join` vs `Path.Combine`)

CodeQL `cs/path-combine` ("call to `Path.Combine` may silently drop its earlier
arguments") fires because `Path.Combine` discards every segment before any
argument that is **rooted** (absolute). The fix is contextual — do not blanket
find/replace `Combine`→`Join`; they diverge exactly when a later arg is rooted,
and `Combine` throws on `null` where `Join` quietly concatenates.

- **Default to `Path.Join`** for plain concatenation of fragments you control. It
  inserts one separator and never reinterprets a rooted later segment, so it can't
  silently drop earlier parts — and it clears the rule.
- **Keep `Path.Combine` deliberately** only when you either (a) *want* the
  rooted-wins behaviour (honouring a caller-supplied absolute override), or
  (b) guard the inputs first — `if (Path.IsPathRooted(segment)) throw new
  ArgumentException(...)` — making the relative-path contract explicit. In both
  cases the finding is a justified dismiss, not a fix.

#### Argument validation (BCL throw-helpers)

Use the **BCL throw-helpers** for argument validation — they ship in the runtime
(net6+) and capture the argument name via `[CallerArgumentExpression]`, so they
need no dependency and stay nullable-flow- and analyzer-aware:

- `ArgumentNullException.ThrowIfNull(x)` (net6)
- `ArgumentException.ThrowIfNullOrEmpty(s)` (net7) / `ThrowIfNullOrWhiteSpace(s)` (net8)
- `ArgumentOutOfRangeException.ThrowIfNegative/ThrowIfZero/ThrowIfNegativeOrZero/ThrowIfGreaterThan/ThrowIfLessThan` (net8)
- `ObjectDisposedException.ThrowIf(condition, this)` (net8)

For a predicate the BCL doesn't cover, write the one-liner inline — don't reach
for a library:

```csharp
if (!IsValid(value)) throw new ArgumentException("must be valid", nameof(value));
```

**Do not add `Ardalis.GuardClauses`.** The BCL helpers cover its common surface on
net8+; the rest is one-liners. A guard-clause library only earns its place on a
pre-net6 TFM, which the house default (`net10.0`) never is.

The conversion is analyzer-enforced, not `.editorconfig`-enforced: the SDK rules
**CA1510–CA1513** flag the verbose `if (…) throw new ArgumentNullException(…)`
form and offer a code-fix to the helper. Their severity is set in the
`<YourOrg.CodeStyle>` global config (advisory `warning`, matching the Sonar-S
stance) — not in the formatter-only `.editorconfig`.

### Resource Files

The following files are copied into the new solution. The `.gitignore` and
`dependabot.yml` are source-controlled in the `.claude` repo under `~/.claude/resources/`;
the `.editorconfig` is a **formatter-only stub** (the rules live in the package, not this file):

| File | Source | Destination |
|------|--------|-------------|
| `.editorconfig` (formatter-only stub) | `~/.claude/resources/.editorconfig` | Solution root |
| `.gitignore` | `~/.claude/resources/.gitignore` | Solution root |
| `dependabot.yml` | `~/.claude/resources/dependabot.yml` | `.github/dependabot.yml` |

> `~/.claude/resources/.editorconfig` is the **authoritative source** — copy it directly to
> the project root. It is also the source the package's global config is generated from; if
> `<YourOrg.CodeStyle>`'s `assets/consumer.editorconfig` ever differs, the
> `~/.claude/resources/` version wins. When the house style changes, edit the master there,
> regenerate the package's global config, and release a new package version.

## Checklist

When scaffolding or normalizing a .NET project, verify:

- [ ] `src/` and `tests/` folders created; projects moved accordingly
- [ ] Solution Items folder added with `Directory.Build.props`, `Directory.Packages.props`, `.editorconfig`, `.gitignore`, `nuget.config`
- [ ] `.github/workflows/` folder created and added to Solution Items — wire CI via the `scaffold-ci` skill (ci.yml, mutation.yml, CodeQL)
- [ ] `.github/dependabot.yml` copied into place
- [ ] All projects target `net10.0`
- [ ] `Nullable` and `ImplicitUsings` enabled (via `Directory.Build.props`)
- [ ] Central package management enabled via `Directory.Packages.props`
- [ ] `<YourOrg.CodeStyle>` added as a `PackageReference` (`PrivateAssets="all"`) in `Directory.Build.props` — brings the global config, `EnforceCodeStyleInBuild`, and bundled `SonarAnalyzer.CSharp`; do **not** add Sonar separately
- [ ] Argument validation uses BCL throw-helpers (`ArgumentNullException.ThrowIfNull` etc.); no `Ardalis.GuardClauses` reference
- [ ] `nuget.config` maps the <your-org> GitHub Packages feed; `read:packages` token wired via env var (not committed)
- [ ] NodaTime packages added to `Directory.Packages.props`; `IClock`/`TimeProvider` registered in DI; NodaTime JSON serialization wired (`ConfigureForNodaTime`)
- [ ] Test project(s) created/normalized — see the `scaffold-tests` skill
- [ ] All NuGet packages updated to latest .NET 10-compatible versions
- [ ] `.editorconfig` formatter-only stub in place (copied from `~/.claude/resources/.editorconfig`); rules NOT duplicated locally
- [ ] `.gitignore` copied from resources
- [ ] No projects renamed
