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
            elseif ($value) {
                # Kept identical to review-digest/collect.ps1's reader, which needs the marker for `subsystem:`.
                if ($value -match '^(["''`]).*\1$') { $fm["quoted:$key"] = $true }
                $fm[$key] = $value.Trim('"', "'", '`')
            }
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

# Mirrors Resolve-OnHead in review-digest/collect.ps1: a sha on HEAD's ancestry, or one whose tree
# a HEAD commit carries exactly (a rebase-merged review tip).
function Test-OnHead([string] $Sha) {
    $commit = @(& git -C $RepoPath rev-parse --verify --quiet "$Sha^{commit}" 2>$null)[0]
    if (-not $commit) { return $false }
    & git -C $RepoPath merge-base --is-ancestor $commit HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }
    $tree = @(& git -C $RepoPath rev-parse "$commit^{tree}" 2>$null)[0]
    @(& git -C $RepoPath log --format=%T HEAD 2>$null | Where-Object { $_ -eq $tree }).Count -gt 0
}

# Mirrors Find-PatchTwin in collect.ps1: a commit on HEAD since the fork point whose
# `patch-id --stable` equals the off-HEAD commit's own (its rebased copy).
function Test-PatchTwin([string] $Sha) {
    $forked = @(& git -C $RepoPath merge-base $Sha HEAD 2>$null)[0]
    if (-not $forked) { return $false }
    $id = @(& git -C $RepoPath -c core.quotepath=false show --no-color $Sha 2>$null | & git -C $RepoPath patch-id --stable 2>$null)[0]
    if (-not $id) { return $false }
    $id = ($id -split ' ')[0]
    @(& git -C $RepoPath -c core.quotepath=false log -p --no-color --no-merges "$forked..HEAD" 2>$null | & git -C $RepoPath patch-id --stable 2>$null | Where-Object { $_ -like "$id *" }).Count -gt 0
}

# Mirrors Test-RangeTwins in collect.ps1: every reviewed commit off HEAD has a patch-id copy on
# HEAD since the fork, so a `reviewed` record's whole branch reached mainline by rebase.
function Test-RangeTwins([string] $Base, [string] $Tip) {
    # @() outside the if: a one-element array returned from `if` unrolls to a string, which @exclude would splat per character.
    $exclude = @(if ($Base -ne $emptyTree) { "^$Base" })
    $offHead = @(& git -C $RepoPath rev-list --no-merges $Tip @exclude '^HEAD' 2>$null | Where-Object { $_ })
    if (-not $offHead.Count) { return $false }
    $forked = @(& git -C $RepoPath merge-base $Tip HEAD 2>$null)[0]
    if (-not $forked) { return $false }
    $onHead = [Collections.Generic.HashSet[string]]::new([string[]]@(& git -C $RepoPath -c core.quotepath=false log -p --no-color --no-merges "$forked..HEAD" 2>$null | & git -C $RepoPath patch-id --stable 2>$null | ForEach-Object { ($_ -split ' ')[0] }))
    foreach ($commit in $offHead) {
        $id = @(& git -C $RepoPath -c core.quotepath=false show --no-color $commit 2>$null | & git -C $RepoPath patch-id --stable 2>$null)[0]
        if (-not $id -or -not $onHead.Contains(($id -split ' ')[0])) { return $false }
    }
    $true
}

