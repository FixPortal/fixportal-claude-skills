#requires -Version 7
<#
.SYNOPSIS
  Asserts the model-log capture stub does not lose appends under concurrency.

.DESCRIPTION
  (verify-registry-selection.ps1 needs the model-registry sibling skill and is not
  published in this tree; verify-registry-optional.ps1 reads the same log.)
  verify-registry-selection.ps1 decides whether the driver handed each wrapper the
  right model string, and it decides it by reading a log the capture stub appends
  to. The driver dispatches seats in PARALLEL, and each phase dispatches again, so
  several copies of that stub append to one file at once.

  A bare `Add-Content` silently DROPS appends it cannot take the file lock for.
  Measured on this box before the fix: 24 workers x 12 appends produced 279 of 288
  lines - 9 lost, none torn. That is why verify-registry-selection.ps1 failed once
  in a full-suite pass on 2026-09-06, passed on three re-runs, and carried the
  cause as UNVERIFIED in its own comments until it was measured here.

  The dangerous half is not the false failure. An assertion that a model is ABSENT
  passes when the line proving otherwise was dropped - a selection defect reported
  as clean.

  This test runs the real stub from several processes at once and asserts every
  append survives intact.
#>
[CmdletBinding()]
param(
    [int] $Workers = 8,
    [int] $Rounds = 3
)

$ErrorActionPreference = 'Stop'

$stub = Join-Path $PSScriptRoot 'fixtures/stub-capture-review.ps1'
if (-not (Test-Path -LiteralPath $stub)) { throw "capture stub not found: $stub" }

$log = Join-Path ([IO.Path]::GetTempPath()) ('ar-model-log-' + [Guid]::NewGuid().ToString('N') + '.txt')
# Long enough that a partial write would be obvious, and shaped like a real
# selector so a naive substring assertion elsewhere would still match it.
$model = 'kimi-code/kimi-for-coding-concurrency-probe'

try {
    $jobs = 1..$Workers | ForEach-Object {
        Start-Job -ScriptBlock {
            param($stub, $log, $model, $rounds)
            $env:AR_TEST_MODEL_LOG = $log
            for ($i = 0; $i -lt $rounds; $i++) {
                & pwsh -NoProfile -File $stub -Model $model -DiffPath 'x' | Out-Null
            }
        } -ArgumentList $stub, $log, $model, $Rounds
    }
    $jobs | Wait-Job | Out-Null
    $jobs | Remove-Job

    $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
    $expected = $Workers * $Rounds

    if ($lines.Count -ne $expected) {
        throw "the capture stub lost appends under concurrency: expected $expected lines, got $($lines.Count). A dropped line makes a selection assertion fail for no reason, or pass when it should not."
    }

    $bad = @($lines | Where-Object { $_ -ne $model })
    if ($bad.Count -gt 0) {
        throw "the capture stub wrote $($bad.Count) malformed line(s); first: [$($bad[0])]"
    }

    Write-Host "ok   capture stub kept all $expected appends under $Workers concurrent writers"

    # The mutex name is derived from the log PATH, so two spellings of one file must
    # still serialise. If the derivation skipped normalisation, '<drive>\x\log.txt' and
    # '<drive>/x/LOG.TXT' would hash to different mutexes and the writers would not be
    # serialised against each other at all - the dropped-append bug reintroduced by
    # its own fix, and invisible because each spelling looks correctly guarded.
    # A redundant '.' segment is the same file on EVERY platform, and
    # [IO.Path]::GetFullPath collapses it on both. Case is deliberately NOT used
    # here: on Linux, which is what CI runs, 'LOG.TXT' is a different file from
    # 'log.txt', so a case variant would be testing a Windows-only truth - and it
    # did, failing this suite on the Linux runner while passing locally.
    $dir = Split-Path -Parent $log
    $leaf = Split-Path -Leaf $log
    $spellings = @(
        $log,
        (Join-Path (Join-Path $dir '.') $leaf)
    )

    $jobs = 1..$Workers | ForEach-Object {
        $spelling = $spellings[($_ - 1) % $spellings.Count]
        Start-Job -ScriptBlock {
            param($stub, $log, $model, $rounds)
            $env:AR_TEST_MODEL_LOG = $log
            for ($i = 0; $i -lt $rounds; $i++) {
                & pwsh -NoProfile -File $stub -Model $model -DiffPath 'x' | Out-Null
            }
        } -ArgumentList $stub, $spelling, $model, $Rounds
    }
    $jobs | Wait-Job | Out-Null
    $jobs | Remove-Job

    $mixed = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
    $mixedExpected = $expected * 2
    if ($mixed.Count -ne $mixedExpected) {
        throw "writers using different spellings of ONE log path were not serialised against each other: expected $mixedExpected lines, got $($mixed.Count). The mutex name must be derived from a normalised path."
    }

    Write-Host "ok   two spellings of one log path share a mutex ($mixedExpected appends kept)"

    # Case-insensitivity is a WINDOWS property. Asserting it on Linux would assert
    # that two different files are one file, which is how this suite passed locally
    # and failed on the CI runner.
    if ([System.OperatingSystem]::IsWindows()) {
        $caseLog = Join-Path ([IO.Path]::GetTempPath()) ('ar-case-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $caseSpellings = @($caseLog, $caseLog.ToUpperInvariant())

        $jobs = 1..$Workers | ForEach-Object {
            $spelling = $caseSpellings[($_ - 1) % $caseSpellings.Count]
            Start-Job -ScriptBlock {
                param($stub, $log, $model, $rounds)
                $env:AR_TEST_MODEL_LOG = $log
                for ($i = 0; $i -lt $rounds; $i++) {
                    & pwsh -NoProfile -File $stub -Model $model -DiffPath 'x' | Out-Null
                }
            } -ArgumentList $stub, $spelling, $model, $Rounds
        }
        $jobs | Wait-Job | Out-Null
        $jobs | Remove-Job

        $cased = @(Get-Content -LiteralPath $caseLog -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath $caseLog -Force -ErrorAction SilentlyContinue
        if ($cased.Count -ne $expected) {
            throw "on Windows, two CASE variants of one log path were not serialised: expected $expected lines, got $($cased.Count)."
        }
        Write-Host "ok   two case variants of one log path share a mutex on Windows ($expected appends kept)"
    }
    else {
        Write-Host 'SKIP: case-variant serialisation is a Windows-only property - this filesystem is case-sensitive'
    }

    exit 0
}
finally {
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
