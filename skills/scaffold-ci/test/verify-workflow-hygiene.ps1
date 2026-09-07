$ErrorActionPreference = 'Stop'

$script = Resolve-Path (Join-Path $PSScriptRoot '..' 'assets' 'assert_workflow_hygiene.py')
$root = Join-Path ([IO.Path]::GetTempPath()) ('workflow-hygiene-' + [guid]::NewGuid().ToString('N'))

$python = @('python3', 'python') |
    ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $python) {
    Write-Host 'SKIP: no python3/python on this host; workflow-hygiene parser not exercised'
    return
}
& $python.Source -c 'import yaml' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'SKIP: PyYAML not available; workflow-hygiene parser not exercised'
    return
}

$SHA = '3d39aea434753780c3b3d4a1a31c854b4dbf49d7'
$DIGEST = 'a' * 64

# The script resolves .github/workflows relative to the CURRENT DIRECTORY, exactly as it
# does on a runner whose working directory is the checkout. The test therefore builds a
# throwaway repo root and runs from inside it, rather than passing paths -- a harness
# that diverged from the invocation would be testing something the runner never does.
function Invoke-Hygiene([hashtable] $files) {
    $repo = Join-Path $root ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $repo '.github/workflows') -Force | Out-Null
    foreach ($relative in $files.Keys) {
        $target = Join-Path $repo $relative
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        $files[$relative] | Set-Content -LiteralPath $target -Encoding utf8
    }
    Push-Location $repo
    try {
        # No -S here, unlike the gate-coverage test: that asset is stdlib-only by
        # design, this one needs PyYAML from site-packages exactly as the runner does.
        $output = & $python.Source $script 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
    }
    finally { Pop-Location }
}

$clean = @'
name: ci
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: raven-actions/actionlint@SHAPLACEHOLDER # v2
'@ -replace 'SHAPLACEHOLDER', $SHA

# Acquired HERE, not at the top of the file: the restore lives in the `finally` of the
# `try` below, and the two SKIP paths above return before reaching it. Clobbering the
# variable before those returns left TRUSTED_THIRD_PARTY_ACTIONS empty in the calling
# session whenever python or PyYAML was missing -- and an empty value disables the
# checker's allowlist mode entirely, so the next in-session run silently stopped
# enforcing it. A fail-OPEN in the strictness this suite exists to prove. Contained only
# when run as `pwsh -NoProfile -File` (a separate process), which is how
# run-skill-tests.ps1 invokes it but not how a developer necessarily does.
$oldTrusted = $env:TRUSTED_THIRD_PARTY_ACTIONS
$env:TRUSTED_THIRD_PARTY_ACTIONS = ''
$oldNoCheckout = $env:PRIVILEGED_TRIGGER_NO_CHECKOUT
$env:PRIVILEGED_TRIGGER_NO_CHECKOUT = ''

try {
    New-Item -ItemType Directory -Path $root | Out-Null

    $ok = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $clean }
    if ($ok.Code -ne 0) { throw "a clean workflow must pass:`n$($ok.Output)" }
    if ($ok.Output -notmatch '1 workflow\(s\) scanned') { throw "pass message must state what was scanned:`n$($ok.Output)" }
    # A first-party ref on a vN release tag is the CONFORMANT shape -- house standard is
    # the inverse of the third-party rule (audit-ci grades a SHA-pinned first-party action
    # as drift), so a v7-pinned actions/checkout passes silently, counted in the summary.
    if ($ok.Output -notmatch 'first-party ref\(s\) on a vN release tag, conformant') {
        throw "a vN-tagged first-party ref must be counted conformant, not noticed as unpinned:`n$($ok.Output)"
    }

    # --- A first-party ref NOT on a vN tag is exactly as mutable as an unpinned
    #     third-party tag and must fail the same way -- a branch ref, or a bare name.
    foreach ($badRef in 'actions/checkout@main', 'actions/checkout') {
        $badFirstParty = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @"
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: $badRef
"@ }
        if ($badFirstParty.Code -ne 1 -or $badFirstParty.Output -notmatch 'not on a vN release tag') {
            throw "a first-party ref not on a vN tag ('$badRef') must fail:`n$($badFirstParty.Output)"
        }
    }

    # A dotted minor/patch release tag is still a vN tag.
    $dottedTag = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7.1.2
