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

function Invoke-Gate([string] $yaml) {
    $workflow = Join-Path $root 'ci.yml'
    $output = Join-Path $root 'output.txt'
    $yaml | Set-Content -LiteralPath $workflow -Encoding utf8
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
    # fixportal-initiator#225.
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
        run: |
          echo "Upstream results: ${{ join(needs.*.result, ', ') }}"
          exit 1
'@
    if ($conditionAndEcho.Code -ne 0) {
        throw "the shipped gate shape (step if: plus diagnostic echo) must pass:`n$($conditionAndEcho.Output)"
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
    # gate that aggregates nothing. Found by CodeRabbit on fixportal-quickfixn#68.
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
    # fixportal-ci-backend PR #140.)
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

    # `always()` is unconditionally true, so `always() && <coverage>` gates exactly what the
    # coverage atom gates. Leaving it UNKNOWN kept it as a residual conjunct and reported a
    # correct gate as referencing no needs.<job>.result at all -- a false RED on the very
    # shape the gate's own job-level condition uses.
    # (CodeRabbit, fixportal-claude-skills#106.)
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
    # (CodeRabbit, fixportal-claude-skills#106.)
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
    # conjunction rejected fixportal-initiator's correct gate as "aggregates nothing" --
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
    # (CodeRabbit, fixportal-ci-backend PR #140.)
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
    # RED. (CodeRabbit, fixportal-ci-frontend PR #163.)
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

    # The rules this asset absorbed from the fixportal-ci-backend and fixportal-ci-frontend
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
        run: if [ ${#x} -eq 0 ]; then exit 1; fi
'@
    if ($parameterLength.Code -ne 0) {
        throw "a shell parameter length must not be stripped as a comment:`n$($parameterLength.Output)"
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
