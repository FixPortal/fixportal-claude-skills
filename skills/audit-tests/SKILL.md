---
name: audit-tests
description: Use when a repository's test quality or adequacy is in question, when test gaps or false confidence need assessing, or when a verified prior audit must be reconciled against later code or test changes. Triggers include /audit-tests, "audit the tests", "test quality review", "test adequacy", "what tests are missing", "test gaps", and "delta test audit". Requires a git repository.
---

# Audit Tests

## Overview

Run a read-only, risk-based assessment of whether tests would catch material regressions. Coverage and mutation results are supporting evidence, never the verdict.

## Quick reference

| Phase | Action | Binding reference |
|---|---|---|
| Recon | choose Full/Delta, establish stack, scope, baseline, artefacts | [orchestration](references/orchestration.md) |
| Evidence | independent workers for applicable axes A–H | [axis brief](references/axis-brief.md) |
| Synthesis | map behaviours to effective tests; route finding kinds | [audit prompt](references/audit-prompt.md) |
| Verify | independently refute Critical/High gaps or closures | [verify/refute](references/verify-refute.md), [verify resolution](references/verify-resolution.md) |
| Report | additive vault report; no merge verdict | [orchestration](references/orchestration.md) |
| Approved fix | one approved slice at a time in review worktree | [fix slice](references/fix-slice.md), [stack conventions](references/stack-conventions.md) |

## Procedure

   <!-- routing: recon -->

1. Read [the orchestration runbook](references/orchestration.md). A missing/ambiguous/unverified Delta baseline, non-ancestor, or unbounded impacted surface means Full or stop—never a relabelled partial audit.
   <!-- routing: evidence-axes -->

2. Dispatch every applicable evidence axis with `axis-brief.md` verbatim plus its documented run context. Only worker H receives coverage/mutation artefact paths.
   <!-- routing: synthesis -->

3. Re-key findings by axis, verify file/line evidence, route `behaviour`, `suite-hygiene`, `measurement`, and `n-a` separately, apply exclusions, and build the seven-section report contract.
   <!-- routing: verify-refute -->

4. Independently verify every Critical/High backlog item and claimed Critical/High resolution/downgrade. Unusable verification retries once, then remains explicitly unverified.
   <!-- routing: report -->
   <!-- routing: approved-fix-slice -->

5. Write the additive report and stop in report-only mode. A fix pass begins only when requested and each slice is approved; use `review-worktree-pass`, demonstrate the new test can fail, run the full local gate, and let the orchestrator own git.

## Load-bearing rules

- Report mode never edits the audited repo. Subagents never commit, push, or open PRs.
- Delta traces changed symbols through callers, registrations, contracts, consumers, and tests; unchanged baseline material is not revalidated.
- Downstream harm is not confirmed without reading the consumer; unresolved host claims remain explicit.
- Every non-N/A claim has a `file:line` anchor. Read assertions; test names and coverage colour are not evidence.
- Timing evidence follows `scaffold-tests/references/async-and-timing.md`: prefer real signals and one generous diagnostic ceiling. `WaitAsync`/`CancelAfter` are valid under Aggressive or unknown xUnit scheduling. Static-now expiry/settlement data is not a timing defect, but is a separate hygiene finding when injected-clock/NodaTime rules are violated.
- CI eligibility follows `scaffold-tests/references/ci-test-budgets.md`: worker H inspects recent run and TRX durations, reports misplaced slow tests as suite-hygiene, and reports missing job caps or excessive matrix fan-out as measurement findings.
- Vault reports are additive and identify mode, audited HEAD, and Delta baseline/range.

Supporting files: Report validator `scripts/test-audit-report.ps1`; contract tests `test/verify-package-ids.ps1`, `test/verify-policy.ps1`, `test/verify-report-contract.ps1`.
