# Review policy contract

Read this reference for `.gitignore`, review-policy guard, risk tiering, or CodeRabbit spend controls.

## `.gitignore` — keep the review policy addable

Ignore Claude's local scratch with a file glob, not a directory exclusion. Git cannot
re-include a file whose parent directory is excluded:

```gitignore
.claude/*
!.claude/review-policy.json
```

Verify addability rather than trusting the text:

```text
git add --dry-run .claude/review-policy.json
```

Success means the policy is addable. If it fails as ignored, then run
`git check-ignore -v .claude/review-policy.json` to identify the rule. Do not use verbose
`check-ignore` as the pass/fail test: for an untracked but re-included file it can print the
matching `!` rule even though the file is addable.

Agent tooling writes per-machine state into the repo it is pointed at, and every such
directory belongs in `.gitignore` or it surfaces as untracked work in a status sweep:

```gitignore
.semgrep/
```

`semgrep-guardian` writes `.semgrep/guardian.yml` into whichever repo it scans. It is
local config, regenerated on demand, never project source. Ignore the whole directory —
`.semgrep/guardian.yml` alone leaves the cache behind.

## `review-policy-guard.yml` — the control plane must not delete itself

`git add --dry-run` above verifies addability **once, at scaffold time**. The invariant
has to hold on every later commit too, because one `.gitignore` line re-excluding
`.claude/` makes the policy file vanish and silently reverts the whole repo to NORMAL —
and the PR making that change would be the last one reviewed properly.

**Copy the shipped asset; do not retype it from this page.**

```bash
mkdir -p .github/workflows
cp ~/.agents/skills/scaffold-ci/assets/review-policy-guard.yml .github/workflows/
```

The path is `~/.agents/skills/`, the canonical cross-CLI home — not any single runtime's
skills root, which would resolve only under that runtime.

The shipped asset also rejects an empty/invalid policy, a missing `high` array, and
dropped review-control paths. Copy it rather than reviving the obsolete inline guard;
the rollout incident is recorded in [provenance.md](provenance.md).

Two details worth knowing rather than rediscovering:

- `--no-index` on `git check-ignore` is load-bearing. Without it `check-ignore` consults
  the index and never reports a **tracked** file as ignored, so that check passes
  unconditionally and guards nothing.
- The workflow runs on pushes to mainline and pull requests targeting mainline. Branch
  pushes are omitted because the pull-request event already covers them.

Where this workflow exists, `.gitignore` is NORMAL — do not also tier it HIGH.

### Workflow hygiene, asserted rather than reviewed

These assertions replaced `.github/workflows/**` in the policy's `high` list on 2026-08-19
(rationale under *`.claude/review-policy.json`* below). They live in a second shipped asset,
invoked by the guard:

```bash
cp ~/.agents/skills/scaffold-ci/assets/assert_workflow_hygiene.py .github/scripts/
```

The checker parses workflow structure rather than grepping text; the failed grep rollout
and covered edge cases are recorded in [provenance.md](provenance.md).

The union also folds in what seven repos had each added locally and separately — container and
`services:` images (an image runs code exactly as an action does, including the
`services: {db: postgres}` shorthand that names the image as a bare string), `workflow_run`
alongside `pull_request_target`, refs inside a local composite action's own `action.yml`, bare
`sha256:` digests as a valid pin, and a notice when a workflow omits `permissions:` entirely.

An **opt-in** stricter mode is available: set `TRUSTED_THIRD_PARTY_ACTIONS` to a
space-separated `owner/repo` list and every third-party action must be named there as well as
pinned. It is off unless set, deliberately — the pin check validates a ref's *shape*, so the
allowlist is the only thing that catches a *new* third-party dependency, but defaulting it on
with any short list fails most repos in this estate, and a gate that reddens on adoption gets
reverted rather than fixed.

What is asserted:

