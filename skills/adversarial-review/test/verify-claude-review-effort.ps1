#requires -Version 7
<#
.SYNOPSIS
  Asserts claude-review.ps1 forwards -Effort to the claude CLI as --effort.

.DESCRIPTION
  The wrapper declares `[string] $Effort = 'high'` and its own help says the
  parameter "maps to `--effort`". It did not: $claudeArgs was built without the
  flag, so every value the driver passed was accepted and silently discarded.

  That silence had teeth. run-review.ps1 INTROSPECTS each wrapper and passes
  -Effort only to wrappers that declare the parameter - so declaring it is
  precisely what convinced the driver the capability was real. reviewers.json
  sets effort "high" on the Claude seat and "max" on the Opus adjudicator; both
  ran at the CLI's default instead, on every panel run, with nothing to show for
  it in any log.

  `claude --help` advertises `--effort <level>`, so the flag is real and the
  wrapper was the broken half.

  The test drives the wrapper against a fake `claude` on PATH that records its
  argument list, then asserts the flag is present with the value it was given.
  Args are checked even when the wrapper exits non-zero: the fake emits nothing
  the wrapper's stream-json parser can use, and the invocation is what is under
  test, not the parse.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$wrapper = Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-review.ps1'
if (-not (Test-Path -LiteralPath $wrapper)) { throw "wrapper not found: $wrapper" }

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('claude-effort-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

try {
    $fakeBin = Join-Path $sandbox 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null

    $brief = Join-Path $sandbox 'brief.txt'
    $diff = Join-Path $sandbox 'review-diff.txt'
    $capture = Join-Path $sandbox 'args.txt'
    $out = Join-Path $sandbox 'out.txt'

    Set-Content -LiteralPath $brief -Value 'Review this.'
    Set-Content -LiteralPath $diff -Value '+ changed line'

    # The wrapper runs `claude` from a throwaway working directory, so the capture
    # path must be absolute. It also pipes the prompt in on stdin; the fake drains
    # it so the pipeline does not block.
    Set-Content -LiteralPath (Join-Path $fakeBin 'claude.ps1') -Value @(
        '$input | Out-Null'
        "Set-Content -LiteralPath '$capture' -Value (`$args -join ' ')"
        '$global:LASTEXITCODE = 0'
        "'FAKE'"
    )

    $oldPath = $env:PATH
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
    try {
        $resolved = & pwsh -NoProfile -Command '(Get-Command claude).Source'
        if ($resolved -ne (Join-Path $fakeBin 'claude.ps1')) {
            throw "test double not resolved; got '$resolved'"
        }

        # This wrapper has no -OutPath: it returns the review on stdout. Passing one
        # is a parameter-binding failure that exits before the CLI is ever reached,
        # which looks exactly like the defect under test and proves nothing.
        & pwsh -NoProfile -File $wrapper -Instruction 'Review this.' -DiffPath $diff `
            -Model 'claude-opus-5' -Effort 'max' > $out 2>$null
        $wrapperExit = $LASTEXITCODE
    }
    finally {
        $env:PATH = $oldPath
    }

    if (-not (Test-Path -LiteralPath $capture)) {
        throw "the fake claude was never invoked (wrapper exited $wrapperExit); nothing to assert against"
    }

    $argsText = Get-Content -LiteralPath $capture -Raw

    # Anchors: prove the capture is a real invocation before judging the flag.
    foreach ($anchor in '--model claude-opus-5', '--permission-mode plan') {
        if ($argsText -notlike "*$anchor*") {
            throw "capture does not look like a real claude invocation, missing '$anchor': $argsText"
        }
    }

    if ($argsText -notlike '*--effort max*') {
        throw "claude-review.ps1 did not forward -Effort as '--effort max'. Captured args: $argsText"
    }

    Write-Host 'ok   claude-review.ps1 forwards -Effort to the claude CLI'
    exit 0
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
