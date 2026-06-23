---
name: scaffold-doc
description: Use when authoring or normalizing a structured markdown document — a README, an audit or cost report, an ADR, a technical note, a runbook, or any reference doc destined for a repo or the Obsidian vault. Triggers - write a README, draft an audit report, document this estate/system, "make a proper write-up", normalize this doc, write an ADR.
---

# Scaffold Doc

## Overview

Author structured markdown documents in the house style: a document that orients the reader before detail, leads with the conclusion, carries data in scannable tables and diagrams that do real work, and stays auditable and reproducible. The reference exemplar is the Acme Azure audit at `<vault>\Acme-Azure-Audit-2026-05-30.md` — when in doubt, open it and match its shape.

## When to Use

- Writing a **README** (repo root or NuGet package) → use the README sub-template below
- Writing an **audit/cost report, estate or system survey, technical note, or runbook** → use the report skeleton
- Writing an **ADR** (Architecture Decision Record) → use the ADR sub-template below
- Normalizing an existing doc that reads as a wall of prose or undifferentiated tables
- Any markdown deliverable headed for a repo root or the Obsidian vault (`<vault>\`)

A capable writer already produces an executive summary, sensible tables, and an actions log without being told. This skill exists for the conventions that do **not** emerge on their own — frontmatter, the orientation blockquote, load-bearing diagrams, the symptom→cause section, and the ID appendix. Spend your attention there.

## The five non-obvious conventions

These are the patterns baseline drafts consistently miss. Get these right and the rest follows.

### 1. YAML frontmatter — not a bold header block

Open with a real YAML block, not bolded `**Key:**` lines. The vault is Obsidian; frontmatter is indexed, a bold block is not. Always include `status` — most of these docs are living.

```markdown
---
title: Acme Azure Audit
date: 2026-05-30
author: Claude (Sonnet 4.6) + Chris Dowling
status: living document
last-updated: 2026-06-20
tags: [audit, azure, acme]
---
```

- `author` — vault docs and private notes only; **omit from repo-committed files** (a package README checked into source control should not carry a personal author line).
- `tags` — always include for vault docs; consistent taxonomy: `audit`, `azure`, `dotnet`, `runbook`, `architecture`, `decision`, `review`, plus project name. Tags drive Obsidian graph view and search.
- `last-updated` — required when `status: living document`; update on every substantive revision.
- Domain keys when they aid retrieval: `tenant`, `account`, `subscription`, `repo`, `scope`.

### 2. Orientation blockquote and Obsidian callouts

**Orientation blockquote** — immediately after the H1, not buried at the end. Tells the reader scope, currency of data, and units. Plain `>` syntax:

```markdown
# Acme Azure Audit — 2026-05-30

> Snapshot of the **Acme** Azure estate as seen from `you@example.com`.
> All figures are **month-to-date (MTD)** actual cost in **USD**, pulled live via the
> Cost Management API on 2026-05-30.
```

**Callout blocks** — use these (not plain `>`) for warnings, notes, and tips within sections. Both GitHub (since Sep 2023) and Obsidian render them distinctly; they are valid in repo-committed files and vault docs alike:

```markdown
> [!WARNING]
> This runbook deletes resources permanently. Verify the subscription before running.

> [!NOTE]
> All costs are MTD actuals in USD as of 2026-05-30.

> [!TIP]
> Run `az account set --subscription <id>` first to avoid operating on the wrong sub.

> [!IMPORTANT]
> If the App Service is recreated, delete the stale Key Vault role assignment before re-deploying.
```

GitHub supports: `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`. Obsidian supports all of these plus custom types. Use `[!WARNING]`/`[!CAUTION]` for destructive actions or data-loss risks. Use `[!NOTE]` for caveats, assumptions, or data currency. Use `[!TIP]` for shortcuts or non-obvious tricks. Use `[!IMPORTANT]` for critical setup or operational prerequisites. The orientation blockquote under the H1 stays as plain `>`; callout types are for inline annotation within sections.

### 3. Load-bearing mermaid — diagrams that carry information tables can't

Tables are not enough. Add a diagram wherever shape, hierarchy, or relationship is part of the message. Decoration is not the bar — *load-bearing* is. Three workhorses:

- **`pie showData`** for a distribution (cost by service, time by area, issues by severity)
- **`graph TD`** for hierarchy/topology (account → tenant → subscription → resource group; module tree)
- **`graph LR`** for relationships/flow (who calls what, data lineage, what-hosts-what)

Use node styling to make state legible: `stroke-dasharray` for absent/unreachable, a red `stroke` for the problem node, a `classDef` for dead/deleted items.

### 4. Symptom→cause section — name the confusion, then explain it

When the document exists because something is surprising or wrong, give that confusion its own section with a table mapping surface symptom to underlying cause. This is the section that makes the doc *teach* rather than just *report*. Scope: audit reports and runbooks. For READMEs, use a `## Troubleshooting` section with the same symptom → cause table shape.

### 5. Appendix of raw references — reproducible, untruncated

Close with an appendix carrying the full, copy-pasteable identifiers and exact commands or API endpoints used. Never truncate an ID (`1234abcd-…` is useless to the next person). For READMEs the appendix carries install commands and package IDs instead of internal infra IDs.

## Doc-type sub-templates

### README (repo root or NuGet package)

READMEs differ from audit reports: no actions-taken ledger, no Azure ID appendix, `author` omitted from repo-committed frontmatter, plain description over executive summary. Obsidian callout syntax is vault-copy-only (GitHub renders plain `>`).

```
---  frontmatter (title, date, status; NO author for repo-committed files)  ---
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
![NuGet](https://img.shields.io/nuget/v/YourOrg.HealthChecks)
![Build](https://github.com/YourOrg/your-repo/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/github/license/YourOrg/your-repo)
```

**Compatibility table** (always for NuGet packages; apps only if runtime requirements are non-obvious):

```markdown
| Version | .NET | Notes |
|---|---|---|
| 2.x | net9.0, net10.0 | Current |
| 1.x | net8.0 | LTS, security fixes only |
```

**Quick start must be copy-pasteable** — install command → minimal `Program.cs` → minimal config. No prose preamble. Reader reaches a working state in under 60 seconds.

**Trim from README**: executive summary (replace with orientation blockquote), actions-taken ledger (omit entirely), recommendations section (omit — README is documentation, not an audit verdict). Mermaid diagrams: include only if architecture or data flow is genuinely non-obvious — the load-bearing bar is higher for a README.

### ADR (Architecture Decision Record)

```
---
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

- **Repo copy** — minimal: no `author`, no `last-updated`, no `tags` in frontmatter; badge row present; plain `>` only (not callout blocks); no vault paths in the text.
- **Vault copy** — enriched: full frontmatter with `author`, `tags`, `last-updated`; callout blocks for warnings/notes; may carry additional context not appropriate for a public README.

## Patterns that should already be habit

Confirm these are present; they rarely need teaching:

- **Lead with the conclusion.** Executive summary opens with the headline number/finding and the *why*. Inverted pyramid, not a slow build.
- **Plain-English column in every data table.** Name it after what it contains (`Description`, `What it tests`, `Why`, `Status`) — never leave a row decodeable only from a bare identifier. Right-align numeric columns (`---:`).
- **Actions-taken ledger** (audit/report docs only — not READMEs). Table of what changed (action · target · result), deferred items included. Plain-text status markers (`[deleted]`, `[confirmed]`, `[deferred]`), no emoji.
- **Priority-ordered recommendations**, biggest lever first.

## Document skeleton (audit/report)

Full report-style, in order. README and ADR use their own sub-templates above.

```
---  frontmatter (title, date, author, status, last-updated, tags)  ---
# Title — date
> orientation blockquote (scope · currency · units)
## Executive summary        ← lead with the number + why
## <Data section>           ← tables (right-aligned numerics, description column)
   ```mermaid pie / graph```  ← load-bearing diagram
## <Per-item catalogue>      ← one subsection per major item, each self-contained
## Symptom→cause explanation ← if the doc exists to resolve a confusion
## Notable findings          ← numbered, surprising-first
## Recommendations           ← priority order, biggest lever first
## Actions taken             ← ledger: action · target · result
## Appendix — raw IDs / commands  ← untruncated, reproducible
```

## Common Mistakes

| Mistake | Fix |
|---|---|
| Bold `**Key:**` header block instead of YAML frontmatter | Use a real `---` YAML block so Obsidian indexes it |
| Scope/caveats parked at the bottom | Lead with the orientation blockquote under the H1 |
| Tables only, zero diagrams | Add load-bearing mermaid wherever shape/hierarchy/relationship matters |
| Bare identifiers in data rows | Add a plain-English description column named for what it carries |
| Truncated IDs (`1234abcd-…`) anywhere | Full IDs in the appendix; truncation only ever in inline prose |
| Slow build-up to the finding | Executive summary states the conclusion first |
| Diagram added for decoration | If it carries no information a table couldn't, cut it |
| Using report skeleton for a README | README has its own sub-template — no ledger, no executive summary, no appendix of infra IDs |
| `author` in a repo-committed README | Author is vault-doc convention; omit it from anything in source control |
| No `tags` in vault doc frontmatter | Add a `tags` array; vault docs without tags are invisible in Obsidian graph view |
| Plain `>` for warnings/notes/important caveats | Use `> [!WARNING]` / `> [!NOTE]` / `> [!IMPORTANT]` callout blocks — rendered by both GitHub and Obsidian |
| Actions-taken ledger in a new package README | Ledger is for post-hoc audit reports; omit from READMEs authored fresh |

## Checklist

**All docs:**
- [ ] YAML frontmatter with `title`, `date`, `status`
- [ ] `tags` array present (vault docs) or omitted (repo-only files)
- [ ] `last-updated` present when `status: living document`
- [ ] Orientation blockquote directly under H1 (scope, data currency, units)
- [ ] Plain-English description column in every data table; numeric columns right-aligned
- [ ] Every diagram is load-bearing

**Audit/report docs additionally:**
- [ ] `author` in frontmatter
- [ ] Executive summary leads with the headline number/finding
- [ ] At least one load-bearing mermaid diagram
- [ ] Symptom→cause section if the doc resolves a confusion or failure
- [ ] Recommendations in priority order, biggest lever first
- [ ] Actions-taken ledger (action · target · result), deferred items included
- [ ] Appendix with full untruncated IDs and exact commands/endpoints

**README additionally:**
- [ ] Badge row (version · build · license)
- [ ] Quick start is copy-pasteable end-to-end
- [ ] Compatibility / TFM table present (packages) or omitted with reason (apps)
- [ ] No `author` in frontmatter
- [ ] No actions-taken ledger
- [ ] Troubleshooting section (symptom → cause) if package has known footguns
- [ ] Appendix carries install commands and package IDs