- **Third-party actions must be pinned to a full 40-character commit SHA** — a hard failure.
  A tag is mutable: whoever owns the action can change what `@v4` resolves to after review.
- **Unpinned `actions/*` is reported, not failed.** Scoping matters here, and the scope came
  from measuring rather than taste. Across 28 estate repos there were **319 unpinned refs and
  only one fully pinned repo**, so a gate on all owners would have reddened 27 repos on their
  next PR — while **third-party unpinned was exactly zero**, making the narrower gate free to
  enforce immediately. `actions/*` is GitHub's own namespace, where a mutable tag means
  trusting GitHub, which every workflow already does by running on their runners. Flip it to
  a failure once a pinning sweep lands.
- **No `pull_request_target`, no `workflow_run`, no `permissions: write-all`** — hard
  failures, at workflow *and* job scope for the token, and all three were at zero occurrences
  estate-wide when introduced. Both triggers run in the base repository's context with its
  secrets and a write-scoped token while able to reach untrusted head code.
- **The checker fails closed.** An unparsable workflow, a document whose top level is not a
  mapping, a `.github/workflows` that does not exist, and a run that scanned nothing all exit
  non-zero rather than printing a pass. A document carrying both `on:` and the YAML-1.1
  boolean `True:` key is refused outright: which one GitHub honours depends on the parser, so
  a trigger could hide in the one the checker does not read.

**The job name `Review policy intact` is load-bearing.** It is a *required* status check on
mainline in nearly every estate repo, which is also what makes deleting this workflow safe to
leave un-reviewed: the required check simply never reports and the PR cannot merge. Renaming
the job silently detaches that requirement — the rule waits for a context that no longer
arrives — so rename it only alongside a deliberate ruleset update everywhere.

## PR review policy — `.claude/review-policy.json` + `.coderabbit.yaml`

Public repositories receive GitHub's free deterministic CodeQL and Code Quality coverage;
Code Quality is a separate paid product on private/internal repositories. The two AI reviewers are
separate products and are not equally scarce — which is why the repo declares a risk policy
instead of every PR getting identical ceremony:

- **CodeRabbit** meters reviews **per developer identity across every repo**, rolling 7-day
  window, degrading from 30 reviews/7d with no bypass once degraded. A review spent on a
  zero-risk PR is taken from the pool available to the next migration.
- **Gitar** publishes no review quota — manual `Gitar review` always works. Only its
  *automatic* processing is rationed, against seat headroom per billing period.

So Gitar is the routine reviewer and CodeRabbit is reserved for HIGH-risk changes. The
`pr-review-gate.sh` / `pr-review-watch.sh` hooks enforce this; they read the tier from the
repo's committed policy file.

### `.claude/review-policy.json`

Copy `~/.agents/skills/scaffold-ci/assets/review-policy.example.json` and **edit it for this repo**. Rules:
any changed file matching `high` ⇒ HIGH; *every* changed file matching `low` ⇒ LOW;
anything else ⇒ NORMAL. Omitting the file is safe and means everything is NORMAL.

The asymmetry is deliberate — HIGH needs one match, LOW needs unanimity — because an
unrecognised path is unknown risk, and unknown risk is not low risk.

- **`high`** is broadly portable: migrations, `infra/**`, `**/*.bicep`,
  `.github/dependabot.yml`, auth paths and money-ledger writes. Still trim it to globs the
  repo actually has.
- **`.github/workflows/**` is deliberately NOT HIGH, and must not be re-added.** Workflow
  hygiene is asserted mechanically; the measured review-budget rationale is in
  [provenance.md](provenance.md). `.github/dependabot.yml` stays HIGH because its semantic
  policy cannot be checked by the workflow parser.
