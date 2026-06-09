# Claude Code Skills

A curated, sanitised subset of the authored [Claude Code](https://claude.com/claude-code)
skills I use day to day, published as a portfolio reference. These are the
genuinely reusable ones — scaffolding, review, and session-management workflows —
with machine paths, client names, and personal vault locations replaced by
placeholders.

> These are extracted from a larger private working set. Paths like `~/.claude/...`,
> `<vault>`, `<workdir>`, and example values like `you@example.com` / `Acme` are
> placeholders — point them at your own locations before use.

## What's here

| Skill | What it does |
|---|---|
| `adversarial-review` | Cross-vendor code review — Claude Opus + Claude Sonnet + a non-Claude model (GPT via the GitHub Copilot CLI), then cross-examination and adjudication. The point is uncorrelated error across vendors. |
| `scaffold-dotnet` | Create / normalise a .NET solution to a house standard (NodaTime boundaries, central package management, canonical `.editorconfig`). |
| `scaffold-tests` | Scaffold xUnit v3 + NSubstitute + AwesomeAssertions test projects. |
| `scaffold-ci` | GitHub Actions CI for .NET / Vite-React / hybrid repos, plus Dependabot and CodeQL. |
| `scaffold-frontend` | Vite + React + TypeScript scaffolding with ESLint (sonarjs) and Vitest. |
| `scaffold-minimal` | Convert ASP.NET controllers to minimal APIs with OpenAPI + Scalar. |
| `scaffold-doc` | Author structured markdown docs (READMEs, audit reports, runbooks) in a consistent house style. |
| `review-digest` | Mine PAST adversarial-review / reviewer-findings work across a folder of repos into a dated intelligence report — coverage ledger, recurring-theme digest, forward-looking risk ranking, and a hand-off scope brief (commits since each repo's last review + a paste-ready review prompt for another agent). Read-only; runs no reviews. |
| `recap` | "Where did we get to?" — a fast, multi-source, journalled recap of work done and what's next, per repo/branch. |
| `reflect` | An honest, evidence-scored audit of how well a Claude Code setup is actually being used. |

## How skills work

Each folder is a skill: a `SKILL.md` with YAML frontmatter (`name`, `description`)
that Claude Code loads on demand when the description matches the task. Drop a
folder into `~/.claude/skills/` (global) or a repo's `.claude/skills/` (project)
and it becomes available.

## A note on the adversarial-review skill

The whole value is the **non-Claude** reviewer. A multi-agent panel made only of
Claude models is same-vendor self-review and defeats the purpose — the
uncorrelated error of a different vendor's model is what catches what one vendor
misses. The skill wires Claude Opus + Claude Sonnet + GPT (via the Copilot CLI).

## Licence

MIT — see [LICENSE](LICENSE).
