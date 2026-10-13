$ErrorActionPreference = 'Stop'
$skillRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$templateRoot = Join-Path $skillRoot 'templates'
$packagePath = Join-Path $templateRoot 'package.json'
$package = Get-Content $packagePath -Raw | ConvertFrom-Json
$skill = Get-Content (Join-Path $skillRoot 'SKILL.md') -Raw
$architecture = Get-Content (Join-Path $templateRoot 'src' 'architecture.spec.ts') -Raw
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('frontend-template-' + [guid]::NewGuid().ToString('N'))

foreach ($script in @{ test = 'vitest run'; coverage = 'vitest run --coverage'; build = 'tsc -b && vite build' }.GetEnumerator()) {
    if ($package.scripts.($script.Key) -ne $script.Value) { throw "package template missing $($script.Key) script" }
}
if ($package.engines.node -ne '>=24.15.0 <25') { throw 'package template Node floor drifted' }
foreach ($dependency in 'typescript','typescript-eslint','vitest','@vitest/coverage-v8','jsdom','archunit','@testing-library/react','@testing-library/jest-dom') {
    if (-not $package.devDependencies.PSObject.Properties.Name.Contains($dependency)) { throw "package template missing $dependency" }
}
if ($package.devDependencies.archunit -ne '2.4.0') { throw 'archunit must remain exact' }
if ($package.devDependencies.vitest -ne $package.devDependencies.'@vitest/coverage-v8') { throw 'vitest and @vitest/coverage-v8 must use the same range' }

foreach ($note in '~/.agents/notes/npm-publishing-traps.md','~/.agents/notes/web-ui-traps.md','~/.agents/notes/archunitts-traps.md') {
    if ($skill -notmatch [regex]::Escape($note)) { throw "skill missing canonical note: $note" }
}
if ($architecture -notmatch [regex]::Escape('*.{test,spec,archunit}.*')) { throw 'architecture wrapper is not excluded from its own graph' }
if ($skill -notmatch [regex]::Escape('npm exec --silent --yes --package=typescript@<version> --call "tsc --showConfig --project <config>"')) {
    throw 'skill missing npm 11-compatible TypeScript config verification command'
}

# Test sources must belong to a project: without tsconfig.test.json referenced from the
# root solution file, `tsc -b` type-checks app and node config while Vitest transpiles
# test files with no type-checking - both stay green on a type-broken test.
$rootTsconfig = Get-Content (Join-Path $templateRoot 'tsconfig.json') -Raw | ConvertFrom-Json
if (-not ($rootTsconfig.references.path -contains './tsconfig.test.json')) {
    throw 'tsconfig.json must reference ./tsconfig.test.json so test sources are type-checked'
}
$testTsconfigPath = Join-Path $templateRoot 'tsconfig.test.json'
if (-not (Test-Path $testTsconfigPath)) { throw 'templates/tsconfig.test.json is missing' }

# House TypeScript tightenings (owned by scaffold-typescript, adopted here). Real values,
# parsed - a flag mentioned in a comment must not satisfy these.
foreach ($config in 'tsconfig.app.json','tsconfig.node.json','tsconfig.test.json') {
    $options = (Get-Content (Join-Path $templateRoot $config) -Raw | ConvertFrom-Json).compilerOptions
    foreach ($flag in 'noUncheckedIndexedAccess','exactOptionalPropertyTypes','noPropertyAccessFromIndexSignature','noImplicitOverride') {
        if ($options.$flag -ne $true) { throw "$config must set $flag to true" }
    }
}