- **Dependency manifests do NOT belong in `high`** — not `package.json`,
  `package-lock.json`, `Directory.Packages.props`, `**/*.csproj`. **Reversed 2026-07-29**;
  this list used to include them on supply-chain grounds. Dependency PRs are now out of AI
  code review on both vendors, so classing a manifest HIGH demands a reviewer that can never
  run — coverage on paper, none in fact. Registry, SDK and analyzer config stays HIGH
  (`nuget.config`, `global.json`, `.npmrc`, `Directory.Build.props`): a bot does not edit
  those, and a change to one redirects where dependencies come from.
- **The review control plane must be HIGH in every repo** — `.claude/review-policy.json`
  itself and `.coderabbit.yaml`. Unlisted they classify as NORMAL, which means the
  single edit capable of disabling review across the repo would itself receive the
  lighter review.
- **So must the merge barrier** — `.github/workflows/ci.yml`, `.claude/ci-budget-approval.json`,
  `.github/workflows/review-policy-guard.yml`, `.github/workflows/review-tier.yml`,
  `.github/scripts/assert_gate_coverage.py`,
  `.github/scripts/assert_workflow_hygiene.py`.
  These are named paths, not a re-added broad workflow glob. Adjust `ci.yml` when
  the main workflow has another name; a HIGH path that does not exist protects nothing.
- **The canonical-asset manifest is HIGH wherever a repo has adopted the divergence gate** —
  `.github/canonical-assets.json` records which canonical-asset content the repo runs, and
  regenerating it is the act that makes a local divergence deliberate, so it is exactly the
  judgement HIGH exists for. It is deliberately NOT in the merge-barrier path list above:
  that list is mechanically derived and asserted estate-wide, and a required HIGH entry for
  a file a not-yet-adopted repo does not have would fail its guard for nothing. The rollout
  adds the entry per repo at adoption. The gate's verifier script needs no named entry here
  at all — it is a script a gated job runs, so the derived requirement below covers it (and
  the rollout adds it by name where a repo lists its scripts individually).
- **And so must any script the merge barrier RUNS — this one is derived, not listed.**
  A gated job executes the pull request's own checkout, so a checker it invokes decides
  what can merge exactly as the workflow does. The named-path list above cannot cover a
  checker one repository authored later: a hard-coded path would red every repository
  that does not have that file. So `assert_gate_coverage.py` derives the requirement
  instead — it reads the scripts each merge-blocking job actually invokes, and fails when
  one is not covered by a `high` glob. Nothing to maintain per repo: a gate script added
  years after scaffolding is covered the day it is wired in, and a repository that runs
  no repo-local scripts from a gated job is unaffected.

  Scoped deliberately to jobs the gate depends on, and to paths that exist on disk. A
  script in a non-gated job cannot neuter the barrier, and a path that does not resolve
  cannot be edited to neuter anything — asserting over either would be a false RED.

  **Scoped also to a closed set of directory roots** — `.github/scripts/`, `scripts/`,
  `build/`, `tools/` — so that path-shaped tool arguments and report files are not read as
  scripts. This is the one limit that is not self-announcing, so state it plainly: a gate
  script kept outside those roots (`ci/`, `eng/`, the repository root) is **not** derived
  and must still be listed in `high` by hand, or moved under one of the four. Derivation
  covers the estate's conventions, not every possible layout.

  **Rolling the asset into a repo whose gate scripts are unlisted reds its next PR, so
  land both edits together.** `CI Gate` is a required check, and a red required check on an
  unrelated pull request is what gets a control reverted rather than fixed. Add the script
  paths (or a covering glob) to `.claude/review-policy.json` in the SAME commit that syncs
  the asset. Measured 2026-09-09 across 26 repos with both a workflow and a policy, six
  needed that paired edit.

  The glob matcher mirrors `glob_to_regex` in the `pr-review-policy` hook exactly
  (`**/` → `(.*/)?`, `**` → `.*`, `*` → `[^/]*`, `?` → `[^/]`), so a repository covering
  its checkers with `scripts/**` satisfies the check just as it satisfies the hook.
  Mirrored rather than approximated: a checker stricter than the hook reds a repository
  the hook already tiers HIGH, and a false RED on a required check is how a working
  control gets deleted to make CI green.

  Why it exists: one estate repo added `scripts/assert-coverage-floor.ps1` as a merge
  gate on 2026-08-24 and it sat outside both the policy and the guard until an adversarial
  review found it on 2026-09-08 — the **third** recurrence of this class in that repository,
  three weeks after the same hole was closed for the two Python checkers. Enumeration had
  already failed twice there; derivation is the fix.
