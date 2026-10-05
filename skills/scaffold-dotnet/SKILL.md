---
name: scaffold-dotnet
description: Use when creating a new .NET project or solution, or when applying standard project preferences to an existing .NET codebase. Triggers include dotnet new, solution restructuring, adding projects to a solution, or when the user asks to set up, scaffold, or normalize a .NET project.
---

# Scaffold .NET

## Checklist

Use Preferences below as the complete scaffold contract; this checklist records completion, rather than repeating its settings.

- [ ] Confirm existing layout/target preservation and authorized migrations.
- [ ] Apply Solution Structure, Project Defaults, Date and Time, Code Style and Analysis, and Resource Files.
- [ ] Invoke `scaffold-tests` for tests and `scaffold-ci` for visibility-appropriate workflows/security/review-policy rules.
- [ ] Resolve package versions, restore, build, and test against the documented exceptions.
- [ ] Run repository-local formatting and its check; isolate initial formatting from semantic changes.

## Overview

Apply standard .NET project and solution preferences when creating new projects or normalizing existing ones. Existing-project normalization preserves its target frameworks and layout unless a migration is explicitly authorized.

## When to Use

- Creating a new .NET solution or project from scratch
- Adding a new project to an existing solution
- Restructuring or normalizing an existing .NET project to match preferred conventions. For a large existing estate, consider `audit-dotnet-estate` first (read-only survey) before this skill makes edits.
- When asked to "scaffold", "set up", or "initialize" a .NET project

## When NOT to use / disambiguate

- **ASP.NET Core web API created from scratch**: For a new minimal API, run
  `scaffold-dotnet` first and then `scaffold-minimal`. Use `scaffold-minimal`
  directly only for converting controllers or adding minimal endpoints, OpenAPI,
  or Scalar to an existing project.
- **Estate-wide read-only conformance audit** — use `audit-dotnet-estate`, not
  this modifying skill.

## Example — minimal CLI skeleton

This demonstrates solution layout and repository-local formatting only. It
intentionally omits the complete scaffold's `Directory.Build.props`,
`Directory.Packages.props`, `.gitignore`, `nuget.config`, CodeStyle and NodaTime
references, tests, Dependabot, CI, and Solution Items; apply the checklist and
the named sibling skills for those surfaces.

```powershell
# 1. Create solution and layout
#    `dotnet new sln` writes the solution file into the current directory and does
#    not create a folder for it, so make the folder first.
mkdir YourOrg.Example
cd YourOrg.Example
dotnet new sln -n YourOrg.Example
mkdir src, tests

# 2. Add repository-local formatter files
cp ~/.claude/resources/dotnet-thin.editorconfig .editorconfig
#    - Tool manifest. `-o .config` is required: since the .NET 10 SDK, a bare
#      `dotnet new tool-manifest` writes ./dotnet-tools.json, not .config/dotnet-tools.json.
dotnet new tool-manifest -o .config
dotnet tool install csharpier --version 1.3.0

# 3. Add projects and wire them in the solution
dotnet new classlib -n YourOrg.Example.Core -o src/YourOrg.Example.Core
dotnet sln add src/YourOrg.Example.Core/YourOrg.Example.Core.csproj

# 4. Format and verify
#    Build the .slnx the SDK created in step 1 — `dotnet new sln` emits .slnx by default.
dotnet tool restore
dotnet csharpier format .
dotnet build YourOrg.Example.slnx --configuration Release
```

## Preferences

### Solution Structure

- Use `.slnx` format (XML-based, SDK 9+) for new solutions. Preserve an existing solution format unless migration is explicitly authorized.
- `src/` folder for production projects
- `tests/` folder for test projects
- Preserve an existing project's layout unless relocation is explicitly authorized
- A **Solution Items** solution folder containing:
  - `Directory.Build.props` (common project settings)
  - `Directory.Packages.props` (central package management)
  - `.editorconfig` — thin formatter stub (copied from `~/.claude/resources/dotnet-thin.editorconfig`) with layout settings plus documented Roslyn formatter-compatibility preferences; analyzer/style **rules** remain owned by `<YourOrg.CodeStyle>` — see *Code Style and Analysis* below
  - `.gitattributes` — `*.cs text eol=crlf`, so CSharpier sees the same line endings on every runner
  - `.csharpierignore` — excludes XML-family files; CSharpier formats C# only
  - `.config/dotnet-tools.json` — repository-local tools, including CSharpier `1.3.0`
  - `.gitignore` (copied from `~/.claude/resources/.gitignore`)
  - `nuget.config` (maps the <your-org> GitHub Packages feed — see Code Style and Analysis)
  - `.github/workflows/` folder
- A `.github/dependabot.yml` file (copied from `~/.claude/resources/dependabot.yml`)

