---
name: azure-cost-sweep
description: Use when the user asks why Azure spend is high, wants repo-aware cost reductions or right-sizing, or wants to verify that a prior Azure saving survived later deployments. Supports one repository or a folder of repositories; prefer this over bill-only tooling when code or IaC is in scope.
---

# Azure Cost Sweep

Reconcile live Azure spend with the code and IaC that require it. Produce a
ranked, risk-annotated report; make no changes.

Read `~/.agents/notes/deploy-and-ci-traps.md` (if that note is not present, proceed and record the assumption), then read
[references/runbook.md](references/runbook.md) before gathering evidence.

## Quick Reference

| Stage | Required evidence |
|---|---|
| Prior run | ICM, prior vault log or the first-run record, IaC history, on-disk audits |
| Live estate | Paged Cost Management query, resources, Advisor candidates |
| Drift | Resolved IaC names, deploy path, activity-log writers |
| Requirements | Code/IaC proof for every tier-gated capability |
| Right-size | Utilisation over the same stated window as cost |
| Price | GBP Retail Prices response; bill remains source of truth |
| Persist | Additive decision log with outcome and IaC persistence |

## Invariants

- Determine the [prior-run or first-run branch](references/runbook.md#0-prior-runs-and-drift)
  before drafting recommendations. A reverted saving outranks a new optimisation.
- For a later run, run prior-sweep/drift reconciliation before drafting
  recommendations.
- Never recommend a cheaper tier until code proves the dropped capability is
  unused, or explicitly price and risk the code change that removes it.
- Never infer cost from IaC or size from the SKU name; query live cost and
  utilisation.
- One metrics window drives the analysis. Report actual returned timestamps
  and retention truncation.
- Separate safe-now savings from change-required savings.
- `REALISED` requires both committed owning IaC and live verification after a
  deployment. A successful live update alone is not banked.

## Modes and completion

Default to the current repository. For a parent folder, enumerate top-level Git
repositories with exact-name exclusions, persist one runbook item per repo, and
reuse subscription cost data across attribution.

Completion is one report per repo plus a cross-repo roll-up in sweep mode. Each
report cites billed GBP, code requirements, recommendation, saving, risk, and
prerequisite, then writes an additive timestamped, immutable decision log to the vault.

Stop when evidence required by the selected prior-run/first-run branch is
unavailable, a recommendation lacks code proof, or an apply-only change is being
counted as realised.

**Incomparable metrics scope the stop, they do not end the sweep.** Withhold only the
sizing recommendation that depends on the affected series, mark the omitted period
`UNVERIFIED`, and continue under the runbook's conservative default. A
retention-truncated series used to satisfy both this skill-wide stop and the runbook's
"mark it UNVERIFIED and default conservatively" instruction at the same time, so the same
reachable scenario executed differently per operator and per runtime.

Supporting files: Run `test/verify-contract.ps1` for local contract checks.