- **`.gitignore` is deliberately NOT HIGH, and must not be re-added.** The guard asserts
  its review-policy invariant directly without spending a review on every ignore edit.
  `~/.agents/skills/scaffold-ci/assets/review-policy.example.json` carries the same instruction —
  do not re-add `.gitignore` to `high` without first removing the guard.
- **`low` is the dangerous list and is repo-specific fact.** A path belongs there only if
  it is provably unreachable from **every deploy path in this repo** — which a generic hook
  cannot determine. Worked example: a `.dockerignore` is LOW in a repo whose frontend ships
  via npm + `static-web-apps-deploy` and whose CI only pulls a postgres service container,
  because nothing deployed is built from a Dockerfile. In a repo that ships a container
  image, the same file is NORMAL. **Never copy a `low` list between repos** without
  re-checking it against that repo's actual deploy jobs.
- Markdown is the usual `low` trap: `**/*.md` is genuinely low-risk in a service repo, but
  NOT in a repo that *publishes* its markdown (docs sites, content-driven frontends,
  skill/prompt repos where a `.md` file is the shipped artefact).

The file is committed, so classification rules get scrutinised once in a PR rather than
re-argued per PR by an agent. Agents must never self-classify or work around a tier.

### The cost envelope binds everywhere; the executable check does not

SKILL.md step 6 states one envelope for every repository — 30s per test, 10 minutes per
substantive required job, a 15 aggregate runner-minute target. The mechanical check behind
it is narrower: `audit-ci`'s cost test reads measured Actions job durations for a private
.NET lane, and on a public repository or a non-.NET stack it cannot run at all.

So on those repos the envelope is a target enforced by READING the workflow — job counts,
declared `timeout-minutes`, what the required lane contains — and an audit must report it
as unmeasured rather than clean. An envelope nothing measured is a coverage gap, never a
pass, and the difference matters most exactly where the check is absent: standard
GitHub-hosted runner minutes are free on public repositories, so the bill never flags an
over-budget lane there — the envelope is a runtime and capacity limit, not a cost one.
Larger runners are charged at every visibility.

### Rolling this contract out across the estate

Every rule above makes `.claude/review-policy.json` and the merge-barrier paths HIGH, and
HIGH requires CodeRabbit. Rolling the contract into twenty-odd repositories therefore
proposes twenty-odd HIGH PRs, against an allowance [provenance.md](provenance.md) records
degrading at 30 reviews in seven days on this account. The rollout as written cannot all
be reviewed under the budget it exists to protect — many of those PRs will be throttled
out — so what an asset-parity PR's coverage rests on is stated here rather than decided
quietly per repo.

**Mechanical-sync exception.** This is a coverage claim, not a tier change.
`review-tier.yml` still labels the PR HIGH — it labels any PR touching a HIGH path and
re-applies a removed label — and CodeRabbit still runs on it, so the label and the spend
are unchanged. What the exception governs is what the PR's review coverage rests on: a
byte comparison rather than a reviewer's verdict, so a throttled or absent CodeRabbit
review is not a coverage gap for the PR. It holds only when ALL of these hold — each
checkable from the diff:

1. Every changed path is a file this contract SHIPS (`.claude/review-policy.json`,
   `.coderabbit.yaml`, `.github/workflows/review-policy-guard.yml`,
   `.github/scripts/assert_gate_coverage.py`,
   `.github/scripts/assert_workflow_hygiene.py`, `scripts/summarize-stryker.ps1`).
