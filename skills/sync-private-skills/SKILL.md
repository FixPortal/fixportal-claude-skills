---
name: sync-private-skills
description: Use when reconciling authored skills between the two PRIVATE homes — ~/.claude/skills/ (Claude Code) and ~/.agents/skills/ (Codex/Antigravity) — e.g. "sync my Claude and Codex/Antigravity skills", skill drift across CLIs, or after audit-skills reports cross-home divergence. For private↔private mirroring, NOT the public sanitised mirror (that is sync-public-skills).
---

# Sync Private Skills

## Overview

The user authors skills in **two private homes** and edits in **either**,
depending on which CLI they are in:

- `~/.claude/skills/` — Claude Code
- `~/.agents/skills/` — Codex / Antigravity

Drift is therefore **two-directional**: a given skill's newer copy may be in
*either* home. This skill **reconciles** the two — it does not blindly copy one
over the other.

**Core principle: detect which side changed, then propose — never assume a
global winner, never overwrite without showing the diff and getting a yes.**

Both homes hold the same real paths, so this is a **straight copy with NO
sanitisation** — unlike `sync-public-skills` (private→public, which transforms
client names / vault paths / emails). Do not apply the sanitisation map here.

**Composes with `audit-skills`:** that skill is the read-only *detector* of
cross-home drift; this skill is the *resolver*. Run audit-skills to learn what
diverged; run this to reconcile it.

## What is mirrored

The mirror set is the **intersection** of skill folders present in **both**
homes. A skill in only one home (today: `hone`, `observe` are Claude-only) is
**reported, not copied** — adding a skill to the other home is an explicit
**curation decision the user makes**, not an automatic sync.

## The Iron Law

```
NEVER overwrite a private skill file without (1) showing its diff,
(2) naming which side changed, and (3) getting explicit confirmation.
No -Force blind copies. No blanket "X is the source of truth."
```

Violating the letter of this is violating the spirit. "It's obviously newer",
"they're basically the same", "the user clearly wants Claude to win" — all mean
STOP and surface the diff.

## Direction detection — the last-sync manifest

Guessing direction from mtime alone is unsafe (a copy resets mtime; a stale edit
looks fresh). Instead keep a manifest of the content hash of each mirrored file
**as of the last successful sync**, at:

`~/.claude/skills/sync-private-skills/.last-sync-manifest.json`
(`{ "<skill>/<relative-path>": "<sha256>" }`)

For each differing file, compare both homes' current hash against the manifest:

| .claude vs manifest | .agents vs manifest | Meaning | Action |
|---|---|---|---|
| changed | unchanged | **.claude** was edited | propose `.claude → .agents` |
| unchanged | changed | **.agents** was edited | propose `.agents → .claude` |
| changed | changed | **both** edited | **true conflict** — surface diff + both mtimes, do NOT auto-pick |
| (no manifest yet / first run) | — | unknown | treat every diff as a conflict to surface |

mtime is shown only as a secondary *hint* next to the diff — never as the basis
for an automatic overwrite.

## Intentional divergence registry

Some files differ **by design per host** (e.g. `adversarial-review/reviewers.json`
— the panel composition is host-specific: Claude honours the Opus-approval rule,
the Codex copy warns against a same-vendor Gemini judge). List such paths in
`intentionally-divergent.md` (this skill's directory). Files listed there are
reported as "intentionally divergent — skipped" and are **never** synced or
re-flagged. Add to it (with a reason) whenever the user confirms a divergence is
deliberate.

## Procedure

1. **Enumerate both homes.** Glob `~/.claude/skills/*/` and `~/.agents/skills/*/`.
   Compute the **intersection** (mirror set) and the **single-home-only** list.
   Report the single-home list; take no action on it.
2. **Load** `.last-sync-manifest.json` (may be absent) and `intentionally-divergent.md`.
3. **Compare every file** in each mirrored skill (SKILL.md + all supporting
   files) by content hash. Identical both sides → in sync, skip.
4. **Skip registered divergences** — report them, don't touch.
5. **Classify each remaining diff** via the manifest table above into:
   one-sided (propose the copy in the changed→unchanged direction) or
   two-sided **conflict** (surface only).
6. **Present the plan**: a table of proposed copies (with direction + diff) and a
   separate list of unresolved conflicts + skipped/curation items. **Confirm
   before writing anything.**
7. **Apply confirmed copies** with a plain `Copy-Item` (recurse for whole new
   files), preserving bytes/encoding — no transform. For a conflict, only act on
   the direction the user explicitly chooses.
8. **Update the manifest** with the new post-sync hashes for every reconciled
   file. Report what synced, what was skipped (identical / intentional /
   curation), and any conflict left unresolved.

## Common Mistakes

| Mistake (seen in baseline) | Reality |
|---|---|
| Auto-copying single-home skills to "make them match" | Intersection only. A missing skill is a curation call — report it, don't copy it. |
| "Claude is the source of truth for everything that differs" | Direction is **per file**, detected via the manifest. The user edits both homes. |
| Inferring intent from file contents to decide direction | Use the manifest (who changed), not a guess about what the change means. |
| `Copy-Item -Force` straight from the plan | Show the diff, name the changed side, confirm. Then copy. |
| Clobbering an intentionally per-host file (reviewers.json) | Honour `intentionally-divergent.md`. When unsure if a divergence is deliberate, surface it — don't resolve it. |
| Applying the sanitisation map | That's `sync-public-skills`. Private↔private is a verbatim copy. |

## Red Flags — STOP

- You typed `-Force` or `Copy-Item` before showing a diff and getting a yes.
- You picked a global direction ("Claude wins") instead of per-file detection.
- You're about to copy a skill that exists in only one home.
- You decided a divergence is "intentional" or "stale" by reading the content
  instead of checking the manifest / registry / asking.
- You skipped reading `intentionally-divergent.md` this run.
