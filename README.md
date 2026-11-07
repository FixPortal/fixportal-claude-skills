# Agent Skills

[![CI](https://github.com/FixPortal/fixportal-claude-skills/actions/workflows/ci.yml/badge.svg)](https://github.com/FixPortal/fixportal-claude-skills/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/FixPortal/fixportal-claude-skills)](LICENSE)

A curated, sanitised subset of the agent skills I author and use day to day,
published as a portfolio reference. They are not written for one vendor's CLI.
Each skill is a folder in the shared `SKILL.md` format, kept once in a single
canonical home and mounted into every agent runtime I use: Claude Code, Codex,
Kimi Code, Antigravity (IDE and CLI) and PI. See
[One canonical home, every runtime](#one-canonical-home-every-runtime).

These are the genuinely reusable ones — scaffolding, review, audit, and session
workflows — with machine paths, client names, and personal vault locations
replaced by placeholders.

> These are extracted from a larger private working set. Paths like `~/.agents/...`,
> `<vault>`, `<workdir>`, and example values like `you@example.com` / `Acme` /
> `<your-org>` are placeholders — point them at your own locations before use.
> A path under one runtime's own home (for example `~/.claude/...`) names that
> runtime's configuration, not the place the skills live.

For the setup these skills sit inside (the hooks, gates, memory and review routing, and the
failures that shaped them), see [How I work with coding agents](docs/agentic-workflow.md).

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
| `adversarial-review` | Cross-vendor code review: one reviewer seat per vendor (the enabled seats in `reviewers.json` at the time of writing: Anthropic, OpenAI via the Codex CLI, Google via Antigravity, z.AI via an isolated Claude Code session, and DeepSeek and Moonshot via their APIs; the Kimi CLI and Grok seats are present but disabled), which cross-examine each other before a separate judge adjudicates. The panel is data, not code: `reviewers.json` defines it, pins a literal model per seat, and the driver enforces a minimum vendor-diversity invariant. |
| `review-sweep` | The same review across every repository under a parent folder, one subsystem at a time. |
| `review-worktree-pass` | Remediate review findings in a dedicated, ephemeral review worktree on a numbered batch branch, so the primary checkout is never disturbed. |
| `review-digest` | Mine *past* review records across a folder of repos into a dated report — per-repository review coverage, change counts since the last usable review, a ranked work queue (explicitly not a risk verdict), and a paste-ready `/adversarial-review` prompt per changed scope. Reads vault records and git only; runs no reviews and edits no scanned code. |
| `quality-gate-review` | A merge/release verdict from the evidence already gathered. Classifies what was verified and what is still a gap, rather than re-reviewing. |

### Audit — measure something against a standard, change nothing

| Skill | What it does |
|---|---|
| `audit-ci` | GitHub Actions CI/CD for one repo or a folder sweep, measured against a house standard — gaps, drift, cross-repo inconsistency, and a Docker layer-cache opportunity lens. Advisory; hands fixes to `scaffold-ci`. |
| `audit-tests` | Test quality and adequacy: what the suite actually proves, where the false confidence is, and how a prior audit reconciles against later code changes. |
| `audit-skills` | Audit authored agent skills across Claude Code, Codex, Kimi, Antigravity, and PI for stale references, weak triggers, runtime incompatibility, and cross-home drift. |
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
that an agent runtime loads on demand when the description matches the task.
Larger skills keep `SKILL.md` short and push detail into `references/`, so the
loaded context stays small until the detail is actually needed.

The skill bodies are written for any runtime that reads the format. They do not
name one CLI's tools, and they resolve their own support files relative to the
folder they were loaded from. Where a skill drives specific vendor CLIs, as
`adversarial-review` does, those CLIs are what the skill is about. The runtime
it is loaded into does not change that.

### One canonical home, every runtime

Every skill lives exactly once, in `~/.agents/skills/<skill>/`, and every runtime
reads that one copy. Nothing is duplicated per CLI. Per-runtime copies drift, and
a fix made in one of them leaves the others broken without any sign of it.

| Runtime | How it reaches `~/.agents/skills/` |
|---|---|
| Codex | Scans it directly |
| Kimi Code | Scans it directly. `~/.kimi-code/skills/` holds only Kimi-specific overlays, which shadow the canonical skill of the same name |
| Claude Code | A directory junction per skill: `~/.claude/skills/<skill>` → `~/.agents/skills/<skill>` |
| Antigravity IDE | A junction per skill under `~/.gemini/config/skills/` |
| Antigravity CLI | A junction per skill under `~/.gemini/antigravity-cli/skills/` |
| PI | A junction per skill under both roots it reads, `~/.pi/skills/` and `~/.pi/agent/skills/` |

On Windows a junction needs no administrator rights:

```powershell
New-Item -ItemType Junction -Path "$HOME\.claude\skills\ef-core" -Target "$HOME\.agents\skills\ef-core"
```

A junction is used rather than a copy or a hard link because an edit made through
it changes the one real file. A hard link breaks silently the first time a tool
saves by writing a new file in place of the old one. On macOS or Linux a symbolic
link (`ln -s`) is the equivalent. I have only run this setup on Windows.

Mounting into every runtime is the default, not an absolute rule. A runtime that
routes through a third-party model provider sends the full text of every skill it
mounts to that provider. In the private working set, a few skills that need
private identity or local context are therefore left out of those runtimes. The
copies published here are sanitised, so that restriction does not apply to them.

To use a skill from this repository, copy `skills/<name>/` to
`~/.agents/skills/<name>/` and mount it as above. For a single project, use that
repository's own skills folder instead.

## A note on the adversarial-review skill

The whole value is that the reviewers come from **different vendors**. A panel
made only of Claude models is same-vendor self-review: its errors correlate, so
the second opinion mostly agrees with the first. Spanning several vendors is
what makes one vendor's blind spot another's finding.

Two rules fall out of that. The driver enforces the first in code: the active
reviewer set must span a minimum number of distinct vendors (`minVendors` in
`reviewers.json`). The second is that an adjudicator that voted earlier is just
its own opinion, counted twice. Until 2026-10-15 the manifest held that rule by
construction: the Opus lineage judged, and the Anthropic reviewer seat was
constrained to a different model family. I have since moved that seat to Opus
as well, a cost decision, and the manifest records the overlap as a deliberate
trade rather than hiding it. What now keeps adjudication from being one vendor's
opinion is the judge audit: a reviewer from a different vendor checks the
adjudicated report, and that audit is mandatory when the review gates a merge.

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
