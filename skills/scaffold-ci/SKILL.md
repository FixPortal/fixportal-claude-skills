---
name: scaffold-ci
description: Use when adding or normalizing GitHub Actions CI, Dependabot, GitHub security, or AI-review policy in a .NET, React, or hybrid repository.
---

# scaffold-ci

## Overview

Reconcile CI with the house standard; preserve working automation. Read `~/.agents/notes/deploy-and-ci-traps.md` before non-trivial CI or deploy work.

## Quick reference

| Work | Reference |
|---|---|
| `ci.yml`, runners, deploy/publish jobs, CI Gate | [CI workflow](references/ci-workflow.md) |
| Stryker.NET and `mutation.yml` | [Mutation](references/mutation.md) |
| Dependabot, GitHub security settings, and secret scanning | [Dependencies and security](references/dependencies-and-security.md) |
| `.gitignore`, review guard, risk tiers, CodeRabbit | [Review policy](references/review-policy.md) |
| Final normalization | [Common mistakes](references/common-mistakes.md) |
| Before changing policy rationale: dated measurements and rollout incidents | [Policy provenance](references/provenance.md) |

Copy shipped `assets/` and `templates/`. After changes, run `scripts/sweep-canonical-asset-drift.ps1`.
Estate sweeps use `-ExceptionsPath` with caller-owned JSON outside this skill;
[Supporting files](references/supporting-files.md) defines the schema. No path grants
no exemptions; missing or invalid specified data fails closed.
Local asset edits fail the consumer manifest gate; see `references/ci-workflow.md`.

## Procedure

1. Identify mainline, visibility, workflows, roots, package scripts, deploy jobs, tests, and tools.
2. Classify backend, frontend, or hybrid; preserve existing automation and deployment behavior.
3. Apply the relevant references. Control surfaces include `ci.yml`, `mutation.yml`, Dependabot, Stryker support files, GitHub security settings, Dependabot security settings, AI-review policy, `.gitignore`, `review-policy-guard.yml`, `review-tier.yml`, and secret scanning. Tier both review workflows HIGH in `.claude/review-policy.json`.
4. Run actionlint first after checkout in substantive jobs; zero-authority gate-control jobs are exempt.
5. Keep Stryker outside per-commit CI: every mutation workflow has manual dispatch plus one staggered weekly UTC schedule.
6. PR cost envelope: 30 seconds per test, 10 minutes per substantive required job, and a 15 aggregate runner-minute target. Route extended coverage to weekly/manual jobs capped at 45 minutes; cap each mutation job at 30 minutes.
7. Never mutate GitHub settings or create secrets without approval. Public repositories enable free deterministic Code Quality, AI findings disabled; private/internal keep it off.

## Load-bearing checks

- No-deploy workflows cancel superseded branch runs but not main or tags; deploy workflows use `cancel-in-progress: false`.
- Backend CI is npm-free. Restore local tools and run `dotnet csharpier check .` before restore/build/test.
- End-to-end, stress/load/soak, repeated concurrency, slow packaging, and compatibility matrices never run in the required PR lane.
- `CI Gate` has `if: always()`, zero permissions, and needs every quality job. `Gate coverage` runs the shipped stdlib-only asset, asserting gate semantics.
- `review-policy-guard.yml` verifies the policy is tracked, uses `git check-ignore --no-index`, and runs `assert_workflow_hygiene.py` — which parses workflows, never greps them.
- Secret gates pin the gitleaks install and scan range *and* tree; sweeps use the TruffleHog detector allowlist.
- Tag-fired publish/deploy asserts ancestry of the default branch.
- Dependency manifests are not HIGH. Registry, SDK, analyzer, auth, migration, review controls, and the merge barrier are.

## Validation

Parse changed YAML/JSON; run actionlint, shipped tests, and `git add --dry-run .claude/review-policy.json`. Verify approved server-setting changes took effect. Commit or push only when requested.

Supporting files: [Script and test inventory](references/supporting-files.md).
