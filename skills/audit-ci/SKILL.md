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
practice".** `scaffold-ci` is the single source of truth for the house standard.
Read its [ten control surfaces](../scaffold-ci/SKILL.md), its [CI workflow
contract](../scaffold-ci/references/ci-workflow.md), and its shipped
[`secret-sweep.yml`](../scaffold-ci/assets/secret-sweep.yml),
[`assert_gate_coverage.py`](../scaffold-ci/assets/assert_gate_coverage.py),
[`assert_workflow_hygiene.py`](../scaffold-ci/assets/assert_workflow_hygiene.py), and
[review-policy contract](../scaffold-ci/references/review-policy.md) at audit time;
compare against those assets rather than duplicating their pins or rules here.

**This skill is read-only and advisory.** It diffs config against the standard and
writes a report. It does **not** edit workflows, branch, or commit. Remediation is a
separate `scaffold-ci` pass (in the review worktree, per the code-review-pass
workflow). Sibling of `review-sweep`.

**Before reasoning about any GitHub Actions gotcha, read
`~/.agents/notes/deploy-and-ci-traps.md`.** That is the canonical path in every
runtime — each runtime's own notes directory is a directory junction onto it. If it is absent,
use `scaffold-ci` and current authoritative sources rather than recalled guidance.

## The spine

1. **Discover** the in-scope repo(s).
2. **Inventory** each repo's CI/CD artifacts and their shape.
3. **Evaluate** each against the house standard (gaps + drift + non-house extras).
4. **Blacksmith lens** — score each Docker/heavy-compute job for a runner move.
5. **Report** — per-repo findings + (on a sweep) a cross-repo consistency matrix.

## 1. Discover

<!-- routing: discover -->
- **One repo:** the current repo, or a named path.
- **Sweep:** enumerate top-level dirs under the target folder, minus an exclusion
  list (exact leaf-name match). Keep only git repos
  (`git -C <dir> rev-parse --is-inside-work-tree`). A sweep is long — keep the
  per-repo sequence in the runtime's persistent plan/task facility when one is
  available, otherwise maintain a compact checklist in the working report.

For each repo, read the mainline branch
(`git symbolic-ref refs/remotes/origin/HEAD`) — findings about triggers and
ref-gating depend on it, and it is not always `main`. That command fails on a
clone whose remote HEAD is unset or differently named; fall back to
`git remote show origin` (its "HEAD branch" line) or
`gh api repos/{owner}/{repo} --jq .default_branch`, and if none resolve, mark
the trigger / ref-gating findings **unverifiable** rather than assuming `main`.

## 2. Inventory

<!-- routing: inventory -->
Read [the inventory procedure](references/inventory.md) in full before collecting evidence; it defines the workflow, control and Actions-run inventory.

## 3. Evaluate against the house standard

<!-- routing: evaluate -->
Read [the evaluation procedure](references/evaluation.md) in full after inventory. Apply every house-standard check, including runtime evidence and cost approvals.

## 4. Blacksmith lens (the headline)

<!-- routing: blacksmith-lens -->
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
| `runs-on: ubuntu-latest` | `runs-on: blacksmith-<N>vcpu-ubuntu-2404` |
| `docker/setup-buildx-action@…` | `useblacksmith/setup-docker-builder@<full-commit-sha> # v2` |
| `docker/build-push-action@…` | `useblacksmith/build-push-action@<full-commit-sha> # v2` |
| — | add `cache-key: <Dockerfile path>` to `setup-docker-builder` — **required input**, and it is what scopes the cache to one build workload (one sticky disk per `cache-key`) |
| `cache-from:` / `cache-to:` (registry/inline cache) | **remove** — sticky-disk layer cache replaces them |

Payoff: 2x–40x rebuild speedups on large/incremental images (unchanged layers derive
from the sticky disk; only modified layers rebuild). Verify the action versions and
runner labels against the docs at audit time. Resolve each current Blacksmith major
tag to its commit, pin that full SHA, and retain the major as a comment; do not trust
this table blind.

**If the job is ALREADY on Blacksmith**, the finding is not "move it" but a
**residual-drift check** for a half-finished migration:
- leftover `cache-from:` / `cache-to: type=gha` (or registry cache) sitting **next to**
  the sticky-disk cache — the GHA cache should have been removed at migration; flag it;
- missing `cache-key` on `useblacksmith/setup-docker-builder` — it is a required input,
  and without it the cache is not scoped to the build workload;
- still on the deprecated `# v1` setup-only flow rather than `setup-docker-builder@v2`;
- the Blacksmith actions not SHA-pinned (they are third-party — full commit SHA, not a tag).

**Cost + caveats to surface with every recommendation** (do not sell the move without them):
- Sticky disk is billed **$0.50/GB/mo**, one disk per unique Dockerfile, evicted after
  **7 days** of no build (Blacksmith pricing / eviction as of 2026-07 — re-check the
  docs at audit time; they change). A rarely-built image may never warm the cache —
  recommend only where build frequency clears the eviction window.
