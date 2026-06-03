---
name: recap
description: Use when the user runs /recap, asks for a summary of recent work and what is next, or is resuming work after a break or context switch and needs to know where things stand — not for ending a session (use /close for that). Requires a git repository.
---

# Recap

## Overview

`recap` answers two questions — **what has been done** since the last recap and
**what is next** — as fast and as straightforwardly as asking "where did we get
up to?". It is one operation with no modes: the user asks, you give a concise
answer.

"What is next" is split by **actionability**, not lumped into one list:
**Actionable Now** (startable this session), **Deferred** (real but parked or
blocked), and **Information Only** (state and context, no action). The split is
the whole value of the digest — it keeps status noise out of the list the user
actually acts on.

Before gathering, it does a quick, **safe** housekeeping pass on the local repo
— pruning only branches and worktrees whose content is provably preserved
elsewhere, never touching uncommitted, unpushed, or stashed work (step 2).

Behind that answer is a defined, multi-source gathering process, so the answer
is consistent and well-sourced every time. A per-repo journal under
`~/.claude/recap/` backs the skill — it stores a marker so each recap analyses
only the delta since the last one, and keeps a readable history. The journal is
**internal plumbing**: the user never triggers, stages, reviews, or is nagged
about it. You maintain it silently. It lives under `~/.claude/`, never inside
the user's repository.

## Procedure

### 0. Re-anchor on the user's standing instructions

Before anything else, **re-read the global `~/.claude/CLAUDE.md` in full** with
the Read tool — do not rely on the copy already in context, which may be
summarised, truncated, or stale. Read it, take it in, and treat every rule it
carries as binding for the rest of the session: tool selection on Windows, shell
discipline, the review-worktree workflow and its numbering, rebase-merge
cleanup, the date/time and unit-testing conventions, configuration scope, the
PR-vs-push rules, and the Azure/CI and .NET-runtime trap docs it points at.
Where CLAUDE.md tells you to consult a notes file before a class of work, that
obligation is live for this session.

The recap is the moment work resumes, so it is the moment to reload these rules
and recommit to them. The recurring cost of skipping this is exactly what the
user is tired of: re-litigating issues that were already resolved and written
down. This step is **not optional** and is never skipped because "the rules are
already in context". Confirm it happened with the single line described in
step 6 — then move on; do **not** summarise or enumerate the file's contents in
the answer.

### 1. Verify git, compute the journal key

Run `git rev-parse --is-inside-work-tree`. If it fails or prints anything other
than `true`, answer exactly "Not a git repository — recap needs git history.
Nothing to recap." and stop.

Compute the key identifying this repo + branch:

- **rootSHA** — `git rev-list --max-parents=0 HEAD`. If more than one line is
  returned (multiple root commits), take the lexically-smallest. `<root12>` is
  its first 12 characters; keep the full SHA for the journal header.
- **branch** — `git rev-parse --abbrev-ref HEAD`. If this is `HEAD` (detached
  HEAD), use `detached-` followed by `git rev-parse --short HEAD`.
- **sanitised branch** — in the branch string, replace every character that is
  not a letter, digit, `.`, `_`, or `-` with `-`.
- **journal path** — `~/.claude/recap/<root12>__<sanitised-branch>.md` (two
  underscores between the parts).

### 2. Tidy the local repo — if safe

A quick, best-effort housekeeping pass before gathering. Every action here errs
on the side of caution: only ever remove things whose content is provably
preserved elsewhere. If any command fails (offline, permission, a repo guard),
skip it silently and continue — tidying **never** blocks the recap.

Three operations, in this order, and **nothing else**:

1. **`git fetch --prune`** — refresh remote-tracking refs so `gone`/merged state
   is current before you act on it. If it fails (e.g. offline), skip the branch
   pruning (operation 3 below) as well — a stale view of the remote is not safe
   to delete against — but still do `git worktree prune` and continue to the
   recap.
2. **`git worktree prune`** — drop admin entries for worktrees whose directory
   is already gone. Inherently safe: it never touches a live worktree's files.
3. **Delete local branches that are provably merged AND whose remote is gone.**
   For each local branch other than the one checked out, delete it only when
   **both** hold:
   - its upstream is marked `gone` (`git branch -vv` shows `: gone]`), **and**
   - its commits are on the mainline — confirm the **rebase-merge fingerprint**
     (same commit *titles* on `main`/default branch as on the branch, different
     SHAs) or that `git branch --merged <default-branch>` lists it.

   Both ⇒ `git branch -D <branch>` (rebase-merge gives new SHAs, so `-d` refuses;
   `-D` is the sanctioned post-merge cleanup). Report what you pruned in one line
   of the digest `<details>` — deletions are never silent.

**Never, under any reading of "tidy":**

- Delete a branch that has unpushed commits (`ahead`), no upstream at all, or is
  not merged — *even if its remote is `gone`*. A `gone` upstream alone does
  **not** prove a merge; the remote may have been deleted without merging. Hold
  the branch and, if relevant, surface it.
