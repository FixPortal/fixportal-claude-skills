/**
 * ArchUnitTS architecture spec (https://github.com/LukasNiessen/ArchUnitTS).
 *
 * File/folder-level architecture rules. Scope: the high-value, hard-to-eyeball
 * invariants only -- layer isolation and cycle freedom. (Naming and size-metric
 * rules were trialled and dropped: naming overlaps lint/convention, and
 * ArchUnitTS's metrics are class-oriented, of little use in a function-component
 * codebase.)
 *
 * TODO 1 -- replace the layer diagram below with this project's actual import
 * hierarchy (low -> high), then derive FORBIDDEN_EDGES from it.
 *
 * Layer diagram (example -- replace):
 *
 *   api/*          data fetching; depends on nothing UI
 *     |- lib/*     pure helpers; depend only on api/types
 *        |- hooks/*     depend on api + lib
 *           |- components/* presentational; depend on api + lib, NOT hooks/pages
 *              |- pages/*  composition; wires hooks + components
 *
 * Assertion style: we call `.check()` (every condition implements Checkable) and
 * assert on the returned Violation[] with plain `expect`. ArchUnitTS's
 * `toPassAsync` matcher only auto-registers under Vitest `globals: true`, which
 * this scaffold opts out of -- `projectFiles` therefore comes through the local
 * wrapper `./architecture.archunit`, which isolates the dist-internal deep import
 * and the exact-version pin it needs. See that file's header for the full story.
 */
import { describe, it, expect } from 'vitest'
import { projectFiles } from './architecture.archunit'

// TODO 2 -- set to the tsconfig that scopes this project's src tree. Resolves
// relative to the test runner's cwd (= package root under Vitest).
const TS_CONFIG = 'tsconfig.app.json'

// Test files (and the architecture specs themselves) reach across layers by
// design; exclude them from layering AND cycle rules. Matches the
// `*.{test,spec}.*` set vitest.config.ts uses — `*.spec.*` must be here too, or
// this spec file and its `.archunit` wrapper become nodes in their own analysis.
const EXCEPT_TESTS = { except: { withName: '*.{test,spec}.*' } }

// TODO 3 -- replace with this project's FORBIDDEN_EDGES. Each row asserts:
// nothing in `from` may import from `to`. Derive from the layer diagram: for each
// pair (low, high), lower layers must not depend on higher ones.
const FORBIDDEN_EDGES: ReadonlyArray<{
  from: string
  fromGlob: string
  to: string
  toGlob: string
}> = [
  // Example -- replace:
  { from: 'api',        fromGlob: '**/api/**',        to: 'hooks',      toGlob: '**/hooks/**'      },
  { from: 'api',        fromGlob: '**/api/**',        to: 'components', toGlob: '**/components/**' },
  { from: 'api',        fromGlob: '**/api/**',        to: 'pages',      toGlob: '**/pages/**'      },
  { from: 'lib',        fromGlob: '**/lib/**',        to: 'hooks',      toGlob: '**/hooks/**'      },
  { from: 'lib',        fromGlob: '**/lib/**',        to: 'components', toGlob: '**/components/**' },
  { from: 'lib',        fromGlob: '**/lib/**',        to: 'pages',      toGlob: '**/pages/**'      },
  { from: 'hooks',      fromGlob: '**/hooks/**',      to: 'components', toGlob: '**/components/**' },
  { from: 'hooks',      fromGlob: '**/hooks/**',      to: 'pages',      toGlob: '**/pages/**'      },
  { from: 'components', fromGlob: '**/components/**', to: 'hooks',      toGlob: '**/hooks/**'      },
  { from: 'components', fromGlob: '**/components/**', to: 'pages',      toGlob: '**/pages/**'      },
]

describe('architecture / layer isolation', () => {
  for (const edge of FORBIDDEN_EDGES) {
    it(`${edge.from} must not depend on ${edge.to}`, async () => {
      const violations = await projectFiles(TS_CONFIG)
        .inFolder(edge.fromGlob, EXCEPT_TESTS)
        .shouldNot()
        .dependOnFiles()
        .inFolder(edge.toGlob)
        .check()
      expect(violations).toEqual([])
    })
  }

  // If contexts (or other cross-cutting files) live outside a named folder,
  // target them by filename. Example:
  //
  // it('components must not depend on React contexts', async () => {
  //   const violations = await projectFiles(TS_CONFIG)
  //     .inFolder('**/components/**', EXCEPT_TESTS)
  //     .shouldNot()
  //     .dependOnFiles()
  //     .withName('*Context.tsx')
  //     .check()
  //   expect(violations).toEqual([])
  // })
})

describe('architecture / cycles', () => {
  it('the whole src tree is free of import cycles', async () => {
    const violations = await projectFiles(TS_CONFIG)
      .inFolder('**/src/**', EXCEPT_TESTS)
      .should()
      .haveNoCycles()
      .check()
    expect(violations).toEqual([])
  })
})
