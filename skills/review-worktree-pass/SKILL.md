---
name: review-worktree-pass
description: Use when selecting or implementing remediation actions for code-review findings, adversarial-review findings, cross-vendor review follow-ups, AI-findings, CodeQL, or Sonar. Do not use for read-only review, review-digest, or audit requests.
---

# Code-review pass workflow

Code-review-driven fix passes (reviewer findings, adversarial-review remediation,
cross-vendor review follow-ups) **must run in a dedicated review worktree**, not
in the primary project checkout, with one numbered branch per pass.

## Where to work

- Each review project has a single review worktree at
  `<project>\.claude\worktrees\reviewer-passes`. The `.claude` segment is
  literal **regardless of which agent** you are; this is a shared project
  location, not a per-runtime config directory, so there is no `.codex` or
  `.gemini` variant. **Read the project's own memory for its exact path and
  current lifecycle state**, then verify the path with `git worktree list`
  before using or recreating it. Do not assume a historical project example is
  still live.
- When the user asks to select or implement remediation actions for review
  findings, use `git worktree list` to choose one path:
  - **If the review worktree already exists**, `cd` into it and run
    `git fetch --prune` as a discrete command, before any new branch choice, then
    resolve and verify the project mainline using the procedure below. What happens
    next depends on the branch it is on — read it with
    `git -C <review-worktree-path> rev-parse --abbrev-ref HEAD`:
    - **An in-flight pass** (the branch has commits not on the verified mainline,
      and its PR is open or unopened): continue on it. Do not start a new batch
      number; a pass is one branch.
    - **A closed, unmerged PR** — stop before batch selection. Do not treat it as
      an in-flight pass or silently abandon it; ask whether to resume the branch
      with a new PR or explicitly abandon the pass.
    - **A merged pass** — first inspect `gh pr view <branch> --repo <owner>/<repo> --json state --jq .state`.
      If it reports `MERGED`, the pass is merged. When the PR cannot be resolved, use
      `git cherry -v <mainline-ref> HEAD` only after confirming the remote branch is gone;
      no `+` rows means every branch patch is present on mainline. Rebase-merge rewrites
      SHAs, so `<mainline-ref>..HEAD` stays non-empty after a merge and cannot answer this.
      Matching titles are not patch evidence either. If any `+` remains, the pass is in
      flight; continue on it. If none remain, confirm the tree is clean (`git status --porcelain` empty;
      stop and ask if it is not — uncommitted work there is somebody's), then choose `<N>`
      by the *Branch numbering* rule below and switch to a fresh branch with
      `git -C <review-worktree-path> switch -c reviewer-findings-batch<N> <mainline-ref>`.
      Delete the old branch only under the *Teardown* checks.
    - **Any other state** — detached HEAD, a branch that is not
      `reviewer-findings-batch<N>`, or a dirty tree you did not create: stop and
      say so. A review pass must not start on top of a workspace whose state
      nobody has accounted for.
  - **If the review worktree is absent** after teardown, `cd` to the verified
    primary checkout (confirm it with `git worktree list`) and run
    `git fetch --prune` as a discrete command. Resolve and verify the project
    mainline from `origin/HEAD`, then select the next batch number and create the
    branch with
    `git worktree add -b reviewer-findings-batch<N> <review-worktree-path> <mainline-ref>`.
    This creates the dedicated worktree; it does not branch the primary
    checkout.

After fetching, resolve `<mainline-ref>` with
`git symbolic-ref --quiet --short refs/remotes/origin/HEAD`. If that symbolic
ref is absent, use `git ls-remote --symref origin HEAD` and accept only its
single advertised `refs/heads/<branch>` target as `origin/<branch>`. Verify the
result with `git rev-parse --verify --quiet "<mainline-ref>^{commit}"`; stop if
the remote HEAD is missing, ambiguous, or not present in the refreshed local
refs. Record that verified ref and use it throughout the pass.

**Why:** the primary checkout is where parallel feature work, dogfooding, and
manual exploration live. Letting a review pass land there overlaps with in-flight
work — stale local commits, untracked artefacts, the wrong branch checked out —
and makes merge cleanup unreliable.

## Branch numbering

Branches inside that worktree follow `reviewer-findings-batch<N>` (or the
project's established numbering). Increment monotonically — never reuse a number,
never start a new batch without merging or abandoning the prior one.

`<N>` is one more than the highest number ever used in this project, local or
remote — not one more than what happens to exist locally, which is how a number
gets reused after a teardown removed the branch:

```
git -C <repo> for-each-ref --format='%(refname:short)' 'refs/heads/reviewer-findings-batch*' 'refs/remotes/*/reviewer-findings-batch*'
git -C <repo> log --oneline <mainline-ref> --grep='batch [0-9]'
```

The history search is deliberately UNCAPPED. A `-20` limit reads only the most recent
commits, so with batch 17 sitting 21 commits back and both branch refs long deleted, the
highest number found would be 16 and the next pass would reuse 17 — which is exactly the
collision the monotonic rule exists to prevent.

**Neither of those two commands is sufficient, and on a rebase-merge repo both can be badly
wrong. Read the merged pull requests as well — that is the authority:**

```
$pullRequests = gh api --paginate 'repos/<owner>/<repo>/pulls?state=all&per_page=100' --jq '.[].head.ref'
if ($LASTEXITCODE -ne 0) { throw 'GitHub PR history lookup failed; do not choose a batch number' }
```

Why that is authoritative and the git pair is not: rebase-merge rewrites the commits, so a
branch name never reaches a subject unless someone typed it there by hand, and
`delete_branch_on_merge` removes the ref the moment the PR lands. The number then survives in
exactly one place — GitHub's pull-request record. Measured on a skills repository,
2026-09-09, all three against the same repo:

| source | highest found |
|---|---:|
| `git for-each-ref` over local + remote batch refs | **empty** |
| `git log --grep='batch [0-9]'` over all of `main` | **6** |
| merged pull-request head refs | **20** |

Take the highest number **any** of the three reveals and add one. Reading only the git pair
would have reused 7 on a repo standing at 20.

This has already cost a collision. A hand-off that took its number from `review-digest`'s
`batchMarkers` — commit subjects — sent a remediation pass in another repository to
`reviewer-findings-batch15` when 15 was already used by an earlier merged PR and the sequence
stood at 21.
`review-digest` stopped emitting batch numbers after that (2026-09-09, and the fields left its
output entirely in the 2026-09-12 rebuild): it is an offline collector, it cannot source the
authoritative number, and it declines to guess rather than hand one over. No other tool
supplies the number either. Do not fill that gap by inference — run the command above.

If all three come back empty in a project whose memory records earlier passes, trust the
memory: a merged and torn-down batch can leave nothing behind at all.

## Before you push

Run the repo's full local check suite **in this worktree** before the push that
opens or updates the PR — the *Build and test before pushing a PR* rule, whose
own rationale is written around exactly this workspace ("the whole point of a
worktree is to run exactly this check without disturbing the primary checkout").
For a TS/JS repo that is typecheck, lint, the full test run, and a build when an
SSR-rendered component was touched; elsewhere it is that repo's equivalent.

Push **once**, when the batch is finished. Every push re-spends review budget, so
fold review findings, lint fixes and nits into the same branch rather than
pushing per fix.

Once a batch's PR may have merged, never push follow-ups to that branch: with
auto-delete-on-merge the remote branch is already gone, and a later push silently
re-creates it as an orphan with no PR, so the commits never reach `main`. The
tell is `git push` printing `* [new branch]` for a branch you believed existed.
Start `reviewer-findings-batch<N+1>` instead — which the monotonic numbering rule
above already gives you.

## Teardown

The review worktree and its branch are **ephemeral** — they exist only while a
pass is in flight. Nothing should linger between passes: when a pass is done
(branch merged into the verified `<mainline-ref>`, the review artefact closed
per *Close the review artefact* below, repo clean, `origin` clean,
no pass running),
**remove both** the worktree and the `reviewer-findings-batch<N>` branch.
Recreate them from scratch (`git worktree add` + branch from the verified
`<mainline-ref>`) at
the start of the next review.

## Close the review artefact

Only after all findings are fixed, declined with reasoning, or explicitly deferred,
close the source run's `_index.md`: set `disposition: remediated` and add
`remediation-tip: <40-character mainline SHA>`. Flip an existing
`disposition: reviewed` line — and if the run predates the convention and has
no `disposition` line at all (a legacy record), add both lines. Never leave the
source record dispositionless after a merged pass.
Use the post-merge commit on the refreshed verified mainline, then run the review
producer's `validate-report.ps1 -Path <run-folder> -RepoPath <repo>`. Do not close
the artefact while any finding lacks a disposition; if closure is genuinely
deferred, record that decision in project memory so the source review's closure
state remains clear.

This step keeps the source review record accurate and makes the remediation
traceable. `state-of-play` uses review records for review dates and drift only;
it does not treat `open`, `reviewed`, or a missing legacy disposition as Git
work. Close the source record after the pass so later readers can distinguish a
remediated review from one that was only assessed. This machine closure
supersedes generated handoff prompts; historical ledger files remain immutable.

**Keep a rollback for that edit.** The run folder lives in the shared vault, which is
not version-controlled and which other agents read — so an edit that fails validation
is live, not staged, and there is nothing to revert to. Before touching `_index.md`,
copy it beside itself:

```powershell
Copy-Item -LiteralPath '<run-folder>\_index.md' -Destination '<run-folder>\_index.md.bak' -ErrorAction Stop
```

Then edit, then validate. If `validate-report.ps1` fails, restore from the copy before
doing anything else — do not attempt a second edit on top of a rejected one, which is
how a malformed frontmatter block ends up half-repaired. Delete the `.bak` only once
validation passes. Copying first also makes the failure recoverable by a person who is
not this session.

Stale-after-merge cleanup (pre-authorised post-merge tidy): before deleting the
branch, confirm it is genuinely merged using the rebase-merge fingerprint from
the *Pull request merge style* rule: **both** the remote branch is gone and the
local branch's commit titles match the rebased commits on the verified
mainline. An empty
`git diff <mainline-ref>..<branch>` is useful supplemental evidence, never a
substitute for either required check.

Because the branch is checked out in the worktree, first change the shell's
working directory to the verified primary checkout (or another safe directory
outside the review worktree). Then run `git worktree remove <path>`, which frees
the branch for `git branch -D reviewer-findings-batch<N>`. Do this as part of
finishing the pass — do not leave a parked worktree or merged branch behind.

**Say what you are about to remove, and get a yes.** "Pre-authorised" covers the
JUDGEMENT — that a branch matching the rebase-merge fingerprint may be deleted without
re-arguing the policy — not the ACT. `git worktree remove` and `git branch -D` are
irreversible for anything not already on the mainline, and a clean tree is not evidence
that the branch is unwanted: it is equally the state of a finished pass whose PR has not
merged yet. Immediately before removing, report the worktree path, the branch name, the
empty-range and remote-gone checks that were run, and wait for explicit confirmation.
Absent it, leave both in place and say so; a lingering worktree costs disk, a deleted
in-flight branch costs the pass.
