param(
    [string] $Instruction,
    [string] $DiffPath,
    [string] $FindingsPath,
    [string] $ContextPath,
    [string] $Model
)

# Records the model string the DRIVER actually handed this wrapper, which is the
# only way to tell a correct registry-id -> CLI-selector translation from one that
# resolved correctly and then passed the wrong string to the CLI. Both look
# identical in telemetry, and only the second produces a run by a model nobody
# selected.
if ($env:AR_TEST_MODEL_LOG) {
    # Serialised across processes, deliberately. The driver dispatches seats in
    # PARALLEL and each phase dispatches again, so several copies of this stub
    # append to one log at once - and a bare Add-Content SILENTLY DROPS writes it
    # cannot take the lock for. Measured on this box: 24 workers x 12 appends
    # produced 279 of 288 lines, 9 lost, none torn. A dropped line makes an
    # assertion looking for a model fail for a reason that has nothing to do with
    # selection, and - worse - makes an assertion expecting a model's ABSENCE pass
    # when it should not. verify-registry-selection.ps1 carried that flake as
    # UNVERIFIED from 2026-09-06 until this was measured.
    # Scoped to the LOG FILE, not to the stub. One fixed name serialises every
    # stub invocation in every concurrent run against each other, including runs
    # writing to different files - verify-registry-selection.ps1 alone uses two
    # ($modelLog, then $pinLog), and a second harness in another worktree adds
    # more. That is latency for no safety, and under load it risks the timeout
    # below firing for contention that has nothing to do with this file.
    #
    # The path is normalised and upper-cased FIRST. Two spellings of one path
    # ('<drive>\x\log.txt' vs '<drive>/x/LOG.TXT') would otherwise hash to two different
    # mutexes, leaving the writers unserialised against a single file - which is
    # precisely the dropped-append bug this guard exists to prevent, reintroduced
    # by the fix for it.
    $normalisedLog = [IO.Path]::GetFullPath($env:AR_TEST_MODEL_LOG)
    # Case-fold ONLY where the filesystem is case-insensitive. On Linux - which is
    # what CI runs - /x/log.txt and /x/LOG.TXT are DIFFERENT FILES, and folding them
    # together would serialise writers that share nothing. Windows is the opposite:
    # not folding leaves two spellings of one file unserialised, which is the
    # dropped-append bug this guard exists to prevent.
    if ([System.OperatingSystem]::IsWindows()) {
        $normalisedLog = $normalisedLog.ToUpperInvariant()
    }
    $logKey = [BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($normalisedLog)
        )
    ).Replace('-', '')
    $mutex = [System.Threading.Mutex]::new($false, "Global\AR_TEST_MODEL_LOG_$logKey")
    try {
        # A stub that cannot record is a stub that lies about what the driver did,
        # so time out loudly rather than skipping the write.
        if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(30))) {
            throw 'stub-capture-review.ps1 could not acquire the model-log mutex within 30s'
        }
        try { Add-Content -LiteralPath $env:AR_TEST_MODEL_LOG -Value $Model }
        finally { $mutex.ReleaseMutex() }
    }
    finally { $mutex.Dispose() }
}

if ($FindingsPath) {
    'F1: AGREE - selection fixture'
} else {
    @'
### Selection fixture
- **Severity:** Low
- **Location:** sample.txt:1
- **Trigger:** fixture
- **Issue:** fixture
- **Impact:** fixture
- **Suggested fix:** fixture
'@
}
