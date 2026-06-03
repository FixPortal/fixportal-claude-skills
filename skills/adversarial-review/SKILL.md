---
name: adversarial-review
description: Use when the user requests an adversarial review, cross-vendor / multi-model code review, or runs /adversarial-review — now or deferred ("once you are done", "after this"). MANDATORY trigger phrases — "/adversarial-review", "adversarial review", "cross-vendor review", "cross-vendor code review", "multi-model review". If the user uses any of these by name — now or for later ("once you are done", "after this", etc.) — you MUST invoke this skill via the Skill tool. Do NOT hand-roll an equivalent with general-purpose Agent subagents — that uses Claude-only reviewers and defeats the entire point of the panel (uncorrelated error across vendors). The point is the non-Claude reviewer; without it, this is just same-vendor self-review. Use for a code review of a branch, diff, pull request, or module/whole-repo audit. Runs a blind independent review by Claude Opus, Claude Sonnet, and a non-Claude model (GPT-5.4 via the GitHub Copilot CLI), then a cross-examination round, then an adjudication pass, then a verification pass over the High and contested findings against the live code. Works in a git repository.
---

# Adversarial Review

## Overview

`adversarial-review` runs a code review as a three-model panel whose value
comes from *uncorrelated* error: two Claude tiers and one non-Claude model
(GPT-5.4, reached through the user's GitHub Copilot subscription) review the
same change, then attack each other's findings, then a judge reconciles.

The pipeline has four phases, and the invariants matter more than the tools:

1. **Blind** — each reviewer sees the diff and nothing else, never another
   reviewer's output. Independence is what keeps their mistakes uncorrelated.
2. **Cross-examine** — each reviewer sees the *pooled, unattributed* findings
   and is told to attack them: false positives, overstatements, gaps.
3. **Adjudicate** — a separate judge reconciles into one ranked report and
   surfaces disagreement instead of averaging it away.
4. **Verify** — every High and every contested finding is checked against the
   live code before the report is published. A blind panel over-rates severity
   — it labels things High that turn out unreachable — so a finding that
   survives a deliberate attempt to refute it is worth far more than one that
   merely sounded plausible. This phase is where roughly half of over-rated
   Highs are caught.

The panel is host-portable: its composition lives in `reviewers.json` and its
phases run through uniform reviewer wrappers driven by `run-review.ps1`, so the
same review runs under Claude Code, Antigravity (`agy`), or any shell-capable
agent. See **Cross-host operation** below.

Invoking this skill is the user's explicit approval to spawn the Opus reviewer and
Opus judge that `reviewers.json` configures — it satisfies the global "Opus needs
explicit approval" rule for this run, so don't pause to re-confirm each Opus spawn.

## Usage

```
/adversarial-review [<target>] [-- <pathspec>…]
```

`<target>` selects what revision to review; an optional git pathspec after `--`
scopes which files. Both halves are optional.

- `/adversarial-review` — the current branch against its base (committed +
  uncommitted work both included).
- `/adversarial-review 482` — pull request #482.
- `/adversarial-review main..HEAD` — an explicit ref or range.
- `/adversarial-review audit -- src/Engine` — the *current state* of one
  module, reviewed as if newly written (diff against the empty tree).
- `/adversarial-review audit -- src/Data ':!**/Migrations/**'` — same, with
  generated files excluded. A whole-repo audit runs as several such
  module-scoped invocations, never one.
- `/adversarial-review HEAD~5..HEAD -- ':!docs/**'` — a range review with prose
  excluded.

The pathspec (everything after `--`) is passed straight to `git diff`, so it
takes standard git syntax, including `:(exclude)` / `:!` patterns. Section 0
resolves all of this in full.

## Prerequisites

- A git repository — the change under review lives here.
- GitHub Copilot CLI installed and authenticated (`copilot` on PATH). The
  cross-vendor reviewer rides the user's Copilot subscription.
- `external-review.ps1` (beside this file) wraps the Copilot call. If it exits
  non-zero — Copilot not authenticated, premium-request quota exhausted, model
  unavailable — report the cross-vendor reviewer as unavailable and continue
  with the two Claude reviewers. A two-model panel is degraded, not broken; do
  not abort the run.
- Sibling wrappers `claude-review.ps1` (Claude tiers via `claude -p`) and
  `gemini-review.ps1` (Gemini) share the same contract and exist for cross-host
  runs and for swapping the panel via `reviewers.json` (see **Cross-host
  operation**). The native Claude Code path does not need them — it spawns the
  Claude reviewers with the `Agent` tool — but a Google reviewer or a
  non-Claude-Code host does.

## Cross-host operation (manifest + driver)

This skill runs natively under Claude Code using the `Agent` tool (the procedure
below). It is **also** runnable from any shell-capable host — Antigravity
(`agy`), the Gemini CLI, a bare terminal — through three portability pieces that
live beside this file:

- **`reviewers.json`** — the panel as *data*. Each reviewer is `{ id, label,
  wrapper, model, vendor, effort, repoAccess, enabled }`. Swap or add reviewers
  here, never in code. The **vendor-diversity invariant** is enforced from this
  file: the enabled set must span at least `minVendors` (default 2) distinct
  vendors, or a run aborts — a same-vendor panel is self-review, not adversarial.
- **Uniform reviewer wrappers** — `claude-review.ps1` (Claude tiers via
  `claude -p`), `external-review.ps1` (GPT via Copilot), `gemini-review.ps1`
  (Gemini). All share one contract: `-Instruction -DiffPath [-FindingsPath]
  [-ContextPath…] -Model [-Effort] [-RepoPath]`, returning the review on stdout
  and a non-zero exit on failure. Each runs read-only and hermetic.
- **`run-review.ps1`** — the deterministic spine: resolves the diff (§0), fans
  out Phase 1, pools + anonymises + assigns F-ids (§2), fans out Phase 2, and
  writes a self-contained `judge-packet.md` plus `status.json`. It **stops at
  the judgment boundary** — adjudication, verification, and synthesis are not in
  the script, because they require reading the repo to settle contested
  mechanisms, which is the host agent's job.

**Per-harness adapter:**

- **Under Claude Code** — follow the native procedure (§0–§6): the `Agent` tool
  spawns reviewers O/S, the judge, and the verifiers in-process. This is the
  default and the richest path (the judge and verifiers explore the repo
  interactively). The driver is optional here.
- **Under any other host** — there is no `Agent` tool, so run the driver:
  `pwsh -NoProfile -File run-review.ps1 -Target <…> [-Pathspec …] [-ContextPath …]`.
  Then the host agent itself does the judgment, reading the briefs as data:
  adjudicate from `judge-packet.md` with `briefs/phase3-adjudicate.txt` →
  verify each High/contested finding with `briefs/phase4-verify.txt` →
  synthesise multi-chunk runs with `briefs/synthesis.txt` → persist (§6). The
  invariants (blind independence, anonymised pooling, surfaced disagreement,
  verify-before-publish) are identical; only the spawning mechanism differs.

**Antigravity (`agy`) needs a real terminal.** Its headless print mode
(`agy -p '…' --dangerously-skip-permissions`) returns correctly when run
interactively in a terminal — verified executing a `pwsh -File <script>` and
handing back its output — but hangs silently, emitting nothing and ignoring
`--print-timeout`, when stdout is redirected to a file or the call is
backgrounded (no TTY). Run it in a terminal, not through a captured/background
pipe. Keep the prompt single-quoted with no inner double quotes (have `agy` run
a script file rather than an inline `-Command`) so the host shell does not
mangle the quoting.

**Reasoning effort is not uniform across vendors.** `--effort`
(low|medium|high|xhigh|max) is real on `claude -p` and the wrappers honour the
manifest's `effort` for Claude reviewers. The Copilot and Gemini CLIs expose no
clean reasoning-effort flag, so `effort` is a no-op for them — the driver
introspects each wrapper and silently omits a flag it does not declare. Do not
plan to "dial the scanners down to save cost": for a panel whose whole value is
catching what a shallow pass misses, default the reviewers to depth.

## Procedure

### 0. Resolve the diff

Confirm a git repo with `git rev-parse --is-inside-work-tree`. If it is not,
tell the user adversarial-review needs a git repository and stop.

The skill argument has the form `[<target>] [-- <pathspec>…]`: the part before
`--` selects *what revision* to review, and an optional pathspec after `--`
scopes *which files*. Resolve the revision part as:

- **A pull request number** (`/adversarial-review 482`) — `gh pr diff 482`.
- **A ref or range** (`main..HEAD`, a branch name, a SHA) — `git diff -U15 <arg>`.
- **`audit`** (or a bare empty-tree SHA) — review the *current state* of the
  code, not a change: diff against git's empty tree,
  `git diff -U15 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD`. Every line
  counts as an addition, so the panel reviews the code as it stands today.
  Always pair this with a pathspec — auditing a whole repo in one run dilutes
  every finding and overruns the Copilot reviewer; scope each run to one module.
- **No argument** — review the current branch against its base. Detect the
  default branch (`git symbolic-ref --short refs/remotes/origin/HEAD`, falling
  back to whichever of `main` / `master` exists), take
  `git merge-base <default> HEAD`, and run `git diff -U15 <merge-base>` so that
  committed and uncommitted work on the branch are both included.

The generous `-U15` context matters: the Copilot reviewer sees only the diff
file.

**Pathspec.** Anything after `--` is forwarded verbatim to `git diff` as a
pathspec — it supports both inclusion (`src/Engine`) and exclusion
(`':!**/*.Designer.cs'`). Use it to keep the panel on hand-written code;
generated files and prose are not substantive defects and waste the run. A
sound exclusion set for an audit is `':!docs/**' ':!**/Migrations/**'
':!**/*.Designer.cs' ':!**/*ModelSnapshot.cs'` — adjust per repo. A pathspec is
optional for a PR or branch review; reach for it when the diff is dominated by
generated or vendored files.

Create a per-run working directory `<temp>/adversarial-review/<UTC-timestamp>/`
and write the diff there as `review-diff.txt`. If the diff is empty, say so and
stop.

Also capture, for orientation only (not as material to review): the changed
file list (`git diff --name-only …`). For a PR or branch review also capture
commit subjects (`git log --format='%h %s' <base>..HEAD`); skip this for an
`audit`, where `<base>..HEAD` would be the project's entire history.

### 0a. Size the diff and plan the chunking

A reviewer reasons well over a diff it can hold whole; past roughly **2,000
added lines** the panel degrades — findings dilute, and the Copilot/GPT-5.4
reviewer (which sees only the diff file, no repo access) starts to lose the
far end. So before running, count added lines
(`git diff … | grep -c '^+'`). If the diff is under the budget, run it as a
single review — skip the rest of this section.

If it is over budget — which a whole-repo `audit` almost always is — **do not
run it as one review.** Split it into chunks and run the full three-phase
pipeline once per chunk, then synthesise (§5). Plan the split like this:

- **Group by functional cohesion, not by raw file count.** Files that share
  invariants belong in the same chunk so one reviewer sees the whole story —
  e.g. a type system's parsing, coercion, and wire-format files together, not
  scattered across chunks by folder depth. Cohesion is what lets a reviewer
  catch a cross-file contract break.
- **Cap each chunk at the ~2,000-line budget.** A cohesive area larger than
  that splits again along the next natural seam.
- **One pathspec per chunk**, carrying the audit exclusions (generated files,
  prose). Chunks should tile the codebase without overlap — a file reviewed in
  two chunks wastes a run and produces duplicate findings.

**Present the chunk plan to the user before running** — a short table of
chunk → pathspec → approx. lines — and get approval. Boundary-picking is cheap
and the human is better-informed about what is cohesive than a line count is;
do not auto-run a multi-chunk audit without showing the plan. Flag the cost:
each chunk is a full run (see Cost).

### 1. Phase 1 — blind independent review

Run three reviewers **in parallel, in a single message**. Each is given the
Phase 1 brief and the diff; none is given anything from the others.

**Audit mode:** when the target is an `audit`, the diff is the empty tree vs
HEAD, so *every* line reads as freshly added even though most of it is existing
(often inherited / upstream) code. Prepend the **audit-mode preamble** (below,
with the briefs) to the Phase 1 brief so reviewers calibrate severity to real
defects rather than flagging long-standing intentional design as a fresh
regression. Omit it for PR, branch, and range reviews — there the additions
really are new.

- **Reviewer O** — `Agent` tool, `subagent_type: general-purpose`,
  `model: opus`. Prompt: the Phase 1 brief, plus an instruction to read the
  diff at `<workdir>/review-diff.txt`. The subagent may also read the
  repository for surrounding context.
- **Reviewer S** — identical, `model: sonnet`.
- **Reviewer X** — the Copilot wrapper. Write the Phase 1 brief to a file in
  the working directory first; the wrapper reads it with `Get-Content -Raw`.
  Invoke via `pwsh -NoProfile -File` so it stays inside the `pwsh` allowlist:
  `pwsh -NoProfile -File ~/.claude\skills\adversarial-review\external-review.ps1 -Instruction (Get-Content "<workdir>\phase1-brief.txt" -Raw) -DiffPath "<workdir>\review-diff.txt" -ContextPath <key-file> [-ContextPath <key-file> …]`
  The script pins `gpt-5.4`.

  **Reviewer X never sees the repository** — unlike O and S, it works from the
  files you hand it. That blindness is the cross-vendor reviewer's main
  weakness: it withholds ("needs evidence") on any finding whose mechanism — a
  base class's `= null!` field, an interface contract, a caller's guard — lives
  outside the diff, and those abstentions then masquerade as genuine doubt at
  adjudication. Narrow it: before the run, pick the few repo files the chunk's
  diff *depends on but does not contain* — the interfaces/contracts it
  implements, the base types it extends, the one or two hot callers — and pass
  each via `-ContextPath`. The wrapper labels them read-only background, not
  material under review. Keep it tight (≈3–5 files); the point is to close the
  specific blind spots, not to hand over the repo. If the diff is self-contained
  (no external contract in play), omit `-ContextPath`.

**End every `Agent` prompt (O and S, both phases) with a verbatim-capture
line:** `Your entire final message is captured verbatim as this reviewer's
output — return only the findings (Phase 1) / verdicts and gaps (Phase 2), no
narration or thinking-aloud preamble.` The brief already says "no narration",
but a subagent treats its final message as a human-facing summary unless told
otherwise, and will prepend "Let me verify…" reasoning that pollutes the saved
artefact. The Copilot wrapper does not need this — it returns only the model's
answer.

**Then strip any surviving preamble mechanically — do not rely on the
instruction alone.** Even with the verbatim-capture line, the Claude reviewers
frequently open with a sentence or two of "I have enough context…" narration
before the first finding. When you capture each reviewer's output, discard
everything before the first finding block — the first line beginning `### ` in
Phase 1, the first line matching `F#:` in Phase 2 — and keep from there. The
narration is never part of a finding, so this is lossless. Apply it to O and S;
the Copilot output rarely needs it but check the same way.

Collect the three finding sets verbatim (post-strip). Do not merge or edit them
yet.

### 2. Phase 2 — cross-examination

Pool every Phase 1 finding into `<workdir>/pooled-findings.txt`. **Strip
attribution** — no reviewer names, no per-reviewer grouping — and give each
finding a stable id (`F1`, `F2`, …). Anonymity is load-bearing: a reviewer must
judge a finding on its merits, not defer to whoever raised it.

Run the same three reviewers again, in parallel, each given the Phase 2 brief,
the diff, and the pooled findings:

- Reviewers O and S — fresh `Agent` calls (`opus`, `sonnet`); have them read
  both `review-diff.txt` and `pooled-findings.txt`.
- Reviewer X — `external-review.ps1` with the Phase 2 brief and **both**
  files, the pooled findings passed as `-FindingsPath`. Pass the **same**
  `-ContextPath` files you gave it in Phase 1, so it can still check the
  mechanisms the diff does not show when it attacks the pooled findings:
  `pwsh -NoProfile -File ~/.claude\skills\adversarial-review\external-review.ps1 -Instruction (Get-Content "<workdir>\phase2-brief.txt" -Raw) -DiffPath "<workdir>\review-diff.txt" -FindingsPath "<workdir>\pooled-findings.txt" -ContextPath <same key files as Phase 1>`

### 3. Phase 3 — adjudication

One judge: a single `Agent` call, `subagent_type: general-purpose`,
`model: opus`, **not** reused from Phase 1 or 2. Give it the diff, all Phase 1
findings, and all Phase 2 cross-examinations, plus the Phase 3 brief, and tell
it the repository path so it can open files. Unlike the reviewers, the judge is
expected to read the repo when — and only when — it needs to settle a contested
*mechanism* the diff alone can't (see the Phase 3 brief); the diff remains the
material under review. When you hand it a set of pooled materials, flag which
findings the reviewers split on so the judge knows where to look. It produces
the final report.

Write the judge's report to the working directory as `report.md` (for a
multi-chunk audit, `report-<chunk>.md`). The chat is ephemeral; an audit run as
the final piece of a piece of work wants a durable artefact, and §5 reads these
files back.

