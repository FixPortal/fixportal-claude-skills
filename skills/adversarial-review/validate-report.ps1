#requires -Version 7
<#
.SYNOPSIS
  Rejects the shape defects that have actually reached a persisted adversarial-review
  deliverable, the run folder's coverage-schema errors, and (for runs dated on/after
  2026-10-05) any Critical/High/contested finding block with no **Verification** line.

.DESCRIPTION
  `report.md` is assembled by the host agent, not by a script, so nothing checked its
  shape until a run shipped three Phase 4 lines reading

      **Verifier** - $(@{id=C001; title=...; verifier=claude:sonnet; ...}.verifier)

  an unevaluated PowerShell subexpression written verbatim into markdown, each one
  also embedding an absolute scratch path that no longer exists. It survived a full
  remediation pass unnoticed.

  The two rules below are deliberately narrow, and the narrowness is evidence-backed:
  a sweep of every report in the vault found ZERO legitimate occurrences of either
  pattern, while the wider candidates ("no `$(` anywhere", "no `@{` anywhere") match a
  dozen real MSBuild and PowerShell snippets quoted inside Fix suggestions
  (`$(TargetFramework)`, `$(DefineConstants)`, `@{ In=...; Out=... }`). A check that
  cries wolf on a dozen good reports is a check reviewers learn to skip.

  Deliverables only. `working/` holds raw transcripts and reviewer diffs, which
  legitimately contain both patterns and are not what anyone reads later.

.EXAMPLE
  pwsh -File validate-report.ps1 -Path '<vault>\Claude\Adversarial Review\<repo>\<RunId>'
#>
[CmdletBinding()]
param(
    # A run folder (recursed, `working/` excluded) or individual markdown files.
    [Parameter(Mandatory)]
    [string[]] $Path,

    # Required when a run folder contains the machine-readable coverage schema.
    [string] $RepoPath
)

$ErrorActionPreference = 'Stop'

$rules = @(
    @{
        Name    = 'leaked-interpolation'
        Pattern = '\$\(\s*@\{'
        Message = 'unevaluated PowerShell subexpression written verbatim into markdown'
    }
    @{
        Name    = 'dead-scratch-path'
        # Both separators: the same class of bug shipped twice this week from a
        # single-separator pattern that never matched on the other host. `\s*` at each
        # seam so a path word-wrapped across two lines cannot slip through - the file is
        # matched whole, not line by line, precisely so `\s` can span the newline.
        Pattern = 'AppData\s*[\\/]+\s*Local\s*[\\/]+\s*Temp'
        Message = 'absolute scratch path, dead the moment the run directory is pruned'
    }
)

$files = @(
    foreach ($p in $Path) {
        if (-not (Test-Path -LiteralPath $p)) { throw "no such path: $p" }
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -Recurse -File -Filter *.md |
                Where-Object { $_.FullName -notmatch '[\\/]working[\\/]' }
        } else {
            Get-Item -LiteralPath $p
        }
    }
)

# RECURSIVE, with the same working/ exclusion the deliverable scan uses. Deliverables
# recursed and this did not, so a vault-root sweep -- where every _index.md sits two
# levels down under <repo>/<run-folder>/ -- validated markdown shape while never checking
# a target SHA or a coverage declaration. The coverage contract was enforced only when a
# single run folder was passed directly at persist time.
$indexes = @(
    foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -Recurse -File -Filter '_index.md' |
                Where-Object { $_.FullName -notmatch '[\\/]working[\\/]' }
        } elseif ((Split-Path $p -Leaf) -eq '_index.md') {
            Get-Item -LiteralPath $p
        }
    }
)

# An empty file set is the fail-open shape this whole check exists to avoid: a clean
# exit over nothing reads identically to a clean exit over a validated report.
if (-not $files) { throw "no markdown deliverables found under: $($Path -join ', ')" }