'@ }
    if ($dottedTag.Code -ne 0) { throw "a dotted vN.N.N release tag must pass:`n$($dottedTag.Output)" }

    # --- Privileged triggers, in both the key form and the list form.
    foreach ($trigger in 'pull_request_target', 'workflow_run') {
        $keyForm = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @"
on:
  ${trigger}:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
"@ }
        if ($keyForm.Code -ne 1) { throw "$trigger (key form) must fail:`n$($keyForm.Output)" }

        $listForm = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @"
on: [push, $trigger]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
"@ }
        if ($listForm.Code -ne 1) { throw "$trigger (list form) must fail - the key-anchored grep missed this:`n$($listForm.Output)" }
    }

    # --- PRIVILEGED_TRIGGER_NO_CHECKOUT: opt-in, file-scoped, and enforced rather than
    #     merely granted. Off by default so a new repo cannot inherit an exemption by
    #     accident; on, it still refuses the exempted file if it ALSO checks out code.
    $oldExempt = $env:PRIVILEGED_TRIGGER_NO_CHECKOUT
    $noCheckoutFixture = @'
on:
  pull_request_target:
    branches: [main]
permissions:
  contents: read
jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      - run: echo "label only, no checkout"
'@
    $exemptOff = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $noCheckoutFixture }
    if ($exemptOff.Code -ne 1) { throw "pull_request_target must still fail with no exemption set:`n$($exemptOff.Output)" }

    $env:PRIVILEGED_TRIGGER_NO_CHECKOUT = 'ci.yml'
    $exemptOn = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $noCheckoutFixture }
    if ($exemptOn.Code -ne 0) { throw "a named, no-checkout workflow must pass under the exemption:`n$($exemptOn.Output)" }

    $exemptButCheckout = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
on:
  pull_request_target:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
'@ }
    $env:PRIVILEGED_TRIGGER_NO_CHECKOUT = $oldExempt
    if ($exemptButCheckout.Code -ne 1 -or $exemptButCheckout.Output -notmatch 'also uses actions/checkout') {
        throw "an exempted workflow that ALSO checks out code must still fail - that is exactly the dangerous shape:`n$($exemptButCheckout.Output)"
    }

    # A workflow that never calls actions/checkout ITSELF but delegates to a local
    # composite action that does is exactly as dangerous, and a check of only the
    # workflow's own uses: refs misses it entirely.
    $env:PRIVILEGED_TRIGGER_NO_CHECKOUT = 'ci.yml'
    $exemptViaComposite = Invoke-Hygiene @{
        '.github/workflows/ci.yml' = @'
on:
  pull_request_target:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup
'@
        '.github/actions/setup/action.yml' = @'
name: setup
runs:
  using: composite
  steps:
    - uses: actions/checkout@v7
      shell: bash
'@
    }
    $env:PRIVILEGED_TRIGGER_NO_CHECKOUT = $oldExempt
    if ($exemptViaComposite.Code -ne 1 -or $exemptViaComposite.Output -notmatch 'also uses actions/checkout') {
        throw "an exempted workflow that checks out code THROUGH a local composite action must still fail:`n$($exemptViaComposite.Output)"
    }

    # --- Duplicate `on:` / YAML-1.1 `True:` key. Which one GitHub honours depends on the
    #     parser, so a trigger could hide in the one this check does not read.
    $dupKey = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
"on":
  pull_request:
    branches: [main]
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
'@ }
    if ($dupKey.Code -ne 1 -or $dupKey.Output -notmatch 'duplicate-key|both `on:`') {
        throw "a document carrying both on-key spellings must be refused:`n$($dupKey.Output)"
    }

    # --- write-all, at workflow and at job scope, bare and quoted.
    foreach ($value in 'write-all', "'write-all'", '"write-all"') {
        $wa = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @"
on:
  pull_request:
permissions: $value
jobs:
  build:
    runs-on: ubuntu-latest
"@ }
        if ($wa.Code -ne 1) { throw "write-all as $value must fail:`n$($wa.Output)" }
    }
    $jobScope = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    permissions: write-all
'@ }
    if ($jobScope.Code -ne 1) { throw "job-scope write-all must fail:`n$($jobScope.Output)" }

    # --- Pinning: third-party mutable tag fails; every immutable form passes.
    $mutable = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: raven-actions/actionlint@v2