### Project Defaults

- New projects target `net10.0`.
- Preserve an existing target framework (for example, an intentional `netstandard2.0` library) unless migration is explicitly authorized.
- `Nullable`: enable
- `ImplicitUsings`: enable
- Examples must use syntax compatible with the project's declared language version; do not assume C# 12 features.
- Read `~/.agents/notes/dotnet-runtime-traps.md` before normalising packages
  (if that note is not present, proceed and record the assumption).
  Prefer the newest stable release that the target stack can restore, build,
  and test; TFM metadata alone does not prove compatibility. Preserve documented
  exception pins, including `Microsoft.OpenApi` 2.x with the .NET 10
  `Microsoft.AspNetCore.OpenApi` generator, until the note's build-based
  refutation condition passes.
- These shared settings should be defined in `Directory.Build.props` where possible

### Date and Time

New projects default to NodaTime for date/time handling (see the date/time section of the global `CLAUDE.md`). When scaffolding:

- Add `NodaTime` and `NodaTime.Serialization.SystemTextJson` as `PackageVersion` entries in `Directory.Packages.props` (newest stable releases verified by restore, build, and test)
- Add a `PackageReference` only to the projects that actually handle date/time — don't blanket-reference it in `Directory.Build.props`
- Register `IClock` (`SystemClock.Instance`) in DI; never call `DateTime.UtcNow` or `SystemClock.Instance` statically. For projects that don't use NodaTime, inject .NET `TimeProvider` instead — same rule, never read the clock statically
- Wire NodaTime JSON serialization at scaffold time so the boundary plumbing is in place from the start — `ConfigureForNodaTime(DateTimeZoneProviders.Tzdb)` on the relevant `JsonSerializerOptions` (e.g. via `ConfigureHttpJsonOptions` / `AddJsonOptions`)
- For projects using EF Core, also wire NodaTime persistence — see the `ef-core` skill

### Code Style and Analysis

Code style and analyzers are delivered by the shared **`<YourOrg.CodeStyle>`** NuGet
package (from the house code-style repository), **not** by copying an `.editorconfig`.
The package ships a global AnalyzerConfig (every rule + severity), sets
`EnforceCodeStyleInBuild=true`, and bundles `SonarAnalyzer.CSharp` (pinned). One
reference makes the whole house style build-enforced, and a rule change ships as a
package version bump instead of N hand-edits to drift-prone copies.

**CSharpier owns physical C# formatting** (whitespace, wrapping, and layout).
`<YourOrg.CodeStyle>` continues to own semantic style, naming, and analyzer
diagnostics; version `0.1.11` and later disables the competing IDE0055 formatter
diagnostic. Do not add a repository-local IDE0055 override once that package
version is in use.

- Pin CSharpier `1.3.0` in `.config/dotnet-tools.json`. If the manifest already
  contains Stryker or another tool, merge the `csharpier` entry into it; never
  overwrite the manifest. The entry is:

  ```json
  "csharpier": {
    "version": "1.3.0",
    "commands": ["csharpier"],
    "rollForward": false
  }
  ```

- **APPEND** `*.cs text eol=crlf` to `.gitattributes`; never create or replace that file
  here. If the repository's seed commit already wrote it, its `* text=auto eol=lf` line is
  deliberately first: git applies the LAST matching pattern, so this line only takes effect
  by coming after it. Rewriting the file would drop the `.bat`/`.cmd`/`.sh`/`.png` rules
  already established; prepending would make this line dead. On a repository without that
  file, create it with `* text=auto eol=lf` first and this line after it.
- Add `.csharpierignore` containing `*.csproj`, `*.props`, `*.targets`, `*.xml`,
  `*.config`, `*.slnx`, `*.xaml`, and `*.axaml`. Do not add a separate
  `.csharpierrc.json`; the shared `.editorconfig` is the single printer config.
- Run `dotnet tool restore` and `dotnet csharpier format .` after scaffolding.
  For an existing repository, commit this mechanical formatting separately from
  configuration or semantic changes. Do not add `CSharpier.MsBuild`, a pre-commit
  hook, or a mandatory editor extension; `scaffold-ci` owns the required check.

- Add to `Directory.Build.props` so it applies to every project:

  ```xml
  <ItemGroup>
    <PackageReference Include="YourOrg.CodeStyle" PrivateAssets="all" />
  </ItemGroup>
  ```

  Do not specify a literal `Version="<latest>"` — `<latest>` is not a valid NuGet
  version. `<YourOrg.CodeStyle>` is private, so query its authenticated GitHub
  Packages versions and select the highest stable release:

  ```powershell
  gh api -H "Accept: application/vnd.github+json" "/orgs/YourOrg/packages/nuget/YourOrg.CodeStyle/versions?per_page=100" --paginate --jq '.[].name'
  ```

  Pin that concrete result centrally in `Directory.Packages.props` — the version
  below stands in for whatever that query returned:

  ```xml
  <PackageVersion Include="YourOrg.CodeStyle" Version="1.4.2" />
  ```

  Keep the versionless shared `PackageReference` in `Directory.Build.props`.
  Do not run an unqualified project-scoped package-add command from the solution
  root; it either fails to find a project or edits the wrong scope. If package
  discovery or feed authentication fails, stop and report the gap rather than
  guessing a version.

