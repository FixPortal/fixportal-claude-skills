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
Start with `scripts/get-workflow-inventory.ps1 -RepositoryRoot <repo>`. Record its sorted
output and inventory count. The audit is incomplete unless every inventoried workflow has one evidence
row; never infer repository-wide conformance from `ci.yml` alone.

Read, per repo, using the runtime's filesystem listing, reading, and search
capabilities rather than shell `cat`/`find`:

- `.github/workflows/*.yml` **and** `*.yaml` — **enumerate both by literal path**
  (`<repo>\.github\workflows\*.yml` and `<repo>\.github\workflows\*.yaml`); a
  `**` glob silently skips the dotted `.github` dir, and a repo whose workflows use
  the `.yaml` extension is otherwise wrongly reported as having no CI.
- `.github/dependabot.yml`, `.github/actionlint.yaml`.
- For private repositories, verify all three secret-scanning controls separately: the
  PR-range scan and push-range scan in the selected primary workflow, and `.github/workflows/secret-sweep.yml`'s
  weekly full-history scan. They cover different history ranges; read their contract
  from `scaffold-ci`, not from similarly named public GitHub security settings.
- With `mutation.yml`, `.config/dotnet-tools.json`, `stryker-config.json`, and
  `scripts/summarize-stryker.ps1`; inspect the files, not just the workflow references.
- `.github/workflows/review-policy-guard.yml` wherever
  `.claude/review-policy.json` is scaffolded. Confirm it protects the policy's tracked and
  unignored invariants rather than merely existing.
- `.claude/review-policy.json` and `.coderabbit.yaml` — the AI-reviewer risk policy and
  spend controls. Both are dot-path files, so enumerate them by **literal path**; a `**`
  glob skips the dotted `.claude` dir and reads as absent.
- `.gitignore`, plus `git add --dry-run .claude/review-policy.json`; success proves the
  policy is addable. Use `git check-ignore -v` only after failure to identify the rule:
  verbose mode can print a matching negation for an untracked, addable file.
- Any `Dockerfile` / `*.Dockerfile`, plus modern and legacy Compose names:
  `compose.yml`, `compose.yaml`, `docker-compose.yml`, `docker-compose.yaml`,
  `docker-compose*.yml`, and `docker-compose*.yaml` (repo builds images?). Filter
  IDE/tool-generated noise out of those names — Rider's `.idea/**/compose*.generated*`
  and `.idea/**/docker-compose*.generated*` files, with either YAML extension, are
  not CI artifacts.
- **Reusable / called workflows.** An **external** call
  (`uses: <org>/<repo>/.github/workflows/x.yml@ref`) delegates its runner and step
  config to the *called* repo — note the delegation, treat its internals as out of
  scope, don't grade a step you cannot see. A **same-repo** call
  (`uses: ./.github/workflows/x.yml`) is fully auditable here: its jobs, runners and
  steps live in this repo, so audit them like any other workflow.
- The repo's stack signals: a `.sln` / `*.csproj` (backend), `package.json` with
  `lint`/`test`/`build` scripts (frontend), test projects (mutation candidate).
- Repository visibility and effective GitHub security configuration. Apply the
  visibility matrix from `scaffold-ci` before classifying any security surface.
