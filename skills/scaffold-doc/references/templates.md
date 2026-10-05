# Document templates

## Contents

- [Doc-type sub-templates](#doc-type-sub-templates)
- [README (repo root or NuGet package)](#readme-repo-root-or-nuget-package)
- [ADR (Architecture Decision Record)](#adr-architecture-decision-record)
- [Dual-destination handling (repo + vault)](#dual-destination-handling-repo--vault)


Read the destination-specific template before authoring a README, ADR, or dual repo/vault document.

## Doc-type sub-templates

### README (repo root or NuGet package)

READMEs differ from audit reports: no actions-taken ledger, no Azure ID
appendix, `author` omitted from repo-committed frontmatter, plain description
over executive summary. A README rendered by the **NuGet gallery** must omit
YAML frontmatter and use plain `>` only; its Markdig feature set does not
support YAML metadata or GFM alert blocks. An ordinary GitHub README must also
omit frontmatter because its standard renderer does not consume it, although it
may use GitHub callouts. Use frontmatter only for a destination that explicitly
parses it, such as an Obsidian vault note or configured Jekyll/GitHub Pages site.
When the destination is unclear, omit frontmatter and use plain `>` so the file
renders cleanly in both places.

```markdown
---  frontmatter only for a destination with a parser; OMIT for GitHub/NuGet README  ---
<!-- badge row: version · build · license -->
# Package / Project Name

> One-line description of what this is and who it is for.

## Quick start          ← install + minimal working example, copy-pasteable
## Configuration        ← all keys / options in a table
## API reference        ← if a library; skip for apps
## Compatibility        ← TFM / runtime version matrix (NuGet packages always)
## Troubleshooting      ← symptom → cause table (§4 shape)
## Contributing         ← PR conventions, test command, branch policy
## Appendix             ← install commands, package IDs, feed URLs (untruncated)
```

**Badge row** immediately after frontmatter:

```markdown
![NuGet](https://img.shields.io/nuget/v/Example.PackageName)
![Build](https://github.com/example-org/example-repo/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/github/license/example-org/example-repo)
```

**Compatibility table** (always for NuGet packages; apps only if runtime requirements are non-obvious):

```markdown
| Version | .NET | Notes |
|---|---|---|
| 2.x | net9.0, net10.0 | Current |
| 1.x | net8.0 | LTS, security fixes only |
```

**Quick start must be copy-pasteable** — install command → minimal `Program.cs` → minimal config. No prose preamble. Reader reaches a working state in under 60 seconds.

**Contributing commands for a C# repository using the pinned CSharpier tool** —
list each command in its own copy-pasteable block, adapted to the real solution name:

```powershell
dotnet tool restore
```

```powershell
dotnet csharpier format .
```

```powershell
dotnet build <solution>.slnx --configuration Release
```

```powershell
dotnet test <solution>.slnx --configuration Release --no-build
```

Explain that CI runs `dotnet csharpier check .`, which validates without rewriting
files. Format-on-save may be recommended but remains optional. Do not document a
global CSharpier install, `CSharpier.MsBuild`, or a mandatory editor extension; the
repository-local manifest is authoritative.

**Trim from README**: executive summary (replace with orientation blockquote), actions-taken ledger (omit entirely), recommendations section (omit — README is documentation, not an audit verdict). Mermaid diagrams: include only if architecture or data flow is genuinely non-obvious — the load-bearing bar is higher for a README.

### ADR (Architecture Decision Record)

```
---
# Frontmatter only for a destination with a parser; for an ordinary
# repo-committed ADR omit the whole frontmatter block, both delimiters included.
title: ADR-NNN — <decision title>
date: YYYY-MM-DD
status: proposed | accepted | deprecated | superseded by ADR-NNN
tags: [architecture, decision]
---

# ADR-NNN — <decision title>

## Context
What situation forced this decision? What constraints apply?

## Decision
What was decided, stated plainly in one sentence.

## Consequences
What is now easier / harder / different as a result? Honest trade-offs.
```

No appendix unless the decision references external IDs. No diagrams unless topology is the point.

## Dual-destination handling (repo + vault)

When a doc serves both a repo root and the Obsidian vault, maintain two separate files — the frontmatter and callout conventions are incompatible:

- **Repo copy** — minimal: no `author`, no `last-updated`, no `tags`; badge
  row present; no vault paths. Omit YAML frontmatter and use plain `>` for an
  ordinary GitHub or NuGet README. A configured Jekyll/GitHub Pages copy may
  retain frontmatter and callout blocks when that destination consumes them.
- **Vault copy** — enriched: full frontmatter with `author`, `tags`, `last-updated`; callout blocks for warnings/notes; may carry additional context not appropriate for a public README.
