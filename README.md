# Claude Code Skills

[![CI](https://github.com/FixPortal/fixportal-claude-skills/actions/workflows/ci.yml/badge.svg)](https://github.com/FixPortal/fixportal-claude-skills/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/FixPortal/fixportal-claude-skills)](LICENSE)

A curated, sanitised subset of the authored [Claude Code](https://claude.com/claude-code)
skills I use day to day, published as a portfolio reference. These are the
genuinely reusable ones — scaffolding, review, audit, and session workflows —
with machine paths, client names, and personal vault locations replaced by
placeholders.

> These are extracted from a larger private working set. Paths like `~/.claude/...`,
> `<vault>`, `<workdir>`, and example values like `you@example.com` / `Acme` /
> `<your-org>` are placeholders — point them at your own locations before use.

## What's here

### Scaffolding — start a repo, or bring an existing one up to standard

| Skill | What it does |
|---|---|
| `scaffold-dotnet` | Create or normalise a .NET solution to a house standard (NodaTime at the boundaries, central package management, a thin `.editorconfig` with analyzer rules owned by a shared package). |
| `scaffold-tests` | Scaffold xUnit v3 + NSubstitute + AwesomeAssertions test projects, with references on async/timing determinism and CI test budgets. |
| `scaffold-frontend` | Vite + React + TypeScript scaffolding with ESLint (sonarjs), Vitest, and architecture tests. |
| `scaffold-minimal` | Convert ASP.NET controllers to minimal APIs with OpenAPI + Scalar. |
| `scaffold-ci` | GitHub Actions CI for .NET / Vite-React / hybrid repos, plus Dependabot, mutation testing, and the AI-review control plane. |
| `scaffold-doc` | Author structured markdown docs — READMEs, audit reports, ADRs, runbooks — in a consistent house style. |

### Review — find the defects, then remediate them safely

| Skill | What it does |
|---|---|
| `adversarial-review` | Cross-vendor code review: one reviewer seat per vendor (Anthropic, OpenAI via the Codex CLI, Moonshot via the Kimi Code CLI, Google via Antigravity, and xAI via the Grok CLI at the time of writing), which cross-examine each other before a separate judge adjudicates. The panel is data, not code: `reviewers.json` defines it, pins a literal model per seat, and the driver enforces a minimum vendor-diversity invariant. |
| `review-sweep` | The same review across every repository under a parent folder, one subsystem at a time. |
| `review-worktree-pass` | Remediate review findings in a dedicated, ephemeral review worktree on a numbered batch branch, so the primary checkout is never disturbed. |
| `review-digest` | Mine *past* review work across a folder of repos into a dated intelligence report — coverage ledger, recurring-theme digest, risk ranking, and a paste-ready scope brief for the next pass. Read-only; runs no reviews. |
| `quality-gate-review` | A merge/release verdict from the evidence already gathered. Classifies what was verified and what is still a gap, rather than re-reviewing. |

### Audit — measure something against a standard, change nothing

| Skill | What it does |
|---|---|
| `audit-ci` | GitHub Actions CI/CD for one repo or a folder sweep, measured against a house standard — gaps, drift, cross-repo inconsistency, and a Docker layer-cache opportunity lens. Advisory; hands fixes to `scaffold-ci`. |
| `audit-tests` | Test quality and adequacy: what the suite actually proves, where the false confidence is, and how a prior audit reconciles against later code changes. |
| `audit-skills` | Audit authored agent skills across Claude Code, Codex, Kimi, and Antigravity for stale references, weak triggers, runtime incompatibility, and cross-home drift. |
| `audit-github-estate` | GitHub quality and security across an org or repository estate — code scanning, Dependabot, secret scanning, Actions evidence, and post-merge verification. |
| `audit-dotnet-estate` | Compare multiple .NET repositories against current house standards: scaffold drift, analyzer and formatter conformance, tests, docs, CI. |
| `audit-dotnet-performance` | Measure and profile one .NET repository, rank evidence-backed performance findings, and publish a reproducible audit manifest. |
| `remediate-dotnet-performance` | Run one approved performance experiment against a current audit finding, accepting only measured improvements that preserve correctness. |
| `audit-dotnet-analyzers` | Inventory the analyzer and code-style configuration actually in force across a solution or estate, and produce a portable remediation prompt. |
| `audit-dependabot-coverage` | Reconcile open advisories against the PRs Dependabot actually raised — the gap between "alerts exist" and "fixes were offered". |
| `azure-cost-sweep` | Reconcile live Azure spend against the code and IaC that require it. Ranked, risk-annotated, and strict about the difference between a saving applied and a saving *realised* — the latter needs committed IaC plus live verification after a deploy. |

### Session — cross a context boundary without losing the thread

| Skill | What it does |
|---|---|
| `handoff` | Write the brief that survives the session: what is done, what is in flight, and exactly what the next agent must not re-derive. |

### Domain — depth in the stacks I actually work in

| Skill | What it does |
|---|---|
| `ef-core` | Entity Framework Core design and implementation — entity and `DbContext` shape, query shaping, migrations, value converters. |
| `composition-review` | Defects that only appear when stateful parts compose: restart-replay, idempotency, ordering, and outbox/inbox behaviour in messaging and persistence paths. |

## How skills work

Each folder is a skill: a `SKILL.md` with YAML frontmatter (`name`, `description`)
that Claude Code loads on demand when the description matches the task. Drop a
folder into `~/.claude/skills/` (global) or a repo's `.claude/skills/` (project)
and it becomes available.

Larger skills keep `SKILL.md` short and push detail into `references/`, so the
loaded context stays small until the detail is actually needed.

## A note on the adversarial-review skill

The whole value is that the reviewers come from **different vendors**. A panel
made only of Claude models is same-vendor self-review: its errors correlate, so
the second opinion mostly agrees with the first. Spanning several vendors is
what makes one vendor's blind spot another's finding.

Two rules fall out of that and are enforced rather than documented: the active
reviewer set must span a minimum number of distinct vendors, and the judge is
never also a reviewer — an adjudicator that voted earlier is just its own
opinion, counted twice.

In the private working set each seat names a model *constraint* that a separate
model registry resolves to whatever is current. This mirror does not ship that
registry, so every seat also carries a literal model pin; the driver uses the pin
when no registry is installed. Expect the pins to age — update them, or install
your own resolver beside the skill.

## Contributing

PRs only — `main` is protected (rebase-merge, no direct pushes). Keep each
skill self-contained under `skills/<name>/` with `SKILL.md` frontmatter
(`name` matching the folder, `description` ≤ 1024 chars) and no
machine-specific paths — see [AGENTS.md](AGENTS.md) for the full conventions.

CI runs four jobs: skill validation (actionlint over the workflows, then the skill
verifiers), gate coverage (asserts every job in `ci.yml` is wired into the gate), a
repository-wide sanitisation scan (no machine paths, private tokens, or real endpoints),
and a required `CI Gate` check that needs the other three.

Run the verifiers locally before pushing:

```powershell
$failed = @()
Get-ChildItem skills -Recurse -Filter 'verify-*.ps1' |
  Sort-Object FullName |
  ForEach-Object {
    # Capture the path BEFORE try: inside catch, $_ rebinds to the ErrorRecord (which
    # has no FullName), so a failure recorded as $_.FullName would print an empty name.
    $verifier = $_.FullName
    # Reset BEFORE each verifier: a negative-path verifier runs a child that is
    # *supposed* to fail and asserts its exit code, and that native status must not
    # leak into the next script's result. A nonzero code after a verifier is that
    # verifier's own failure.
    $global:LASTEXITCODE = 0
    try { & $verifier }
    catch { $failed += $verifier; return }
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { $failed += $verifier }
  }
if ($failed) { Write-Host "Failed: $($failed -join ', ')"; exit 1 }
```

CI does the same, except a pull request that only touches files under
`skills/<name>/` runs just that skill's verifiers — anything outside `skills/`, or a
loose file directly under `skills/`, widens the run back to everything. A verifier
that reads a sibling skill's contract also runs when that sibling changes (the mapping
lives in `ci.yml`). Verifiers that spawn a deliberately failing
child clear its exit code on their own success path, so the code a passing
verifier leaves behind is always 0.

## Licence

MIT — see [LICENSE](LICENSE).
