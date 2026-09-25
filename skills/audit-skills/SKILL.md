---
name: audit-skills
description: Use when the user wants their authored agent skills audited across Claude Code, Codex, Kimi Code, Antigravity, or PI for relevance, stale references, weak triggers, runtime incompatibility, cross-home drift, or what a skill body discloses to a third-party model vendor that mounts it.
---

# Audit Skills

## Overview

Sweep the skills the user **authors and can edit**, and produce a candid,
trend-aware findings report across five axes: **reach** (trigger reliability),
**implementation** (structure against the house skill-writing conventions),
**correctness of references** (every path/file/command/package/constant the
skill names actually resolves today, plus adherence to the user's own active
runtime instructions), **utility** (evidence that the skill still earns its
place in the active inventory), and **exposure** (what the skill body discloses
when a third-party runtime mounts it and ships it to a model vendor).

**Report only. Never edit a skill body.** Editing a skill is a separate,
deliberate act governed by the skill-writing Iron Law (a skill edit needs a RED
test first). A blind fix here would violate that.

**The core differentiator — and the thing agents reliably skip — is that the
audit VERIFIES references itself.** Baseline testing showed even strong agents
eyeball the prose and hand verification back ("verify that path exists on your
machine") instead of running the check. That is the failure this skill exists to
prevent.

Use the rubric in `audit-brief.md`. Use the runtime's native parallel-agent
capability when available; it is not a portability requirement. Audit
sequentially when the runtime cannot delegate.

## When to Use

- User asks to audit / sanity-check / quality-check their skills, or suspects
  skill rot (a path moved, a package was renamed, a trigger stopped firing).
- After a batch of skill edits, a tooling/path change, or a convention change in
  `CLAUDE.md`, to catch what drifted.

**When NOT to use:**
- Documenting/inventorying skills → `current-skills`.

## The Iron Law

```
EVERY referenced path, file, command, package, and constant is VERIFIED on disk.
NEVER hand a verification back to the user.
```

Writing "verify X exists" in a finding is the failure, not the finding. If you
named it, you check it — with the runtime's filesystem search, `Test-Path`, a
shell existence check, or an authoritative package lookup — and report it as
RESOLVED or BROKEN with the evidence. No exceptions:
not for "probably fine", not for "it's the user's machine", not for "out of
scope". You have the tools. Use them.

## Procedure

<!-- routing: phase-0-assemble-rubric -->
**Phase 0 — Assemble the rubric (main thread).**
- Discover the owned-skill set across **all six runtime surfaces** — never
  hardcode the list:
  - `~/.claude/skills/*/SKILL.md` (Claude Code home)
  - `~/.agents/skills/*/SKILL.md` (Codex and Kimi shared home)
  - `~/.kimi-code/skills/*/SKILL.md` (Kimi-native overlays)
  - `~/.gemini/config/skills/*/SKILL.md` (Antigravity IDE global home)
  - `~/.gemini/antigravity-cli/skills/*/SKILL.md` (Antigravity CLI global home)
  - `~/.pi/skills/*/SKILL.md` **and** `~/.pi/agent/skills/*/SKILL.md` (PI — two
    roots, both live, and it mounts a hand-picked subset rather than the whole
    canonical set, so enumerate it instead of assuming parity with `~/.agents`)
- Record, per surface, which model vendor the runtime is configured against —
  `~/.pi/agent/settings.json` for PI, the equivalent config for each other
  runtime. Axis 5 needs to know which homes are third-party, and a runtime
  repointed at a new vendor changes the exposure verdict without changing a
  single skill body.
- The five runtime homes span six surfaces, because PI has two roots. The Antigravity CLI root is **not** flat
  Markdown — globbing `*.md` there returns only its CLI-native router skill and
  hides every canonical skill junctioned into it, so the audit reports false
  absences. Most entries in the Claude Code and both Antigravity roots are
  directory junctions onto `~/.agents/skills/<skill>`; a junction is the same
  bytes as its target, so it can never diverge from canonical. Resolve each
  entry's shape before treating a same-named pair as two copies to diff.
- Decide ownership per skill by reading the YAML frontmatter of every discovered
  `SKILL.md`. The `owner: <your-org>` marker is the source of truth for
  your-org-owned skills:
  - **`owner: <your-org>` present** → owned; include in the deep audit.
  - **No `owner: <your-org>`** → not owned; include only in the full inventory
    for overlap awareness.
  - Do not infer ownership from path, voice, or conventions, and never add the
    marker to a third-party skill.
- Cross-check against `~/.claude/skills/current-skills/CurrentSkills.md` when it
  exists, but defer to the frontmatter marker:
  - A skill listed as local but missing `owner: <your-org>` is a metadata gap
    (flag it, do not promote it to owned).
  - A skill listed as plugin/built-in but carrying `owner: <your-org>` is a
    metadata error (flag it, do not demote it).
  - Treat firecrawl as owned only if its frontmatter has `owner: <your-org>`.
- Exclude non-owned skills from:
  - the scorecard
  - drift lists
  - the "missing skills" gap section
  - reliability/polish deep-audit findings
- Capture the **full session skill inventory** — every skill description,
  including non-owned/plugin/third-party skills — for the cross-skill overlap
  pass only.
- Read the applicable instruction files that exist for the current runtime
  (e.g., `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.kimi-code/AGENTS.md`).
  Record which governed each check.
- Verify the shared traps-docs plumbing. The traps documents live in ONE real
  directory inside the shared docs checkout, and every runtime notes directory
  — `~/.agents/notes/` included — is a **directory junction** onto it. Hard links
  were retired on 2026-09-18 because ordinary file writes and `git checkout`
  severed them silently. So the assertion is per DIRECTORY, not per file: check
  `LinkType` is `Junction` and that its target resolves to the canonical notes
  directory. A junction cannot hold a divergent copy, so a per-file link check
  here produces false findings — on 2026-09-19 one reported all 14 docs as
  unlinked copies in all five runtimes while the topology was correct. Report any
  real drift as a reliability finding under `audit-skills` itself.
- Read the previous report (latest `SkillAudit-*.md` in the Report path below)
  for the trend diff.
- Collect available utility evidence for each owned skill and record the source
  and observation window: explicit skill invocations or mentions in local
  session histories, recorded outcomes, prior reports, and git history showing
  continued maintenance or supersession. Session/token totals without
  skill-level attribution are not invocation evidence. Missing evidence is
  `insufficient-evidence`, never an invented zero.

  **Where the session histories are, and what counts as attribution.** Enumerated on this
  box 2026-09-06; a runtime whose path is absent contributes nothing and is recorded as a
  searched source with a negative result, never skipped in silence.

  | Runtime | Path | Shape |
  |---|---|---|
  | Claude Code | `~/.claude/projects/<slugged-cwd>/<session-id>.jsonl` | one JSON object per line; the slug is the working directory with separators replaced by `-` |
  | Codex | `~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-<timestamp>-<uuid>.jsonl` | the same line-delimited JSON, foldered by date |
  | Antigravity | `~/.gemini/history/<project>/` | one directory per project |
  | Kimi | `~/.kimi-code/logs/kimi-code.log` | a single rolling log, NOT per session, so it cannot establish a per-session window — treat it as indirect evidence |

  Attribution means the record NAMES the skill: a `Skill` tool call carrying its name, a
  literal `/<skill-name>` invocation, or the skill's own path. Prose about the subject the
  skill covers is not attribution — plenty of sessions discuss deployment without invoking
  `deploy`, and counting those turns a topic's popularity into a skill's usage. State the
  window as the date range of the files actually read (list the directory; do not assume it
  reaches further back than it does), and say which runtimes were searched, including the
  ones that returned nothing.

  **Count in a single pass, and match the call, not the key.** Scan each history root once
  with `rg` and a single alternation that captures the skill name — 55 separate patterns
  per file did not finish over ~4,000 Claude transcripts in ten minutes. Match the tool-call
  form `"name":"Skill","input":{"skill":"<name>"` (allowing whitespace), or a
  `<command-name>/<name></command-name>` tag. A bare `"skill": "<name>"` key also matches
  audit worker JSON, so the skills audited most often look the most used: on 2026-09-25 it
  inflated `close` from 159 sessions to 215 matches.

  **A skill that never makes a Skill call is not unused.** A skill run by a hook (`observe`),
  or reached through another skill's instructions without a Skill tool call, has no record
  in this count. Check the hook registrations and the invoking skill's outputs before
  grading it; if nothing attributable exists, say which route it runs by and grade
  `insufficient-evidence`, not a measured zero.

<!-- routing: phase-1-per-skill-audit -->
**Phase 1 — Audit one owned skill per isolated worker.**
Use the runtime's native parallel-agent capability when available. Give each worker the
contents of `audit-brief.md` (in this skill's directory), the path(s) to its one
skill (across every surface where it exists), the full description inventory,
that skill's utility evidence, and the per-surface vendor map from Phase 0. Each
subagent reads only its skill, verifies every reference, scores the five axes,
runs its own exposure sweep, detects its own cross-home drift, and returns the
structured JSON the brief specifies. Run the same contract sequentially if
delegation is unavailable.

Resolve the model for this phase before dispatching:

```bash
python ~/.agents/skills/model-registry/route.py \
  --routing ~/.agents/skills/audit-skills/routing.json \
  --phase phase-1-per-skill-audit \
  --facts '{"fanout": <owned skill count>, "priorUnresolvedHigh": <open Critical+High in the previous report, omitted entirely when there is no previous report>}' \
  --manifest <run working dir>/routing-manifest.json
```

If the `model-registry` skill is not installed, skip resolution and dispatch at your
default model, and say so in the report's method section. Otherwise dispatch each worker
at the row's `model`. `"delegation": "native"` means the
host itself accepts a per-worker model. `"delegation": "wrapper"` means invoke
the wrapper named in the row's `wrapper` field with `-Instruction`, `-Model`, and
the resolved `-Effort`; treat its stdout as that worker's output. `"delegation": "none"`
is the fail-closed answer: run the contract sequentially at your own model and
say so in the report's method section. Never substitute a model of your own
choosing for an unresolved one. A row may also carry a non-null `tierFallback`
when the resolved tier had no host model and the run fell back up within the
same vendor; report the tier actually used (`resolvedTier`), not the declared one.

Omit `priorUnresolvedHigh` entirely when there is no previous report. Passing
zero would assert a clean backlog that was never observed.

<!-- routing: phase-2-synthesize -->
**Phase 2 — Synthesize (main thread).**
- Collect the JSON. **Reconcile the returned set against the Phase 0 owned set
  BEFORE anything else**: diff the `skill` names you got back against the names
  you dispatched, and re-dispatch every one that is missing. Do not synthesize
  until that diff is empty. A worker can vanish without failing — the host caps
  concurrent subagents (20 on the host where this was measured), and a dispatch over that cap is refused
  per-call while the rest of the wave succeeds, so the loss is silent and looks
  exactly like a skill that was never owned. Measured 2026-09-19: `model-registry`
  was dropped this way and a 53-row scorecard was about to be published as 54.
  The scorecard's row count is not evidence of coverage; this diff is.
- **Dedupe cross-skill findings** — an overlap surfaces from both sides of the
  pair.
- Run the cross-skill pass the per-skill subagents cannot: trigger **overlaps**
  across the full inventory, coverage **gaps** that an owned skill should fill,
  dead/duplicate trigger phrases in owned skills, and reinvention of a plugin
  skill by an owned skill.
- Reconcile each utility grade into one lifecycle disposition: `keep`, `narrow`,
  `merge`, `archive`, `retire`, or `insufficient-evidence`. Frequency is never a
  verdict by itself: preserve rare high-impact capabilities, account for whether
  the observation window contained a realistic trigger opportunity, and prefer
  demonstrated outcomes over raw invocation counts.
- Keep lifecycle decisions out of the defect findings buckets. A sound but
  superseded skill can merit `retire` without being technically broken.
- Assign severities, compute each skill's per-axis grade and an inventory-level
  verdict, and diff against the previous report (fixed / regressed / still-open
  / new).

<!-- routing: phase-3-write-and-deliver -->
**Phase 3 — Write & deliver.**
- Render the report to the vault path below (create the folder if absent),
  normalized to CRLF.
- In chat, give only: the verdict, the scorecard table, and the top fixes; state
  the report path. The only action offered is pointing the user at the
  appropriate skill-editing workflow to fix a specific skill deliberately — make no edits.

## Model routing

Each phase declares its capability tier in `routing.json` beside this file, and
`model-registry/route.py` resolves that tier for whichever runtime is hosting the
run. The declaration, not this prose, is the contract; in the source repository a
verifier reconciles every `routing.json` phase against the `<!-- routing: -->` markers.

Routing decides who does the work. It never changes how the work is checked: no
routing row may be cited to skip a verification, drop an axis, or soften a
severity.

Every phase declared in `routing.json` is resolved the same way shown above for
`phase-1-per-skill-audit` — substitute that phase's own `--phase` id and the
facts its rules name. The invocation above is one worked example, not the only
routed phase.

## Grades and report

Every worker result uses the closed grade vocabulary: 🟩, 🟨, 🟧, 🟥.
Reach/Implementation/Correctness use the defect scale: 🟥 Broken, 🟧 Reliability,
🟨 Polish, and 🟩 Good. Utility uses the lifecycle scale: 🟩 `keep`, 🟨
`insufficient-evidence`, 🟧 `narrow`/`merge`/`archive`, and 🟥 `retire`. Never read
a Utility glyph as defect severity. Exposure uses the disclosure scale: 🟥
credential material, 🟧 identity and topology, 🟨 attribution, 🟩 generic —
defined in [references/exposure-classes.md](references/exposure-classes.md).

Write the report as CRLF to
`<vault>\Claude\SkillAudits\SkillAudit-YYYY-MM-DD.md`, where `<vault>` is the
single Obsidian vault the active runtime instructions name; a
same-day rerun may overwrite only a prior report written by this skill; otherwise use
the next `-NN` suffix. Directly below the title include generated-by metadata:
`> Generated by audit-skills · <N> owned skills · <S> runtime surfaces`.
Use the title `# Skill Audit — YYYY-MM-DD`.

The report must contain:

- Verdict.
- Scorecard with columns
  `Skill | Reach | Impl | Correctness | Utility | Exposure | Top issue`.
- Findings grouped under Broken, Reliability, and Polish; each names the skill,
  exact evidence, and precise unapplied fix.
- Exposure with columns `Skill | Class | Evidence | Exported by | Fix`, plus one
  line naming which surfaces were treated as third-party this run and on what
  configuration evidence. Omit the table when every owned skill graded 🟩, but
  never omit the scope line — a clean exposure result is only meaningful
  alongside the scope it was clean over.
- Cross-skill findings for overlap, gaps, drift, and reinvention where present.
- Lifecycle recommendations with columns
  `Skill | Disposition | Confidence | Evidence`.
- `Trend since <date>` with fixed, regressed, still-open, and new items when a
  prior report exists; omit the section on a first run.
- Prioritized fixes. Every item names the skill and change and includes
  `impact <h/m/l> · effort <l/m/h>`.

In chat return only the verdict, scorecard, top fixes, and report path. Consult
[references/report-contract.md](references/report-contract.md) only for
illustrative formatting and presentation traps; it does not own execution rules.

## Red Flags — STOP

- You're about to write "verify/confirm/check that … exists" as a *finding*.
- You graded a skill without running a filesystem or package check.
- You never opened the active runtime instruction files this run.
- You conflated Antigravity IDE with Antigravity CLI or ignored Kimi-native overlays.
- You are about to synthesize without diffing the returned worker set against the
  dispatched owned set. A silently capped subagent leaves no error in your context.
- You graded exposure 🟩 without naming the scope it was clean over, or reasoned
  that a workspace sandbox contains it (it does not — skills load from the
  runtime home, not the working directory).
- Two subagents' findings use different severity words.

**All of these mean: you skipped the work. Go verify.**
