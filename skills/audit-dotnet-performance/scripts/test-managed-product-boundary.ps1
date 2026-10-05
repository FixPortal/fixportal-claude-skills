#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepositoryPath,

    [Parameter(Mandatory)]
    [string] $BaseRef,

    [string[]] $ProductPath = @('.')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Exit 0 means the audit completed (including boundary violations); exit 2 means it could not run.
function Invoke-GitReadOnly {
    param([string] $Repository, [string[]] $GitArguments)

    # core.quotePath=false is pinned for EVERY read, alongside the diff-format pinning
    # further down and for the same reason. With git's default, any path containing a
    # non-ASCII byte comes back C-quoted - `"src/caf\303\251.cs"` - and that string
    # matches no `+++ b/(.+)` capture the caller can open, no extension test, and no entry
    # in the name-status cross-check. A file the guard cannot name is a file it does not
    # scan, and the run still reports passed = true.
    $output = @(& git -C $Repository -c core.quotePath=false @GitArguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArguments -join ' ') failed: $($output -join ' ')"
    }

    return @($output | ForEach-Object ToString)
}

function Get-ProductPathspec {
    param([string] $Repository, [string[]] $Paths)

    $root = [IO.Path]::GetFullPath($Repository)
    $separator = [IO.Path]::DirectorySeparatorChar
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $pathspec = foreach ($path in $Paths) {
        $fullPath = if ([IO.Path]::IsPathRooted($path)) { [IO.Path]::GetFullPath($path) } else { [IO.Path]::GetFullPath((Join-Path $root $path)) }
        if (-not $fullPath.Equals($root, $comparison) -and -not $fullPath.StartsWith("$root$separator", $comparison)) {
            throw "ProductPath '$path' is outside RepositoryPath."
        }
        $relative = [IO.Path]::GetRelativePath($root, $fullPath)
        if ($relative -eq '.') { '.' } else { $relative.Replace($separator, '/') }
    }
    return @($pathspec)
}