'@ }
    if ($mutable.Code -ne 1) { throw "a third-party mutable tag must fail:`n$($mutable.Output)" }

    $quoted = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @"
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: "raven-actions/actionlint@$SHA"
"@ }
    if ($quoted.Code -ne 0) { throw "a QUOTED pinned ref must pass - the sed scanner kept the quotes and called this unpinned:`n$($quoted.Output)" }

    # --- Container and service images run code exactly as an action does.
    $unpinnedService = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    services:
      db: postgres:16
'@ }
    if ($unpinnedService.Code -ne 1) { throw "an unpinned SHORTHAND service image must fail:`n$($unpinnedService.Output)" }

    $unpinnedContainer = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: node:22
'@ }
    if ($unpinnedContainer.Code -ne 1) { throw "an unpinned container image must fail:`n$($unpinnedContainer.Output)" }

    $digestPinned = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @"
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: node@sha256:$DIGEST
    services:
      db:
        image: postgres@sha256:$DIGEST
"@ }
    if ($digestPinned.Code -ne 0) { throw "a bare sha256: digest is an immutable pin and must pass:`n$($digestPinned.Output)" }

    # --- A local composite action is this repo's own code, but what IT calls is not,
    #     and is invisible to a scan that stops at .github/workflows.
    $compositeBad = Invoke-Hygiene @{
        '.github/workflows/ci.yml' = @'
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup
'@
        '.github/actions/setup/action.yml' = @'
name: setup
runs:
  using: composite
  steps:
    - uses: raven-actions/actionlint@v2
      shell: bash
'@
    }
    if ($compositeBad.Code -ne 1 -or $compositeBad.Output -notmatch 'actionlint') {
        throw "an unpinned ref INSIDE a local composite action must fail:`n$($compositeBad.Output)"
    }

    # An action directory can end in YAML syntax without being a workflow.
    foreach ($suffix in '.yml', '.yaml') {
        foreach ($revision in @('v2', $SHA)) {
            $directoryAction = Invoke-Hygiene @{
                '.github/workflows/ci.yml' = $clean -replace "raven-actions/actionlint@$SHA", "./.github/actions/setup$suffix"
                ".github/actions/setup$suffix/action.yml" = @"
name: setup
runs:
  using: composite
  steps:
    - uses: raven-actions/actionlint@$revision
"@
            }
            $expected = if ($revision -eq $SHA) { 0 } else { 1 }
            if ($directoryAction.Code -ne $expected -or
                ($expected -eq 1 -and $directoryAction.Output -notmatch 'actionlint@v2')) {
                throw "an action directory ending in $suffix must check its nested pins:`n$($directoryAction.Output)"
            }
        }
    }

    $compositeMissing = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/absent
'@ }
    if ($compositeMissing.Code -ne 1 -or $compositeMissing.Output -notmatch 'no action.yml') {
        throw "a local ref with no manifest cannot resolve at run time and must fail:`n$($compositeMissing.Output)"
    }

    # --- Opt-in allowlist. OFF by default: defaulting it on would fail most of the
    #     estate, and a gate that reddens on adoption gets reverted rather than fixed.
    $allowlistOff = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $clean }
    if ($allowlistOff.Code -ne 0) { throw "with no allowlist set, a pinned third-party action must pass:`n$($allowlistOff.Output)" }

    $env:TRUSTED_THIRD_PARTY_ACTIONS = 'some-other/action'
    $allowlistOn = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $clean }
    $env:TRUSTED_THIRD_PARTY_ACTIONS = ''
    if ($allowlistOn.Code -ne 1 -or $allowlistOn.Output -notmatch 'TRUSTED_THIRD_PARTY_ACTIONS') {
        throw "with an allowlist set, an unlisted third-party action must fail even when pinned:`n$($allowlistOn.Output)"
    }

    $env:TRUSTED_THIRD_PARTY_ACTIONS = 'raven-actions/actionlint'
    $allowlistPass = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $clean }
    $env:TRUSTED_THIRD_PARTY_ACTIONS = ''
    if ($allowlistPass.Code -ne 0) { throw "a listed, pinned third-party action must pass:`n$($allowlistPass.Output)" }

    # An action in a SUBDIRECTORY of an already-trusted repo (owner/repo/subdir/action)
    # must match on owner/repo, not on the full path -- the allowlist names repositories.
    $subdirClean = @"
