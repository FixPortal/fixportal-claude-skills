#Requires -Version 7
<#
.SYNOPSIS
    Finds Pester suites under a repository and flags destructive shapes. Parses only; executes nothing.

.DESCRIPTION
    Suite discovery, shipped here because Test-PowerShellTestSafety.ps1 dot-sources it from the same directory. A Pester suite
    found here is REPORTED, never run in the working profile: run suites in an isolated lane. The flags lower the chance of a
    mistake going unnoticed; they are not isolation and say nothing about
    a suite that builds its commands dynamically (that is itself flagged as 'dynamic-code').

    Dot-source for the functions, or run with -Repository to list suites. There is no top-level param() block: dot-sourcing
    would bind it in the caller's scope and overwrite the caller's own $Repository and $IncludeVerifyScripts.

    Flags: recursive-delete, automatic-variable-assignment, environment-write, junction-or-symlink, dynamic-code (all destructive),
    and profile-reference (informational).
#>

# Read-only or meaning-bearing automatic variables. Benign, routinely assigned ones ($null discard, $global:LASTEXITCODE in mocks,
# $Args, $Input, $Error, $Matches, $Event) are deliberately not listed: flagging them buries the real signal.
$script:AutomaticVariables = @('Home', 'PSHome', 'Profile', 'PID', 'Host', 'PWD', 'ExecutionContext', 'MyInvocation', 'PSCmdlet',
    'PSCommandPath', 'PSScriptRoot', 'ShellId', 'PSVersionTable', 'true', 'false', '?', 'PSCulture', 'PSUICulture',
    'PSEdition', 'IsCoreCLR', 'IsWindows', 'IsLinux', 'IsMacOS', 'EnabledExperimentalFeatures', 'PSStyle', '_', 'PSItem', 'this')
$script:ProfileEnvNames = @('USERPROFILE', 'HOME', 'HOMEPATH', 'HOMEDRIVE', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'ProgramData', 'PATH', 'PSModulePath')
$script:DeleteCommands = @('Remove-Item', 'ri', 'rm', 'rmdir', 'rd', 'del', 'erase')
$script:SkippedDirectories = @('node_modules', '.git', 'bin', 'obj', 'dist', '.next', 'coverage', 'TestResults', 'StrykerOutput')

function Get-VariableNameFromAst($VariableAst) { return [regex]::Replace($VariableAst.VariablePath.UserPath, '^[A-Za-z]+:', '') }

function Get-StaticPathArgument($CommandAst) {
    $elements = @($CommandAst.CommandElements | Select-Object -Skip 1)
    for ($i = 0; $i -lt $elements.Count; $i++) {
        $element = $elements[$i]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { return $element }
        $parameter = $element.ParameterName
        if ('Path'.StartsWith($parameter, [StringComparison]::OrdinalIgnoreCase) -or 'LiteralPath'.StartsWith($parameter, [StringComparison]::OrdinalIgnoreCase) -or $parameter -eq 'lp') {
            if ($element.Argument) { return $element.Argument }
            if ($i + 1 -lt $elements.Count) { return $elements[$i + 1] }
            return $null
        }
        if (-not $element.Argument -and $parameter -notmatch '^(force|f|whatif|wi|confirm|cf|verbose|vb|debug|db|passthru|nonewline|asbytestream)$') { $i++ }
    }
    return $null
}

function Get-AssignedVariableAsts($Target) {
    if ($Target -is [System.Management.Automation.Language.VariableExpressionAst]) { return @($Target) }
    if ($Target -is [System.Management.Automation.Language.ForEachStatementAst]) { return @(Get-AssignedVariableAsts $Target.Variable) }
    if ($Target -is [System.Management.Automation.Language.ParameterAst]) { return @(Get-AssignedVariableAsts $Target.Name) }
    if ($Target -is [System.Management.Automation.Language.UnaryExpressionAst] -and $Target.TokenKind -in 'PlusPlus', 'MinusMinus', 'PostfixPlusPlus', 'PostfixMinusMinus') { return @(Get-AssignedVariableAsts $Target.Child) }
    if ($Target -is [System.Management.Automation.Language.ConvertExpressionAst]) { return @(Get-AssignedVariableAsts $Target.Child) }
    if ($Target -is [System.Management.Automation.Language.ArrayLiteralAst]) { return @($Target.Elements | ForEach-Object { Get-AssignedVariableAsts $_ }) }
    return @()
}