- `git stash drop`/`clear`, `git clean` untracked files, or discard/stash the
  dirty working tree. Each holds the only copy of real work.
- `git gc`, `git pull`, or otherwise advance `main`. Out of scope for a recap.

### 3. Find the marker

The marker is the commit a recap analyses forward from. Read the journal file.

- **It exists** — the marker is the second SHA of the `<from>..<to>` token on
  the file's first `## ` heading line (regex `\.\.([0-9a-f]{7,40})`).
- **It does not exist** — detect the default branch: try
  `git symbolic-ref --short refs/remotes/origin/HEAD`; if that fails, use
  whichever of `main` or `master` `git rev-parse --verify` resolves. The marker
  is `git merge-base <default-branch> HEAD`. If that resolves to `HEAD` (you are
  on the default branch itself), use `HEAD~20` instead — or the repo's first
  commit if the branch is shorter than 20 commits.
- **Orphaned marker** — if the stored marker SHA is not in history
  (`git cat-file -e <sha>^{commit}` fails), treat the journal as absent and
  apply the no-journal rule above.

If the SessionStart hook has already pre-loaded the latest digest into your
context and HEAD has not moved since, the marker is known — no file read needed.

### 4. Gather work done

- `git log <marker>..HEAD --format='%h %s'` — one line per commit. Use this
  `--format`: plain `git log` prints full multi-paragraph bodies and can exceed
  read limits. Pull a single commit's body only when you need it.
- `git diff --stat <marker>..HEAD` — files and churn.
- `git status --short`, and `git diff --stat` for the shape of any uncommitted
  changes.

If there are no commits in `<marker>..HEAD` and no uncommitted changes,
**re-display the last journal entry's digest** — everything from its `## `
heading line down to (but not including) `<details>`, whatever forward sections
that entry happens to carry (older entries predate the three-bucket split and
may still show a single **Up next**; render them as-is) — prefaced with a
one-line note that nothing has moved, e.g. "No new work since last recap —
here's the last one:". Then stop; write nothing to the journal.
If the SessionStart hook has already loaded the latest digest into your
context, render that; otherwise read the journal file. If the journal is
genuinely empty (first-ever recap on a branch with no commits past the
default-branch marker), answer "No work to recap on this branch yet." and
stop.

The first-ever recap has no marker and spans the whole branch; it may cover many
commits. Summarise at the theme level, not commit by commit, within the bullet
caps.

### 5. Gather what's next

Consult every source; silently skip any that is absent — a missing source is
never an error.

- **`[code]`** — `TODO` / `FIXME` / `HACK` / `XXX` comments in files changed
  since the marker. If the changed set is large, scope to the actively-developed
  source, not every file. Skip vendor / third-party trees. Do **not** run the
  test suite.
- **`[doc]`** — opportunistically, if they exist at or near the repo root:
  `TODO.md`, `ROADMAP.md`, `NEXT.md`, any `PLAN*.md`, and the "unreleased"
  section of a `CHANGELOG`. Never required.
- **`[pr]`** — if the `gh` CLI is available and authenticated, the current
  branch's open pull request (`gh pr view --json title,body,url`). Skip silently
  if `gh` is absent, unauthenticated, or there is no PR.
- **`[memory]`** — relevant `project` and `feedback` memories already in your
  context. No file read needed.

**Then classify every candidate into one of three buckets.** This split is the
whole point of the digest — do it deliberately, item by item. The bucket is
about *actionability*, independent of which source the item came from:

- **Actionable Now** — work you could pick up **this session with nothing
  blocking it**: a concrete next step, an unblocked `TODO`/`FIXME`, review
  feedback to act on, the next phase of a plan, an open PR that needs *your*
  action (address comments, merge). If you could literally start it now, it
  goes here.
