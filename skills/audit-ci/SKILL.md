---
name: audit-ci
description: Use when evaluating or comparing GitHub Actions CI/CD configuration across one or more repos — auditing for gaps, drift from the house standard, cross-repo inconsistency, or opportunities to add or remove workflow steps, and especially whether a Docker-building workflow should move to Blacksmith runners for layer-cache build speedups. Triggers — /audit-ci, "audit the CI", "review my CI/CD config", "is my CI up to house standard", "CI gaps", "should this move to Blacksmith", "compare CI across the repos". Read-only and advisory; hands remediation to scaffold-ci. NOT a scaffolder (that is scaffold-ci) and NOT a code review (adversarial-review).
---

# audit-ci

## Overview

Evaluate the GitHub Actions CI/CD of one repo — or sweep every repo under a
folder — against the house standard, and report **gaps, drift, cross-repo
inconsistency, and opportunities to add or subtract**. The headline lens: flag
Docker-building workflows that would benefit from **Blacksmith runners** (sticky-disk
layer caching), which the house rollout has not yet reached.

**Core principle: measure against `scaffold-ci`, do not improvise a "best
practice".** `scaffold-ci` is the single source of truth for the house standard —
the five artifacts, the current pinned action versions, concurrency policy, CodeQL
default-setup, dependabot shape, mutation.yml, and the CI-dashboard job-lane naming
contract. Read those values from `scaffold-ci` at audit time and compare; never
hardcode a pin or rule here, because both drift and this doc would lag.

**This skill is read-only and advisory.** It diffs config against the standard and
writes a report. It does **not** edit workflows, branch, or commit. Remediation is a
separate `scaffold-ci` pass (in the review worktree, per the code-review-pass
workflow). Sibling of `review-sweep` and `azure-cost-sweep`.

**Before reasoning about any GitHub Actions gotcha, read
`~/.claude/notes/deploy-and-ci-traps.md`** — concurrency-cancel semantics, CodeQL
default-setup scope, the Blacksmith `--provenance` / actionlint-label traps. The
audit's findings lean on those.

## The spine

1. **Discover** the in-scope repo(s).
2. **Inventory** each repo's CI/CD artifacts and their shape.
3. **Evaluate** each against the house standard (gaps + drift + non-house extras).
4. **Blacksmith lens** — score each Docker/heavy-compute job for a runner move.
5. **Report** — per-repo findings + (on a sweep) a cross-repo consistency matrix.

## 1. Discover

- **One repo:** the current repo, or a named path.
- **Sweep:** enumerate top-level dirs under the target folder, minus an exclusion
  list (exact leaf-name match). Keep only git repos
  (`git -C <dir> rev-parse --is-inside-work-tree`). A sweep is long — write the
  per-repo sequence to Tasks (`TaskCreate`) so it survives a compaction, and mark
  each `in_progress`/`completed` as you go.

For each repo, read the mainline branch
(`git symbolic-ref refs/remotes/origin/HEAD`) — findings about triggers and
ref-gating depend on it, and it is not always `main`. That command fails on a
clone whose remote HEAD is unset or differently named; fall back to
`git remote show origin` (its "HEAD branch" line) or
`gh api repos/{owner}/{repo} --jq .default_branch`, and if none resolve, mark
the trigger / ref-gating findings **unverifiable** rather than assuming `main`.

## 2. Inventory

Read, per repo (use `Read`/`Glob`/`Grep`, not shell `cat`/`find`):

- `.github/workflows/*.yml` **and** `*.yaml` — **enumerate both by literal path**
  (`<repo>\.github\workflows\*.yml` and `<repo>\.github\workflows\*.yaml`); a
  `**` glob silently skips the dotted `.github` dir, and a repo whose workflows use
  the `.yaml` extension is otherwise wrongly reported as having no CI.
- `.github/dependabot.yml`, `.github/actionlint.yaml`.
- Any `Dockerfile` / `*.Dockerfile` / `docker-compose*.yml` (repo builds images?).
  Filter IDE/tool-generated noise out of that glob — a
  `.idea/**/docker-compose*.generated*.yml` (Rider) is not a CI artifact.
- **Reusable / called workflows.** An **external** call
  (`uses: <org>/<repo>/.github/workflows/x.yml@ref`) delegates its runner and step
  config to the *called* repo — note the delegation, treat its internals as out of
  scope, don't grade a step you cannot see. A **same-repo** call
  (`uses: ./.github/workflows/x.yml`) is fully auditable here: its jobs, runners and
  steps live in this repo, so audit them like any other workflow.
- The repo's stack signals: a `.sln` / `*.csproj` (backend), `package.json` with
  `lint`/`test`/`build` scripts (frontend), test projects (mutation candidate).
- CodeQL state via the Actions API (`workflow` scope suffices, no
  `security_events` needed):
  `gh api --paginate repos/{owner}/{repo}/actions/workflows --jq '.workflows[] | {name,path,state}'`
  — an active `dynamic/github-code-scanning/codeql` workflow = default setup on.
  (`--paginate`: without it only the first page returns, so a repo with many
  workflows can hide the CodeQL entry and read as "off".)

