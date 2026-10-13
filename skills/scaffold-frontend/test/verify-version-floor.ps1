$ErrorActionPreference = 'Stop'

# The shared TypeScript floor (typescript, typescript-eslint, vitest, @vitest/coverage-v8)
# is owned by scaffold-typescript; this skill's own table holds only frontend-only rows,
# none of which this check resolves through npm.
$sharedSkill = Join-Path $PSScriptRoot '..' '..' 'scaffold-typescript' 'SKILL.md'
# The floors live in a sibling skill the public mirror does not publish. Where it is absent,
# read the same rows from this skill's own SKILL.md, which reproduces them; every assertion
# below still runs (the private copy throws when the owner is missing).
if (Test-Path $sharedSkill) {
    $floorSource = $sharedSkill
} else {
    Write-Host 'NOTE: scaffold-typescript not present in this tree; reading the shared floors from this skill SKILL.md'
    $floorSource = Join-Path $PSScriptRoot '..' 'SKILL.md'
}
$skill = Get-Content $floorSource -Raw
$root = Join-Path ([IO.Path]::GetTempPath()) ('frontend-floor-' + [guid]::NewGuid().ToString('N'))

# Return the FLOOR itself - a bare version - not the documented RANGE. Scraping the cell
# verbatim yielded '^6.0.3', and npm resolves a caret to the newest matching release, so
# the install proved only "some 6.x works with typescript-eslint". The floor is the number
# the table actually promises, and it is the one that goes stale silently when a peer range
# moves under it. Pinning it exactly is the whole point of this check.
#
# The cell is parsed for a semver anywhere inside it, so table formatting (backticks, bold,
# a trailing "(tilde, not caret)" note) cannot break the extraction the way an exact-cell
# match would.
function Get-Floor([string] $package) {
    foreach ($row in $skill -split "`r?`n") {
        $cells = $row -split '\|'
        for ($index = 1; $index -lt $cells.Count - 1; $index += 2) {
            if ($cells[$index].Trim() -ne "``$package``") { continue }
            $cell = $cells[$index + 1]
            $version = [regex]::Match($cell, '\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?')
            if (-not $version.Success) { throw "No semver floor found for $package in table cell '$($cell.Trim())'" }
            return $version.Value
        }
    }
    throw "No version floor found for $package"
}

# Pure static comparison, so it runs before any npm / registry SKIP guard: the frontend
# template must not sit below the shared floor it inherits.
$template = Get-Content (Join-Path $PSScriptRoot '..' 'templates' 'package.json') -Raw | ConvertFrom-Json
foreach ($name in 'typescript','typescript-eslint','eslint','@eslint/js','eslint-plugin-sonarjs','globals','prettier','vitest','@vitest/coverage-v8','@types/node') {
    $declared = $template.devDependencies.$name
    if ($null -eq $declared) { throw "scaffold-frontend template lacks $name" }
    $have = [version]([regex]::Match($declared, '\d+\.\d+\.\d+').Value)
    if ($have -lt [version](Get-Floor $name)) { throw "frontend template $name $have is below the shared scaffold-typescript floor $(Get-Floor $name)" }
}

# This check resolves the documented floors against the live npm registry. On a host with
# no npm it cannot run at all - say so rather than failing the whole suite.
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP: npm not on PATH; documented version floors not resolved'
    return
}

# npm 10's arborist crashes with "Cannot read properties of null (reading 'edgesOut')"
# (npm/cli#9787) while loading this fixture's peer set, and that crash is indistinguishable
# from the floors themselves failing to resolve. Reproduced in node:22 - npm 10.9.8 dies on
# the exact fixture below, npm 12.0.2 resolves it in the same image - so an npm that old
# cannot answer the question this check asks. Say so rather than reporting a healthy floor
# as stale. CI pins npm 12 for the same reason, so this skip should never fire there.
#
# The version is validated before it is trusted: [int]'' is 0 in PowerShell, so an npm that
# fails or prints nothing would otherwise read as major 0, trip the guard below, and turn a
# check that never ran into a green suite.
$npmVersion = (& npm --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $npmVersion -notmatch '^(\d+)\.\d+\.\d+') {
    throw "npm --version reported no usable version (exit $LASTEXITCODE): '$npmVersion'"
}
$npmMajor = [int]$Matches[1]
if ($npmMajor -lt 11) {
    Write-Host "SKIP: npm $npmMajor hits the arborist 'edgesOut' peer-set crash (npm/cli#9787); documented floors not resolved"
    return
}

# A registry blip must not fail the required gate on a PR that could not have caused it,
# so the npm call retries with backoff, and a failure whose output is network-shaped means
# "registry unreachable" (SKIP), not "floors broken". A genuine resolution failure -
# ERESOLVE, a peer conflict, a yanked version - still throws.
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

function Invoke-NpmWithRetry([string] $What, [string[]] $Arguments) {
    # Returns the captured output on success, $null when the registry stayed unreachable
    # through every retry (the caller must SKIP), and throws on any other failure.
    $output = ''
    foreach ($attempt in 1..3) {
        $output = & npm @Arguments 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return $output }
        if (-not (Test-RegistryUnreachable $output)) {
            throw "$What failed (exit $LASTEXITCODE):`n$output"
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)) }
    }
    return $null
}

try {
    New-Item -ItemType Directory -Path $root | Out-Null
    [ordered]@{
        name = 'frontend-floor-fixture'
        private = $true
        devDependencies = [ordered]@{
            typescript = Get-Floor 'typescript'
            'typescript-eslint' = Get-Floor 'typescript-eslint'
            vitest = Get-Floor 'vitest'
            '@vitest/coverage-v8' = Get-Floor '@vitest/coverage-v8'
        }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'package.json') -Encoding utf8

    if ((Get-Floor 'vitest') -ne (Get-Floor '@vitest/coverage-v8')) {
        throw "Vitest $(Get-Floor 'vitest') and @vitest/coverage-v8 $(Get-Floor '@vitest/coverage-v8') must share their exact peer release"
    }

    $output = Invoke-NpmWithRetry 'documented TypeScript/typescript-eslint floors resolution' @('install', '--prefix', $root, '--package-lock-only', '--ignore-scripts', '--no-audit', '--no-fund')
    if ($null -eq $output) {
        Write-Host 'SKIP: npm registry unreachable after retries; documented floors not resolved'
        return
    }

    # The documented TypeScript range must not admit a version typescript-eslint's peer
    # range rejects. A caret does: '^6.0.3' is '>=6.0.3 <7.0.0', which includes 6.1.0 while
    # the prose says <6.1.0 is the limit - so the scaffold breaks on the day 6.1.0 ships,
    # and the documented recoveries are the two flags the same section forbids.
    $tsCell = [regex]::Match($skill, '\|\s*`typescript`\s*\|\s*([^|]+)').Groups[1].Value
    if ($tsCell -match '\^') {
        throw "TypeScript is documented with a caret range ('$($tsCell.Trim())'); typescript-eslint peer-declares <6.1.0, so a caret admits a version that cannot install"
    }

    "scaffold-frontend version floor OK (floors read from $(Split-Path (Split-Path $floorSource) -Leaf)/SKILL.md) — npm resolved TypeScript $(Get-Floor 'typescript') with typescript-eslint $(Get-Floor 'typescript-eslint'), Vitest $(Get-Floor 'vitest') with @vitest/coverage-v8 $(Get-Floor '@vitest/coverage-v8')"
}
finally {
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