- Organization Code Quality **Repository access** and enforcement. Code Quality is free on
  public repositories and paid on private/internal ones, so the compliant state is
  `Selected repositories` containing exactly the public repositories with `Enforce access`
  on, or `All repositories` where every repository in scope is public. Classify an
  overridable scope, enforcement off, or any private/internal repository in the selection
  as drift.

  **This is a UI-only surface — there is no API for it, and free is not the same as
  readable.** GitHub publishes Code Quality only at repository scope
  (`GET/PATCH /repos/{owner}/{repo}/code-quality/setup`,
  `GET /repos/{owner}/{repo}/code-quality/findings`); no organization endpoint exposes the
  repository-access selection or its enforcement flag. Every
  neighbouring check below names an exact call, so state plainly that this one cannot:
  **ask the user** to read *Organization settings → Code security → Code Quality* and
  report the selection and the enforcement toggle. Record their answer
  as the evidence, with the date. If they do not answer, this is an **evidence gap** —
  report it as `Code Quality org access: UNVERIFIED (UI-only, awaiting operator)` and carry
  on with the rest of the audit. Never infer it from repository-level `state`, and never
  let an unanswered question silently become "compliant".

  **ASK ONCE PER SWEEP, not once per repository.** The setting is a property of the
  ORGANIZATION, so the answer is identical for every repo in one pass — asking per repo
  interrupts a twenty-repo sweep twenty times for one fact. Ask at the start of the sweep,
  before the per-repo work, and apply the single answer to every repo in it, recording the
  same date and the same operator response on each.

  An answer from a PRIOR sweep may be reused only if it is DATED and no more than seven
  days old; state the date you are reusing. An undated answer, or one older than that, is
  not evidence — the whole point of the question is that nothing mechanical can detect a
  change to this setting, so an unbounded carry-forward reports a stale UI reading as a
  current observation. When you cannot ask (an unattended run), every repo in the sweep
  carries `UNVERIFIED`; a single unanswered question does not become twenty different
  verdicts.
- For a **public** repository, verify free CodeQL default setup through its own endpoint:
  `GET repos/{owner}/{repo}/code-scanning/default-setup` must return `state: configured`.
  Do not infer this from an Actions workflow named `CodeQL`; paid Code Quality uses the same
  workflow name.
- For a **private/internal** repository, do not query CodeQL or secret-scanning endpoints.
  Their expected `403`/`404` is policy-compliant paid-feature disablement, not a gap.
- Dependabot alerts via `GET repos/{owner}/{repo}/vulnerability-alerts`; HTTP 204 means
  enabled and HTTP 404 means disabled. Automated security fixes use a different contract:
  `GET repos/{owner}/{repo}/automated-security-fixes` must return HTTP 200 with
  `enabled: true` and `paused: false`; HTTP 404, `enabled: false`, or `paused: true` is
  non-compliant.

## 3. Evaluate against the house standard

<!-- routing: evaluate -->
For each dimension, classify a finding as **gap** (missing), **drift** (present but
diverges from `scaffold-ci`), or **subtract** (non-house extra to remove). Read the
canonical value from `scaffold-ci` and compare.