## 3. Evaluate against the house standard

For each dimension, classify a finding as **gap** (missing), **drift** (present but
diverges from `scaffold-ci`), or **subtract** (non-house extra to remove). Read the
canonical value from `scaffold-ci` and compare.

| Dimension | What to check | Typical finding |
|---|---|---|
| **ci.yml present** | build + test + lint per stack | gap: no CI at all |
| **Action pins** | compare each `uses:` against `scaffold-ci`'s pin table (re-read it — pins drift and dependabot bumps them) | drift: stale `@v4` checkout, etc. |
| **Third-party SHA pins** | third-party actions pinned to full commit SHA, not a floating tag; and the SHA is current — cross-check the live upstream tag **of the action's own repo** (the `<owner>/<repo>` from its `uses:`, NOT the audited repo's `origin`), dereferencing an annotated tag to its commit (`git ls-remote https://github.com/<owner>/<repo> 'refs/tags/<tag>^{}'`, falling back to `refs/tags/<tag>` for a lightweight tag; a `git/ref/tags/<tag>` `.object.sha` is the tag object, not the commit), and do not assume `scaffold-ci`'s documented SHA is fresh | drift: `raven-actions/actionlint@v2` tag (semgrep hook flags it); drift: SHA under `# v2` that no longer matches the live `v2` tag |
| **First-party pin style** | first-party `actions/*` take the major tag, not a SHA (the inverse of third-party) — and consistently across the repo's own workflows | drift: `actions/checkout@<sha>` in one workflow, `@v7` in a sibling |
| **actionlint step** | first validation step of every job, right after checkout | gap: missing |
| **Concurrency** | deploy repo → flat `cancel-in-progress: false`; no-deploy → `${{ github.ref != 'refs/heads/main' }}` | drift: flat `false` on a library repo; unconditional `true` |
| **Triggers** | `push ['**']` + tags `v*` + `pull_request` to mainline + bare `workflow_dispatch` | drift: `push: [main]` only |
| **Dead dispatch input** | `workflow_dispatch` `environment` choice only where a deploy job reads it | subtract: dead dropdown no step consumes |
| **dependabot.yml** | present; ecosystems match the repo (nuget/npm/github-actions); npm `directory` points at the real `package.json` folder | gap / drift: missing npm ecosystem, wrong directory |
| **mutation.yml** | present + separate workflow for any repo with a .NET test project; `continue-on-error`, `break: 0`, push-to-main + dispatch | gap: missing on a .NET repo; drift: run as a `ci.yml` gate |
| **CodeQL** | default setup enabled (settings toggle, not a committed file) | gap: off; subtract: a committed `codeql.yml` advanced-setup double-scan |
| **Job-lane naming** | deploy jobs contain `deploy`; publish jobs a package term; one job = one lane | drift: a `build-and-push` job that mis-lanes or vanishes from the dashboard |
| **Non-house extras** | `dependency-review-action`, redundant `tsc --noEmit`, coverage gating, Node in the backend job | subtract: per `scaffold-ci` "Not house standard" |

**Do not grade what the house standard does not define.** `scaffold-ci` documents
Stryker.NET mutation, not a JS/TS mutation sibling; a reusable-workflow delegation is
not one of its five artifacts. When a repo adds something the standard is silent on
(e.g. a `mutation-web.yml` StrykerJS run), **note it as an undocumented addition** —
do not score it gap/drift/subtract against a standard that never mentioned it.

On a **sweep**, additionally flag **cross-repo inconsistency**: the same knob set
differently across repos (different checkout pins, some repos on Blacksmith and some
not, one repo cancels concurrency and its sibling does not). Inconsistency is itself a
finding even where each individual value is defensible.

## 4. Blacksmith lens (the headline)

Two distinct moves — score each job for both.

### (a) Docker layer-cache move — the one to hunt for

A job is a **strong candidate** when ALL hold:
- the repo builds a Docker image (has a `Dockerfile`, or a workflow step uses
  `docker/build-push-action`), AND
