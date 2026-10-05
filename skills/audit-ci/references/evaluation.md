# 3. Evaluate against the house standard reference

## Contents

- [3. Evaluate against the house standard](#3-evaluate-against-the-house-standard)


## 3. Evaluate against the house standard

<!-- routing: evaluate -->
For each dimension, classify a finding as **gap** (missing), **drift** (present but
diverges from `scaffold-ci`), or **subtract** (non-house extra to remove). Read the
canonical value from `scaffold-ci` and compare.

| Dimension | What to check | Typical finding |
|---|---|---|
| **Primary workflow present** | The primary workflow is the exact workflow path replacing `.github/workflows/ci.yml` in the HIGH policy list (`ci.yml` wins when several workflows are HIGH); require build + test + lint per stack | gap: no CI at all; gap: several HIGH workflows and no `ci.yml` (ambiguous primary) |
| **CI Gate** | Run the repository's shipped `assert_gate_coverage.py` against the primary workflow; require its `Gate coverage` job to execute that checker and require zero-authority `CI Gate` semantics from the current CI workflow contract | gap: a quality job is absent from `needs`; drift: missing `if: always()`, result aggregation, gate coverage, or zero permissions |
| **Action pins** | compare each `uses:` against `scaffold-ci`'s pin table (re-read it — pins drift and dependabot bumps them) | drift: stale `@v4` checkout, etc. |
| **Third-party SHA pins** | third-party actions use a valid full commit SHA, not a floating tag. Cross-check the live upstream major tag **of the action's own repo**, dereferencing an annotated tag to its commit (`refs/tags/<tag>^{}` with lightweight-tag fallback). A valid immutable pin behind the moving tag is timestamped `freshness drift`: report it, but it does not change the repository verdict. A floating tag, nonexistent commit, wrong repository, or known revoked/compromised commit remains blocking structural drift. | structural drift: `raven-actions/actionlint@v2`; freshness drift: a valid older SHA under `# v2` |
| **First-party pin style** | first-party `actions/*` take the major tag, not a SHA (the inverse of third-party) — except the **reviewed exception** in [`scaffold-ci/assets/secret-sweep.yml`](../../scaffold-ci/assets/secret-sweep.yml), whose full-history checkout is SHA-pinned. Compare that workflow with the shipped asset; do not report its matching checkout pin as drift. | drift: an ordinary workflow mixes `actions/checkout@<sha>` with `@v7` |
| **actionlint step** | normally the first validation step after checkout; on a cold runner consuming private npm packages, `setup-node` and `NODE_AUTH_TOKEN` must come before actionlint so its transitive install can authenticate | gap: missing; drift: private-npm actionlint runs before authentication |
| **Workflow hygiene** | compare `.github/scripts/assert_workflow_hygiene.py` with the shipped asset and run it over every local workflow; confirm `review-policy-guard.yml` invokes it | gap: guard never executes the parser; drift: local checker differs from the shipped asset |
| **Concurrency** | deploy repo → flat `cancel-in-progress: false`; no-deploy → `${{ github.ref != 'refs/heads/main' }}` | drift: flat `false` on a library repo; unconditional `true` |
| **Triggers** | [push to mainline + tags `v*`](../../scaffold-ci/references/ci-workflow.md) + `pull_request` to mainline + bare `workflow_dispatch` | drift: push builds every branch or omits tags |
| **Tag ancestry** | for every tag-fired publish/deploy path, apply the current ancestry assertion from `scaffold-ci/references/ci-workflow.md` | drift: a `v*` tag can publish an unreviewed commit |
| **Required-lane cost** | derive the current per-test, per-job, aggregate, and extended-lane ceilings from `scaffold-ci/references/ci-workflow.md`; count matrix legs and keep extended work out of `CI Gate` | drift: timeout/cost exceeds the current contract or slow coverage blocks PRs |
| **CSharpier gate** | in each .NET backend job, derive the command/order from `scaffold-ci`: local tool restore, read-only CSharpier check, then NuGet restore/build/test | gap: no format gate; drift: check runs after restore or CI mutates source |
| **Dead dispatch input** | `workflow_dispatch` `environment` choice only where a deploy job reads it | subtract: dead dropdown no step consumes |
| **dependabot.yml** | present; ecosystems match the repo (nuget/npm/github-actions); npm `directory` points at the real `package.json` folder; private feeds have a referenced `registries:` entry and a Dependabot-store secret; peer-locked families such as Vite/vitest have a major-admitting group above the minor/patch catch-all | gap / drift: missing npm ecosystem, wrong directory, private updater cannot authenticate, or Vite major PRs cannot install |
| **mutation.yml** | present + separate workflow for any repo with a .NET test project; exactly `workflow_dispatch` plus one staggered weekly UTC schedule, with no push/PR trigger; no `continue-on-error`; `break: 0`; ordinary one-project lane runs from the intended unit-test project directory; MTP config has no `test-case-filter`; intentional multi-project lanes use documented `test-projects` from the project-under-test directory; discovered-test count matches the lane and known-tested code produces a non-zero `Killed` count | gap: missing or manual-only; drift: push/PR/nightly trigger, run as a `ci.yml` gate, inert MTP filter, or unverified discovery/result attribution |
| **Stryker support files** | with `mutation.yml`: local tool manifest contains Stryker and CSharpier without replacing existing tools; `stryker-config.json` matches the selected lane and house defaults; the workflow uses `scripts/summarize-stryker.ps1`; compare that file with the shipped template using `scripts/compare-canonical-file.ps1 -IgnoreLineEndings` | gap: any support file absent; drift: manifest clobbered, config contradicts the lane, or the script is not the shipped content |
| **Secret scanning** | For private repos, derive the contract from [`scaffold-ci/assets/secret-sweep.yml`](../../scaffold-ci/assets/secret-sweep.yml) and [`scaffold-ci/references/dependencies-and-security.md`](../../scaffold-ci/references/dependencies-and-security.md). Require the CI job to run both the PR commit-range scan and checked-out-tree scan and to feed `CI Gate`; compare the sweep's trigger, pins, detector allowlist, install and checksum with the canonical sources. | gap: either compensating control or either CI scan absent; drift: secret job is not gated or sweep diverges from its shipped contract |
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