function Get-PesterRisk {
    <# Returns the flags for a PowerShell source string. Pure: no file access, no execution. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Source)
    $flags = [System.Collections.Generic.HashSet[string]]::new()
    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count) { [void]$flags.Add('parse-error'); return @($flags) }

    foreach ($ast in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -or $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] -or $args[0] -is [System.Management.Automation.Language.ParameterAst] -or $args[0] -is [System.Management.Automation.Language.UnaryExpressionAst] }, $true)) {
        $target = if ($ast -is [System.Management.Automation.Language.AssignmentStatementAst]) { $ast.Left } else { $ast }
        foreach ($var in (Get-AssignedVariableAsts $target)) {
            if ($var.VariablePath.IsDriveQualified -and $var.VariablePath.DriveName -eq 'env') { [void]$flags.Add($(if ((Get-VariableNameFromAst $var) -in $script:ProfileEnvNames) { 'environment-write' } else { 'environment-write-other' })); continue }
            if ((Get-VariableNameFromAst $var) -in $script:AutomaticVariables) { [void]$flags.Add('automatic-variable-assignment') }
        }
    }
    foreach ($ast in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $name = Get-VariableNameFromAst $ast
        if ($ast.VariablePath.IsDriveQualified -and $ast.VariablePath.DriveName -eq 'env') { if ($name -in $script:ProfileEnvNames) { [void]$flags.Add('profile-reference') } }
        elseif ($name -in 'Home', 'Profile') { [void]$flags.Add('profile-reference') }
    }
    foreach ($ast in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $ast.GetCommandName()
        if (-not $name) {
            # `& $cmd` / `. $path`: the command is not a literal, so nothing about it can be judged.
            if ($ast.InvocationOperator -in 'Ampersand', 'Dot') { [void]$flags.Add('dynamic-code') }
            continue
        }
        # `Microsoft.PowerShell.Management\Remove-Item` and `$env:SystemRoot\System32\cmd.exe` are the same commands under another spelling,
        # and so is `C:/Program Files/PowerShell/7/pwsh.exe` (CodeRabbit, PR #426).
        $name = [regex]::Replace($name, '^.*[\\/]|\.exe$', '', 'IgnoreCase')
        if ($name -in $script:DeleteCommands) {
            $recursive = @($ast.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '^(r|re|rec|recu|recur|recurs|recurse)$' }).Count -gt 0
            # `Get-ChildItem $d -Recurse | Remove-Item` deletes a whole tree with no -Recurse on the delete itself (R-C R08).
            # Any earlier pipeline element that recurses or limits depth counts; piping from anything else is not judged recursive.
            # Every ENCLOSING pipeline is checked, not only the delete's own: in
            # `gci $d -Recurse | ForEach-Object { Remove-Item $_ }` the delete sits in a scriptblock fed by the recursion (CodeRabbit, PR #426).
            $node = $ast
            while (-not $recursive -and $node.Parent) {
                if ($node.Parent -is [System.Management.Automation.Language.PipelineAst]) {
                    $stages = @($node.Parent.PipelineElements)
                    $at = [array]::IndexOf($stages, $node)
                    if ($at -gt 0) {
                        $recursive = @($stages[0..($at - 1)] | ForEach-Object { if ($_ -is [System.Management.Automation.Language.CommandAst]) { $_.CommandElements } } |
                            Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '^(r|re|rec|recu|recur|recurs|recurse|de|dep|dept|depth)$' }).Count -gt 0
                    }
                }
                $node = $node.Parent
            }
            if ($recursive) { [void]$flags.Add('recursive-delete') }
            # `Remove-Item @splat` can hide -Recurse inside the hashtable, so it cannot be judged either.
            $splatted = @($ast.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted }).Count -gt 0
            if ($splatted) { [void]$flags.Add('dynamic-code') }
        }
        # Native deletes bypass the cmdlet check: `rmdir /s`, `del /s`, and robocopy's destination-emptying /MIR and /PURGE.
        if ($name -eq 'cmd' -and $ast.Extent.Text -match '(?i)\b(rmdir|rd|del|erase)\b[^|&]*\s/s\b') { [void]$flags.Add('recursive-delete') }
        if ($name -eq 'robocopy' -and $ast.Extent.Text -match '(?i)\s/(mir|purge)\b') { [void]$flags.Add('recursive-delete') }
        if ($name -in 'Set-Variable', 'sv', 'New-Variable', 'nv') {
            # The variable name is `-Name <x>` / `-Name:<x>` or the first positional argument.
            $elements = @($ast.CommandElements | Select-Object -Skip 1)
            $named = $elements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '^n(a|am|ame)?$' } | Select-Object -First 1
            $target = if ($named -and $named.Argument) { $named.Argument } elseif ($named) { $elements[[array]::IndexOf($elements, $named) + 1] }
            if (-not $named) {
                for ($i = 0; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        # Inline values consume no following node. Switches also consume no value;
                        # other named arguments (e.g. -Scope Script) precede the positional Name.
                        if (-not $element.Argument -and $element.ParameterName -notmatch '^(f(o(r(c(e)?)?)?)?|p(a(s(s(t(h(r(u)?)?)?)?)?)?)?|whatif|wi|confirm|cf|verbose|vb|debug|db)$') { $i++ }
                    } else { $target = $element; break }
                }
            }
            $targets = if ($target -is [System.Management.Automation.Language.ArrayLiteralAst]) { @($target.Elements) } else { @($target) }
            foreach ($nameAst in $targets) {
                if ($nameAst -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $nameAst.Value -in $script:AutomaticVariables) { [void]$flags.Add('automatic-variable-assignment') }
            }
        }
        if ($name -in 'Invoke-Expression', 'iex', 'Invoke-Command', 'icm') { [void]$flags.Add('dynamic-code') }
        if ($name -in 'pwsh', 'powershell') {
            $viaCommand = @($ast.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and ($_.ParameterName -match '^(c|co|com|comm|comma|comman|command|ec)$' -or 'EncodedCommand'.StartsWith($_.ParameterName, [StringComparison]::OrdinalIgnoreCase)) }).Count -gt 0
            if ($viaCommand) { [void]$flags.Add('dynamic-code') }
        }
        if ($name -in 'Set-Item', 'si', 'Set-Content' -and ($ast.Extent.Text -match '(?i)\benv:')) { [void]$flags.Add('environment-write') }
        if ($name -in 'Set-Item', 'si', 'Set-Content') {
            $pathAst = Get-StaticPathArgument $ast
            $pathAsts = if ($pathAst -is [System.Management.Automation.Language.ArrayLiteralAst]) { @($pathAst.Elements) } else { @($pathAst) }
            foreach ($literalPath in $pathAsts) {
                if ($literalPath -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $literalPath.Value -match '(?i)^Variable:[\\/]?(?:(?:global|script|local|private):)?(.+)$' -and $Matches[1] -in $script:AutomaticVariables) { [void]$flags.Add('automatic-variable-assignment') }
            }
        }
        if ($name -in 'New-Item', 'ni', 'mklink') {
            $text = $ast.Extent.Text
            if ($name -eq 'mklink' -or $text -match '(?i)-(?:ItemType|Type)(?:\s+|:)[''"]?(Junction|SymbolicLink|HardLink)\b') { [void]$flags.Add('junction-or-symlink') }
        }
    }
    foreach ($ast in $tree.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $member = $ast.Member.Extent.Text
        if ($member -in 'Delete', 'DeleteDirectory') {
            $callArguments = if ($ast.Arguments) { @($ast.Arguments) } else { @() }
            # Directory.Delete(path, recursive) is static; DirectoryInfo.Delete(recursive) is an instance call, so the flag moves to argument 0.
            $flagIndex = if ($ast.Static) { 1 } else { 0 }
            $isNonRecursive = $callArguments.Count -le $flagIndex -or ($callArguments[$flagIndex] -is [System.Management.Automation.Language.VariableExpressionAst] -and $callArguments[$flagIndex].VariablePath.UserPath -eq 'false')
            if (-not $isNonRecursive) { [void]$flags.Add('recursive-delete') }
        }
        if ($member -eq 'SetEnvironmentVariable') { [void]$flags.Add('environment-write') }
        if ($member -eq 'Create' -and $ast.Static -and $ast.Expression.Extent.Text -match '(?i)^\[(System\.Management\.Automation\.)?ScriptBlock\]$') { [void]$flags.Add('dynamic-code') }
        # $ExecutionContext.InvokeCommand runs or expands text as code. Matched by member name alone, so an alias of the object is caught too.
        if ($member -in 'InvokeScript', 'ExpandString') { [void]$flags.Add('dynamic-code') }
        if ($member -in 'CreateSymbolicLink', 'CreateHardLink', 'CreateSymbolicLinkA', 'CreateSymbolicLinkW') { [void]$flags.Add('junction-or-symlink') }
    }
    return @($flags | Sort-Object)
}

