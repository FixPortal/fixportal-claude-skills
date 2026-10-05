[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter(Mandatory)]
    [string] $Key
)

$ErrorActionPreference = 'Stop'

function Expand-EditorConfigBraces {
    param([string] $Pattern)

    $open = $Pattern.IndexOf('{')
    if ($open -lt 0) { return $Pattern }
    $close = $Pattern.IndexOf('}', $open + 1)
    if ($close -lt 0) { return $Pattern }

    $prefix = $Pattern.Substring(0, $open)
    $suffix = $Pattern.Substring($close + 1)
    foreach ($choice in $Pattern.Substring($open + 1, $close - $open - 1).Split(',')) {
        Expand-EditorConfigBraces -Pattern ($prefix + $choice + $suffix)
    }
}

function Convert-EditorConfigGlobToRegex {
    param([string] $Pattern)

    $regex = [Text.StringBuilder]::new('^')
    for ($i = 0; $i -lt $Pattern.Length; $i++) {
        $char = $Pattern[$i]
        if ($char -eq '*') {
            if ($i + 1 -lt $Pattern.Length -and $Pattern[$i + 1] -eq '*') {
                $i++
                if ($i + 1 -lt $Pattern.Length -and $Pattern[$i + 1] -eq '/') {
                    $i++
                    [void] $regex.Append('(?:.*/)?')
                } else {
                    [void] $regex.Append('.*')
                }
            } else {
                [void] $regex.Append('[^/]*')
            }
        } elseif ($char -eq '?') {
            [void] $regex.Append('[^/]')
        } elseif ($char -eq '[') {
            $close = $Pattern.IndexOf(']', $i + 1)
            if ($close -lt 0) {
                [void] $regex.Append('\[')
                continue
            }
            $class = $Pattern.Substring($i + 1, $close - $i - 1)
            if ($class.StartsWith('!')) { $class = '^' + $class.Substring(1) }
            [void] $regex.Append('[' + $class + ']')
            $i = $close
        } else {
            [void] $regex.Append([regex]::Escape([string] $char))
        }
    }
    [void] $regex.Append('$')
    return $regex.ToString()
}

function Test-EditorConfigSection {
    param([string] $Pattern, [string] $RelativePath)

    $patternPath = $Pattern.Replace('\', '/')
    $candidate = $RelativePath.Replace('\', '/')
    if ($patternPath.StartsWith('/')) { $patternPath = $patternPath.Substring(1) }
    elseif (-not $patternPath.Contains('/')) { $candidate = [IO.Path]::GetFileName($candidate) }

    foreach ($expanded in Expand-EditorConfigBraces -Pattern $patternPath) {
        if ($candidate -match (Convert-EditorConfigGlobToRegex -Pattern $expanded)) { return $true }
    }
    return $false
}

$sourceFile = (Resolve-Path -LiteralPath $Path).Path
if ([IO.Path]::GetExtension($sourceFile) -ne '.cs') {
    throw "Path must name a concrete C# file: '$sourceFile'."
}

$configs = [System.Collections.Generic.List[object]]::new()
$directory = Split-Path $sourceFile -Parent
while ($directory) {
    $configPath = Join-Path $directory '.editorconfig'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $configPath)
        $configs.Add([pscustomobject]@{ Path = $configPath; Directory = $directory; Lines = $lines })

        $isRoot = $false
        foreach ($line in $lines) {
            if ($line -match '^\s*\[') { break }
            if ($line -match '^\s*[#;]') { continue }
            if ($line -match '^\s*root\s*=\s*true\s*$') { $isRoot = $true; break }
        }
        if ($isRoot) { break }
    }

    $parent = Split-Path $directory -Parent
    if (-not $parent -or $parent -eq $directory) { break }
    $directory = $parent
}

$orderedConfigs = @($configs)
[array]::Reverse($orderedConfigs)
$keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*?)\s*$'
$assignment = $null

foreach ($config in $orderedConfigs) {
    $relativePath = [IO.Path]::GetRelativePath($config.Directory, $sourceFile)
    $section = $null
    $sectionMatches = $false
    foreach ($line in $config.Lines) {
        if ($line -match '^\s*[#;]') { continue }
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $section = $Matches[1]
            $sectionMatches = Test-EditorConfigSection -Pattern $section -RelativePath $relativePath
            continue
        }
        if ($sectionMatches -and $line -match $keyPattern) {
            $assignment = [pscustomobject]@{
                ConfigPath = $config.Path
                Section    = $section
                Key        = $Key
                Value      = $Matches[1]
            }
        }
    }
}

if ($null -ne $assignment) { $assignment }
