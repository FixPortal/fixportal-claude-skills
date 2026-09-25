# CI exclusions and common mistakes

Use this as the final normalization checklist.

## Not house standard — do not add unprompted

An unaided agent tends to reach for these. They are NOT part of the house standard; add only
if explicitly asked:
- A committed CodeQL/`codeql-action` workflow (use default setup instead).
- `actions/dependency-review-action` PR gate.
- A separate `tsc --noEmit` step (the `build` script already type-checks via `tsc -b`).
- `--collect:"XPlat Code Coverage"` / coverage gating in `ci.yml`.
- Node setup or a publish-verify step in the backend job.
- An unconditional `cancel-in-progress: true` (it cancels `main`/tags too) — gate it on
  `github.ref != 'refs/heads/main'`, and use flat `false` only on a deploy repo.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Flat `cancel-in-progress: false` on a no-deploy repo | `${{ github.ref != 'refs/heads/main' }}`; flat `false` only when a deploy job needs protecting. |
| `cancel-in-progress: true` unconditionally | Cancels main/tags too. Gate on `github.ref != 'refs/heads/main'`. |
| Dead `workflow_dispatch` `environment` input | Bare `workflow_dispatch:` unless a deploy job reads `${{ inputs.environment }}`. |
| Believing `version:` on `raven-actions/actionlint` is invalid | It is valid — actionlint's own semver, defaulting to `latest`. The action-ref SHA pins the *action*, not the actionlint *binary*. Omit it to take the default, or set an explicit semver if you want the binary reproducible too. |
| Push builds every branch alongside `pull_request` | Push only mainline + tags `v*`; let `pull_request` cover branches. |
| Stale `@v4` pins | checkout@v7, setup-dotnet@v6, setup-node@v7, upload-artifact@v7. |
| Tag-pinning `raven-actions/actionlint` | Third-party — pin the full commit SHA with a `# v2` comment; semgrep's edit hook flags a floating tag. |
| No actionlint in a substantive job | Make it the first validation step after checkout; zero-authority gate-control jobs are exempt. |
| Node added to backend job | Backend CI is npm-free; frontend build is publish-only. |
| No CSharpier gate, or CI runs `format` | After .NET setup run `dotnet tool restore`, then `dotnet csharpier check .`; never mutate source in CI. |
| Required PR job has no timeout or exceeds ten minutes | Set `timeout-minutes: 10`; move extended coverage to weekly/manual. |
| Slow test is retried after timeout | Do not retry; make it bounded, optimize it, or move it to the extended lane. |
| E2E, stress/load/soak, or compatibility matrix runs on every PR | Use a separate project/list in one weekly/manual extended workflow capped at 45 minutes. |
| Formatting repeated in publish/deploy | Make those jobs depend on the backend gate; check once. |
| Stryker as a `ci.yml` job, a push/PR trigger, or a manual-only workflow | Separate `mutation.yml` with `workflow_dispatch` plus one staggered weekly UTC schedule. |
| Job/step `continue-on-error` to keep score informational | Remove it and use `break: 0`; execution/report failures must be red. |
| Missing report only warns | Make the summary throw and set report upload `if-no-files-found: error`. |
| Copying another repo's mutation cron | Stagger weekly UTC slots across the estate. |
| `test-runner: mtp` beside `test-case-filter` | Remove the inert filter and scope the lane by test-project structure; do not switch xunit.v3 to VSTest merely for filtering. |
| Trusting a Stryker score without checking discovery | Compare `Number of tests found` with the intended lane and require a non-zero `Killed` count on known-tested code. |
| npm dependabot `directory: /` | Point at the actual package.json folder. |
| Vite/vitest left in a minor/patch catch-all | Add a `vite-toolchain` group above it that admits major updates. |
| Private package feed declared only in `nuget.config` | Add a Dependabot secret plus a referenced `registries:` entry. |
| Committing a `codeql.yml` | Public: use default setup. Private/internal: keep CodeQL disabled under the paid-product policy. |
| Dependabot alerts or automated security fixes left off | Enable and verify both repository settings. |
| `.claude/` ignored as a directory | Use `.claude/*` plus negations for `!.claude/review-policy.json` and `!.claude/ci-budget-approval.json`, then run `git add --dry-run` on both files. |
| Copying another repo's `low` globs into `review-policy.json` | `low` means "unreachable from every deploy path **in this repo**" — re-derive it from this repo's own deploy jobs. |
| `**/*.md` in `low` on a repo that publishes markdown | Docs sites, content-driven frontends and skill repos ship their `.md`; there it is NORMAL, not LOW. |
| `auto_review.enabled: true` in `.coderabbit.yaml` | Reviews every PR regardless of tier, so `review-policy.json` decides nothing. Set `false` **and** add `labels: ["review-high", "review-high-manual"]`. |
| `enabled: false` with no `labels` list | Worse than leaving it on: the gate's `review-high` and manual override `review-high-manual` labels go inert, no check registers, and the watch hook reads that as "not installed" and stops gating. |
| `ignore_title_keywords: ["chore:"]` | Matches this estate's Dependabot titles verbatim, so it silently skips PRs you did not mean to skip. Decide by path in `review-policy.json`. |
| Dependency manifests in `review-policy.json` `high` | Reversed 2026-07-29 — HIGH requires CodeRabbit, which refuses bot authors, so it demands a reviewer that can never run. |
| PR base `branches: [main]` when mainline differs | Check `git symbolic-ref refs/remotes/origin/HEAD`. |