### 3a. Phase 4 — verify the High and contested findings

Run this on the report that will actually be **published**: the §3 report for a
single-chunk review, or the §5 consolidated report for a multi-chunk audit (so
you verify the deduplicated set once, not the same defect in every chunk). It
runs *after* §5 synthesis and *before* §4 answer / §6 persist.

Why this phase exists: a blind panel systematically over-rates severity, so a
non-trivial share of Highs do not survive contact with the live code. Leaving
that to manual follow-up means publishing a report that is partly wrong. Verify
before you publish. (Canonical example: the `fixportal-fixatdl` run's contested
High `H6` — a verification pass found the sole call site already guards the null
return, so it was by-design and downgraded to cosmetic. That is exactly the work
this phase formalises.)

Verify **every finding rated Critical or High, and every `[contested]` finding**
(any severity). For each, spawn a fresh `Agent` (`subagent_type:
general-purpose`, `model: sonnet`; use `opus` only for a genuinely subtle
mechanism) that took no part in producing the report. Run them in parallel, like
the reviewers. Give each the repository path, the one finding to test (its
location, claimed mechanism, and claimed trigger), and the verification brief.
The verifier's job is to **refute**: open the code, trace the real call path,
construct the input that triggers the defect — or establish that no such path
exists — and, where cheap, write and run a quick probe or test. It returns one
of `CONFIRMED` / `REFUTED` / `INDETERMINATE` with concrete evidence
(`file:line`, the triggering input, command output).

