---
name: scaffold-frontend
description: Use when creating a new frontend (Vite + React + TypeScript) project, or when applying standard frontend preferences to an existing one. Triggers include creating a new web UI, setting up Vite/React, scaffolding an SPA, adding or normalizing ESLint/Vitest config, wiring static analysis (eslint-plugin-sonarjs), or adding architecture tests (ArchUnitTS) to a frontend.
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

- **Build**: Vite (latest), `type: module`
- **Framework**: React 19 + React Router (apps; a component library omits the router)
- **Language**: TypeScript (latest), strict, bundler module resolution
- **Lint**: ESLint flat config (`eslint.config.js`), `typescript-eslint`,
  `eslint-plugin-react-hooks`, `eslint-plugin-react-refresh`,
  `eslint-plugin-sonarjs`
- **Test**: Vitest + `@testing-library/react` + `jsdom`; coverage via
  `@vitest/coverage-v8` with thresholds
- **Architecture tests**: ArchUnitTS (`archunit`), via a local wrapper
- **Styling**: Tailwind (via `@tailwindcss/vite`)

Pin all deps to the latest release at scaffold time (unless a peer-dep
constraint forbids it). The table below is the **floor** — the known-good set as
of 2026-06; bump to current latest when scaffolding, but do not go below it.

| Package | Floor | Package | Floor |
|---|---|---|---|
| `vite` | ^8.0.16 | `eslint` | ^10.4.1 |
| `react` / `react-dom` | ^19.2.7 | `@eslint/js` | ^10.0.1 |
| `react-router` | ^8.0.1 | `typescript-eslint` | ^8.61.0 |
| `typescript` | ~6.0.3 | `eslint-plugin-react-hooks` | ^7.1.1 |
| `@vitejs/plugin-react` | ^6.0.2 | `eslint-plugin-react-refresh` | ^0.5.2 |
| `vitest` | ^4.1.6 | `eslint-plugin-sonarjs` | ^4.0.3 |
| `@vitest/coverage-v8` | ^4.1.8 | `globals` | ^17.6.0 |
| `@testing-library/react` | ^16.3.2 | `@tailwindcss/vite` | ^4.3.0 |
| `@testing-library/jest-dom` | ^6.9.1 | `tailwindcss` | ^4.2.2 |
| `@testing-library/user-event` | ^14.6.1 | `jsdom` | ^29.1.1 |
| **`archunit`** | **`2.3.0` (exact, no caret)** | `@types/node` | ^26 |

`archunit` is pinned **exactly** — see *Architecture tests* below for why.

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
- `templates/tsconfig.json` + `tsconfig.app.json` + `tsconfig.node.json` —
  bundler mode, strict, `target`/`lib` es2023.
- `templates/src/test/setup.ts` — jest-dom matchers + explicit RTL cleanup
  (needed because globals are off). Add project-specific shims below the core.

## Static Analysis (eslint-plugin-sonarjs)

Enable the **full recommended set**, downgrade every Sonar rule to `warn`
(advisory, **non-blocking** — `eslint .` must still exit 0), and switch off the
rules that are stylistic policy or false-positive noise. Cognitive complexity is
the complexity gate; do **not** also enable cyclomatic-complexity (it over-counts
flat switch/ternary dispatch). The wiring — the spread-then-downgrade pattern and
the off-list (`file-header`, `arrow-function-convention`,
`declarations-in-global-scope`, `cyclomatic-complexity`, `no-reference-error`) —
is in `templates/eslint.config.js`.

Triage remaining first-run findings by silencing noisy rules in config (with a
WHY comment), never by removing the plugin.

## Architecture tests (ArchUnitTS)

ArchUnitTS (`archunit`) enforces file/folder-level architecture: directional
layering and import-cycle freedom — the things review and ESLint don't catch. Two
files, both in `templates/src/`:

- `architecture.archunit.ts` — the **import wrapper**. Every spec imports
  `projectFiles` from here, never from `archunit` directly.
- `architecture.spec.ts` — the layer-isolation + cycle template (three TODOs:
  layer diagram, tsconfig path, `FORBIDDEN_EDGES`).

### Why the wrapper (do not "just import archunit")

Importing the package root (`archunit`) throws at import time under Vitest
`globals: false` — it eagerly registers a custom matcher needing a global
`expect`. This scaffold runs without globals, so the wrapper deep-imports the
compiled subpath `archunit/dist/src/files`, which skips that side-effect. That
subpath is dist-internal (`archunit` ships no `exports` map), so `archunit` is
pinned to an **exact** version, and the wrapper centralises both the deep import
and the pin to one line for clean upgrades.

A 2026-06 cross-vendor adversarial review verified that the upstream fix is a
**major-version change**, not a drive-by patch (the candidate behavioural fix
shipped a non-functional advertised opt-in; the candidate `exports` map was
itself breaking). So the wrapper is the pragmatic stance — not a fork, not a
speculative PR. When upstream fixes the root throw or ships an `exports` map,
only the wrapper changes.

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
- [ ] Config copied from `templates/`; deps at/above the version floor
- [ ] Feature-first `src/` for new projects (existing flat layout may stay this pass)
- [ ] ESLint flat config with `typescript-eslint`, react-hooks, react-refresh
- [ ] `eslint-plugin-sonarjs` full recommended at `warn`; noise rules off;
      `eslint .` exits 0
- [ ] cognitive-complexity gate on, cyclomatic-complexity off
- [ ] Vitest + Testing Library + jsdom wired with `src/test/setup.ts`;
      `@vitest/coverage-v8` added with coverage thresholds in `vitest.config.ts`
- [ ] ArchUnitTS wired: `archunit` pinned exactly, `architecture.archunit.ts`
      wrapper copied, `architecture.spec.ts` with real `FORBIDDEN_EDGES`,
      non-vacuity proven, spec green under `npm test`
- [ ] All deps on latest release versions
