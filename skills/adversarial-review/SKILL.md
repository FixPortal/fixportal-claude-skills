---
name: adversarial-review
description: Use when the user requests an adversarial, cross-vendor, or multi-model code review, now or deferred, or runs /adversarial-review. Reviews a branch, diff, pull request, module, or whole-repository audit inside Git; for multi-repository sweeps use review-sweep.
---

# Adversarial Review

Run a multi-vendor panel whose value is uncorrelated error: blind findings,
anonymous cross-examination, adjudication, and live-code verification. Always
invoke this skill for its trigger phrases. Never substitute a panel of
general-purpose same-host workers.

Read `reviewers.json` every run; do not name a remembered panel or model. Pass
files under `briefs/` verbatim.

## Usage

```text
/adversarial-review [<target>] [-- <pathspec>…]
```

- no target: current branch and working tree against the default-branch base;
- PR number: `gh pr diff`; pathspecs are rejected because that transport cannot
  apply them;
- ref/range: Git diff against that revision/range;
- `audit -- <pathspec>`: current state against the empty tree.

Whole-repository audits split into cohesive subsystem pathspecs, never one
giant diff. Exclude generated/migration/build outputs where appropriate.

## Pre-flight

1. Require a Git worktree and read the active manifest. Skip seats whose UTC
   `expiresAt` has passed before preflight or model resolution.
2. Resolve each enabled primary wrapper and execute the exact
   `PREFLIGHT_COMMAND:` from its header; accept only `PREFLIGHT_SUCCESS:`. Try a
   declared `fallbackWrapper` identically and disclose metered/degraded use.
   **Host step:** the driver does not parse headers. Missing `PREFLIGHT_COMMAND:`
   means unverified. Record results in the required run-root `preflight.json`
   (`docs/run-artefacts.md`).
3. Stop if available non-supplemental vendors fall below `minVendors`.
4. For a dirty target, include the working-tree diff deliberately or stop —
   never imply uncommitted work was reviewed when it was invisible.
   **Enforced, not advisory**: `run-review.ps1` checks `git status --porcelain`.
   Bare branch/SHA targets include tracked edits; git diffs omit untracked files
   for every non-PR target. The driver stops unless in-scope omissions are recorded
   in `status.json` and the judge packet. `audit` and `A..B` also omit tracked edits.

## Procedure

### 0. Resolve and size

Resolve the target exactly as Usage states. Capture the diff, added/total lines,
and estimated tokens. Repo-blind reviewers get compact diffs once the driver
crosses its transport gate; routing comes from each manifest entry's
`repoAccess`, never hardcoded IDs.

Before choosing a repository-aware Codex route, read
`~/.agents/notes/model-routing-traps.md` (if that note is not present, proceed
and record the assumption); it governs that mode.

**A target whose reviewable surface, after `excluded-paths`, is only dependency
bumps does not convene the panel by default.** Estate policy keeps those out of AI
review because they starve a finite allowance, and a version or pinned-SHA move
has one question of mechanism, answerable by lookup. Answer it, put the choice to
the operator, and never skip silently. A skip still persists a validated run folder at
`disposition: reviewed`, or `review-digest` re-queues the range forever, carrying
`reviewers: none`, `judge: none` and a `skip-reason:` — `validate-report.ps1`
requires those together. Say in both `_index.md` and `report.md` that no panel ran,
and emit neither telemetry nor
`aggregate-verdict.json`, whose zeros read as a verdict. Most action bumps fall to
one lookup — an old pin that is an annotated tag object, not a commit, dereferences
through `gh api repos/<o>/<r>/git/tags/<sha>`, often to the very commit the bump
"moved" to.

### 1–2. Blind review and cross-examination

Run the driver once per approved chunk. It passes `briefs/phase1-review.txt`
(with the relevant audit/system preamble) to enabled reviewers, pools and
anonymises findings, then passes `briefs/phase2-cross-examine.txt` with the set.

Phase 1 and Phase 2 must each retain `minVendors`; zero output or a diversity
collapse stops before metrics or a judge packet. Wrapper failures are visible;
only manifest-declared fallbacks may replace them.
`supplemental` seats contribute findings and cross-examination, never quorum or
judge/audit/verifier/synthesis roles. Failed or missing preflight skips them visibly.

### 3. Adjudicate

