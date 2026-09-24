$ErrorActionPreference = 'Stop'

$script = Resolve-Path (Join-Path $PSScriptRoot '..' 'assets' 'assert_gate_coverage.py')
$repoCopy = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '.github' 'scripts' 'assert_gate_coverage.py')
if (([IO.File]::ReadAllText($script) -replace "\r\n?", "`n") -cne ([IO.File]::ReadAllText($repoCopy) -replace "\r\n?", "`n")) {
    throw '.github/scripts/assert_gate_coverage.py has drifted from the canonical scaffold-ci asset'
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('gate-coverage-' + [guid]::NewGuid().ToString('N'))
# Interpreter discovery comes BEFORE the environment is touched. The skip below is a
# bare `return`, which does not run the restoring `finally` further down, so clearing
# the exemption variables first left GATE_EXEMPT / GATE_CONDITIONAL_EXEMPT /
# GATE_FILE_EXEMPT emptied for the rest of the session on any host without python -
# and an emptied exemption list is the fail-RED direction for every later caller.
#
# python3 first: the generated workflows invoke the shipped asset as `python3`, and
# `python` does not exist on a stock ubuntu runner. Bare `& python` made this test
# unrunnable on the very platform the asset ships to.
$python = @('python3', 'python') |
    ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $python) {
    Write-Host 'SKIP: no python3/python on this host; gate-coverage parser not exercised'
    return
}

$oldExempt = $env:GATE_EXEMPT
$oldConditionalExempt = $env:GATE_CONDITIONAL_EXEMPT
$oldFileExempt = $env:GATE_FILE_EXEMPT
$env:GATE_EXEMPT = ''
$env:GATE_CONDITIONAL_EXEMPT = ''
$env:GATE_FILE_EXEMPT = ''

function Invoke-Gate([string] $yaml, [switch] $Bom) {
    $workflow = Join-Path $root 'ci.yml'
    $output = Join-Path $root 'output.txt'
    # -Bom writes the SAME text with a leading UTF-8 BOM. PowerShell 7's `utf8` is
    # BOM-less and `utf8BOM` is the only way to get one, so no existing case could have
    # produced a BOM by accident -- which is how the BOM defect survived.
    $encoding = if ($Bom) { 'utf8BOM' } else { 'utf8' }
    $yaml | Set-Content -LiteralPath $workflow -Encoding $encoding
    & $python.Source -S $script $workflow *> $output
    [pscustomobject]@{
        Code = $LASTEXITCODE
        Output = Get-Content -LiteralPath $output -Raw
    }
}

try {
    New-Item -ItemType Directory -Path $root | Out-Null

    $flow = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  lint:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build, lint]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($flow.Code -ne 0) { throw "flow needs should pass without site packages:`n$($flow.Output)" }

    $block = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  lint:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs:
      - build
      - lint
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($block.Code -ne 0) { throw "block needs should pass without site packages:`n$($block.Output)" }

    $missing = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  lint:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: build
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($missing.Code -eq 0 -or $missing.Output -notmatch "not gated by 'ci-gate': lint") {
        throw "an omitted job must fail clearly:`n$($missing.Output)"
    }

    # A gate naming a job that does not exist (a typo in needs:) must fail with a
    # message, not a Python traceback from the feeder lookup.
    $undefinedNeed = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build, biuld]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($undefinedNeed.Code -eq 0 -or $undefinedNeed.Output -match 'Traceback' -or
        $undefinedNeed.Output -notmatch "needs undefined job\(s\): biuld") {
        throw "an undefined needs id must fail clearly, not crash:`n$($undefinedNeed.Output)"
    }

    # A feeder skipped through an exempt dependency must fail closed, and the remediation
    # text is copied straight into workflows, so it must be valid YAML: a bare
    # `if: !cancelled()` is read as a YAML tag, not an expression.
    $env:GATE_EXEMPT = 'optional'
    try {
        $skippedDependency = Invoke-Gate @'
jobs:
  optional:
    runs-on: ubuntu-latest
  quality:
    needs: [optional]
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [quality]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    }
    finally { $env:GATE_EXEMPT = '' }
    if ($skippedDependency.Code -eq 0 -or $skippedDependency.Output -notmatch 'dependency chain') {
        throw "a feeder skipped through an exempt needs dependency must fail closed:`n$($skippedDependency.Output)"
    }
    if ($skippedDependency.Output -match '`if: !cancelled\(\)`' -or
        $skippedDependency.Output -notmatch [regex]::Escape('`if: ${{ !cancelled() }}`')) {
        throw "the dependency-chain remediation must recommend a valid YAML spelling of !cancelled():`n$($skippedDependency.Output)"
    }

    # --- Fail-open regression: a QUOTED job key is valid Actions syntax. It used to be
    #     invisible to the job scan, so it could never appear in missing-set arithmetic
    #     and the gate printed "all N job(s) accounted for" over an ungated quality job.
    $quotedUngated = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  "security-scan":
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($quotedUngated.Code -eq 0 -or $quotedUngated.Output -notmatch "not gated by 'ci-gate': security-scan") {
        throw "a quoted ungated job must be caught, not silently accounted for:`n$($quotedUngated.Output)"
    }

    $quotedGated = Invoke-Gate @'
jobs:
  'build':
    runs-on: ubuntu-latest
  "security-scan":
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: ['build', "security-scan"]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($quotedGated.Code -ne 0) { throw "quoted job keys and quoted flow needs must pass:`n$($quotedGated.Output)" }

    # --- Fail-closed regressions: four valid YAML forms that used to misparse into an
    #     empty or short `needs` list, reddening a correct workflow.
    $fourSpaceSeq = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  lint:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs:
    - build
    - lint
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($fourSpaceSeq.Code -ne 0) { throw "a 4-space block sequence is valid YAML and must pass:`n$($fourSpaceSeq.Output)" }

    $commentedSeq = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  lint:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs:
      - build
    # lint is the slow one
      - lint
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($commentedSeq.Code -ne 0) { throw "a comment inside the needs sequence must not truncate it:`n$($commentedSeq.Output)" }

    $quotedSeqItems = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  lint:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs:
      - "build"
      - 'lint'
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($quotedSeqItems.Code -ne 0) { throw "quoted block sequence items must be read:`n$($quotedSeqItems.Output)" }

    $commentedJobsKey = Invoke-Gate @'
jobs: # every job in this workflow
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($commentedJobsKey.Code -ne 0) { throw "a trailing comment on 'jobs:' must not hide every job:`n$($commentedJobsKey.Output)" }

    # --- The parser must refuse to report coverage it cannot verify.
    $unparsable = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  <<: *shared
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($unparsable.Code -eq 0 -or $unparsable.Output -notmatch 'unparsable line at job indentation') {
        throw "an unclassifiable line at job indentation must fail closed:`n$($unparsable.Output)"
    }

    # --- A conditional job feeding the gate reports green while checking nothing,
    #     because the gate counts `skipped` as a pass.
    $conditionalFeeder = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  secrets:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build, secrets]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($conditionalFeeder.Code -eq 0 -or $conditionalFeeder.Output -notmatch "job-level 'if:' on job\(s\) feeding 'ci-gate': secrets") {
        throw "a conditional job feeding the gate must fail:`n$($conditionalFeeder.Output)"
    }

    $env:GATE_CONDITIONAL_EXEMPT = 'secrets'
    $conditionalExempted = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  secrets:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build, secrets]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    $env:GATE_CONDITIONAL_EXEMPT = ''
    if ($conditionalExempted.Code -ne 0) {
        throw "a named GATE_CONDITIONAL_EXEMPT job must pass:`n$($conditionalExempted.Output)"
    }

    # --- The gate's OWN semantics. Both of these keep the job, its name and its needs:
    #     list intact, so neither is visible as a coverage change in a diff -- and both
    #     leave the required context reporting green while deciding nothing.
    $noAlways = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($noAlways.Code -eq 0 -or $noAlways.Output -notmatch "must carry ``if: always\(\)`` -- found no job-level 'if:'") {
        throw "a gate without always() must fail: it is skipped exactly when it was needed:`n$($noAlways.Output)"
    }

    $narrowedCondition = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always() && github.event_name == 'push'
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($narrowedCondition.Code -eq 0 -or $narrowedCondition.Output -notmatch 'must carry') {
        throw "a compound gate condition must fail -- a gate that runs only sometimes is the defect:`n$($narrowedCondition.Output)"
    }

    $noAggregation = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - run: echo "all good"
'@
    if ($noAggregation.Code -eq 0 -or $noAggregation.Output -notmatch 'has no step whose `if:` references a') {
        throw "a gate that aggregates nothing must fail:`n$($noAggregation.Output)"
    }

    # THE DIAGNOSTIC ECHO MUST NOT SATISFY THE AGGREGATION CHECK. The house skeleton ships
    # `echo "Upstream results: ${{ join(needs.*.result, ', ') }}"` in the SAME step as the
    # gating `if:`. While this assertion searched the whole job block, deleting the `if:` --
    # so the step runs unconditionally and never fails -- still passed, because the echo
    # matched. That is exactly the "guts only the aggregation step" neuter the checker
    # exists to catch, so it was blind to its own subject. Found by Gitar on
    # an upstream review.
    $echoOnly = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Fail if any upstream job did not succeed
        run: |
          echo "Upstream results: ${{ join(needs.*.result, ', ') }}"
'@
    if ($echoOnly.Code -eq 0 -or $echoOnly.Output -notmatch 'has no step whose `if:` references a') {
        throw "a needs.*.result in a run: body must not satisfy the aggregation check:`n$($echoOnly.Output)"
    }

    # The real shape -- gating condition AND diagnostic echo together -- must still pass,
    # or the tightening would red every gate the scaffold ships.
    #
    # The expression lives in `env:`, not in the body. The checker refuses any `${{ }}`
    # inside a gate `run:` body, because GitHub substitutes it textually before the shell
    # parses the line and it can splice a separator or an early exit into an otherwise
    # inert message. This fixture carried the pre-hoist spelling and so began failing the
    # moment the hardened checker became canonical -- the house shape it exists to protect
    # had moved, and the fixture had not.
    $conditionAndEcho = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Fail if any upstream job did not succeed
        if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        env:
          RESULTS: ${{ join(needs.*.result, ', ') }}
        run: |
          echo "Upstream results: $RESULTS"
          exit 1
'@
    if ($conditionAndEcho.Code -ne 0) {
        throw "the shipped gate shape (step if: plus diagnostic echo) must pass:`n$($conditionAndEcho.Output)"
    }

    # And the PRE-HOIST spelling must now be REFUSED, which is the property the migration
    # rests on. Without this, the fixture above could be hoisted to make the suite green
    # while the checker quietly went back to accepting an interpolated body.
    $inlineInterpolation = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Fail if any upstream job did not succeed
        if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: |
          echo "Upstream results: ${{ join(needs.*.result, ', ') }}"
          exit 1