name: ci
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: raven-actions/actionlint/cmd/actionlint@$SHA
"@
    $env:TRUSTED_THIRD_PARTY_ACTIONS = 'raven-actions/actionlint'
    $subdirAllowlisted = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $subdirClean }
    $env:TRUSTED_THIRD_PARTY_ACTIONS = ''
    if ($subdirAllowlisted.Code -ne 0) {
        throw "a subdirectory action from an already-trusted owner/repo must match the allowlist entry:`n$($subdirAllowlisted.Output)"
    }

    # --- The checker must refuse to report a pass it cannot stand behind.
    $noWorkflows = Invoke-Hygiene @{}
    if ($noWorkflows.Code -ne 2) { throw "an empty workflows directory must exit 2, not report a clean pass:`n$($noWorkflows.Output)" }

    # An unterminated flow mapping: genuinely invalid YAML, unlike a merely odd
    # indentation, which the parser accepts.
    $unparsable = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
on: {pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
'@ }
    if ($unparsable.Code -eq 0 -or $unparsable.Output -notmatch 'Not parseable as YAML') {
        throw "an unparsable workflow must fail, not be skipped silently:`n$($unparsable.Output)"
    }

    # A workflow whose top level is not a mapping is not a workflow, and must not be
    # counted as scanned-and-clean.
    $notAMapping = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
- just
- a
- list
'@ }
    if ($notAMapping.Code -eq 0 -or $notAMapping.Output -notmatch 'not a mapping') {
        throw "a non-mapping document must fail:`n$($notAMapping.Output)"
    }

    # --- A MISSING PyYAML IS "COULD NOT RUN" (2), NOT "VIOLATION" (1). `sys.exit(str)`
    #     prints and exits 1, so a runner image without PyYAML reported as though the
    #     workflows were bad. Shadow the real yaml module with one that refuses to
    #     import, which is the runner condition without uninstalling anything.
    $shadow = Join-Path $root 'shadow'
    New-Item -ItemType Directory -Path $shadow -Force | Out-Null
    'raise ImportError("no yaml here")' | Set-Content -LiteralPath (Join-Path $shadow 'yaml.py') -Encoding utf8
    $repoForImport = Join-Path $root ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $repoForImport '.github/workflows') -Force | Out-Null
    $clean | Set-Content -LiteralPath (Join-Path $repoForImport '.github/workflows/ci.yml') -Encoding utf8
    $oldPythonPath = $env:PYTHONPATH
    $env:PYTHONPATH = $shadow
    Push-Location $repoForImport
    try { & $python.Source $script 2>&1 | Out-Null; $importCode = $LASTEXITCODE }
    finally { Pop-Location; $env:PYTHONPATH = $oldPythonPath }
    if ($importCode -ne 2) {
        throw "a runner image without PyYAML must exit 2 ('could not run'), not $importCode"
    }

    # --- THE TRUSTED ALLOWLIST NAMES ACTIONS, SO IT MUST NOT GATE IMAGES. Container and
    #     service images arrive as bare names, which also satisfy "third party"; because
    #     the allowlist test ran BEFORE is_pinned, a correctly digest-pinned image was
    #     failed for missing from an allowlist it could never be in.
    $pinnedImage = @'
name: ci
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    services:
      db:
        image: mcr.microsoft.com/mssql/server@sha256:BADGERBADGER
    steps:
      - uses: raven-actions/actionlint@SHAPLACEHOLDER # v2