# Matched against the whole file, not line by line. Markdown gets word-wrapped, and a
# per-line match cannot see a leak whose `$(` and `@{` land either side of a newline -
# it would report clean on the very defect it exists to catch. Both patterns tolerate
# whitespace at their seams, and `\s` spans a newline only when the text is matched whole.
$violations = @(foreach ($file in $files) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if (-not $text) { continue }
    foreach ($rule in $rules) {
        foreach ($match in [regex]::Matches($text, $rule.Pattern)) {
            $window = $text.Substring($match.Index, [Math]::Min(160, $text.Length - $match.Index))
            [pscustomobject]@{
                File    = $file.FullName
                # Derived from the match offset: a match may span lines, so there is no
                # single "matching line" to report - this is where it starts.
                Line    = ($text.Substring(0, $match.Index) -split "`n").Count
                Rule    = $rule.Name
                Message = $rule.Message
                Text    = ($window -replace '\s+', ' ').Trim()
            }
        }
    }
})

# Frontmatter is parsed ONCE, with review-digest's semantics, and every key is read from the
# result. This file used to carry two regex readers of its own, and all three defects they
# produced were the same defect: a second parser that disagrees with the consumer.
#
#  - `Get-List` required every continuation line to match `[ \t]+-`, so an interior `# comment`
#    inside a list TERMINATED it. an example run comments its
#    excluded-paths halfway down, and this file read 6 of its 23 entries. Measured, not inferred:
#    the truncation produced 2 false `uncovered path` violations (NOTICE and
#    tests/deploy-contract.test.mjs); that record's other 15 are a real coverage gap and are
#    still reported. The run's violation count fell 17 -> 15, so a count alone would NOT have
#    identified this - reading the two lists side by side is what did.
#  - `Get-Scalar` did not strip a trailing `# comment`, which collect.ps1 does, so
#    `disposition: reviewed # <note>` failed the disposition check on its own comment.
#  - Both matched a `key:` line ANYWHERE in the file rather than inside the leading block.
#
# The comment below this function used to describe that last divergence and was answered by
# checking the BLOCK's shape while still reading keys from the whole file - half the fix.
# Mirrors Read-Frontmatter in review-digest/collect.ps1; the contract test asserts the two agree.
function Read-Frontmatter([string] $Text) {
    $m = [regex]::Match($Text, '(?s)\A\s*---\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { $m = [regex]::Match($Text, '(?s)(?:\A|\r?\n)```yaml[ \t]*\r?\n(.*?)\r?\n```') }
    $fm = @{}
    if (-not $m.Success) { return $fm }
    $key = $null
    foreach ($line in $m.Groups[1].Value -split '\r?\n') {
        $line = $line -replace '\s+#.*$', ''
        if ($line -match '^([A-Za-z][\w-]*):\s*(.*)$') {
            $key = $Matches[1]; $value = $Matches[2].Trim()
            if ($value -match '^\[(.*)\]$') { $fm[$key] = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'", '`') } | Where-Object { $_ }) }
            elseif ($value) { $fm[$key] = $value.Trim('"', "'", '`') }
            else { $fm[$key] = @() }
        } elseif ($key -and $line -match '^\s*-\s*(.*)$') {
            $fm[$key] = @($fm[$key]) + @($Matches[1].Trim().Trim('"', "'", '`'))
        }
    }
    $fm
}

function Get-Scalar([hashtable] $Fm, [string] $Name) {
    $v = $Fm[$Name]
    if ($null -eq $v) { return $null }
    if ($v -is [array]) { if ($v.Count -eq 0) { return $null } else { $v = $v[0] } }
    $s = "$v".Trim()
    if ($s) { return $s } else { return $null }
}

function Get-List([hashtable] $Fm, [string] $Name) {
    @($Fm[$Name] | Where-Object { $_ })
}

$emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

# The target shapes review-digest's collector can actually use, mirroring Get-Run in
# review-digest/collect.ps1. Returns @{Base;Tip} or $null.
#
# This used to demand a literal `<40 hex>..<40 hex>` and nothing else, which rejected three
# shapes the collector reads happily and one that review-sweep MANDATES:
#
#   audit:<sha> / audit -- <paths> (range a..b)  - the empty-tree snapshot review-sweep
#                                                  requires of every never-reviewed repo
#   <base>..HEAD  with  head: <sha>              - stated as allowed by collect.ps1's own header
#   <sha>..<sha>  with  scope-note: Full-state   - the collector's identical-tip audit path
#   7-to-39-character SHAs                       - the collector accepts 7+
#
# A gate stricter than its consumer does not enforce quality, it reports usable records as
# broken: an example run is one of the estate's 71 USABLE runs and
# failed here for eight months. Durability is still enforced - the resolved SHAs must exist in
# the repository, which is also what catches an abbreviation too short to stay unambiguous.
function Resolve-Target([hashtable] $Fm) {
    $target = Get-Scalar $Fm 'target'
    if (-not $target) { $target = Get-Scalar $Fm 'range' }
    if (-not $target) { return $null }

    $auditTip = $null
    $identical = [regex]::Match($target, '^([0-9a-f]{7,40})\.\.\1\b')
    if ($target -match '^audit\b') {
        $shas = @([regex]::Matches($target, '(?<![0-9a-f])[0-9a-f]{7,40}(?![0-9a-f])') | ForEach-Object { $_.Value })
        $auditRange = [regex]::Match($target, '(?<![0-9a-f])[0-9a-f]{7,40}\.\.([0-9a-f]{7,40})(?![0-9a-f])')
        $head = Get-Scalar $Fm 'head'
        if ("$head" -match '^[0-9a-f]{7,40}$') { $auditTip = $head }
        elseif ($auditRange.Success) { $auditTip = $auditRange.Groups[1].Value }
        elseif ($shas.Count -eq 1) { $auditTip = $shas[0] }
        else { return $null }   # no shas, or several with no range: ambiguous, same as the collector
    } elseif ($identical.Success -and (Get-Scalar $Fm 'scope-note') -match '^Full-state audit') {
        $auditTip = $identical.Groups[1].Value
    }
    if ($auditTip) { return @{ Base = $emptyTree; Tip = $auditTip } }

    $m = [regex]::Match($target, '^([0-9a-f]{7,40})\.\.([0-9a-f]{7,40}|HEAD)\b')
    if (-not $m.Success) { return $null }
    $tip = if ($m.Groups[2].Value -eq 'HEAD') { Get-Scalar $Fm 'head' } else { $m.Groups[2].Value }
    if ("$tip" -notmatch '^[0-9a-f]{7,40}$') { return $null }   # `..HEAD` with no head: key
    @{ Base = $m.Groups[1].Value; Tip = "$tip" }
}

foreach ($index in $indexes) {
    $indexText = Get-Content -LiteralPath $index.FullName -Raw
    # The consumer reads metadata only from a leading `---` block, so a record keeping its keys
    # in prose validated clean here while being dropped as `no-date` and counted in no coverage
    # figure anywhere. It hid an application’s largest review for a day, and eight further records
    # for months. Assert the shape the consumer requires, before reading any key.
    $frontmatterMatch = [regex]::Match($indexText, '(?s)\A\s*---\r?\n(.*?)\r?\n---')
    if (-not $frontmatterMatch.Success) {
        $violations += [pscustomobject]@{
            File = $index.FullName; Line = 1; Rule = 'frontmatter-shape'
            Message = 'no leading --- frontmatter block; review-digest drops this run as no-date'; Text = ''
        }
        continue
    }
    # Every key below comes from THIS hashtable. Reading any of them off $indexText again would
    # reintroduce the whole-file match, and with it the divergence this file has now had twice.
    $fm = Read-Frontmatter $indexText
    $scopeKind = Get-Scalar $fm 'scope-kind'
    if (-not $scopeKind) { continue } # legacy report; new runs opt into the coverage schema
    # Shape is not completeness. A record can carry a well-formed block and still be dropped,
    # because the block omits a key the collector requires and the key sits in the body instead -
    # a markdown bullet `- **date:** ...` reads fine to a person and matches nothing. Found by
    # running the collector after the shape guard landed: an example run
    # was a REMEDIATED repository review with a valid target, still invisible.
    if (-not (Get-Scalar $fm 'date')) {
        $violations += [pscustomobject]@{
            File = $index.FullName; Line = 1; Rule = 'coverage-schema'
            Message = 'no date: inside the frontmatter block; review-digest drops this run as no-date'; Text = ''
        }
    }
    $reviewDate = [datetime]::MinValue
    $dateText = Get-Scalar $fm 'date'
    if ($dateText -and -not [datetime]::TryParseExact($dateText, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$reviewDate)) {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'date must use yyyy-MM-dd'; Text = $dateText }
    } elseif ($dateText -and $reviewDate.Date -gt (Get-Date).Date) {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'date must not be in the future'; Text = $dateText }
    }
    if ($scopeKind -notin 'repository', 'subsystem', 'document') {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "invalid scope-kind '$scopeKind'"; Text = '' }
        continue
    }
    # A run that convened no panel is legitimate (SKILL.md §0 lets the operator skip a
    # dependency-only target) but it must SAY so, both ways round. Checked in both
    # directions deliberately: one direction alone is trivially satisfied by omission.
    # Without this a skipped run is byte-identical to a completed review, which is the
    # same defect as publishing zeros for a panel that never ran - relocated into the
    # frontmatter. No check can prove a human was asked; this only guarantees that a run
    # claiming no reviewers carries its reason, so every skip is discoverable later.
    #
    # Deliberately ABOVE the -RepoPath guard: this reads frontmatter only and needs no
    # checkout, and the guard below `continue`s for a whole-vault sweep. Leaving it
    # underneath would have made the one sweep that scans every report the one place the
    # rule never fired.
    $reviewers = Get-Scalar $fm 'reviewers'
    $judge = Get-Scalar $fm 'judge'
    $skipReason = Get-Scalar $fm 'skip-reason'
    $declaresNoPanel = ($reviewers -match '^(?i)none\b') -or ($judge -match '^(?i)none\b')
    if ($declaresNoPanel -and -not $skipReason) {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'a run declaring no reviewers/judge requires a non-empty skip-reason'; Text = "reviewers: $reviewers" }
    }
    if ($skipReason -and -not $declaresNoPanel) {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'skip-reason is set but reviewers/judge do not declare none'; Text = "reviewers: $reviewers" }
    }

    if ($scopeKind -eq 'document') { continue }
    if (-not $RepoPath -or -not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
        # SKIP with a notice, not a violation. A multi-repo vault sweep cannot supply one
        # -RepoPath that fits every index it finds, and recording each as a violation
        # would turn the recursion above into a wall of red for reports that are fine.
        # A single run folder passed at persist time always carries -RepoPath, which is
        # where the coverage gate actually binds.
        Write-Warning "SKIPPED coverage validation for $($index.FullName): no -RepoPath supplied, so target SHAs cannot be checked."
        continue
    }
    $target = Get-Scalar $fm 'target'
    $resolved = Resolve-Target $fm
    # `coverage-waiver:` tells review-digest to stop reporting this record as unreadable. It is a
    # statement that the coverage CANNOT be reconstructed, so a record that carries one alongside a
    # target this validator can already resolve is not waiving anything - it is hiding a readable
    # record, which is the one way this key could make the estate less honest than no key at all.
    # Checked here rather than at the top so it reads the SAME resolved target the gate below does.
    $waiver = Get-Scalar $fm 'coverage-waiver'
    if ($waiver) {
        # "Already resolves" must mean what the COLLECTOR means, not merely that both shas parse.
        # collect.ps1 additionally requires the tip on HEAD's ancestry, so a record whose tip was
        # rewritten by a rebase and has no patch-id twin left is genuinely unreconstructable while
        # still carrying a well-formed 40..40 target. Checking only the shape here would reject the
        # waiver on exactly the records that most need one - and the rejection would be invisible,
        # since nothing downstream re-reads it.
        $resolves = $false
        if ($resolved) {
            & git -C $RepoPath merge-base --is-ancestor $resolved.Tip HEAD 2>$null
            $resolves = $LASTEXITCODE -eq 0
        }
        if ($resolves) {
            $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'coverage-waiver on a record whose target already resolves; remove the waiver or the target'; Text = "$target" }
        }
        # A waiver with no reason is indistinguishable from an empty key someone left behind, and
        # the reason is the only thing a later reader gets in place of the coverage.
        elseif ("$waiver".Trim().Length -lt 10) {
            $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'coverage-waiver must state why the coverage cannot be reconstructed'; Text = "$waiver" }
        }
        continue
    }
    if (-not $resolved) {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'target is not a shape review-digest can resolve to <base>..<tip>'; Text = "$target" }
        continue
    }
    $baseSha = $resolved.Base
    $tipSha = $resolved.Tip
    # An `audit` target diffs the canonical EMPTY TREE against HEAD, and review-sweep
    # mandates that shape for every never-reviewed repo. The empty tree is a tree, not
    # a commit, so `cat-file -e <sha>^{commit}` rejects it -- which left the one target
    # shape the sweep requires with no machine form that validates. It is a fixed,
    # universal git constant, so accept it as a base and check only the tip.
    $shasToCheck = if ($baseSha -eq $emptyTree) { @($tipSha) } else { @($baseSha, $tipSha) }
    foreach ($sha in $shasToCheck) {
        & git -C $RepoPath cat-file -e "$sha^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "target commit does not exist in RepoPath: $sha"; Text = '' }
        }
    }
    $disposition = Get-Scalar $fm 'disposition'
    if ($disposition -notin 'open', 'reviewed', 'remediated') {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'disposition must be open, reviewed, or remediated'; Text = "$disposition" }
    }
    if ($disposition -eq 'remediated') {
        $remediationTip = Get-Scalar $fm 'remediation-tip'
        if ($remediationTip -notmatch '^[0-9a-f]{40}$') {
            $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'remediated review requires an exact remediation-tip SHA'; Text = "$remediationTip" }
        } else {
            & git -C $RepoPath cat-file -e "$remediationTip^{commit}" 2>$null
            if ($LASTEXITCODE -ne 0) {
                $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "remediation-tip does not exist in RepoPath: $remediationTip"; Text = '' }
            }
        }
    }
    foreach ($sha in @(Get-List $fm 'remediation-commits')) {
        if ($sha -notmatch '^[0-9a-f]{40}$') {
            $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "remediation-commits requires exact 40-character SHAs: $sha"; Text = [string]$sha }
        } else {
            & git -C $RepoPath cat-file -e "$sha^{commit}" 2>$null
            if ($LASTEXITCODE -ne 0) {
                $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "remediation commit does not exist in RepoPath: $sha"; Text = '' }
            } else {
                & git -C $RepoPath merge-base --is-ancestor $sha HEAD 2>$null
                if ($LASTEXITCODE -ne 0) { $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "remediation commit is not on RepoPath HEAD history: $sha"; Text = '' } }
            }
        }
    }
    $reviewedPaths = @(Get-List $fm 'reviewed-paths')
    $excludedPaths = @(Get-List $fm 'excluded-paths')
    foreach ($path in $reviewedPaths) {
        $matchesAtTip = @(& git -C $RepoPath diff --name-only $emptyTree $tipSha -- $path)
        if (-not $matchesAtTip.Count) {
            $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "reviewed-paths entry matches no tracked files at reviewed tip: $path"; Text = [string]$path }
        }
    }
    foreach ($path in @($reviewedPaths) + @($excludedPaths)) {
        $pathText = [string]$path
        $magic = [regex]::Match($pathText, '^:\((?<tokens>[^)]*)\)')
        $hasExcludeMagic = $magic.Success -and @($magic.Groups['tokens'].Value.Split(',')) -contains 'exclude'
        if ($pathText -match '^:(?:!|\^)' -or $hasExcludeMagic) {
            $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "pathspec exclusions are not allowed in coverage lists: $path"; Text = [string]$path }
        }
    }
    if ($scopeKind -eq 'subsystem' -and -not $reviewedPaths.Count) {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'subsystem review requires reviewed-paths'; Text = '' }
    }
    if ($scopeKind -eq 'repository' -and $reviewedPaths.Count) {
        $changed = @(& git -C $RepoPath diff --name-only "$baseSha..$tipSha")
        # Ordinal, not OrdinalIgnoreCase, and not the filesystem's rule either: both
        # sides of this comparison come from `git diff --name-only`, and git's index is
        # byte-exact about case on every platform. Folding case let `src/A.cs` mark
        # `src/a.cs` accounted for on a case-sensitive repo, so a genuinely unreviewed
        # file passed coverage on the strength of its sibling's name.
        $accounted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($pathspec in @($reviewedPaths) + @($excludedPaths)) {
            foreach ($file in @(& git -C $RepoPath diff --name-only "$baseSha..$tipSha" -- $pathspec)) {
                [void]$accounted.Add("$file")
            }
        }
        foreach ($file in $changed) {
            if (-not $accounted.Contains("$file")) {
                $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "uncovered path in repository review: $file"; Text = '' }
            }
        }
    }
}