Fold the verdicts back into the published report — additively, never by silent
deletion:

- **REFUTED** — annotate the finding with a `> **RESOLVED post-audit (<date>,
  verification) — …**` blockquote stating what was refuted and the evidence, and
  re-rate it down (to latent Medium, Low, or not-a-defect as warranted). Keep
  the original finding visible above the note so the reasoning is auditable.
- **CONFIRMED** — stamp it "verified against `<file:line>`" (and the triggering
  input). Keep, or raise, severity.
- **INDETERMINATE** — keep its `[contested]` tag and state exactly what evidence
  is still missing, so the reader knows it is genuinely open, not unchecked.

Skip this phase only if the user explicitly opted out (e.g. "no verification
pass"). Note the added cost when you present the chunk plan (§0a) — see Cost.

### 4. Answer the user

Present the post-verification report directly — a severity-ranked finding list,
each tagged `[unanimous]` / `[majority]` / `[contested]`, contested items showing
both sides, and each High/contested finding now carrying its Phase-4 verdict
(verified-against, or the refuted/downgrade note). Note if the cross-vendor
reviewer was unavailable. Lead with the report; do not narrate the phases you
ran. Mention where the report was saved — both the temporary working directory
and the durable Obsidian vault copy (§6).

For a multi-chunk audit, do **not** answer after each chunk — run every chunk,
synthesise (§5), verify (§3a), then present the one consolidated report.

**Lead the action list with the verified findings.** After Phase 4, the
confirmed Critical/High findings are the things to act on first — say so, with
their verified evidence. List any finding that came back `INDETERMINATE`
separately as genuinely open, naming the evidence still missing. A finding that
verification refuted is not an action item — it stays in the report under its
resolution note for auditability, but do not present it as work to do. Never
silently treat a contested finding as resolved: its disposition is whatever
Phase 4 evidenced.

### 5. Synthesize across chunks (multi-chunk audits only)

Skip this for a single-chunk review. When an audit ran as several chunks, each
produced its own `report-<chunk>.md`. A defect in shared code surfaces in more
than one chunk, worded differently, and severities drift between independently
judged runs. So reconcile them into one repo-level report.

One fresh `Agent` call, `subagent_type: general-purpose`, `model: opus`, that
took no part in any chunk. Give it every `report-<chunk>.md` and the synthesis
brief (below). Write its output to `report.md`. This consolidated report is then
the input to the Phase 4 verification pass (§3a); verify it before presenting —
a single ranked report for the whole audited surface, noting which chunk(s) each
finding came from. This is the artefact the run exists to produce.

### 6. Persist the findings to the Obsidian vault

The per-run working directory is temporary and gets cleaned up; the findings are
a durable artefact, so copy them into the user's Obsidian vault as the final step
of **every** run — single-chunk and multi-chunk alike. Do this before you finish,
or the review is lost on the next temp sweep.

- **Vault root:** `<vault>`.
- **Destination:** `<vault>\Claude\Adversarial Review\<repo>\<run-folder>\`.
- **`<repo>`** is the repository name — the basename of the repo root
  (`git rev-parse --show-toplevel`), e.g. `fixportal-fixatdl`. All of a repo's
  audits group under this one folder.
- **`<run-folder>`** is the working directory's own name (its UTC timestamp, or
  the audit's name), nested under `<repo>` so successive runs of the same repo
  accumulate as dated runs rather than overwriting each other.

Copy into the destination:

- the consolidated `report.md` and every per-chunk `report-<chunk>.md` at the
  run-folder root — these are the findings;
- the raw working files (`review-diff*.txt`, the phase briefs, pooled findings,
  per-reviewer outputs) into a `working/` subfolder — bulky, but worth keeping
  for provenance;
- a short `_index.md` at the run-folder root that makes the run navigable in
  the vault. Follow the **house style** below exactly.

The copy is additive and non-destructive — never delete or overwrite unrelated
vault content. Report the vault path to the user in §4.

#### `_index.md` house style

YAML frontmatter uses **inline arrays** for `reviewers` and `tags` (not
block-list syntax). `project` is the repo name — the same basename used for the
run folder (`git rev-parse --show-toplevel`, e.g. `fixportal-engine`); use it
verbatim in the H1 too. Add the
`remediation-*` / `deferred` keys only when a fix pass actually followed; omit
them otherwise. The body is: an H1 `# <Project> — Adversarial Audit (<date>)`,
a one-paragraph summary of the run, the consolidated-report wikilink, a
per-chunk wikilink list (`[[report-chunkNN]] — <area>`), a tally line, a
one-line Phase-4 verification summary, a one-or-two-sentence "headline highs"
note, the `working/` pointer, and — when remediation followed — a
`## Remediation (post-audit)` section. Template:

```markdown
---
project: fixportal-engine
review-type: adversarial-audit
date: 2026-05-29
reviewers: [Claude Opus, Claude Sonnet, GPT-5.4]
remediation-branch: reviewer-findings-batch1        # only if a fix pass followed
remediation-pr: 25 (rebase-merged to main as <sha>) # only if a fix pass followed
deferred: H-1 / H-2 (themes T-1/T-2) — skip-marked tests  # only if work was deferred
tags: [fix, adversarial-review, code-audit, <repo>]
---

# fixportal-engine — Adversarial Audit (2026-05-29)

Whole-repo cross-vendor audit of `<repo>`, run as N functionally-cohesive
chunks (three reviewers per chunk: Claude Opus, Claude Sonnet, GPT-5.4 via
GitHub Copilot → blind review → cross-examination → adjudication), then
synthesised into one repo-level report.

- **Consolidated report:** [[report]]

## Per-chunk reports
- [[report-chunk01]] — <area>
- … one line per chunk …

## Tally (from the consolidated report)
- High: N · Medium: ~N · Low/Informational: ~N · Refuted/Not-a-defect: N

## Verification (Phase 4)
<one line: how many High/contested findings were checked against the live code,
and the split — e.g. "6 Highs + 2 contested verified; H6 refuted and downgraded
to cosmetic, the rest confirmed.">

<one or two sentences naming the headline-high findings>

The raw per-chunk working materials (diffs, phase briefs, pooled & reviewer
outputs) are under `working/`.

## Remediation (post-audit)
<present only when a fix pass followed — what was fixed + merged, what was
deferred and why, and the next batch branch>
```

## The briefs

**Canonical source:** each brief is stored verbatim as a file under `briefs/`,
which is what `run-review.ps1` and every reviewer wrapper read. The blocks below
mirror those files for in-context reading. **When you change a brief, edit the
file in `briefs/` and keep the mirror below identical** (the two must not drift).

| Phase | File |
|---|---|
| Audit-mode preamble | `briefs/audit-preamble.txt` |
| Phase 1 — blind review | `briefs/phase1-review.txt` |
| Phase 2 — cross-examination | `briefs/phase2-cross-examine.txt` |
| Phase 3 — adjudication | `briefs/phase3-adjudicate.txt` |
| Phase 4 — verification | `briefs/phase4-verify.txt` |
| Synthesis (multi-chunk) | `briefs/synthesis.txt` |

In `audit` mode the Phase 1 brief is the audit preamble followed by the Phase 1
review brief (the driver composes this automatically; the Agent-tool path
prepends it by hand).

Pass each brief verbatim to all three reviewers (as the `Agent` prompt, and as
the `-Instruction` argument to the wrappers).

### Audit-mode preamble (prepend to the Phase 1 brief only in `audit` mode)

```
This is an AUDIT of existing code, not a review of a change. The diff shows
the current state of the code with every line marked as an addition — but most
of it is pre-existing, and some is inherited from an upstream project. Do not
treat code as defective merely because it is old, unfashionable, or not how
you would write it today. Calibrate severity to defects that are genuinely
wrong or hazardous as the code stands now; ignore legacy style and design
choices that are working as intended.

Before raising anything, separate "this is wrong" from "this is not how I would
write it". The following are NOT defects and must not be reported as such:
- code that is unidiomatic, verbose, or dated but behaves correctly;
- tolerance of out-of-spec / malformed input that is a deliberate robustness
  choice (lenient parsing, first-match-wins, null-coercion) rather than a bug;
- defensive fallbacks and guards that fire on inputs the system never produces;
- a design you would have built differently but which honours its own contract.
For every defect you do raise, name the specific input, caller, or call path
that makes it go wrong as the code stands. If you cannot, it is an observation,
not a finding — drop it.
```

### Phase 1 — review brief

```
You are one of three independent reviewers on an adversarial code-review
panel. You are reviewing a change in isolation — you cannot see the other
reviewers or their findings.

Review the diff for substantive defects only:
- correctness and logic errors
- concurrency hazards: races, deadlocks, unsafe shared state
- resource leaks, lifetime and disposal errors
- unhandled errors, missing edge cases, broken invariants
- security issues: injection, authz/authn gaps, unsafe input handling,
  secret exposure
- API and contract misuse, incorrect assumptions about callers or callees

Ignore pure style and formatting unless it changes behaviour.

Severity discipline. A blind panel systematically over-rates severity: it
labels things High that later prove unreachable. Guard against this. To rate a
finding **Critical or High you must name the concrete trigger** — the caller,
call path, or specific input that actually reaches the defect in this codebase.
If you cannot point to a real path that reaches it (it depends on a caller that
may not exist, a subtype nobody defines, a configuration nobody sets, an
exception that may not actually throw), then either cap it at Medium and label
it "latent", or drop it. Severity reflects what demonstrably happens, not what
could go wrong in principle. A smaller set of findings you can each trigger is
worth more than a long list of maybes.

For each defect, output one finding block in exactly this format:

### <short title>
- **Severity:** Critical | High | Medium | Low
- **Location:** <file:line, or the changed region>
- **Trigger:** <the caller, call path, or input that reaches this defect —
  required to justify High or Critical; for a latent/Medium finding, say what
  is missing that keeps it from firing today>
- **Issue:** <what is wrong>
- **Impact:** <what goes wrong if this ships>
- **Suggested fix:** <a concrete direction, one or two sentences>

Cite concrete locations. Prefer a few well-evidenced findings over a long
speculative list. If you find no substantive defect, say so explicitly.
Output only the findings — no preamble, no narration.
```

### Phase 2 — cross-examination brief

```
You are on an adversarial code-review panel. The blind review (Phase 1) is
done. The attached pooled-findings file holds every finding from the three
reviewers combined, with attribution removed, each with an id (F1, F2, …).
One may be your own; you cannot tell, and that is deliberate.

Two tasks.

1. Verdict on every finding. For each F#, output one line:
   F#: AGREE | FALSE POSITIVE | NEEDS EVIDENCE - <one-sentence argument>
   Be adversarial: actively look for reasons a finding is wrong, overstated,
   mislocated, or already handled elsewhere in the diff. Fault it first; a
   finding you genuinely cannot fault, you AGREE with. Severity overstatement
   is a fault worth calling out: if a Critical/High names no path that actually
   reaches it — it needs a caller that may not exist, a subtype nobody defines,
   a config nobody sets, an exception that may not throw — say so and name the
   missing trigger, even if the underlying observation is true.

2. Gaps. List any substantive defect the pooled set missed entirely, as full
   finding blocks in the Phase 1 format (including the Trigger line).

Work only from the diff and the pooled findings. If a finding's mechanism lives
in repository code you cannot see here, say "needs repo" explicitly rather than
guessing — that is a request for the judge to check, not a defect in the
finding.
```

### Phase 3 — adjudication brief

```
You are the adjudicator for an adversarial code review. You took no part in
the review itself. You are given the diff, all Phase 1 findings, and all
Phase 2 cross-examinations.

Produce the final report:

- Deduplicate findings that describe the same defect.
- For each surviving finding give: title, severity, location, issue, impact,
  suggested fix, and a consensus tag:
  [unanimous] - every reviewer treated it as real
  [majority]  - most did; note the dissent in one line
  [contested] - reviewers split; state both sides, do NOT pick a winner
- Rank by severity. A contested Critical or High finding keeps its severity —
  never demote a finding for being contested.
- Distinguish "contested" from "mechanism refuted". Disagreement about whether
  a real defect matters does NOT lower severity. But when cross-examination
  shows the finding's stated *mechanism* is wrong — the claimed exception does
  not actually throw, the dereference cannot happen, the bad code path is
  unreachable — the original severity was based on a false premise: re-rate to
  the severity the corrected mechanism warrants, and state in one line what was
  refuted and by whom. A reviewer's own Phase-2 walk-back of a Phase-1 claim is
  the clearest such case. This is correcting a factual error, not averaging.
- When reviewers split on a finding's *mechanism* (not merely its severity) and
  the diff alone cannot settle it — the disputed call path, type relationship,
  exception behaviour, or reachability lives in code the diff does not fully
  show — READ THE REPOSITORY to resolve it, then state the verdict and how you
  confirmed it ("confirmed against <file:line>"). This is the one place the
  judge should leave the diff: a contested mechanism resolved by reading the
  code is worth far more than one left hanging as "[contested]". Do not invent a
  resolution you cannot evidence; if the code does not settle it, keep it
  contested and say what evidence is missing.
- One reviewer (the cross-vendor model) saw ONLY the diff — never the
  repository. When its verdict is "needs evidence" or it withholds purely
  because a contract, caller, or type it would need lives in code the diff does
  not show, that is a repo-access limitation, not genuine doubt. Do not let a
  diff-bound abstention keep a finding contested or hold its severity down: read
  the repo, settle the mechanism, and rate it on what the code actually does.
  Conversely, do not inflate a finding just because that reviewer flagged it
  without being able to check.
- Enforce the Phase-1 severity discipline at adjudication too: a Critical or
  High must have a real, named trigger (a caller/path/input that reaches it). If
  the evidence shows no such path exists, re-rate it down to "latent" Medium (or
  lower) and say so — this is the same factual-correction principle as a refuted
  mechanism, not averaging.
- End with a "Raised in cross-examination" section for defects that surfaced
  only as Phase 2 gaps.

Do not average away disagreement: a visible contested high-severity finding is
worth more to the user than a smoothed-over consensus. Be concise in prose, but
format the report for a durable Obsidian artefact (it is read later, not just in
chat). Use this house style for every finding:

  ### <ID> · <short title>
  **<Severity>** · [<consensus>]      (append provenance after a " · " if useful)

  **Where** — `file:line`  (put EVERY identifier, type, member, path, and
  file:line in backtick code spans)

  **What's wrong** — <mechanism>

  **Impact** — <consequence; omit the line if it would only restate What's wrong>

  **Fix** — <concrete direction>

  **Consensus** — <for [majority]/[contested], the dissent or both sides>

Leave a blank line between every block. Keep any severity tally as a markdown
table. Render a long tail of minor (Low) findings as a bulleted list — one line
each, code spans intact — rather than full blocks. Rank highest severity first.
```

### Synthesis brief (multi-chunk audits only — §5)

```
You are consolidating an adversarial audit that was run in chunks. Each
attached report covers one slice of the codebase and was adjudicated
independently. Produce one repo-level report.

- Merge findings that describe the same underlying defect across chunks into a
  single entry, noting every chunk it appeared in. A defect raised in several
  chunks is corroborated, not duplicated — reflect that, do not inflate it into
  several findings.
- Reconcile severities: where the same defect was scored differently in
  different chunks, give it one severity and say why in a clause.
- Preserve each finding's consensus tag ([unanimous]/[majority]/[contested]).
  Do not let synthesis launder a contested finding into a clean one.
- Rank the whole set by severity. Keep the per-chunk "Raised in
  cross-examination" items, merged the same way.
- End with a mandatory "Cross-cutting themes" section — this is the highest-
  value output of a repo-wide audit and must always be present (write "none
  identified" only if you genuinely find no recurring pattern). A theme is one
  mistake repeated across areas: name it, and list every finding/location that
  belongs to it so the reader can fix the pattern once instead of N times.
  Typical themes to look for: the same null-handling, exception-wrapping,
  validation-ordering, culture/timezone, shared-mutable-state, or
  contract-masquerade mistake recurring in several files. The point of chunking
  was to review thoroughly; the point of synthesis is to see what no single
  chunk could — surface those patterns explicitly.

Format the consolidated report in the same readability house style the chunk
reports use, since this is the durable Obsidian artefact the whole run exists to
produce:

  ### <ID> · <short title>
  **<Severity>** · [<consensus>] · *chunk(s) N*

  **Where** — `file:line`  (every identifier/type/member/path/file:line in
  backtick code spans)

  **What's wrong** — <mechanism>     **Impact** — <only if distinct>

  **Fix** — <concrete direction>     **Consensus** — <dissent/both sides>

Blank line between every block. Keep the severity tally as a markdown table.
Render the Low tail as a bulleted list (one line each, code spans intact), not
full blocks. In "Cross-cutting themes", give each theme a bold lead sentence
followed by a bullet listing every finding/location that belongs to it. Rank
highest severity first.

Be concise in prose. Do not re-review the code — work only from the chunk
reports.
```

### Verification brief (Phase 4 — §3a)

```
You are verifying ONE finding from an adversarial code review against the live
repository. You took no part in producing it. Your default stance is skeptical:
try to REFUTE the finding. Blind reviewers over-rate severity, so treat it as
possibly overstated until the code proves otherwise.

You are given the repository path and one finding: its location, the mechanism
it claims, and the trigger (caller/path/input) it claims reaches the defect.

Do this:
- Open the cited code and the surrounding call paths. Follow the real callers,
  contracts, base types, and guards — not only the lines quoted in the finding.
- Establish whether a real path reaches the defect with a triggering input. If
  it does, construct that input, and where it is cheap write and run a quick
  probe or test to demonstrate it. If no such path exists, the finding is
  refuted or overstated — say which.
- Check the claimed mechanism is literally true: does the exception actually
  throw, the dereference actually happen, the contract actually permit the bad
  value, the caller actually exist and pass it?

Return exactly one verdict line, then the evidence:
VERDICT: CONFIRMED | REFUTED | INDETERMINATE
- CONFIRMED — name the file:line that proves it and the triggering input.
- REFUTED — name what is false (no caller, guarded at <file:line>, exception not
  thrown, path unreachable) and the evidence.
- INDETERMINATE — state exactly what you could not determine and what evidence
  would settle it.

Cite file:line throughout. Do not restate the finding back to me; report what
the code shows. Output only the verdict and evidence — no preamble.
```

## Cost

One run (one chunk) is 5 Claude subagent calls plus 2 Copilot calls (Phase 1
and Phase 2). The Copilot calls draw on the user's monthly Copilot
premium-request allowance. A multi-chunk audit multiplies this by the chunk
count and adds one Claude synthesis call — e.g. a 6-chunk audit is ~31 Claude
subagent calls and 12 Copilot *calls*.

Phase 4 verification adds one more Claude subagent call **per High/contested
finding**, run once on the published report (not per chunk) and defaulting to
Sonnet — usually a handful (the 6-chunk fixportal-fixatdl audit had 6 Highs).
So budget roughly "+ one Sonnet call per High/contested finding" on top of the
figures above; verification adds no Copilot calls. State the projected cost when
presenting the chunk plan (§0a), and mention it too if the skill is being run
repeatedly in quick succession.

A Copilot *call* is not one premium request. Each request is billed at the
model's multiplier, so the pinned `gpt-5.4` may consume more than one premium
request per call — count Copilot calls × the model multiplier against the
plan's monthly allowance (Copilot Pro ≈ 300 premium requests/month, Pro+ ≈
1,500; both the allowance and per-model multipliers change over time and are
authoritative at github.com/settings/copilot). Even so, an audit's call count
is small relative to the allowance; the allowance only bites under repeated
whole-repo runs.

