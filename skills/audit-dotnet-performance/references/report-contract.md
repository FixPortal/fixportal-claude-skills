# Report contract

## Contents

- [Report order](#report-order)


Write additive reports and manifests beneath `<vault>\Claude\Performance Audit\<repository>\` using:

```text
YYYY-MM-DD-HHmm-<scope>-performance-audit.md
YYYY-MM-DD-HHmm-<scope>-performance-audit.manifest.json
YYYY-MM-DD-HHmm-PERF-001-experiment.md
```

Draft exactly `report.md` and `report.manifest.json` in a unique `.staging-*` child of the destination repository directory. Publish with `scripts/publish-performance-audit.ps1 -StagingDirectory <path> -DestinationDirectory <path> -Stem <YYYY-MM-DD-HHmm-scope-performance-audit>`. The helper validates both files, rejects unrelated staging contents, serializes suffix selection and publication with `.performance-audit-publish.lock`, chooses the lowest available deterministic pair suffix (`-02`, `-03`, ...), moves the same-stem pair, and removes only that invocation's staging directory after success. It preserves staging evidence when validation or publication fails. Never overwrite an existing file or manually clean another invocation's staging directory; remove a stale publication lock only after confirming no publisher is running.

## Report order

**These fourteen lines are the report's level-2 headings, verbatim, including the `## N.`
prefix.** Each appears once, in this order, and the report carries no other `##` heading;
`Test-Report` in `scripts/test-performance-manifest.ps1` compares them exactly. Stated because
"report order" alone left it open whether these were headings or a summary of topics, and a
validator or a reader comparing two audits has nothing to compare if each names its sections
differently. Under section 8, give each finding all four costing views.

```text
## 1. Orientation and executive summary
## 2. Repository, scope, and authority boundaries
## 3. Workload contracts
## 4. Environment and reproducibility ledger
## 5. Tool and source ledger
## 6. Baseline results
## 7. Attributed hotspot map
## 8. Costed findings
## 9. Rejected and inconclusive experiments
## 10. Recommended experiment order
## 11. Unassessed dimensions and fidelity gaps
## 12. Repository-state preservation evidence
## 13. Artifact ledger
## 14. Remediation manifest
```

When a reusable external harness should enter source, add this small table under section 10, outside the `PERF-NNN` remediation lifecycle:

| Retained source | Cases worth keeping | Fixture dependencies | Stability caveats | Proposed destination | Source-change workflow |
| --- | --- | --- | --- | --- | --- |

Omit the table when no harness promotion is recommended.

The artifact ledger records each raw trace, benchmark output, supplied production artifact, and other retained input/output by path, SHA-256 hash, producing command, sensitivity, retention state, and required analysis tool. Do not copy, modify, or delete supplied production artifacts. A missing artifact or hash is a fidelity gap, not implied evidence.

Record the target repository's before and after Git state. A published finding ID has the immutable form `PERF-NNN`; publish every audit finding with immutable `resolutionState: "unresolved"`. A later remediation invocation records user approval separately and must not rewrite the audit manifest.

**`PERF-NNN` is unique only WITHIN one manifest, so it does not identify a finding.** A
second audit of the same repository publishes its own `PERF-001` into the same vault
folder and both validate, so a user approval naming "PERF-001" names two things. Qualify
every approval, experiment record and cross-reference by **manifest path plus finding ID**,
never the ID alone.

And because the manifest's `resolutionState` is immutable, a finding stays `unresolved`
forever — including one whose experiment was already run and REJECTED. Resolution lives in
the experiment records, so **look there before proposing an experiment**: an
`accepted` or `rejected` record for that manifest-plus-ID closes the finding, and
re-running it needs an explicit reopen naming why the earlier evidence no longer holds.
Without that look-back, an already-rejected experiment reads as open and is re-runnable on
exactly the evidence that rejected it.

New publications use schema v2. The validator continues accepting immutable v1 publications, but new v1 output is non-conforming. The v2 minimum shape is:

```json
{
  "schemaVersion": 2,
  "repository": { "path": "...", "head": "...", "branch": "..." },
  "audit": { "startedUtc": "...", "completedUtc": "...", "mode": "repository", "targetStateUnchanged": true, "depth": "Measured" },
  "workloads": [
    {
      "id": "request",
      "status": "Completed",
      "representativeMetrics": ["p95 20 ms", "2.1 KB allocated/op"],
      "stability": "Stable",
      "harnessDisposition": "Promote",
      "harnessPromotion": {
        "retainedSource": "<artifact-root>/request-harness",
        "cases": ["Representative request"],
        "fixtureDependencies": ["Local PostgreSQL"],
        "stabilityCaveats": [],
        "proposedDestination": "benchmarks/Request.Benchmarks",
        "sourceChangeWorkflow": "Normal reviewed repository change"
      }
    }
  ],
  "findings": [
    {
      "id": "PERF-001",
      "title": "...",
      "classification": "Observed bottleneck",
      "confidence": "High",
      "resolutionState": "unresolved",
      "evidence": ["..."],
      "project": "src/Example",
      "files": ["src/Example/HotPath.cs"],
      "symbols": ["HotPath.Execute"],
      "workload": { "id": "request", "baseline": "p95 20 ms" },
      "attributedMechanism": "...",
      "proposedExperiment": "...",
      "correctnessInvariants": ["..."],
      "expectedTradeoffs": ["..."],
      "materialityThreshold": "...",
      "commands": { "baseline": "...", "candidate": "..." },
      "requiredTools": ["..."],
      "requiredArtifacts": ["..."],
      "cost": { "inputs": ["..."], "missingInputs": ["..."] },
      "productBoundary": {
        "allowed": "managed-public-api",
        "exclusions": ["unsafe", "System.Runtime.Intrinsics", "DllImport", "LibraryImport", "PInvoke", "native binaries", "native-dependent packages", "custom native allocators", "undocumented runtime switches", "runtime-private APIs", "reflection/runtime patching"]
      },
      "acceptanceConditions": ["..."],
      "rejectionConditions": ["..."],
      "rollbackExpectation": "..."
    }
  ]
}
```

`audit.mode` is exactly `repository` or `artifact`, and it decides one other field.
`targetStateUnchanged` is a repository-mode preservation proof: in `repository` mode it is
required and must be `true`, except a preservation failure may be published with
`targetStateUnchanged: false` only when `audit.depth` is `Blocked`, `audit.preservationFailure`
is a non-empty explanation, and `findings` is empty. This records why the audit stopped
without claiming the target was preserved. In `artifact` mode `targetStateUnchanged` must be ABSENT, because step 1's
captures are repository-mode only, so there is no baseline to compare against and any
value there asserts a proof that was never constructed. An omitted `mode` reads as
`repository`, which keeps every existing v1 and v2 manifest valid — but a new artifact-mode
manifest must state it, since absence cannot distinguish the two.

`audit.depth` is exactly `Measured`, `Characterized`, `Surveyed`, or `Blocked`. Every attempted or unavailable workload has one outcome. `status` is exactly `Completed`, `Unstable`, `Unavailable`, `Blocked`, `Not run`, or `Not required`; `representativeMetrics` may be empty unless status is `Completed`; `stability` is exactly `Stable`, `Unstable`, `Mixed`, `Not assessed`, or `Not required`; and `harnessDisposition` is exactly `Existing`, `Promote`, `Retained external`, `Not needed`, or `Rejected`. A `Promote` disposition requires the complete `harnessPromotion` object shown above. Use `status: "Not required"`, `stability: "Not required"`, and `harnessDisposition: "Not needed"` when the audit establishes there is no material performance workload or contract; its basis must start `No benchmark required:` and explain that decision. This is a completed scope decision, not a gap. Use `Not assessed` only when an applicable dimension could not be evaluated. A `Not required` outcome has no metrics and no harness promotion.

**Every disposition other than `Promote` states its basis in `harnessDispositionBasis`,
a required one-sentence string on that workload.** `Promote` is the only value that
carries a mandatory object, which made it the only expensive answer — and the three
cheapest exits (`Not needed`, `Existing`, `Retained external`) all avoided filling in
promotion detail while asserting something about the world that nobody had to evidence.
The field is required exactly when `harnessDisposition` is not `Promote`, so there is now
somewhere to put it and the validator enforces that it is filled. What each must say:

- **`Not needed`** — why this workload will not be re-measured. Name what makes a
  regression here detectable without a harness (an existing assertion, a budget already
  enforced in CI), or say the workload is not on a path whose performance is a
  requirement. "No harness was written" is a description of the audit, not a basis.
- **`Existing`** — WHICH harness, by path and case name, and the evidence it covers this
  workload: a run, or the case's own name matching the measured scenario. An `Existing`
  that names nothing is indistinguishable from `Not needed` with better manners.
- **`Retained external`** — where the harness now lives and how it stays reachable. A
  path on the auditing machine is not retention; anyone reading the manifest later must be
  able to find it.
- **`Rejected`** — what disqualified it: instability that survived the stability protocol,
  a fixture that cannot be reproduced, cost out of proportion to the signal.

Every finding is a complete one-experiment handoff. `evidence`, `files`, `symbols`,
`correctnessInvariants`, `expectedTradeoffs`, `productBoundary.exclusions`,
`acceptanceConditions`, and `rejectionConditions` are non-empty text arrays.
`evidence` appeared in neither list while the closing sentence below declared
everything unlisted a scalar, so a manifest written from this prose failed
validation: `test-performance-manifest.ps1` calls `Require-TextArray` on it.
`requiredTools`, `requiredArtifacts`, `cost.inputs`, and `cost.missingInputs`
are required text arrays and may be empty only when that is the evidenced
state. All other shown finding values are required scalar text or objects.
`proposedExperiment` is one scalar description, never a list. `commands`
contains the exact comparable baseline and candidate commands. `workload`
records its stable ID and baseline identity. `productBoundary.allowed` is
exactly `managed-public-api`; `productBoundary.exclusions` must contain this
canonical minimum vocabulary: `unsafe`, `System.Runtime.Intrinsics`,
`DllImport`, `LibraryImport`, `PInvoke`, `native binaries`,
`native-dependent packages`, `custom native allocators`, `undocumented runtime
switches`, `runtime-private APIs`, and `reflection/runtime patching`.
Target-specific text exclusions may be added. The validator rejects missing,
wrongly typed, or incomplete handoff fields; it does not mutate the manifest.

Only production artifacts supplied by the user may support production-correlated evidence; never attach to a live production process.