Use `roles.judge` with `briefs/phase3-adjudicate.txt` and the judge packet.
Measure consensus by vendor, not reviewer headcount. Preserve contested
findings, correct refuted mechanisms, and inspect the repository when a
repo-blind limitation leaves a mechanism unsettled.

### 3.5. Judge audit

Mandatory when the review gates a merge or the target is HIGH-tier; otherwise
optional. `docs/METHODOLOGY-v2.md` and `reviewers.json` say the same.

**Tier a non-PR target** by running the repo's own `.claude/review-policy.json`
globs over `git diff --name-only <target>` — the PR gate's classifier, fed the
range. No policy file means NORMAL. Never self-classify to skip the phase.

Select from `roles.judgeAudit.pool` and pass
`briefs/phase3.5-judge-audit.txt` verbatim. This checks the adjudicator for
dropped/misrated findings; it does not replace verification.

**Fold every `Correction:` into `report.md` before Phase 4.** An unfolded
`DROPPED` finding is invisible to Phase 4, producing no engineering outcome; the
3.5 brief makes a `DROPPED` correction carry severity, trigger and impact, so it
folds unconditionally and is rateable. An `UNKNOWN` severity enters Phase 4 as
contested rather than being dropped again.

A demotion (uncontested High taken below High) removes the finding from Phase-4
scope untested, so route it back to the judge rather than applying it. **Terminus:**
re-run `briefs/phase3-adjudicate.txt` on that one finding with the judge packet plus
the auditor's block; that second verdict is final. Until it returns the finding
keeps its severity and its Phase-4 slot, so a demotion that never returns is never
applied. Restored/promoted-to-High findings enter Phase 4 like any other.

### 4. Verify

Every Critical, High, and contested finding is verified against live code by a
fresh worker from `roles.verifier.pool`, rotating vendors. Prefer a vendor
other than the one that raised the finding; `briefs/phase4-verify.txt` requires
its own verdict regardless, so a same-vendor check is weaker, not invalid — say
which it was. Use that brief verbatim.
Record `CONFIRMED`, `REFUTED`, or `INDETERMINATE` with file/line evidence in each
finding's `**Verification**` line. Never
publish a High solely because a blind reviewer sounded confident. `REFUTED`
moves the finding out of the `_index.md` severity tally — record it in
`report.md` with its evidence, never counted as open. **`INDETERMINATE` KEEPS its
severity and its tally slot** — only `REFUTED` removes anything, because no answer
is not evidence of absence. Record what would settle it.

**Honour each pool member's own `repoAccess`** — declared per member, not per role.
`repoAccess: false` means one thing: the wrapper has no per-invocation read-only
mode, so it never gets the live checkout. It is **write isolation**, not a claim the
member is untrusted with the source. Give it the diff and context files, or a
**detached-commit `git worktree`**, never `-RepoPath` on the live tree. The verdict
records the commit read (`git rev-parse HEAD`) and `git status --porcelain` at end.

That is the WORKTREE route; a hermetic member records the diff `sha256` instead. Either
way the verdict says which route it took — `docs/run-artefacts.md`.

- **A dirty tree at run end forces `INDETERMINATE`.** The brief invites a probe, so
  leftovers are expected — but a verdict read off a tree the verifier modified is not
  evidence. Re-run that finding in a fresh worktree.
- **The worktree route is forbidden for a target carrying uncommitted work unless
  that work is applied first.** A detached commit cannot hold bytes no commit holds,
  so the verifier reads absence and refutes a real finding as "no such path exists".
  Apply the driver's `working-tree.patch` with `git apply --index`, commit it in
  the detached worktree, and record the resulting commit and patch hash in the
  verdict (`docs/run-artefacts.md`).

A working-tree-inclusive review has no commit identity, so `_index.md` records
`working-tree-sha256:` from `status.json` beside the literal `target:` range.

### 5. Synthesize and persist

For multi-chunk audits, use `roles.synthesis` and `briefs/synthesis.txt` to
deduplicate, reconcile severity, preserve contention, and surface cross-cutting
themes. Do not re-review during synthesis.

