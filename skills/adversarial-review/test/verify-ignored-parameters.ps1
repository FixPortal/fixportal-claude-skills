#Requires -Version 7
<#
.SYNOPSIS
    Asserts review wrappers WARN when handed an -Effort their CLI cannot apply.

.DESCRIPTION
    run-review.ps1's Build-Args introspects each wrapper and forwards -Effort to
    any wrapper that DECLARES the parameter. That tests the declaration, not the
    capability, and for two seats the two disagree:

      codex-review.ps1   `codex exec` exposes no clean effort flag
      kimi-review.ps1    `kimi --help` advertises no effort flag at all

    Both declare -Effort for contract symmetry, so reviewers.json's per-seat
    effort reaches them and cannot be applied. Discarding it silently is exactly
    how claude-review.ps1's dropped --effort survived review: the declaration
    convinced the driver the capability was real, and the adjudicator's
    effort:"max" was paper-only for as long as nobody captured the child's
    argument list.

    These wrappers cannot be fixed by forwarding -- there is no flag to forward
    to -- so the contract is that they SAY the effort was not applied. This test
    is what makes that contract real rather than a comment.

    The warnings are emitted before the CLI lookup so this runs with neither
    vendor CLI installed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$reviewDir = Split-Path -Parent $PSScriptRoot
$failures = 0

# A path that does not exist: -DiffPath is mandatory and must bind, but nothing
# should read it before the wrapper gives up for want of an instruction.
$absentDiff = Join-Path ([IO.Path]::GetTempPath()) ('no-such-diff-' + [Guid]::NewGuid().ToString('N') + '.patch')

function Assert-Warns {
    param(
        [string] $Wrapper,
        [string] $ExpectFragment
    )

    $path = Join-Path $reviewDir $Wrapper
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "FAIL $Wrapper not found at $path"
        $script:failures++
        return
    }

    # -Model is mandatory on every wrapper (seats resolve via the registry, so no
    # wrapper pins a default); an inert fixture id reaches the body, which warns
    # before any CLI lookup. codex-review.ps1's -m guard rejects non-native ids,
    # so the fixture never reaches the CLI there either.
    $output = (& pwsh -NoProfile -File $path -DiffPath $absentDiff -Effort 'high' -Model 'fixture-model' 2>&1 | Out-String)

    if ($output -like "*$ExpectFragment*") {
        Write-Host "ok   $Wrapper warns that the seat's -Effort was not applied"
    }
    else {
        Write-Host "FAIL $Wrapper accepted -Effort without saying it cannot apply it"
        Write-Host "     expected to contain: $ExpectFragment"
        Write-Host "     captured: $($output.Trim())"
        $script:failures++
    }
}

Assert-Warns -Wrapper 'codex-review.ps1' -ExpectFragment 'codex exec exposes no per-invocation effort flag'
Assert-Warns -Wrapper 'kimi-review.ps1'  -ExpectFragment 'the kimi CLI exposes no per-invocation effort flag'

# The negative half: grok-review.ps1 DOES forward -Effort as --reasoning-effort,
# so it must not claim the effort was dropped. Without this, warning
# unconditionally would satisfy every assertion above.
$grok = Join-Path $reviewDir 'grok-review.ps1'
if (Test-Path -LiteralPath $grok -PathType Leaf) {
    $quiet = (& pwsh -NoProfile -File $grok -DiffPath $absentDiff -Effort 'high' -Model 'fixture-model' 2>&1 | Out-String)
    if ($quiet -like '*effort flag*') {
        Write-Host 'FAIL grok-review.ps1 claimed it cannot apply an -Effort it does forward'
        Write-Host "     captured: $($quiet.Trim())"
        $failures++
    }
    else {
        Write-Host 'ok   grok-review.ps1 stays quiet about the -Effort it does forward'
    }
}
else {
    Write-Host "FAIL grok-review.ps1 not found at $grok"
    $failures++
}

if ($failures -gt 0) {
    Write-Error "$failures ignored-effort contract check(s) failed."
    exit 1
}
Write-Host 'ok   both effort-less seats declare their refusal'
exit 0