function Get-FSharpCode {
    param([string] $Line, [ref] $State)

    $code = [Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Line.Length;) {
        if ($State.Value -eq 'block') {
            if ($index + 1 -lt $Line.Length -and $Line.Substring($index, 2) -eq '*)') { $State.Value = 'code'; $index += 2 } else { $index++ }
            continue
        }
        if ($State.Value -eq 'string') {
            # [char] comparison. '\\' in PowerShell single quotes is the TWO-character
            # string \\, which never equals a [char], so this branch was dead: an escaped
            # quote closed string state early and code after it was never scrubbed.
            if ($Line[$index] -eq [char]'\' -and $index + 1 -lt $Line.Length) { $index += 2; continue }
            if ($Line[$index] -eq '"') { $State.Value = 'code' }
            $index++
            continue
        }
        if ($index + 1 -lt $Line.Length -and $Line.Substring($index, 2) -eq '//') { break }
        if ($index + 1 -lt $Line.Length -and $Line.Substring($index, 2) -eq '(*') { $State.Value = 'block'; $index += 2; continue }
        if ($Line[$index] -eq '"') { $State.Value = 'string'; $index++; continue }
        [void]$code.Append($Line[$index])
        $index++
    }
    # Reaching end-of-line still inside a string means F#'s multi-line form, which this
    # scanner does not model: the state is reset so the next line is not scrubbed as
    # string content forever, and the line is marked AMBIGUOUS so the reset is routed to
    # manual review. The C# scanner has always done both; F# reset silently, so the guard
    # made an unverifiable assumption and reported nothing about it.
    $ambiguous = $false
    if ($State.Value -eq 'string') { $State.Value = 'code'; $ambiguous = $true }
    return [pscustomobject]@{ code = $code.ToString(); ambiguous = $ambiguous }
}

# XML project files are NOT C#. Routed to the C# lexer they were mangled twice over: an
# apostrophe in a comment (`<!-- don't -->`) entered the char-literal branch and consumed
# the rest of the line, and a `//` inside any URL truncated it - which is enough to hide a
# PackageReference from the dependency rule on the line that added it. The only lexical
# construct that matters here is the XML comment.
function Get-XmlCode {
    param([string] $Line, [ref] $State)

    $code = [Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Line.Length;) {
        if ($State.Value -eq 'comment') {
            if ($index + 2 -lt $Line.Length -and $Line.Substring($index, 3) -eq '-->') { $State.Value = 'code'; $index += 3 }
            else { $index++ }
            continue
        }
        if ($index + 3 -lt $Line.Length -and $Line.Substring($index, 4) -eq '<!--') { $State.Value = 'comment'; $index += 4; continue }
        [void]$code.Append($Line[$index])
        $index++
    }
    # An XML comment legitimately spans lines, so the state is CARRIED rather than reset -
    # and unlike the F# case above that is not an assumption, it is the format.
    return [pscustomobject]@{ code = $code.ToString(); ambiguous = $false }
}

function Get-VisualBasicCode {
    param([string] $Line, [ref] $State)

    $trimmed = $Line.TrimStart()
    if ($trimmed -match '(?i)^REM(?:\s|$)') { return [pscustomobject]@{ code = ''; ambiguous = $false } }
    $code = [Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Line.Length;) {
        if ($State.Value -eq 'string') {
            if ($Line[$index] -eq '"') {
                if ($index + 1 -lt $Line.Length -and $Line[$index + 1] -eq '"') { $index += 2; continue }
                $State.Value = 'code'
            }
            $index++
            continue
        }
        if ($Line[$index] -eq "'") { break }
        if ($Line[$index] -eq '"') { $State.Value = 'string'; $index++; continue }
        [void]$code.Append($Line[$index])
        $index++
    }
    if ($State.Value -eq 'string') { $State.Value = 'code' }
    return [pscustomobject]@{ code = $code.ToString(); ambiguous = $false }
}

function Get-CSharpCode {
    param([string] $Line, [ref] $State)

    $code = [Text.StringBuilder]::new()
    $ambiguous = $false
    for ($index = 0; $index -lt $Line.Length;) {
        if ($State.Value -eq 'block') {
            if ($index + 1 -lt $Line.Length -and $Line[$index] -eq '*' -and $Line[$index + 1] -eq '/') { $State.Value = 'code'; $index += 2 } else { $index++ }
            continue
        }
        if ($State.Value -eq 'string') {
            # [char], not the two-character string '\\' -- see Get-FSharpCode.
            if ($Line[$index] -eq [char]'\' -and $index + 1 -lt $Line.Length) { $index += 2; continue }
            if ($Line[$index] -eq '"') { $State.Value = 'code' }
            $index++
            continue
        }
        if ($State.Value -eq 'verbatim') {
            if ($Line[$index] -eq '"') {
                if ($index + 1 -lt $Line.Length -and $Line[$index + 1] -eq '"') { $index += 2; continue }
                $State.Value = 'code'
            }
            $index++
            continue
        }
        if ($State.Value -eq 'raw') {
            if ($index + 2 -lt $Line.Length -and $Line.Substring($index, 3) -eq '"""') { $State.Value = 'code'; $index += 3 } else { $index++ }
            continue
        }

        $character = $Line[$index]
        if ($character -eq '/' -and $index + 1 -lt $Line.Length) {
            if ($Line[$index + 1] -eq '/') { break }
            if ($Line[$index + 1] -eq '*') { $State.Value = 'block'; $index += 2; continue }
        }
        if ($character -eq '"') {
            if ($index + 2 -lt $Line.Length -and $Line.Substring($index, 3) -eq '"""') { $State.Value = 'raw'; $ambiguous = $true; $index += 3; continue }
            $State.Value = 'string'; $index++; continue
        }
        if ($character -eq '@' -and $index + 1 -lt $Line.Length -and $Line[$index + 1] -eq '"') { $State.Value = 'verbatim'; $index += 2; continue }
        # An INTERPOLATED string is entered as a plain string with no brace tracking, so
        # everything inside an expression hole -- NativeLibrary.Load, PInvoke,
        # System.Runtime.Intrinsics.*, Activator.CreateInstance, Type.GetType -- never
        # reaches the buffer the rules run against. Tracking hole depth properly needs a
        # real parser; marking the line ambiguous routes it to manual review instead,
        # which is the honest outcome for something this guard cannot interpret.
        if ($character -eq '$' -and $index + 2 -lt $Line.Length -and $Line[$index + 1] -eq '@' -and $Line[$index + 2] -eq '"') { $State.Value = 'verbatim'; $ambiguous = $true; $index += 3; continue }
        if ($character -eq '@' -and $index + 2 -lt $Line.Length -and $Line[$index + 1] -eq '$' -and $Line[$index + 2] -eq '"') { $State.Value = 'verbatim'; $ambiguous = $true; $index += 3; continue }
        if ($character -eq '$' -and $index + 1 -lt $Line.Length -and $Line[$index + 1] -eq '"') {
            # $""" is a raw interpolated string, not a plain one.
            if ($index + 3 -lt $Line.Length -and $Line.Substring($index + 1, 3) -eq '"""') { $State.Value = 'raw'; $ambiguous = $true; $index += 4; continue }
            $State.Value = 'string'; $ambiguous = $true; $index += 2; continue
        }
        if ($character -eq "'") {
            $index++
            if ($index -lt $Line.Length -and $Line[$index] -eq [char]'\') { $index++ }
            if ($index -lt $Line.Length) { $index++ }
            if ($index -lt $Line.Length -and $Line[$index] -eq "'") { $index++ } else { $ambiguous = $true }
            continue
        }
        [void]$code.Append($character)
        $index++
    }
    if ($State.Value -eq 'string') { $State.Value = 'code'; $ambiguous = $true }
    return [pscustomobject]@{ code = $code.ToString(); ambiguous = $ambiguous }
}

try {
    $repository = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $repository -PathType Container)) { throw "RepositoryPath '$RepositoryPath' is not a directory." }
    if (@(Invoke-GitReadOnly -Repository $repository -GitArguments @('rev-parse', '--is-inside-work-tree'))[0] -ne 'true') { throw "RepositoryPath '$repository' is not a Git work tree." }
    # --is-inside-work-tree is true throughout a work tree, including subdirectories --
    # but diff paths are repository-root-relative while `ls-files --others` prints them
    # relative to the cwd, so a subdirectory RepositoryPath joins a root-relative path
    # onto the sub-folder and ReadAllLines throws. Reject it by name rather than failing
    # closed on the first modified file with a message that does not say why.
    $topLevel = @(Invoke-GitReadOnly -Repository $repository -GitArguments @('rev-parse', '--show-toplevel'))[0]
    if (-not $topLevel) { throw "Could not resolve the work-tree root for '$repository'." }
    $topLevel = (Resolve-Path -LiteralPath $topLevel).Path
    if ($topLevel -ne $repository) {
        throw ("RepositoryPath '$repository' is a subdirectory of the work tree rooted at '$topLevel'. " +
            'Pass the work-tree root: diff paths are root-relative and cannot be joined onto a subdirectory.')
    }
    $baseCommit = @(Invoke-GitReadOnly -Repository $repository -GitArguments @('rev-parse', '--verify', "$BaseRef^{commit}"))[0]
    $pathspec = Get-ProductPathspec -Repository $repository -Paths $ProductPath
    $limitations = @(
        'Generated code requires manual review.',
        'Reflection requires manual review.',
        'Package transitivity requires manual review.',
        'Ambiguous interop requires manual review.',
        'Raw or lexically ambiguous source requires manual review.',
        'Extensionless binary files require manual review.',
        'Concurrent working-tree mutation during the scan invalidates its result.'
    )
    $violations = [Collections.Generic.List[object]]::new()
    $warnings = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    function Add-Finding {
        param([Collections.Generic.List[object]] $Target, [string] $Rule, [string] $Path, [int] $Line, [string] $Message)
        $key = "$Rule|$Path|$Line"
        if ($seen.Add($key)) {
            $Target.Add([ordered]@{ rule = $Rule; path = $Path; line = $Line; message = $Message })
        }
    }

    function Inspect-AddedLine {
        param([string] $Path, [int] $Line, [string] $Text, [ref] $LexicalState, [switch] $StateOnly)

        $extension = [IO.Path]::GetExtension($Path)
        $scrubbed = switch ($extension.ToLowerInvariant()) {
            '.fs' { Get-FSharpCode -Line $Text -State $LexicalState; break }
            '.vb' { Get-VisualBasicCode -Line $Text -State $LexicalState; break }
            { $_ -in '.csproj', '.fsproj', '.vbproj', '.props', '.targets' } {
                Get-XmlCode -Line $Text -State $LexicalState; break
            }
            default { Get-CSharpCode -Line $Text -State $LexicalState }
        }
        $code = $scrubbed.code
        if ($StateOnly) { return }
        if ($scrubbed.ambiguous) {
            Add-Finding -Target $warnings -Rule 'lexical-review' -Path $Path -Line $Line -Message 'Raw or lexically ambiguous source requires manual review; this guard did not interpret it.'
        }
        if ($code -match '(?i)\b(unsafe|AllowUnsafeBlocks)\b') {
            Add-Finding -Target $violations -Rule 'unsafe-code' -Path $Path -Line $Line -Message 'Unsafe code is outside the managed product-code boundary.'
        }
        if ($code -match '(?i)\bSystem\.Runtime\.Intrinsics\b') {
            Add-Finding -Target $violations -Rule 'runtime-intrinsics' -Path $Path -Line $Line -Message 'Runtime intrinsics are outside the managed product-code boundary.'
        }
        if ($code -match '(?i)\b(DllImport|LibraryImport|NativeLibrary|PInvoke)\b' -or $code -match '(?i)\bDeclare\b.*\bLib\b') {
            Add-Finding -Target $violations -Rule 'native-interop' -Path $Path -Line $Line -Message 'Native interop is outside the managed product-code boundary.'
        }
        if ($code -match '(?i)<\s*(PackageReference|PackageVersion|PackageDownload)\b') {
            Add-Finding -Target $warnings -Rule 'dependency-change' -Path $Path -Line $Line -Message 'Added package dependency requires manual confirmation of its managed boundary and transitive dependencies.'
        }
        if ($code -match '(?i)<\s*ProjectReference\b') {
            Add-Finding -Target $warnings -Rule 'project-dependency' -Path $Path -Line $Line -Message 'Added project dependency requires manual confirmation of its managed boundary.'
        }
        if ($code -match '(?i)\b(System\.Reflection|Type\.GetType|Activator\.CreateInstance)\b') {
            Add-Finding -Target $warnings -Rule 'reflection-review' -Path $Path -Line $Line -Message 'Reflection can obscure interop and requires manual review.'
        }
        if ($Path -match '(?i)(^|/)obj/|\.(?:g|generated)\.(?:cs|fs|vb)$' -or $code -match '(?i)\bGeneratedCode\b') {
            Add-Finding -Target $warnings -Rule 'generated-code-review' -Path $Path -Line $Line -Message 'Generated code requires manual review; this guard does not establish its managed safety.'
        }
    }

    $nameStatus = Invoke-GitReadOnly -Repository $repository -GitArguments (@('diff', '--no-ext-diff', '--name-status', $baseCommit, '--') + $pathspec)
    foreach ($entry in $nameStatus) {
        $parts = $entry -split "`t"
        $status = $parts[0]
        $path = $parts[$parts.Count - 1]
        # R### and C### are routine: diff.renames has defaulted on since git 2.9, and the
        # destination path is already the last field. Matching only 'A' let a tracked file
        # RENAMED to .dll/.so/.exe enter with no violation, and the untracked pass cannot
        # see it either because it is tracked.
        if ($status -match '^[ACR]' -and $path -match '(?i)\.(dll|so|dylib|a|lib|exe)$') {
            Add-Finding -Target $violations -Rule 'native-binary' -Path $path -Line 0 -Message 'Added native binary or executable is outside the managed product-code boundary.'
        }
    }

    $untracked = Invoke-GitReadOnly -Repository $repository -GitArguments (@('ls-files', '--others', '--exclude-standard', '--') + $pathspec)
    foreach ($path in $untracked) {
        if ($path -match '(?i)\.(dll|so|dylib|a|lib|exe)$') {
            Add-Finding -Target $violations -Rule 'native-binary' -Path $path -Line 0 -Message 'Untracked native binary or executable is outside the managed product-code boundary.'
            continue
        }
        if ($path -notmatch '(?i)\.(cs|fs|vb|csproj|fsproj|vbproj|props|targets)$') { continue }
        $fullPath = Join-Path $repository ($path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $lexicalState = 'code'
        $lineNumber = 1
        foreach ($text in [IO.File]::ReadLines($fullPath)) {
            Inspect-AddedLine -Path $path -Line $lineNumber -Text $text -LexicalState ([ref]$lexicalState)
            $lineNumber++
        }
    }

    # Path prefixes and colour are PINNED. `diff.noprefix`, `diff.mnemonicPrefix` or
    # forced colour all break the `^+++ b/(.+)$` match below, leaving $currentPath null
    # and every added line skipped -- and the script would then print passed = true with
    # zero violations over a diff it never read, indistinguishable from "scanned and
    # clean". A security guard reporting success is the worst failure available to it.
    $diff = Invoke-GitReadOnly -Repository $repository -GitArguments (
        @('-c', 'diff.noprefix=false', '-c', 'diff.mnemonicPrefix=false', '-c', 'color.ui=never',
          'diff', '--no-ext-diff', '--no-color', '--src-prefix=a/', '--dst-prefix=b/',
          '--unified=0', $baseCommit, '--') + $pathspec)
    $currentPath = $null
    $nextLine = 0
    $lexicalState = 'code'
    $sourceLines = @()
    $scannedThrough = 0
    $headersMatched = 0
    $unreadableHeaders = 0
    # Header lines and CONTENT lines are told apart by POSITION, not by their text. A
    # `+++`-prefixed string is genuinely ambiguous: the added C# line `++i;` arrives as
    # `+++i;` and was discarded as a file header, which both skipped the line and left
    # $nextLine unincremented, so every remaining line of that hunk was attributed to the
    # wrong number. Git's own grammar settles it - file headers precede the first `@@` of
    # a file, content lines only ever follow one - so track which side of the hunk header
    # we are on and there is nothing left to guess.
    $inHunk = $false
    foreach ($entry in $diff) {
        if ($entry.StartsWith('diff --git ')) { $inHunk = $false; continue }
        if (-not $inHunk -and $entry -match '^\+\+\+ ' -and $entry -notmatch '^\+\+\+ b/' -and
            $entry -notmatch '^\+\+\+ /dev/null\s*$') {
            # A destination header the `b/` capture could not read. `/dev/null` is a
            # DELETION and is expected; anything else means the prefix pinning did not
            # hold, which is the one shape this cross-check exists to catch.
            $unreadableHeaders++
            continue
        }
        if (-not $inHunk -and $entry -match '^\+\+\+ b/(.+)$') {
            $headersMatched++
            $candidatePath = $Matches[1]
            $currentPath = if ($candidatePath -match '(?i)\.(?:cs|fs|vb|csproj|fsproj|vbproj|props|targets)$') { $candidatePath } else { $null }
            $lexicalState = 'code'
            $sourceLines = if ($null -ne $currentPath) { [IO.File]::ReadAllLines((Join-Path $repository $currentPath)) } else { @() }
            $scannedThrough = 0
            continue
        }
        if ($entry -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@') {
            $inHunk = $true
            $nextLine = [int]$Matches[1]
            while ($null -ne $currentPath -and $scannedThrough -lt $nextLine - 1) {
                Inspect-AddedLine -Path $currentPath -Line ($scannedThrough + 1) -Text $sourceLines[$scannedThrough] -LexicalState ([ref]$lexicalState) -StateOnly
                $scannedThrough++
            }
            continue
        }
        # Inside a hunk every `+` line is content, `++i;` included. The old
        # `-not StartsWith('+++')` guard was what dropped it.
        if ($inHunk -and $entry.StartsWith('+') -and $null -ne $currentPath) {
            Inspect-AddedLine -Path $currentPath -Line $nextLine -Text $entry.Substring(1) -LexicalState ([ref]$lexicalState)
            $scannedThrough = $nextLine
            $nextLine++
        }
    }

    # Cross-check the two git reads against each other. If --name-status listed source
    # files the guard must scan but the diff loop matched no file header, the pinning
    # above did not hold and the scan is empty for a reason that is not "clean".
    # Deletions are excluded: their header is `+++ /dev/null`, which the loop correctly
    # never matches, so counting them would trip this check on a legitimate diff.
    # Anchored on UNREADABLE HEADERS, not on the name-status list. Comparing against
    # `--name-status` threw on two diffs the script had read perfectly: a pure rename or a
    # mode-only change has no content, so git emits no `+++` header and no hunk for it,
    # while name-status still reports `R100<TAB>old<TAB>new` - and the audit then could not
    # run at all for that change. Counting hunks instead trips on a plain DELETION, whose
    # header is `+++ /dev/null` and which legitimately has hunks and no scannable path.
    #
    # What this check is actually for is broken prefix configuration, and that has a
    # signature of its own: a destination header the `b/` capture cannot read. `/dev/null`
    # is excluded because a deletion is expected; anything else means the pinning did not
    # hold and added lines went unscanned. (CodeRabbit, PR #135.)
    if ($unreadableHeaders -gt 0) {
        throw ("git diff produced $unreadableHeaders destination header(s) that are neither " +
            "'+++ b/<path>' nor '+++ /dev/null', so the diff prefix pinning did not hold and " +
            'added lines went unscanned. Refusing to report a pass over an unread diff.')
    }

    $result = [ordered]@{
        passed = $violations.Count -eq 0
        violations = @($violations)
        warnings = @($warnings)
        warningDispositionRequired = $warnings.Count -gt 0
        reviewedRange = "$baseCommit..working-tree"
        manualReviewLimitations = $limitations
    }
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 5 -Compress))
    exit 0
}
catch {
    [Console]::Error.WriteLine("Managed product boundary invocation error: $($_.Exception.Message)")
    exit 2
}
