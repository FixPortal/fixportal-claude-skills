---
name: scaffold-doc
description: Use when shaping supplied findings or content into a structured Markdown README, audit/cost report, ADR, technical note, runbook, or vault document. Triggers include "write a README", "draft this report", "make a proper write-up", "normalize this doc", and "write an ADR". Do not use for discovering, mapping, or analyzing an unfamiliar codebase's architecture; route that work to document-architecture.
---

# Scaffold Doc

## Overview

Turn already-supplied material into a scannable, auditable Markdown document. Lead with the conclusion, orient the reader before detail, and use tables or diagrams only when they carry information.

## Choose the destination first

| Deliverable | Required reference |
|---|---|
| README, ADR, or repo/vault pair | [Templates](references/templates.md) |
| Audit, cost report, technical report, runbook | [Report shape](references/report-shape.md) |
| Any document | [House conventions](references/conventions.md) |
| Any diagram | [Diagram renderers](references/diagram-renderers.md) |
| Final review | [Common mistakes](references/common-mistakes.md) |

For a document serving both a repository and Obsidian, maintain separate files: renderer and metadata rules differ. Use YAML frontmatter only where the destination consumes it; ordinary GitHub and NuGet-rendered READMEs omit it, while vault documents consume it. NuGet-rendered READMEs also omit GitHub callouts. Repo-committed files omit personal `author`; vault documents include useful metadata, tags, and `last-updated` for living documents.

## Core conventions

- Put a plain orientation blockquote immediately under the H1: scope, currency, and units.
- Use real YAML frontmatter where the destination supports it; never simulate metadata with bold lines.
- Lead reports with the headline finding. Give tables plain-English columns and right-align numbers.
- Add a diagram only when hierarchy, flow, or distribution is materially clearer than prose or a table, then pick its renderer by the figure's job — Mermaid to track a moving target, `diagram-design` when landing with a reader is the deliverable. Never by where the file is stored.
- When a failure or surprise motivated the document, map symptom to cause.
- Keep exact, untruncated identifiers and reproducible commands in an appendix.
- READMEs use quick start and troubleshooting, not an audit ledger. ADRs state context, decision, and consequences.
- When controlling a documentation page's layout, use the available main-column width. Do not impose narrow `ch`, `max-w-prose`, or nested article caps by default; keep navigation compact and let wide tables and code scroll locally on small screens. See [House conventions](references/conventions.md#documentation-page-width).

## Procedure

1. Confirm audience, destination, source material, currency date, and whether the document is living or point-in-time.
2. Select and read the applicable references above.
3. Draft in inverted-pyramid order. Preserve uncertainty and source boundaries; do not invent findings to fill a template.
4. Validate links, code blocks, tables, commands, and Mermaid with the destination renderer or its closest available check.
5. Re-read for duplicated sections, decorative diagrams, truncated identifiers, and destination-incompatible metadata.

## Compact checklist

- [ ] Conclusion and orientation appear before detail.
- [ ] Metadata matches the renderer and destination.
- [ ] Every table and diagram earns its space.
- [ ] Commands are complete and copy-pasteable.
- [ ] IDs, dates, units, caveats, and sources are reproducible.
- [ ] README, ADR, and report conventions are not mixed.