# pwsh's own parameters, as CommandLineParameterParser matches them: the full name, the shortest prefix it accepts, any
# alias, and whether a value follows. Unlisted options return '?.ps1' (dynamic-code), because whether one takes a value
# decides which word is the script (`pwsh -settings ./s.json ./x.ps1` runs x.ps1; CodeRabbit, PR #426).
$script:PwshOptions = @(
    @('command', 'c', @(), 'stop'), @('encodedcommand', 'e', @('ec'), 'stop'), @('file', 'f', @(), 'file'),
    @('configurationname', 'config', @(), 'value'), @('configurationfile', 'configurationfile', @(), 'value'),
    @('custompipename', 'custompipename', @(), 'value'), @('encodedarguments', 'encodeda', @('ea'), 'value'),
    @('executionpolicy', 'ex', @('ep'), 'value'), @('inputformat', 'inp', @('if'), 'value'), @('outputformat', 'o', @('of'), 'value'),
    @('settingsfile', 'settings', @(), 'value'), @('windowstyle', 'w', @(), 'value'), @('workingdirectory', 'wo', @('wd'), 'value'),
    @('psconsolefile', 'psconsolefile', @(), 'value'), @('version', 'v', @(), 'value'),
    @('help', 'h', @('?'), 'switch'), @('interactive', 'i', @(), 'switch'), @('login', 'l', @(), 'switch'), @('mta', 'mta', @(), 'switch'),
    @('sta', 'sta', @(), 'switch'), @('noexit', 'noe', @(), 'switch'), @('nologo', 'nol', @(), 'switch'),
    @('noninteractive', 'noni', @(), 'switch'), @('noprofile', 'nop', @(), 'switch'), @('noprofileloadtime', 'noprofileloadtime', @(), 'switch'),
    @('namedpipeservermode', 'namedpipes', @(), 'switch'), @('servermode', 'server', @(), 'switch'),
    @('socketservermode', 'sockets', @(), 'switch'), @('sshservermode', 'sshs', @(), 'switch')
)

