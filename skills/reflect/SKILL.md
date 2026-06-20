---
name: reflect
description: Use when the user runs /reflect or asks for an honest assessment of how well they are using Claude Code — their settings, skills, plugins, hooks, model choices, and interaction habits. Triggers — "how am I doing", "am I getting the most out of Claude Code", "review my workflow", "assess my setup", "is my workflow sophisticated", "/reflect".
---

# Reflect

## Overview

`reflect` answers one question honestly: **is this user getting the most out of
Claude Code?** It audits their configuration and real usage, scores six
dimensions against a maturity rubric, cross-checks what they do against the
*current* Claude Code feature set, and delivers a candid assessment with a
prioritized set of next moves.

Each run writes a dated report to the Obsidian vault, so successive runs form a
trend trail — the skill compares against the previous report and calls out what
improved, what slipped, and which recommendations were actioned or ignored.

**The value of this skill is candor.** A flattering report is a useless report.
Score on evidence, name weaknesses plainly, and cite the file or metric behind
every claim. A flat or low verdict, honestly argued, is the most useful result
this skill can produce. Do not soften, do not pad, do not congratulate.

## Constants

The only values to edit if paths change:

- **CLAUDE_DIR** — `~/.claude` — the configuration root.
- **VAULT_DIR** — `<vault>/Reflections` —
  where dated reports are written. Create it if absent.
- **REPORT** — `VAULT_DIR\Reflection-YYYY-MM-DD.md`. If today's report already
  exists, overwrite it.

## Procedure

### 0. Refresh feature knowledge — do this first, never skip it

Your training cutoff predates today. Claude Code ships constantly, so you
**cannot** assess feature adoption from memory — you will miss everything
released since your cutoff and wrongly mark the user as behind.

- Get the installed version: `claude --version`, or read the `version` field of
  a recent transcript line under `CLAUDE_DIR\projects\`.
- Fetch the changelog: `WebFetch` `https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`.
  If that is blocked, try `https://docs.claude.com/en/release-notes/claude-code`,
  then fall back to `WebSearch` for "Claude Code changelog" over the last ~6
  months.
- From it, build two short lists: (a) capabilities released *after* your cutoff,
  and (b) anything gated behind a newer version than the user has installed.
- If every network path fails, say so in the report and scope feature-adoption
  scoring to what you can verify locally — do not guess.

### 1. Inventory the configuration

- **`settings.json`** (and `settings.local.json` if present) — permission allow
  list breadth, hooks per event, `enabledPlugins`, `autoMode`,
  `autoCompactEnabled`, `skipAutoPermissionPrompt`, notification channel.
- **`CLAUDE.md`** — the global one at `CLAUDE_DIR\CLAUDE.md`; if reflect is run
  inside a repo, its repo-local `CLAUDE.md` too. Judge depth and specificity.
- **Skills** — all four sources (built-in from this session's available-skills
  reminder; `~/.claude/skills/*/SKILL.md`; npx `~/.agents/skills/`; plugin
  skills under `~/.claude/plugins/cache/`). If a fresh `CurrentSkills.md` exists,
  read it instead of re-walking.
- **Plugins** — `~/.claude/plugins/installed_plugins.json` and marketplaces.
- **Hooks** — list `~/.claude/hooks/`.
- **`keybindings.json`** — present (customized) or absent (defaults).
- **MCP servers** — `.mcp.json` / settings; note MCP tools offered this session.

### 2. Gather metrics

- **`stats-cache.json`** — `dailyActivity`, `dailyModelTokens`, `modelUsage`,
  `totalSessions`, `longestSession`, `hourCounts`. Compute, don't dump: cache
  efficiency (cacheRead vs cacheCreation ratio per main model — higher is
  better), tool calls per session, recent activity trend. **Do not** read the
  model-token mix here as a model-discipline signal — it is dominated by the
  main thread and hides what subagents run on. Measure subagent models from
  transcripts (step 3) instead.
- **`history.jsonl`** — prompt count, slash-command and skill-invocation
  frequency, rough prompt-length distribution.

### 3. Sample transcripts and measure real behaviour

The aggregate stats cannot see *how* the user collaborates, or what their
subagents do — transcripts can. Measure; do not infer from counters.

- Pick the 5–8 most-recently-modified transcripts across different
  `CLAUDE_DIR\projects\*` directories. Skip the current live session (partial).
- **Subagent model usage** — this is the *only* reliable model-discipline
  signal. `Grep` the subagent transcripts (`**/subagents/agent-*.jsonl`) for
  `"model":"claude-..."` and tally which model each subagent file runs on. A
  user can be ~95% Opus in aggregate tokens yet route most subagents to
  Sonnet/Haiku — only this measurement reveals it.
