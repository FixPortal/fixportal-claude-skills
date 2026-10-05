# Experiment records

Write every experiment record outside the target repository beside its audit, at `<vault>\Claude\Performance Audit\<repository>\YYYY-MM-DD-HHmm-PERF-NNN-experiment.md`. Retain raw artefacts at their approved external locations; record paths and hashes rather than copying aggregate diff packages or executable artefacts.

```markdown
# PERF-NNN experiment — accepted | rejected | inconclusive | blocked

- Finding and approval: `PERF-NNN`; audit path; quoted/linkable explicit approval for this exact experiment
- Identity: audited commit; baseline commit; candidate commit/worktree branch; target status before/after
- Hypothesis and scope: attributed mechanism; one approved product-code change; expected trade-offs
- Workload: baseline and candidate commands; inputs/hashes; build/configuration; warm-up, repetitions, duration, diagnostics
- Environment: SDK/runtime; OS/architecture; CPU/resources/power; GC/tiering; dependency/configuration identity
- Raw artefacts: external paths, hashes, producer commands, retention/sensitivity
- Correctness: baseline and candidate commands/results; protected invariants; any new focused test
- Normal gates: applicable repository build, test, lint, and analyzer commands/results; any failure makes the result non-accepted
- Results: distributions/statistics; variance/noise; practical materiality threshold; resource displacement
- Cost: measurement cost; engineering/operational cost; supplied commercial inputs or `currencyCost: unknown`
- Boundary: `test-managed-product-boundary.ps1` command, JSON result, each warning's explicit disposition, and manual diff review
- Outcome and rationale: accepted, rejected, inconclusive, or blocked; causal plausibility; limitations; for blocked, the missing tool/environment/authority/correctness seam
- Cleanup: candidate retained or exact experiment-owned paths removed; external evidence preserved
- Benchmark retention: separate approval evidence, stable material hot-path rationale, or `not approved`
```

For accepted results only, add or update `docs/performance/YYYY-MM-DD-<sweep>.md` in the target repository after acceptance:

```markdown
# Performance sweep — YYYY-MM-DD

- Accepted finding: `PERF-NNN`; approval evidence; audited/baseline/candidate commits
- Change and rollback: causal change, behavioural surface, rollback path
- Evidence: commands, environment, raw external artefacts/hashes, focused correctness and normal build/test/lint/analyzer results, statistics/noise, materiality, costs
- Boundary and review: boundary JSON result, manual-review disposition, limitations and displaced costs
- Benchmark: separate retention approval and stable material hot-path rationale, or `not retained`
```

Rejected, inconclusive, and blocked experiments remain external records only. This documentation does not authorize a commit, push, PR, merge, deployment, or CI performance gate.
