---
name: audit-dependabot-coverage
description: Use when checking for unactioned GitHub Dependabot alerts across an estate, including "is Dependabot keeping up", "any alerts without a PR", and "Dependabot coverage check". Complements audit-ci, which checks configuration rather than remediation outcomes.
---

# Audit Dependabot Coverage

Answer one question per repository: does each selected Dependabot alert have an open
Dependabot PR for the same package and target, or is it an unmatched alert requiring
human review?

<!-- routing: reconcile -->
```powershell
pwsh -File ~/.agents/skills/audit-dependabot-coverage/reconcile.ps1
```

This is an outcome check. `audit-ci` checks configuration; enabled and unpaused
security updates can still leave an alert unactioned. Investigation history lives
in trap 16 of `~/.agents/notes/npm-publishing-traps.md` (if that note is not present, proceed and record the assumption).

## Decision contract

<!-- routing: interpret-output -->
- Read-only: never dismiss alerts, open PRs, or close anything.
- Enumerate the live estate and all open Dependabot PRs without silent caps.
- Never report unread evidence as clean. API failures appear under NOT CHECKED with
  bounded stderr; response bodies are not trusted after a failed command.
- Match the package only at Dependabot's `Bumps`/`Updates` verb anchor. When alert
  manifest directory or ecosystem is known, the PR must agree. Ambiguous PR target
  context remains unmatched.
- Keep UNKNOWN security-update health separate from confirmed DISABLED or PAUSED
  health. UNKNOWN is evidence missing, not proof of an unhealthy setting.
- Emit every unmatched alert. Alerts inside the grace window remain individually
  visible in GRACED UNMATCHED ALERTS rather than disappearing from the result.
- Never self-triage by severity, age, scope, or rule family.

A package-name match is then narrowed by **directory and ecosystem**. In a monorepo a
PR bumping a package in `/web` says nothing about the same package's alert in `/api`.
The alert's target comes from `dependency.manifest_path`; the PR's from its branch
(`dependabot/<ecosystem>/<directory>/<update>`). When the PR's target cannot be
established the alert stays unmatched — unresolvable is not covered.

## Reading the output

Findings are alerts older than the grace window with no open Dependabot PR matching
their package, manifest directory, and ecosystem where known. Graced rows are the
same unmatched condition but are not findings yet. Each row still needs human review.

Dependabot's update-job log has no API: inspect it at Insights → Dependency graph →
Dependabot → the ecosystem row → Last checked.

Before accepting a "cannot update" verdict, inspect the parent's declared range:

```powershell
Select-String -LiteralPath package-lock.json -Pattern '"node_modules/<parent>"' -Context 0,3
```

A compatible parent range can permit a lockfile-only bump; trap 16 explains the
failure mode and investigation sequence.

## Options

| Flag | Purpose |
|---|---|
| `-Org` | Organisation or user to enumerate; repeatable. Default `YourOrg`. |
| `-Repo` | Explicit `owner/repo`; repeatable. Skips enumeration. |
| `-GraceHours` | Finding threshold. Default 48 hours. Use `0` when every unmatched alert must enter a parent audit ledger. |
| `-AlertState` | `open` (default), `fixed`, `dismissed`, or `auto_dismissed`. Historical states backtest emission, not past PR state. |
| `-Json` | Machine-readable output, including findings, graced unmatched alerts, unhealthy settings, and NOT CHECKED rows. |

Run after each repository's configured Dependabot schedules have had enough time to
produce PRs. Do not assume one universal estate schedule. This is not a SessionStart
hook because the live-estate API sweep adds avoidable startup latency.

Supporting files: Run `test/verify-matcher.ps1` for local contract checks.
