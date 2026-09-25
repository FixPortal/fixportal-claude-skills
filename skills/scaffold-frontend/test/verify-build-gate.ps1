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
    Copy-Item -Path (Join-Path $templateRoot '*') -Destination $fixtureRoot -Recurse

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

createRoot(document.getElementById('root')!).render(<App />)
'@

    $validApp = @'
export function App() {
  const label: string = 'ok'
  return <p>{label}</p>
}
'@
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'src' 'App.tsx') -Value $validApp

    $install = Invoke-WithRetry 'fixture npm install' 'npm' @('install', '--no-audit', '--no-fund') $fixtureRoot
    if ($null -eq $install) {
        Write-Host 'SKIP: npm registry unreachable after retries; build-gate check not run'
        $global:LASTEXITCODE = 0
        return
    }
    if (-not $install.Ok) { throw "fixture npm install failed:`n$($install.Output)" }

    $distDir = Join-Path $fixtureRoot 'dist'

    $validBuild = Invoke-WithRetry 'valid-source build' 'npm' @('run', 'build') $fixtureRoot
    if ($null -eq $validBuild) {
        Write-Host 'SKIP: npm registry unreachable after retries; build-gate check not run'
        $global:LASTEXITCODE = 0
        return
    }
    if (-not $validBuild.Ok) { throw "template build failed against valid sources (should have passed):`n$($validBuild.Output)" }
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