'@
    if ($inlineInterpolation.Code -eq 0) {
        throw "a `${{ }} interpolation inside a gate run: body must be refused:`n$($inlineInterpolation.Output)"
    }

    # --- ordinary failing spellings must be ACCEPTED --------------------------------
    # The allowlist is fail-closed, so a rejection here is a PERMANENTLY RED required
    # check on a correct gate - in every repository this asset is installed into.
    # (CodeRabbit, PR #135.) The `||`/`&&` guard spellings were briefly here and have
    # moved to the rejection list below: they exit ZERO when their test passes, and the
    # gate step's own `if:` has already decided that an upstream job failed.
    $failableBodies = [ordered]@{
        'exit with redirection'    = 'exit 1 >&2'
        'false with redirection'   = 'false 2>/dev/null'
        'unconditional pwsh throw' = 'throw "upstream failed"'
        # `echo` cannot fail, so `&&` here always fires -- unlike the guard forms below,
        # where the left side is a real test that decides whether the exit runs at all.
        'message then exit'        = 'echo "::error::bad" >&2 && exit 1'
    }
    foreach ($failable in $failableBodies.GetEnumerator()) {
        $body = $failable.Value
        $failableGate = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Fail if any upstream job did not succeed
        if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: $body
"@
        if ($failableGate.Code -ne 0) {
            throw "a valid failing form was rejected ($($failable.Key)): $body`n$($failableGate.Output)"
        }
    }

    # --- inert text must not read as a failing command ------------------------------
    # Four independent escapes were found in the old separator-splitting heuristic, each
    # producing a step that exits 0 while reading as failable. The checker now recognises
    # a small set of verified forms instead of parsing arbitrary shell, so each of these
    # must be REJECTED.
    $inertBodies = [ordered]@{
        'a multi-line echo whose string contains exit 1' = 'echo "\n exit 1 \n"'
        'echo with then as an argument'                  = 'echo then exit 1'
        'a piped exit'                                   = 'exit 1 | true'
        'a short-circuited false'                        = 'false || true'
        'a successful exit guarding a failing one'        = 'exit 0 || exit 1'
        # A substituted exit code is deliberately still rejected: its value cannot be
        # read from the file, which is the whole basis on which this checker vouches.
        'a substituted exit code'                        = 'exit "$code"'
        # --- the round-1 widening, reverted. Each of these EXITS ZERO on the branch it
        #     actually takes, so accepting them let a gate stay green over a failed lane.
        #     The gate step's own `if:` has already decided that an upstream job failed;
        #     a second test inside the body can only re-decide it the wrong way.
        'a test guarding the exit with ||'               = '[ -z "$x" ] || exit 1'
        'a test guarding the exit with &&'               = 'test -n "$x" && exit 1'
        # The `if <test>; then exit 1; fi` house forms were carried as a stated residual
        # for exactly as long as a repo still shipped one. They exit ZERO when the test
        # fails, which is the same fail-open as the `||`/`&&` spellings above.
        'a test guarding the exit with if'               = 'if [ -z "$x" ]; then exit 1; fi'
        # mask_quoted blanks the message, so a `.*` throw tail normalised this to
        # `throw || true` and fullmatched -- while bash `-e` does not fire on a command
        # whose status `||` consumes, so the step exits 0.
        'a guarded pwsh throw'                           = 'throw "upstream failed" || true'
        # `\S+` as the redirect target swallowed the separator, so this fullmatched the
        # `false` arm while the step exits 0 on `true`.
        'a redirect target hiding a separator'           = 'false >/tmp/gate;true'
        # A conditional pwsh throw does not throw when its condition is false.
        'a conditional pwsh throw'                       = 'if ($false) { throw "failed" }'
    }
    foreach ($inert in $inertBodies.GetEnumerator()) {
        $body = $inert.Value
        $inertGate = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Fail if any upstream job did not succeed
        if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: $body
"@
        if ($inertGate.Code -eq 0) {
            throw "inert gate body accepted as failable ($($inert.Key)): $body"
        }
        if ($inertGate.Output -notmatch 'not a recognised failing form') {
            throw "rejection of '$($inert.Key)' must name the supported forms:`n$($inertGate.Output)"
        }
    }

    # A per-job gate: one step neutered, another still failable. Breaking on the first
    # failable step accepted the whole gate on that one survivor, so `lint` could fail
    # while the required context stayed green.
    $partiallyNeutered = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  lint:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build, lint]
    runs-on: ubuntu-latest
    steps:
      - name: Fail on build
        if: needs.build.result != 'success'
        run: exit 1
      - name: Fail on lint
        if: needs.lint.result != 'success'
        continue-on-error: true
        run: exit 1
'@
    if ($partiallyNeutered.Code -eq 0) {
        throw "a dependency referenced only by a step that cannot fail must not count as gated:`n$($partiallyNeutered.Output)"
    }
    if ($partiallyNeutered.Output -notmatch 'referenced only by steps that cannot') {
        throw "the partial-gate rejection must name the unenforced dependency:`n$($partiallyNeutered.Output)"
    }

    # A BLOCK-SCALAR condition is still a condition. `if: >` carries its value on the
    # following, more-indented lines; a checker that reads only the `if:` line itself sees
    # an empty value and reports a spurious failure on correct configuration.
    $blockScalarCondition = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Fail if any upstream job did not succeed
        if: >
          contains(needs.*.result, 'failure') ||
          contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($blockScalarCondition.Code -ne 0) {
        throw "a block-scalar step condition must be read:`n$($blockScalarCondition.Output)"
    }

    # ...including the forms carrying an explicit INDENTATION INDICATOR. `>2`, `|2-` and
    # `|-2` are all valid YAML headers; a header regex of only [|>][+-]? treats `>2` as an
    # ordinary truthy value, never reads the continuation, and reds a correct gate.
    $blockScalarIndented = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Fail if any upstream job did not succeed
        if: >2
          contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($blockScalarIndented.Code -ne 0) {
        throw "a block scalar with an indentation indicator must be read:`n$($blockScalarIndented.Output)"
    }

    # A folded condition on a DASH-form step must end at the `if:` key's column. Measuring
    # the line instead put the bar at the dash, so the sibling `run:` and its whole body
    # were absorbed into the condition -- and the gate's own diagnostic echo of
    # `join(needs.*.result, ', ')` inside that body then satisfied the aggregation check
    # for a step whose condition is literally `false`. Fail-open, reached by way of a fix
    # for the dash form.
    $dashFoldedFalsy = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: >-
          false
        run: |
          echo "Upstream results: ${{ join(needs.*.result, ', ') }}"
          exit 1
'@
    if ($dashFoldedFalsy.Code -eq 0 -or $dashFoldedFalsy.Output -notmatch 'has no step whose ') {
        throw "a folded condition must not absorb the sibling run: body:`n$($dashFoldedFalsy.Output)"
    }

    # The same shape with a real condition still has to pass, or the rule above bought its
    # strictness by reddening a correct gate.
    $dashFolded = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: >-
          contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($dashFolded.Code -ne 0) {
        throw "a folded condition on a dash-form step must be read:`n$($dashFolded.Output)"
    }

    # A comment naming the expression must not satisfy the aggregation check.
    $commentedAggregation = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      # this used to check needs.*.result
      - run: echo "all good"
'@
    if ($commentedAggregation.Code -eq 0 -or $commentedAggregation.Output -notmatch 'has no step whose `if:` references a') {
        throw "a commented-out aggregation must not count as aggregation:`n$($commentedAggregation.Output)"
    }

    # Three valid spellings of the same condition, and per-job result references.
    $spellings = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: ${{ always() }}
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: needs.build.result != 'success'
        run: exit 1
'@
    if ($spellings.Code -ne 0) {
        throw "`${{ always() }}` and a per-job result reference are both valid and must pass:`n$($spellings.Output)"
    }

    $quotedAlways = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    'if': "always()"
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($quotedAlways.Code -ne 0) {
        throw "a quoted 'if' key and quoted always() value must pass:`n$($quotedAlways.Output)"
    }

    # A `run:` BLOCK-SCALAR BODY containing text shaped like a real step `if:` line must
    # not be mistaken for one. Here the gate's actual step-level `if:` has been deleted
    # (the step runs unconditionally and never fails), but an earlier diagnostic step's
    # `run: |` payload prints a line that LOOKS like `if: contains(needs.*.result, ...)`
    # at step-body indentation. A checker that scans every line for the STEP_IF_VALUE
    # shape, blind to whether it sits inside a preceding block scalar, reads that printed
    # text as the real condition and reports the gate as aggregating -- fail-open on a
    # gate that aggregates nothing. Found by CodeRabbit on an upstream review.
    $conditionInRunBody = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Explain the gate shape
        run: |
          cat <<'EOF'
          if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
          EOF
      - name: Fail if any upstream job did not succeed
        run: exit 1
'@
    if ($conditionInRunBody.Code -eq 0 -or $conditionInRunBody.Output -notmatch 'has no step whose `if:` references a') {
        throw "if:-shaped text inside a preceding run: body must not count as a real step condition:`n$($conditionInRunBody.Output)"
    }

    $conditionInQuotedRunBody = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Explain the gate shape
        'run': |
          cat <<'EOF'
          if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
          EOF
      - name: Fail if any upstream job did not succeed
        run: exit 1
'@
    if ($conditionInQuotedRunBody.Code -eq 0 -or $conditionInQuotedRunBody.Output -notmatch 'has no step whose `if:` references a') {
        throw "if:-shaped text inside a quoted run: body must not count as a real step condition:`n$($conditionInQuotedRunBody.Output)"
    }

    # The same shape but with a GENUINE step-level `if:` after the look-alike run: body
    # must still pass, or the fix above bought its strictness by reddening a correct gate.
    $conditionAfterRunBody = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - name: Explain the gate shape
        run: |
          echo "This gate is wired like:"
          echo "  if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')"
      - name: Fail if any upstream job did not succeed
        if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($conditionAfterRunBody.Code -ne 0) {
        throw "a real step if: after a look-alike run: body must still be read:`n$($conditionAfterRunBody.Output)"
    }

    $workflowDir = Join-Path $root 'workflows'
    New-Item -ItemType Directory -Path $workflowDir | Out-Null
    @'
