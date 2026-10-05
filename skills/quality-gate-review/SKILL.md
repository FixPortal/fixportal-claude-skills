---
name: quality-gate-review
description: 'Use when implementation and validation evidence are complete and the user asks for a merge/release verdict: "quality gate", "gate review", "should this merge", "is this ready to PR", "gate this", or /quality-gate-review. This skill classifies supplied evidence and known gaps.'
---

# Quality Gate Review

Apply the committed policy to supplied evidence; issue `PASS`, `PASS WITH CONDITIONS`, or `FAIL`. Do not redo adversarial review or search for additional defects.

## Required inputs

- Diff and changed files; PR/commit summary; current HEAD and author.
- Build, test, coverage, analysis, and relevant runtime results.
- Existing adversarial-review report, or an explicit absence.
- Repository standards and the relevant canonical traps note.
- Base-ref `.claude/review-policy.json` classifier result and current-HEAD reviewer/thread evidence.
- Composition review output from `composition-review`, or an explicit absence with reason. `N/A — no stateful or messaging path touched` is permitted under the step-6 condition.

Missing evidence is a named gap.

## Gate procedure

1. Classify supplied evidence across all eight domains in [the gate contract](references/gate-contract.md). Use `N/A — reason` where appropriate.
2. Apply the committed base-ref review policy mechanically; never self-classify or override it. No policy means `NORMAL`; unreadable policy or changed-file evidence means `UNCLASSIFIED` and `FAIL`.

   The hook is the only classifier; its `NORMAL` fall-through on a read error is a defect,
   not a tier. See `classifier-disagreement`.

   | Review Tier | Required current-HEAD evidence |
   |---|---|
   | `HIGH` | Gitar and CodeRabbit clean; no unresolved threads |
   | `NORMAL` | Gitar clean; CodeRabbit not requested; no unresolved Gitar threads |
   | `LOW` | AI review optional; any review that ran has no unresolved threads |

   Only dependency-bump PRs authored by `dependabot[bot]` or `renovate[bot]` are exempt from both AI reviewers, not from CI; control/config changes are not exempt. At any tier, a reviewer that ran must have no unresolved threads, and an explicit negative verdict blocks regardless of whether that reviewer was required. A missing, stale, skipped, rate-limited, or verdict-less required review is a **coverage gap** and blocks `PASS`.
3. Consume `adversarial-review` output using its owned contract: Phase 3 severity plus `[unanimous]`, `[majority]`, or `[contested]`; preserve any `mechanism refuted` re-rating. Record Phase 4 `CONFIRMED` / `REFUTED` / `INDETERMINATE` separately. There is no Dismissed bucket.

   Phase 4 decides where it spoke: `REFUTED` closes; `INDETERMINATE` stays open. Absent where its producer requires one: coverage gap.
4. Delegate GitHub finding-versus-ledger disposition mechanics to `ai-findings-ledger`; do not duplicate them here.
5. Run `ponytail:ponytail-review`. `Lean already. Ship.` is clear. Otherwise preserve every finding and `net: -<N> lines possible.`; any reported finding **blocks PASS** until fixed or explicitly accepted by the user. If the plugin is unavailable, perform and label a manual simplicity check.
6. Consume `composition-review` output: five questions, each answered `finding`, `clear`, or `N/A`. Any composition finding **blocks PASS** until fixed or explicitly accepted by the user. An unanswered question, or one answered without its own slot's support, is a **coverage gap** and blocks PASS the same way — absence of analysis is not an all-clear. `N/A — no stateful or messaging path touched` leaves nothing to answer **only when the gate did not emit `COMPOSITION REVIEW REQUIRED`**.
7. Apply the verdict rules and output template in [the gate contract](references/gate-contract.md). Conditions must be specific and verifiable.

Never override the AR judge, infer clean reviewer silence, or issue `PASS` with an unclassified tier or required coverage gap.

Supporting files: `test/verify-ar-vocabulary.ps1`, `test/verify-verdict-matrix.ps1`.
