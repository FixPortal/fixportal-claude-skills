---
name: scaffold-ci
description: Use when adding or normalizing GitHub Actions CI, Dependabot, GitHub security, or AI-review policy in a .NET, React, or hybrid repository.
---

# scaffold-ci

## Overview

Reconcile a repository with the house CI standard; never overwrite working automation blindly. Read `~/.agents/notes/deploy-and-ci-traps.md` before non-trivial CI or deploy work.

## Quick reference

Read only the references for the surface in hand, then follow their contract exactly:

| Work | Reference |
|---|---|
| `ci.yml`, runners, deploy/publish jobs, CI Gate | [CI workflow](references/ci-workflow.md) |
| Stryker.NET and `mutation.yml` | [Mutation](references/mutation.md) |
| Dependabot, GitHub security settings, and secret scanning | [Dependencies and security](references/dependencies-and-security.md) |
| `.gitignore`, review guard, risk tiers, CodeRabbit | [Review policy](references/review-policy.md) |
| Final normalization | [Common mistakes](references/common-mistakes.md) |

Copy and adapt shipped files from `assets/` and `templates/`; do not retype them. Changing
either makes every copy elsewhere stale: run `scripts/sweep-canonical-asset-drift.ps1`.
A local edit to a copied asset fails the consumer's canonical-asset manifest gate
(`references/ci-workflow.md`).

## Procedure

1. Identify the mainline, repo visibility, existing workflows, project roots, package scripts, deploy jobs, test projects, and local tool manifests.
2. Classify the repo as backend, frontend, or hybrid. Reconcile existing automation and preserve repo-specific deployment behavior.
3. Apply the relevant references. Control surfaces include `ci.yml`, `mutation.yml`, Dependabot, Stryker support files, GitHub security settings, Dependabot security settings, AI-review policy, `.gitignore`, `review-policy-guard.yml`, `review-tier.yml`, and secret scanning. Tier both review workflows HIGH in `.claude/review-policy.json`.
4. Actionlint is the first validation step after checkout in substantive jobs; the zero-authority gate-control jobs are exempt.
5. Keep Stryker outside per-commit CI: every mutation workflow has manual dispatch plus one staggered weekly UTC schedule.
6. Enforce the PR cost envelope: 30 seconds per test, 10 minutes per substantive required job, and a 15 aggregate runner-minute target. Route extended coverage to weekly/manual jobs capped at 45 minutes.
7. Never mutate GitHub settings or create secrets without approval. Public repositories enable free deterministic Code Quality, AI findings disabled; private/internal keep it off.

## Load-bearing checks

- No-deploy workflows cancel superseded branch runs but not main or tags; deploy workflows use `cancel-in-progress: false`.
- Backend CI is npm-free. Restore local tools and run `dotnet csharpier check .` before restore/build/test.
- End-to-end, stress/load/soak, repeated concurrency, slow packaging, and compatibility matrices never run in the required PR lane.
- `CI Gate` has `if: always()`, zero permissions, and needs every quality job. `Gate coverage` runs the shipped stdlib-only asset, which asserts the gate's own semantics.
- `review-policy-guard.yml` verifies the policy is tracked, uses `git check-ignore --no-index`, and runs `assert_workflow_hygiene.py` — which parses workflows, never greps them.
- Secret gates pin the gitleaks install and scan range *and* tree; sweeps use the TruffleHog detector allowlist.
- Tag-fired publish/deploy asserts ancestry of the default branch.
- Dependency manifests are not HIGH. Registry, SDK, analyzer, auth, migration, review controls, and the merge barrier are.

## Validation

Parse changed YAML/JSON, run actionlint when workflows changed, run the shipped tests, and verify `git add --dry-run .claude/review-policy.json`. Verify effective state after approved server-setting changes. Never commit or push unless requested.