- that job runs on `ubuntu-latest` (not already a `blacksmith-*` runner), AND
- the image is non-trivial / built often (base image + deps that rarely change but
  get rebuilt every run — the incremental-layer case Blacksmith's cache wins on).

The recommended swap (per <https://docs.blacksmith.sh/blacksmith-caching/docker-builds>):

| From | To |
|---|---|
| `runs-on: ubuntu-latest` | `runs-on: blacksmith-<N>vcpu-ubuntu-2204` |
| `docker/setup-buildx-action@vX` | `useblacksmith/setup-docker-builder@v1` |
| `docker/build-push-action@vX` | `useblacksmith/build-push-action@v2` |
| `cache-from:` / `cache-to:` (registry/inline cache) | **remove** — sticky-disk layer cache replaces them |

Payoff: 2x–40x rebuild speedups on large/incremental images (unchanged layers derive
from the sticky disk; only modified layers rebuild). Verify the action versions and
runner labels against the docs at audit time — pin the current major, do not trust
this table blind.

**If the job is ALREADY on Blacksmith** (much of an estate may already be
migrated), the finding is not "move it" but a **residual-drift
check** for a half-finished migration:
- leftover `cache-from:` / `cache-to: type=gha` (or registry cache) sitting **next to**
  the sticky-disk cache — the GHA cache should have been removed at migration; flag it;
- missing `max-cache-size-mb` on `useblacksmith/setup-docker-builder` — unbounded growth;
- the Blacksmith actions not SHA-pinned (they are third-party — full commit SHA, not a tag).

**Cost + caveats to surface with every recommendation** (do not sell the move without them):
- Sticky disk is billed **$0.50/GB/mo**, one disk per unique Dockerfile, evicted after
  **7 days** of no build (Blacksmith pricing / eviction as of 2026-07 — re-check the
  docs at audit time; they change). A rarely-built image may never warm the cache —
  recommend only where build frequency clears the eviction window.
- Set `max-cache-size-mb` (e.g. `409600` = 400 GB) or the cache grows unbounded.
- **A publish/release job that emits npm provenance MUST stay `ubuntu-latest`** — npm's
  sigstore / trusted-publishing check rejects a Blacksmith `self-hosted` runner (E422).
  Check every provenance trigger, not just an explicit `npm publish --provenance` flag:
  `NPM_CONFIG_PROVENANCE=true`, `provenance=true` in `.npmrc`, `publishConfig.provenance`
  in `package.json`, or OIDC trusted publishing (provenance on by default). Never
  recommend moving any of them.
- Any job gaining a `blacksmith-*` `runs-on` needs the Blacksmith labels allowlisted in
  `.github/actionlint.yaml`, or actionlint red-fails the build on the unknown label.
  If the repo has no such file, that is part of the recommendation.

### (b) Heavy-compute move — the existing rollout pattern

Independently of Docker, a common rollout runs **compute-heavy CI + Stryker
mutation** jobs on a Blacksmith runner (e.g. `blacksmith-4vcpu-ubuntu-2404`). Flag
a repo whose build/test or `mutation.yml` still runs on `ubuntu-latest`
as a compute-move candidate. **Leave on `ubuntu-latest`:** deploy, smoke, lighthouse,
actionlint-only, CodeQL, and `--provenance` publish jobs — network-bound or
policy-pinned, no compute gain.

## 5. Report

**Single repo** → a findings summary in chat: one table, grouped
gap / drift / subtract / Blacksmith-opportunity, each row naming the
`workflow:job` (or file), the finding, and the concrete fix. Close with a one-line
verdict and a pointer: "run `scaffold-ci` to remediate".

**Sweep** → in chat AND persisted to the vault
(`<vault>\CI Audit\<folder>\<YYYY-MM-DD>.md`, per the
scaffold-doc conventions). If that path already exists (a same-day rerun, or an
unrelated note), do **not** clobber it — overwrite only a prior audit report of your
own at that path, otherwise add a `-NN` suffix; never destroy unrelated vault content:

- a **consistency matrix** — one row per repo, columns for the load-bearing knobs
  (CI present, checkout pin, concurrency policy, dependabot, CodeQL, mutation, runner
  = ubuntu/blacksmith, Docker build y/n) — so drift across repos reads at a glance;
- a **Blacksmith opportunity ranking** — the Docker-build candidates ordered by
  expected payoff (build frequency × image size), each with its cost caveat;
- a per-repo findings block for anything not captured by the matrix.

Convert relative dates to absolute when stamping the report.

## Common mistakes

| Mistake | Fix |
|---|---|
| Hardcoding action pins / rules in this skill | Read them from `scaffold-ci` at audit time; they drift. |
| Recommending Blacksmith for every Docker job | Gate on build frequency vs the 7-day eviction and image size; a rarely-built image never warms the cache. |
| Recommending a Blacksmith move for a `--provenance` publish job | It must stay `ubuntu-latest` (sigstore rejects self-hosted). |
| Recommending a `blacksmith-*` runner without the actionlint allowlist | The move needs `.github/actionlint.yaml` too, or actionlint red-fails. |
| Concluding "no workflows" from an empty `**` glob | `**` skips the dotted `.github` dir; enumerate by literal path. |
| Editing workflows to "just fix it" | Read-only skill. Hand remediation to `scaffold-ci` in the review worktree. |
| Flagging a no-deploy repo's ref-gated concurrency as wrong | Flat `false` is house-correct only for deploy repos; ref-gated is right for libraries. |
| Treating cross-repo inconsistency as fine because each value is defensible | Inconsistency is itself a finding on a sweep — flag it. |

## Red flags — STOP

- About to edit a workflow file → stop; this skill reports, `scaffold-ci` fixes.
- About to recommend a Blacksmith move without its cost caveat (sticky-disk billing,
  7-day eviction, `max-cache-size-mb`) → stop; the caveat ships with the recommendation.
- About to restate action pins or concurrency rules from memory → stop; read them from
  `scaffold-ci`.
