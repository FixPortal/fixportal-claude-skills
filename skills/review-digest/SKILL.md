---
name: review-digest
description: Use when the user runs /review-digest or wants an intelligence report mined from PAST adversarial-review / reviewer-findings work across a folder of repos — coverage ledger (who's reviewed, latest batch, when fixed, fixer + panel models), cross-repo recurring-theme digest, deferred-findings backlog, coverage gaps, forward-looking risk ranking, and a hand-off scope report listing commits since the last review per repo with a paste-ready adversarial-review prompt for another agent. Triggers - "review digest", "what's been reviewed", "review coverage across the repos", "recurring review findings", "what needs reviewing next", "what do the review batches tell us". READ-ONLY harvester - it does NOT run reviews (that's adversarial-review / review-sweep) and never edits CLAUDE.md or scaffolds.
---

# Review Digest

## Overview

Mine **past** review work — git remediation commits + vault adversarial-review
reports — across the repos under a folder into one dated markdown report. This
skill reads what `adversarial-review` / `review-sweep` already produced; it never
runs a review and never branches or commits to the scanned repos.

## Invocation

`/review-digest [path]`
- No arg -> scan all git repos directly under the current directory.
- `path` arg -> scan that folder instead.
- A single repo name/path -> digest just that one repo.

## The spine

1. **Collect** — run `collect.ps1` to produce `digest-data.json` (deterministic).
2. **Classify** — match each finding against `themes.json`; append new themes.
3. **Join** — bucket each repo (git n vault / git - vault / vault - git / neither).
4. **Rank** — forward-looking risk score per repo (what is UNREVIEWED now).
5. **Delta** — diff against the most recent prior report in the Review Ledger folder.
6. **Write** — the dated digest report; **write back** themes.json.
7. **Hand-off** — write the sibling `<today>-handoff.md` scope brief for another agent.

## 1. Collect

Run once:
`pwsh -NoProfile -File ~/.claude/skills/review-digest/collect.ps1 -Path <path>`
(defaults `-OutFile` to `%TEMP%\review-digest-data.json`). It exits non-zero on a
bad path or a folder with no git repos — STOP and report if so. Read the JSON;
each repo carries `git` (reviewCommits — each entry has `{ sha, date, subject,
fixerModel }`, lastReviewDate, batchMarkers
— the raw review-batch identifier strings lifted from commit subjects, e.g.
`reviewer-findings batch 1`, `batch 14`, `B5`),
`vault` (exists, reviewers = panel models, judge, date, reviewType, tally = found
C/H/M/L, `reviewTarget` = the report's `target:` field, `isDocumentReview` = true when that
target is a document not a code tree), `hasGraphify` (a `graphify-out/` dir is present in the
repo), `hasTrackedSource` (the repo tracks at least one source file — false for a docs/spec/CV
repo), and `outsideScanPath`.

**`isDocumentReview` — a document review is NOT code coverage.** When true (a report whose
`target:` is a document, e.g. `target: some-cv.html` — a reviewed CV/document), the review confers
zero coverage on any code. Render such a row as reviewed-a-document, never as a reviewed (or
unreviewed) code repo, and never let it enter a bucket or the rank. The script warns these
separately from genuine unresolved rows.

**`hasTrackedSource` — voids the never-reviewed floor.** A never-reviewed repo with
`hasTrackedSource = false` has no code to review (a docs/spec repo, a playbook repo, a CV repo).
It must NOT get the `100 + commits` floor (see §4) — that floated four such repos above
genuinely-unreviewed code across three prior digests. Report it as "not code-reviewable", not as
a review priority.

**Vault-folder resolution.** A vault folder name is NOT proof of a repo — it may name a
**subsystem** of one. Each vault-only folder is resolved to real code in priority order:
(1) its report's `file:///` links (walked up to the enclosing `.git`); (2) its `scope: <sha>..HEAD`
sha, tested with `git cat-file -e` against every in-path and `-RepoRoots` repo — the falsifiable
check that survives a prefix rename; (3) a normalised name search, exact then **suffix then
substring** (so a de-hyphenated variant matches AND a prefix-renamed repo resolves).
A vault folder that resolves to a repo **already scanned in-path** is a stale pre-rename duplicate
and is dropped (its own newer in-path row already covers it). Resulting fields:
- `resolvedPath` — the git repo whose tree the review actually covered. The git side
  (`sinceReview`, boundary, staleness) is computed against THIS path, so remediation on an
  `outsideScanPath` row is detectable rather than structurally invisible.
- `isSubsystem` / `subsystemPath` — true when the reviewed code is a sub-path of the host repo
  (a vault folder whose review covered `host-repo` + `path\to\subsystem`). Every git query for
  such a row is **pathspec-scoped to `subsystemPath`**, so its counts are the subsystem's, not the
  host's. When describing one, name the HOST repo and the sub-path — never the vault folder alone.
  A mere name variance (a de-hyphenated folder name) is not a subsystem: same tree, no sub-path.
- `unresolved` — true when nothing could be placed on disk. The script `Write-Warning`s these.
  **Never report an unresolved row's tally as outstanding** (see Common mistakes).

`git` also carries the **forward-looking scope fields** that drive the risk rank
and the hand-off report:
- `boundarySha` — sha of the last point a genuine ADVERSARIAL review saw the tree.
  Null when the repo was never reviewed.
- `boundarySource` — how the boundary was chosen: `vault-date` (last commit on/before
  the vault adversarial-review date — the tree a panel actually reviewed; preferred),
  `vault-predates-history` (the vault review is older than the repo's earliest commit,
  e.g. an OSS re-init squash — boundary anchored at the root commit, so the WHOLE current
  tree is adversarially unreviewed; flag it as a full-repo sweep), `git-marker` (no vault
  report — fell back to the newest non-web-quality reviewer-findings commit), `none`
  (never reviewed), `outside-scan-path`, or `unresolved-vault-folder` (a vault folder that
  could not be placed on disk — review state UNKNOWN, see `neverReviewed` below). Web-quality
  sweeps (react-doctor / optimise-web / a11y `reviewer-findings-batch1` commits) are
  deliberately excluded from boundary candidacy — they are NOT adversarial reviews and
  previously faked `sinceReview=0`.
- `vaultPredatesHistory` — true for the OSS-re-init case above.
- `neverReviewed` — true when there is no `boundarySha`. **One deliberate exception:** an
  `unresolved` row has a null `boundarySha` but `neverReviewed = false`, because a review
  demonstrably happened (`vault.exists`) — we just cannot place the code it covered. Its state
  is UNKNOWN, not "never". Flagging it `true` would assert a falsehood and score it
  `100 + commits`, floating an unknown to the top of the rank. Unresolved rows are excluded
  from ranking entirely instead.
- `sinceReview` — commits **since the last review** (`boundarySha..HEAD`), each
  `{ sha, date, subject }`. Empty for a never-reviewed repo (history is not
  dumped) and for a repo whose last commit *was* the review.
- `sinceReviewCount` — count of `sinceReview`; for a never-reviewed repo this is
  instead the **full-history** commit count (full-audit scope).
- `sinceReviewFiles` / `sinceReviewIns` / `sinceReviewDel` — `git diff
  --shortstat boundarySha..HEAD` (files changed, insertions, deletions).
- `daysSinceReview` — whole days between `lastReviewDate` and today; null if
  never reviewed.

## 2. Classify against themes.json

Read `themes.json` (it lives beside this skill at
`~/.claude/skills/review-digest/themes.json`; it ships **empty** — `{}` — and this skill
populates it per-user over successive runs). For each repo's review commits + vault report
findings, match the described bug-classes against theme `aliases` (case-insensitive,
substring). Record which themes each repo exhibits. For a genuinely-new recurring
class not covered, ADD a new theme entry (`aliases`, a suggested `home`,
`seen: [repo]`). Merge `seen` repos by set-union: append any repos not already
listed to the existing `seen` array, deduplicate, order does not matter.

## 3. Join (the four buckets)

Classify each repo by what evidence was found — **git** = remediation commits in
the repo, **vault** = a review report in the vault:

- **git n vault** — found and fixed; both model sides known.
- **git - vault** — fixed, no vault report -> flag.
- **vault - git** — reviewed, no remediation commits here. If `outsideScanPath`,
  note "reviewed, lives outside <path>" (NOT a gap). Else: unremediated -> flag.
- **neither** — no git fingerprint AND no vault report -> **coverage gap**.

## 4. Rank (forward-looking risk)

Score each in-path repo by **what is unreviewed now** — NOT by historical
findings. A repo that surfaced many Highs but was fully remediated is low risk;
a repo with 30 commits and no review since is high risk. The vault tally is
shown for context but **does not feed the score**.

Per repo (skip `outsideScanPath` repos — reviewed elsewhere; skip `isDocumentReview` rows —
not code):

```
score =
  (neverReviewed && !hasTrackedSource) ? VOID          # no code to review — not a priority
  : neverReviewed ? (100 + sinceReviewCount)            # never reviewed floats to the top
  : sinceReviewCount * (1 + daysSinceReview / 30)       # unreviewed work, aged by staleness
  + deferredBacklogCount * 5                            # still-open deferred items
```

**The `hasTrackedSource` guard is not optional.** A never-reviewed repo with no tracked source
(`git ls-files` for source extensions is empty — docs/spec/playbook/CV repos) is **not
code-reviewable**: void its score, list it separately as "not code-reviewable (0 tracked source)",
and never let the `100 + commits` floor rank it. Missing this floated four such docs/spec/CV repos
into the top-10 across three prior digests. Also treat a `git-marker` boundary with an **empty
`batchMarkers`** array as effectively-never-reviewed (the marker matched prose like a playbook
doc, not a real review) — same treatment.

`deferredBacklogCount` = the repo's harvested "out of scope / future batch" items
(same source as the backlog section). Round to a whole number. Rank descending.
A reviewed repo with `sinceReviewCount = 0` scores ~0 → "nothing new" tier.

**Render the component values next to the score** (commits-since, days-stale,
deferred-count, never-reviewed flag) so the rank is auditable, not a black box.

## 5. Delta

Look in `<vault>\Claude\Review Ledger\` for the newest prior
`YYYY-MM-DD.md`. If one exists, compute what changed since: new batches, new
themes, newly-closed deferred items, newly-reviewed repos, new gaps. First run ->
omit the delta header.

## 6. Write the report

Write `<vault>\Claude\Review Ledger\<today>.md` (today =
`Get-Date -Format yyyy-MM-dd`). Sections, in order:

1. **Since <last date>** (omit on first run).
2. **Review-priority** — repos ranked worst-first by the §4 risk score, with the
   component columns (score | commits-since | days-stale | deferred | never-reviewed?).
   Link to the hand-off file (§7) for the per-repo scope and agent prompt.
3. **Coverage ledger** — repo | reviewed? | latest batch (raw marker) | fixed date | fixer model | panel models | join bucket.
4. **Severity & maturity** — found C/H/M/L (vault tally) vs batches landed (git); note "Highs drying up" where a repo has many batches.
5. **Recurring themes** — per theme: name | count | repos seen | severity skew | prevention-home.
6. **Deferred-findings backlog** — per repo, harvested "out of scope / future batch" items with source sha.
7. **Coverage gaps** — neither-bucket repos; plus a sub-list of `outsideScanPath` repos.
8. **Prevention candidates** — recurring theme -> suggested home. **PROPOSE-ONLY.**

Then write `themes.json` back (same path:
`~/.claude/skills/review-digest/themes.json`) with merged `seen` +
any new themes.

## 7. Hand-off scope report

Write a **sibling** file `<vault>\Claude\Review Ledger\<today>-handoff.md`.
This is the file you (or the user) hand to **another agent** that holds the
`adversarial-review` skill — it tells that agent exactly what to review and over
what scope, so it spends its tokens reviewing, not rediscovering scope.

Header: generated date, scanned path, and a one-line "hand this file to an agent
with the adversarial-review skill" note.

Then one block per in-path repo, **ordered by the §4 risk rank, worst first**.
Skip a repo whose `sinceReviewCount = 0` and is already reviewed — list those at
the foot under **Nothing new since review** (no prompt). For each ranked repo:

- **Heading** — `repo` — rank #, risk score, `never reviewed` flag if set.
- **Last review** — `lastReviewDate` · latest batch marker · panel models · `daysSinceReview`d stale.
- **Scope** — `boundarySha..HEAD` — `sinceReviewCount` commits, `sinceReviewFiles` files, +`sinceReviewIns`/−`sinceReviewDel`. For a never-reviewed repo say "full repo — never reviewed (`sinceReviewCount` commits total)".
- **Commits since the last review** — the `sinceReview` list as `sha7 — date — subject`, capped at ~40 with a "+N more" line.
- **Recurring weak spots** — the themes whose `seen` array (in `themes.json`) includes this repo. Tells the reviewer where this repo has bled before.
- **Agent prompt** — a fenced, paste-ready block, e.g.:

````
```
Run /adversarial-review on <repoPath>.
Scope: the diff <boundarySha>..HEAD — <N> commits since the last review
  (<batch marker>, <lastReviewDate>).
graphify-out/ present: <hasGraphify>. If yes, run /graphify first and query it
  for the subsystems these commits touch before reviewing.
Recurring weak spots in this repo: <themes>. Probe these first.
```
````

For a **never-reviewed** repo the scope line becomes the whole repo (HEAD) with a
"never reviewed — full audit" note instead of a `boundarySha..HEAD` range.

The hand-off report is **propose / READ-ONLY** like the digest: it names what an
agent *should* review; it runs no review and touches no scanned repo.

## Rendering rules for partial vault data

`collect.ps1` returns `vault.exists=true` even for older PROSE-format `_index.md`
files that have no YAML frontmatter — in that case `reviewers`/`judge`/`date`/`tally`
come back null. Render these honestly:
- Empty `reviewers` with `exists=true` -> panel-models cell = "unknown (prose-format report)", NOT blank.
- Null or partial `tally` -> severity cell = "not available" (or show only the severities that parsed), NEVER "0".
- A blank panel-models cell is reserved for `vault.exists=false` only.

## Hard boundaries

- READ-ONLY on the scanned repos — never branch, commit, or edit their code.
- NEVER auto-edit CLAUDE.md or scaffolds. The prevention candidates are a proposal you action by hand.
- The ONLY file this skill mutates as state is its own `themes.json`. The two
  vault files (`<today>.md` digest, `<today>-handoff.md` scope brief) are outputs.
- The hand-off report is **propose-only**: it tells another agent what to review;
  it never runs `adversarial-review` itself.
- Do NOT run a review — if the user wants one, that's `adversarial-review` /
  `review-sweep`.

## Common mistakes

- Treating an empty panel-models column as "no panel" when the vault folder is
  absent — it means *unknown*; banner-warn instead.
- Treating a null tally as zero findings — render "not available".
- Counting an `outsideScanPath` repo as a coverage gap — it was reviewed elsewhere.
- **Reporting an `unresolved` row's tally as outstanding.** A vault folder is NOT proof of a
  repo — it can name a **subsystem** of one. An unresolved row has an EMPTY GIT SIDE, so
  remediation is undetectable and the row can only ever read "unfixed and aging": it is
  **unfalsifiable**. Render it "unresolved — cannot assess", never as an outstanding finding
  count, and never rank it. Not hypothetical: a subsystem folder mistaken for a repo made three
  consecutive digests call its long-since-fixed Highs "the estate's oldest open wound" because no
  git side existed to contradict them.
- **Copying a prior report's prose forward as fact.** The delta step (§5) reads the last report
  to compute *what changed* — it is not a licence to restate its claims. Any claim carried
  forward is a claim you are re-asserting: re-derive it from this run's data or drop it. A wrong
  line in a ledger hardens with every repetition.
- **Treating "no git evidence" as "not fixed".** It usually means "not looked at" — an empty
  `reviewCommits`, an unresolved row, or a boundary that could not be anchored. Same shape as
  the `Glob` "No files found is never evidence of absence" rule in CLAUDE.md.
- Synthesising a global batch number across repos — numbering schemes differ
  (finding-IDs vs `batch N` vs audit `B<N>`); record the raw marker string.
- Auto-appending to CLAUDE.md — propose only.
- Treating a `git - vault` row with EMPTY batchMarkers as a real remediation —
  the marker regex also matches commits that merely mention "adversarial"/"review"
  in prose (e.g. skill-maintenance commits, a UAT "break-it" note). A git-only row
  with `batchMarkers = []` is likely a false positive; confirm before flagging it
  as fixed-but-unreported.
- Rendering a null `judge` (with `vault.exists=true`) as blank — like empty
  reviewers, render it "unknown", never blank.
- Letting the historical vault tally inflate the risk score — the rank is
  **forward-looking only** (unreviewed commits + staleness + deferred backlog).
  A heavily-reviewed, now-clean repo must NOT rank above an unreviewed one.
- Ranking an `outsideScanPath` repo — it lives outside the folder the user asked about, so it
  stays out of the risk rank and the hand-off prompts regardless of how it resolved. **But
  "not ranked" is not "not reported":** a *resolved* outside row now carries real git evidence,
  so §7 must state its remediation status honestly (fixed / still open / unknown). Only an
  `unresolved` row is genuinely unassessable. Do not silently drop a resolved outside row that
  has open findings — say it was reviewed elsewhere and where it stands.
- Reporting a never-reviewed repo's scope as "0 commits" — its `sinceReview`
  list is empty by design (history isn't dumped); use `sinceReviewCount` (the
  full-history count) and label it full-audit scope.
- Emitting an agent prompt for a repo with `sinceReviewCount = 0` — there is
  nothing new to review; list it under "Nothing new since review" instead.