- **Harness artifacts** — check for `docs/superpowers/plans/*.md` files and
  superpowers skill invocations in `history.jsonl`. These, not the
  `permissionMode:"plan"` marker, are how a superpowers user plans. A planning
  habit driven by skills is invisible to the built-in plan-mode signal.
- `Grep` the JSONL set for correction/redirect phrases ("that's wrong", "that's
  not what", "I didn't ask", "revert that", "undo", "you misunderstood",
  "actually, ", "no, I", "stop,") for an approximate redirection rate. This is
  rough — assistant text contaminates it — so treat it as a cross-check only.
- `Read` 3–5 of the sampled transcripts in part for the real judgement: prompt
  specificity (context, constraints, acceptance criteria), whether a deliberate
  planning step precedes ambiguous or large work, parallel tool calls, whether
  the user verifies outputs, and context the user re-explains repeatedly that
  belongs in `CLAUDE.md` or memory.
- Stay bounded — sample, never read every transcript. Cap total reading.

### 4. Score against the rubric

Score each of the six dimensions (below) at one level, with 2–3 evidence-backed
sentences. Then give an overall verdict. Anchor every score to the rubric's
"Advanced looks like" line — do not grade on a curve or on effort.

**Score harness-aware.** Before marking any dimension a gap, ask whether a
plugin or skill harness the user relies on already covers it through a
non-default mechanism. The absence of a *built-in* feature is not a gap if a
skill does the same job — e.g. superpowers `brainstorming`/`writing-plans`
replace built-in plan mode, and superpowers `subagent-driven-development`
already routes subagent models by task. Penalising the absence of the built-in
when the harness covers it produces a wrong, unfair verdict.

### 5. Detect feature gaps

Cross-reference step 0's feature list against actual usage from steps 1–3. List
the capabilities the user does not appear to use that genuinely fit their
workflow. Be specific about why each fits — generic suggestions are noise.

**An absent setting is not a gap.** Before flagging any `settings.json` key as
unadopted, check its *default*. Most keys are unset because their default is
already correct — calling those a gap is the "absent = missing" error. Only
flag a setting when a *specific non-default value* would genuinely help this
user; name the value and the reason. When unsure of a key's default or value
domain, consult the settings schema (the `update-config` skill carries it)
rather than guessing — and never assume a key is a boolean.

### 6. Ensure the reflections directory exists, then compare to the previous reflection

Run `New-Item -ItemType Directory -Path "<vault>/Claude/Reflections" -Force | Out-Null`
to create `VAULT_DIR` if it is absent (idempotent — safe to run even when it already exists).

Then `Glob` `VAULT_DIR\Reflection-*.md`. If a prior report exists, read its scorecard
and recommendations. Note the deltas: dimensions that rose or fell, and which of
last time's "next moves" were actioned versus ignored. If no prior report
exists, skip this — it is the first reflection.

### 7. Write the report

Render the template below to `REPORT`. `VAULT_DIR` was already created in step 6.
Normalize to CRLF line endings. Omit the "Trend" section entirely on a first run.

### 8. Deliver and offer to act

In chat, give only: the overall verdict, the scorecard table, and the top 3 next
moves. Keep it tight — the full detail is in the report; state the report path.

Then offer to action the top recommendations — settings tweaks, new permission
rules, scaffolding a skill, enabling a plugin. **Make no changes until the user
green-lights them.** Apply config changes at global scope unless the change is
inherently repo-specific.

## The rubric

Levels: 🟥 **Ad hoc** · 🟧 **Developing** · 🟩 **Proficient** · 🟦 **Advanced**.

1. **Context engineering** — `CLAUDE.md` (global + per-repo) and memory accuracy
   and depth, `/clear` vs `/compact` discipline, offloading search to subagents
   to keep the main context lean, a deliberate `autoCompact` stance, session
   hygiene.
   *Advanced looks like:* lean, accurate context curated per task; subagents
   absorb fan-out; the user rarely re-explains things that should be persisted.
   *Warning signs:* giant unfocused sessions, repeated re-explanation, stale or
   thin `CLAUDE.md`.

2. **Prompt & collaboration** — prompt specificity, a deliberate planning step
   for ambiguous or large work (built-in plan mode *or* a planning skill such as
   superpowers `brainstorming`/`writing-plans`), low correction/redirect rate,
   verifying outputs before moving on.
   *Advanced looks like:* prompts carry context, constraints and acceptance
   criteria; ambiguous work is planned before it is started; corrections are
   rare.
   *Warning signs:* terse prompts that need several rounds of redirection,
   diving into big changes with no plan of any kind.