| Dimension | What to check | Typical finding |
|---|---|---|
| **Primary workflow present** | The primary workflow is the exact workflow path replacing `.github/workflows/ci.yml` in the HIGH policy list; require build + test + lint per stack | gap: no CI at all |
| **CI Gate** | Run the repository's shipped `assert_gate_coverage.py` against the primary workflow; require its `Gate coverage` job to execute that checker and require zero-authority `CI Gate` semantics from the current CI workflow contract | gap: a quality job is absent from `needs`; drift: missing `if: always()`, result aggregation, gate coverage, or zero permissions |
| **Action pins** | compare each `uses:` against `scaffold-ci`'s pin table (re-read it — pins drift and dependabot bumps them) | drift: stale `@v4` checkout, etc. |
| **Third-party SHA pins** | third-party actions use a valid full commit SHA, not a floating tag. Cross-check the live upstream major tag **of the action's own repo**, dereferencing an annotated tag to its commit (`refs/tags/<tag>^{}` with lightweight-tag fallback). A valid immutable pin behind the moving tag is timestamped `freshness drift`: report it, but it does not change the repository verdict. A floating tag, nonexistent commit, wrong repository, or known revoked/compromised commit remains blocking structural drift. | structural drift: `raven-actions/actionlint@v2`; freshness drift: a valid older SHA under `# v2` |
| **First-party pin style** | first-party `actions/*` take the major tag, not a SHA (the inverse of third-party) — except the **reviewed exception** in [`scaffold-ci/assets/secret-sweep.yml`](../scaffold-ci/assets/secret-sweep.yml), whose full-history checkout is SHA-pinned. Compare that workflow with the shipped asset; do not report its matching checkout pin as drift. | drift: an ordinary workflow mixes `actions/checkout@<sha>` with `@v7` |
| **actionlint step** | normally the first validation step after checkout; on a cold runner consuming private npm packages, `setup-node` and `NODE_AUTH_TOKEN` must come before actionlint so its transitive install can authenticate | gap: missing; drift: private-npm actionlint runs before authentication |
| **Workflow hygiene** | compare `.github/scripts/assert_workflow_hygiene.py` with the shipped asset and run it over every local workflow; confirm `review-policy-guard.yml` invokes it | gap: guard never executes the parser; drift: local checker differs from the shipped asset |
| **Concurrency** | deploy repo → flat `cancel-in-progress: false`; no-deploy → `${{ github.ref != 'refs/heads/main' }}` | drift: flat `false` on a library repo; unconditional `true` |
| **Triggers** | [push to mainline + tags `v*`](../scaffold-ci/references/ci-workflow.md) + `pull_request` to mainline + bare `workflow_dispatch` | drift: push builds every branch or omits tags |
| **Tag ancestry** | for every tag-fired publish/deploy path, apply the current ancestry assertion from `scaffold-ci/references/ci-workflow.md` | drift: a `v*` tag can publish an unreviewed commit |
| **Required-lane cost** | derive the current per-test, per-job, aggregate, and extended-lane ceilings from `scaffold-ci/references/ci-workflow.md`; count matrix legs and keep extended work out of `CI Gate` | drift: timeout/cost exceeds the current contract or slow coverage blocks PRs |
| **CSharpier gate** | in each .NET backend job, derive the command/order from `scaffold-ci`: local tool restore, read-only CSharpier check, then NuGet restore/build/test | gap: no format gate; drift: check runs after restore or CI mutates source |
| **Dead dispatch input** | `workflow_dispatch` `environment` choice only where a deploy job reads it | subtract: dead dropdown no step consumes |
| **dependabot.yml** | present; ecosystems match the repo (nuget/npm/github-actions); npm `directory` points at the real `package.json` folder; private feeds have a referenced `registries:` entry and a Dependabot-store secret; peer-locked families such as Vite/vitest have a major-admitting group above the minor/patch catch-all | gap / drift: missing npm ecosystem, wrong directory, private updater cannot authenticate, or Vite major PRs cannot install |
| **mutation.yml** | present + separate workflow for any repo with a .NET test project; exactly `workflow_dispatch` plus one staggered weekly UTC schedule, with no push/PR trigger; no `continue-on-error`; `break: 0`; ordinary one-project lane runs from the intended unit-test project directory; MTP config has no `test-case-filter`; intentional multi-project lanes use documented `test-projects` from the project-under-test directory; discovered-test count matches the lane and known-tested code produces a non-zero `Killed` count | gap: missing or manual-only; drift: push/PR/nightly trigger, run as a `ci.yml` gate, inert MTP filter, or unverified discovery/result attribution |
| **Stryker support files** | with `mutation.yml`: local tool manifest contains Stryker and CSharpier without replacing existing tools; `stryker-config.json` matches the selected lane and house defaults; the workflow uses `scripts/summarize-stryker.ps1`; compare that file with the shipped template using `scripts/compare-canonical-file.ps1 -IgnoreLineEndings` | gap: any support file absent; drift: manifest clobbered, config contradicts the lane, or the script is not the shipped content |
| **Secret scanning** | For private repos, derive the contract from [`scaffold-ci/assets/secret-sweep.yml`](../scaffold-ci/assets/secret-sweep.yml) and [`scaffold-ci/references/dependencies-and-security.md`](../scaffold-ci/references/dependencies-and-security.md). Require the CI job to run both the PR commit-range scan and checked-out-tree scan and to feed `CI Gate`; compare the sweep's trigger, pins, detector allowlist, install and checksum with the canonical sources. | gap: either compensating control or either CI scan absent; drift: secret job is not gated or sweep diverges from its shipped contract |
| **GitHub security surfaces** | public: CodeQL default setup, secret scanning and push protection enabled, plus free deterministic Code Quality configured; every visibility: Code Quality AI findings disabled; private/internal: paid Code Security, secret scanning and paid Code Quality disabled | gap: public free CodeQL/secret/Code Quality coverage off; drift: Code Quality enabled on a private/internal repository, AI findings enabled anywhere, or any paid private surface enabled; subtract: any automatic `copilot_code_review` ruleset or committed `codeql.yml` |
| **Dependabot security settings** | vulnerability alerts GET returns HTTP 204; automated security fixes GET returns HTTP 200 with `enabled: true` and `paused: false`. **These are CONFIGURATION checks and passing them is not evidence Dependabot is fixing anything** — a repo can pass every row here while a high-severity alert sits unactioned, because Dependabot can reach a wrong "cannot update" verdict (`~/.agents/notes/npm-publishing-traps.md` trap 16). The outcome axis belongs to `audit-dependabot-coverage`; do not report Dependabot healthy on config alone. | gap: either repository setting is off or automated fixes are paused |
| **`.gitignore`** | Claude scratch uses `.claude/*` with `!.claude/review-policy.json`; `git add --dry-run .claude/review-policy.json` succeeds | drift: `.claude/` excludes the parent directory, so the policy can never be committed |
| **`review-policy-guard.yml`** | compare with the shipped control, confirm it runs workflow hygiene, and require the exact current merge-barrier paths from `scaffold-ci/references/review-policy.md` to be HIGH; `Review policy intact` remains required | gap: guard, hygiene execution, HIGH path, or required context absent; drift: local guard diverges from the current contract |
| **Job-lane naming** | deploy jobs contain `deploy`; publish jobs a package term; one job = one lane | drift: a `build-and-push` job that mis-lanes or vanishes from the dashboard |
| **`review-policy.json`** | present; `high` covers the migration / infra / workflow / auth paths this repo actually has, and does NOT list dependency manifests (`package.json`, `package-lock.json`, `Directory.Packages.props`, `**/*.csproj` — reversed 2026-07-29; HIGH requires CodeRabbit, which refuses bot authors, so it demands a reviewer that can never run); **every** `low` glob is genuinely unreachable from this repo's deploy jobs — verify against the deploy/publish steps you just inventoried, do not take the list on trust | gap: absent (safe — all PRs default NORMAL); **drift: a `low` glob that IS reachable, e.g. `**/*.md` in a repo that publishes its markdown, or `.dockerignore` in a repo that ships an image** |
| **`.coderabbit.yaml`** | present with `auto_review.enabled: false` **and** `labels: ["review-high"]`; `auto_pause_after_reviewed_commits: 2`; `ignore_usernames` lists `dependabot[bot]` and `renovate[bot]`; no `ignore_title_keywords` | gap: missing, so the repo runs on CodeRabbit defaults; **drift: `enabled: true` — reviews every PR regardless of tier, so `review-policy.json` decides nothing**; **drift (worse than `true`): `enabled: false` with NO `labels` list — the gate's `review-high` label is inert, no CodeRabbit check registers, and `pr-review-watch.sh` reads the persistently absent check as "not installed" and stops gating, so a HIGH PR merges unreviewed while every signal looks clean**; **drift: `"chore:"` in `ignore_title_keywords`, which matches this estate's Dependabot titles verbatim and skips PRs silently** |
| **Non-house extras** | `dependency-review-action`, redundant `tsc --noEmit`, coverage gating, Node in the backend job | subtract: per `scaffold-ci` "Not house standard" |

