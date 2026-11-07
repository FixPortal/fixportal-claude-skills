$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$main = Get-Content (Join-Path $root 'SKILL.md') -Raw
$axis = Get-Content (Join-Path $root 'references' 'axis-brief.md') -Raw
$stack = Get-Content (Join-Path $root 'references' 'stack-conventions.md') -Raw
# orchestration.md is READ, not merely existence-checked. The SKILL.md -> references/
# refactor moved the bulk of the policy prose here, so a check that never opened it
# reported "audit-tests policy OK" over exactly the file most likely to hold stale text.
$orchestrationPath = Join-Path $root 'references' 'orchestration.md'
$orchestration = if (Test-Path $orchestrationPath) { Get-Content $orchestrationPath -Raw } else { '' }
$words = ([regex]::Matches($main, '\b[\p{L}\p{N}][\p{L}\p{N}''.-]*\b')).Count

if ($words -gt 500) { throw "SKILL.md is $words words" }
if (-not (Test-Path $orchestrationPath)) { throw 'missing orchestration reference' }
# The HOST-UNVERIFIED branch was deleted once while verify-refute.md still produced the
# verdict, which routed an unexamined downstream risk into "effectively covered".
# Dash-agnostic on purpose: pinning one glyph is how a stale-text guard becomes
# unfireable (an ASCII hyphen in the needle against an en dash in the prose matches
# nothing and the check silently never fires).
foreach ($needle in 'HOST-UNVERIFIED', 'Unsettled\s*[-‐-―]\s*host evidence required', 'cites \*\*no test\*\*') {
    if ($orchestration -notmatch $needle) {
        throw "orchestration.md lost the HOST-UNVERIFIED handling: $needle"
    }
}
foreach ($stale in 'poll with a timeout', 'task.WaitAsync(5s)',
                    'DateTime.UtcNow.AddDays(n)` used as test data such as an expiry or settlement date. The distinction') {
    if (($axis + "`n" + $stack) -match [regex]::Escape($stale)) { throw "stale timing policy remains: $stale" }
}
foreach ($needle in 'scaffold-tests/references/async-and-timing.md',
                    'Conservative scheduling or disabled parallelism',
                    'Aggressive or unknown scheduling', 'WaitAsync(TimeSpan)',
                    'linked token with `CancelAfter`',
                    '**timing-defect** finding',
                    'separate `suite-hygiene` finding', 'NodaTime `LocalDate`') {
    if (($main + "`n" + $axis + "`n" + $stack) -notmatch [regex]::Escape($needle)) { throw "missing timing contract: $needle" }
}

# The delegation target must EXIST, not merely be named. Checking the string only proves
# the sentence is present; it cannot tell a live pointer from a dangling one, and the
# whole timing policy is delegated through it.
$timingPolicy = Join-Path (Split-Path $root -Parent) 'scaffold-tests' 'references' 'async-and-timing.md'
if (-not (Test-Path -LiteralPath $timingPolicy)) {
    throw "audit-tests delegates its timing rules to a file that does not exist: $timingPolicy"
}
# ...and it must actually carry the policy the delegation promises, so a gutted or
# renamed-away target is caught rather than silently followed into nothing.
$timingText = Get-Content -LiteralPath $timingPolicy -Raw
foreach ($needle in 'WaitAsync', 'CancelAfter', 'Conservative') {
    if ($timingText -notmatch [regex]::Escape($needle)) {
        throw "the canonical timing policy no longer carries '$needle'; audit-tests' delegation is empty"
    }
}

$budgetPolicy = Join-Path (Split-Path $root -Parent) 'scaffold-tests' 'references' 'ci-test-budgets.md'
if (-not (Test-Path -LiteralPath $budgetPolicy)) {
    throw "audit-tests delegates CI eligibility to a file that does not exist: $budgetPolicy"
}
$budgetText = Get-Content -LiteralPath $budgetPolicy -Raw
foreach ($needle in '30 seconds', '10 minutes', '15 aggregate runner-minutes', '45 minutes') {
    if ($budgetText -notmatch [regex]::Escape($needle)) { throw "canonical CI budget lost '$needle'" }
}
foreach ($needle in 'scaffold-tests/references/ci-test-budgets.md',
                    'recent CI run', 'TRX per-test durations', 'aggregate runner-minutes',
                    '30-second PR ceiling', '10-minute PR job ceiling',
                    '45-minute extended-job ceiling', 'weekly/manual extended lane') {
    if (($main + "`n" + $axis) -notmatch [regex]::Escape($needle)) { throw "missing CI cost audit contract: $needle" }
}
if ($axis -notmatch '(?is)suite-hygiene.*test.*30-second PR ceiling') {
    throw 'misplaced slow tests are not routed to suite-hygiene'
}
foreach ($needle in 'exactly one of `behaviour` | `suite-hygiene` | `measurement` | `n-a`',
                    '`invariant` is a **field**, not a kind') {
    if ($axis -notmatch [regex]::Escape($needle)) { throw "axis brief does not pin the findingKind enum: $needle" }
}
if ($axis -notmatch '(?is)measurement.*workflow.*aggregate runner-minutes') {
    throw 'workflow fan-out and budget controls are not routed to measurement'
}