3. **Friction reduction** — permission allow-list coverage, hooks doing real
   work, `autoMode` / `skipAutoPermissionPrompt`, how prompt-free routine work
   is.
   *Advanced looks like:* routine commands run without prompts; hooks automate
   guards and approvals; the allow list reflects real usage.
   *Warning signs:* constant permission prompts for safe, repeated commands.

4. **Skills & extensibility** — repetitive workflows captured as skills,
   custom-skill description quality (trigger reliability), plugin and
   marketplace use, MCP servers.
   *Advanced looks like:* recurring workflows are skills with crisp triggers;
   plugins and MCP extend reach where it pays off.
   *Warning signs:* the same multi-step task re-typed each time; skills with
   vague descriptions that never self-trigger.

5. **Model & cost discipline** — model choice matched to task (Opus / Sonnet /
   Haiku), cache efficiency, delegating cheap or parallel work to
   subagents.
   *Advanced looks like:* heavy reasoning on Opus, routine work on Sonnet/Haiku,
   high cache-read ratios, subagents for parallel grunt work.
   *Warning signs:* Opus for everything, poor cache reuse from context thrash.

6. **Feature adoption** — use of current Claude Code capabilities (plan mode,
   background tasks, `/loop`, `schedule`, worktrees, task tracking, parallel
   tool calls) and the newest changelog items from step 0.
   *Advanced looks like:* new capabilities are adopted deliberately where they
   fit, not chased for novelty.
   *Warning signs:* a workflow frozen at an old mental model of the tool.

## Report template

```markdown
# Claude Code Reflection — YYYY-MM-DD

> Generated by `/reflect` · Claude Code v<version> · <N> sessions, <M> messages analysed

## Verdict

**Overall: <level>** — <2–4 honest sentences. Lead with the single most
important thing the user should change.>

## Scorecard

| Dimension | Level | One-line |
|---|---|---|
| Context engineering | <🟥/🟧/🟩/🟦 name> | ... |
| Prompt & collaboration | ... | ... |
| Friction reduction | ... | ... |
| Skills & extensibility | ... | ... |
| Model & cost discipline | ... | ... |
| Feature adoption | ... | ... |

## What's working

- <Genuine strengths, evidence-backed. Brief — this is not the point of the report.>

## Where you're leaving value on the table

### <Dimension>
- **Evidence:** <the file, metric, or transcript pattern observed>
- **Gap:** <what an Advanced user would do instead>
- **Move:** <the concrete change>

## Unused features worth adopting

- **<feature>** — <what it is, why it fits this user's workflow>. (Released <when>.)

## Trend since last reflection (<date>)

- <Dimensions that rose or fell; recommendations actioned vs ignored. Omit this
  whole section on a first run.>

## Prioritized next moves

1. **<action>** — impact: <high/med/low> · effort: <low/med/high> — <why it matters>
   (max 5, ranked by impact-to-effort)

## Metrics snapshot

- Sessions / messages / tool calls analysed: ...
- Model mix (share of output tokens): ...
- Cache efficiency: ...
- Approx redirection rate: ...
- Working pattern: ...
```

## Common mistakes

- **Scoring feature adoption from memory.** Your knowledge is stale by months —
  step 0 is mandatory; never skip the changelog fetch.
- **Flattery.** The report's only value is candor. An uncomfortable verdict,
  honestly argued and evidenced, beats a kind vague one. Do not pad strengths.
- **Reading every transcript.** Sample 5–8, read 3–5 in part, cap the reading.
- **Dumping raw stats.** Interpret. The snapshot is a handful of computed
  numbers, never a pasted JSON blob.
- **Changing settings unprompted.** Step 8 *offers*; the user green-lights.
- **Writing into a repo.** The report lives in the vault, never in a working
  repository.
- **Vague recommendations.** Every next move names a specific, checkable change.
- **Inferring subagent models from aggregate stats.** `stats-cache.json`'s token
  mix is main-thread-weighted. Subagent model routing is only visible by
  tallying `**/subagents/agent-*.jsonl` — measure it there (step 3).
- **Penalising a missing built-in when the harness covers it.** A superpowers
  user plans via skills, not `permissionMode:"plan"`, and routes subagent models
  via `subagent-driven-development`, not by hand. Check the harness before
  scoring a gap (step 4).
- **Flagging an absent setting as a gap.** A `settings.json` key left unset is
  usually at a sensible default, not "unadopted" — `worktree.bgIsolation`
  defaults to isolated, `worktree.baseRef` to a clean tree. Check the default
  before recommending it; only flag a specific non-default value (step 5).