- **Deferred** — real, intended work that is **parked or blocked**: waiting on
  someone else (handed off to another agent, awaiting the user's review/red-pen),
  gated behind another task, scheduled for a later phase, or explicitly
  postponed. Not noise — just not startable yet.
- **Information Only** — state and context that carries **no action**: a
  clean/in-sync working tree, no open PR, a decision already recorded as closed
  ("don't reopen"), background facts about where things stand. This is the
  bucket that keeps status out of the action list.

When torn between Actionable Now and Deferred, ask "could I literally start this
right now?" — if no, it is **Deferred**. A blocked item is never Actionable Now;
a pure status fact is never an action.

### 6. Answer the user

Give the digest: the heading line (format below), then **Done since last
recap**, then the three forward-looking sections — **Actionable Now**,
**Deferred**, **Information Only** — nothing from inside `<details>`. This is
what the user asked for: lead with it, keep it tight, and do not narrate the
steps you took.

- **Actionable Now** is a **numbered** list in recommended order: put whatever
  unblocks or is a prerequisite for other items first, then order by leverage.
  This is the section the user acts on — it leads the forward-looking part.
- **Deferred** and **Information Only** are bulleted (`-`).
- **Render all three headings every time.** If a bucket is empty, show it with a
  single `- none` bullet rather than dropping the heading — the `- none`
  placeholder uses a dash even under the otherwise-numbered Actionable Now.
- Keep every forward-looking entry tagged with its source: `[code] [doc] [pr]
  [memory]`. An entry drawing on more than one source may carry more than one
  tag (e.g. `[pr] [doc]`).
- Cap each section at 7 entries; push overflow into `<details>`. Keep
  **Information Only** the tersest — it is the section most likely to become
  noise.

End the digest with a single confirmation line that you have re-read and will
follow the global instructions — e.g. `✓ Re-read global CLAUDE.md — standing
house rules in force for this session.` One line only; do not list the rules.
This line is the user's proof that step 0 happened.

### 7. Update the journal — silently

Plumbing. Do it quietly — no announcement, no "I have saved this", no staleness
remark, no commit.

- **If `<marker>..HEAD` contains new commits** — prepend a new entry (format
  below) to the journal file, creating the `~/.claude/recap/` directory and the
  file if they do not exist. A new file begins with a
  `# Recap Journal — <repo name>` title (`<repo name>` is the basename of
  `git rev-parse --show-toplevel`), then on the next line the comment
  `<!-- key: rootSHA=<full rootSHA> branch=<raw branch> -->`, then a blank line,
  then the entry.
- **If it contains no new commits** — only uncommitted changes, or nothing —
  write nothing. The marker advances only to a real commit, never to volatile
  working-tree state. Your step-6 answer still describes any uncommitted work;
  it is simply not journalled until committed.

## Entry format

```text
## YYYY-MM-DD HH:MM — <branch> — <fromSHA>..<toSHA>

**Done since last recap**
- 3–7 concise bullets

**Actionable Now**
1. numbered, recommended order; each tagged [code] [doc] [pr] [memory]

**Deferred**
- parked or blocked work; each tagged [code] [doc] [pr] [memory]

**Information Only**
- state/context, no action; each tagged [code] [doc] [pr] [memory]

<details><summary>Detail</summary>

Commit list, file-change stats, caveats — the fuller record.

</details>
```

- Entries are newest-first — prepend each new entry directly below the title and
  key comment.
- The `## ` heading line is the parse anchor; the `<fromSHA>..<toSHA>` token is
  found by regex, the separators around it are cosmetic. `<toSHA>` is `HEAD` at
  recap time and becomes the next run's marker.
- Timestamp the heading with local system time.
- Cap each digest section at 7 bullets; everything else goes inside `<details>`.
- Always write all three forward sections (**Actionable Now**, **Deferred**,
  **Information Only**); an empty bucket gets a single `- none` bullet, never a
  dropped heading. Actionable Now is numbered; the other two are bulleted.
- When an entry is written and uncommitted work also exists, flag it
  `(uncommitted)` in the digest and note the files in `<details>`.

## Common mistakes

- **Skipping the re-anchor (step 0).** Re-reading the global `CLAUDE.md` is the
  first thing a recap does and the most likely thing to get rationalised away
  ("it's already in context", "I know the rules"). Don't — read the file fresh
  every time and end the digest with the one-line confirmation. The whole point
  is to stop re-litigating settled, already-logged decisions.
- **Over-eager tidying.** The step-2 tidy deletes only branches that are *both*
  provably merged (rebase-merge fingerprint / `git branch --merged`) *and*
  remote-gone, plus already-dead worktrees. A `gone` upstream alone is **not**
  proof of a merge. Never delete unpushed, unmerged, or upstream-less branches,
  never drop a stash, never `git clean`, never discard the working tree, never
  `git gc`/`pull`. Tidy failures (offline, guards) are skipped, never fatal.
- **Adding ceremony.** The journal is plumbing — do not announce writing it, do
  not call it "saved for review", do not nag about staleness.
- **Journalling uncommitted-only state.** An entry is written only for new
  commits. Uncommitted changes are described in the answer but never produce an
  entry on their own.
- **Running the test suite.** Too slow — use static code signals only.
- **Treating a missing source as an error.** No planning docs, no PR, no
  memories — each is skipped silently.
- **Writing into the user's repo.** The journal lives under `~/.claude/recap/`,
  never in the repository.
- **A wall of text.** Each section is capped at 7 bullets; detail belongs inside
  `<details>`. Keep **Information Only** the tersest.
- **Leaking status into Actionable Now.** A clean/in-sync tree, "no open PR", or
  a closed-and-don't-reopen decision is **Information Only**, never an action.
  Work that is blocked or handed off is **Deferred**, never Actionable Now. If
  you cannot literally start it this session, it does not belong in Actionable
  Now. Misfiling here is exactly the noise the split exists to remove.
- **Collapsing the split back to one list, or dropping empty buckets.** Always
  render all three forward headings; an empty one shows `- none`. Do not revert
  to a single "Up next".
- **Bare "nothing new" answer.** When `<marker>..HEAD` is empty, re-render the
  last entry's digest — the user is asking where things stand, not whether the
  marker has advanced.