Write the final report additively to
`<vault>\Claude\Adversarial Review\<repo>\<RunId>\` (`RunId` = `yyyyMMddTHHmmssZ`).
**The per-run folder is required.** Consumers scan `<repo>\<run-folder>\_index.md`
(`review-digest/collect.ps1`, `state-of-play`); writing into `<repo>\` leaves
`vault.exists` false, so the report is never discovered and successive runs collide.
Contents:

- `_index.md` — `project`, `review-type`, `date`, `reviewers`, `judge`, severity
  tally, and the machine-readable coverage block below. Resolve both target ends
  before writing; a completed report never persists symbolic `HEAD`. An `audit`
  base is the literal empty tree, which `validate-report.ps1` and
  `review-digest/collect.ps1` both accept; never fabricate a base commit or omit
  `scope-kind` to dodge the gate. Shape, `scope-kind` selection, predicate sets and
  `disposition` values: `docs/run-artefacts.md`;
- `report.md` — target, manifest-derived participants, findings, vendor consensus,
  Phase 4 evidence, chunk coverage;
- `working/` — per-phase transcripts and the judge packet.

**Also write `aggregate-verdict.json` into the `RunRoot` here** (shape:
`docs/run-artefacts.md`). It carries the accepted-per-vendor counts and the judge
row — the two facts no script can derive — and without it `aggregate-and-emit.ps1`
publishes zeros that read as a verdict.

**`report.md` carries every finding, every severity — never a curated subset.**
Rank freely; never omit to shorten. Only same-report duplication removes one; a
Low keeps its file:line evidence, never dropped for priority. A `REFUTED` finding
**stays** in `report.md` with its refuting evidence and leaves only the `_index.md`
severity tally — deleting it discards the verification that settled it.

Resolve `<vault>` from the runtime's active user instructions; never hardcode a
drive letter **in this skill's own writes**. The
consumers are pinned and this rule does not claim otherwise — `collect.ps1`,
`review-sweep` and `state-of-play` default to the estate's single vault root, so if
the resolved vault differs, pass them `-VaultRoot`. A report outside the root they
scan is never discovered, and reads downstream as never reviewed.

Then gate the run folder with `validate-report.ps1 -Path <run-folder>
-RepoPath <repo>`; it validates exact targets and path coverage. Fix and re-run
until clean. The chat response leads with Critical/High, contested items, and
evidence gaps — the report itself must not lead-and-drop.

Review is read-only. Remediation is a separate approved pass in the dedicated
review worktree.

## Telemetry

Emit one telemetry row per **vendor-participant** plus the judge: same-vendor seats
merge into one `anthropic/reviewer` row. Two rows for two seats of one
vendor is unachievable — `-Reviewer` is a vendor-level ValidateSet, both rows carry
the key `(runId, anthropic, reviewer)`, and the Observatory upserts on it — so sum
the seats into the merged row rather than emitting twice. That merge makes per-seat
acceptance unrecoverable; `reviewers.json` records which retirement it blocks. Multi-chunk
runs use `aggregate-and-emit.ps1`; for a single chunk, call
`emit-review-telemetry.ps1` after Phase 4 with the work directory's `-RunId`. Include
`Role` because the Observatory upserts on `(runId, reviewer, role)`. The driver's
`pooled-map.json` (shape: `docs/run-artefacts.md`), never consensus tags, is the
F-id-to-vendor source. Credit
`IssuesAccepted` only to the vendor's own Phase-1 findings that survive adjudication and
verification; derive ownership from pooled provenance, and never let accepted exceed
raised. Resolve moving model aliases and prices through the canonical model registry.
When resolution fails, preserve `costUnknown=true` and render `UNKNOWN`, never zero or a
stale estimate. Disclose every metered fallback.

## Canonical contracts

| Contract | Source |
|---|---|
| Panel/roles/access/fallbacks | `reviewers.json` |
| Seat model resolution | `model-registry` (optional; literal `model` fallback) |
| Phase prompts | `briefs/*.txt` |
| Deterministic Phase 1/2 driver | `run-review.ps1` |
| Multi-chunk driver/aggregation | `batch-review.ps1`, `aggregate-and-emit.ps1` |
| Telemetry emission (one row per vendor-participant) | `emit-review-telemetry.ps1` |
| Design rationale | `docs/METHODOLOGY-v2.md` |

Do not mirror prompt bodies or roster facts here. Change the canonical file
and its contract tests instead.

## Stop

- Available vendors below `minVendors` in either review round.
- A **run-level** collapse: no reviewer produced usable output in a round. One
  reviewer going quiet is not a stop — the driver warns, marks it unavailable and
  continues while diversity holds.
- PR pathspec requested.
- A remembered model/wrapper is about to override the manifest.
- A report would call unverified Highs confirmed or silently erase contention.