$tsTemplates = Join-Path $skillRoot '..' 'scaffold-typescript' 'templates'
foreach ($file in '.prettierrc.json','.prettierignore') {
    $mine = Join-Path $templateRoot $file
    if (-not (Test-Path $mine)) { throw "templates/$file is missing" }
    if (-not (Test-Path $tsTemplates)) { Write-Host "SKIP: scaffold-typescript not present in this tree; templates/$file not compared"; continue }
    if ((Get-Content $mine -Raw) -ne (Get-Content (Join-Path $tsTemplates $file) -Raw)) { throw "templates/$file differs from scaffold-typescript's" }
}
if ($package.scripts.format -ne 'prettier --check .') { throw 'package template format script must be "prettier --check ."' }
if ($package.scripts.lint -ne 'eslint .') { throw 'package template lint script must be "eslint ."' }
if ($package.scripts.typecheck -ne 'tsc -b') { throw 'package template typecheck script must be "tsc -b"' }
$ignoreLines = (Get-Content (Join-Path $templateRoot '.prettierignore')).Trim()
foreach ($entry in 'dist','coverage','.github/ai-smells','.claude/review-policy.json','.github/workflows/review-tier.yml') {
    if ($ignoreLines -notcontains $entry) { throw ".prettierignore must list '$entry' on its own line" }
}
if ($package.scripts.gate -ne 'npm run format && npm run lint && npm run build && npm test') { throw 'package template gate script must chain format, lint, build, test in that order' }
if (Test-Path $tsTemplates) {
    $tsPackage = Get-Content (Join-Path $tsTemplates 'package.json') -Raw | ConvertFrom-Json
    if ($package.devDependencies.prettier -ne $tsPackage.devDependencies.prettier) { throw 'prettier devDependency must match the scaffold-typescript floor' }
} else {
    Write-Host 'SKIP: scaffold-typescript not present in this tree; prettier floor not compared'
}