2. Each is BYTE-IDENTICAL to the canonical file that
   `~/.agents/skills/scaffold-ci/scripts/canonical-assets.json` names for it (under
   `assets/` for all but the Stryker summariser, whose canonical is
   `templates/summarize-stryker.ps1`) — proved per file with
   `audit-ci/scripts/compare-canonical-file.ps1 -IgnoreLineEndings`, output pasted into
   the PR body.
3. The PR changes nothing else. One repo-specific glob edited alongside the copy voids
   the exception for the whole PR.

The reasoning: there is nothing here for a reviewer to find. The content was reviewed
once where it is authored, and this PR asserts only that a copy matches it — which a byte
comparison settles better than a language model can. CI, the guard and CodeRabbit still
run; the exception changes what the coverage rests on, not what runs.

The exception does NOT cover a repo-specific tier edit, a `low` list, or a change to a
canonical asset itself; those are the judgement HIGH exists for. A PR claiming the
exception without the comparison output is an ordinary HIGH PR whose coverage rests on
CodeRabbit's verdict, because the claim is the thing being trusted and an unevidenced one
is worth nothing.

### `.coderabbit.yaml`

Minimum house content — this is spend control, not review configuration:

```yaml
reviews:
  auto_review:
    # LABEL-TRIGGERED, not automatic. `enabled: false` WITH a `labels` list means a
    # positive label match still triggers a review — the label is the TRIGGER, not an
    # exclusion filter. The workflow applies `review-high`; `review-high-manual` is a
    # durable manual override for an otherwise NORMAL PR and is never removed.
    enabled: false
    labels: ["review-high", "review-high-manual"]
    drafts: false
    # Still load-bearing under label triggering: once a PR carries the label, every
    # later push re-reviews it. Default 5; CodeRabbit's own docs suggest 1-2.
    auto_pause_after_reviewed_commits: 2
    # Dependency PRs are out of AI code review on both vendors; Gitar's bot review is
    # switched off too. CodeRabbit already declines bot authors ("Review skipped: bot
    # user not eligible for review"), so this states the intent rather than leaving it
    # incidental to a vendor behaviour that can change.
    ignore_usernames:
      - "dependabot[bot]"
      - "renovate[bot]"
```

**`enabled: false` on its own is NOT the house standard, and is worse than leaving
auto-review on.** Without the `labels` list the `review-high` and `review-high-manual`
labels are inert, so no CodeRabbit check ever registers — and `pr-review-watch.sh` reads
a persistently absent check as "CodeRabbit is not installed in this repo" and stops gating
on it. A HIGH-tier PR then merges unreviewed while every signal looks clean. The two
settings go together or not at all.

- **Keep `auto_pause_after_reviewed_commits: 2`.** It is *not* dead config under label
  triggering: a labelled PR re-reviews on every subsequent push, and each one spends from
  the same pool.
- **`ignore_title_keywords` is a trap, not a saving.** `"chore:"` looks harmless and
  matches this estate's Dependabot titles verbatim (`chore: Bump X from 1.0 to 1.1`) —
  several repos were silently skipping every dependency PR through it without meaning to.
  Decide what gets skipped by **path** (`review-policy.json`) and by **author**
  (`ignore_usernames`), never by a title, which can lie about what a PR touches.
- **`ignore_usernames` was the opposite before 2026-07-29** — an explicit instruction NOT
  to ignore the dependency bots, on supply-chain grounds. Normalizing an older repo you
  will find that comment; replace it, or the file keeps arguing against its own settings.
- The matching Gitar setting is dashboard-only: Settings → Scope → **Allowed bots**, which
  must be **empty**.
- Keep `base_branches` in a repo whose mainline is not the GitHub default branch (a fork):
  it defaults to the default branch only, which in such a repo is never PR'd into.
