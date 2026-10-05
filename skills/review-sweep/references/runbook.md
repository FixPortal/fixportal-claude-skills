# Review Sweep Runbook

## Contents

- [Discover and scope](#discover-and-scope)
- [Panel pre-flight](#panel-pre-flight)
- [Evidence-driven triage](#evidence-driven-triage)
- [Approval and runbook](#approval-and-runbook)
- [Execute and consolidate](#execute-and-consolidate)


## Discover and scope

Inspect top-level directories beneath the requested root. Keep roots where
`git -C <dir> rev-parse --is-inside-work-tree` succeeds. Require clean working
trees because uncommitted changes are invisible to an audit diff.

Verify each target is checked out at the approved merged mainline. Scope the
pass to one named subsystem. If a request spans subsystems or includes a whole
never-reviewed repository, stop and show the proposed narrower pass for one
approval.

## Panel pre-flight

Resolve the loaded `adversarial-review` skill directory and read its
`reviewers.json`. For each enabled reviewer:

1. Resolve `wrapper` through the manifest and confirm the sibling file exists.
2. Read the wrapper header and execute its exact `PREFLIGHT_COMMAND:`. Accept
   only its documented `PREFLIGHT_SUCCESS:`.
3. When the primary fails and declares `fallbackWrapper`, pre-flight that
   wrapper identically.
4. Record primary/fallback availability and any metered degradation.

Compute distinct available vendors. Below `minVendors` is a hard stop. Any
other degradation belongs in the approval message.

## Evidence-driven triage

Resolve `review-digest` and run its `collect.ps1` once for the parent path.
Join discovery to collector rows by canonical `resolvedPath`. Git fields are
nested under `.git`: `.git.boundarySha`, `.git.effectiveNeverReviewed`,
`.git.sinceReviewCount`, `.git.sinceReviewFiles`, `.git.sinceReviewIns`,
`.git.sinceReviewDel`, and `.git.daysSinceReview`; `hasTrackedSource` is a
top-level field. `sinceReviewCount` and `sinceReviewFiles` count changes after
the newest usable review boundary. Each `reviewCoverage` group keeps its own
counts from its own boundary, including changes that predate that review.
`hasTrackedSource` describes the full tracked tree; `hasCoveredSource` describes
reviewed groups. Consume the top-level `scopeValidation` and `subsystemPaths`
exactly as emitted; do not recreate pathspec validation.
The queue value shows the highest-priority class for the row; a repository can
also have changed coverage groups or open review records. Process every emitted
class: new source, each changed group, and open-review age are separate evidence.
`git.sinceReviewFiles` is the count of covered files changed since the newest
review boundary. The path names live in each `reviewCoverage[].changedFiles`
list, while newly uncovered paths live in `newSource`.

Each discovered repo needs exactly one admissible row: `unresolved` and
`outsideScanPath` false, `vault.isDocumentReview` false, and `resolvedPath`
equal to the repo root. Missing, duplicate, unresolved, outside-scan, or
document-review matches are `UNKNOWN` with a reason and `STOP` before approval.
Vault-only rows never create targets.

`effectiveNeverReviewed` is authoritative. Do not use `.git.neverReviewed` or
recreate git-marker inference: a prose-only git marker is already emitted as
full-history `effectiveNeverReviewed = true` by `review-digest`.

Evaluate `scopeValidation` before `hasTrackedSource`. Only `none` (whole repo)
and `valid` are usable scope states; any other value is unknown. An invalid
declared scope stays UNKNOWN even if another field appears to say it is empty.

| Evidence | Class | Action |
|---|---|---|
| `scopeValidation = invalid` | UNKNOWN | STOP before approval; report the invalid declared subsystem paths |
| `scopeValidation` missing or unrecognized | UNKNOWN | STOP before approval |
| `scopeValidation = valid`; `hasTrackedSource = false` | skip/void | Record the validated scope as not code-reviewable; do not audit |
| `scopeValidation = none`; `hasTrackedSource = false` | skip/void | Record the whole repo as not code-reviewable; do not audit |
| usable scope state; `hasTrackedSource` missing or null | UNKNOWN | STOP before approval |
| `hasTrackedSource = true`; `queue = new-source` | new source | Review the emitted `newSource` paths; do not use the newest scope's boundary for these files |
| `hasTrackedSource = true`; `effectiveNeverReviewed = false`; all groups unchanged | skip | Record unchanged |
| `hasTrackedSource = true`; `effectiveNeverReviewed = false`; any group has changed files | drift | Review each changed `reviewCoverage` group under that group's boundary and paths |
| `openReviewCount > 0` | open review | Report the count and `oldestOpenReviewAgeDays` separately; do not count it as file drift |
| `hasTrackedSource=true`; `effectiveNeverReviewed=true` | audit | Audit only the approved `subsystemPaths` pathspecs |

"The approved `subsystemPaths` pathspecs" means the approved SCOPE, which is not always
that array — read it with `scopeValidation`, which is what says whether the array means
anything:

- `scopeValidation = valid`: the scope IS `subsystemPaths`; audit or diff under exactly
  those pathspecs and no others.
- `scopeValidation = none`: no subsystem was declared, `subsystemPaths` is EMPTY, and the
  approved scope is the WHOLE REPOSITORY. Run the command with no `--` clause at all.
  (`git ... --` with nothing after it applies no path restriction and selects everything,
  so it is harmless here; what is NOT harmless is substituting a placeholder or a guessed
  path when the array is empty, which silently narrows the audit to something the review
  never approved.)
- `scopeValidation = invalid`, or missing/unrecognised: STOP, per the rows above. There is
  no scope to approve and none to substitute.

`sinceReviewFiles` is a file count, not a list. For drift candidates, expand
`reviewCoverage` and use each group's boundary and paths; a bare
range here sizes work the approval will not cover. Size the total diff, including
deletions and context, so transport-heavy drift is visible before approval.

**Docs/assets/brand-only drift becomes skip**, and the test is the FILE LIST from that
command, applied to every changed path — not an impression of the change. The drift is
docs/assets/brand-only when every path is one of:

- a Markdown or plain-text document (`*.md`, `*.mdx`, `*.txt`, `*.adoc`), including
  `README`, `LICENSE`, `CHANGELOG` and anything under `docs/`;
- a binary or vector asset — image, font, icon, video, PDF (`.png`, `.jpg`, `.jpeg`,
  `.gif`, `.svg`, `.webp`, `.ico`, `.woff`, `.woff2`, `.ttf`, `.otf`, `.eot`, `.mp4`,
  `.webm`, `.pdf`);
- a brand or content value with no behaviour: a colour, a logo path, a display string, a
  copy block.

Anything else makes the drift reviewable, and ONE such path is enough — a `*.md` change
sitting beside a single `*.ts` change is not docs-only. Three shapes are called out
because they read as content and are not:

- a config or manifest file, even a data-only one (`*.json`, `*.yml`, `*.toml`,
  `*.csproj`, `package.json`): it changes what runs;
- a workflow, script or hook under `.github/`, `scripts/` or `hooks/`, whatever its
  extension;
- an SVG carrying a `<script>` element, which is code in an asset's clothing.

Where a path genuinely fits none of these — a templating language emitting both markup and
logic, say — it is REVIEWABLE. The skip exists to spare review budget on changes that
cannot alter behaviour, and a path whose category is uncertain has not met that bar.

## Approval and runbook

In one message show the triage table, the single-subsystem chunk/pathspec plan,
any degradation, and the projected marginal cost of selected metered wrappers.
Read current pricing from the wrapper or linked primary documentation; unknown
rates remain unknown. Subscription-backed wrappers have zero marginal API cost.

After approval, write one durable plan/task item per drift review or audit
target plus consolidation. If the runtime has no durable plan facility, keep
the equivalent conversation checklist. Update it through compaction.

## Execute and consolidate

Invoke `adversarial-review` sequentially:

- drift: `<boundarySha>..HEAD -- <approved subsystem pathspecs>`
- audit: `audit -- <approved subsystem pathspecs>`

Both carry the pathspecs. Approval was granted against the single-subsystem plan,
so a bare range spends panel budget outside the approved scope and — worse — the
report then claims a repository boundary the approval never granted, which becomes
the recorded coverage boundary the next sweep trusts. A genuinely whole-repo
approval is `scopeValidation = none` with no pathspecs to pass, never a pathspec
dropped at execution time.

Let each invocation own chunking, synthesis, and vault persistence. Do not
report per target. At the end provide one row per repository with class,
Critical/High counts, contested findings, and notes. Include skipped repos and
their reasons. Never silently resolve contested findings.
