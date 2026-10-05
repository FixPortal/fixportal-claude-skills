---
name: remediate-dotnet-performance
description: Use when running exactly one explicitly approved, measured remediation experiment for an unresolved .NET performance audit finding.
---

# Remediate .NET Performance

Run one causal experiment only after the user explicitly approves its exact unresolved `PERF-NNN` finding and proposed change. A sweep, urgency, or approval of another finding is not approval. Do not commit, push, open a PR, merge, deploy, or alter a CI gate without separate authority.

**A finding is identified by manifest path plus ID, never by ID alone** — `PERF-NNN` is
unique only within one manifest, so a second audit of the same repository publishes its own
`PERF-001` and an approval naming "PERF-001" names two things. **Check the experiment
records for that manifest-and-ID before proposing anything**: the manifest's
`resolutionState` is immutable, so a finding whose experiment already ran and was REJECTED
still reads `unresolved` and is otherwise re-runnable on the very evidence that rejected
it. An `accepted` or `rejected` record closes it; reopening needs an explicit statement of
why the earlier evidence no longer holds.

Commands may run from the target repository; resolve `~/.agents/skills/` to the canonical skills home before invoking PowerShell scripts.

Before any target-repository mutation, run the identity gate with its **full invocation**.
`-Path` is mandatory, and an unsupplied mandatory parameter under a non-interactive host is
a hang rather than an error:

```powershell
pwsh -NoProfile -File ~/.agents/skills/audit-dotnet-performance/scripts/test-performance-manifest.ps1 -Path "<vault>\Claude\Performance Audit\<repo>\<run>\manifest.json" -Mode Finding -FindingId PERF-NNN
```

The manifest lives in the audit's published vault folder — `report-contract.md` defines
that layout — not in the target repository. Confirm its repository identity and audited
HEAD. If HEAD, dependencies, runtime, configuration, workload, or the attributed mechanism
drifted, stop for re-baselining or a fresh audit decision.

Use only `<repo>\.claude\worktrees\performance-experiments` on a branch such as `performance/perf-001-short-slug`. Inspect `git worktree list` and that worktree's status first. If it is occupied or has uncommitted work, stop until that experiment is completed or explicitly abandoned; never create a second performance-experiment worktree.

Read [the experiment runbook](references/experiment-runbook.md) before changing product code. Read [the change-record templates](references/change-record.md) when recording evidence or an accepted result. Keep Git operations explicit and reversible. Run the boundary gate on the candidate diff, with both mandatory parameters:

```powershell
pwsh -NoProfile -File ~/.agents/skills/audit-dotnet-performance/scripts/test-managed-product-boundary.ps1 -RepositoryPath "<experiment-worktree-root>" -BaseRef "<branch-point-sha>" -ProductPath src
```

**"It must pass" means `passed: true` in the JSON, plus a recorded disposition for every
warning** — not exit 0. Exit 0 means the audit COMPLETED, boundary violations included;
exit 2 means it could not run at all, which is a stop, not a pass. Read the verdict, not
the exit code.

After the candidate's focused correctness checks, A/B workload, and boundary check, run the repository's applicable normal build, test, lint, and analyzer gates. Record every command and result. Any failure makes the result non-accepted; do not waive or weaken a normal gate for performance.

Accepted product code uses only supported public managed APIs and existing approved managed dependencies. Do not accept `unsafe`, runtime intrinsics, native/interop paths, or new native dependencies. When EF Core is involved, invoke `ef-core`; for EF Core raw SQL/model/query shapes, Wolverine, or SignalR lifecycle work, read `~/.agents/notes/dotnet-runtime-traps.md` (if that note is not present, proceed and record the assumption). For stateful, concurrent, or messaging paths, invoke `composition-review` before acceptance.

Supporting files: Run `test/verify-contract.ps1` for local contract checks.

## Acceptance checklist

- [ ] Manifest path and finding ID match the explicit approval; no accepted/rejected experiment already closes it.
- [ ] Audit identity and HEAD are current; dedicated experiment worktree is free.
- [ ] Focused correctness checks and the A/B workload complete with recorded evidence.
- [ ] Boundary JSON says `passed: true`; every warning has a disposition.
- [ ] Repository build, tests, lint and analyzers pass; composition review runs when applicable.
- [ ] Record accepted/rejected outcome before any separately authorized publication.
