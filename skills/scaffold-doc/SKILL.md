---
name: scaffold-doc
description: Use when authoring or normalizing a structured markdown document — a README, an audit or cost report, a technical note, a runbook, or any reference doc destined for a repo or the Obsidian vault. Triggers - write a README, draft an audit report, document this estate/system, "make a proper write-up", normalize this doc. Sibling of scaffold-dotnet / scaffold-ci for prose deliverables.
---

# Scaffold Doc

## Overview

Author structured markdown documents in the house style: a document that orients the reader before detail, leads with the conclusion, carries data in scannable tables and diagrams that do real work, and stays auditable and reproducible. The reference exemplar is the Acme Azure audit at `<vault>\Acme-Azure-Audit-2026-05-30.md` — when in doubt, open it and match its shape.

## When to Use

- Writing a README, audit/cost report, estate or system survey, technical note, or runbook
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
author: Claude (Opus 4.8) + Chris Dowling
status: living document
---
```

Add domain keys when they aid retrieval (`tenant`, `account`, `subscription`, `repo`, `scope`).

### 2. Orientation blockquote — immediately after the H1, not buried at the end

Before any section, a `>` blockquote tells the reader what they are looking at: **scope, currency of the data, and units.** Do not bury this as a "Caveats" section at the bottom — it is the first thing read, so it goes first.

```markdown
# Acme Azure Audit — 2026-05-30

> Snapshot of the **Acme** Azure estate as seen from `you@example.com`.
> All figures are **month-to-date (MTD)** actual cost in **USD**, pulled live via the
> Cost Management API on 2026-05-30.
```

### 3. Load-bearing mermaid — diagrams that carry information tables can't

Tables are not enough. Add a diagram wherever shape, hierarchy, or relationship is part of the message. Decoration is not the bar — *load-bearing* is. Three workhorses:

- **`pie showData`** for a distribution (cost by service, time by area, issues by severity)
- **`graph TD`** for hierarchy/topology (account → tenant → subscription → resource group; module tree)
- **`graph LR`** for relationships/flow (who calls what, data lineage, what-hosts-what)

Use node styling to make state legible: `stroke-dasharray` for absent/unreachable, a red `stroke` for the problem node, a `classDef` for dead/deleted items.

```markdown
​```mermaid
pie showData title MTD cost by service (USD)
    "SQL Database" : 57.63
    "Container Registry" : 25.14
    "Storage" : 17.18
​```
```

### 4. Symptom→cause section — name the confusion, then explain it

When the document exists because something is surprising or wrong ("nothing's running but I'm billed", "the build is green but the app 500s"), give that confusion its own section with a table that maps the surface symptom to its underlying cause. This is the section that makes the doc *teach* rather than just *report*.

```markdown
## The "nothing's running but I'm charged" explanation

Azure bills many resources on **existence, not use**:

| Resource | Charges while idle? | Why |
|---|---|---|
| Container Registry | ✅ flat per-day | Storage-tier fee regardless of pulls |
| Managed disks (deallocated VM) | ✅ | Disk capacity bills even when the VM is off |
| SQL serverless | ⚠️ storage only | Auto-pause zeroes compute after the idle delay |
```

### 5. Appendix of raw references — reproducible, untruncated

Close with an appendix carrying the full, copy-pasteable identifiers and the exact commands or API endpoints used. Never truncate an ID in the appendix (`1234abcd-…` is useless to the next person). This is what lets the doc be re-run, not just re-read.

```markdown
## Appendix — quick reference IDs

- **Subscription:** `00000000-0000-0000-0000-000000000000`
- **Tenant:** `00000000-0000-0000-0000-000000000000`
- Cost API: `POST https://management.azure.com/subscriptions/<sub>/providers/Microsoft.CostManagement/query?api-version=2023-11-01`
```

## Patterns that should already be habit

Confirm these are present; they rarely need teaching:

- **Lead with the conclusion.** The executive summary opens with the headline number/finding and the *why*, then enumerates causes. Inverted pyramid, not a slow build.
- **Right-align numeric columns** (`---:`) and give every data row a plain-English **"what it is" / "why"** column — never make the reader decode a bare identifier.
- **Actions-taken ledger.** A table of what changed during the work (action · target · result), with deferred/opted-out items recorded too. Use status markers (🗑️ deleted, ✅ confirmed) for scannability.
- **Priority-ordered recommendations**, biggest lever first.

## Document skeleton

A full report-style doc, in order. Trim sections a README doesn't need (a README keeps frontmatter, orientation blockquote, an intro, then usage — skip the ledger and cost tables).

```
---  frontmatter (title, date, author, status)  ---
# Title — date
> orientation blockquote (scope · currency · units)
## Executive summary        ← lead with the number + why
## <Data section>           ← tables (right-aligned numerics, "what it is" column)
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
| Bare identifiers in data rows | Add a plain-English "what it is" column |
| Truncated IDs (`1234abcd-…`) anywhere | Full IDs in the appendix; truncation only ever in inline prose |
| Slow build-up to the finding | Executive summary states the conclusion first |
| Diagram added for decoration | If it carries no information a table couldn't, cut it |

## Checklist

- [ ] YAML frontmatter with `title`, `date`, `author`, `status` (+ domain keys)
- [ ] Orientation blockquote directly under the H1 — scope, data currency, units
- [ ] Executive summary leads with the headline number/finding and the why
- [ ] Data tables: numeric columns right-aligned, a plain-English "what it is"/"why" column present
- [ ] At least one load-bearing mermaid diagram (pie / graph TD / graph LR) where it carries real information
- [ ] Symptom→cause section if the doc resolves a confusion or failure
- [ ] Recommendations in priority order, biggest lever first
- [ ] Actions-taken ledger (action · target · result), deferred items included
- [ ] Appendix with full untruncated IDs and the exact commands/endpoints used
- [ ] No section is decoration — every table and diagram earns its place