- Copy a genuinely **thin formatter `.editorconfig`** to the solution root —
  `~/.claude/resources/dotnet-thin.editorconfig`, saved as `.editorconfig`. It carries
  layout primitives (charset, indentation, EOL, trimming, final newline), C#
  max-line-length (**which CSharpier reads as its print width** — see the existing-repo
  warning below before copying this into a formatted tree), and the documented
  IDE0011/IDE0049 compatibility preferences.
  CSharpier supplies its own spacing and wrapping behavior. Analyzer rules and severities still belong to
  the NuGet-shipped global config; however, `dotnet format` 10.0.204 does not activate those
  two fixers from a packaged global config alone, so their package-owned values are repeated
  locally. A bare whitespace key (`indent_size`, `charset`, `end_of_line`,
  `trim_trailing_whitespace`) is not a diagnostic at all — `dotnet format`/the IDE read it only
  from a real `.editorconfig` on disk, so no NuGet package can deliver it. That is the whole
  reason a project-local `.editorconfig` still exists once `<YourOrg.CodeStyle>` is referenced.
  These compatibility entries do not create a second rule source. **Do not copy
  `~/.claude/resources/.editorconfig`** (no `-thin` suffix) into a project — that
  file is the **full** house style (every analyzer/naming/CA/IDE severity, pre-`<YourOrg.CodeStyle>`
  legacy — see *Resource Files* below) and copying it wholesale reproduces the exact
  rule-duplication this section exists to avoid. Do **not** use `<YourOrg.CodeStyle>`'s
  `assets/consumer.editorconfig` instead — if the two formatter-only sources ever differ,
  `~/.claude/resources/dotnet-thin.editorconfig` wins. Add a local rule override only for a
  genuine project-specific need, with a comment why (e.g. re-enabling culture rules
  CA1304/1307/1308/1309/1311 in a service that serves localized text) — such an override
  necessarily carries a `:severity` suffix, so it belongs in the project's own `.editorconfig`,
  never merged back into the thin template.
- **Do not** add `SonarAnalyzer.CSharp` separately — the package bundles it. The `S3776`
  cognitive-complexity gate (prefer cognitive over cyclomatic, which over-counts flat
  `switch`/ternary dispatch) and the full CA/IDE/Sonar suppression set all live in the
  package's global config.
- File-scoped namespaces, always-brace (IDE0011), no-redundant-parens (IDE0047), etc. are
  enforced at `error` severity — they fail the build via `EnforceCodeStyleInBuild`,
  independent of `TreatWarningsAsErrors`. Sonar S-rules are warning-level by default;
  they become build-blocking when a consumer enables `TreatWarningsAsErrors`. Do not
  rename existing projects.
- After adding the package to an **existing** project, run `dotnet format` once to apply
  semantic rules, then run CSharpier, build, and test before committing.