## Common mistakes

- **Leaking attribution into Phase 2.** Pooled findings must be anonymous and
  not grouped by reviewer, or reviewers anchor on each other instead of judging
  the finding.
- **Letting a Phase 1 reviewer see another's output.** The blind phase is
  blind — three independent prompts, no shared context, sent together.
- **Reusing a reviewer as the judge.** The judge is a fresh agent; a reviewer
  grading work it contributed to inflates its own findings.
- **Averaging away disagreement.** A contested critical finding stays in the
  report, marked contested. The disagreement is the signal the panel exists to
  produce.
- **Aborting when Copilot fails.** Degrade to the two Claude reviewers and say
  so; never silently collapse to a single model.
- **Auditing a whole repo in one run.** A multi-thousand-line `audit` diff
  dilutes every finding and overruns the Copilot reviewer. Size the diff and
  chunk it (§0a); scope each chunk to one cohesive area with a pathspec.
- **Answering chunk-by-chunk.** A multi-chunk audit produces one consolidated
  report after every chunk has run (§5), not a separate verdict per chunk —
  otherwise shared-code defects appear several times and severities drift.
- **Treating audited legacy code as a fresh regression.** In `audit` mode every
  line reads as an addition. Without the audit-mode preamble, reviewers flag
  long-standing intentional design as if it just landed. Prepend it.
- **Reviewing style.** The panel hunts substantive defects; spending three
  models on formatting noise wastes the run.
- **Publishing without Phase 4.** A blind panel over-rates severity — a real
  share of Highs do not survive contact with the live code. Presenting the
  adjudicated report without verifying every High and contested finding (§3a)
  ships a report that is partly wrong. Verify before you answer, unless the user
  explicitly opted out.
- **Reading Reviewer X's repo-blindness as genuine doubt.** The cross-vendor
  model never sees the repository. A "needs evidence" it raises only because a
  contract, caller, or base type lives outside the diff is an access limit, not
  a real gap — feed it the key files via `-ContextPath` (§1), and at
  adjudication settle such findings on the code rather than leaving them
  contested or holding their severity down.
- **Leaving the findings in temp.** The working directory is transient. A run
  that ends without copying its reports to the Obsidian vault (§6) loses the
  whole review on the next temp cleanup — persist before you finish.