- Cache size needs **no** configuration: BuildKit's native time-based garbage collection
  evicts layers unused for 8 days and keeps actively-used layers regardless of total
  size. There is no size knob to set — do not invent one.
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

Independently of Docker, read the heavy-compute runner convention from
`scaffold-ci` ("Runners — `ubuntu-latest` by default, Blacksmith for heavy
lanes"). It assigns build/test, Stryker mutation and Docker-image publish to
`blacksmith-4vcpu-ubuntu-2404`, and everything else to `ubuntu-latest`.

**A build/test job on `ubuntu-latest` is not drift.** That is the documented
scaffold default, deliberately, because Blacksmith bills per minute and per GB of
sticky-disk cache. Raise it as an **opportunity**, and only with evidence the repo
has outgrown the default — a long-running job, or Docker layer rebuilds dominating
the wall clock. No evidence, no recommendation; "it could be faster" is true of
every job and is not a finding.

Where you do recommend a move for a Docker-building job, the
`useblacksmith/setup-docker-builder` and `useblacksmith/build-push-action` swaps
are part of the recommendation, not a follow-up — without them the sticky-disk
cache is never used and the move buys only a bigger CPU.

**Never recommend moving:** deploy, smoke, lighthouse, actionlint-only, CodeQL,
and `--provenance` publish jobs — network-bound or policy-pinned, no compute gain.

## 5. Report

<!-- routing: report -->
**Single repo** → a findings summary in chat: one table, grouped
gap / drift / subtract / Blacksmith-opportunity, each row naming the
`workflow:job` (or file), finding kind (`structural`, `execution`, or `freshness`), the
finding, and the concrete fix. Close with a one-line
verdict and a pointer: "run `scaffold-ci` to remediate".

The three finding kinds, because only one of them names itself:

- **`structural`** — read off the FILES. A control is absent, misdeclared, or diverges
  from the shipped asset: no `dependabot.yml`, a quality job outside `ci-gate`'s
  `needs`, a drifted `summarize-stryker.ps1`. Provable from the checkout alone.
- **`execution`** — read off a RUN. The configuration is present and its behaviour is
  wrong or unproven: a required job that concluded `skipped` on every mainline run, a
  lane over the minute budget, a gate step whose body cannot fail. It needs Actions
  evidence, so it cannot be raised from the checkout — and when no run was read, its
  absence is a coverage gap, not a clean result.
- **`freshness`** — read off a DATE or a version. The control exists and works but is
  behind: an action pinned several majors back, an approval naming a superseded
  `head_sha`, a `.gitleaksignore` fingerprint for a file long deleted.

A finding that fits two kinds is `execution`: what a run actually did outranks what the
file says it should do.

**Sweep** → always in chat, and also persisted when the active runtime
instructions configure a CI-audit vault or report directory. Do not invent a
vendor-specific global path. If the target file already exists (a same-day rerun,
or an unrelated note), do **not** clobber it — overwrite only a prior audit report
of your own at that path, otherwise add a `-NN` suffix; never destroy unrelated
vault content:

- a **consistency matrix**, headed `Structural verdict as of <verification timestamp>` —
  one row per repo, with freshness drift in a separate column and columns for the load-bearing knobs
  (CI present, checkout pin, concurrency policy, dependabot, visibility-appropriate security settings,
  review policy addable, review-policy guard, mutation cadence/support files,
  runner = ubuntu/blacksmith, Docker build y/n) — so
  drift across repos reads at a glance;
- a **Blacksmith opportunity ranking** — the Docker-build candidates ordered by
  expected payoff (build frequency × image size), each with its cost caveat;
- a per-repo findings block for anything not captured by the matrix.

Convert relative dates to absolute when stamping the report.

## Red flags — STOP

- About to edit a workflow file → stop; this skill reports, `scaffold-ci` fixes.
- About to recommend a Blacksmith move without its cost caveat (sticky-disk billing,
  7-day eviction) → stop; the caveat ships with the recommendation.
- About to name a Blacksmith input from memory → stop; read it off
  <https://docs.blacksmith.sh/blacksmith-caching/docker-builds>. This skill has
  already shipped one invented knob (`max-cache-size-mb`, corrected 2026-08-03).
- About to restate action pins or concurrency rules from memory → stop; read them from
  `scaffold-ci`.

Supporting files: Run `scripts/get-workflow-inventory.ps1`, `scripts/test-scaffold-contract.ps1`, `scripts/compare-canonical-file.ps1` and `scripts/test-required-lane-cost.ps1` as directed by the inventory/evaluation references. Run `test/verify-audit-mechanics.ps1`, `test/verify-blacksmith-guidance.ps1` for local contract checks.
