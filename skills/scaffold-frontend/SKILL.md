---
name: scaffold-frontend
description: Use when creating or normalizing a Vite + React + TypeScript frontend project to house conventions - ESLint, Vitest, ArchUnitTS, and dependency floors.
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
templates are the source of truth; the version table below pins the floor.

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
- **Test**: Vitest + `@testing-library/react` + `jsdom`; coverage via
  `@vitest/coverage-v8` with thresholds
- **Architecture tests**: `archunit` (npm package), via a local wrapper

Pin all deps to their latest **mutually compatible** releases at scaffold time.
The table below is the **floor** — the known-good set last amended in 2026-08;
bump within current peer ranges when scaffolding, but do not go below it.

| Package | Floor | Package | Floor |
|---|---|---|---|
| `vite` | ^8.0.16 | `eslint` | ^10.4.1 |
| `react` / `react-dom` | ^19.2.7 | `@eslint/js` | ^10.0.1 |
| `react-router` | ^8.0.1 | `typescript-eslint` | ^8.61.0 |
| `typescript` | **`~6.0.3`** (tilde, not caret) | `eslint-plugin-react-hooks` | ^7.1.1 |
| `@vitejs/plugin-react` | ^6.0.2 | `eslint-plugin-react-refresh` | ^0.5.2 |
| `vitest` | ^4.1.10 | `eslint-plugin-sonarjs` | ^4.0.3 |
| `@vitest/coverage-v8` | ^4.1.10 | `globals` | ^17.6.0 |
| `@testing-library/react` | ^16.3.2 | `@testing-library/user-event` | ^14.6.1 |
| `@testing-library/jest-dom` | ^7.0.0 | `jsdom` | ^30.0.1 |
| **`archunit`** | **`2.4.0` (exact, no caret)** | `@types/node` | ^24.13.3 |

`typescript-eslint` 8.x currently declares TypeScript `>=4.8.4 <6.1.0`, so
TypeScript 7 is not installable with this stack. Keep TypeScript on the latest
6.0.x release until that peer range expands; never bypass it with
`--legacy-peer-deps` or `--force`.

**That is why the range is `~6.0.3` and not `^6.0.3`.** A caret means
`>=6.0.3 <7.0.0`, which admits 6.1.0 — a version this same paragraph says is not
installable — so on the day 6.1.0 publishes, every fresh scaffold fails `npm install`
with `ERESOLVE` and the only documented recoveries are the two flags forbidden above.
The tilde pins the 6.0.x line the peer range actually allows. Widen it when
`typescript-eslint` widens, not before.

Use Node **24.15.0 or newer on the Node 24 line** for this stack, matching the
`engines.node` contract in `templates/package.json`. This satisfies Vite,
jest-dom, and jsdom 30 together; verify `node --version` before install.

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
  `test: vitest run` and coverage. Adapt only the package name and app/library
  dependencies; keep the toolchain mutually resolvable.
- `templates/eslint.config.js` — flat config: `js` + `typescript-eslint` +
  react-hooks + react-refresh + the full SonarJS recommended set, all SonarJS
  rules downgraded to `warn`, noise rules off (see below). Per-area override
  blocks (generated code, demo mocks, scripts, tests) are included as commented
  examples — keep each with a WHY.
- `templates/vitest.config.ts` — jsdom + `src/test/setup.ts` + test `include`,
  **plus a `coverage` block with `include: ['src/**']` and thresholds** (provider
  `v8`). The `coverage.include` is load-bearing: without it v8 counts only the
  files a test imported, so untested src files fall outside the denominator and
  the thresholds pass vacuously. Set the threshold floors from a real
  `--coverage` run over all of src, not the smaller test-touched-only figure.
  `globals: true` is deliberately omitted (tests import from `vitest`; this also
  keeps ArchUnitTS's root import from throwing).
- `templates/tsconfig.json` + `tsconfig.app.json` + `tsconfig.node.json` +
  `tsconfig.test.json` — bundler mode, strict, `target`/`lib` es2023. The test
  project owns `*.test.*`/`*.spec.*`/`*.archunit.*` and `src/test/**`, so test
  sources are type-checked by `tsc -b` instead of belonging to no project.
- Verify each resolved config with
  `npm exec --silent --yes --package=typescript@<version> --call "tsc --showConfig --project <config>"`.
  `--call` avoids npm-version-specific argument separator handling; treat empty
  output as failure before parsing JSON.
- `templates/src/test/setup.ts` — jest-dom matchers + explicit RTL cleanup
  (needed because globals are off). Add project-specific shims below the core.

## Static Analysis (eslint-plugin-sonarjs)

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

## Checklist

When scaffolding or normalizing a frontend, verify:

- [ ] Vite + React + TypeScript project builds (`npm run build`)
- [ ] Node is at least 24.15.0 on the Node 24 line; `package.json` carries the engine floor
- [ ] Config copied from `templates/`; deps at/above the version floor
- [ ] Feature-first `src/` for new projects (existing flat layout may stay this pass)
- [ ] ESLint flat config with `typescript-eslint`, react-hooks, react-refresh
- [ ] `eslint-plugin-sonarjs` full recommended at `warn`; noise rules off;
      `eslint .` exits 0
- [ ] cognitive-complexity advisory on, cyclomatic-complexity off
- [ ] Vitest + Testing Library + jsdom wired with `src/test/setup.ts`;
      `@vitest/coverage-v8` added with coverage thresholds in `vitest.config.ts`
- [ ] ArchUnitTS wired: `archunit` pinned exactly, `architecture.archunit.ts`
      wrapper copied, `architecture.spec.ts` with real `FORBIDDEN_EDGES`,
      non-vacuity proven, spec green under `npm test`
- [ ] All deps on latest mutually compatible releases (except `archunit`, pinned exactly)

Supporting files: Run `test/verify-template-contract.ps1`, `test/verify-version-floor.ps1`, `test/verify-build-gate.ps1` for local contract checks.
