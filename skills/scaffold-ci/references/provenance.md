# CI policy provenance

This appendix records dated measurements and incidents behind the actionable contracts.
The owning references remain authoritative for what to implement.

## Review guard and workflow hygiene

An automated rollout once emptied review-policy files across 21 repositories. The first
two-check guard still passed because an empty file remained tracked and unignored; the
shipped guard was expanded to validate JSON shape and load-bearing HIGH paths.

Workflow hygiene began as grep rules. On a pilot repository, patterns matched the
comments explaining themselves; later exclusions also misread quoted values, list-form
triggers, and digest pins. The stdlib parser replaced those greps on 2026-08-24.

A 2026-08 review-budget sample found 27 config-only diffs among 100 recent HIGH PRs but
only four actionable CodeRabbit comments, while 45 PRs received no verdict after the
account reached 73 reviews in seven days. Mechanical workflow checks replaced the broad
HIGH glob. A later review found the merge-barrier paths NORMAL in six repositories,
which is why those exact files remain HIGH.

## Mutation score correction

Before 2026-08-13 the summary used `killed / (total - ignored)`, omitting Timeout from
the numerator while retaining CompileError and RuntimeError in the denominator. One
backend report moved from 52.6% to 64.9% with no suite improvement. Two
identical-code classifier runs then scored 84.9% and 87.9%, with 63 of 892
mutants changing status in both directions; this is why threshold re-baselining needs two
runs.

## Canonical asset divergence gate

2026-09-20: a consuming repository's remediation hardened its local `assert_gate_coverage.py`
and, in closing two real CI-gate bypasses, reversed a rule canonical's own contract test
asserted in terms. Both existing controls behaved correctly and missed it: the drift sweep
answers content presence on a schedule in another repository, and the contract test lives
only in the canonical repo. Promoting the hardening to canonical red 18 of 28
passing repositories on the `${{ }}`-in-gate-body refusal; the estate migrated to the
`env:` hoist across 16 merged PRs. The response is the divergence gate: a committed
`.github/canonical-assets.json` per consumer, verified by `assert_canonical_assets.py` in
the existing `gate-coverage` job, so a local edit to a canonical asset fails at PR time
unless the manifest is regenerated in the same PR. The comparison is local-only by design,
so a legitimate canonical bump cannot red-line the estate — the lesson of that
estate-wide red. The design record lives with the canonical skills repository.