# Delta mode is not executable without these. The "Audit modes" body was deleted in the
# SKILL.md -> references/ split while orchestration.md's Phase 0 step 7 still said
# "validate the baseline above" and the failure table still gated on the terms it defined
# - so the operator improvised baseline validity while the report claimed Delta legitimacy.
foreach ($needle in '## Audit modes', 'exactly one existing verified', 'mechanically complete') {
    if ($orchestration -notmatch [regex]::Escape($needle)) {
        throw "orchestration.md lost the delta-baseline definition: $needle"
    }
}
if ($orchestration.IndexOf('## Audit modes') -gt $orchestration.IndexOf('## Phase 0')) {
    throw '"Audit modes" must appear ABOVE Phase 0 - step 7 says "validate the baseline above"'
}
# Operator-misconception guidance, dropped once with no successor.
if ($orchestration -notmatch '(?m)^## Common mistakes') { throw 'orchestration.md lost its Common mistakes section' }
# Worker H cannot open the canonical policy unless the orchestrator resolves it into the
# run context; the brief's only path anchor is the AUDITED repo.
if ($orchestration -notmatch 'Canonical timing policy:') {
    throw 'worker H run-context does not carry the resolved canonical timing policy path'
}
if ($orchestration -match 'all four classes below') {
    throw 'row H still names the four-class taxonomy this skill removed'
}

# A build and passing tests leave formatter, analyzer, and lint regressions invisible;
# they cannot by themselves authorise a fix-pass push.
if ($orchestration -notmatch 'Build and tests\s+alone never authorize a push') {
    throw 'full local gate lets build and tests alone authorize a push'
}
if ($orchestration -notmatch 'repository-configured formatter, analyzer, and lint command') {
    throw 'full local gate does not require configured formatter, analyzer, and lint commands'
}
if ($orchestration -notmatch [regex]::Escape('record the configuration inspected and its absence')) {
    throw 'full local gate does not require absence evidence for an unconfigured tool class'
}

# Node TypeScript (Vitest) is its own stack. Anchored on the USAGE form (the detection
# rule and the table row), not on a bare mention of the name.
$nodeRule = [regex]::Match($orchestration, '`package\.json`\s+\+\s+`vitest\.config\.\*`\s+\+\s+`tsconfig\.json`')
$frontendRule = [regex]::Match($orchestration, '`package\.json`\s+\+\s+`vitest\.config\.\*`\s*/\s*`vite\.config\.\*`\s*(→|->)\s*frontend')
if (-not $nodeRule.Success) { throw 'orchestration.md step 4 lost the Node TypeScript (Vitest) detection rule (package.json + vitest.config.* + tsconfig.json)' }
if (-not $frontendRule.Success) { throw 'orchestration.md step 4 lost the frontend rule (vitest.config.* / vite.config.* -> frontend)' }
if ($nodeRule.Index -gt $frontendRule.Index) { throw 'orchestration.md step 4 must evaluate the Node TypeScript rule BEFORE the frontend rule' }
if ($orchestration -notmatch '(?s)`tsconfig\.json`.{0,60}no\s+`react`\s*/\s*`react-dom`.{0,400}→\s*Node TypeScript\s+\(Vitest\)') {
    throw 'Node TypeScript detection rule does not exclude react'
}
if ($orchestration -notmatch '(?s)`tsconfig\.json`.{0,300}\bno\s+`vite\.config\.\*`.{0,200}→\s*Node TypeScript\s+\(Vitest\)') {
    throw 'Node TypeScript detection rule does not exclude vite.config.*'
}
if ($orchestration -notmatch '(?s)`tsconfig\.json`.{0,400}\bno\s+`workspaces`\s+field.{0,200}→\s*Node TypeScript\s+\(Vitest\)') {
    throw 'Node TypeScript detection rule does not exclude a root package.json that declares workspaces'
}
if ($orchestration -notmatch '(?s)declares\s+`workspaces`,?\s+stays\s+frontend') {
    throw 'orchestration.md no longer keeps a workspaces root in the frontend rule'
}
if ($orchestration -notmatch 'per-package\s+classification\s+for\s+workspaces\s+is\s+not\s+defined') {
    throw 'orchestration.md does not say per-package classification for workspaces is undefined'
}
if ($orchestration -notmatch '(?s)`vitest\.config\.\*`,\s+no\s+`tsconfig\.json`\)\s+(also\s+)?stays\s+frontend') {
    throw 'orchestration.md does not state that a plain-JavaScript Vitest repo stays frontend'
}
if ($orchestration -notmatch '(?s)Node TypeScript \(Vitest\):\s+the\s+repository''s\s+own\s+`typecheck`,\s+`lint`,\s+`format`\s+\(check-only\),\s+`test`\s+and\s+`build`\s+scripts') {
    throw 'fix-pass full local gate lost the Node TypeScript (Vitest) clause'
}
if ($stack -notmatch '(?m)^- Node TypeScript \(Vitest\): no house default tool[^\r\n]*scaffold-typescript/references/architecture-tests\.md') {
    throw 'stack-conventions.md Node TypeScript architecture bullet must say "no house default tool" and cite scaffold-typescript/references/architecture-tests.md on the same line'
}
if ($stack -notmatch 'a Node service''s real env-parsing path, parsed once at startup') {
    throw 'stack-conventions.md configuration tests lost the Node service env-parsing wording'
}
if ($stack -match 'scaffold-typescript. spec' -or $stack -match 'frontend-owned and undecided') {
    throw 'stack-conventions.md architecture bullet carries stale wording about a spec that does not ship'
}
if ($orchestration -notmatch '(?s)`vite\.config\.\*`.{0,200}stays\s+frontend') {
    throw 'orchestration.md no longer says a vite.config / react repo stays frontend'
}
if ($orchestration -notmatch '\.NET plus Node TypeScript\s+\(Vitest\)\s*(→|->)\s*hybrid') {
    throw 'orchestration.md lost the .NET plus Node TypeScript -> hybrid rule'
}
if ($orchestration -notmatch 'Stack: <[^>]*Node TypeScript \(Vitest\)[^>]*>') {
    throw 'report-contract Stack: line does not list Node TypeScript (Vitest)'
}
if ($orchestration -notmatch 'no instrument covers this stack \(<label>\)' -or $orchestration -notmatch '`package\.json` with neither\s+Vite\s+nor\s+Jest\s+nor\s+Vitest\s*(→|->)\s*`Node`') {
    throw 'uncovered-stack label for plain Node lost or inconsistent with the Vitest stack'
}
if ($orchestration -match 'dedicated Node\s+TypeScript stack is not defined yet' -or $orchestration -match 'label the stack `Vitest \(Node TypeScript\)`') {
    throw 'orchestration.md still carries the interim Node TypeScript note'
}
if ($stack -notmatch '(?m)^\| Node TypeScript \(Vitest\) \| Vitest ') {
    throw 'stack-conventions.md table lost the Node TypeScript (Vitest) row'
}
if ($stack -notmatch 'scaffold-typescript/references/language-rules\.md') {
    throw 'stack-conventions.md does not point Node TypeScript at scaffold-typescript language-rules.md'
}

