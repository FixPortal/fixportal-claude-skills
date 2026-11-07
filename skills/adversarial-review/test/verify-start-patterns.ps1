#Requires -Version 7
$ErrorActionPreference = 'Stop'

# Contract test for run-review.ps1's ROUND CONTRACT: the Phase 1 / Phase 2 start patterns that
# decide whether a reviewer counted as participating, and the round timeout that stops one wedged
# slot from stalling a phase forever.
#
# Why this exists: the strict line-initial patterns discarded substantive, repository-backed
# reviews TWICE on formatting alone -- 2026-08-16 (`**F1** ... AGREE`, three anthropic reviews)
# and 2026-08-17 (`**F1: FALSE POSITIVE**`). Both times the reviewer was dropped from the
# participating-vendor count, so every consensus tally for that chunk was wrong. Widening the
# pattern then risks the opposite failure -- admitting narration as a verdict block -- so both
# directions are pinned here.

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'run-review.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "run-review.ps1 not found at $scriptPath" }
$source = Get-Content -LiteralPath $scriptPath -Raw

function Get-InvokeRoundPattern([string] $phase) {
    # Pull the literal the script actually passes, rather than restating it here -- a copy would
    # drift and the test would pass while the driver used something else. Phase 1 passes the
    # SHARED $script:FindingHeading variable (see the participation/pooling contract below),
    # so follow it to its assignment rather than demanding an inline literal.
    $match = [regex]::Match($source, "(?m)^\`$${phase}ok = Invoke-Round '$phase' '(?<pattern>.+?)'\s")
    if ($match.Success) { return $match.Groups['pattern'].Value }
    $viaVariable = [regex]::Match($source, "(?m)^\`$${phase}ok = Invoke-Round '$phase' \`$(?<name>[\w:]+)\s")
    if (-not $viaVariable.Success) { throw "could not find the Invoke-Round call for phase '$phase'" }
    $name = $viaVariable.Groups['name'].Value
    $assignment = [regex]::Match($source, "(?m)^\`$$([regex]::Escape($name)) = '(?<pattern>.+?)'\s*$")
    if (-not $assignment.Success) { throw "phase '$phase' uses `$$name but its assignment could not be read" }
    $assignment.Groups['pattern'].Value
}