# ESLint: usage form, not bare mentions (a comment naming a ban would pass a bare grep).
$eslint = (Get-Content (Join-Path $templateRoot 'eslint.config.js') -Raw)
$eslintCode = [regex]::Replace($eslint, '(?m)^\s*//.*$|\s//.*$', '')
$eslintRequired = [ordered]@{
    'strictTypeChecked in extends'  = 'tseslint\.configs\.strictTypeChecked\s*,'
    'stylisticTypeChecked in extends' = 'tseslint\.configs\.stylisticTypeChecked\s*,'
    'projectService'                = 'parserOptions:\s*\{\s*projectService:\s*true,\s*tsconfigRootDir:\s*import\.meta\.dirname'
    'switch-exhaustiveness-check'   = "'@typescript-eslint/switch-exhaustiveness-check':\s*'error'"
    'Date.now ban'                  = "'no-restricted-properties':\s*\[\s*'error',\s*\{\s*object:\s*'Date',\s*property:\s*'now'"
    'bare new Date ban'             = "selector:\s*`"NewExpression\[callee\.name='Date'\]\[arguments\.length=0\]`""
    'enum ban'                      = "selector:\s*'TSEnumDeclaration'"
    'default export ban'            = "selector:\s*'ExportDefaultDeclaration'"
    'setTimeout ban scoped to test files' = "files:\s*\['\*\*/\*\.\{test,spec\}\.\{ts,tsx\}'\],\s*rules:\s*\{\s*'no-restricted-globals':\s*\[\s*'error',\s*\{\s*name:\s*'setTimeout'"
    'main block lists all three syntax bans' = "'no-restricted-syntax':\s*\['error',\s*noEnum,\s*noDefaultExport,\s*noBareNewDate\]"
    '*.config.ts block lists noEnum and noBareNewDate but not noDefaultExport' = "files:\s*\['\*\*/\*\.config\.ts'\],\s*rules:\s*\{\s*'no-restricted-syntax':\s*\['error',\s*noEnum,\s*noBareNewDate\]\s*\}"
    'clock boundary exemption'      = "files:\s*\['src/\*\*/clock\.\{ts,tsx\}'\],\s*rules:\s*\{\s*'no-restricted-syntax':\s*\['error',\s*noEnum,\s*noDefaultExport\],?\s*\}"
    'react-hooks kept'              = 'reactHooks\.configs\.flat\.recommended'
    'react-refresh kept'            = 'reactRefresh\.configs\.vite'
    'sonarjs spread-then-downgrade, unguarded' = "\.\.\.Object\.fromEntries\(\s*Object\.keys\(sonarjs\.configs\.recommended\.rules\)\.map\(\(name\) => \[name, 'warn'\]\),?\s*\)"
}
foreach ($item in $eslintRequired.GetEnumerator()) {
    if ($eslintCode -notmatch $item.Value) { throw "eslint.config.js missing: $($item.Key)" }
}
if ($eslintCode -match 'tseslint\.configs\.recommended') { throw 'eslint.config.js still extends tseslint.configs.recommended; strictTypeChecked replaces it' }

# The resolution half needs npm and the live registry. On a host with no npm the static
# assertions above still hold; say what did not run rather than failing the whole suite.
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP: npm not on PATH; package template resolution and tsconfig checks not run'
    return
}

# A registry blip must not fail the required gate on a PR that could not have caused it,
# so npm calls retry with backoff, and a failure whose output is network-shaped means
# "registry unreachable" (SKIP), not "template broken". Anything else - ERESOLVE, a peer
# conflict, a missing version - still throws.
function Test-RegistryUnreachable([string] $Output) {
    return $Output -match '(?i)EAI_AGAIN|ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ESOCKETTIMEDOUT|EAI_FAIL|E50[234]|ERR_SOCKET_TIMEOUT|EHOSTUNREACH|ENETUNREACH|fetch failed|network request to .* failed'
}

# Classifier self-test: every transient code npm 12 prints must take the retry/SKIP
# path (E502/E503/E504, ERR_SOCKET_TIMEOUT, EHOSTUNREACH, ENETUNREACH were the misses),
# and a genuine resolution failure must still throw.
foreach ($code in 'EAI_AGAIN','ENOTFOUND','ECONNREFUSED','ECONNRESET','ETIMEDOUT','ESOCKETTIMEDOUT','EAI_FAIL','E502','E503','E504','ERR_SOCKET_TIMEOUT','EHOSTUNREACH','ENETUNREACH') {
    if (-not (Test-RegistryUnreachable "npm error code $code")) { throw "Test-RegistryUnreachable misses transient npm code: $code" }
}
if (Test-RegistryUnreachable 'npm error code ERESOLVE') { throw 'Test-RegistryUnreachable swallows ERESOLVE; resolution failures must throw' }

function Invoke-NpmWithRetry([string] $What, [string[]] $Arguments, [string] $AllowedErrorPattern) {
    # Returns the captured output on success, $null when the registry stayed unreachable
    # through every retry (the caller must SKIP), and throws on any other failure. A
    # failure matching $AllowedErrorPattern is returned as output for the caller to judge.
    $output = ''
    foreach ($attempt in 1..3) {
        $output = & npm @Arguments 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return $output }
        if ($AllowedErrorPattern -and $output -match $AllowedErrorPattern) { return $output }
        if (-not (Test-RegistryUnreachable $output)) {
            throw "$What failed (exit $LASTEXITCODE):`n$output"
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)) }
    }
    return $null
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Copy-Item -LiteralPath $packagePath -Destination (Join-Path $tempRoot 'package.json')
    $install = Invoke-NpmWithRetry 'package template resolution' @('install', '--prefix', $tempRoot, '--package-lock-only', '--ignore-scripts', '--no-audit', '--no-fund')
    if ($null -eq $install) {
        Write-Host 'SKIP: npm registry unreachable after retries; package resolution and tsconfig checks not run'
        return
    }

    foreach ($config in 'tsconfig.app.json','tsconfig.node.json','tsconfig.test.json') {
        $path = Join-Path $templateRoot $config
        # --silent is load-bearing: npm 12 prefixes exec output with "npm notice run npx"
        # and "npm notice run 'tsc' ..." lines, which land in this capture and make the
        # ConvertFrom-Json below fail with "Unexpected character encountered" - a parse
        # error that reads as a broken tsconfig. Observed in node:22 with npm 12 installed.
        $shown = Invoke-NpmWithRetry "tsc --showConfig for $config" @('exec', '--silent', '--yes', '--package=typescript@6.0.3', '--', 'tsc', '--showConfig', '--project', $path) 'TS18003'
        if ($null -eq $shown) {
            Write-Host "SKIP: npm registry unreachable after retries; tsconfig checks for $config not run"
            return
        }
        if ($shown -match 'TS18003') {
            # TS18003 "No inputs were found": the bare templates/src holds only
            # test-family files (the app project legitimately resolves empty HERE; a
            # scaffolded project has app sources). Fall back to the raw compilerOptions.
            Write-Host "SKIP: $config has no inputs in the bare templates tree; strict asserted from raw JSON"
            $resolved = [pscustomobject]@{ compilerOptions = ((Get-Content $path -Raw) -replace '//.*', '' | ConvertFrom-Json).compilerOptions }
        }
        else { $resolved = $shown | ConvertFrom-Json }
        if ($resolved.compilerOptions.strict -ne $true) { throw "$config does not resolve strict=true" }
    }

    'scaffold-frontend template contract OK'
}
finally {
    if ($tempRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
