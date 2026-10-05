# Supporting files

Paths below are relative to the scaffold-ci skill directory.

The drift sweep accepts optional `-ExceptionsPath <caller-owned-json>` outside this
skill directory. Keep private estate identities in that caller's repository or
configuration, never under a mounted skill. The schema is:

```json
{
  "version": 1,
  "localImplementations": { "review-tier.yml": ["example-local-classifier"] },
  "sanitisedRepublications": ["example-public-mirror"]
}
```

Use immediate repository directory basenames. All three keys are required; unknown
keys, assets without declared variance, non-array lists, invalid basenames, missing
specified files and malformed JSON fail closed. An omitted path uses empty lists:
local classifiers are compared normally and republications are swept. The built-in
branch-line mask remains unchanged. Existing estate callers must migrate their
local-classifier and republication exemptions into this file and pass its path on
every invocation. Excluding a republication requires a separate behavioural
equivalence check (`scripts/compare-asset-semantics.py`); table output names each
exclusion, while JSON output contains only swept repositories as before.

Read `scripts/canonical-assets.json` for asset identities; run `scripts/sync-canonical-asset-manifest.ps1`, `scripts/rollout-canonical-asset-gate.ps1` and `scripts/sweep-canonical-asset-drift.ps1` for their named sync, rollout and drift operations; `scripts/compare-asset-semantics.py` compares asset semantics. Run `test/verify-asset-drift-sweep.ps1`, `test/verify-canonical-assets.ps1`, `test/verify-compare-asset-semantics.ps1`, `test/verify-gate-coverage.ps1`, `test/verify-review-control-plane.ps1`, `test/verify-rollout-canonical-asset-gate.ps1`, `test/verify-secret-scanning.ps1`, `test/verify-security-visibility-policy.ps1`, `test/verify-skill-layout.ps1`, `test/verify-stryker-summary.ps1`, `test/verify-workflow-hygiene.ps1` for local contract checks.