- **`max_line_length` is CSharpier's print width, not documentation.** The template states
  `120`; CSharpier's own default is `100`. On a NEW scaffold either is fine because nothing is
  formatted yet. On an **existing** repo, copying the template blind re-wraps every C# file
  that was formatted at a different width — 819 files in one estate repo, a diff
  that buries whatever change you were actually making. Measure before you copy:

  Treat only an active assignment in an applicable C# section as configured; comments and
  examples do not count. A value under an unrelated section is not the repository's CSharpier
  width.

  ```
  dotnet csharpier check .          # clean at the repo's current width
  ```

  Run it with the template's `120` in place. Failures mean the tree is not at 120, and you
  have two honest options — never the third one of letting it happen by accident:

  1. **Adopt 120 and reformat deliberately, in its own commit.** This is the default. The
     template width is canonical, and a per-repo width means every later `scaffold-dotnet`
     sync has to argue with that repository. The churn only ever gets more expensive, so take
     it while the repo is not yet load-bearing.
  2. **Pin the width the tree already is**, with a comment giving the reason and what would
     justify raising it later. Correct when a reformat cannot be afforded right now — an
     in-flight branch it would conflict with, or a review budget it would swamp.

  Whenever the reformat happens — now on route 1, or later on route 2 — it is a **standalone
  commit and its own PR**, never a side effect of adopting house style. It needs that scoping
  for a practical reason: CodeRabbit refuses a PR over 300 files, so a whole-repo rewrap left
  in with real changes makes the reviewable part unreviewable too.

  **Validate it with a build and a full test run.** A diff comparison is supporting evidence,
  not the gate. Stripping whitespace **and** CSharpier's dangling commas from both sides and
  comparing byte-for-byte is a genuinely strong signal — equality over the ordered character
  stream rules out moved `lock`/`using`/`try` scopes and reordered statements, which
  `git diff -w` alone does not. But it is **not** proof behaviour is unchanged: stripping
  whitespace makes it blind to whitespace inside verbatim (`@"..."`) and raw (`"""..."""`)
  string literals, which is precisely where a real change would hide. Never report a reformat
  as semantics-free on the strength of the diff alone.

  One estate repo took route 2 first — pinned 100, with the
  deviation documented in its own `.editorconfig` — then switched to route 1 once the cost of
  carrying a per-repo width was understood, reformatting 516 files in its own follow-up PR.

  Refuted if `dotnet csharpier check .` ever passes at both widths on the same tree.

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
    <add key="YourOrg" value="https://nuget.pkg.github.com/YOUR_ORG/index.json" />
  </packageSources>
  <packageSourceCredentials>
    <YourOrg>
      <add key="Username" value="YOUR_ORG" />
      <add key="ClearTextPassword" value="%GITHUB_PACKAGES_TOKEN%" />
    </YourOrg>
  </packageSourceCredentials>
  <packageSourceMapping>
    <packageSource key="YourOrg"><package pattern="YourOrg.*" /></packageSource>
    <packageSource key="nuget.org"><package pattern="*" /></packageSource>
  </packageSourceMapping>
</configuration>
```

`YOUR_ORG` is the GitHub org hosting the private feed; supply it explicitly.

Use `YourOrg.*` in the source mapping, not an exact package name like `<YourOrg.CodeStyle>`.
Exact matches break as soon as a second first-party package is added (e.g. `<YourOrg.CodeStyle>.ArchRules`
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
`<YourOrg.CodeStyle>` global config (`suggestion`, non-blocking) — not in the
formatter-only `.editorconfig`.

### Resource Files

The following files are copied into the new solution. The `.gitignore` and
`dependabot.yml` source files are owned by the Claude-config repository under
`~/.claude/resources/`; `scaffold-ci` owns their placement and Dependabot path selection.

**`~/.claude/resources/` is the Claude runtime home, not a shared location.** Codex,
Kimi Code and both Antigravity runtimes mount this skill but have no such directory,
so on those runtimes the copy commands below have no source. From a runtime other
than Claude Code, take these assets from a checkout of that repo, or supply
equivalents — and say which you did, rather than scaffolding a solution that is
silently missing its formatter stub or its Dependabot config.

There are **two** `.editorconfig`-shaped files in `~/.claude/resources/` and they do
different jobs — do not confuse them:

| File | Role | Source | Destination |
|------|------|--------|-------------|
| `dotnet-thin.editorconfig` | Formatter layout plus documented IDE0011/IDE0049 compatibility preferences — what gets copied into a new scaffold | `~/.claude/resources/dotnet-thin.editorconfig` | Solution root, as `.editorconfig` |
| `.editorconfig` | **Full** house style (formatting + naming + every analyzer/CA/IDE severity) — pre-`<YourOrg.CodeStyle>` legacy; the master the package's global config is generated from | `~/.claude/resources/.editorconfig` | Not copied into a project that references `<YourOrg.CodeStyle>` — see below |
| `.gitignore` | — | `~/.claude/resources/.gitignore` | Solution root |
| `dependabot.yml` | — | `~/.claude/resources/dependabot.yml` | `.github/dependabot.yml` |

> `~/.claude/resources/.editorconfig` predates `<YourOrg.CodeStyle>` and is honestly a **full**
> ruleset, not a stub — it still carries every CA/IDE/naming severity the package now also
> ships. It is kept for two reasons: as the master the package's global config is regenerated
> from, and as a self-contained fallback for the rare repo that does **not** reference
> `<YourOrg.CodeStyle>` at all — that repo copies it in full, with no package dependency. For
> any project that **does** reference the package, only `dotnet-thin.editorconfig` is copied;
> copying the full file too would duplicate every rule the package already build-enforces. When
> house style changes: edit the master (`.editorconfig`) and mirror formatter-layout changes
> into `dotnet-thin.editorconfig`; for analyzer rules, regenerate the package's
> `<YourOrg.CodeStyle>.globalconfig` and release a new package version. Mirror a rule preference
> into the thin file only when a regression test proves its fixer requires a hierarchical
> `.editorconfig`, and document it as a compatibility entry.
