# 2. Inventory reference

## Contents

- [2. Inventory](#2-inventory)


## 2. Inventory

<!-- routing: inventory -->
Start with `scripts/get-workflow-inventory.ps1 -RepositoryRoot <repo>`. Record its sorted
output and inventory count. The audit is incomplete unless every inventoried workflow has one evidence
row; never infer repository-wide conformance from `ci.yml` alone.

Read, per repo, using the runtime's filesystem listing, reading, and search
capabilities rather than shell `cat`/`find`:

- `.github/workflows/*.yml` **and** `*.yaml` — **enumerate both by literal path**
  (`<repo>\.github\workflows\*.yml` and `<repo>\.github\workflows\*.yaml`); a
  `**` glob silently skips the dotted `.github` dir, and a repo whose workflows use
  the `.yaml` extension is otherwise wrongly reported as having no CI.
- `.github/dependabot.yml`, `.github/actionlint.yaml`.
- For private repositories, verify all three secret-scanning controls separately: the
  PR-range scan and push-range scan in the selected primary workflow, and `.github/workflows/secret-sweep.yml`'s
  weekly full-history scan. They cover different history ranges; read their contract
  from `scaffold-ci`, not from similarly named public GitHub security settings.
- With `mutation.yml`, `.config/dotnet-tools.json`, `stryker-config.json`, and
  `scripts/summarize-stryker.ps1`; inspect the files, not just the workflow references.
- `.github/workflows/review-policy-guard.yml` wherever
  `.claude/review-policy.json` is scaffolded. Confirm it protects the policy's tracked and
  unignored invariants rather than merely existing.
- `.claude/review-policy.json` and `.coderabbit.yaml` — the AI-reviewer risk policy and
  spend controls. Both are dot-path files, so enumerate them by **literal path**; a `**`
  glob skips the dotted `.claude` dir and reads as absent.
- `.gitignore`, plus `git add --dry-run .claude/review-policy.json`; success proves the
  policy is addable. Use `git check-ignore -v` only after failure to identify the rule:
  verbose mode can print a matching negation for an untracked, addable file.
- Any `Dockerfile` / `*.Dockerfile`, plus modern and legacy Compose names:
  `compose.yml`, `compose.yaml`, `docker-compose.yml`, `docker-compose.yaml`,
  `docker-compose*.yml`, and `docker-compose*.yaml` (repo builds images?). Filter
  IDE/tool-generated noise out of those names — Rider's `.idea/**/compose*.generated*`
  and `.idea/**/docker-compose*.generated*` files, with either YAML extension, are
  not CI artifacts.
- **Reusable / called workflows.** An **external** call
  (`uses: <org>/<repo>/.github/workflows/x.yml@ref`) delegates its runner and step
  config to the *called* repo — note the delegation, treat its internals as out of
  scope, don't grade a step you cannot see. A **same-repo** call
  (`uses: ./.github/workflows/x.yml`) is fully auditable here: its jobs, runners and
  steps live in this repo, so audit them like any other workflow.
- The repo's stack signals: a `.sln` / `*.csproj` (backend), `package.json` with
  `lint`/`test`/`build` scripts (frontend), test projects (mutation candidate).
- Repository visibility and effective GitHub security configuration. Apply the
  visibility matrix from `scaffold-ci` before classifying any security surface.
- Organization Code Quality **Repository access** and enforcement. Code Quality is free on
  public repositories and paid on private/internal ones, so the compliant state is
  `Selected repositories` containing exactly the public repositories with `Enforce access`
  on, or `All repositories` where every repository in scope is public. Classify an
  overridable scope, enforcement off, or any private/internal repository in the selection
  as drift.

  **This is a UI-only surface — there is no API for it, and free is not the same as
  readable.** GitHub publishes Code Quality only at repository scope
  (`GET/PATCH /repos/{owner}/{repo}/code-quality/setup`,
  `GET /repos/{owner}/{repo}/code-quality/findings`); no organization endpoint exposes the
  repository-access selection or its enforcement flag. Every
  neighbouring check below names an exact call, so state plainly that this one cannot:
  **ask the user** to read *Organization settings → Code security → Code Quality* and
  report the selection and the enforcement toggle. Record their answer
  as the evidence, with the date. If they do not answer, this is an **evidence gap** —
  report it as `Code Quality org access: UNVERIFIED (UI-only, awaiting operator)` and carry
  on with the rest of the audit. Never infer it from repository-level `state`, and never
  let an unanswered question silently become "compliant".

  **ASK ONCE PER SWEEP, not once per repository.** The setting is a property of the
  ORGANIZATION, so the answer is identical for every repo in one pass — asking per repo
  interrupts a twenty-repo sweep twenty times for one fact. Ask at the start of the sweep,
  before the per-repo work, and apply the single answer to every repo in it, recording the
  same date and the same operator response on each.

  An answer from a PRIOR sweep may be reused only if it is DATED and no more than seven
  days old; state the date you are reusing. An undated answer, or one older than that, is
  not evidence — the whole point of the question is that nothing mechanical can detect a
  change to this setting, so an unbounded carry-forward reports a stale UI reading as a
  current observation. When you cannot ask (an unattended run), every repo in the sweep
  carries `UNVERIFIED`; a single unanswered question does not become twenty different
  verdicts.
- For a **public** repository, verify free CodeQL default setup through its own endpoint:
  `GET repos/{owner}/{repo}/code-scanning/default-setup` must return `state: configured`.
  Do not infer this from an Actions workflow named `CodeQL`; paid Code Quality uses the same
  workflow name.
- For a **private/internal** repository, do not query CodeQL or secret-scanning endpoints.
  Their expected `403`/`404` is policy-compliant paid-feature disablement, not a gap.
- Dependabot alerts via `GET repos/{owner}/{repo}/vulnerability-alerts`; HTTP 204 means
  enabled and HTTP 404 means disabled. Automated security fixes use a different contract:
  `GET repos/{owner}/{repo}/automated-security-fixes` must return HTTP 200 with
  `enabled: true` and `paused: false`; HTTP 404, `enabled: false`, or `paused: true` is
  non-compliant.
