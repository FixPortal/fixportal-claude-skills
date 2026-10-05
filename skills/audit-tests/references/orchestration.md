# Audit-tests orchestration runbook

## Contents

- [Audit modes](#audit-modes)
- [Phase 0 — recon (main loop)](#phase-0--recon-main-loop)
- [Phase 1 — evidence fan-out](#phase-1--evidence-fan-out)
- [Timing evidence](#timing-evidence)
- [Phase 2 — synthesis (main loop)](#phase-2--synthesis-main-loop)
- [Phase 3 — verify](#phase-3--verify)
- [Phase 4 — report](#phase-4--report)
- [Phase 5 — fix pass (only if opted in)](#phase-5--fix-pass-only-if-opted-in)
- [Failure handling table](#failure-handling-table)
- [Common mistakes](#common-mistakes)


Read this reference for the detailed recon, dispatch, synthesis, verification, reporting, and approved fix-pass mechanics.

## Audit modes

**Full** is the default and rebuilds the repository-wide behaviour model.

**Delta** is selected with `--delta-from <report-or-commit>` or an unambiguous
natural-language request to check changes since a prior audit. It reconciles a
verified prior audit against later production, test, configuration, and contract
changes without re-auditing untouched baseline behaviour.

Resolve a delta baseline as follows:

1. A report path must identify this repository, contain the seven-section behaviour
   map/backlog contract, and record its audited commit. The report set — the primary
   report plus any explicitly linked companion verification file — must show completed
   verification for every Critical/High item (or state that none existed).
2. A commit argument is valid only when **exactly one existing verified** audit report
   for this repository names that commit. The report remains the semantic baseline; a
   bare commit is not enough.
3. The baseline commit must resolve locally and be an ancestor of the audited HEAD.
   Never guess a merge-base after a rebase or history rewrite.

For a natural-language request without a path/ref, use the newest verified report under
the Phase 4 vault root whose audited commit is an ancestor only when it is unique.
Otherwise ask which baseline the user intends; never silently choose among candidates.

An impacted surface is **mechanically complete** only when the Phase 0 manifest accounts
for every changed production symbol and configuration/contract entry, their in-repo
references found by compiler/reference search or repository search, composition
registrations, persisted/wire consumers, and relevant tests. Record why each out-of-diff
path is included. An unresolved external consumer or changed symbol whose callers cannot
be established makes the surface unbounded.

Fall back to **Full** when the baseline is missing, ambiguous, unverified, lacks an
audited commit, or is not an ancestor; when stack/test architecture changed; or when the
affected callers and consumers cannot be bounded confidently. Broad changes to public
contracts, persistence/migrations, authentication/startup, or several cross-cutting
boundary families usually trigger that last condition. Changes spanning three or more of
axes B-G default to Full unless tracing produces a mechanically complete, explicitly
recorded impacted surface. Explain the reason before running Full. If the user refuses,
stop; do not issue a partial result or offer a relabelled substitute.

Age alone does not invalidate a baseline. The resolvable diff and its impacted surface
decide validity.

## Phase 0 — recon (main loop)

1. `git rev-parse --show-toplevel`. Not a repo → stop.
2. Repo name = leaf directory of the toplevel path.
3. Dirty working tree → say so and ask before continuing. Record whether the audit
   targets committed HEAD only or includes the named working-tree changes; a fix
   pass always needs a clean base.
4. Stack detection: `*.sln` / `*.slnx` / `*.csproj` → .NET. `package.json` +
   `vitest.config.*` / `vite.config.*` → frontend. `pyproject.toml` + `uv.lock` →
   Python (uv), the `scaffold-python` layout. .NET plus frontend → hybrid (run both
   conventions). None of these → stop and say so; do not guess.

   **Say WHICH thing is true when you stop.** A repo this skill cannot audit is not a
   repo with no test-quality gap: unlocked Python, Go, a Jest frontend and a plain Node
   service all land here, and every one can hold exactly the defects this audit exists
   to find. Report `no instrument covers this stack (<label>)` — never `n/a`, and never
   a clean row. Step 4 only classifies .NET, Vitest/Vite frontend, Python (uv), hybrid,
   or none, so `<label>` comes from the MANIFEST that was actually found, named plainly:
   `pyproject.toml` without `uv.lock`, or `requirements.txt` → `Python (not uv)`, `go.mod` → `Go`, `package.json` with a
   Jest config → `Jest frontend`, `package.json` with neither Vite nor Jest → `Node`,
   `Cargo.toml` → `Rust`, and anything else → `unknown stack (<the manifest filenames
   seen>)`. Naming the manifests rather than guessing a framework keeps the row
   falsifiable: a reader can check what was on disk. A sweep that renders both the same way claims coverage it does not have,
   and the repos most likely to be unaudited are then the least likely to be noticed.
   The limit is the instrument's conventions (xUnit/NSubstitute/AwesomeAssertions,
   Vitest), not a judgement that other stacks need no auditing.
5. Locate test projects (paths go to Phase 1 workers) and any
   coverage / mutation artefacts (`TestResults/`, `StrykerOutput/`,
   `coverage/`, `*.cobertura.xml`). A middle-anchored `**\<name>\**` `Glob`
   is unreliable full stop, not just over dot-directories — enumerate with a
   literal path or `Get-ChildItem -Recurse -Directory` instead, and never
   treat an empty `**` result as evidence of absence. Note the artefact
   paths separately; only those go to worker H.
6. Note whether `<toplevel>\graphify-out\` exists; if so, workers consult it
   before walking the tree.
7. Resolve audit mode. For delta, validate the baseline above; record baseline
   report, baseline commit, audited HEAD, `git diff --name-status --find-renames
   <baseline>..HEAD`, and any approved working-tree changes. Map the changed surface
   to applicable axes. H always applies; include any A-G axis that may be affected,
   and include an axis when uncertain. For test-only changes, include every axis
   owning a baseline behaviour exercised by the changed tests; H alone is valid
   only for pure suite-hygiene or measurement changes with no mapped behaviour.
8. Resolve the fix-pass question: `--fix` → yes. `--report-only`, or an audit/check/
   review request that does not ask for changes → no. If the user asks for fixes but
   does not choose a mode, ask once using the runtime's normal user-input mechanism.

## Phase 1 — evidence fan-out

Full mode dispatches one independent worker for every axis A-H. Delta mode
dispatches H plus every applicable A-G axis selected in Phase 0. Run independent
workers concurrently up to the runtime limit, then dispatch the next batch.

| Worker | `<AXIS>` |
|---|---|
| A | Externally observable behaviours, business rules, invariants |
| B | Security and trust boundaries |
| C | Persistence and transaction guarantees |
| D | Asynchronous processing, retries, idempotency |
| E | External integrations and failure behaviour |
| F | Public API and serialization contracts |
| G | Startup, configuration, deployment-critical behaviour |
| H | Existing test-suite inventory — frameworks, layout, assertion strength, mocking density, timing defects per the axis brief's timing rules, duplication |

### Timing evidence

Worker H applies `references/axis-brief.md` verbatim. Its timing rules delegate to the canonical `scaffold-tests/references/async-and-timing.md`; do not restate or tighten them here.

Prompt = full text of `references/axis-brief.md` with `<AXIS>` and
`<EVIDENCE_SCOPE>` substituted, then an appended run-context block:

```
--- RUN CONTEXT (appended by orchestrator) ---
Repository root: <toplevel>
Audit mode: <full | delta>
Evidence scope: <entire repository | changed paths plus impacted surface>
Stack: <.NET | frontend | Python (uv) | hybrid — from Phase 0>
Test project paths: <from Phase 0>
Knowledge graph: <toplevel>\graphify-out\ exists — consult it before walking the tree.   [omit this line if absent]
Glob ** is unreliable both for dot-directories AND for middle-anchored patterns like **\<name>\** — enumerate both by literal path or Get-ChildItem -Recurse -Directory; an empty ** result is never evidence of absence.
```

For delta, append baseline report, baseline commit, audited HEAD, changed paths,
baseline findings whose evidence paths/symbols changed, and the reason each caller,
consumer, or test outside the diff is included. Workers may add an out-of-diff path
when tracing proves it is impacted; they must say why. For changed tests, inspect
both baseline and current versions so deleted or weakened assertions remain visible.

**Worker H only**, append two further lines:

1. The coverage/mutation artefact paths from Phase 0. Workers A-G never receive it —
   the axis brief forbids them from opening such reports, and the orchestrator must
   not hand them over anyway. This is the F1/F7 countermeasure and it is load-bearing.
2. `Canonical timing policy: <resolved absolute path to scaffold-tests/references/async-and-timing.md>`
   — resolve it from the loaded `audit-tests` skill directory's sibling `scaffold-tests`
   before dispatch. The brief goes out verbatim with `Repository root: <toplevel>` as its
   only path anchor, and that is the **audited** repo; the canonical policy lives in the
   skills home, which the worker prompt otherwise never names. Without this line worker H
   cannot open the file its timing rules delegate to and silently falls back to the
   abbreviated inline summary, losing detail the delegation exists to preserve (notably
   the transport-timeout `OperationCanceledException` mechanics). If the path cannot be
   resolved, say so in the run context rather than omitting the line.

Worker H runs the narrow affected tests when the environment supports it. A run is
supporting evidence, not proof of adequacy and not a merge verdict. If execution is
unavailable or fails for an environmental reason, record that limitation; do not
invent a pass.

Unparseable JSON → one retry restating the contract. In Full mode, a second failure
drops that axis and is disclosed in the report. In Delta mode, losing any selected
axis makes the impacted surface unbounded: fall back to Full or stop. Never fabricate
an axis's findings.

## Phase 2 — synthesis (main loop)

First, re-key every finding: do not trust the `id` an agent supplied — axes
routinely collide on it (e.g. two agents both emitting `A1`). On receipt,
before merging the applicable result sets, reassign each finding's `id` to
`<axis letter><sequence>` within its own axis. Phase 3 dispatches and
matches verdicts by `id`, so this must happen first.

In Delta mode, namespace every baseline resolution/downgrade dispatch id as
`baseline:<original-id>` (for example, `baseline:C1`). Reserve the `baseline:`
prefix for these reconciliation claims; current-run findings keep the axis-letter
scheme. Verdict matching always uses the namespaced dispatch id, never the bare
baseline id. If a baseline item is reinstated in the backlog or becomes a Section 6
slice, it keeps that same namespaced id for the rest of the report.

In Full mode, join A-G (what must hold) against H (what the suite does). In
Delta mode, join the selected behavioural axes and H against the baseline report's
behaviour map and verified backlog. Draft the report body in memory — nothing is
written to the vault until Phase 4 — into the seven `##` sections of
`references/audit-prompt.md`, in its order, with its wording.
The mode-specific scope rules here govern how that generic seven-section contract is
populated; its repository-wide wording never expands a Delta beyond the impacted
surface.

Every Delta finding receives one reconciliation status:

| Status | Meaning |
|---|---|
| `new` | The delta introduces or exposes a behaviour gap absent from the baseline |
| `reopened` | A baseline-covered or previously resolved behaviour is now partial/missing |
| `changed` | A baseline finding still exists but its risk, evidence, test shape, or construction warning changed |
| `resolved` | Current evidence demonstrates that a baseline finding is now effectively defended |
| `unchanged-not-revalidated` | The baseline item was not implicated by the delta; list its id only and make no new claim |

Delta Section 2 contains only impacted behaviours. Section 3 contains only `new`,
`reopened`, and still-actionable `changed` items. Record `resolved` items and their
current test anchors in a reconciliation appendix. List
`unchanged-not-revalidated` baseline ids/counts without copying their prose. Never
mark an item resolved merely because its production or test file changed: open the
test, inspect its assertions, and name the regression that now makes it fail.

Route every finding by its `findingKind`:

| `findingKind` | Routes to |
|---|---|
| `behaviour` | Sections 2 and 3 (map and backlog) |
| `suite-hygiene` | Section 4 (tests to improve or remove) |
| `measurement` | Section 7 (measurement strategy) — never the backlog, that was F9 |
| `n-a` | An explicit statement that the axis was considered and does not apply |

Assign each `behaviour` finding a tier — Critical confidence gap, High-value
addition, Useful strengthening, or Low-value / consciously omitted — from
`riskIfBroken` and `coverageVerdict`, never coverage percentage: high risk
with missing or partial coverage is Critical; high risk with effective
coverage that still has a material hole noted in `why`, or medium risk with
missing coverage, is High-value; medium risk with partial coverage, or low
risk with missing coverage, is Useful strengthening; everything else is
Low-value or consciously omitted. The tier is the item's `priority` field —
same thing, two names — and remains a judgment synthesis must be able to
defend, not a lookup applied blindly.

`unknown` is never tiered by default. `riskIfBroken: high` with an `unknown`
verdict is resolved right here in synthesis: you already have the Phase 1
file:line anchors, so open the tests yourself and settle the verdict — a
read, not a re-dispatch. Still unsettled → tier on risk alone and record the
uncertainty in `confidence`. Lower-risk `unknown`s may be tiered on risk the
same way. Nothing lands in Low-value merely because an agent could not tell.
The same applies when two axes return CONFIDENT but contradictory verdicts
for the same behaviour: synthesis does not adjudicate by preference — open
the cited test yourself and settle it on the evidence. Still unsettled →
tier on risk and record the disagreement in `confidence`; never silently
resolve it to the more convenient verdict.

Every backlog item carries all eight mandated fields from `audit-prompt.md`:
risk/invariant; exact files and symbols; existing tests and why insufficient;
test level; concrete scenario; mocking verdict and which boundary stays
real; the regression it must detect; priority, cost, confidence. An item
missing any field is not ready to ship — complete it or drop it.

Enforce `audit-prompt.md`'s six exclusions HERE, before tiering: trivial
getters/constructors, framework-guaranteed behaviour, private methods
independent of observable behaviour, exhaustive combinations without risk
justification, implementation details likely to change without behaviour
changing, coverage for its own sake. Drop them outright — never hedge them
into Low-value; that tier is for real candidates judged not worth the
maintenance burden.

An empty backlog after exclusions is a valid, reportable outcome: report the
assessment and the behaviour-to-test map and state plainly that no material gaps
survived. In Delta mode, continue to Phase 3 when a claimed Critical/High
resolution or downgrade still needs verification; otherwise report the empty
delta. Do not manufacture findings to fill Section 3.

Section 6 slice granularity: one slice = one backlog item = one fix-slice
dispatch = one commit. Grouping several items under one themed narrative is
fine; each must still be emitted as a separate dispatchable slice —
`fix-slice.md`'s placeholders are singular for a reason.

## Phase 3 — verify

Dispatch one independent skeptic per Critical and High backlog item, in parallel
up to the runtime limit. In Delta mode, also verify every claimed resolution or
risk downgrade of a baseline Critical/High item.

For backlog gaps, prompt = `references/verify-refute.md` with its placeholders substituted
(`<CLAIMED_GAP>`, `<PRODUCTION_SYMBOLS>`, `<TESTS_CLAIMED_INSUFFICIENT>`),
then an appended run-context block:

```
--- RUN CONTEXT (appended by orchestrator) ---
Repository root: <toplevel>
Backlog item id: <id> — echo this back unchanged as "id" in the verdict JSON.
```

For claimed resolutions/downgrades, prompt =
`references/verify-resolution.md` with `<BASELINE_FINDING>`,
`<CLAIMED_RESOLUTION>`, `<PRODUCTION_SYMBOLS>`, and `<CURRENT_TESTS>` substituted,
then this run-context block:

```
--- RUN CONTEXT (appended by orchestrator) ---
Repository root: <toplevel>
Resolution item id: baseline:<original-baseline-id> — echo this back unchanged as "id" in the verdict JSON.
```

A REFUTED resolution remains in the backlog at its baseline status and under its
namespaced `baseline:<original-id>` id; never record it as closed or strip the
namespace.

A verdict with a missing or unrecognised `id` is unusable — discard it and
re-dispatch that item once. A second failure leaves the item in the backlog
flagged **UNVERIFIED**: never silently confirmed, never silently dropped.

Apply backlog-gap verdicts to the Phase 2 draft before finalising Section 6.

**A `REFUTED` whose `reason` begins `HOST-UNVERIFIED:` is not a refutation and must
never take the path below.** `references/verify-refute.md` instructs the skeptic to
return that verdict when it *cannot reach* the downstream consumer — it means "I could
not check", not "there is no gap", and by construction it cites **no test**. Dropping it
and recording the behaviour as "effectively covered, anchored to the test the skeptic
cited" therefore reclassifies an unexamined downstream risk as covered, anchored to
nothing. Carry every `HOST-UNVERIFIED` item into the report as its own **"Unsettled —
host evidence required"** section, tiered on the risk it would carry if real, naming the
out-of-repo mechanism that would have to hold. It stays out of Section 2's covered set,
stays out of the dropped-items appendix, and may become a Section 6 slice only once a
human has supplied the missing evidence.

**Route every other REFUTED gap by the check that refuted it, because only two of the
four produce a cited test.** The `HOST-UNVERIFIED` carve-out above is scoped to one
reason string; the condition underneath it — a refutation citing no test — is broader,
and promoting those into Section 2 recorded a confirmed-real gap as covered, anchored to
nothing.

- **Checks 1 and 3** cite a real test. Remove the gap from Sections 3 and 6, log it in
  the **"Items dropped in verification"** appendix with its reason, and UPDATE Section 2:
  record the behaviour as effectively covered, **anchored to that cited test**, so a real
  gap the skeptic closed by finding coverage is not thrown away with the false claim.
- **Check 2** refutes on a phantom symbol. That makes the finding malformed; it does not
  make the behaviour covered. Dropped-items appendix only — never Section 2.
- **Check 4** refutes because the *proposed* test would not fail on the regression, which
  `references/verify-refute.md` calls "a different, more useful finding" — the gap is
  real, uncovered, and worse than stated. Re-enter it in the backlog restated around what
  the skeptic found, at no lower priority. Never Section 2.

The Section 2 promotion is gated on the refutation actually citing a test: no citation,
no promotion. No Section 6 slice may reference a REFUTED item.

A CONFIRMED backlog-gap verdict may carry a non-empty `constructionWarning` — the gap is
real, but the obvious test shape cannot fail on the regression. **Store it
against the item and pass it into that item's Phase 5 dispatch verbatim.** It
is the one thing the skeptic knows that the agent writing the test does not,
and it is lost the moment the verdict JSON is discarded. Surface it in the
report alongside the item too, so a human reading the backlog sees the hazard
whether or not a fix pass ever runs.

Explore-style agents hallucinate symbol names and file contents. A backlog
of phantom gaps burns review attention and destroys trust in the report —
that is what this phase exists to prevent. Its sibling failure is a *confirmed*
gap closed by a test that cannot fail: same green tick, and nothing looks at it
again. `constructionWarning` and the Phase 5 `inferred` escalation exist for
that one.

## Phase 4 — report

Create `<vault>\Claude\Test Audit\<repo>\` if absent.

Path: `<vault>\Claude\Test Audit\<repo>\<YYYY-MM-DD>.md`.
Same-day rerun → `-2`, `-3`, ... Never overwrite.

The report header records mode and audited HEAD. Delta reports also record the
baseline report, baseline commit, exact diff range, selected axes, changed paths,
and any out-of-diff impacted paths. Add the reconciliation appendix defined in
Phase 2 and state plainly that unchanged baseline items were not revalidated.

The YAML frontmatter also records these scalar fields:

```yaml
status: <Complete or an explicit partial status>
required-evidence-axes: <comma-separated axis letters>
completed-evidence-axes: <comma-separated axis letters>
failed-evidence-axes: <comma-separated axis letters or none>
unverified-critical-items: <non-negative integer>
unverified-high-items: <non-negative integer>
```

List each axis separately; `A-G` is not a completed-axis shorthand. `Complete` is valid
only when every required axis completed, no required axis failed, and both unverified
counts are zero. Otherwise use an explicit partial status such as
`Critical tier verified; High tier deferred`.

**Every "Unsettled — host evidence required" item increments the count matching its
tier** — `unverified-critical-items` for a Critical, `unverified-high-items` for a High.
Write each item as one list entry beginning `- **Critical** —` or `- **High** —` so the
report validator can count it.
Without that, a report carrying an unexamined Critical downstream risk validated as
`Complete` and shipped: the item is deliberately not the `UNVERIFIED` flag used for a
discarded verdict, and nothing connected it to the counters the status gate reads.

Draft outside the vault, run `scripts/test-audit-report.ps1 -Path <draft>`, and publish
to the unused final filename only after it passes. A validator failure forbids publication.

Chat gets section 1 (assessment), section 3 (backlog) as a table (id, priority,
behaviour, level, cost, confidence), **and the "Unsettled — host evidence required"
section in full**. Unsettled is the only section that asks the human for something, so
delivering the report without it leaves that request with no path to the person who can
discharge it.

A report-only run ENDS HERE. Say where the report is; stop.

## Phase 5 — fix pass (only if opted in)

1. Present section 6's slices ONE AT A TIME. Approve / defer / reject each.
   No batch approval. Zero approved → clean end.
2. Review-worktree path: from project memory if recorded, else
   `<toplevel>\.claude\worktrees\reviewer-passes`. `git fetch --prune` first.
   Batch N = highest existing `reviewer-findings-batch*` across local
   branches, remote branches and project memory, plus one — monotonic,
   never reused. `git worktree add <path> -b reviewer-findings-batch<N>
   origin/main` (or the repo's mainline).
3. Per approved slice, dispatch one implementation worker using
   `references/fix-slice.md` with its placeholders substituted —
   `<WORKTREE_PATH>`, `<SLICE_ID>`, `<RISK_OR_INVARIANT>`,
   `<PRODUCTION_FILES_AND_SYMBOLS>`, `<CONCRETE_SCENARIO>`,
   `<MOCKING_VERDICT>`, `<REGRESSION_TO_DETECT>`, `<CONSTRUCTION_WARNING>`.
   Use these exact token spellings — they are what the file contains.
   `<CONSTRUCTION_WARNING>` is the verbatim field from this item's Phase 3
   verdict; substitute an empty string when there was none. Never drop the
   placeholder — an unsubstituted token reaches the subagent as literal text.
4. **Review `git -C <worktree> diff` against the approved slice before
   committing.** `fix-slice.md` requires ONE narrow production-code
   exception, by default on every slice: temporarily breaking production
   behaviour to prove the new test can actually fail, then reverting it. So
   the orchestrator must independently confirm the production files are
   clean — do not take the subagent's word for it. Any other off-scope hunk → one re-dispatch
   quoting it with an instruction to narrow; still off-scope → skip the
   slice and record it. One commit per slice. Any slice abandoned for any
   reason (this re-dispatch failure, an unparseable completion report, or a
   subagent reporting the slice no longer applies) leaves the worktree dirty
   unless reverted first — `git -C <worktree> checkout -- .` plus removing
   untracked files the slice created — before the next slice is dispatched.

   Read the completion report's **demonstrated vs. inferred** field with the
   same weight as the diff. `demonstrated` is the expected outcome. `inferred`
   means the test has never been seen to fail, so it is not known to defend
   anything — commit it if you judge it worth having, but never present the
   slice as closing the gap, and tell the user which of the two `inferred`
   cases it was. If the subagent broke the behaviour and the test stayed
   green, the slice has FAILED regardless of a green suite: re-dispatch once
   with that fact quoted, and if the second attempt cannot demonstrate it
   either, stop and hand the item back as needing a different test design. A
   test that cannot fail is worse than the gap it claims to close.
5. Full local gate before any push. .NET: build + all tests, then every
   repository-configured formatter, analyzer, and lint command. Build and tests
   alone never authorize a push. If a category has no configured command, skip
   only that category and record the configuration inspected and its absence;
   an unavailable local tool is not absence evidence. Frontend: `npx tsc -b
   --noEmit`, `npx eslint .`, `npx vitest run`, plus `npx vite build` if an
   SSR-rendered component was touched. All green, no exceptions. Red → iterate
   in the worktree; stuck → stop, no push.
6. `finishing-a-development-branch` option 2 → PR-gate sentinel → push →
   `gh pr create` per the push-vs-PR org rules. PR body emoji-free.

   **Sentinel key.** `finishing-gate.sh` looks for
   `ftdb-<basename of "git -C $CWD rev-parse --show-toplevel">`, where `$CWD` is
   the working directory of the tool call that runs `gh pr create`. Inside a
   worktree, `--show-toplevel` returns the WORKTREE path — so the key is the
   worktree dir name (`reviewer-passes`), NOT the repo name.
   `pr-gate-sentinel.ps1` derives its default the same way from its own CWD.

   So: **write the sentinel from the same working directory you will run
   `gh pr create` from**, and the bare no-arg form is correct —
   `pwsh -File ~/.claude/hooks/pr-gate-sentinel.ps1`. The two only
   disagree when the sentinel is written from one directory and the PR created
   from another. If you cannot guarantee that, pin `-Repo` to the basename of
   the toplevel as seen from the PR-creating CWD. If it blocks anyway, the error
   names the key it wanted — write that exact value.
7. Windows trap: `Set-Location` OUT of the worktree before any later
   `git worktree remove`.

## Failure handling table

| Failure | Handling |
|---|---|
| Delta report missing a unique verified baseline commit | Explain why and fall back to Full; if Full is refused, stop without an `audit-tests` report |
| Baseline commit is absent, rebased away, or not an ancestor | Never guess a merge-base; Full or stop |
| Delta impacted surface cannot be bounded safely | Full or stop; a changed-files-only report is not an audit |
| Unparseable Phase 1 evidence JSON | One retry with the contract restated; in Full, drop and disclose; in Delta, Full or stop because a selected axis was lost |
| Unparseable Phase 3 verdict JSON, or one with a missing/unrecognised `id` | One retry with the contract restated; then the item stays UNVERIFIED in the backlog — never silently confirmed, never silently dropped |
| Unparseable Phase 5 completion report | One retry; then skip that slice, clean the worktree (Phase 5 step 4), and surface it |
| Cited path does not exist | Mark the finding PATH-UNCONFIRMED; send it to Phase 3 regardless |
| No stack detected | Stop; do not guess |
| Dirty working tree | Ask before continuing |
| Fix subagent reports the slice no longer applies | Clean the worktree (Phase 5 step 4), continue with the remaining slices; surface this one to the user explicitly at the end of the pass as a decision they still owe — not buried in a record |
| Production file dirty after a fix slice | Not acceptable — revert and re-dispatch; the file's exception requires a clean production diff |
| Fix slice reports `inferred` because the regression could not be introduced | Commit if worth having, but say so to the user with the subagent's stated blocker; never report the gap as closed |
| Fix slice reports `inferred` because the test stayed green under the broken behaviour | The slice FAILED — a green suite does not redeem it. One re-dispatch quoting the fact; then hand the item back as needing a different test design |
| Check suite red after fixes | Iterate in the worktree; stuck → stop, no push |

## Common mistakes

The failure-handling table above covers what to do when a *step* fails. This covers
operator misconceptions — the ways a run goes wrong while every step appears to succeed.
Restored 2026-08-08: the section was dropped in the `SKILL.md` → `references/` split with
no successor, and neither the failure table nor the repository README replaces it.

| Mistake | Correct |
|---|---|
| Calling an ad hoc diff review a delta audit | Delta requires a verified report, its audited ancestor commit, impacted-surface tracing, synthesis, and verification |
| Treating unchanged baseline items as revalidated | Mark `unchanged-not-revalidated`; list ids/counts only |
| Marking a baseline item resolved because a test was added | Read the assertions and verify the Critical/High closure with `verify-resolution.md` |
| Forcing Delta after broad boundary or architecture changes | Fall back to Full when callers/consumers cannot be bounded safely |
| Blocking because a named model or API is unavailable | Select workers by capability using the runtime's native primitives |
| Reporting a coverage percentage as the verdict | Coverage is supporting evidence; the verdict is whether a regression would be caught |
| Handing coverage artefacts to agents A-G | Agent H only — A-G build the risk model first |
| Shipping an unverified Critical item | Every Critical and High item is refuted first |
| Counting tests instead of reading their assertions | Presence is not effectiveness |
| Writing a test before its slice is approved | Phase 5 is a hard per-slice gate |
| Fixing in the primary checkout | Review worktree + `reviewer-findings-batch<N>`, no exception |
| Reusing a batch number | Monotonic across local + remote + memory |
| A subagent committing | The orchestrator owns git |
| Adding the `FluentAssertions` package | AwesomeAssertions — see `references/stack-conventions.md` |
| A sleep-based async test | Event-driven: await a signal or poll with timeout |
| CI-gate findings in the test backlog | `measurement` findings go to section 7 |
| Accepting a new test that has never been seen to fail | `inferred` is an escalation; the break-and-revert step is the default on every slice |
| Dropping a verdict's `constructionWarning` after Phase 3 | Carry it verbatim into that item's Phase 5 dispatch and into the report |
