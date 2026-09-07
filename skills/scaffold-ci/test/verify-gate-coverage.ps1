$ErrorActionPreference = 'Stop'

$script = Resolve-Path (Join-Path $PSScriptRoot '..' 'assets' 'assert_gate_coverage.py')
$root = Join-Path ([IO.Path]::GetTempPath()) ('gate-coverage-' + [guid]::NewGuid().ToString('N'))
$oldExempt = $env:GATE_EXEMPT
$oldConditionalExempt = $env:GATE_CONDITIONAL_EXEMPT
$env:GATE_EXEMPT = ''
$env:GATE_CONDITIONAL_EXEMPT = ''

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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
    # the upstream review.
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
          contains(needs.*.result, 'failure')
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
          contains(needs.*.result, 'failure')
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
      - if: contains(needs.*.result, 'failure')
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
    # gate that aggregates nothing. Found by CodeRabbit on the upstream review.
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
          echo "This gate is wired like:"
          echo "  if: contains(needs.*.result, 'failure')"
      - name: Fail if any upstream job did not succeed
        run: exit 1
'@
    if ($conditionInRunBody.Code -eq 0 -or $conditionInRunBody.Output -notmatch 'has no step whose `if:` references a') {
        throw "if:-shaped text inside a preceding run: body must not count as a real step condition:`n$($conditionInRunBody.Output)"
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
          echo "  if: contains(needs.*.result, 'failure')"
      - name: Fail if any upstream job did not succeed
        if: contains(needs.*.result, 'failure')
        run: exit 1
'@
    if ($conditionAfterRunBody.Code -ne 0) {
        throw "a real step if: after a look-alike run: body must still be read:`n$($conditionAfterRunBody.Output)"
    }

    'assert_gate_coverage.py OK - quoted keys, sequence forms, fail-closed parsing, conditional feeders, and the gate''s own always()/aggregation semantics'
}
finally {
    $env:GATE_EXEMPT = $oldExempt
    $env:GATE_CONDITIONAL_EXEMPT = $oldConditionalExempt
    if ($root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
