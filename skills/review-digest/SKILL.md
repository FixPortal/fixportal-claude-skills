---
name: review-digest
description: Use when the user requests a review digest, what changed since the last adversarial review, review coverage across repositories, or a ranked queue of what to review next from existing adversarial-review records.
---

# Review Digest

Answers one question per repository: what has changed since the last adversarial review,
and how much. It reads existing vault records and git; it never reviews, edits scanned
code, or interprets findings.

## Run

1. Under PowerShell 7, run this skill's `collect.ps1` with the estate file and a unique
   `-OutFile`:

   <!-- routing: collect -->

   ```powershell
   & '<skill-dir>/collect.ps1' -EstateFile '<skill-dir>/estate.json' -OutFile '<unique>.json'
   ```

   `estate.json` ships as an empty template (`paths: []`, `vaultRoot: "<vault>"`); fill it in for your machine before the first run. It holds this machine's scope once: `paths` (repositories, or parents of
   repositories), `vaultRoot` (the vault's `Claude\Adversarial Review` folder) and `exempt`
   (`{ repo, reason }` for repositories deliberately left out of review - vendored forks, second
   checkouts). Scope changes go in that file, not in the command. Explicit `-Path`,
   `-VaultRoot` and `-Exempt` still work and win; there is no built-in default for either path.

   <!-- routing: write-and-publish -->

2. Run `write-report.ps1 -DataFile <json> -OutFile <report.md>`. Publish the report under
   `<vault>\Claude\Review Ledger\` as `YYYY-MM-DD-HHmmss-review-digest.md`.
   Existing ledgers are immutable; a correction is a new dated report.

   <!-- routing: present-ranked-queue -->

3. Give the user the report's column key and ranked table, pasted from the report, then
   the per-repository prompts they ask for. Do not restate the columns in different words,
   and do not hand-edit counts, ranges, file lists or scores; fix the evidence or the
   script and rerun.

## What counts as a review

A vault run `<VaultRoot>\<folder>\<run>\_index.md` attaches by its
`repo-path: <absolute repository path>` when present; otherwise its folder name must equal the
repository folder name. It is **usable** when it has:

- `date: yyyy-MM-dd`
- `target: <base>..<tip>` with both ends resolvable in the repository (`..HEAD` only with a
  `head: <sha>` key; an audit base is the empty tree `4b825dc6...`), tip on HEAD's ancestry
- `scope-kind: repository` or `subsystem` (`document` is skipped; missing means repository
  unless paths are declared)
- for subsystem, every `reviewed-paths:` entry (legacy `subsystem:`) must match a tracked
  file at the reviewed tip; one unmatched entry makes the run unusable and its scope invalid;
  `excluded-paths:` are subtracted

`remediation-tip:` records where remediation finished; it never moves the review boundary.
List exact on-HEAD fix commits under `remediation-commits:` to subtract them from every
coverage group. The collector shows files changed only by those commits separately and never
scores them. Commits between the reviewed tip and remediation tip remain drift unless listed.

A usable run covers the files its range changed within its paths. Every tracked file belongs to
the newest usable run that covers it, with ownership followed through Git renames. Each coverage
group keeps its own counts from its own boundary. The row totals (`git.sinceReviewCount`,
`git.sinceReviewFiles`, `score`, and the oldest-change age) count only changes after the newest
usable review's boundary. A file an older group still owns is included in those totals only when
it changed after that boundary. The queue is still `drift` when any coverage group has changed
files: that older change is unreviewed, because the newest review did not cover the file. Source absent from coverage but added or changed after the newest review
boundary is queued as `new-source`; older uncovered files stay listed without being treated as new. `hasTrackedSource` describes the full tracked tree and
`hasCoveredSource` describes reviewed groups. Exemptions are decided before the queue and suppress
prompts. A record with no usable target is **unusable** with a reason, never evidence of no
review happened. A record whose coverage genuinely cannot be reconstructed may carry
`coverage-waiver: <reason>`; a resolvable target cannot be hidden by a waiver. Generated files
(`*.Designer.cs`, EF `*ModelSnapshot.cs`) never count as source.

**History reset.** When a repository's history was replaced by a root whose subject is
`Initial OSS release`, dated on or after the review, every reviewed tip leaves HEAD's
ancestry. That is distinct from a rebase-merge `tip-not-on-head`. The review is **not**
carried to the new root (an empty-tree credit would certify files the panel never saw) and
is **not** dropped either (that hid four fixatdl-wpf reviews and the 46 files that changed
between their remediated state and the public release). The run stays usable with
`historyReset: <root sha> (<date>)`; its boundary is the reviewed tip in the replaced
history, which is still in the object store, and its drift is the **tree diff** from that boundary to HEAD. A squashed
history has one commit, so a reset group scores changed files, not commits. Files the
replaced history never had are uncovered. Only when the old commit is gone from the object
store does the run fall back to `tip-not-in-repo`.

**Coverage follows the review's diff, not its declared scope.** A run covers the files its
range *changed*; a repository-scoped review of a 53-commit range credits only that range's
files. So uncovered source in a repository that has a usable review routinely includes code
that has been looked at, vendored code and generated output. It is reported and not scored:
reviews in this estate are targeted at new work, and a repository with no commits since its
last review has no changed-file workload however large its uncovered set.

**No usable review is ranked first.** A repository with source and no usable review at all
(`queue: no-usable-review`) outranks drift and is scored by its distinct uncovered source file
count. Scoring it zero sank new work beside the vendored forks.
The two are separated by the `exempt` list in `estate.json`, never by the score: an exempt
repository (`queue: exempt`) is reported with its reason and never queued. A repository with
unusable records but no usable one is still queued - repairing the record may be cheaper than
the review, and the digest lists the records beside the prompt.

## Output

`collect.ps1` writes one JSON row per repository. `repo` is the canonical basename from
`origin`, not the local directory name. The three live homes carry explicit roles:
`<repo> (live home)` for the skills and Claude config checkouts, and
`<repo> (live home; notes backing checkout)` for the shared docs checkout. This prevents a live home from being
confused with a similarly named source repository. Each row contains the primary review
(`vault`), change counts since the newest review boundary (`git.sinceReviewCount`, `git.sinceReviewFiles`),
oldest-change age (`git.daysSinceReview`), `subsystemPaths`, `scopeValidation`,
`hasTrackedSource` (source in the full tracked tree), `hasCoveredSource`, and
`reviewCoverage` (one group per usable run with its boundary, changed files, source flag,
commit ids, remediation files, staleness and `historyReset`), plus `unusable`, `uncovered`,
`queue` (`no-usable-review`, `new-source`, `drift`, `open-review`, `exempt`, `collector-error` or `none`),
`exempt`, `exemptReason`, `firstCommitDate`, `newSource`, `oldestUnreviewedChange`,
`openReviewCount`, `oldestOpenReviewAgeDays`, `remediationFiles`, and `score` (distinct
changed-file workload).

`write-report.ps1` writes one Markdown file. It opens with the column key, then a table that
ranks `no-usable-review`, then `new-source`, then drift by distinct changed-file workload and
oldest change age, both measured from the newest review boundary. The key is the display
contract for those columns. It includes a per-group
`/adversarial-review` prompt for each changed scope, a whole-repository prompt for
`no-usable-review`, a narrow prompt for queued `newSource`, unqueued uncovered source for
context, own remediation files, open review age, and unusable record reasons. Exempt rows have
no prompts; collector failures are flagged per repository.

Workload is distinct changed files since the newest review plus queued new source, or source files for a repository with
no usable review. Staleness is the age of the oldest of those changes. Open review records are
shown separately and aged from their review date. An exempt repository with a usable review still
shows that review; its workload stays zero. The ranking is a work queue, not a risk verdict.
`review-sweep` consumes the queue fields and per-group changed paths. `state-of-play`
cadence does not: it is the age of `vault.date`, and a non-empty queue does not make a
repository cadence-overdue. `state-of-play` drift, only when review is on, does consume
the queue.

Regression: `test/verify-digest.ps1`, `test/verify-skillmd.ps1`.