# Mirrors collect.ps1's history-reset rescue: HEAD's root is an `Initial OSS release|commit` made
# on or after the review date, so the reviewed tip lives on in the replaced history.
function Test-HistoryReset([datetime] $ReviewDate) {
    foreach ($rootSha in @(& git -C $RepoPath rev-list --max-parents=0 HEAD 2>$null)) {
        $root = @(& git -C $RepoPath show -s '--format=%ad%x09%s' --date=short $rootSha 2>$null)[0]
        if ($root -match '^(\d{4}-\d{2}-\d{2})\tInitial OSS (?:release|commit)$' -and $Matches[1] -ge $ReviewDate.ToString('yyyy-MM-dd')) { return $true }
    }
    $false
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
    # The closure step records the merged fix commits, so review-digest can subtract them from
    # drift even across a later history reset (owner decision, PR #425 X1). Runs dated before the
    # rule are grandfathered, as the verdict rules below are. Frontmatter-only, so it runs before
    # both the legacy-schema exit and the -RepoPath guard: a vault sweep enforces it too, and a
    # post-cutover record cannot skip it by omitting scope-kind (CodeRabbit, PR #426).
    # A missing or malformed date falls back to the run folder's id, and with neither the record is
    # held to the rule: it cannot prove it predates the cutover (CodeRabbit, PR #426).
    $closureDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact("$(Get-Scalar $fm 'date')", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$closureDate) -and
        -not ((Split-Path -Leaf (Split-Path -Parent $index.FullName)) -match '^(\d{8})T\d{6}Z' -and
            [datetime]::TryParseExact($Matches[1], 'yyyyMMdd', [cultureinfo]::InvariantCulture, 'None', [ref]$closureDate))) {
        $closureDate = [datetime]::MaxValue
    }
    $remediationCommits = @(Get-List $fm 'remediation-commits')
    if ((Get-Scalar $fm 'disposition') -eq 'remediated' -and $closureDate -ge [datetime]'2026-11-02' -and -not $remediationCommits.Count) {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'remediated review dated on/after 2026-11-02 requires remediation-commits (the merged fix SHAs)'; Text = '' }
    }
    # Format needs no checkout, so a post-cutover record is checked here: exiting below (no scope-kind,
    # scope-kind: document, no -RepoPath) must not pass it with an unusable list (CodeRabbit, PR #426).
    # Earlier legacy records keep their prose lists (for example a 2026-06-24 run); the scoped check below still reads them.
    $commitsCheckedEarly = $closureDate -ge [datetime]'2026-11-02'
    foreach ($sha in @($remediationCommits | Where-Object { $commitsCheckedEarly })) {
        if ($sha -notmatch '^[0-9a-f]{40}$') { $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "remediation-commits requires exact 40-character SHAs: $sha"; Text = [string]$sha } }
    }
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
    # "Today" is the UTC calendar day, because `date:` follows the UTC RunId: a host behind UTC
    # rejected a record dated by its own run id. review-digest/collect.ps1 applies the same rule
    # (`$date.Date -gt [datetime]::UtcNow.Date`); change both together.
    $today = [datetime]::UtcNow.Date
    if ($dateText -and -not [datetime]::TryParseExact($dateText, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$reviewDate)) {
        $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = 'date must use yyyy-MM-dd'; Text = $dateText }
    } elseif ($dateText -and $reviewDate.Date -gt $today) {
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
        #
        # Decided only once the whole boundary is known, as collect.ps1's Get-Run reaches it: the
        # tip on HEAD (directly, or through a HEAD commit with the identical tree), or rescued by a
        # remediated record whose remediation-tip is on HEAD AND whose reviewed tip has a patch-id
        # copy on HEAD (the collector's boundary), or by a reviewed record whose every off-HEAD
        # reviewed commit has such a copy, or by a later history reset; AND the base
        # resolving. A record that fails any of those is unusable, so its waiver is legitimate.
        $resolves = $false
        if ($resolved) {
            & git -C $RepoPath cat-file -e "$($resolved.Tip)^{commit}" 2>$null
            $tipUsable = $LASTEXITCODE -eq 0 -and ((Test-OnHead $resolved.Tip) -or
                ((Get-Scalar $fm 'disposition') -eq 'remediated' -and "$(Get-Scalar $fm 'remediation-tip')" -match '^[0-9a-f]{7,40}$' -and (Test-OnHead (Get-Scalar $fm 'remediation-tip')) -and (Test-PatchTwin $resolved.Tip)) -or
                ((Get-Scalar $fm 'disposition') -eq 'reviewed' -and (Test-RangeTwins $resolved.Base $resolved.Tip) -and (Test-PatchTwin $resolved.Tip)) -or
                (Test-HistoryReset $reviewDate))
            $baseUsable = $resolved.Base -eq $emptyTree
            if (-not $baseUsable) { & git -C $RepoPath cat-file -e "$($resolved.Base)^{commit}" 2>$null; $baseUsable = $LASTEXITCODE -eq 0 }
            $resolves = $tipUsable -and $baseUsable
            # ...and, for a subsystem record, a declared path list whose every entry matches.
            if ($resolves -and $scopeKind -eq 'subsystem') {
                $declared = @(Get-List $fm 'reviewed-paths')
                $unmatched = @($declared | Where-Object {
                    -not @(& git -C $RepoPath diff --name-only $emptyTree $resolved.Tip -- $_ 2>$null).Count -and
                    -not @(& git -C $RepoPath diff --name-only $resolved.Base $resolved.Tip -- $_ 2>$null).Count })
                $resolves = $declared.Count -gt 0 -and -not $unmatched.Count
            }
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
    $tipExists = $true
    foreach ($sha in $shasToCheck) {
        & git -C $RepoPath cat-file -e "$sha^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            if ($sha -eq $tipSha) { $tipExists = $false }
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
            if (-not $commitsCheckedEarly) { $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "remediation-commits requires exact 40-character SHAs: $sha"; Text = [string]$sha } }
        } else {
            & git -C $RepoPath cat-file -e "$sha^{commit}" 2>$null
            if ($LASTEXITCODE -ne 0) {
                $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "remediation commit does not exist in RepoPath: $sha"; Text = '' }
            } else {
                & git -C $RepoPath merge-base --is-ancestor $sha HEAD 2>$null
                if ($LASTEXITCODE -ne 0) { $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "remediation commit is not on RepoPath HEAD history: $sha"; Text = '' } }
                # The reviewed tip, or anything before it, is the state that was reviewed, not a fix to it (CodeRabbit, PR #426).
                if ($tipExists) {
                    & git -C $RepoPath merge-base --is-ancestor $sha $tipSha 2>$null
                    if ($LASTEXITCODE -eq 0) { $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "remediation commit is not after the reviewed tip: $sha"; Text = '' } }
                }
            }
        }
    }
    $reviewedPaths = @(Get-List $fm 'reviewed-paths')
    $excludedPaths = @(Get-List $fm 'excluded-paths')
    # A missing tip is reported above; probing paths against it would only add a false
    # "matches no tracked files" per entry.
    foreach ($path in @(if ($tipExists) { $reviewedPaths })) {
        $matchesAtTip = @(& git -C $RepoPath diff --name-only $emptyTree $tipSha -- $path 2>$null)
        if ($LASTEXITCODE -ne 0) {
            $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "reviewed-paths entry could not be probed (git diff exited $LASTEXITCODE): $path"; Text = [string]$path }
        }
        elseif (-not $matchesAtTip.Count) {
            # An entry whose files were all deleted in the reviewed range still names reviewed
            # changes: a repository-scope chunk pathspec, or a subsystem path list built from the
            # range's changed files (review-sweep's drift recipe). A tip-only check left such a
            # record unable to pass or to drop the entry. collect.ps1 applies the same rule.
            $matchesInRange = @(& git -C $RepoPath diff --name-only $baseSha $tipSha -- $path 2>$null)
            if (-not $matchesInRange.Count) {
                $violations += [pscustomobject]@{ File = $index.FullName; Line = 1; Rule = 'coverage-schema'; Message = "reviewed-paths entry matches no tracked files at reviewed tip: $path"; Text = [string]$path }
            }
        }
    }
    foreach ($path in @($reviewedPaths) + @($excludedPaths)) {
        $pathText = [string]$path
        # Short-form magic is any run of `/`, `!`, `^` after the colon, so `:/!foo` excludes too;
        # long form names `exclude` as one of its comma-separated words (not inside `attr:...`).
        # One rule, shared verbatim with audit-ai-quality/detect.ps1 and review-digest/collect.ps1.
        if ($pathText -match '^:(?:[/!^]*[!^]|\((?:[^)]*,)?exclude(?:,[^)]*)?\))') {
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
# The verdict rules (a Verification paragraph must hold a verdict, never PENDING; a [contested]
# bullet or row needs its own verdict) landed 2026-11-02 and are grandfathered the same way:
# measured that day, they turned 115 checks red across 16 run folders written before them, which
# would block every remediation write-back to those folders (owner decision, PR #425 XM6/XM7).
# Refuted if: a vault sweep reports contested-without-block or verification-without-verdict on a
# run dated before this cutover.
$verdictRulesCutover = [datetime]'2026-11-02'
# The run date that governs a deliverable: $null for a legacy folder with no index (exempt),
# MaxValue for an index with no parseable date (broken, so every rule applies).
function Get-GoverningRunDate([string] $FilePath) {
    $dir = Split-Path -Parent $FilePath
    while ($dir) {
        $idx = Join-Path $dir '_index.md'
        if (Test-Path -LiteralPath $idx -PathType Leaf) {
            # Only an index that DATES itself before a cutover is exempt. A missing or malformed
            # date is a broken index, and a broken index must not switch the rules off.
            $d = [datetime]::MinValue
            $dateText = Get-Scalar (Read-Frontmatter (Get-Content -LiteralPath $idx -Raw)) 'date'
            if ($dateText -and [datetime]::TryParseExact($dateText, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$d)) { return $d }
            return [datetime]::MaxValue
        }
        # The run folder (<RunId>, SKILL.md 5) is the top of the search: an _index.md above it
        # belongs to no run. shortcut: a legacy run folder not named by RunId still climbs; none
        # of the vault's parent folders carries an _index.md today.
        if ((Split-Path -Leaf $dir) -match '^\d{8}T\d{6}Z$') { break }
        $dir = Split-Path -Parent $dir
    }
    $null
}

# Fence-aware, so a `### ` or `[contested]` quoted inside a code sample is not report structure.
# CommonMark's rule: an opener is 3+ backticks (info string without a backtick) or tildes, indented
# at most 3 spaces; only the same character at least as long, alone on its line, closes it. A fence
# left open at end of file is a typo, so everything after its opener is read as prose again.
function Get-OutsideFence([string[]] $Lines) {
    $outside = [bool[]]::new($Lines.Count)
    $fence = $null; $openedAt = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($fence) {
            if ($Lines[$i] -match ('^ {0,3}' + $fence[0] + '{' + $fence.Length + ',}\s*$')) { $fence = $null }
            continue
        }
        if ($Lines[$i] -match '^ {0,3}(?<f>`{3,})[^`]*$' -or $Lines[$i] -match '^ {0,3}(?<f>~{3,})') {
            $fence = $Matches['f']; $openedAt = $i
            continue
        }
        $outside[$i] = $true
    }
    if ($fence) { for ($i = $openedAt; $i -lt $Lines.Count; $i++) { $outside[$i] = $true } }
    , $outside
}

# A Phase-4 verdict, or the documented skip (`Not Phase-4 verified: <reason>`, phase3-adjudicate.txt).
# Case-sensitive: the brief's verdict words are upper-case, and prose "confirmed" is not a verdict.
function Test-HasVerdict([string] $Text) {
    ($Text -cmatch '\b(CONFIRMED|REFUTED|INDETERMINATE)\b' -or $Text -match 'Not Phase-4 verified:') -and $Text -cnotmatch '\bPENDING\b'
}

foreach ($file in $files) {
    $runDate = Get-GoverningRunDate $file.FullName
    if ($null -eq $runDate -or $runDate -lt $verificationCutover) { continue }
    $verdictRulesApply = $runDate -ge $verdictRulesCutover
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if (-not $text) { continue }
    $lines = $text -split '\r?\n'
    $outside = Get-OutsideFence $lines

    # A finding block is a `### ` heading up to the next level 1-3 heading, so a trailing `## Low`
    # list or `## Refuted` table is never read as part of the last finding.
    $starts = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($outside[$i] -and $lines[$i] -match '^#{1,3} ') { $i } })
    for ($n = 0; $n -lt $starts.Count; $n++) {
        $start = $starts[$n]
        if ($lines[$start] -notmatch '^### ') { continue }
        $end = if ($n + 1 -lt $starts.Count) { $starts[$n + 1] } else { $lines.Count }
        $body = @(for ($i = $start + 1; $i -lt $end; $i++) { if ($outside[$i]) { $i } })
        # The tag counts only on the block's own severity line (`**<Severity>** · [...]`), never
        # where a Consensus line quotes another finding's tag.
        $severityLine = @($body | ForEach-Object { $lines[$_] } | Where-Object { $_ -match '^\*\*[^*]+\*\*\s*(?:\([^)]*\)\s*)?·' })[0]
        $required = "$severityLine" -match '^\*\*(Critical|High)\*\*\s*(?:\([^)]*\)\s*)?·' -or "$severityLine" -match '\[contested\]'
        if (-not $required) { continue }
        # The label may open its own paragraph or follow the Consensus text on the same line.
        $verificationAt = @($body | Where-Object { $lines[$_] -match '\*\*Verification\*\*' })[0]
        if ($null -eq $verificationAt) {
            $violations += [pscustomobject]@{
                File = $file.FullName; Line = $start + 1; Rule = 'missing-verification'
                Message = 'Critical/High/contested finding block has no **Verification** line (Phase-4 verdict)'
                Text = $lines[$start].Trim()
            }
            continue
        }
        if (-not $verdictRulesApply) { continue }
        $paragraph = @(for ($i = $verificationAt; $i -lt $end -and $lines[$i].Trim(); $i++) { $lines[$i] }) -join ' '
        $paragraph = $paragraph.Substring($paragraph.IndexOf('**Verification**'))
        if (-not (Test-HasVerdict $paragraph)) {
            $violations += [pscustomobject]@{
                File = $file.FullName; Line = $verificationAt + 1; Rule = 'verification-without-verdict'
                Message = '**Verification** line holds no CONFIRMED/REFUTED/INDETERMINATE verdict (or still reads PENDING); record the Phase-4 outcome'
                Text = $lines[$start].Trim()
            }
        }
    }

    # A [contested] finding written as a bullet or table row has no block of its own, so it would
    # otherwise borrow whatever Verification line sits above it. It must carry its own verdict.
    if (-not $verdictRulesApply) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $outside[$i]) { continue }
        $item = [regex]::Match($lines[$i], '^(?<indent>\s*)(?:[-*+]|\d+[.)])\s')
        if ($item.Success) {
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j].Trim() -and $lines[$j] -notmatch '^#' -and
                -not ($lines[$j] -match '^(?<indent>\s*)(?:[-*+]|\d+[.)])\s' -and $Matches['indent'].Length -le $item.Groups['indent'].Length)) { $j++ }
        } elseif ($lines[$i] -match '^\s*\|') { $j = $i + 1 }
        else { continue }
        $itemText = @($lines[$i..($j - 1)]) -join ' '
        # The tag counts in a finding's tag position (after `·`, a bold label, or a table cell
        # edge), outside code spans: `- AR-8 [contested]: ...` in a themes list is a
        # cross-reference to a block, and a backticked tag is quoted text.
        $tagged = ($itemText -replace '`[^`]*`', '') -match '(?:·|\*\*|\|)\s*\[contested\]'
        if ($tagged -and -not (Test-HasVerdict $itemText)) {
            $violations += [pscustomobject]@{
                File = $file.FullName; Line = $i + 1; Rule = 'contested-without-block'
                Message = 'a [contested] finding outside its own ### block carries no Phase-4 verdict; give it a full block with a **Verification** line'
                Text = $lines[$i].Trim()
            }
        }
        $i = $j - 1
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
