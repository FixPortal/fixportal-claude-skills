---
name: audit-azure
description: Use when the user wants an Azure estate evaluated for decisions that no longer hold, stale infrastructure reasoning, or unrecorded Azure decisions, or asks for the estate's decision register. Read-only. For Azure cost, use azure-cost-sweep.
---

# Audit Azure

Evaluate a whole Azure estate and answer one question for every decision it
embodies: is the reason for this still true?

Open `~/.agents/notes/deploy-and-ci-traps.md` by heading (if that note is absent, proceed and say so),
then read [references/runbook.md](references/runbook.md), before gathering evidence.

## Inputs

| Input | Default | Notes |
|---|---|---|
| Subscription name | none; ask | Resolved live. Scope is every enabled subscription in its tenant. |
| Estate root | none; ask | A folder of Git repositories. |
| Exclusions | none | Exact repository names. |
| Decision log | none | An optional source of reasons. Say so when absent. |
| Backups root | none | Pre-reset repository backups, searched when a repository's history is truncated. |

## Phases

| Phase | Produces |
|---|---|
| [1. Resolve](references/runbook.md#1-resolve-and-authenticate) | Login confirmed; repositories and their Bicep listed |
| [2. Inventory](references/runbook.md#2-inventory) | The evidence file, from `scripts/Get-AzureInventory.ps1` |
| [3. Join](references/runbook.md#3-join-live-resources-to-bicep) | Each resource declared, undeclared, or declared and not live |
| [4. Decisions](references/runbook.md#4-decisions-and-reasons) | Every decision, with its recorded reason and status |
| [5. Verdicts](references/runbook.md#5-verdicts) | One verdict per decision, with its observation |
| [6. Report](references/runbook.md#6-report) | An immutable report in the vault |

## Invariants

- The estate drives the audit. A decision log is a source of reasons, never the list of
  things to check.
- Every Azure read is `az rest --method get`; `az account list` reads only the local login.
  No POST, no Key Vault data-plane call, no cost query: the budget read is for the budget's
  definition only. A setting readable only by POST is `NotObserved`, kind `post-only`.
- No secret value and no personal data in the report.
- A failed read, an empty result and a throttled read are three findings. `NotObserved`
  never reads as clean.
- A resource is "not declared" only after the repositories were enumerated by literal path.
- An unrecorded reason is `Unknown`. A reconstruction needs the literal prefix `UNVERIFIED:`
  and what would refute it.
- Never assign `Backfilled` or `Default applied`; quote them from the decision log. Never
  promote either to `Recorded`.
- Never attribute a decision to the owner unless a record does. The wording is
  "agent proposed, owner approved".
- Terraform is checked only as a mirror of the Bicep.
- Change nothing: not Azure, not a repository, not the decision log. Remediation belongs to
  the owning repository in another session.
- No emoji.

## Stop rules

Stop and tell the user what to run when `az` is not logged in, the subscription cannot be
resolved, a top-level listing fails, or the evidence file cannot be written.

Continue past a failed resource or child read, a missing decision log or cost sweep log,
or a repository with no Terraform. Record each as not observed.

Supporting files: `scripts/Get-AzureInventory.ps1` (the inventory),
`references/child-reads.json` (which child settings it reads),
`references/runbook.md` (the procedure), `test/Inventory.Tests.ps1` and
`test/verify-contract.ps1` (run both in a sandbox).