function Get-PwshOptionKind([string] $Name) {
    # The longest-minimum match wins, so `-noprofileloadtime` is not read as `-noprofile`.
    $hit = $script:PwshOptions | Where-Object { $Name -in $_[2] -or ($_[0].StartsWith($Name, [StringComparison]::OrdinalIgnoreCase) -and $Name.Length -ge $_[1].Length) } |
        Sort-Object { $_[1].Length } -Descending | Select-Object -First 1
    if ($hit) { $hit[3] }
}

function Get-ScriptCallTargets {
    <# Literal `.ps1` names this source runs (`& ./x.ps1`, `. ./x.ps1`, bareword `x.ps1`, `pwsh -File ./x.ps1`). Pure: parses only.
       A `pwsh -File` value that is not a literal (`pwsh -File $validator`) is returned as '?.ps1', which never resolves, so
       Get-FileRisk flags it dynamic-code (Gitar, PR #426). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Source)
    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    @($tree.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object {
            $name = $_.GetCommandName()
            if ($name -match '(?i)\.ps1$') { $name }
            elseif ($name -and [regex]::Replace($name, '(?i)^.*[\\/]|\.exe$', '') -in 'pwsh', 'powershell') {
                # -File is pwsh's first positional parameter, so `pwsh -NoProfile ./x.ps1` runs x.ps1 too (Gitar, PR #426).
                # Options taking a value are stepped over; -Command / -EncodedCommand end the search (already dynamic-code).
                $elements = @($_.CommandElements)
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        $kind = Get-PwshOptionKind $element.ParameterName
                        if ($kind -eq 'file') {
                            $value = if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] }
                            if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $value.Value } else { '?.ps1' }
                            break
                        }
                        if ($kind -eq 'stop') { break }
                        if (-not $kind) { '?.ps1'; break }
                        if ($kind -eq 'value' -and -not $element.Argument) { $i++ }
                    } else {
                        if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $element.Value } else { '?.ps1' }
                        break
                    }
                }
            }
        } | Sort-Object -Unique)
}

