# G1 (2026-09-25 test audit): the template's build script is `tsc -b && vite
# build` (package.json:9-15). Nothing in the suite proved that ordering is load-
# bearing: `vite build` alone does not type-check (esbuild strips types without
# checking them), so a TypeScript error that esbuild's transpile would ignore
# must still fail the combined build command before a bundle is written.
#
# This spins up a minimal generated-app fixture from the real template (not a
# stub), runs the real `npm run build` first against valid sources (must
# succeed, must produce dist/), then reintroduces the same command against a
# source with a type-only error (assignment type mismatch: no syntax error, so
# esbuild would happily transpile it) and asserts the command fails and does
# not (re)produce dist/. Mirrors verify-template-contract.ps1's npm
# retry/SKIP-on-unreachable-registry shape: a registry blip must not fail this
# gate, but any other npm/tsc/vite failure must.

$ErrorActionPreference = 'Stop'
$skillRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$templateRoot = Join-Path $skillRoot 'templates'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('frontend-build-gate-' + [guid]::NewGuid().ToString('N'))

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP: npm not on PATH; build-gate check not run'
    return
}

function Test-RegistryUnreachable([string] $Output) {
    return $Output -match '(?i)EAI_AGAIN|ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ESOCKETTIMEDOUT|EAI_FAIL|E50[234]|ERR_SOCKET_TIMEOUT|EHOSTUNREACH|ENETUNREACH|fetch failed|network request to .* failed'
}

function Invoke-WithRetry([string] $What, [string] $Exe, [string[]] $Arguments, [string] $WorkingDirectory) {
    # Returns @{ Ok = <bool exit0>; Output = <string> } on a real result, or $null
    # when the registry stayed unreachable through every retry (caller SKIPs).
    $output = ''
    foreach ($attempt in 1..3) {
        Push-Location $WorkingDirectory
        try { $output = & $Exe @Arguments 2>&1 | Out-String }
        finally { Pop-Location }
        if ($LASTEXITCODE -eq 0) { return @{ Ok = $true; Output = $output } }
        if (-not (Test-RegistryUnreachable $output)) { return @{ Ok = $false; Output = $output } }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)) }
    }
    return $null
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    # Copy the directory's CONTENTS with -Force: a '*' glob skips dotfiles on Unix.
    Get-ChildItem -LiteralPath $templateRoot -Force | Copy-Item -Destination $fixtureRoot -Recurse -Force

    # Guard: the fixture must carry every template dotfile (.prettierrc.json,
    # .prettierignore, ...). Without them Prettier silently runs on defaults and every
    # file fails, which reads as a broken template rather than a bad copy.
    $dropped = @(Get-ChildItem -LiteralPath $templateRoot -Force -File | Where-Object Name -like '.*' |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $fixtureRoot $_.Name)) } | ForEach-Object Name)
    if ($dropped.Count -gt 0) { throw "fixture copy dropped template dotfile(s): $($dropped -join ', ')" }

    # The template ships config only; a generated app also needs an entrypoint
    # and a Vite config. Keep both minimal and valid.
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'vite.config.ts') -Value @'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
})
'@

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'index.html') -Value @'
<!doctype html>
<html>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
'@

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'src' 'vite-env.d.ts') -Value '/// <reference types="vite/client" />'

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'src' 'main.tsx') -Value @'
import { createRoot } from 'react-dom/client'
import { App } from './App'

const root = document.getElementById('root')
if (root) createRoot(root).render(<App />)
'@

    $validApp = @'
export function App() {
  return <p>ok</p>
}
'@
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'src' 'App.tsx') -Value $validApp

    # The bare template is red by design (no app, and the architecture spec's layer
    # rules match no files). A generated app has the five layer folders, each with at
    # least one module, and at least one real test; add the smallest valid versions so
    # the whole house gate (format, lint, build, test) can be required green.
    foreach ($layer in 'api','lib','hooks','components','pages') {
        New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'src' $layer) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'src' $layer 'index.ts') -Value "export const layer = '$layer'"
    }
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'src' 'lib' 'greet.ts') -Value @'
export function greet(name: string): string {
  return `Hello, ${name}`
}
'@
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'src' 'lib' 'greet.test.ts') -Value @'
import { describe, expect, it } from 'vitest'
import { greet } from './greet'

