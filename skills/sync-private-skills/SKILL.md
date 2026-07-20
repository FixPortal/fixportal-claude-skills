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
The manifest is itself a **registered intentional divergence**, so it is
**excluded** from the mirrored-file reconciliation below — never hash-compared,
diffed, or `Copy-Item`ed between homes. Only the `.claude` copy is read and written.

For each differing file, compare **all four** homes' current hash against the
manifest. The rule is by count of changed homes, not a per-combination table:

| Homes changed vs manifest | Meaning | Action |
|---|---|---|
| exactly one (`.claude` **or** `.agents` **or** `.gemini` **or** `.kimi-code`) | that home was edited | propose copy from the changed home → the other homes **that already hold the skill** (a home missing the whole skill stays a curation call; a home that holds the skill but lacks *this one file* is a new-file add target — see below) |
| two or more | **conflict** | surface diffs, do NOT auto-pick a winner |
| none (differs but all match manifest — impossible unless manifest stale) | stale manifest | treat as conflict, surface |
| **deletion** — a manifest-tracked file is now **absent** from one holding home, unchanged in the others | that home removed it (or it went missing) | a proposed **deletion**, NOT a copy — the "exactly one changed" copy rule does not apply (there is no source to copy from). Surface it; never copy from the nonexistent side, never auto-delete the other homes. Only act on an explicit choice |
| **new file** — no manifest entry, present in one holding home, absent from the other holding homes | that home added it (feature commit) | propose **adding** it to the other holding homes (step-5a scan first); a plain add, not a conflict |
| **new file** — no manifest entry, present with **identical hashes in EVERY holding home** | added independently / already mirrored everywhere, just untracked | already in sync — take no copy action, only **adopt** it into the manifest (step 8) |
| **new file** — no manifest entry, present (identical) in **some** holding homes but **absent** from others | partially replicated | NOT in sync — the present homes are the source; route each absent holding home through the one-sided **add** rule (step-5a scan first). Adopt into the manifest only once every holding home has it |
| **new file** — no manifest entry, present in **two or more** holding homes, **hashes differ** | independent divergent adds — no baseline to arbitrate | **conflict** — surface the diffs and get an explicit choice; do NOT auto-pick, do NOT record a manifest hash until resolved |
| (no manifest yet / first run) | unknown | treat every diff as a conflict to surface |

Distinguish **whole-skill absence** from **single-file absence** — conflating
them IS the new-file-blindness bug:
- A home that does **not hold the skill at all** is excluded from that skill's
  comparison — adding the whole skill to it is a curation call, not a diff.