# Every Phase-4-scoped finding block -- every Critical, every High, every [contested] one --
# must carry a **Verification** line, or a REFUTED/INDETERMINATE verdict has no home and the
# tally keeps counting a finding nobody checked. Anchored on the house-style severity line
# (`**High** · [...]`) so tally tables and prose mentions of a severity cannot trip it.
#
# Grandfathered by run date: measured 2026-10-05, 1901 of the vault's 1920 in-scope blocks
# predate the rule (the judge brief never asked for the line), and failing them would block
# every remediation write-back that re-validates a legacy folder. A deliverable is checked
# only when the nearest _index.md above it is dated on/after the cutover; SKILL.md 5 makes
# that index mandatory for every new run, and legacy folders without one (15 files measured)
# stay exempt. Refuted if: a vault sweep reports missing-verification on a pre-cutover run.
$verificationCutover = [datetime]'2026-10-05'
function Test-VerificationApplies([string] $FilePath) {
    $dir = Split-Path -Parent $FilePath
    while ($dir) {
        $idx = Join-Path $dir '_index.md'
        if (Test-Path -LiteralPath $idx -PathType Leaf) {
            $d = [datetime]::MinValue
            $dateText = Get-Scalar (Read-Frontmatter (Get-Content -LiteralPath $idx -Raw)) 'date'
            return ($dateText -and [datetime]::TryParseExact($dateText, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$d) -and $d -ge $verificationCutover)
        }
        $dir = Split-Path -Parent $dir
    }
    $false
}
foreach ($file in $files) {
    if (-not (Test-VerificationApplies $file.FullName)) { continue }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if (-not $text) { continue }
    foreach ($block in [regex]::Matches($text, '(?ms)^### .+?(?=^### |\z)')) {
        $required = $block.Value -match '(?m)^\*\*(Critical|High)\*\*\s*·' -or $block.Value -match '\[contested\]'
        if ($required -and $block.Value -notmatch '\*\*Verification\*\*') {
            $violations += [pscustomobject]@{
                File = $file.FullName; Line = ($text.Substring(0, $block.Index) -split "`n").Count
                Rule = 'missing-verification'
                Message = 'Critical/High/contested finding block has no **Verification** line (Phase-4 verdict)'
                Text = (($block.Value -split "`n")[0]).Trim()
            }
        }
    }
}

if ($violations) {
    foreach ($v in $violations) {
        $snippet = if ($v.Text.Length -gt 140) { $v.Text.Substring(0, 140) + '...' } else { $v.Text }
        Write-Host "$($v.File):$($v.Line): $($v.Rule) - $($v.Message)"
        Write-Host "  $snippet"
    }
    Write-Host ''
    Write-Host "$(@($violations).Count) report-shape violation(s) across $($files.Count) deliverable(s)."
    exit 1
}

"report shape OK - $($files.Count) deliverable(s) checked"
