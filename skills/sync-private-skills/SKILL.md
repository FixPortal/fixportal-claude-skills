---
name: sync-private-skills
description: Use when reconciling authored skills between the four PRIVATE homes — ~/.claude/skills/ (Claude Code), ~/.agents/skills/ (Codex/Copilot), ~/.gemini/config/skills/ (Antigravity), and ~/.kimi-code/skills/ (Kimi Code) — e.g. "sync my private skills", skill drift across CLIs, or after audit-skills reports cross-home divergence. For private↔private mirroring, NOT the public sanitised mirror (that is sync-public-skills).
---

# Sync Private Skills

## Overview

The user authors skills in **four private homes** — `~/.claude/skills/`,
`~/.agents/skills/`, `~/.gemini/config/skills/`, and `~/.kimi-code/skills/` —
and edits in **any**, depending on which CLI they are in:

- `~/.claude/skills/` — Claude Code
- `~/.agents/skills/` — Codex / Copilot
- `~/.gemini/config/skills/` — Antigravity
- `~/.kimi-code/skills/` — Kimi Code

Note: `~/.agents/skills/` is already scanned by Kimi, so a skill there is
visible to Kimi without copying. `~/.kimi-code/skills/` is for skills authored
**Kimi-first** that must flow back to the other homes, or skills that stay
Kimi-native (Kimi-specific paths / placeholders — register those in
`intentionally-divergent.md`).

Drift is therefore **multi-directional**: a given skill's newer copy may be in
any home. This skill **reconciles** the four — it does not blindly copy one
over the others.

**Core principle: detect which side changed, then propose — never assume a
global winner, never overwrite without showing the diff and getting a yes.**

All four homes hold the same real paths, so this is a **straight copy with NO
sanitisation** — unlike `sync-public-skills` (private→public, which transforms
client names / vault paths / emails). Do not apply the sanitisation map here.

**Composes with `audit-skills`:** that skill is the read-only *detector* of
cross-home drift; this skill is the *resolver*. Run audit-skills to learn what
diverged; run this to reconcile it.

## What is mirrored

The mirror set is the **intersection of skill folders present in at least two**
of the four homes. When a skill is in the mirror set, it is synchronized across
all homes that hold it (copied to a missing home only on explicit curation, and
kept in sync where present). A skill in only one home (today: `hone`, `observe`
are Claude-only) is **reported, not copied** — adding a skill to another home is
an explicit **curation decision the user makes**, not an automatic sync.

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
(`{ "<skill>/<relative-path>": "<sha256>" }`) — the **authoritative** copy lives
in `.claude` only; the `.agents`/`.gemini`/`.kimi-code` copies are inert
artefacts of mirroring this skill's own folder (see `intentionally-divergent.md`).

For each differing file, compare **all four** homes' current hash against the
manifest. The rule is by count of changed homes, not a per-combination table:

| Homes changed vs manifest | Meaning | Action |
|---|---|---|
| exactly one (`.claude` **or** `.agents` **or** `.gemini` **or** `.kimi-code`) | that home was edited | propose copy from the changed home → the other homes **that already hold the skill** (an absent home stays a curation call, never an auto-copy target) |
| two or more | **conflict** | surface diffs, do NOT auto-pick a winner |
| none (differs but all match manifest — impossible unless manifest stale) | stale manifest | treat as conflict, surface |
| (no manifest yet / first run) | unknown | treat every diff as a conflict to surface |

A home that does not hold the skill at all is simply excluded from its
comparison — a mirror-set file present in three homes is reconciled across those
three; the fourth is a curation call, not a diff.

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

1. **Enumerate all four homes.** Glob `~/.claude/skills/*/`, `~/.agents/skills/*/`, `~/.gemini/config/skills/*/`, and `~/.kimi-code/skills/*/`.
   Compute the **mirror set** (present in at least two homes) and the **single-home-only** list (present in only one home).
   Report the single-home list; take no action on it.
2. **Load** `.last-sync-manifest.json` (may be absent) and `intentionally-divergent.md`.
3. **Compare every file** in each mirrored skill (SKILL.md + all supporting
   files) by content hash. Identical both sides → in sync, skip.
4. **Skip registered divergences** — report them, don't touch.
5. **Classify each remaining diff** via the manifest table above into:
   one-sided (propose the copy in the changed→unchanged direction) or
   two-sided **conflict** (surface only).
5a. **Vendor-lock-in scan.** Before adding any file to the copy plan, grep the
   **whole candidate file** (not just the new/changed diff hunk — an unchanged
   line already in the file gets copied wholesale too) for `mcp__<server>__`
   tool references. Claude Code's MCP
   servers (`icm`, `plugin_azure`, `semgrep-guardian`, `plan`, etc.) are
   registered per-host — a Codex or Antigravity copy calling one produces
   config-error noise, not a graceful skip, even when the skill text says "if
   available". Flag any such reference found in a file proposed to copy
   **into** `.agents`, `.gemini`, or `.kimi-code` (a `.claude`-only file
   referencing its own MCP servers is fine and not flagged). Kimi has its own MCP
   config (`~/.kimi-code/mcp.json`), so an `mcp__icm__…` call copied from Claude
   fails on Kimi unless that server is registered there too. Do not silently strip or copy through —
   surface it as a **held-back item** alongside the plan: which file, which
   `mcp__` reference, and that it needs either (a) stripping into a
   host-specific variant + a new `intentionally-divergent.md` entry, or (b) the
   user confirming the server is actually available on the target host. Never
   propose the copy as-is when it carries an unreviewed `mcp__` reference.
6. **Present the plan**: a table of proposed copies (with direction + diff), the
   vendor-lock-in held-back list from step 5a, and a separate list of
   unresolved conflicts + skipped/curation items. **Confirm before writing
   anything.**
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
| Copying a file with an `mcp__icm__`/`mcp__plugin_azure__`/etc. reference straight into `.agents`/`.gemini`/`.kimi-code` | Claude-only MCP servers aren't registered on other hosts (Kimi has its own `~/.kimi-code/mcp.json`) — the "if available" gate in the skill text doesn't stop config-error noise. Run the step-5a scan, hold the file back, get a decision. (Bit `recap`/`close` — ICM calls mirrored into Codex/Antigravity, fixed 2026-07-08.) |

## Red Flags — STOP

- You typed `-Force` or `Copy-Item` before showing a diff and getting a yes.
- You picked a global direction ("Claude wins") instead of per-file detection.
- You're about to copy a skill that exists in only one home.
- You decided a divergence is "intentional" or "stale" by reading the content
  instead of checking the manifest / registry / asking.
- You skipped reading `intentionally-divergent.md` this run.
