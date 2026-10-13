---
name: scaffold-frontend
description: Use when creating or normalizing a Vite + React + TypeScript frontend project to house conventions - ESLint, Prettier, Vitest, ArchUnitTS, and dependency floors.
---

# Scaffold Frontend

## Overview

Apply standard frontend project preferences when creating new Vite + React +
TypeScript projects or normalizing existing ones. This is the TypeScript/React
counterpart to `scaffold-dotnet`. Existing projects should be updated to match
these preferences rather than rewritten.

The canonical config lives in **`templates/`** beside this file — copy those
files rather than improvising or copying from another repo. There is
deliberately **no "reference repo"**: a live project drifts, carries
project-specific baggage, and can fall behind this skill's own checklist. The
templates are the source of truth; the frontend-only version table below pins the
floor for what this skill owns, and the shared TypeScript floor lives in
`scaffold-typescript`.

## When to Use

- Creating a new frontend (SPA / dashboard / admin UI) from scratch
- Setting up or normalizing ESLint, Vitest, or TypeScript config on a frontend
- Wiring static analysis (`eslint-plugin-sonarjs`) into a frontend
- Adding architecture tests (ArchUnitTS) to a frontend
- When asked to "scaffold", "set up", or "initialize" a web UI

## Stack and versions

Before selecting or changing dependencies, read
`~/.agents/notes/npm-publishing-traps.md` (if that note is not present, proceed
and record the assumption). Pin a mutually compatible set from
the lockfile evidence; do not equate each package's independent latest version
with a resolvable stack. Before bumping Vitest, `@testing-library/jest-dom`,
or `eslint-plugin-react-refresh`, also read
`~/.agents/notes/js-toolchain-traps.md` (if that note is not present, proceed
and record the assumption) — it records Vitest 5's `Assertion<R,T>`
widening breaking jest-dom matcher types, and eslint-plugin-react-refresh
0.5.6's changed recognition of `export const P = Ctx.Provider`.

- **Build**: Vite (latest), `type: module`
- **Framework**: React 19 + React Router (apps; a component library omits the router)
- **Language**: latest TypeScript supported by `typescript-eslint`, strict,
  bundler module resolution
- **Lint**: ESLint flat config (`eslint.config.js`), `typescript-eslint`,
  `eslint-plugin-react-hooks`, `eslint-plugin-react-refresh`,
  `eslint-plugin-sonarjs`
- **Format**: Prettier (`prettier --check .` is the first gate step)
- **Test**: Vitest + `@testing-library/react` + `jsdom`; coverage via
  `@vitest/coverage-v8` with thresholds
- **Architecture tests**: `archunit` (npm package), via a local wrapper

