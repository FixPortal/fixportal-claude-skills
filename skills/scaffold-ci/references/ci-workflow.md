# CI workflow contract

Read this reference whenever `ci.yml`, deploy/publish jobs, runners, or the CI Gate are in scope.

## Non-negotiable house rules for `ci.yml`

These are the deltas an unaided agent gets wrong. Get them right:

1. **Concurrency depends on whether the repo deploys.**
   - **Repo WITH a deploy job:** `cancel-in-progress: false`, always. A second push while a
     deploy is mid-flight must NOT kill the deploy — the house accepts redundant runs to
     protect deploy integrity.
   - **Library / tool / no-deploy repo:** there is nothing to protect, so a superseded
     feature-branch run is just wasted minutes. Use `cancel-in-progress: ${{ github.ref !=
     'refs/heads/main' }}` — cancel redundant branch runs, never cancel on `main` or tags.
     (Reviewers flagged a flat `false` here across the library repos in the sweep; matching
     the concurrency policy to the repo's actual risk is the fix.)
2. **Triggers:** `push` to mainline + tags `v*`, `pull_request` to mainline, and a bare
   `workflow_dispatch:`. Do not push-build every branch: an open PR would run the same
   commit once for `push` and again for `pull_request`. Add an `environment` choice
   input to `workflow_dispatch` **only when the repo has a real deploy job** that reads
   `${{ inputs.environment }}` — otherwise the dropdown is dead and misleads a manual trigger
   (a footgun that recurred across library repos in the sweep). See the Deploy section.
3. **actionlint is the first validation step of every substantive build, test, publish,
   mutation, or deploy job**, normally immediately after `actions/checkout`
   (`raven-actions/actionlint`, SHA-pinned, `shellcheck: true`). Zero-authority gate-control
   jobs such as `gate-coverage` and `ci-gate` are exempt. Exception for substantive jobs:
   on a cold runner where actionlint must resolve
   private npm dependencies, run `setup-node` and supply `NODE_AUTH_TOKEN` before actionlint;
   unauthenticated bootstrap otherwise fails with E401.
4. **Current action pins** (see table). An unaided agent defaults to stale `@v4`.
5. **Backend job is npm-free.** The frontend build runs only on `dotnet publish`
   (gated by an MSBuild target), so ordinary `build`/`test` never invokes npm. Do NOT add
   Node setup or a publish step to the backend CI job. The frontend has its own job.
6. **C# formatting is a separate, read-only gate.** In every .NET backend job, restore
   repository-local tools and run `dotnet csharpier check .` immediately after .NET setup,
   before NuGet restore/build/test. CSharpier is pinned by `scaffold-dotnet`; merge its
   entry into an existing tool manifest rather than replacing Stryker. CI checks only—it
   never runs `format`. Publish/deploy jobs depend on the backend gate and do not repeat it.
7. **Required PR tests have a fixed cost envelope.** One test gets a 30-second hard
   ceiling, each substantive required job gets `timeout-minutes: 10`, and substantive PR
   work targets 15 aggregate runner-minutes per commit. Count every matrix leg. Never retry
   a timeout: optimize or move the test. End-to-end, stress, load, soak, repeated or
   randomized concurrency, real package/publish/install exercises over 30 seconds, and
   broad compatibility matrices run in the weekly/manual extended lane described below.

### Runners — `ubuntu-latest` by default, Blacksmith for heavy lanes

Scaffold every job as `runs-on: ubuntu-latest`. A new repo's CI is fast because it
is empty; Blacksmith bills per minute and its sticky-disk cache is charged per GB
per month, so making it the scaffold default puts every throwaway repo on a meter
for a speed-up it does not yet need.

Switching is a **one-line change per job**, made deliberately once a repo's CI is
slow enough to be worth it — typically when Docker layer rebuilds or a Stryker run
dominate the wall clock:

```yaml
runs-on: blacksmith-4vcpu-ubuntu-2404   # was: ubuntu-latest
```

The house split, as deployed across the estate (several .NET and frontend repos
and others):

| Lane | Runner | Why |
|---|---|---|
| `backend` / `frontend` build+test | `blacksmith-4vcpu-ubuntu-2404` | compute-bound; the win is real |
| Extended tests | Existing compatible runner | weekly/manual only; bounded at 45 minutes |
| Stryker mutation (`mutation.yml`) | `blacksmith-4vcpu-ubuntu-2404` | longest job in the estate |
| Docker image publish | `blacksmith-4vcpu-ubuntu-2404` | sticky-disk layer cache is the whole point |
| `deploy` | `ubuntu-latest` | network-bound; a faster CPU buys nothing |
| npm `release` publish (provenance) | `ubuntu-latest` | attestation is cheap, and provenance is better left on GitHub-hosted runners |

Docker-building jobs that move to Blacksmith should also swap
`docker/setup-buildx-action` → `useblacksmith/setup-docker-builder` and
`docker/build-push-action` → `useblacksmith/build-push-action`, or the sticky-disk
cache is never used and the move buys only a bigger CPU. `audit-ci` evaluates
whether a given repo has crossed that threshold — it is an upgrade decision per
repo, not a scaffold default.

### Pinned action versions (current house standard)

| Action | Pin |
|--------|-----|
| `actions/checkout` | `v7` |
| `actions/setup-dotnet` | `v6` |
| `actions/setup-node` | `v7` |
| `actions/upload-artifact` | `v7` |
| `raven-actions/actionlint` | `3d39aea434753780c3b3d4a1a31c854b4dbf49d7` (`v2`) |

.NET: `10.0.x`. Node: `24`.

**First-party `actions/*` take the major tag; third-party actions take a full commit
SHA.** `raven-actions/actionlint` is third-party, so pin the SHA with a trailing `# v2`
comment — a floating tag there trips the Semgrep registry rule
`third-party-action-not-pinned-to-commit-sha`; if your repo enforces it via a local edit hook
or workflow, a tag-pinned scaffold gets flagged the moment it is written. Re-resolve the SHA before
scaffolding rather than trusting this table (`gh api repos/raven-actions/actionlint/git/ref/tags/v2
--jq '.object.sha'`); dependabot bumps it in-repo and this doc lags.

That SHA pins the **action**, not the **actionlint binary** it downloads. Those are
separate knobs: the action's `version:` input is actionlint's own semver and defaults to
`latest`, so a SHA-pinned action still fetches a floating linter. The house default is to
omit `version:` and accept that — a new actionlint release surfacing a new lint is
usually what you want from a linter. Set an explicit semver only where a reproducible
binary matters more than current rules.

### `ci.yml` skeleton (hybrid; drop the job you don't need)

```yaml
name: CI

on:
  # Deliberately narrow: all-branch pushes fire a second full run on every PR commit.
  # Concurrency does not safely solve that because push and PR refs differ.
  # Regression signal: two runs with one head SHA, one push and one pull_request.
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]          # <- mainline branch of THIS repo
  # Bare manual trigger. Add an `environment` choice input ONLY if this repo has a
  # deploy job that reads ${{ inputs.environment }} (see the Deploy section); a
  # dropdown no step consumes is a dead footgun.
  workflow_dispatch:

# Concurrency: this no-deploy skeleton cancels superseded branch runs but never
# cancels main/tags. A repo WITH a deploy job must instead pin `cancel-in-progress:
# false` to protect mid-flight deploys (see house rule 1).
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

permissions:
  contents: read

jobs:
  backend:
    name: Backend (.NET)
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - name: Lint workflows (actionlint)
        uses: raven-actions/actionlint@3d39aea434753780c3b3d4a1a31c854b4dbf49d7 # v2
        with:
          shellcheck: true
      - name: Set up .NET
        uses: actions/setup-dotnet@v6
        with:
          dotnet-version: '10.0.x'
      - name: Restore local tools
        run: dotnet tool restore
      - name: Check C# formatting
        run: dotnet csharpier check .
      - name: Restore
        run: dotnet restore YourSolution.sln
      - name: Build
        run: dotnet build YourSolution.sln --configuration Release --no-restore
      # `YourSolution.sln` here means the FAST projects only. The moment an extended test
      # project exists (scaffold-tests directs you to create one), running the solution
      # runs it too: on every PR, against the 15-runner-minute budget, the 30s hang
      # ceiling and timeout-minutes: 10. Keep the extended project out of the solution,
      # or name a solution filter -- `dotnet test YourSolution.Fast.slnf` -- or list the
      # fast projects explicitly. Excluding by filter is not the answer; the extended
      # lane rule below says so and it applies here too.
      - name: Test
        run: dotnet test YourSolution.sln --configuration Release --no-build --logger "trx;LogFileName=test-results.trx" --results-directory ./TestResults --blame-hang-timeout 30s --blame-hang-dump-type none
      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: test-results
          path: ./TestResults/*.trx
          if-no-files-found: ignore

  frontend:
    name: Frontend (UI)
    runs-on: ubuntu-latest
    timeout-minutes: 10
    defaults:
      run:
        working-directory: src/your-ui   # <- the UI subfolder, if not repo root
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - name: Lint workflows (actionlint)
        uses: raven-actions/actionlint@3d39aea434753780c3b3d4a1a31c854b4dbf49d7 # v2
        with:
          shellcheck: true
      - name: Set up Node.js
        uses: actions/setup-node@v7
        with:
          node-version: '24'
          cache: 'npm'
          cache-dependency-path: src/your-ui/package-lock.json
      - name: Install
        run: npm ci
      # - name: Generate types        # only if a generate:*-types script exists
      #   run: npm run generate:rest-types
      - name: Lint
        run: npm run lint
      - name: Test
        run: npm run test
      - name: Build (typecheck + bundle)
        run: npm run build
```

### Extended tests — weekly/manual, never a PR gate

Use one repository-specific workflow only when extended tests exist. Select a separate
test project or explicit project list; do not run the solution and exclude tests with
filters. The workflow has exactly `workflow_dispatch` plus one staggered weekly schedule:

```yaml
name: Extended tests

on:
  workflow_dispatch:
  schedule:
    - cron: '17 3 * * 2' # choose a distinct estate slot

permissions:
  contents: read

jobs:
  extended-tests:
    name: Extended tests
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - name: Lint workflows (actionlint)
        uses: raven-actions/actionlint@3d39aea434753780c3b3d4a1a31c854b4dbf49d7 # v2
        with:
          shellcheck: true
      - uses: actions/setup-dotnet@v6
        with:
          dotnet-version: '10.0.x'
      - run: dotnet test tests/YourProject.ExtendedTests/YourProject.ExtendedTests.csproj --configuration Release
```

This workflow is never a required PR gate and is not listed in `CI Gate`. Manual dispatch
is for diagnosis or release verification, not a routine pre-merge step. Weekly does not
mean unbounded: split or optimize work that cannot finish within 45 minutes.

PR CI uses the smallest representative platform set that covers the production path.
Move broad OS/runtime compatibility matrices to this extended workflow. The default
budget is 15 aggregate runner-minutes: expected job duration multiplied by matrix legs,
excluding lightweight gate-control jobs. Widening any budget requires explicit owner
approval backed by measured CI evidence.

The VSTest flags in the backend skeleton are per-test enforcement. MTP's hang timeout is
an inactivity timeout, not an equivalent per-test duration limit; retain operation-local
deadlines and the ten-minute job cap instead. See `scaffold-tests` for the full test-lane
contract.

**Has a deploy target?** This skeleton is the no-deploy default (bare `workflow_dispatch:`,
ref-gated `cancel-in-progress`). When a real deploy target lands: add the `environment`
choice input to `workflow_dispatch` (see Deploy section), wire deploy jobs that read
`${{ inputs.environment }}`, and switch `cancel-in-progress` to a flat `false` to protect
mid-flight deploys. Never list environments that no step consumes.

**Conditional backend extras** — add only where the repo actually has them: Bicep lint
(`az bicep build`), an EF idempotent-migration generate + apply-to-fresh-DB precondition
(needs a `sqlserver` service container), and contract-snapshot artifact uploads. Don't add
empty placeholders.

### Deploy (optional, documented pattern — not boilerplate)

Where a repo has a deploy target, add the `environment` choice input back to
`workflow_dispatch` (the skeleton omits it) so a manual deploy can pick a target:

```yaml
  workflow_dispatch:
    inputs:
      environment:
        description: 'Which environment to manually deploy to'
        type: choice
        required: true
        default: <repo-dev-env>
        options:
          - <repo-dev-env>
          - <repo-prod-env>
```

and switch `cancel-in-progress` to a flat `false` (house rule 1). Then `ci.yml` calls a
reusable `_deploy.yml` / `_deploy-ui.yml`
via `uses: ./.github/workflows/_deploy.yml` with `secrets: inherit` and
`permissions: { id-token: write, contents: read }`. Deploy jobs are **ref-gated**:
`workflow_dispatch` is `main`-only (the env-scoped OIDC federated cred is branch-agnostic at
the token layer, so without a ref check anyone could deploy a feature branch), and tag
pushes (`refs/tags/v*`) fire prod. The infra/targets are repo-specific — point at this
pattern, don't fabricate Bicep or environments that don't exist.

### A tag trigger is not a review gate — assert ancestry

**A ref gate on `refs/tags/v*` proves the ref's SHAPE, never that the commit was
reviewed.** `git push origin v1.2.3` puts the tag on whatever commit you name, including
one that never opened a PR, and the workflow then builds and publishes it. Tag creation
is unrestricted by default: rulesets target branches, and a branch ruleset does not
constrain tags. An adversarial-review sweep found this in three estate repos on the same
day; both repos checked had **zero** tag-target rulesets, so nothing outside the workflow
was enforcing anything.

**The control that binds has to live outside the tagged tree.** GitHub runs a
`push: tags:` workflow from the tagged commit's own tree, so the assertion below is
content the tag-pusher controls: `git push origin v1.2.3` naming a commit that never
carried the step runs a workflow with no ancestry check at all. That makes the
in-workflow assertion a belt — cheap, fail-closed, visible in the diff, worth having —
and not the primary control. Primary is state the pusher cannot author in the same
commit:

- **restricted tag creation** (a tag ruleset — load-bearing, not defence in depth), or
- **environment-protected deploy credentials**, so an unreviewed tag's job cannot reach
  the secret, or
- a **trusted release workflow reached by `workflow_call` from a protected branch**,
  which executes the caller's tree rather than the tag's.

There is also **no PR-time enforcement** of any of this: `.github/workflows/**` is
deliberately not HIGH and `assert_workflow_hygiene.py` carries no ancestry assertion, so
a newly added tag-fired publish workflow is NORMAL and mechanically unchecked until
someone runs `audit-ci` against the repo. Adding one is a reviewed change on its own
merits, not a routine workflow edit.

With that ordering understood, add both:

1. **Assert reachability from the default branch, before restore.** Fails closed and is
   visible in the diff:

   ```yaml
         # Full fetch of main, not --depth: the tag may name an older main commit, and a
         # shallow fetch leaves merge-base no shared history to walk.
         - name: Assert the tagged commit is reachable from main
           run: |
             set -euo pipefail
             git fetch --no-tags origin main
             if ! git merge-base --is-ancestor "$GITHUB_SHA" FETCH_HEAD; then
               echo "::error::Tag '${GITHUB_REF_NAME}' names a commit that is not reachable from main. Only reviewed, merged commits may be released."
               exit 1
             fi
   ```

   This works from `actions/checkout`'s default depth-1 clone — verified by
   reproduction: fetch the tagged SHA at depth 1, then `git fetch --no-tags origin main`,
   then `merge-base --is-ancestor`, which exits 0 for a commit that is genuinely an
   ancestor. Do not assume it needs `fetch-depth: 0`.

2. **Where publish is triggered by a branch push rather than a tag, gate on the ref
   itself** — `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` — and
   drop the `v*` tag trigger entirely if nothing needs it. A tag push satisfies
   `github.event_name == 'push'`, so the event check alone gates nothing.

Write the assertion because it is cheap and reviewable, but do not stop there: the
ruleset is administrative state nobody diffs, and it is also the only one of the two
that an unreviewed tag cannot simply omit.

### Job naming — CI dashboard lane contract

A CI dashboard (`your-repo`) sorts workflow **jobs** into
board lanes — **Deploys** and **Packages** — by a case-insensitive substring
match on the **job `name:`**. Names that break this contract mis-lane (a deploy
rendered as a package) or vanish from the board entirely (a job whose name
matches no pattern, e.g. `build-and-push` → neither lane). Always set an
explicit job `name:` — never rely on the job id — and follow:

- **Deploy job** → `Deploy (<target>)` where `<target>` is a deploy target name
  such as a production slot or a client dev UI (e.g. `Deploy (<target>)`), or
  `Deploy (Azure Container Apps)`. Must contain `deploy`; `<target>` must NOT
  contain a package term (below).
- **Publish/package job** → `Publish <Artifact> (<location>)` — e.g.
  `Publish Image (GHCR)`, `Publish Image (ACR)`, `Publish Package (NuGet)`,
  `Publish Package (npm)`. Must contain a package term; must NOT contain `deploy`.
- **One job = one lane.** A job that builds/pushes an image **and** deploys must
  be **split** into a `Publish Image (...)` job and a `Deploy (...)` job — a
  single job cannot carry both lane identities, and naming it for one silently
  drops the other from the board.

The runtime half of this contract is `JobLanes` in the dashboard's
`appsettings.json`:
- deploys patterns: `["deploy"]`
- packages patterns: `["publish","package","docker","image","release","ghcr"]`

Keep job names matching these. If you change a lane or pattern there, update this
section so scaffold and classifier stay in sync.

## `CI Gate` — the required status check

Every repo's `ci.yml` carries two extra jobs. `CI Gate` is the context branch protection
requires; `Gate coverage` proves the gate is wired to everything it should be.

The script ships as an asset so its shape cannot drift:

```bash
mkdir -p .github/scripts
cp ~/.agents/skills/scaffold-ci/assets/assert_gate_coverage.py .github/scripts/
```

The path is `~/.agents/skills/`, the canonical cross-CLI home — not any single runtime's
skills root, which would resolve only under that runtime.

```yaml
  gate-coverage:
    name: Gate coverage
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false

      - name: Assert every job in this workflow is gated
        env:
          # Jobs deliberately outside the gate, by job id. Push-only publish and deploy
          # work belongs here; quality jobs never do. Every name must exist as a job in
          # this workflow — the checker fails on a name that does not.
          GATE_EXEMPT: ''
        run: python3 .github/scripts/assert_gate_coverage.py .github/workflows/ci.yml

      - name: Assert canonical asset copies match the committed manifest
        run: python3 .github/scripts/assert_canonical_assets.py

  ci-gate:
    name: CI Gate
    if: always()
    needs: [backend, frontend, gate-coverage]   # the quality jobs in THIS file
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions: {}
    steps:
      - name: Fail if any upstream job did not succeed
        if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        env:
          RESULTS: ${{ join(needs.*.result, ', ') }}
        run: |
          echo "Upstream results: $RESULTS"
          exit 1
```

Rules, each of which is a way this goes wrong:

- **`if: always()` is load-bearing.** Without it the gate is *skipped* when an upstream job
  fails, a skipped job emits no check run at all, and a required context that never reports
  leaves the pull request permanently unmergeable. The failure mode is the opposite of what
  you would expect: a broken build produces an unblockable PR rather than a blocked one.
- **`skipped` counts as a pass**, which is what lets job-level `if:` conditions and path
  filtering work. `failure` and `cancelled` do not. That used to be recorded here as an
  accepted cost — a job skipped by a *bug* in its `if:` satisfies the gate silently. It is
  no longer accepted: `assert_gate_coverage.py` refuses a job-level `if:` on any job
  feeding the gate, so a conditional quality job has to be named in
  `GATE_CONDITIONAL_EXEMPT` with a written rationale beside it. Conditional exemption does
  **not** exempt a job from gate membership; that is `GATE_EXEMPT` alone.
- **The gate's own semantics are asserted, not assumed.** `needs:` membership does not
  make a gate real: with no `if: always()` it is skipped exactly when it was needed, and
  with no step keyed on a `needs.<job>.result` it aggregates nothing and reports success
  unconditionally. Both keep the job, its name and its `needs:` list intact, so neither
  reads as a coverage change in a diff. The checker fails on both. This is the in-repo
  half of a fix whose other half is tiering `ci.yml` and the checker HIGH — see
  `review-policy.md`, and the `$comment` block in `review-policy.example.json`.
- **The gate has no `permissions`, no checkout and no network.** It only reads
  GitHub-controlled `needs.*.result`. It is the one job deciding what can merge, so it gets
  zero token authority and nothing that can fail on its own.
- **The hosting workflow must NOT carry a workflow-level `paths:` filter.** A workflow that
  does not run produces no check run, and the required context blocks forever. Filter at
  job level with `if:` instead. Watch for a filter whose first entry is `'**'` — it matches
  everything and is a no-op, so it looks like a filter while doing nothing, and narrowing
  it later silently blocks every merge.
- **`needs:` lists the quality jobs in this file only.** `needs:` cannot cross workflow
  files, so a gate in `ci.yml` cannot cover `react-doctor.yml` or `review-policy-guard.yml`.
  That is why `Review policy intact` is required as a second context rather than gated.
- **Invoke it with `python3`, never through a shell wrapper.** This started life as a
  bash script that called Python, and three repos failed the required check with
  `set: pipefail: invalid option name` — bash reading `pipefail\r` because the file was
  checked out with CRLF. Every committed blob carried CRLF; the repos that passed passed
  by accident of checkout configuration. Do not "fix" a recurrence with `.gitattributes`:
  that leaves any repo one `* text=auto eol=crlf` away from a red gate whose symptom
  points at the gate rather than at line endings. Keep the shell out of the path.
- **The manifest step fails closed, and must never be guarded.** `assert_canonical_assets.py`
  exits non-zero when a listed asset differs from `.github/canonical-assets.json` or is
  gone, and exits 2 when the manifest itself is missing or unreadable. Never give the step
  an `if:` — a skipped step renders exactly like a passed one, and the presence of the
  check is not the presence of the verdict. A deliberate divergence regenerates the
  manifest in the same PR: `pwsh ~/.agents/skills/scaffold-ci/scripts/sync-canonical-asset-manifest.ps1 -RepoRoot .`.
  The verifier ships like the gate checker: `cp ~/.agents/skills/scaffold-ci/assets/assert_canonical_assets.py .github/scripts/`,
  and allow-list `.gitignore` repos need the same explicit un-ignore for it and for
  `.github/canonical-assets.json`.
- **Allow-list `.gitignore` repos need an explicit un-ignore** for
  `.github/scripts/assert_gate_coverage.py`. Otherwise the file is present locally and
  absent from the clone CI checks out, and the gate fails looking like a script bug.

`scaffold-repo` owns the matching `required_status_checks` rule. A gate with no requirement
is decoration; a requirement with no gate blocks every merge — so if you add one, check the
other exists.