name: Metadata only
'@ | Set-Content -LiteralPath (Join-Path $workflowDir 'metadata.yml') -Encoding utf8
    @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@ | Set-Content -LiteralPath (Join-Path $workflowDir 'ci.yml') -Encoding utf8
    $directoryOutput = Join-Path $root 'directory-output.txt'
    & $python.Source -S $script $workflowDir *> $directoryOutput
    if ($LASTEXITCODE -ne 0 -or (Get-Content -LiteralPath $directoryOutput -Raw) -notmatch 'no jobs -- not a workflow, skipped') {
        throw "directory mode must skip a jobs-less YAML file while checking real workflows:`n$(Get-Content -LiteralPath $directoryOutput -Raw)"
    }

    $emptyFile = Invoke-Gate "name: Metadata only"
    if ($emptyFile.Code -eq 0 -or $emptyFile.Output -notmatch 'no jobs found') {
        throw "file mode must fail closed when its named workflow has no jobs:`n$($emptyFile.Output)"
    }

    # ── Gate scripts must be tiered HIGH ────────────────────────────────────────
    # A script a merge-blocking job runs from the PR's own checkout decides what can
    # merge. The guard's named-path list cannot cover a checker one repository authored
    # later, so this is derived from what the workflow actually invokes.
    #
    # Every case builds a MINI REPO in temp -- .claude/review-policy.json, the script,
    # and .github/workflows/ci.yml -- because the assertion resolves the policy by
    # walking up from the workflow file. The cases above deliberately have no policy in
    # scope, which is what keeps them asserting only what they were written to assert.
    # MULTI-SEGMENT Join-Path throughout, and the script paths are split on '/' rather
    # than pasted in: an embedded '\' is not a directory separator on POSIX, so a fixture
    # built that way creates one file whose NAME contains backslashes. The check then
    # finds no policy, asserts nothing, and every case here passes on Linux while
    # proving nothing -- the exact inert-test shape this check exists to catch, and the
    # same trap already recorded in run-tests/test/verify-contract.ps1. Green on ubuntu is
    # therefore not evidence these fixtures are sound; only the separators are.
    # (CodeRabbit, PR #142.)
    function New-GateRepo([string] $policyJson, [string[]] $scriptPaths, [string] $yaml) {
        $repo = Join-Path $root ('repo-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo '.github' 'workflows') -Force | Out-Null
        if ($null -ne $policyJson) {
            $policyJson | Set-Content -LiteralPath (Join-Path $repo '.claude' 'review-policy.json') -Encoding utf8
        }
        foreach ($relative in $scriptPaths) {
            $full = $repo
            foreach ($segment in ($relative -split '/')) { $full = Join-Path $full $segment }
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            '# probe' | Set-Content -LiteralPath $full -Encoding utf8
        }
        $workflow = Join-Path $repo '.github' 'workflows' 'ci.yml'
        $yaml | Set-Content -LiteralPath $workflow -Encoding utf8
        $output = Join-Path $repo 'output.txt'
        & $python.Source -S $script $workflow *> $output
        [pscustomobject]@{
            Code = $LASTEXITCODE
            Output = Get-Content -LiteralPath $output -Raw
        }
    }

    $gatedYaml = @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - shell: pwsh
        run: ./scripts/assert-coverage-floor.ps1 -MinimumLineRate 70
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@

    # 1. Gated step runs a repo-local script that no high glob covers -> FAIL.
    $unprotected = New-GateRepo '{"version":1,"high":[".github/workflows/ci.yml"],"low":[]}' `
        @('scripts/assert-coverage-floor.ps1') $gatedYaml
    if ($unprotected.Code -eq 0 -or $unprotected.Output -notmatch 'not tiered\s+HIGH') {
        throw "a gate script outside the high list must fail:`n$($unprotected.Output)"
    }
    if ($unprotected.Output -notmatch 'assert-coverage-floor\.ps1') {
        throw "the failure must name the offending script:`n$($unprotected.Output)"
    }

    # 2. Same workflow, script named exactly in the high list -> PASS.
    $protected = New-GateRepo '{"version":1,"high":["scripts/assert-coverage-floor.ps1"],"low":[]}' `
        @('scripts/assert-coverage-floor.ps1') $gatedYaml
    if ($protected.Code -ne 0) {
        throw "a gate script named in the high list must pass:`n$($protected.Output)"
    }

    # 3. Covered by a GLOB rather than an exact path -> PASS. The hook tiers this
    # repository HIGH, so a checker that rejected it would be a false RED — the
    # divergence glob_to_regex is mirrored to prevent.
    $globbed = New-GateRepo '{"version":1,"high":["scripts/**"],"low":[]}' `
        @('scripts/assert-coverage-floor.ps1') $gatedYaml
    if ($globbed.Code -ne 0) {
        throw "a high glob covering the script must pass:`n$($globbed.Output)"
    }

    # 4. No repo-local scripts in any gated step -> PASS, silently. Most repos.
    $noScripts = New-GateRepo '{"version":1,"high":[],"low":[]}' @() @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: dotnet build
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($noScripts.Code -ne 0) {
        throw "a workflow invoking no repo-local scripts must pass:`n$($noScripts.Output)"
    }
    if ($noScripts.Output -match 'gate script') {
        throw "with no gate scripts the check must say nothing:`n$($noScripts.Output)"
    }

    # 5. A script named in a gated step but ABSENT from the repo -> PASS. The candidate
    # cannot be edited to neuter anything, and reddening a repo over a file it does not
    # have is the false-RED direction.
    $missingFile = New-GateRepo '{"version":1,"high":[],"low":[]}' @() $gatedYaml
    if ($missingFile.Code -ne 0) {
        throw "a script that does not exist on disk must not be asserted about:`n$($missingFile.Output)"
    }

    # 6. Script run only by a job that does NOT feed the gate -> PASS. It cannot fail
    # the merge barrier, so requiring it HIGH would be cost without a control.
    $env:GATE_EXEMPT = 'docs'
    try {
        $ungated = New-GateRepo '{"version":1,"high":[],"low":[]}' `
            @('scripts/publish-docs.ps1') @'
jobs:
  build:
    runs-on: ubuntu-latest
  docs:
    runs-on: ubuntu-latest
    steps:
      - shell: pwsh
        run: ./scripts/publish-docs.ps1
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
        if ($ungated.Code -ne 0) {
            throw "a script run only by a non-gated job must not be required HIGH:`n$($ungated.Output)"
        }
    }
    finally { $env:GATE_EXEMPT = '' }

    # 7. A block-scalar run: body, which is how the house shape writes a multi-line
    # step. The body lines are read through continuation_lines, not the inline value.
    $blockScalar = New-GateRepo '{"version":1,"high":[],"low":[]}' `
        @('scripts/assert-coverage-floor.ps1') @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - shell: pwsh
        run: |
          dotnet build
          ./scripts/assert-coverage-floor.ps1 -MinimumLineRate 70
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($blockScalar.Code -eq 0 -or $blockScalar.Output -notmatch 'assert-coverage-floor\.ps1') {
        throw "a script invoked inside a block-scalar run: body must be seen:`n$($blockScalar.Output)"
    }

    # 8. No review policy in scope -> PASS, asserting nothing. review-policy-guard.yml
    # owns a missing policy; duplicating it here would make THIS check fail on a
    # repository whose actual problem is elsewhere.
    $noPolicy = New-GateRepo $null @('scripts/assert-coverage-floor.ps1') $gatedYaml
    if ($noPolicy.Code -ne 0) {
        throw "with no review policy in scope nothing must be asserted:`n$($noPolicy.Output)"
    }

    # 9. EVERY directory root GATE_SCRIPT admits, not just the one the cases above use.
    # The cases above all place their script under `scripts/`, so the other three
    # alternatives were unexercised: an edit tightening or loosening one of them would
    # have regressed detection for that root with the suite still green. That is the same
    # "verified only by cases that cannot fail" class this whole check exists to close, so
    # it is worth the twelve lines. `build/` and `tools/` are admitted but unused across
    # the estate today (checked, 2026-09-09, 26 repos); they stay in the pattern because a
    # gate script the check does not SEE is the fail-open direction, and are pinned here so
    # they cannot rot unnoticed. (Gitar, PR #142.)
    foreach ($prefix in @('.github/scripts', 'build', 'tools')) {
        $rooted = New-GateRepo '{"version":1,"high":[],"low":[]}' @("$prefix/probe.py") @"
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: python $prefix/probe.py
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
"@
        if ($rooted.Code -eq 0 -or $rooted.Output -notmatch 'probe\.py') {
            throw "a gate script under $prefix/ must be detected:`n$($rooted.Output)"
        }
    }

    # A COMMENTED block-scalar opener is a real spelling, and the scan tested the RAW
    # value against an anchored BLOCK_SCALAR, so `run: | # build log` matched neither
    # branch properly: the else arm yielded the bare `|` and advanced one line, skipping
    # the whole payload. The script inside was then invisible and escaped the HIGH-tier
    # requirement -- fail-open on the control this check exists to be. (CodeRabbit,
    # on an upstream review.)
    $commentedScalar = New-GateRepo '{"version":1,"high":[],"low":[]}' @('.github/scripts/probe.py') @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: | # build log
          python .github/scripts/probe.py
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($commentedScalar.Code -eq 0 -or $commentedScalar.Output -notmatch 'probe\.py') {
        throw "a gate script inside a commented block scalar must be detected:`n$($commentedScalar.Output)"
    }

    # -- Windows path spellings reach the same gate script ---------------------------
    # Windows resolves a path separator- and case-insensitively, so a gate job on a
    # windows-latest runner executes `.\scripts\probe.ps1` exactly as it executes the
    # POSIX spelling. GATE_SCRIPT admitted only `/` and lowercase extensions, so neither
    # Windows form was seen and assert_gate_scripts asserted NOTHING -- a repo-authored
    # gate script left editable in a NORMAL-tier pull request, reached by punctuation
    # rather than by deleting anything. Probed before the fix: both spellings exited 0.
    #
    # Each spelling is pinned in BOTH directions. Detection alone would pass with the
    # path captured in a form no policy glob can ever match, which reports every such
    # script as untiered forever -- correct-looking and permanently red.
    foreach ($spelling in @('.\scripts\probe.ps1', './scripts/probe.PS1', '.\scripts\probe.PS1')) {
        $windowsYaml = @"
jobs:
  build:
    runs-on: windows-latest
    steps:
      - shell: pwsh
        run: $spelling
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
"@
        $windowsUntiered = New-GateRepo '{"version":1,"high":[],"low":[]}' @('scripts/probe.ps1') $windowsYaml
        if ($windowsUntiered.Code -eq 0) {
            throw "the Windows spelling '$spelling' must be detected as a gate script:`n$($windowsUntiered.Output)"
        }
        # The COMMITTED spelling must be reported, not the one the workflow typed.
        # This is the assertion that is not inert on Windows: there a mixed-case
        # `probe.PS1` resolves through the case-insensitive filesystem, so a checker
        # that skipped the resolution would still detect the script and still fail --
        # correctly, but reporting `probe.PS1`, a key no exact policy entry can match.
        # On Linux the same missing resolution fails the line above instead. One
        # fixture, both platforms, and it cannot pass while the resolution is absent.
        if ($windowsUntiered.Output -cnotmatch 'scripts/probe\.ps1') {
            throw "the committed spelling must be reported for '$spelling', not the typed one:`n$($windowsUntiered.Output)"
        }
        $windowsTiered = New-GateRepo '{"version":1,"high":["scripts/**"],"low":[]}' @('scripts/probe.ps1') $windowsYaml
        if ($windowsTiered.Code -ne 0) {
            throw "a high glob must cover the Windows spelling '$spelling':`n$($windowsTiered.Output)"
        }
    }

    # A path-shaped token that is NOT a gate script must stay unmatched. The widening
    # above touched the separator and extension classes, which is exactly where an
    # over-broad pattern would start claiming ordinary arguments.
    $notAScript = New-GateRepo '{"version":1,"high":[],"low":[]}' @() @'
