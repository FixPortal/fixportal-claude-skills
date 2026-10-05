---
name: audit-dotnet-performance
description: Use when measuring, profiling, costing, or planning performance work for a .NET repository without changing product code.
---

# Audit .NET Performance

Read-only audit: establish evidence and publish unresolved findings; remediation belongs to `remediate-dotnet-performance`.

## Scope and authority

Fully support libraries, ASP.NET Core services, workers, and CLI applications. Treat desktop/mobile projects and .NET Framework as survey or existing-benchmark support only.

Use either repository mode (inspect a target repository) or supplied-production-artifact mode (interpret only artifacts the user supplied). Production evidence is supplied-artifact-only: this audit never attaches to or collects diagnostics from live production, regardless of approval. Process dumps and GC dumps are outside v1, including controlled non-production processes. Never mutate the target repository: no edits, branches, commits, pushes, pull requests, deployments, configuration changes, resets, stashes, or cleanup.

An ephemeral harness or pinned diagnostic-tool install needs explicit approval before it is created or installed. Approval may cover one harness or one enumerated batch that names every repository, harness purpose, allowed dependency, and isolated temporary root. Before creating each batched harness, verify it still matches that approval; a new repository, purpose, dependency, or location needs fresh approval. Use newly created isolated temporary directories outside target repositories; never install globally or add a repository-local tool manifest. Keep raw artifacts outside those repositories too, unless a repository already owns that benchmark-artifact convention.

## Audit flow

   <!-- routing: capture-state -->

1. In repository mode, capture the repository root (`git rev-parse --show-toplevel`), HEAD (`git rev-parse HEAD`), branch (`git branch --show-current`), and the exact bytes of `git status --short --untracked-files=all` — **the body, without `--branch`**, whose header carries ahead/behind and flips on an IDE background fetch during a multi-minute benchmark, failing the proof over something that is not a mutation. Capture a CONTENT fingerprint alongside it: `git diff` **and `git diff --cached`** over tracked files, plus a hash of each untracked file **under the audit's own working directories** — the same scope step 5 compares against. Bare `git diff` compares the worktree against the INDEX, so it cannot see an index-to-`HEAD` change: a file staged before the run, whose worktree copy still matches the index, leaves both the status bytes and the unstaged diff identical while its tracked content differs from `HEAD`. That is precisely the shape the fingerprint exists to catch, and it is invisible without the staged half. Capturing every untracked file in the tree while step 5 blocks only on changes under those directories is two scopes for one proof: a scratch file the operator saved elsewhere mid-run then changed the fingerprint and failed a comparison the rule says should pass. Status bytes are identical whether or not an already-dirty tracked file, or an untracked file keeping its name, had its contents rewritten during measurement — status reports which paths differ, never what they contain, so status equality alone cannot prove preservation. Then run `scripts/inventory-dotnet-performance.ps1 -RepositoryPath` before choosing measurement depth. Do not build, run, or install during inventory. If `projectInventoryComplete` is false, treat its stopping condition as `Incomplete` and stop before workload selection.
   <!-- routing: select-workload -->

2. Decide whether measurement is required before selecting a workload. If inventory finds no materially performance-sensitive path, performance contract, or plausible scale risk, record **No benchmark required** with its concrete basis and stop the measurement branch. This is a completed scope decision, not `Unmeasured`, `Not assessed`, or a compliance gap. Otherwise choose a representative workload: prefer an existing benchmark, first checking its design; then an existing test or executable workload. In artifact mode, first establish provenance and whether the supplied artifacts can be interpreted safely. Without repository path and identity, analysis is contextual only and stops before a remediation manifest; actionable publication requires repository identity and artifact provenance, but not a repository preservation proof. Read [workload and measurement](references/workload-and-measurement.md) when selecting a workload or measuring it.
   <!-- routing: measure-and-attribute -->

3. Obtain or verify the approval above before any external harness or pinned temporary tool. Establish correctness and a baseline, then measure and attribute. Static best-practice observations are explicitly unmeasured hypotheses until linked to a workload and measurement plan; they are not optimisation recommendations.
   <!-- routing: cost-candidates -->

4. For every measurable candidate, read [costing](references/costing.md) and report performance delta, measurement cost, engineering/operational cost, and commercial impact. Cost only supported evidence; currency remains unknown unless every required input was supplied.
   <!-- routing: classify-and-publish -->

5. Prepare classifications and draft report/manifest content using [the evidence contract](references/evidence-contract.md), including negative, neutral, and missing evidence. Record every attempted workload in the v2 manifest even when `findings` is empty; production evidence uses its exact `Production-correlated` classification. **In repository mode**, recapture the same root, HEAD, branch, status body and content fingerprint — at the SAME scope step 1 used, staged half included — then compare all five. Any tracked change, or any untracked change under the audit's own working directories, makes the audit `Incomplete`: stop, preserve evidence, and never clean up the target. Publish a `Blocked`-depth manifest recording the preservation failure rather than nothing at all — an audit that publishes nothing reads to the estate sweep as a repository that was never audited, and gets dispatched again into the same condition.

   **In repository mode only**, before publication, run `scripts/test-managed-product-boundary.ps1` with the
   captured repository root and initial HEAD as `BaseRef`. Preserve its JSON in
   the evidence. A `passed: false` result is a boundary finding requiring manual
   disposition; an invocation error makes the audit `Incomplete`.

**In artifact mode there is no baseline**, because step 1's captures are repository-mode only: skip this comparison entirely, set `audit.mode: "artifact"` and OMIT `targetStateUnchanged`. The validator enforces exactly that pairing — present and true in repository mode, absent in artifact mode — so the manifest states which run it was instead of leaving a reader to infer it, and an artifact-mode run following this instruction can actually publish. Requiring the byte-compare unconditionally left the operator improvising a baseline at the start of an artifact-mode run or publishing a preservation proof that was never constructed.

Only then read [the report contract](references/report-contract.md), validate the paired Markdown and manifest, and publish them through `scripts/publish-performance-audit.ps1`.

Stop and report rather than infer or continue when the build fails, the benchmark is unstable, no representative workload is safe, attribution is missing for a claimed bottleneck, supplied production artifacts cannot be safely interpreted, or the target tree changed. An audit only publishes or proposes experiments; hand implementation to `remediate-dotnet-performance`. Do not enter a target worktree or change product code or configuration during this audit, even with separate approval. Do not automatically commit, open a PR, deploy, or add a CI gate.

Supporting files: Run `scripts/test-performance-manifest.ps1` to validate the published manifest before accepting its findings. Run `test/verify-boundary-wiring.ps1`, `test/verify-contract.ps1` for local contract checks.