$failures = @()
function Check([string] $label, [string] $pattern, [string] $line, [bool] $expected) {
    $actual = [bool]($line -match $pattern)
    if ($actual -ne $expected) {
        $script:failures += "[$label] '$line' -> match=$actual, expected=$expected"
    }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
$headingParser = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ReviewHeadingLineNumbers' }, $true)
if ($null -eq $headingParser) { throw 'Get-ReviewHeadingLineNumbers was not found in run-review.ps1' }
. ([scriptblock]::Create($headingParser.Extent.Text))
$fencedHeadings = @(Get-ReviewHeadingLineNumbers -Lines @('````powershell', '### hidden', '```', '### still hidden', '````', '### visible') -Pattern '^### ')
if ($fencedHeadings.Count -ne 1 -or $fencedHeadings[0] -ne 5) {
    $failures += 'a shorter closing fence must not end a longer opening fence'
}
# A line that merely starts with an inline ``` span is not a fence (CommonMark: a backtick info
# string holds no backtick), and an unclosed fence must not hide every later heading.
$inline = @(Get-ReviewHeadingLineNumbers -Lines @('### A', '```x``` is inline code', '### B') -Pattern '^### ')
if (($inline -join ',') -ne '0,2') { $failures += "an inline triple-backtick span opened a fence and hid a later heading (got $($inline -join ','))" }
$unclosed = @(Get-ReviewHeadingLineNumbers -Lines @('### A', '```powershell', 'x', '### B') -Pattern '^### ')
if (($unclosed -join ',') -ne '0,3') { $failures += "an unclosed fence hid every later heading (got $($unclosed -join ','))" }

# A reply wrapped in a ```markdown fence, whole or per finding, is markdown, not a code sample.
$wrapperParser = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Expand-WrapperFences' }, $true)
if ($null -eq $wrapperParser) { $failures += 'Expand-WrapperFences was not found in run-review.ps1' }
else {
    . ([scriptblock]::Create($wrapperParser.Extent.Text))
    function Get-WrappedHeadings([string[]] $Lines) {
        $expanded = Expand-WrapperFences $Lines '^### '
        @(Get-ReviewHeadingLineNumbers -Lines $expanded -Pattern '^### ' | ForEach-Object { $expanded[$_] }) -join '|'
    }
    $shapes = @(
        @{ Name = 'whole reply in a markdown fence'; Lines = @('```markdown', '### A', 'a', '### B', 'b', '```'); Want = '### A|### B' }
        @{ Name = 'whole reply in a bare fence'; Lines = @('```', '### A', 'a', '```'); Want = '### A' }
        @{ Name = 'one markdown fence per finding'; Lines = @('Gaps', '', '```markdown', '### A', '```', '', '```markdown', '### B', '```'); Want = '### A|### B' }
        @{ Name = 'markdown wrapper with a nested code block'; Lines = @('```markdown', '### A', '```powershell', 'x', '```', '### B', '```'); Want = '### A|### B' }
        @{ Name = 'a markdown example inside a plain finding stays fenced'; Lines = @('### A', 'fix it like so:', '```markdown', '### <short title>', '```', 'done'); Want = '### A' }
        @{ Name = 'a quoted heading in a code sample stays hidden'; Lines = @('### A', '```text', '### quoted', '```'); Want = '### A' }
        @{ Name = 'leading and trailing code samples are not a wrapper'; Lines = @('```', 'code', '```', '### A', '```', 'more', '```'); Want = '### A' }
    )
    foreach ($shape in $shapes) {
        $got = Get-WrappedHeadings $shape.Lines
        if ($got -ne $shape.Want) { $failures += "[wrapper] $($shape.Name): got '$got', want '$($shape.Want)'" }
    }
}
if ($source -notmatch '\$lines = Expand-WrapperFences') {
    $failures += 'Strip-Preamble must unwrap wrapper fences before it scans and slices the reply'
}

# --- Phase 1: findings are '### ' headings -----------------------------------
$p1 = Get-InvokeRoundPattern 'p1'
Check 'p1' $p1 '### Missing JSON serialization metadata' $true
Check 'p1' $p1 '  ### Indented heading' $true
Check 'p1' $p1 '- ### Heading in a list item' $true
Check 'p1' $p1 '#### Deeper heading' $true
Check 'p1' $p1 'I will now review the diff.' $false
Check 'p1' $p1 'Here are my findings:' $false
# An inline comment after sentence punctuation split a finding into two F-ids (2026-10-31).
Check 'p1' $p1 'x = 1.  # float' $false
Check 'p1' $p1 'I inspected the diff.### NO FINDINGS' $true

# --- Phase 2: per-finding verdicts, however the reviewer emphasises them ------
$p2 = Get-InvokeRoundPattern 'p2'

# MUST match. Each of these was emitted by a real reviewer; the first two are the exact forms
# that were wrongly discarded on 2026-08-17 and 2026-08-16 respectively.
Check 'p2' $p2 '**F1: FALSE POSITIVE**' $true
Check 'p2' $p2 '**F12** ... AGREE' $true
Check 'p2' $p2 'F1: AGREE - real' $true
Check 'p2' $p2 '__F7__ REFUTED' $true
Check 'p2' $p2 '- **F3.** disagree' $true
Check 'p2' $p2 'F9) needs evidence' $true
Check 'p2' $p2 '### Verdicts' $true

# MUST NOT match. Narration and prose that merely mentions an F-number is not a verdict block;
# admitting it would count a reviewer that contributed nothing as a participating vendor.
Check 'p2' $p2 'F12 and F13 both agree with this' $false
Check 'p2' $p2 'F5 findings were raised in total' $false
Check 'p2' $p2 'I will now review the diff.' $false
Check 'p2' $p2 'Adversarial verdict pass. Skills not applicable' $false
Check 'p2' $p2 'FIXME: this is prose' $false

# --- One heading parser, three sites ------------------------------------------
# Participation, pooling and the issuesRaised counter must agree. While participation used
# the tolerant pattern and the other two split on a line-initial '^### ', a reviewer using
# an admitted-but-unpooled form passed the gate, counted toward minVendors, and
# contributed zero findings with issuesRaised = 0 and no warning -- its findings never
# reaching cross-examination while its telemetry row read as a reviewer that found nothing.
if ($source -match "(?m)^\s*if \(\`$ln -match '\^### '\)") {
    $failures += 'the pooling loop still splits on a hardcoded ^### heading instead of the shared parser.'
}
if ($source -match "Where-Object \{ \`$_ -match '\^### ' \}") {
    $failures += 'the issuesRaised counter still counts a hardcoded ^### heading instead of the shared parser.'
}
foreach ($use in @(
    @{ Name = 'participation (Strip-Preamble)'; Pattern = '\$headingIndices = @\(Get-ReviewHeadingLineNumbers -Lines \$lines -Pattern \$startPattern\)' }
    @{ Name = 'pooling'; Pattern = '\$headingIndices = @\(Get-ReviewHeadingLineNumbers -Lines \$lines -Pattern \$script:FindingHeading\)' }
)) {
    if ($source -notmatch $use.Pattern) { $failures += "$($use.Name) must use the shared heading parser." }
}
# issuesRaised is read off the pooler's own provenance, so it cannot disagree with what pooled.
if ($source -notmatch '\$raised = @\(\$pooledMap\.Values \| Where-Object \{ \$_\.reviewer -eq \$r\.id \}\)\.Count') {
    $failures += 'issuesRaised must be derived from pooled-map provenance, not re-counted from the phase file.'
}

# --- Phase 2 verdict LINES: coverage and out-of-pool detection key on these -----
$verdictStart = [regex]::Match($source, "(?m)^\`$script:P2VerdictStart = '(?<p>.+?)'\s*$").Groups['p'].Value
$verdictLineTemplate = [regex]::Match($source, '(?m)^\$script:P2VerdictLine = "(?<p>.+?)"\s*$').Groups['p'].Value
if (-not $verdictStart -or -not $verdictLineTemplate) {
    $failures += 'the Phase-2 verdict start/line assignments could not be read.'
} else {
    if (-not $p2.StartsWith("$verdictStart|")) {
        $failures += 'the Phase-2 start pattern no longer begins with $script:P2VerdictStart; coverage and admission can drift apart.'
    }
    $verdictLine = '(?im)' + $verdictLineTemplate.Replace('$script:P2VerdictStart', $verdictStart)
    Check 'p2-verdict' $verdictLine '**F1: FALSE POSITIVE**' $true
    Check 'p2-verdict' $verdictLine '**F12** ... AGREE' $true
    Check 'p2-verdict' $verdictLine 'F9) needs evidence' $true
    Check 'p2-verdict' $verdictLine 'F4: needs repo - caller not visible' $true
    Check 'p2-verdict' $verdictLine 'F3. disagree' $false
    Check 'p2-verdict' $verdictLine 'F1: arbitrary text with no verdict' $false
    Check 'p2-verdict' $verdictLine 'F12 and F13 both agree with this' $false
    Check 'p2-verdict' $verdictLine '### Verdicts' $false

    # Coverage credits every id a verdict keyword follows, and ignores fenced examples.
    $verdictParser = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VerdictedIds' }, $true)
    if ($null -eq $verdictParser) { $failures += 'Get-VerdictedIds was not found in run-review.ps1' }
    else {
        . ([scriptblock]::Create($verdictParser.Extent.Text))
        $script:P2VerdictLine = $verdictLineTemplate.Replace('$script:P2VerdictStart', $verdictStart)
        foreach ($case in @(
            @{ Text = "F5: AGREE; F6: AGREE"; Want = 'F5,F6' }
            @{ Text = "F1: AGREE - real`n``````text`nF2: AGREE`n``````"; Want = 'F1' }
            @{ Text = "F3: AGREE - same mechanism as F7, which is out of scope"; Want = 'F3' }
            @{ Text = "F3: AGREE with F7's reasoning; F8: AGREE"; Want = 'F3,F8' }
        )) {
            $got = @(Get-VerdictedIds $case.Text) -join ','
            if ($got -ne $case.Want) { $failures += "[verdict-ids] '$($case.Text -replace "`n", ' / ')': got '$got', want '$($case.Want)'" }
        }
        $lineKeywords = [regex]::Match($verdictLineTemplate, '\\b\(\?:(?<k>[^)]+)\)\\b').Groups['k'].Value
        if (-not $lineKeywords -or $verdictParser.Extent.Text -notmatch [regex]::Escape("(?:$lineKeywords)")) {
            $failures += 'Get-VerdictedIds no longer uses the same verdict keywords as P2VerdictLine.'
        }
    }
}

# The brief must say what the driver does with a heading-less reply: it takes part, unpooled.
$phase1Brief = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'briefs' 'phase1-review.txt') -Raw
if ($phase1Brief -match 'review is dropped from the panel' -or $phase1Brief -notmatch 'still\s+counts\s+as\s+taking\s+part') {
    $failures += 'phase1-review.txt misstates what happens to a reply with no heading (the driver counts it as taking part, unpooled).'
}
if ($source -notmatch '(?s)function Get-ReviewHeadingLineNumbers.*?\$line\s+-match\s+\$Pattern') {
    $failures += 'the shared heading parser must match each non-fenced line against its supplied pattern.'
}

# An explicit no-findings reply is PARTICIPATION with zero findings. Without a recognised
# form for it, the panel was structurally unable to return "clean": an all-clean round died
# on "no reviewer produced Phase 1 findings", making a defect-free diff indistinguishable
# from a broken run.
if ($source -notmatch '\$script:NoFindingsHeading\s*=') {
    $failures += 'no NO FINDINGS heading is recognised, so a clean panel cannot report clean.'
}
# ...and it must recognise ONLY that. The heading has to BE the phrase: matching anything
# that merely STARTS with it made `### NO FINDINGS in the parser, but the writer leaks` -
# a finding - discard the reviewer's entire reply while still counting it as participating,
# leaving a "0 findings" line as the only trace. Silence is the wrong direction here: a
# clean note pooled as a finding is visible to the judge; a discarded reviewer is not.
$noFindingsAssignment = [regex]::Match($source, "(?m)^\`$script:NoFindingsHeading = '(?<pattern>.+?)'\s*$")
if (-not $noFindingsAssignment.Success) {
    $failures += 'the NO FINDINGS heading pattern could not be read from its assignment.'
} else {
    $nf = $noFindingsAssignment.Groups['pattern'].Value
    Check 'no-findings' $nf '### NO FINDINGS' $true
    Check 'no-findings' $nf '## No findings.' $true
    Check 'no-findings' $nf '### **NO FINDINGS**' $true
    Check 'no-findings' $nf '### NO FINDINGS in the parser, but the writer leaks' $false
    Check 'no-findings' $nf '### Missing JSON serialization metadata' $false
}
# And the pooler must decide on the WHOLE reply, not the first matching line, so a reply
# carrying both a NO FINDINGS heading and real findings is still pooled.
if ($source -notmatch '\$noFindingsHeadings\.Count -eq \$headings\.Count') {
    $failures += 'the pooler still treats any NO FINDINGS line as a clean reply instead of requiring it to be the only heading.'
}
if ($source -notmatch '(?s)if \(\$findingId -eq 0\).{0,600}Phase 2 skipped') {
    $failures += 'an empty pool still runs (and then fails) Phase 2 instead of reporting a clean result.'
}

# --- Round timeout -----------------------------------------------------------
if ($source -notmatch '\[int\]\s*\$RoundTimeoutSeconds\s*=\s*(?<default>\d+)') {
    $failures += 'RoundTimeoutSeconds parameter is missing: a wedged reviewer would stall its phase indefinitely.'
} elseif ([int]$Matches['default'] -lt 1800) {
    $failures += "RoundTimeoutSeconds default $($Matches['default']) is below the slowest observed reviewer (30m30s) plus margin."
}
if ($source -notmatch '-TimeoutSeconds\s+\$RoundTimeoutSeconds') {
    $failures += 'the parallel reviewer round does not pass -TimeoutSeconds, so the parameter would not bound anything.'
}
# -ErrorAction is NOT accepted in the Parallel parameter set. The script-level 'Stop' must be
# relaxed around the call instead, or the timeout's non-terminating error aborts the whole phase.
if ($source -match "ForEach-Object[^\r\n]*-Parallel[^\r\n]*-ErrorAction") {
    $failures += '-ErrorAction is passed to ForEach-Object -Parallel, which that parameter set rejects at runtime.'
}
if ($source -notmatch "\`$ErrorActionPreference = 'Continue'") {
    $failures += "the round does not relax \$ErrorActionPreference, so a timeout would abort the phase instead of degrading."
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    Write-Error "run-review start-pattern/timeout contract FAILED ($($failures.Count) issue(s))" -ErrorAction Continue
    exit 1
}

Write-Host 'run-review start-pattern and round-timeout contract OK - emphasis tolerated, narration still rejected, round bounded'