jobs:
  build:
    runs-on: windows-latest
    steps:
      - shell: pwsh
        run: dotnet test --results-directory .\artifacts\results
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($notAScript.Code -ne 0) {
        throw "a Windows-spelled non-script argument must not be claimed as a gate script:`n$($notAScript.Output)"
    }

    # -- A BOM'd workflow is still a workflow ----------------------------------------
    # `JOBS_KEY` is anchored at `^`, so a plain utf-8 read left the BOM in front of
    # `jobs:` and the line never matched. In FILE mode that exited 1 with "no jobs
    # found": a permanently red required check over a valid workflow, triggered by
    # nothing more than a Windows editor saving the file. In DIRECTORY mode it was
    # written off as "not a workflow, skipped" and every job in it escaped coverage
    # instead. Pinned as an EQUIVALENCE to its BOM-less twin, because the defect is
    # precisely that the two behaved differently.
    $bomYaml = @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    $plain = Invoke-Gate $bomYaml
    $bom = Invoke-Gate $bomYaml -Bom
    if ($plain.Code -ne 0) { throw "the BOM control workflow must pass without a BOM:`n$($plain.Output)" }
    if ($bom.Code -ne $plain.Code) {
        throw "a BOM must not change the verdict (plain=$($plain.Code) bom=$($bom.Code)):`n$($bom.Output)"
    }
    if ($bom.Output -match 'no jobs') {
        throw "a BOM'd workflow must not read as having no jobs:`n$($bom.Output)"
    }

    # -- pwsh `throw` with a trailing comment -----------------------------------------
    # The pwsh arm fullmatched the joined block-scalar body with no comment handling,
    # while its bash sibling masks then strips them. So `exit 1 # note` was accepted and
    # the identical pwsh `throw "..." # note` was refused -- a false RED on a gate that
    # does fail, and only in the block-scalar form, since the inline form goes through
    # strip_inline_comment.
    $pwshCases = @(
        @{ Name = 'trailing comment';      Body = 'throw "an upstream job did not succeed" # keep the message greppable' }
        @{ Name = 'hash inside message';   Body = 'throw "an upstream job did not succeed # see the runbook"' }
        @{ Name = 'comment on its own line'; Body = "# the gate`n          throw `"an upstream job did not succeed`"" }
    )
    foreach ($case in $pwshCases) {
        $pwshGate = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        shell: pwsh
        run: |
          $($case.Body)
"@
        if ($pwshGate.Code -ne 0) {
            throw "a pwsh throw with a $($case.Name) must be accepted:`n$($pwshGate.Output)"
        }
    }

    # Stripping comments must not have widened what the pwsh arm ACCEPTS. A body that is
    # more than an unconditional throw stays refused: the preceding command can decide
    # the exit status, which is the whole reason this arm is a fullmatch and not a search.
    $pwshNotBare = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        shell: pwsh
        run: |
          Write-Host "upstream failed" # note
          if ($env:OK) { exit 0 }
          throw "an upstream job did not succeed"