describe('greet', () => {
  it('greets by name', () => {
    expect(greet('Ada')).toBe('Hello, Ada')
  })
})
'@

    # Set-Content appends the platform newline, so a Windows host writes CRLF-terminated
    # fixture files that `prettier --check` (the format step below) rightly flags.
    # Normalise every fixture file to LF with exactly one trailing newline.
    # Template-owned files are left byte-for-byte as shipped: they must pass on their own.
    foreach ($file in @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File -Include '*.ts','*.tsx','*.html')) {
        $relative = [IO.Path]::GetRelativePath($fixtureRoot, $file.FullName)
        if (Test-Path -LiteralPath (Join-Path $templateRoot $relative)) { continue }
        $text = ([IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n").TrimEnd() + "`n"
        [IO.File]::WriteAllText($file.FullName, $text)
    }

    $install = Invoke-WithRetry 'fixture npm install' 'npm' @('install', '--ignore-scripts', '--no-audit', '--no-fund') $fixtureRoot
    if ($null -eq $install) {
        Write-Host 'SKIP: npm registry unreachable after retries; build-gate check not run'
        $global:LASTEXITCODE = 0
        return
    }
    if (-not $install.Ok) { throw "fixture npm install failed:`n$($install.Output)" }

    $distDir = Join-Path $fixtureRoot 'dist'

    # The full house gate, each step on its own so a failure names the step, then the
    # chained `gate` script. Order is cheapest first: format, lint, build, test.
    foreach ($step in 'format','lint','build','test','gate') {
        $result = Invoke-WithRetry "valid-source $step" 'npm' @('run', $step) $fixtureRoot
        if ($null -eq $result) {
            Write-Host 'SKIP: npm registry unreachable after retries; build-gate check not run'
            $global:LASTEXITCODE = 0
            return
        }
        if (-not $result.Ok) { throw "template '$step' failed against a valid fixture app (should have passed):`n$($result.Output)" }
    }
    if (-not (Test-Path $distDir)) { throw 'template build reported success but produced no dist/ output' }
    Remove-Item -LiteralPath $distDir -Recurse -Force

    # Type-only error: `tsc -b`'s strict mode rejects this assignment, but
    # `vite build`'s esbuild transpile only strips the type annotation and would
    # emit it without complaint - exactly the case the combined script exists
    # to prevent Vite from bundling silently.
    $brokenApp = @'
export function App() {
  const label: string = 42
  return <p>{label}</p>
}
'@
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'src' 'App.tsx') -Value $brokenApp

    $brokenBuild = Invoke-WithRetry 'type-broken build' 'npm' @('run', 'build') $fixtureRoot
    if ($null -eq $brokenBuild) {
        Write-Host 'SKIP: npm registry unreachable after retries; build-gate check not run'
        $global:LASTEXITCODE = 0
        return
    }
    if ($brokenBuild.Ok) { throw "template build succeeded against a type-broken source; tsc -b is not gating vite build:`n$($brokenBuild.Output)" }
    if ($brokenBuild.Output -notmatch 'TS2322') { throw "type-broken build failed for an unexpected reason (expected TS2322 assignment-type error):`n$($brokenBuild.Output)" }
    if (Test-Path $distDir) { throw 'template build left a dist/ bundle after a type-checking failure' }

    # The last real command above (the intentionally-broken build) exits non-zero
    # by design; without resetting it here, this script's own process would exit
    # non-zero on SUCCESS, which the runner (ci.yml) would misread as a failure.
    $global:LASTEXITCODE = 0
    'scaffold-frontend build-gate check OK'
}
finally {
    if ($fixtureRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
