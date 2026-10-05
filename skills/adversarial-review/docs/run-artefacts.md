# Run artefacts — the files a run must carry

## Contents

- [`preflight.json` — pre-flight evidence (run root)](#preflightjson--pre-flight-evidence-run-root)
- [`status.json` — trial participation (work directory)](#statusjson--trial-participation-work-directory)
- [`pooled-map.json` — F-id to reviewer (work directory)](#pooled-mapjson--f-id-to-reviewer-work-directory)
- [`aggregate-verdict.json` — accepted counts and the judge row (run root)](#aggregate-verdictjson--accepted-counts-and-the-judge-row-run-root)
- [`working-tree.patch` — snapshot of uncommitted reviewed content (work directory)](#working-treepatch--snapshot-of-uncommitted-reviewed-content-work-directory)
- [What a Phase-4 verdict records about its own provenance](#what-a-phase-4-verdict-records-about-its-own-provenance)
- [`_index.md` coverage block — the machine-readable shape](#_indexmd-coverage-block--the-machine-readable-shape)
- [`coverage-waiver:` — for a legacy record that cannot be repaired](#coverage-waiver--for-a-legacy-record-that-cannot-be-repaired)
- [`_index.md` `disposition:` — when each value is written](#_indexmd-disposition--when-each-value-is-written)


Canonical shapes for the sidecars `run-review.ps1`, `batch-review.ps1` and
`aggregate-and-emit.ps1` read or write. `SKILL.md` states *when* each is required;
this file states *what it is*. Change this file and its contract tests, never a
restatement elsewhere.

Every one of these existed as a claim in `SKILL.md` before it existed as a file,
which is the failure mode the whole set is written against: a gate that names an
artefact nothing produces is discharged on faith.

## `preflight.json` — pre-flight evidence (run root)

Written by the **host** before the driver starts, because `run-review.ps1` cannot
parse wrapper headers and does not pretend to. The driver refuses to start without
it, so "pre-flight ran" is evidence rather than recollection.

```json
{
  "runId": "<leaf name of the directory holding this file>",
  "checked": [
    { "reviewer": "b",
      "wrapper": "claude-review.ps1",
      "command": "<the PREFLIGHT_COMMAND: header that was run>",
      "result": "PREFLIGHT_SUCCESS" }
  ]
}
```

- Looked for in `-WorkDir`, then its immediate parent — so a batch run writes **one**
  file in the `RunRoot` and it covers every chunk beneath it.
- Every enabled, unexpired regular reviewer requires `PREFLIGHT_SUCCESS`.
  Supplemental seats without success are skipped and disclosed, not fatal.
  Record their failed preflight honestly; no manifest edit is needed. Extra
  entries are ignored.
- `runId` must equal the leaf name of the directory holding the file. Without that
  binding, one stale file in the shared default parent (`<temp>/adversarial-review`)
  would satisfy every later run on the box.
- A wrapper declaring no `PREFLIGHT_COMMAND:` is **unverified, not passing**: record
  its real result and disable the reviewer rather than inventing a pass.

## `status.json` — trial participation (work directory)

`vendorsP1` and `vendorsP2` count all responding vendors; `quorumVendorsP1` and
`quorumVendorsP2` exclude supplemental seats and enforce `minVendors`.
When there are no findings, Phase 2 is skipped and its counts inherit Phase 1.
`supplementalReviewers` lists active supplemental IDs; `expiredReviewers` lists
enabled IDs skipped because their UTC `expiresAt` cutoff passed. Expired seats
require neither model resolution nor preflight. The cutoff controls routing,
not subscription billing or account entitlement.
`skippedSupplementalReviewers` lists unexpired supplemental IDs without successful
preflight. These seats are omitted from both rounds and named in the judge packet.
`phase2Abstentions` lists, per participating Phase-2 reviewer, the pooled F-ids it
gave no verdict line for (F-id plus AGREE / FALSE POSITIVE / NEEDS EVIDENCE /
NEEDS REPO); a bare mention is not a verdict. A reply whose verdicts name only ids
outside the pool lands in `offContract` and does not count toward `vendorsP2`.
`pooledCount` is what `batch-review.ps1` reads to report a chunk CLEAN; its
`batch-summary.json` rows also carry `timedOut` (exitCode null) for a chunk stopped
at `-ChunkTimeoutSeconds`, which `aggregate-and-emit.ps1` treats as failed.

## `pooled-map.json` — F-id to reviewer (work directory)

Written by the driver beside `pooled-findings.txt`. The pooled findings are
attribution-stripped by design so Phase 2 cannot see who raised what; telemetry
still has to credit `IssuesAccepted` to the raising vendor, so the mapping lives in
a separate file the judge is never given.

```json
{ "runId": "<work directory leaf>",
  "findings": { "F1": { "reviewer": "b", "label": "Claude (Sonnet)", "vendor": "anthropic" } } }
```

An empty pool writes `"findings": {}` — the honest record of a round that raised
nothing, rather than an absent file the aggregator has to guess about. Do not try to
recover ownership from `pooled-findings.txt`.

## `aggregate-verdict.json` — accepted counts and the judge row (run root)

Written by the **host** at §5 synthesis, and read by `aggregate-and-emit.ps1`
(`-VerdictPath`, defaulting to `<RunRoot>/aggregate-verdict.json`). It carries the
two facts no script can derive: whose findings survived adjudication and
verification, and what the judge cost.

```json
{
  "accepted": { "anthropic": 6, "google": 3, "openai": 4 },
  "judge": { "reviewer": "anthropic", "model": "<resolved registry id>",
             "inputTokens": 90000, "outputTokens": 0,
             "costUsd": 2.7, "reviewDurationMs": 140000 }
}
```

Both keys are optional to the script and neither is optional in practice: a missing
`accepted` publishes zeros for every vendor, and a missing `judge` publishes a run
with no judge.

**Derive `accepted` from the FINAL dispositions, then attribute with
`pooled-map.json`** — in that order, because the two files answer different
questions. `pooled-map.json` records F-id ownership and nothing else: it does not
know which findings survived Phase 3 adjudication or Phase 4 verification, so
counting from it alone credits a vendor for findings that were dropped or REFUTED.
Take the accepted F-id set from the chunk's own report and verdicts, then look each
id up in `pooled-map.json` to learn whose it was. Zeros are honest only when the
panel genuinely accepted nothing; when the mapping is unavailable, say so in
`_index.md` rather than publishing counts that look measured.

## `working-tree.patch` — snapshot of uncommitted reviewed content (work directory)

Written by the driver when the target is working-tree-inclusive and the tree is
dirty, with its `workingTreeSha256` recorded in `status.json`. A review of a dirty
tree covers bytes no commit contains, so without this there is no identity for what
was read, and a Phase-4 detached worktree cannot be brought level with it.

`git apply --index` it in the verifier's detached worktree, commit the result so
the tree is clean for verification, then record the resulting commit and patch hash
in the verdict. If it does not apply cleanly, that route is unavailable for that finding —
use diff-and-context or a repo-aware verifier rather than verifying against a commit
the review did not cover.

## What a Phase-4 verdict records about its own provenance

The route a verifier took must be readable from its verdict, because "no dirty-tree
note" and "no tree at all" are otherwise the same silence.

- **Worktree route** (a checkout, detached or live): record `git rev-parse HEAD` and
  `git status --porcelain` at the end. A dirty tree at run end forces `INDETERMINATE`.
  A `repoAccess: false` member may take this route only through a detached-commit
  `git worktree`, never the live tree (`SKILL.md` §4).
- **Hermetic route** (diff and context files, no checkout): open to every member, and
  the other route open to a `repoAccess: false` member. Those commands cannot be run
  and are not expected to be. Record the diff's `sha256` from `status.json` instead, or
  the `sha256` of each inlined file when the evidence is context files rather than the
  diff, and say the read was hermetic.

Omitting the provenance line entirely is what is forbidden. A verdict that records
neither shape cannot be told apart from one whose author skipped the check.

## `_index.md` coverage block — the machine-readable shape

Read by `validate-report.ps1` and `review-digest/collect.ps1`. `SKILL.md` §5 says
when it is written and which target ends must already be resolved; this is what it
looks like.

```yaml
scope-kind: repository # or subsystem/document
target: <base-sha>..<reviewed-tip-sha>
# an `audit` target bases on the canonical empty tree:
# target: 4b825dc642cb6eb9a060e54bf8d69288fbee4904..<reviewed-tip-sha>
working-tree-sha256: <status.json workingTreeSha256>  # only when the target was dirty
reviewed-paths:        # required for subsystem; optional chunk evidence for repository
  - src/**
excluded-paths:        # machine pathspecs, never prose
  - generated/**
disposition: reviewed  # open/reviewed/remediated
```

Coverage entries must be positive pathspecs. Do not use `:!`, `:^`, or
`:(exclude)` entries; an exclusion-only pathspec can make Git return unrelated
changed paths and falsely satisfy repository coverage.

A run that convened no panel declares `reviewers: none` and `judge: none`, and must
then also carry a non-empty `skip-reason:` saying why. `validate-report.ps1` enforces
that pairing in both directions, which is what stops a silent skip: a run either names
the reviewers it had, or admits it had none and states the reason. Omitting the reason
while claiming reviewers is then a fabrication rather than a silence — visible to
anyone who reads the report, and not something the shape check can be talked past.

No validator can attest that a human was actually asked. What this pairing buys is
narrower and worth having: every skipped range is machine-discoverable in the vault,
with its justification attached, instead of being indistinguishable from a completed
review.

A chunked pass that collectively tiled the repository is `scope-kind: repository`;
chunks are `reviewed-paths`, not `subsystem`. `scope-kind: subsystem` means the
uncovered tree deliberately retains its older repository boundary. Narrative
rationale belongs in `scope-note:`. The legacy `subsystem:` key is read only for old
reports and must not be emitted by new runs.

### `coverage-waiver:` — for a legacy record that cannot be repaired

A record written before this shape existed often has no recoverable target at all: no
`target:` key, or a prose one, or a `..HEAD` with no `head:`, and no sha anywhere that
survives a rebase. `review-digest` reports every one of those as unreadable, forever, and
they do not get fewer on their own.

Once a record has actually been READ and its coverage found unreconstructable, say so in
the record:

```yaml
coverage-waiver: predates the base..tip contract; no target recorded and no sha in the
  report body that resolves against this repository
```

`collect.ps1` then classifies it `coverage-waived` instead of `no-exact-target`, and
`write-report.ps1` counts it with `document-review` and `superseded` rather than in the
unreadable headline.

Three rules, because this key is the only one here that makes a record count for less:

- **It is per record and it carries its reason.** A date cutoff in the collector would
  silence the same records without any of them saying why, and would silence a genuine
  defect written in the same window along with them.
- **It is not a substitute for repairing what can be repaired.** `validate-report.ps1`
  rejects a waiver on a record whose `target:` already resolves. A rebased sha usually
  still resolves — find the commit on the mainline with the identical **patch-id**
  (`git diff-tree -p <sha> | git patch-id --stable`), not the identical title and not the
  identical tree: a rebase replays onto a different base, so the tree changes while the
  patch does not.
- **Removing the line puts the record back in scope.** Nothing else needs undoing.

A **predicate**-selected set ("files with >= 10 semantic added lines") still has a
machine form: **enumerate the files it selected**, keeping the predicate in
`scope-note:` for a human to regenerate and check later. Never substitute containing
directories or claim `scope-kind: repository` — both claim coverage the pass lacked.
A later rename that stops the list resolving is correctly UNKNOWN, not a bug.

## `_index.md` `disposition:` — when each value is written

- `reviewed` — a completed run, **or a target the operator chose not to send to the
  panel** under `SKILL.md` §0. A panel that never convenes is not `open`: `open` is
  for a panel that started and failed to finish, and re-queuing a deliberately
  skipped range forever is the worse failure. A skip must carry `skip-reason:`
  (below), so the two cases stay distinguishable by machine rather than by tone.
- `remediated` — written by `review-worktree-pass` once every finding has a
  disposition, together with `remediation-tip: <40-character mainline SHA>`.
- `open` — a run that produced an `_index.md` and did NOT finish: the panel aborted,
  Phase 3 never ran, the report is absent or partial. It exists so a folder on disk
  cannot be mistaken for a completed review.

A successful pass never emits `open`, and nothing upgrades it automatically. An `open`
folder is discharged by re-running the review over that target and overwriting it, or by
retiring it with `_retired.md`. Leaving one is not an error; reading one as `reviewed`
is, which is why the value exists rather than the key being absent.
