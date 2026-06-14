import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'
import sonarjs from 'eslint-plugin-sonarjs'
import { defineConfig, globalIgnores } from 'eslint/config'
// Projects with a shared design system can spread its ESLint configs here:
//   import { configs as designConfigs } from '@your-org/design/eslint'
//   ...designConfigs(),

export default defineConfig([
  globalIgnores(['dist', 'coverage']),
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      tseslint.configs.recommended,
      reactHooks.configs.flat.recommended,
      reactRefresh.configs.vite,
      // Full SonarJS recommended set (cognitive complexity + bug/code-smell rules).
      // Severities are downgraded to 'warn' below -- advisory, never build-breaking.
      sonarjs.configs.recommended,
    ],
    languageOptions: {
      ecmaVersion: 2020,
      globals: globals.browser,
    },
    rules: {
      // Every SonarJS rule runs as a warning, so findings surface in the editor
      // and CI logs without failing `eslint .`. cognitive-complexity keeps its
      // default threshold of 15.
      ...Object.fromEntries(
        Object.keys(sonarjs.configs.recommended.rules ?? {}).map(name => [name, 'warn']),
      ),
      // Silence SonarJS rules that are stylistic policy or false-positive noise,
      // not code-quality signals -- they otherwise bury the findings that matter.
      'sonarjs/file-header': 'off',                  // wants a licence header on every file
      'sonarjs/arrow-function-convention': 'off',    // pure formatting (single-param parens)
      'sonarjs/declarations-in-global-scope': 'off', // misfires on ESM/.d.ts module declarations
      'sonarjs/cyclomatic-complexity': 'off',        // gate on cognitive-complexity instead
      'sonarjs/no-reference-error': 'off',           // false-positives on type-only refs and DOM
                                                     // lib globals; tsc + typescript-eslint catch
                                                     // genuine reference errors (this rule can't
                                                     // see types).
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
    },
  },
  {
    // Build/codegen scripts run under Node (ESM), not the browser. Give them Node
    // globals so `process` resolves, and relax the variable-name rule that flags
    // the conventional ESM `__filename`/`__dirname` shims.
    files: ['scripts/**/*.ts'],
    languageOptions: { globals: globals.node },
    rules: { 'sonarjs/variable-name': 'off' },
  },
  {
    // Test files have different conventions from app code. Repeated literals are
    // readable fixtures; passing `undefined` exercises missing-prop paths;
    // `import * as X` is idiomatic for vi.spyOn module mocks; render-helper
    // components trip name rules that only make sense for shipped code; hardcoded
    // IPs are test data.
    files: ['**/*.{test,spec}.{ts,tsx}'],
    rules: {
      'sonarjs/no-duplicate-string': 'off',
      'sonarjs/no-undefined-assignment': 'off',
      'sonarjs/no-wildcard-import': 'off',
      'sonarjs/function-name': 'off',
      'sonarjs/no-hardcoded-ip': 'off',
      'sonarjs/no-implicit-dependencies': 'off',
    },
  },
  // Add narrowly-scoped project overrides below (e.g. generated code: max-lines
  // off; demo/mock generators: pseudo-random off). Keep each block commented with
  // WHY it is off -- a silenced rule with no rationale rots into cargo-cult config.
])