- A home that **holds the skill but is missing a file** the manifest or another
  holding home has is a **one-sided new-file add**, NOT a curation skip. If the
  file is present in the changed home (usually `.claude`) and absent from a
  holding mirror, **propose adding it** there, subject to the step-5a
  vendor-lock-in scan. Treat an absence as a *delete* only when the manifest
  shows the file existed at last sync and the **source** home removed it — surface
  that as a conflict, never auto-delete.

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
3. **Compare every file** in each mirrored skill by content hash. Enumerate the
   file set as the **union** of every file that exists in ANY home holding the
   skill, **plus** every manifest key for that skill — never just one home's
   listing. This is load-bearing: a file a feature commit ADDED in one home
   (e.g. a new `.claude` wrapper) is absent from the others, so iterating a
   single mirror's existing files alone never sees it and the reconciler goes
   **new-file-blind** — exactly how the v2 `adversarial-review` wrappers
   `codex-review.ps1` / `kimi-review.ps1` (and `briefs/phase3.5-judge-audit.txt`)
   silently never propagated for a week while every already-present file synced
   fine. Identical across all holding homes → in sync, skip.
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
   available". Flag any such reference in a file proposed to copy into **any**
   destination home whose MCP config does not register that server — the copy
   **direction** is what matters, there is no fixed exempt home. MCP servers are
   per-host: Claude Code registers `icm` / `plugin_azure` / `semgrep-guardian` /
   `plan`; Kimi has its own (`~/.kimi-code/mcp.json`); Codex and Antigravity
   theirs. An `mcp__icm__…` ref copied from `.claude` into Kimi fails on Kimi —
   and, symmetrically, a Kimi- or Antigravity-specific `mcp__…__` ref copied
   **into** `.claude` fails there just the same, so `.claude` is NOT exempt as a
   destination. Exempt a target only when the referenced server is confirmed
   registered on that destination host (a file staying in its own home,
   referencing its own host's servers, is fine). Do not silently strip or copy through —
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
8. **Update the manifest** to reflect the **full current fileset**, not just the
   files touched this run — but only record a hash where there is a single agreed
   value to record:
   - **Converged / already-in-sync / intentionally-divergent** files → write the
     post-sync hash (for a divergent file, its agreed canonical baseline). This
     includes newly-added files that are now identical across the holding homes.
   - **Unresolved conflicts** (contents still differ across homes) → do **not**
     write a new hash. Keep the file's **previous** manifest baseline if it had
     one, and leave a newly-introduced conflicted path **unrecorded** — recording
     either home's hash would silently anoint one side as the baseline and mask
     the conflict next run.
   - **Drop** keys for files no longer present in any home.
   Rewriting only the files touched this run lets the manifest carry a stale
   fileset forward — which is what hid the missing v2 files — but baselining an
   unresolved conflict is the opposite failure, so do neither. Report what synced,
   what was skipped (identical / intentional / curation), and any conflict left
   unresolved.

## Common Mistakes

| Mistake (seen in baseline) | Reality |
|---|---|
| Auto-copying single-home skills to "make them match" | Intersection only. A missing skill is a curation call — report it, don't copy it. |
| "Claude is the source of truth for everything that differs" | Direction is **per file**, detected via the manifest. The user edits both homes. |
| Inferring intent from file contents to decide direction | Use the manifest (who changed), not a guess about what the change means. |
| `Copy-Item -Force` straight from the plan | Show the diff, name the changed side, confirm. Then copy. |
| Clobbering an intentionally per-host file (reviewers.json) | Honour `intentionally-divergent.md`. When unsure if a divergence is deliberate, surface it — don't resolve it. |
| Applying the sanitisation map | That's `sync-public-skills`. Private↔private is a verbatim copy. |
| Enumerating only one mirror's existing files (or only manifest keys) | Walk the **union** across all holding homes + manifest (step 3). A file a feature commit ADDED in `.claude` is absent from the mirrors — iterate one home's listing and it stays invisible (v2 `codex-review.ps1`/`kimi-review.ps1` silently never propagated). |
| Treating a `.claude`-new file's absence in a mirror as a curation skip | Single-file absence in a home that HOLDS the skill is a new-file **add**, not curation. Curation is only for a whole-skill-absent home. |
| Copying a file with an `mcp__icm__`/`mcp__plugin_azure__`/etc. reference straight into `.agents`/`.gemini`/`.kimi-code` | Claude-only MCP servers aren't registered on other hosts (Kimi has its own `~/.kimi-code/mcp.json`) — the "if available" gate in the skill text doesn't stop config-error noise. Run the step-5a scan, hold the file back, get a decision. (Bit `recap`/`close` — ICM calls mirrored into Codex/Antigravity, fixed 2026-07-08.) |

## Red Flags — STOP

- You typed `-Force` or `Copy-Item` before showing a diff and getting a yes.
- You picked a global direction ("Claude wins") instead of per-file detection.
- You're about to copy a skill that exists in only one home.
- You decided a divergence is "intentional" or "stale" by reading the content
  instead of checking the manifest / registry / asking.
- You skipped reading `intentionally-divergent.md` this run.
- You enumerated files from one home (or the manifest) instead of the **union**
  of all holding homes + manifest — new files added in another home are invisible
  to that, and the reconciler reports "in sync" while silently missing them.