'@
    if ($pwshNotBare.Code -eq 0) {
        throw "a pwsh body that is more than an unconditional throw must stay refused:`n$($pwshNotBare.Output)"
    }

    # --- CodeRabbit, on an upstream review -------------------------------------

    # A STATICALLY FALSE job-level continue-on-error tolerates nothing, but the old
    # membership test normalised `${{ false && inputs.allow_failure }}` to a compound
    # string -- neither "false" nor "" -- and counted the job tolerant, and a tolerant
    # job feeding the gate is refused: a false RED on a legitimate feeder. The fix
    # consults static_truth, which folds the compound to False.
    $staticFalseTolerance = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
    continue-on-error: ${{ false && inputs.allow_failure }}
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($staticFalseTolerance.Code -ne 0) {
        throw "a statically false continue-on-error must not read as tolerant:`n$($staticFalseTolerance.Output)"
    }

    # The two directions that must NOT change: literal true is tolerant, and an
    # expression the checker cannot fold stays potentially tolerant -- both refused on
    # a merge-blocking job.
    foreach ($case in @('true', '${{ inputs.allow_failure }}')) {
        $stillTolerant = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
    continue-on-error: $case
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
"@
        if ($stillTolerant.Code -eq 0 -or $stillTolerant.Output -notmatch 'continue-on-error') {
            throw "a tolerant or unfoldable continue-on-error on a gate-feeding job must fail ($case):`n$($stillTolerant.Output)"
        }
    }

    # A local `uses:` line inside a run: payload is SHELL TEXT, not a delegation. The
    # LOCAL_USES scan ran over physical lines, so a payload line like the one below
    # matched, and because the target exists and is non-composite the traversal raised
    # its ValueError -- a false RED on a workflow that never delegates. Payload lines
    # are now excluded from both LOCAL_USES scans. (Second finding, same review.)
    function New-GateActionRepo([string] $actionContent, [string] $workflowYaml, [string] $highPaths = '["scripts/**","actions/**"]') {
        # The policy is load-bearing: assert_gate_scripts returns early when no
        # review-policy.json is readable, and gate_script_paths -- where the LOCAL_USES
        # traversal lives -- is only reached behind that read. Without it the
        # local-action fixtures pass while exercising nothing.
        # [string] parameters coerce an omitted argument to "" rather than $null, so a
        # null test never fires and the default workflow never writes -- an empty ci.yml
        # then fails every caller with "no jobs found". IsNullOrEmpty covers both forms.
        $repo = Join-Path $root ('repo-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo '.github' 'workflows') -Force | Out-Null
        ('{"version":1,"high":' + $highPaths + ',"low":[]}') |
            Set-Content -LiteralPath (Join-Path $repo '.claude' 'review-policy.json') -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $repo 'actions' 'probe') -Force | Out-Null
        $actionContent | Set-Content -LiteralPath (Join-Path $repo 'actions' 'probe' 'action.yml') -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $repo 'scripts') -Force | Out-Null
        '# probe' | Set-Content -LiteralPath (Join-Path $repo 'scripts' 'probe.py') -Encoding utf8
        $workflow = Join-Path $repo '.github' 'workflows' 'ci.yml'
        if ([string]::IsNullOrEmpty($workflowYaml)) {
            $workflowYaml = @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./actions/probe
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
        }
        $workflowYaml | Set-Content -LiteralPath $workflow -Encoding utf8
        $outputPath = Join-Path $repo 'output.txt'
        & $python.Source -S $script $workflow *> $outputPath
        [pscustomobject]@{
            Code = $LASTEXITCODE
            Output = Get-Content -LiteralPath $outputPath -Raw
        }
    }

    # --- Follow-up batch: gate-checker coverage gaps and false failures ------------------
    # Self-contained: every fixture file is written BEFORE the checker runs, which the
    # action-path case needs (its script sits beside action.yml).
    function New-FollowupRepo([hashtable] $files, [string] $policy) {
        $repo = Join-Path $root ('repo-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
        $policy | Set-Content -LiteralPath (Join-Path $repo '.claude' 'review-policy.json') -Encoding utf8
        foreach ($relative in $files.Keys) {
            $full = Join-Path $repo $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            $files[$relative] | Set-Content -LiteralPath $full -Encoding utf8
        }
        $outputPath = Join-Path $repo 'output.txt'
        & $python.Source -S $script (Join-Path $repo '.github/workflows/ci.yml') *> $outputPath
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = Get-Content -LiteralPath $outputPath -Raw }
    }
    $followupGate = @'
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    $followupPolicy = '{"version":1,"high":[".github/workflows/ci.yml","scripts/**"],"low":[]}'

    # A composite action running its own script through the action path: the script must
    # be tiered HIGH.
    foreach ($spelling in '"${{ github.action_path }}/scripts/gate.sh"', '"$GITHUB_ACTION_PATH/scripts/gate.sh"') {
        $r = New-FollowupRepo @{
            'actions/probe/action.yml'        = "name: Probe`nruns:`n  using: composite`n  steps:`n    - shell: bash`n      run: $spelling"
            'actions/probe/scripts/gate.sh'   = '# probe'
            '.github/workflows/ci.yml'        = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n      - uses: ./actions/probe`n$followupGate"
        } '{"version":1,"high":["actions/probe/action.yml"],"low":[]}'
        if ($r.Code -eq 0 -or $r.Output -notmatch 'actions/probe/scripts/gate\.sh') {
            throw "a script run through the action path ($spelling) must be tiered HIGH:`n$($r.Output)"
        }
    }

    # A flush `- working-directory:` as the step's first key scopes the gate script.
    $r = New-FollowupRepo @{
        'sub/scripts/gate.py'      = '# probe'
        '.github/workflows/ci.yml' = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n    - working-directory: sub`n      run: python3 scripts/gate.py`n$followupGate"
    } $followupPolicy
    if ($r.Code -eq 0 -or $r.Output -notmatch 'sub/scripts/gate\.py') {
        throw "a dash-form working-directory must locate the gate script it scopes:`n$($r.Output)"
    }

    # A sibling step's working-directory adds no candidate path...
    $r = New-FollowupRepo @{
        'scripts/gate.py'          = '# probe'
        'other/scripts/gate.py'    = '# probe'
        '.github/workflows/ci.yml' = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n      - name: unrelated`n        working-directory: other`n        run: ls`n      - run: python3 scripts/gate.py`n$followupGate"
    } $followupPolicy
    if ($r.Code -ne 0) { throw "a sibling step's working-directory must not require an unrelated file HIGH:`n$($r.Output)" }
    # ...while a job-level defaults.run.working-directory still applies.
    $r = New-FollowupRepo @{
        'app/scripts/gate.py'      = '# probe'
        '.github/workflows/ci.yml' = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    defaults:`n      run:`n        working-directory: app`n    steps:`n      - run: python3 scripts/gate.py`n$followupGate"
    } $followupPolicy
    if ($r.Code -eq 0 -or $r.Output -notmatch 'app/scripts/gate\.py') {
        throw "a job-level defaults.run.working-directory must still apply to its steps:`n$($r.Output)"
    }

    # A quoted '; cd' in message text is not a directory change...
    $r = New-FollowupRepo @{
        'scripts/gate.py'          = '# probe'
        '.github/workflows/ci.yml' = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n      - run: |`n          echo `"step1; cd scripts is deprecated`"`n          python3 scripts/gate.py`n$followupGate"
    } $followupPolicy
    if ($r.Code -ne 0) { throw "a quoted '; cd' in message text must not read as a directory change:`n$($r.Output)" }
    # ...but a quoted command string that changes directory and runs the script is.
    $r = New-FollowupRepo @{
        'scripts/gate.py'          = '# probe'
        '.github/workflows/ci.yml' = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n      - run: bash -c `"cd sub; python3 scripts/gate.py`"`n$followupGate"
    } $followupPolicy
    if ($r.Code -eq 0 -or $r.Output -notmatch 'directory change') {
        throw "a quoted command string that changes directory before a gate script must fail closed:`n$($r.Output)"
    }
    # A quoted command string may span block-scalar lines; its cd still counts.
    $r = New-FollowupRepo @{
        'scripts/gate.py'          = '# probe'
        '.github/workflows/ci.yml' = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n      - run: |`n          bash -c `"cd sub;`n            python3 scripts/gate.py`"`n$followupGate"
    } $followupPolicy
    if ($r.Code -eq 0 -or $r.Output -notmatch 'directory change') {
        throw "a quoted command string spanning lines must still fail closed on its cd:`n$($r.Output)"
    }
    # Adjacent quoted spans are ONE shell argument, and a command substitution runs even
    # inside a printed string: both still change directory before the gate script.
    foreach ($spelling in '(cd sub && python3 scripts/gate.py)',
                          '{ cd sub; python3 scripts/gate.py; }',
                          'if cd sub; then python3 scripts/gate.py; fi',
                          '! cd sub || python3 scripts/gate.py',
                          'bash -c "cd sub; "''python3 scripts/gate.py''',
                          'echo "$(cd sub; python3 scripts/gate.py)"',
                          'echo "cd sub; python3 scripts/gate.py" | bash',
                          'echo $(bash -c "cd sub; python3 scripts/gate.py")',
                          "echo `"cd sub;`n          python3 scripts/gate.py`" | bash") {
        $r = New-FollowupRepo @{
            'scripts/gate.py'          = '# probe'
            'sub/scripts/gate.py'      = '# probe'
            '.github/workflows/ci.yml' = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n      - run: |`n          $spelling`n$followupGate"
        } $followupPolicy
        if ($r.Code -eq 0 -or $r.Output -notmatch 'directory change') { throw "a directory change in ($spelling) must fail closed:`n$($r.Output)" }
    }
    # A MESSAGE that mentions cd is not a command, even beside or naming a gate script.
    foreach ($message in 'echo "cd scripts is deprecated" && python3 scripts/gate.py',
                         'echo "cd scripts/gate.py is required for setup"',
                         'echo "$(date)"; echo "cd scripts/gate.py is deprecated"',
                         'echo then cd sub; python3 scripts/gate.py',
                         'echo hi! cd sub; python3 scripts/gate.py',
                         'bash -c "echo then cd sub; python3 scripts/gate.py"',
                         'printf "cd scripts is deprecated, use scripts/gate.py instead\n"') {
        $r = New-FollowupRepo @{
            'scripts/gate.py'          = '# probe'
            '.github/workflows/ci.yml' = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n      - run: |`n          $message`n          python3 scripts/gate.py`n$followupGate"
        } $followupPolicy
        if ($r.Code -ne 0) { throw "a message line mentioning cd must not read as a directory change ($message):`n$($r.Output)" }
    }

    # A BASH_ENV: line inside a run body is shell text; a real env key still fails.
    $r = Invoke-Gate "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n      - run: |`n          cat <<'EOF' > notes.yml`n          BASH_ENV: documented-here-only`n          EOF`n$followupGate"
    if ($r.Code -ne 0) { throw "a BASH_ENV: line inside a run body must not trip the env-key guard:`n$($r.Output)" }
    $r = Invoke-Gate "jobs:`n  build:`n    runs-on: ubuntu-latest`n    env:`n      BASH_ENV: /tmp/override`n    steps:`n      - run: echo build`n$followupGate"
    if ($r.Code -eq 0 -or $r.Output -notmatch 'BASH_ENV') { throw "a real BASH_ENV env key must still fail:`n$($r.Output)" }
    foreach ($key in '"BASH_ENV"', "'BASH_ENV'") {
        $r = Invoke-Gate "jobs:`n  build:`n    runs-on: ubuntu-latest`n    env:`n      ${key}: /tmp/override`n    steps:`n      - run: echo build`n$followupGate"
        if ($r.Code -eq 0 -or $r.Output -notmatch 'BASH_ENV') { throw "a quoted BASH_ENV env key ($key) must fail like the bare one:`n$($r.Output)" }
    }

    # Directory mode: a file-exempt workflow with no gate job is not subject to the
    # gate's BASH_ENV rule.
    $dirMode = Join-Path $root ('dir-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dirMode | Out-Null
    "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo build`n$followupGate" | Set-Content -LiteralPath (Join-Path $dirMode 'ci.yml') -Encoding utf8
    "jobs:`n  release:`n    runs-on: ubuntu-latest`n    env:`n      BASH_ENV: /tmp/release-env`n    steps:`n      - run: echo release" | Set-Content -LiteralPath (Join-Path $dirMode 'release.yml') -Encoding utf8
    $env:GATE_FILE_EXEMPT = ((Join-Path $dirMode 'release.yml') -replace '\\', '/')
    try {
        $dirOut = & $python.Source -S $script ($dirMode -replace '\\', '/') 2>&1 | Out-String
        $dirCode = $LASTEXITCODE
    }
    finally { $env:GATE_FILE_EXEMPT = '' }
    if ($dirCode -ne 0) { throw "directory mode must not fail a file-exempt, non-gated workflow on BASH_ENV:`n$dirOut" }

    # An always() intermediate stops feeder-chain traversal.
    $env:GATE_EXEMPT = 'optional'
    try {
        $r = Invoke-Gate "jobs:`n  optional:`n    runs-on: ubuntu-latest`n  mid:`n    if: always()`n    needs: [optional]`n    runs-on: ubuntu-latest`n  quality:`n    needs: [mid]`n    runs-on: ubuntu-latest`n  ci-gate:`n    if: always()`n    needs: [mid, quality]`n    runs-on: ubuntu-latest`n    steps:`n      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')`n        run: exit 1"
    }
    finally { $env:GATE_EXEMPT = '' }
    if ($r.Code -ne 0) { throw "an always() intermediate must stop feeder-chain traversal:`n$($r.Output)" }

    $nonCompositeAction = @'
name: probe
runs:
  using: node20
  main: index.js
'@

    $localActionUntiered = New-GateActionRepo @'
name: Probe
runs: {using: composite, steps: []}
'@ $null '["scripts/**"]'
    if ($localActionUntiered.Code -eq 0 -or $localActionUntiered.Output -notmatch 'actions/probe/action\.yml') {
        throw "a local action feeding the gate must itself be tiered HIGH:`n$($localActionUntiered.Output)"
    }

    $payloadUses = New-GateActionRepo $nonCompositeAction @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - shell: pwsh
        run: |
          cat > actions/probe/action.yml <<'EOF'
          name: probe
          runs:
            using: composite
          EOF
          uses: ./actions/probe
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($payloadUses.Code -ne 0) {
        throw "a uses: line inside a run: payload must not be followed as a delegation:`n$($payloadUses.Output)"
    }

    # ... while a GENUINE step-level local delegation to a non-composite action is still
    # refused -- the exclusion covers run payloads only, not the steps list.
    $realUses = New-GateActionRepo $nonCompositeAction @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./actions/probe
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($realUses.Code -eq 0 -or $realUses.Output -notmatch 'gate coverage only follows composite') {
        throw "a genuine non-composite local action must still be refused:`n$($realUses.Output)"
    }

    # ── Dot components in a gate-script path (CodeRabbit, on an upstream review) ──
    # `iterdir()` never yields `.` or `..`, so resolve_committed_paths walking them
    # literally matches nothing and drops the candidate -- fail-open. The exact
    # `is_file()` the walk replaced collapsed a single dot for free, via pathlib, so
    # omitting this was a REGRESSION and not an unchanged gap. Both spellings resolve to
    # the same committed file and must be required HIGH exactly as the plain spelling is.
    foreach ($dotted in @('./scripts/./probe.ps1', './scripts/sub/../probe.ps1')) {
        $dottedYaml = @"
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: $dotted
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
"@
        $dottedRepo = New-GateRepo '{"version":1,"high":[],"low":[]}' @('scripts/probe.ps1', 'scripts/sub/keep.txt') $dottedYaml
        if ($dottedRepo.Code -eq 0) {
            throw "a gate script spelled '$dotted' must be detected:`n$($dottedRepo.Output)"
        }
        if ($dottedRepo.Output -cnotmatch 'scripts/probe\.ps1') {
            throw "'$dotted' must report the normalised committed path:`n$($dottedRepo.Output)"
        }
    }

    # A path climbing above the repository root is refused rather than clamped: nothing
    # outside the checkout is a repo-local gate script, and clamping would resolve it to
    # one that is.
    $escaping = New-GateRepo '{"version":1,"high":[],"low":[]}' @('scripts/probe.ps1') @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: scripts/../../scripts/probe.ps1
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($escaping.Code -ne 0) {
        throw "a path escaping the repository must not be asserted about:`n$($escaping.Output)"
    }

    # A `..` AFTER A SYMLINK does not reduce the way the runner resolves it: the OS
    # follows `link` first and then climbs from the TARGET's parent, so
    # `scripts/link/../gate.ps1` executes a file the lexical reduction never names.
    # Vouching for the lexical answer alone would require HIGH on a path the gate does
    # not run while the one it does run stays untiered -- fail-open. Both spellings must
    # be required. (CodeRabbit, on an upstream review.)
    #
    # Creating a directory symlink needs either Developer Mode or elevation on Windows,
    # so the case SKIPS with a stated reason where it cannot be built rather than passing
    # vacuously -- a silent pass here is indistinguishable from coverage.
    $symlinkRepo = Join-Path $root ('repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $symlinkRepo '.claude') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $symlinkRepo '.github' 'workflows') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $symlinkRepo 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $symlinkRepo 'elsewhere') -Force | Out-Null
    # ONLY the file the symlink actually reaches. The first version of this fixture also
    # created the LEXICAL target at scripts/gate.ps1, and that is what hid a fail-open:
    # with both present the component walk always succeeded, so it never took the
    # empty-candidate path and the filesystem resolution below was never the thing under
    # test. With the lexical target absent the walk finds nothing, which is exactly the
    # case that used to abandon the path before resolving it. (CodeRabbit, on an upstream
    # review.)
    '# real target' | Set-Content -LiteralPath (Join-Path $symlinkRepo 'gate.ps1') -Encoding utf8
    # SymbolicLink first; a JUNCTION where that is refused. A plain symlink needs
    # Developer Mode or elevation on Windows, while a junction needs neither and is a
    # reparse point that `Path.resolve()` follows identically -- so the fallback
    # exercises the same code path rather than skipping it. Without it this case was
    # SKIPPED on the authoring host and ran only on the runner, which is the inert-fixture
    # shape this file keeps warning about.
    $linkMade = $true
    foreach ($kind in @('SymbolicLink', 'Junction')) {
        try {
            New-Item -ItemType $kind -Path (Join-Path $symlinkRepo 'scripts' 'link') -Target (Join-Path $symlinkRepo 'elsewhere') -ErrorAction Stop | Out-Null
            $linkMade = $true
            break
        }
        catch { $linkMade = $false }
    }

    if (-not $linkMade) {
        Write-Host 'SKIP: cannot create a directory symlink or junction on this host; the symlink-plus-dotdot case was NOT checked'
    }
    else {
        # Only `scripts/gate.ps1` is tiered. The file the runner actually reaches through
        # the link is the repository-root `gate.ps1`, which is NOT tiered -- so a checker
        # that trusted the lexical reduction alone would report this repository clean.
        '{"version":1,"high":["scripts/gate.ps1"],"low":[]}' |
            Set-Content -LiteralPath (Join-Path $symlinkRepo '.claude' 'review-policy.json') -Encoding utf8
        @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - shell: pwsh
        run: scripts/link/../gate.ps1
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@ | Set-Content -LiteralPath (Join-Path $symlinkRepo '.github' 'workflows' 'ci.yml') -Encoding utf8
        $symlinkOutput = Join-Path $symlinkRepo 'output.txt'
        & $python.Source -S $script (Join-Path $symlinkRepo '.github' 'workflows' 'ci.yml') *> $symlinkOutput
        $symlinkCode = $LASTEXITCODE
        $symlinkText = Get-Content -LiteralPath $symlinkOutput -Raw

        # WHAT THE RUNNER EXECUTES DIFFERS BY PLATFORM, and that is the whole point of
        # this case: the checker must agree with its own runner, not with a rule someone
        # wrote down. POSIX follows `link` and then climbs from the TARGET's parent, so an
        # untiered file runs. Windows normalises `..` lexically ITSELF, so the tiered file
        # runs and there is no divergence to catch. Asking the same interpreter is the
        # only way to state the expectation without hardcoding one platform's answer --
        # and hardcoding POSIX here is exactly what made the first version of this fixture
        # fail on the authoring host for the wrong reason.
        $probe = @'
import sys
from pathlib import Path
root = Path(sys.argv[1])
real = (root / "scripts/link/../gate.ps1").resolve()
print(real.relative_to(root.resolve()).as_posix())
'@
        $probeFile = Join-Path $symlinkRepo 'probe.py'
        $probe | Set-Content -LiteralPath $probeFile -Encoding utf8
        $executed = (& $python.Source -S $probeFile $symlinkRepo).Trim()

        if ($executed -eq 'scripts/gate.ps1') {
            # This platform normalises `..` lexically, so the path the runner reaches is
            # scripts/gate.ps1 -- which this fixture deliberately does NOT create. A
            # candidate that resolves to no file is not asserted about, so the gate passes.
            if ($symlinkCode -ne 0) {
                throw "on this platform '..' normalises lexically to a file that does not exist, so nothing is asserted and the gate must pass:`n$symlinkText"
            }
        }
        else {
            # An untiered file runs. Vouching for the lexical reduction alone would be
            # fail-open, so the checker must refuse AND name what actually runs.
            if ($symlinkCode -eq 0) {
                throw "a '..' through a symlink reaches '$executed', which no policy tiers -- the gate must refuse it:`n$symlinkText"
            }
            if ($symlinkText -notmatch ([regex]::Escape($executed))) {
                throw "the refusal must name the file the symlink actually reaches ('$executed'):`n$symlinkText"
            }
        }

        # A LEXICAL OVER-CLIMB is not proof the path leaves the checkout.
        # `scripts/link/../../../gate.ps1` removes every component on paper, but when
        # `link` targets a sufficiently deep in-checkout directory the OS lands back
        # INSIDE the repository -- so refusing on the lexical reading alone would omit a
        # gate script that really runs. Containment is decided by the filesystem answer,
        # not the arithmetic. (CodeRabbit, on an upstream review.)
        New-Item -ItemType Directory -Path (Join-Path $symlinkRepo 'elsewhere' 'a' 'b') -Force | Out-Null
        $deepLink = Join-Path $symlinkRepo 'scripts' 'deep'
        $deepMade = $true
        foreach ($kind in @('SymbolicLink', 'Junction')) {
            try {
                New-Item -ItemType $kind -Path $deepLink -Target (Join-Path $symlinkRepo 'elsewhere' 'a' 'b') -ErrorAction Stop | Out-Null
                $deepMade = $true
                break
            }
            catch { $deepMade = $false }
        }

        if (-not $deepMade) {
            Write-Host 'SKIP: cannot create the deep link on this host; the lexical-over-climb case was NOT checked'
        }
        else {
            $overProbe = @'
import sys
from pathlib import Path
root = Path(sys.argv[1])
real = (root / "scripts/deep/../../../gate.ps1").resolve()
try:
    print(real.relative_to(root.resolve()).as_posix())
except ValueError:
    print("<outside>")
'@
            $overProbeFile = Join-Path $symlinkRepo 'overprobe.py'
            $overProbe | Set-Content -LiteralPath $overProbeFile -Encoding utf8
            $overExecuted = (& $python.Source -S $overProbeFile $symlinkRepo).Trim()

            @'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - shell: pwsh
        run: scripts/deep/../../../gate.ps1
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@ | Set-Content -LiteralPath (Join-Path $symlinkRepo '.github' 'workflows' 'ci.yml') -Encoding utf8
            $overOutput = Join-Path $symlinkRepo 'over-output.txt'
            & $python.Source -S $script (Join-Path $symlinkRepo '.github' 'workflows' 'ci.yml') *> $overOutput
            $overCode = $LASTEXITCODE
            $overText = Get-Content -LiteralPath $overOutput -Raw

            if ($overExecuted -eq '<outside>') {
                if ($overCode -ne 0) {
                    throw "an over-climb that genuinely leaves the checkout must not be asserted about:`n$overText"
                }
            }
            else {
                if ($overCode -eq 0) {
                    throw "an over-climb resolving back into the checkout reaches '$overExecuted', which no policy tiers -- the gate must refuse it:`n$overText"
                }
                if ($overText -notmatch ([regex]::Escape($overExecuted))) {
                    throw "the refusal must name the over-climbed file actually reached ('$overExecuted'):`n$overText"
                }
            }
        }
    }

    # ── The OTHER two BOM read paths, and BOM in DIRECTORY mode ─────────────────────
    # Three reads changed to utf-8-sig, and only the workflow one had a fixture. The
    # untested two are the review policy (where json.loads RAISES on a BOM and the
    # surrounding except swallows it as "no policy", silently disabling the HIGH-tier
    # assertion) and the delegated local-action manifest. Directory mode is the third
    # gap and the worst-directioned of them: there a BOM'd workflow was written off as
    # "not a workflow, skipped" and every job in it escaped coverage, which is fail-open
    # where file mode was merely red. (Gitar and CodeRabbit, on an upstream review.)
    function New-BomGateRepo([string] $policyJson, [string[]] $scriptPaths, [string] $yaml, [switch] $BomPolicy, [switch] $BomWorkflow, [string] $Target) {
        $repo = Join-Path $root ('repo-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo '.github' 'workflows') -Force | Out-Null
        $policyJson | Set-Content -LiteralPath (Join-Path $repo '.claude' 'review-policy.json') -Encoding ($BomPolicy ? 'utf8BOM' : 'utf8')
        foreach ($relative in $scriptPaths) {
            $full = $repo
            foreach ($segment in ($relative -split '/')) { $full = Join-Path $full $segment }
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            '# probe' | Set-Content -LiteralPath $full -Encoding utf8
        }
        $yaml | Set-Content -LiteralPath (Join-Path $repo '.github' 'workflows' 'ci.yml') -Encoding ($BomWorkflow ? 'utf8BOM' : 'utf8')
        $output = Join-Path $repo 'output.txt'
        $argument = if ($Target) { Join-Path $repo $Target } else { Join-Path $repo '.github' 'workflows' 'ci.yml' }
        & $python.Source -S $script $argument *> $output
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = Get-Content -LiteralPath $output -Raw }
    }

    # A BOM'd review policy must still be READ, so an untiered gate script is still
    # refused. Before utf-8-sig this exited 0: the policy looked absent, so nothing was
    # asserted -- the fail-open direction, and silent.
    $bomPolicy = New-BomGateRepo '{"version":1,"high":[],"low":[]}' @('scripts/assert-coverage-floor.ps1') $gatedYaml -BomPolicy
    if ($bomPolicy.Code -eq 0 -or $bomPolicy.Output -notmatch 'not tiered\s+HIGH') {
        throw "a BOM'd review policy must still refuse an untiered gate script:`n$($bomPolicy.Output)"
    }

    # DIRECTORY mode over a BOM'd workflow: the gate job must still be found. Before
    # utf-8-sig the file was skipped as "not a workflow" and its jobs escaped entirely.
    $bomDirectory = New-BomGateRepo '{"version":1,"high":[],"low":[]}' @() @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@ -BomWorkflow -Target '.github/workflows'
    if ($bomDirectory.Code -ne 0) {
        throw "directory mode must accept a BOM'd workflow:`n$($bomDirectory.Output)"
    }
    if ($bomDirectory.Output -match 'not a workflow') {
        throw "a BOM'd workflow must not be skipped as 'not a workflow' in directory mode:`n$($bomDirectory.Output)"
    }

    # --- A local action's runs.using is resolved INSIDE the runs: mapping (ported from
    #     the upstream scanner work, 2026-09) ---

    # 1. The block-scalar false match. The description's payload holds an indented
    #    'using': javascript line BEFORE the real runs: mapping; the whole-file search
    #    matched it first and raised on a valid composite action -- a false RED on a
    #    healthy action. (CodeRabbit, on an upstream review.) The composite body invokes
    #    a HIGH-tiered script, so passing ALSO proves the body was followed rather than
    #    the action being silently skipped.
    $blockScalarUsing = New-GateActionRepo @'
name: Probe
description: |
  Explains the metadata shape, for example:
    'using': javascript
runs:
  using: composite
  steps:
    - shell: bash
      run: python scripts/probe.py
'@
    if ($blockScalarUsing.Code -ne 0 -or $blockScalarUsing.Output -notmatch 'scripts/probe\.py') {
        throw "a composite action whose earlier block scalar mentions 'using': must pass, its body followed:`n$($blockScalarUsing.Output)"
    }

    # 2. A flow-style runs: mapping. The line-anchored search could never see `using`
    #    inside `runs: {using: ...}`, so the composite spelling must be recognised --
    #    not raise, and not silently skip the guard.
    $flowComposite = New-GateActionRepo @'
name: Probe
runs: {using: composite, steps: []}
'@
    if ($flowComposite.Code -ne 0) {
        throw "a flow-style runs: {using: composite, ...} must be recognised as composite:`n$($flowComposite.Output)"
    }

    # 2b. The same flow mapping written across SEVERAL LINES, which YAML allows.
    $multilineFlowComposite = New-GateActionRepo @'
name: Probe
runs: {
    using: composite,
    steps: [] }
'@
    if ($multilineFlowComposite.Code -ne 0) {
        throw "a multiline flow runs: mapping must be recognised as composite:`n$($multilineFlowComposite.Output)"
    }

    # 2c. A quoted VALUE carrying a false `using` must not be read as the mapping's own
    #     entry. Searching the joined text matched `{using: composite}` inside the
    #     string and vouched composite for a DOCKER action -- fail-open, the dangerous
    #     direction. Extraction counts a key only OUTSIDE quotes and at depth ONE.
    $quotedFalseUsing = New-GateActionRepo @'
name: Probe
runs: {note: "{using: composite}", using: docker, main: index.js}
'@
    if ($quotedFalseUsing.Code -eq 0 -or $quotedFalseUsing.Output -notmatch 'runs\.using docker') {
        throw "a quoted false using must not mask the real runs.using docker:`n$($quotedFalseUsing.Output)"
    }

    # 2d. ...and a `#` inside a QUOTED flow value is data, not a comment. Truncating
    #     there first broke the mapping mid-scan and reddened a valid composite action.
    #     A comment AFTER the mapping is the ordinary case and must keep working.
    foreach ($hashRuns in @(
        'runs: {description: "a # b", using: composite}',
        'runs: {using: composite, steps: []} # tail'
    )) {
        $quotedHashFlow = New-GateActionRepo "name: Probe`n$hashRuns"
        if ($quotedHashFlow.Code -ne 0) {
            throw "a quoted # inside a flow mapping (or a real trailing comment) must not break runs.using resolution:`n$hashRuns`n---`n$($quotedHashFlow.Output)"
        }
    }

    # 2e. A QUOTED key is still a key: {'using': composite} parses exactly as the bare
    #     spelling does (key_pattern admits quoted keys in block style; flow must agree).
    $quotedKeyFlow = New-GateActionRepo @'
name: Probe
runs: {'using': composite, steps: []}
'@
    if ($quotedKeyFlow.Code -ne 0) {
        throw "a quoted 'using' key in a flow mapping must be recognised:`n$($quotedKeyFlow.Output)"
    }

    # 3. A runs: mapping with NO readable using: entry must RAISE -- fail closed rather
    #    than skip the guard and follow a body whose kind cannot be verified. The flow
    #    form (a typo'd key), the block form (no using: child at all), the multiline
    #    flow form, and a `using` inside a NESTED flow collection (depth one only).
    foreach ($badRuns in @(
        'runs: {usign: composite, steps: []}',
        "runs:`n  steps:`n    - shell: bash`n      run: echo hi",
        "runs: {`n    usign: composite,`n    steps: [] }",
        'runs: {steps: [{using: composite}]}'
    )) {
        $noUsing = New-GateActionRepo "name: Probe`n$badRuns"
        if ($noUsing.Code -eq 0 -or $noUsing.Output -notmatch 'no readable') {
            throw "a runs: mapping with no readable using: entry must fail closed:`n$badRuns`n---`n$($noUsing.Output)"
        }
    }

    # 4. The step-level static fold (from the upstream unit review, 2026-09-21): the
    #    gate's aggregation step with a statically false continue-on-error tolerates
    #    nothing, so it CAN still fail the job and the gate stands.
    $staticFalseStep = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        continue-on-error: ${{ false && inputs.allow_failure }}
        run: exit 1
'@
    if ($staticFalseStep.Code -ne 0) {
        throw "a statically false step-level continue-on-error must not read as cannot-fail:`n$($staticFalseStep.Output)"
    }

    # ... and step-level controls: literal true and an unfoldable expression still refuse.
    foreach ($case in @('true', '${{ inputs.allow_failure }}')) {
        $stepTolerant = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        continue-on-error: $case
        run: exit 1
"@
        if ($stepTolerant.Code -eq 0 -or $stepTolerant.Output -notmatch 'continue-on-error') {
            throw "a tolerant or unfoldable step-level continue-on-error must be refused ($case):`n$($stepTolerant.Output)"
        }
    }

    # 5. A block-scalar job-level spelling (`continue-on-error: >` then `false`) folds
    #    to the literal false and tolerates nothing; the key-line-only read saw the
    #    bare `>` header and counted the job tolerant -- a false RED.
    $blockScalarTolerance = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
    continue-on-error: >
      false
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
'@
    if ($blockScalarTolerance.Code -ne 0) {
        throw "a block-scalar continue-on-error folding to false must not read as tolerant:`n$($blockScalarTolerance.Output)"
    }

    # `always()` is unconditionally true, so `always() && <coverage>` gates exactly what the
    # coverage atom gates. Leaving it UNKNOWN kept it as a residual conjunct and reported a
    # correct gate as referencing no needs.<job>.result at all -- a false RED on the very
    # shape the gate's own job-level condition uses.
    # (CodeRabbit, on an upstream review.)
    foreach ($shape in @(
        "always() && (contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled'))",
        "always() && contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')"
    )) {
        $alwaysGate = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: $shape
        run: exit 1
"@
        if ($alwaysGate.Code -ne 0) {
            throw "always() must fold to true in a step condition:`n$($alwaysGate.Output)"
        }
    }

    # success(), failure() and cancelled() depend on the run, so they must NOT fold -- doing
    # so would be the fail-OPEN direction. `success() && <coverage>` is a step that does not
    # run when an upstream job failed, which is exactly when the gate must fail.
    $successGate = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: success() && (contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled'))
        run: exit 1
'@
    if ($successGate.Code -eq 0) {
        throw "success() must not fold to true -- it is false exactly when the gate must fail:`n$($successGate.Output)"
    }

    # Block-scalar-ness is a property of the RAW header, not of the decoded command. A
    # quoted inline scalar whose command OPENS with a redirection decodes to a string
    # starting with `>`, and testing the decoded text read it as a folded body: the step
    # supplied no coverage and the gate went red over a command that does fail.
    # (CodeRabbit, on an upstream review.)
    $leadingRedirect = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: ">&2 echo upstream failed; exit 1"
'@
    if ($leadingRedirect.Code -ne 0) {
        throw "a quoted body opening with a redirection is inline, not folded:`n$($leadingRedirect.Output)"
    }

    # A CONDITIONAL feeder's house shape: the job may legitimately skip, so skipping must
    # not fail the gate, and `!= 'skipped'` NARROWS the `!= 'success'` atom about the SAME
    # job rather than adding a condition this checker cannot read. Refusing every residual
    # conjunction rejected a consuming repository's correct gate as "aggregates nothing" --
    # found by running the reconciled checker over all 26 repositories BEFORE syncing it to
    # any of them, which is the only reason it was not shipped estate-wide.
    $conditionalFeeder = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  secrets:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build, secrets]
    runs-on: ubuntu-latest
    steps:
      - if: needs.build.result != 'success' || (needs.secrets.result != 'success' && needs.secrets.result != 'skipped')
        run: exit 1
'@
    if ($conditionalFeeder.Code -ne 0) {
        throw "a conditional feeder narrowed by != 'skipped' must be accepted:`n$($conditionalFeeder.Output)"
    }

    # ...but the refinement must name the SAME job, and an unreadable conjunct is still
    # refused: both make the step depend on state the atom does not describe, so the
    # outcomes it appears to cover are not the outcomes that fail the gate.
    foreach ($case in @(
        @{ Name = 'a refinement about a different job'; Condition = "needs.build.result != 'success' && needs.secrets.result != 'skipped'" },
        @{ Name = 'an unreadable residual conjunct'; Condition = "needs.build.result != 'success' && inputs.deep" }
    )) {
        $refused = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  secrets:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build, secrets]
    runs-on: ubuntu-latest
    steps:
      - if: $($case.Condition)
        run: exit 1
"@
        if ($refused.Code -eq 0) {
            throw "$($case.Name) must not count as coverage:`n$($refused.Output)"
        }
    }

    # A `#` inside a QUOTED YAML scalar is data, not a comment. Truncating there hid the
    # script that follows it, so the script escaped the HIGH-tier requirement -- fail-open
    # on this control. Both quote styles, because the escape rules differ.
    # (CodeRabbit, on an upstream review.)
    $quotedHash = @{
        'double-quoted' = '      - run: "printf ''tag # audit''; python .github/scripts/probe.py"'
        'single-quoted' = "      - run: 'printf \`"tag # audit\`"; python .github/scripts/probe.py'"
    }
    foreach ($style in $quotedHash.Keys) {
        $hashed = New-GateRepo '{"version":1,"high":[],"low":[]}' @('.github/scripts/probe.py') @"
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
$($quotedHash[$style])
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
"@
        if ($hashed.Code -eq 0 -or $hashed.Output -notmatch 'probe\.py') {
            throw "a gate script after a literal # in a $style run: scalar must be detected:`n$($hashed.Output)"
        }
    }

    # The same bug seen from the other side: a quoted body carrying a literal `#`, with a
    # genuine YAML comment after the closing quote. Truncating at the inner hash left an
    # unterminated fragment, so a gate that DOES fail read as one that cannot -- a false
    # RED. (CodeRabbit, on an upstream review.)
    $quotedBody = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: 'echo " # progress"; exit 1' # gate
'@
    if ($quotedBody.Code -ne 0) {
        throw "a quoted run: body carrying a literal # must still be read as failing:`n$($quotedBody.Output)"
    }

    # ...and the PLAIN-scalar case must keep behaving the opposite way. YAML itself ends
    # an unquoted value at ` #`, so the shell never receives what follows: treating shell
    # quotes as protection there would vouch for a command the runner does not run.
    $plainHash = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: echo 'tag # audit'; exit 1
'@
    if ($plainHash.Code -eq 0) {
        throw "an unquoted run: value is truncated by YAML at ` #, so it must not be vouched for:`n$($plainHash.Output)"
    }

    # The rules this asset absorbed from the two upstream CI
    # copies, which had each hardened independently while canonical carried neither. They
    # are pinned HERE, in the canonical suite, because the three-way divergence they close
    # was invisible until all three test files were run against one file: a rule owned only
    # by a downstream copy is a rule canonical can silently regress.
    $both = "contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')"
    $absorbed = @(
        # condition suffix, run body, must pass, description
        @('', 'exit 255', $true, 'exit 255 is the top of the shell nonzero range'),
        # `exit 256` exits ZERO -- the shell takes the status modulo 256 -- so a gate body
        # spelt that way reports success over a failed dependency.
        @('', 'exit 256', $false, 'exit 256 exits zero and must not be vouched for'),
        @('', 'exit 300', $false, 'a status above the range exits zero'),
        # A quoted YAML scalar is the same command as its unquoted form.
        @('', '"exit 1"', $true, 'a quoted run: scalar is decoded before inspection'),
        # A trailing redirection does not change whether the command fails.
        @('', 'echo "blocked" >&2; exit 1 >&2', $true, 'compound forms may carry a redirection'),
        # A conjunct that is statically TRUE cannot change whether the step runs, and
        # GitHub's `==` is case-insensitive.
        @(" && 'VALUE' == 'value'", 'exit 1', $true, 'a statically-true conjunct is dropped'),
        @(' && 2 > 1', 'exit 1', $true, 'a true numeric comparison is dropped'),
        # ...but one that is statically FALSE means the step never runs, and one whose
        # value cannot be read means the atoms' outcomes are not the gate's outcomes.
        @(" && 'left' == 'right'", 'exit 1', $false, 'a statically-false conjunct gates nothing'),
        @(' && inputs.deep', 'exit 1', $false, 'an unreadable residual conjunct is refused')
    )
    foreach ($case in $absorbed) {
        $probe = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: $both$($case[0])
        run: $($case[1])
"@
        if (($probe.Code -eq 0) -ne $case[2]) {
            throw "$($case[3]):`n$($probe.Output)"
        }
    }

    # Every dependency must make the gate fail for CANCELLATION as well as failure. A
    # cancelled job is not a passing one, and a gate keyed on 'failure' alone reports
    # green over it.
    $failureOnly = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure')
        run: exit 1
'@
    if ($failureOnly.Code -eq 0 -or $failureOnly.Output -notmatch 'build:cancelled') {
        throw "a gate that ignores cancellation must be rejected by name:`n$($failureOnly.Output)"
    }

    # `!= 'success'` covers both terminal results in one atom, and is the spelling the
    # rejection above recommends -- so it has to be accepted.
    $notSuccess = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: needs.build.result != 'success'
        run: exit 1
'@
    if ($notSuccess.Code -ne 0) {
        throw "`!= 'success' covers both terminal results and must be accepted:`n$($notSuccess.Output)"
    }

    # A FOLDED body joins its lines with spaces at run time, so the command that actually
    # executes is not any line in the file.
    $folded = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: >
          exit 1
'@
    if ($folded.Code -eq 0 -or $folded.Output -notmatch 'folded') {
        throw "a folded run: body must be refused by name:`n$($folded.Output)"
    }

    # `${#x}` is a shell parameter expansion, not a comment. Stripping from the bare `#`
    # truncated the command and reported a correct gate as unfailable.
    $parameterLength = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: echo len=${#x} && exit 1
'@
    if ($parameterLength.Code -ne 0) {
        throw "a shell parameter length must not be stripped as a comment:`n$($parameterLength.Output)"
    }

    # --- the verdict is over the WHOLE body, not its first matching line ---------------
    # Accepting any matching segment vouched for an `exit 1` the step never reaches: it
    # exits ZERO on the earlier line while the checker reads the later one. Only MESSAGE
    # lines may precede the failing command, because a message cannot re-decide the
    # step's exit status.
    $unreachable = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: |
          exit 0
          exit 1
'@
    if ($unreachable.Code -eq 0) {
        throw "an unreachable exit 1 behind exit 0 must not be vouched for:`n$($unreachable.Output)"
    }

    $messagePrefix = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: |
          echo "::error::an upstream job did not succeed"
          exit 1
'@
    if ($messagePrefix.Code -ne 0) {
        throw "message lines before the failing command must stay accepted:`n$($messagePrefix.Output)"
    }

    # EVERY preceding line is tested, not just the first, and _MESSAGE admits the whole
    # message vocabulary: `printf` as well as `echo`, and a leading redirection as well as
    # a trailing one. A regression narrowing the prefix loop to its first line, or the
    # pattern to bare `echo`, passes the single-message case above. (Gitar, PR #176.)
    $messagePrefixes = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: |
          echo "::error::an upstream job did not succeed"
          printf '%s\n' "collecting upstream results"
          >&2 echo "see the job summary"
          exit 1
'@
    if ($messagePrefixes.Code -ne 0) {
        throw "consecutive echo/printf/redirected message lines must stay accepted:`n$($messagePrefixes.Output)"
    }

    # The prefix rule is what makes the whole-body verdict mean anything: a non-message
    # line before the failing command can re-decide the exit status, so it must be
    # refused however ordinary it looks.
    $nonMessagePrefix = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: |
          echo "::error::an upstream job did not succeed"
          trap 'exit 0' EXIT
          exit 1
'@
    if ($nonMessagePrefix.Code -eq 0) {
        throw "a non-message line before the failing command must be refused:`n$($nonMessagePrefix.Output)"
    }

    # `set -euo pipefail` is the house prefix on run: blocks here, and it cannot decide
    # the exit status -- the final line still has to be an accepted failing form. The
    # message-prefix rule refused it, which is a false RED on a gate that does fail.
    # (CodeRabbit, PR #176.)
    $shellOptionPrefix = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: |
          set -euo pipefail
          echo "::error::an upstream job did not succeed"
          exit 1
'@
    if ($shellOptionPrefix.Code -ne 0) {
        throw "a set -euo pipefail prefix must stay accepted:`n$($shellOptionPrefix.Output)"
    }

    # NOT EVERY SHELL OPTION IS INERT. `set -n` (noexec) and `set -t` (onecmd) stop the
    # shell before the final command, so the `exit 1` the checker can see never runs and
    # the step exits ZERO. Both arms are pinned: the unsafe options refused, the safe
    # ones accepted -- an allowlist narrowed by accident would pass the first half of
    # this alone. (CodeRabbit, PR #176.)
    foreach ($case in @(
        @('set -n', $false),
        @('set -o noexec', $false),
        @('set -t', $false),
        @('set -o onecmd', $false),
        @('set -e', $true),
        @('set -x', $true),
        @('set -o nounset', $true),
        @('set -o errexit', $true)
    )) {
        $option, $accepted = $case
        $optionGate = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: |
          $option
          echo "::error::an upstream job did not succeed"
          exit 1
"@
        if ($accepted -and $optionGate.Code -ne 0) {
            throw "an inert shell option must stay accepted ($option):`n$($optionGate.Output)"
        }
        if (-not $accepted -and $optionGate.Code -eq 0) {
            throw "an execution-disabling shell option must be refused ($option):`n$($optionGate.Output)"
        }
    }

    # A command subexpression exits the step before the failing command under pwsh, and
    # mask_quoted blanks it to a bare `echo` that reads as an ordinary message. Refused
    # quoted and unquoted -- what it does cannot be read from the file. This one is
    # older than the whole-body rule: the any-line rule vouched for the same body on its
    # `throw` alone. (CodeRabbit, PR #176.)
    foreach ($subexpression in @('echo "$(exit 0)"', 'echo $(exit 0)')) {
        $subexpressionGate = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        shell: pwsh
        run: |
          $subexpression
          throw "upstream failed"
"@
        if ($subexpressionGate.Code -eq 0) {
            throw "a command subexpression must be refused ($subexpression):`n$($subexpressionGate.Output)"
        }
    }

    # THIS ASSERTION WAS REVERSED ON 2026-09-20, and the reversal is recorded rather than
    # quietly applied. It used to read: "`${{ ... }}` is not `$(`, and refusing it would
    # red every house gate" -- and it was right about the consequence. Measured when the
    # hardened checker became canonical: 18 of the 28 repositories that passed went red,
    # every one of them on this spelling and none of them actually exploitable.
    #
    # It is reversed anyway, because the reasoning behind the old assertion was about the
    # EXPRESSION being harmless while the checker's problem is that it cannot know that.
    # GitHub substitutes `${{ ... }}` textually before the shell parses the line, so the
    # question is not whether `join` over job results is safe -- it is -- but whether this
    # checker can tell a safe expansion from one that splices in a separator or an early
    # exit. Answering that means evaluating GitHub expressions here, and widening this
    # file's accepted forms on that kind of reasoning has already shipped a fail-open rule
    # once (CodeRabbit, PR #176, refuted in a later round).
    #
    # The house gate moved to `env:` instead, across the estate, which costs nothing and
    # needs no judgement call at all. The old spelling is asserted as REFUSED above.
    $githubExpression = Invoke-Gate @'
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        env:
          RESULTS: ${{ join(needs.*.result, ', ') }}
        run: |
          echo "Upstream results: $RESULTS"
          exit 1
'@
    if ($githubExpression.Code -ne 0) {
        throw "a GitHub expression hoisted into env: must stay accepted:`n$($githubExpression.Output)"
    }

    foreach ($case in @(
        @("needs['build'].result != 'success'", '', $true),
        @('needs["build"].result != "success"', '', $true),
        @("needs['build'].result != 'success' && needs['build'].result != 'skipped'", '', $true),
        @("needs['build'].result != 'success' && github.ref == 'refs/heads/main'", '', $false),
        @("needs['build'].result != 'success' && needs.other.result != 'skipped'", '', $false),
        @("needs.build.result != 'success'", "continue-on-error:`n          true", $false),
        @("needs.build.result != 'success'", "continue-on-error: >`n          true", $false),
        @("needs.build.result != 'success'", "continue-on-error: >`n          false", $true),
        @("needs.build.result != 'success'", 'continue-on-error: False', $true)
    )) {
        $probe = Invoke-Gate @"
jobs:
  build:
    runs-on: ubuntu-latest
  ci-gate:
    if: Always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: $($case[0])
        $($case[1])
        run: exit 1
"@
        if (($probe.Code -eq 0) -ne $case[2]) {
            throw "index-access or multiline tolerance regression: $($case[0]) / $($case[1]):`n$($probe.Output)"
        }
    }

    'assert_gate_coverage.py OK - quoted keys, sequence forms, fail-closed parsing, conditional feeders, the gate''s own always()/aggregation semantics, cancellation coverage, and gate scripts tiered HIGH'
}
finally {
    $env:GATE_EXEMPT = $oldExempt
    $env:GATE_CONDITIONAL_EXEMPT = $oldConditionalExempt
    $env:GATE_FILE_EXEMPT = $oldFileExempt
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
