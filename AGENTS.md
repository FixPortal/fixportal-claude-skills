# AGENTS.md

Repo-specific conventions for the public Claude Code skills portfolio. Global
agent rules live in the runtime homes (`~/.claude/CLAUDE.md` etc.) and are not
repeated here.

## Public-repo constraints

- Everything in this repo is world-readable. Never commit machine-specific
  paths, client names, or personal vault locations — use the established
  placeholders (`~/.claude/...`, `<vault>`, `<workdir>`, `you@example.com`,
  `Acme`, `<your-org>`). The `sanitisation` job in `ci.yml`
  (`.github/scripts/assert_no_private_tokens.py`) fails the build on leaked
  Windows user-profile paths, drive-root absolute paths, org-name wiring forms,
  non-placeholder email addresses, and real deployment hostnames.
- **Sweep the whole tree, not just `skills/`, and not with a plain glob.**
  `.github/`, `.claude/` and `.semgrep/` are dot-directories that `rg` and `**`
  skip by default, so a sweep scoped to `skills/` reports clean while a private
  slug sits in a workflow comment — which is exactly how one reached `main`.
  Use an explicit path list including the dot-directories.
- **Enumerate URLs and hostnames as their own class.** A token-list gate only
  finds names it was told about; a deployment hostname is a leak with no token
  in it. No published script may carry a real endpoint as a default — take it
  from the environment and post nothing when it is unset.
- Skills here are a sanitised subset of a larger private working set. Port
  changes one way, from the private canonical copy into this mirror; do not
  edit the public and private copies independently.
- A verifier that reaches for a sibling skill this mirror does not publish
  must skip with a stated reason (`Write-Host "SKIP: ..."`), never fail. The
  same convention already covers notes and policy files that live outside the
  repository.

## Skill shape

- Each skill is a folder under `skills/` with a `SKILL.md` carrying YAML
  frontmatter: `name` (must equal the folder name) and `description`
  (≤ 1024 chars — the Copilot limit; third-person, trigger-phrase led).
- `SKILL.md` must resolve support files relative to its own loaded skill
  directory, never via a hardcoded `~/.claude/skills/<name>` path.

## CI contract

- `ci.yml` runs every `skills/**/test/verify-*.ps1`. A new or changed skill
  must keep its verifiers green; run them locally with pwsh before pushing.
- Workflows are linted by `raven-actions/actionlint` (SHA-pinned,
  `shellcheck: true`) as the first validation step of every job.
- `.claude/review-policy.json` is the review control plane;
  `review-policy-guard.yml` asserts it stays tracked and unignored. Do not
  re-add `.gitignore` to its `high` list without first removing the
  corresponding assertion in `review-policy-guard.yml` — and never delete the
  workflow itself: its job name is a required status check, so a deleted
  workflow never reports and leaves every PR permanently unmergeable.