'@ -replace 'SHAPLACEHOLDER', $SHA -replace 'BADGERBADGER', $DIGEST
    $env:TRUSTED_THIRD_PARTY_ACTIONS = 'raven-actions/actionlint'
    $imageUnderAllowlist = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $pinnedImage }
    $env:TRUSTED_THIRD_PARTY_ACTIONS = ''
    if ($imageUnderAllowlist.Code -ne 0) {
        throw "a digest-pinned container image must not be failed by the ACTIONS allowlist:`n$($imageUnderAllowlist.Output)"
    }

    # A Docker Hub ORG image has no registry host and no colon -- `bitnami/postgresql`
    # is exactly action-shaped -- so the host and colon tells miss it entirely and only
    # the `@sha256:` digest separates it from an action. Without that clause this is the
    # same defect the fix above set out to close, just one registry over.
    $hubImage = $pinnedImage -replace 'mcr\.microsoft\.com/mssql/server@sha256:', 'bitnami/postgresql@sha256:'
    $env:TRUSTED_THIRD_PARTY_ACTIONS = 'raven-actions/actionlint'
    $hubUnderAllowlist = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $hubImage }
    $env:TRUSTED_THIRD_PARTY_ACTIONS = ''
    if ($hubUnderAllowlist.Code -ne 0) {
        throw "a digest-pinned Docker Hub org image must not be failed by the ACTIONS allowlist:`n$($hubUnderAllowlist.Output)"
    }

    # A mutable image tag must still fail, allowlist mode or not -- muting the
    # misclassification must not mute the real check.
    $mutableImage = $pinnedImage -replace '@sha256:[0-9a-f]+', ':2022-latest'
    $mutableUnderAllowlist = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $mutableImage }
    if ($mutableUnderAllowlist.Code -eq 0) {
        throw "a mutable container image tag must still fail:`n$($mutableUnderAllowlist.Output)"
    }

    # --- A LOCAL `./` REF IS TWO DIFFERENT THINGS. A reusable-workflow call names a
    #     YAML FILE and has no action.yml; a composite action names a DIRECTORY that
    #     does. action_refs collects job-level `uses:` on purpose (pin checking), so
    #     without the distinction the manifest lookup demanded action.yml from every
    #     reusable workflow. That failed `Review policy intact` -- a REQUIRED check --
    #     in every repo with a reusable deploy workflow, so those repos could not merge
    #     at all. Found 2026-09-02 against ci-frontend, simulator-backend and
    #     simulator-frontend; latent until then only because no repo carrying the
    #     canonical copy happened to use one.
    $reusableWorkflow = @'
name: ci
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  deploy:
    uses: ./.github/workflows/_deploy.yml
    secrets: inherit
'@
    $deployed = @'
name: _deploy
on:
  workflow_call:
permissions:
  contents: read
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo deploying
'@
    $reusableOk = Invoke-Hygiene @{
        '.github/workflows/ci.yml'      = $reusableWorkflow
        '.github/workflows/_deploy.yml' = $deployed
    }
    if ($reusableOk.Code -ne 0) {
        throw "a job-level call to an existing reusable workflow must pass, not demand action.yml:`n$($reusableOk.Output)"
    }

    # The assertion still has to bite: a call to a reusable workflow that is not there
    # cannot resolve at run time either, so muting the manifest check must not mute this.
    $reusableMissing = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $reusableWorkflow }
    if ($reusableMissing.Code -eq 0 -or $reusableMissing.Output -notmatch 'Reusable workflow') {
        throw "a call to a NON-EXISTENT reusable workflow must still fail:`n$($reusableMissing.Output)"
    }

    # A composite action keeps the original treatment -- directory, with a manifest.
    $compositeMissing = Invoke-Hygiene @{ '.github/workflows/ci.yml' = @'
name: ci
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup
'@ }
    if ($compositeMissing.Code -eq 0 -or $compositeMissing.Output -notmatch 'action\.yml/action\.yaml') {
        throw "a local composite action with no manifest must still fail:`n$($compositeMissing.Output)"
    }

    # --- THE GUARD MUST NOT FLAG ITSELF. Its predecessor greps matched the comments
    #     explaining their own rules, so the guard failed in every repo it was installed
    #     into. A parser cannot do that -- this pins the property rather than assuming it.
    $selfScan = Invoke-Hygiene @{ '.github/workflows/ci.yml' = $clean; '.github/scripts/assert_workflow_hygiene.py' = (Get-Content $script -Raw) }
    if ($selfScan.Code -ne 0) { throw "the checker's own source in the repo must not trip it:`n$($selfScan.Output)" }

    'assert_workflow_hygiene.py OK - triggers (key/list/dup), no-checkout exemption, first-party vN-tag enforcement, write-all scopes, pin forms, container/services, composite recursion, reusable-workflow refs, opt-in allowlist, fail-closed'
}
finally {
    $env:TRUSTED_THIRD_PARTY_ACTIONS = $oldTrusted
    $env:PRIVILEGED_TRIGGER_NO_CHECKOUT = $oldNoCheckout
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