function Get-FileRisk {
    <# Get-PesterRisk for a file, plus every literal .ps1 it calls, followed to any depth (R-C R08). A called script's delete
       runs during the verify exactly as an inline one would. A target that does not resolve (a bareword
       found through PATH, a script the repository does not have) cannot be judged, so it is 'dynamic-code'.
       A relative target resolves against the directory the verify runs FROM (the repository root: an isolated lane's
       working copy, CI's checkout), not beside the caller; both candidates are scanned, fail-closed. Without
       -WorkingDirectory a relative target cannot be placed, so it is 'dynamic-code' (CodeRabbit, PR #426). #>
    param([Parameter(Mandatory)][string] $Path, [string] $WorkingDirectory, [System.Collections.Generic.HashSet[string]] $Visited)
    if (-not $Visited) { $Visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $Visited.Add($full)) { return @() }
    $source = [IO.File]::ReadAllText($full)
    $flags = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-PesterRisk -Source $source))
    foreach ($target in @(Get-ScriptCallTargets -Source $source)) {
        $candidates = if ([IO.Path]::IsPathRooted($target)) { @($target) }
        elseif ($WorkingDirectory) { @((Join-Path $WorkingDirectory $target), (Join-Path ([IO.Path]::GetDirectoryName($full)) $target)) }
        else { @() }
        $resolved = @($candidates | Where-Object { [IO.File]::Exists($_) })
        if (-not $resolved.Count) { [void]$flags.Add('dynamic-code'); continue }
        foreach ($file in $resolved) {
            foreach ($flag in @(Get-FileRisk -Path $file -WorkingDirectory $WorkingDirectory -Visited $Visited)) { [void]$flags.Add($flag) }
        }
    }
    return @($flags | Sort-Object)
}

function Find-PesterSuites {
    <# Pruned walk, never entering a reparse point; returns Path, RelativePath, Kind, Flags and Destructive per file. Reads files, runs nothing.
       Kind is 'Pester' for *.Test(s).ps1. With -IncludeVerifyScripts it also returns verify-*.ps1 as 'VerifyScript': an audit view of the skills corpus
       contract scripts, which run in CI and are not Pester suites, so run-tests must not treat them as ones. #>
    param([Parameter(Mandatory)][string] $Repository, [switch] $IncludeVerifyScripts)
    $root = [IO.Path]::GetFullPath($Repository).TrimEnd('\', '/')
    if (-not [IO.Directory]::Exists($root)) { throw "repository path not found: $Repository" }
    $stack = [System.Collections.Generic.Stack[string]]::new(); $stack.Push($root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        try { $files = @([IO.Directory]::EnumerateFiles($dir)); $subs = @([IO.Directory]::EnumerateDirectories($dir)) }
        catch {
            # A directory that cannot be read hides suites from the report; say so rather than abort the whole walk.
            Write-Warning "Find-PesterSuites could not read '$dir' ($($_.Exception.GetType().Name)); suites beneath it are NOT reported."
            continue
        }
        foreach ($file in $files) {
            $kind = if ($file -match '\.Tests?\.ps1$') { 'Pester' } elseif ($IncludeVerifyScripts -and $file -match '[\\/]verify-[^\\/]*\.ps1$') { 'VerifyScript' } else { continue }
            # @() keeps Flags an array: a function's output unrolls to $null or a lone string otherwise.
            $flags = @(Get-FileRisk -Path $file -WorkingDirectory $root)
            $destructive = @($flags | Where-Object { $_ -in 'recursive-delete', 'automatic-variable-assignment', 'environment-write', 'junction-or-symlink', 'dynamic-code', 'parse-error' }).Count -gt 0
            [pscustomobject]@{ Path = $file; RelativePath = $file.Substring($root.Length + 1); Kind = $kind; Flags = $flags; Destructive = $destructive }
        }
        foreach ($sub in $subs) {
            if ($script:SkippedDirectories -contains [IO.Path]::GetFileName($sub)) { continue }
            if ([IO.File]::GetAttributes($sub) -band [IO.FileAttributes]::ReparsePoint) { continue }
            $stack.Push($sub)
        }
    }
}

if ($MyInvocation.InvocationName -ne '.' -and $args.Count) { Find-PesterSuites @args }