# Python (uv) row: every command in it must be runnable on the house scaffold-python layout
# (pytest/ruff/mypy only, no coverage dependency) and must name its procedures.
$orchFlat = $orchestration -replace '\s+', ' '
$pythonRow = [regex]::Match($stack, '(?m)^\| Python \(uv\) \|[^\r\n]*').Value
if (-not $pythonRow) { throw 'stack-conventions.md table lost the Python (uv) row' }
if ($pythonRow -notmatch [regex]::Escape('uv run --with coverage coverage run --branch -m pytest')) {
    throw 'Python (uv) coverage cell must run coverage via `uv run --with coverage` and pass --branch'
}
if (($pythonRow + "`n" + $axis) -match 'pytest --durations(?!=)') {
    throw 'pytest --durations needs its integer argument (--durations=0 --durations-min=0)'
}
if ($pythonRow -notmatch 'uv run --locked pytest --durations=0 --durations-min=0' -or $axis -notmatch 'uv run --locked pytest --durations=0 --durations-min=0') {
    throw 'stack-conventions.md and axis-brief.md must both carry the corrected pytest durations command'
}
if ($pythonRow -match 'run by the orchestrator' -or $pythonRow -notmatch 'break-and-revert[^|]*fix-slice\.md') {
    throw 'Python (uv) mutation cell must point at the break-and-revert in fix-slice.md, not an undefined orchestrator step'
}
if ($stack -notmatch 'Python \(uv\): [^\r\n]*scaffold-python/SKILL\.md' -or $stack -notmatch 'pytest\.mark\.parametrize') {
    throw 'stack-conventions.md lost the Python async pointer or the parametrize counterpart'
}
if ($orchFlat -notmatch [regex]::Escape('Python (uv) beside any other supported stack is likewise hybrid')) {
    throw 'orchestration.md has no hybrid rule for Python (uv)'
}
if ($orchFlat -notmatch [regex]::Escape('Python (uv): `uv run ruff check`, `uv run ruff format --check`, `uv run mypy` (with explicit paths when the repository configures no mypy `files` and has no CI equivalent) and `uv run pytest`')) {
    throw 'fix-pass full local gate has no Python (uv) line'
}
if ($orchFlat -notmatch [regex]::Escape('`npx tsc -b --noEmit` (only when a `tsconfig.json` exists)')) {
    throw 'frontend gate must run tsc only when a tsconfig.json exists (plain-JavaScript Vitest repos have none)'
}
if ($orchFlat -notmatch [regex]::Escape('looks for `ftdb-<owner>/<repo>`') -or $orchFlat -match 'ftdb-<basename') {
    throw 'sentinel key paragraph must describe the owner/repo key finishing-gate.sh uses, not the basename key'
}

"audit-tests policy OK — $words words"