**Do not grade what the house standard does not define.** `scaffold-ci` documents
Stryker.NET mutation, not a JS/TS mutation sibling; a reusable-workflow delegation is
not one of its ten control surfaces. When a repo adds something the standard is silent on
(e.g. a `mutation-web.yml` StrykerJS run), **note it as an undocumented addition** —
do not score it gap/drift/subtract against a standard that never mentioned it.

Whenever `scaffold-ci` calls a file `shipped verbatim` or `copy-only`, path presence is not
evidence: compare content with `scripts/compare-canonical-file.ps1`. Use semantic comparison
only where the source reference explicitly permits adaptations such as repository cron or
comments; list each permitted field rather than treating every difference as acceptable.

For a private .NET repository, collect measured required-lane evidence before the
executable cross-check:

1. Resolve the audited head SHA independently from the repository/default branch.
2. List completed runs for the selected primary workflow through the Actions runs API
   with full pagination. Check the `gh` exit status before parsing. For a normal cost
   check, select a successful run whose `head_sha` exactly equals the audited SHA. When
   evaluating an over-budget exception, read the committed approval from the audited
   tree and select the successful run matching its `run_id`; verify that run's
   `head_sha` matches the approval. A same-branch run at another SHA is stale evidence.
3. List that run's jobs through the Actions jobs API with `filter=latest` and full
   pagination. Check the `gh` exit status before parsing each response. Preserve the
   response envelope's nonnegative `total_count`, append every page's jobs, and verify
   the accumulated job count exactly equals `total_count`. Write a temporary, sanitized
   JSON object containing only `run: { id, head_sha, conclusion }`, `total_count`, and
   every job's `id`, `name`, `started_at`, `completed_at`, `conclusion` and
   `run_attempt`; do not write it into the repository.

   `id` and `run_attempt` are not decoration. The checker identifies a job by `id` when
   the evidence carries it, because GitHub permits two job ids to declare the same
   `name:` and the Actions API reports `started_at` to the second — two legs starting in
   the same second collapsed to one, understating the lane and turning an
   `APPROVED_EXCEPTION` into `COMPLIANT`. And `run_attempt` is what lets the checker
   refuse evidence that mixes attempts of a re-run, which the name-plus-start identity
   cannot collapse (a re-attempt has a different start time), so both legs were summed
   and the lane was overstated instead. Omit either field and the corresponding guard
   has nothing to read.
