---
name: scaffold-frontend
description: Use when creating a new frontend (Vite + React + TypeScript) project, or when applying standard frontend preferences to an existing one. Triggers include creating a new web UI, setting up Vite/React, scaffolding an SPA, adding or normalizing ESLint/Vitest config, or wiring static analysis (eslint-plugin-sonarjs) into a frontend. Sibling of scaffold-dotnet for the TypeScript/React side.
---

# Scaffold Frontend

## Overview

Apply standard frontend project preferences when creating new Vite + React +
TypeScript projects or normalizing existing ones. This is the TypeScript/React
counterpart to `scaffold-dotnet`. Existing projects should be updated to match
these preferences rather than rewritten.

## When to Use

- Creating a new frontend (SPA / dashboard / admin UI) from scratch
- Setting up or normalizing ESLint, Vitest, or TypeScript config on a frontend
- Wiring static analysis (`eslint-plugin-sonarjs`) into a frontend
- When asked to "scaffold", "set up", or "initialize" a web UI

## Reference Implementation

`<workdir>\fixportal-simulator-frontend` is the canonical reference for
**config and versions** — copy its ESLint/Vitest/Tailwind setup and match the
versions it pins, rather than improvising, unless upgrading deliberately. For
**source layout**, adopt the feature-first structure below — the reference repo
still uses a flat `src/` that predates this convention, so don't mirror its
folder layout.

## Preferences

### Stack and Tooling

- **Build**: Vite (latest), `type: module`
- **Framework**: React 19 + React Router
- **Language**: TypeScript (latest), strict
- **Lint**: ESLint flat config (`eslint.config.js`), `typescript-eslint`,
  `eslint-plugin-react-hooks`, `eslint-plugin-react-refresh`
- **Test**: Vitest + `@testing-library/react` + `jsdom`; coverage via
  `@vitest/coverage-v8`
- **Styling**: Tailwind (via `@tailwindcss/vite`)
- Pin all deps to latest release versions unless a peer-dep constraint forbids it.

### Project Structure

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

### Static Analysis (eslint-plugin-sonarjs)

Add `eslint-plugin-sonarjs` (latest, supports ESLint 10) to `devDependencies`.
Enable the **full recommended set**, but downgrade every Sonar rule to `warn`
(advisory, **non-blocking** — `eslint .` must still exit 0) and switch off the
rules that are stylistic policy or false-positive noise rather than quality
signals. Cognitive complexity is the complexity gate; do **not** also enable the
cyclomatic-complexity rule (it over-counts flat switch/ternary dispatch).

Wire it into the flat config like this:

```js
import sonarjs from 'eslint-plugin-sonarjs'
// ...
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      // ...existing extends...
      // Full SonarJS recommended set (cognitive complexity + bug/code-smell rules).
      // Severities are downgraded to 'warn' below — advisory, never build-breaking.
      sonarjs.configs.recommended,
    ],
    rules: {
      // Every SonarJS rule from the recommended set runs as a warning, not an error.
      ...Object.fromEntries(
        Object.keys(sonarjs.configs.recommended.rules ?? {}).map(name => [name, 'warn']),
      ),
      // Silence rules that are stylistic policy or false-positive noise, not quality
      // signals — they otherwise bury the findings that matter (~82% of first-run noise).
      'sonarjs/file-header': 'off',                  // wants a licence header on every file
      'sonarjs/arrow-function-convention': 'off',    // pure formatting (single-param parens)
      'sonarjs/declarations-in-global-scope': 'off', // misfires on ESM/.d.ts module declarations
      'sonarjs/cyclomatic-complexity': 'off',        // gate on cognitive-complexity instead
      // ...existing project rules...
    },
  },
```

Triage remaining first-run findings by silencing noisy rules in config, never by
removing the plugin.

### Testing

- Vitest with a `src/test/setup.ts` (jsdom + `@testing-library/jest-dom`)
- Co-locate `*.test.ts(x)` with the unit under test
- Prefer testing pure helpers in `features/*/lib` directly

## Checklist

When scaffolding or normalizing a frontend, verify:

- [ ] Vite + React + TypeScript project builds (`npm run build`)
- [ ] Feature-first `src/` structure in place
- [ ] ESLint flat config with `typescript-eslint`, react-hooks, react-refresh
- [ ] `eslint-plugin-sonarjs` added; full recommended set at `warn`; noise rules off; `eslint .` exits 0
- [ ] cognitive-complexity gate on, cyclomatic-complexity off
- [ ] Vitest + Testing Library + jsdom wired with `src/test/setup.ts`
- [ ] All deps on latest release versions