Pin all deps to their latest **mutually compatible** releases at scaffold time.
The table below holds the **frontend-only** floors (the shared TypeScript floor,
including `prettier`, is in `scaffold-typescript`'s table, referenced just below) —
the known-good set; bump within current peer ranges when scaffolding, but do not go
below it. The shared table is dated in its own file (`prettier` joined it in 2026-10).

Shared TypeScript floor (`typescript`, `typescript-eslint`, `eslint`, `@eslint/js`,
`eslint-plugin-sonarjs`, `globals`, `prettier`, `vitest`, `@vitest/coverage-v8`, `@types/node`),
the TypeScript `~` tilde rationale and the Node 24.15.0 engines floor: see
`scaffold-typescript`. Frontend-only floors:

| Package | Floor | Package | Floor |
|---|---|---|---|
| `vite` | ^8.0.16 | `eslint-plugin-react-hooks` | ^7.1.1 |
| `react` / `react-dom` | ^19.2.7 | `eslint-plugin-react-refresh` | ^0.5.2 |
| `react-router` | ^8.0.1 | `@testing-library/user-event` | ^14.6.1 |
| `@vitejs/plugin-react` | ^6.0.2 | `jsdom` | ^30.0.1 |
| `@testing-library/react` | ^16.3.2 | `@testing-library/jest-dom` | ^7.0.0 |
| **`archunit`** | **`2.4.0` (exact, no caret)** | | |

The Node line also has to satisfy Vite, jest-dom, and jsdom 30 together.

`archunit` is pinned **exactly** — see *Architecture tests* below for why. Re-verified
2026-07-27 against 2.4.0: `dist/src/files/index.js` still re-exports `projectFiles`, and
root `dist/index.js` still `require("./src/testing/setup")` eagerly at import time, so the
root-import-throws-under-`globals:false` behaviour the wrapper works around is unchanged.

## Project Structure

Feature-first layout under `src/`:

```
src/
  app/                     # App shell, routing
  features/<feature>/
    api/                   # data fetching + generated types
    components/
    hooks/
    lib/                   # pure helpers (unit-tested)
    pages/
  theme/
  test/                    # setup.ts, shared test utils
```

Normalizing an existing flat `src/` (e.g. top-level `api/`, `components/`,
`hooks/`, `pages/`, `lib/`) does **not** require migrating to feature-first in
the same pass — update config/tooling first, and let architecture rules match
the layout that actually exists. Treat a feature-first migration as its own task.

## Config (copy from `templates/`)

Before changing Vite configuration or plugins, read
`~/.agents/notes/web-ui-traps.md` (if that note is not present, proceed and
record the assumption).

- `templates/package.json` — minimum dependency and script contract, including
  `format` (`prettier --check .`), `lint`, `typecheck` (`tsc -b`), `build`,
  `test: vitest run`, coverage and the chained `gate`. Adapt only the package name and app/library
  dependencies; keep the toolchain mutually resolvable.
- `templates/.prettierrc.json` + `.prettierignore` — byte-identical to
  `scaffold-typescript`'s (the contract verifier compares them). `.prettierignore`
  also lists `.github/ai-smells` and `.github/workflows/review-tier.yml`
  (manifest-listed `scaffold-ci` assets that read DIVERGED if reformatted) and
  `.claude/review-policy.json` (a per-repo copy, not manifest-listed; reason UNVERIFIED).
- `templates/eslint.config.js` — flat config: `js` + `typescript-eslint`
  `strictTypeChecked` + `stylisticTypeChecked` (type-aware: `projectService`) +
  react-hooks + react-refresh + the full SonarJS recommended set, all SonarJS
  rules downgraded to `warn`, noise rules off (see below), and the house bans from
  `scaffold-typescript` (no enums, no default exports, no `Date.now` / bare
  `new Date()`, no `setTimeout` in tests, `switch-exhaustiveness-check`). The
  typed rules live only in the typed block: a block without `projectService`
  crashes on them. Relaxations, each with a WHY in the file: `**/*.config.ts` may
  default-export (Vite/Vitest require it); `src/**/clock.{ts,tsx}` is the one
  place that may call a bare `new Date()`. The template ships no clock file — when the
  first time-dependent code lands, create `src/<area>/clock.ts` (a `Clock` taken by
  parameter everywhere else; see `scaffold-typescript`'s `src/clock.ts`). Write the
  system clock as `{ now: () => new Date() }`; `Date.now()` is banned everywhere,
  including the clock file, so it cannot leak around the `Clock`. The `setTimeout`
  test ban is mechanical for bare `setTimeout(...)` only; `window.setTimeout` /
  `globalThis.setTimeout` are review-only. Per-area
  override blocks (generated code, demo mocks, scripts) are commented examples —
  keep each with a WHY. `react-refresh` and the default-export ban do not interact:
  observed 2026-10-12 on a default-exported component, only the ban fires. Code
  splitting does not need a default export: `lazy(() => import('./X').then((m) => ({
  default: m.X })))` and a router `lazy: () => import('./X').then((m) => ({ Component:
  m.X }))` both lint clean under the ban (observed 2026-10-12); keep route tables
  in a non-component file or react-refresh flags the mixed exports.
- `templates/vitest.config.ts` — jsdom + `src/test/setup.ts` + test `include`,
  **plus a `coverage` block with `include: ['src/**']` and thresholds** (provider
  `v8`). The `coverage.include` is load-bearing: without it v8 counts only the
  files a test imported, so untested src files fall outside the denominator and
  the thresholds pass vacuously. Set the threshold floors from a real
  `--coverage` run over all of src, not the smaller test-touched-only figure.
  `globals: true` is deliberately omitted (tests import from `vitest`; this also
  keeps ArchUnitTS's root import from throwing).
- `templates/tsconfig.json` + `tsconfig.app.json` + `tsconfig.node.json` +
  `tsconfig.test.json` — bundler mode, strict plus `noUncheckedIndexedAccess`,
  `exactOptionalPropertyTypes`, `noPropertyAccessFromIndexSignature` and
  `noImplicitOverride` in app, node and test, `target`/`lib` es2023. The test
  project owns `*.test.*`/`*.spec.*`/`*.archunit.*` and `src/test/**`, so test
  sources are type-checked by `tsc -b` instead of belonging to no project.
- Verify each resolved config with
  `npm exec --silent --yes --package=typescript@<version> --call "tsc --showConfig --project <config>"`.
  `--call` avoids npm-version-specific argument separator handling; treat empty
  output as failure before parsing JSON.
- `templates/src/test/setup.ts` — jest-dom matchers + explicit RTL cleanup
  (needed because globals are off). Add project-specific shims below the core.

## Static analysis and the gate

The local gate is four commands in this order (`npm run gate` runs them; the
template's `build` is `tsc -b && vite build`, so the type check is inside it):

```
prettier --check .
eslint .
tsc -b            (via npm run build)
vitest run
```

Cheapest and most mechanical first. `prettier --check`, never `--write`: the gate
reports, it does not rewrite the tree it judges. The language rules (strictness,
clock, async tests, bans) and what enforces each are in
`../scaffold-typescript/references/language-rules.md`; do not restate them here.
Fix lint at the source; the type-aware presets are errors, not advisories.

A bare copy of `templates/` is red by design (no `src` app yet, and the
architecture spec matches no layer folders). The gate is proven on a fixture app —
see `test/verify-build-gate.ps1`.

`scaffold-ci`'s Node job runs `npm run format` right after install, ahead of lint (see its
`references/ci-workflow.md`), so the Prettier half of this gate is enforced in CI.

### SonarJS (advisory)

Enable the **full recommended set**, downgrade every Sonar rule to `warn`
(advisory, **non-blocking** — `eslint .` must still exit 0), and switch off the
rules that are stylistic policy or false-positive noise. Cognitive complexity is
the advisory complexity signal; do **not** also enable cyclomatic-complexity (it over-counts
flat switch/ternary dispatch). The wiring — the spread-then-downgrade pattern and
the off-list (`file-header`, `arrow-function-convention`,
`declarations-in-global-scope`, `cyclomatic-complexity`, `no-reference-error`) —
is in `templates/eslint.config.js`.

Triage remaining first-run findings by silencing noisy rules in config (with a
WHY comment), never by removing the plugin.

## Architecture tests (ArchUnitTS)

Before changing ArchUnitTS configuration, read
`~/.agents/notes/archunitts-traps.md` (if that note is not present, proceed and
record the assumption).

`archunit` enforces file/folder-level architecture: directional
layering and import-cycle freedom — the things review and ESLint don't catch. Two
files, both in `templates/src/`:

- `architecture.archunit.ts` — the **import wrapper**. Every spec imports
  `projectFiles` from here, never from `archunit` directly.
- `architecture.spec.ts` — the layer-isolation + cycle template (three TODOs:
  layer diagram, tsconfig path, `FORBIDDEN_EDGES`).

### Why the wrapper (do not "just import archunit")

The package-root failure and upstream history are in
[references/archunitts.md](references/archunitts.md). The executable invariant is:
pin `archunit` exactly and import `projectFiles` only through the shipped wrapper.

### Authoring the rules

- Scope to **layer isolation + cycle freedom**. Drop naming rules (overlap lint)
  and metrics (class-oriented, useless for function components).
- Derive `FORBIDDEN_EDGES` from the project's **actual** import hierarchy. Each
  row asserts a lower layer must not import a higher one. Encode current reality
  so the suite is green; if a desired edge is currently violated, either fix the
  small violation or relax the rule and note it.
- `architecture.spec.ts` runs under `npm test`, so it gates CI.
- **Prove non-vacuity**: temporarily invert a rule you know should fire, confirm
  it goes red, revert. An empty subject set fails by default (`allowEmptyTests`
  is false) — do not flip that on to silence a mis-globbed rule.

## Testing

- Vitest with `src/test/setup.ts` (jsdom + `@testing-library/jest-dom`)
- Co-locate `*.test.ts(x)` with the unit under test
- Prefer testing pure helpers in `features/*/lib` directly
- `@vitest/coverage-v8` with thresholds in `vitest.config.ts`

## Bringing an existing frontend to this standard

Do **not** flip everything in one pass. Follow the ladder in `scaffold-typescript`
("Bringing existing TypeScript to standard": dependencies and lockfile, Prettier
alone, strict lint, tsconfig flags one at a time with `noUncheckedIndexedAccess`
and `exactOptionalPropertyTypes` last, then the bans). A blocking weak gate beats
a non-blocking strict one. Frontend deltas only:

- **Prettier step:** do not `prettier --write` the verbatim `scaffold-ci` assets
  (`.github/ai-smells`, `.claude/review-policy.json`,
  `.github/workflows/review-tier.yml`); the template `.prettierignore` covers them,
  so copy it before running `--write`.
- **Strict lint step:** every `.ts`/`.tsx` must belong to a tsconfig (conflict 1 below).
- **Flags step:** the cheap flags first (`noImplicitOverride`,
  `noPropertyAccessFromIndexSignature`); conflict 2 below can force holding one back.

Worked example, one project's measurement on 2026-10-12 (not a rule; your counts
will differ): a large existing simulator frontend, measured on a copy.

| Change | Result |
|---|---|
| `noUncheckedIndexedAccess` alone | 428 own errors |
| `exactOptionalPropertyTypes` alone | 84 |
| `noPropertyAccessFromIndexSignature` alone | 168 |
| `noImplicitOverride` alone | 2 |
| all four flags | 682 errors in 186 files |
| `strictTypeChecked` + `stylisticTypeChecked` | 3560 errors in 598 files |
| house bans on top | +100 errors |
| `prettier --check .` | 1003 files would change |

Three practical conflicts to expect:

- **Files outside every tsconfig break `projectService`** ("was not found by the
  project service"): e2e specs, codegen output, extra `*.config.ts`. Add them to a
  tsconfig `include`, or ignore them in ESLint. (35 files in the example.)
- **Packages that ship `.ts`/`.tsx` sources are not suppressed by `skipLibCheck`.**
  A design-system package shipping sources reported errors under the new flags
  (89 in the example) that the consumer cannot fix; expect to hold a flag back or
  fix upstream.
- **Type-aware rules belong only in the typed block.** A ban block without
  `projectService` crashes on `switch-exhaustiveness-check` ("requires type
  information"); keep the bans in the same config as the typed preset.

## Checklist

When scaffolding or normalizing a frontend, verify:

- [ ] Vite + React + TypeScript project builds (`npm run build`)
- [ ] Node is at least 24.15.0 on the Node 24 line; `package.json` carries the engine floor
- [ ] Config copied from `templates/`; deps at/above the version floor
- [ ] Feature-first `src/` for new projects (existing flat layout may stay this pass)
- [ ] ESLint flat config with `strictTypeChecked` + `stylisticTypeChecked`, react-hooks, react-refresh
- [ ] `eslint-plugin-sonarjs` full recommended at `warn`; noise rules off;
      `eslint .` exits 0
- [ ] Gate green in order: `prettier --check .`, `eslint .`, `npm run build`, `vitest run`
- [ ] cognitive-complexity advisory on, cyclomatic-complexity off
- [ ] Vitest + Testing Library + jsdom wired with `src/test/setup.ts`;
      `@vitest/coverage-v8` added with coverage thresholds in `vitest.config.ts`
- [ ] ArchUnitTS wired: `archunit` pinned exactly, `architecture.archunit.ts`
      wrapper copied, `architecture.spec.ts` with real `FORBIDDEN_EDGES`,
      non-vacuity proven, spec green under `npm test`
- [ ] All deps on latest mutually compatible releases (except `archunit`, pinned exactly)

Supporting files: Run `test/verify-template-contract.ps1`, `test/verify-version-floor.ps1`, `test/verify-build-gate.ps1` for local contract checks.