4. Run
   `scripts/test-scaffold-contract.ps1 -RepositoryRoot <repo> -ScaffoldRoot ../scaffold-ci -ActionsEvidencePath <temp-json> -ExpectedHeadSha <sha>`.
   `-ScaffoldRoot` resolves against the **current directory**, so pass an absolute path
   or run from the `audit-ci` directory. The checker reads the audited repo's own
   `gate-coverage` step `env:` and passes those exemptions into
   `assert_gate_coverage.py`, so a repo declaring `GATE_EXEMPT: docker` is scored
   against its own declared exemptions rather than an empty environment.
   The checker maps required CI Gate job display names to every expanded Actions job,
   sums measured durations, and excludes the lightweight gate-control jobs. Missing,
   failed, incomplete, or stale evidence fails closed. A required job that concludes
   `skipped` — a `GATE_CONDITIONAL_EXEMPT` job carrying a `pull_request` condition stays
   a member of `ci-gate`'s `needs`, so it skips on every mainline run — contributes zero
   minutes and is reported as skipped, not treated as a failure. Read them off the
   result's `SkippedJobs` list — by name, so the report can say WHICH required jobs
   contributed nothing — and verify each one's `pull_request` execution separately.

   When measured required work is above the scaffold's 15-minute target, the checker
   reads owner approval from the audited repository's **committed**
   `.claude/ci-budget-approval.json` (tiered HIGH, so changing it is itself reviewed):
   `approved: true`, nonempty `owner`, valid `approved_at`, the `head_sha` and `run_id`
   of one successful measured ancestor run, and a file committed in the audited tree.
   **Never write that object yourself** — an approval the
   auditor authors is provenance-free and leaves no durable record; this skill is
   read-only and advisory, and cannot approve its own exception. Free-form text is not
   approval evidence, and a missing, malformed, stale, or unapproved object fails closed.
   Never infer approval from timeouts or repository configuration. The executable result
   is `APPROVED_EXCEPTION`, not `COMPLIANT`.

A failure is audit evidence, not a reason to fall back to the older prose checklist.

On a **sweep**, additionally flag **cross-repo inconsistency**: the same knob set
differently across repos (different checkout pins, some repos on Blacksmith and some
not, one repo cancels concurrency and its sibling does not). Inconsistency is itself a
finding even where each individual value is defensible.

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
