#Requires -Version 7
<#
.SYNOPSIS
    A small accident guard for test cleanup: recursively deletes a directory only when it is plainly inside the temp directory. Throws otherwise.

.DESCRIPTION
    Built after 2026-10-14, when a failed assignment left $script:Home pointing at the real profile and a cleanup deleted it. A variable
    name, an intended assignment or a temp-API origin is not proof, so this re-checks the path itself just before deleting:

      1. the path is absolute, wildcard-free, and normalised so `..` cannot escape;
      2. at least one protected path is supplied, the temp root is not a filesystem root, is not equal to or above any protected path
         (a poisoned TEMP), and is itself a directory that is not a reparse point;
      3. the path is strictly inside the temp root;
      4. the path, when it exists, is a directory;
      5. no directory from the temp root down to the path is a reparse point, and every one can be inspected.

    What this does NOT defend. An adversarial panel (2026-10-15) found each of these, and all sit outside the accident it targets:
      - it is not race-safe: the checks and Remove-Item are separate operations, so a directory swapped for a junction between them wins.
        Adversarial cases belong in an isolated lane, not here;
      - comparisons are lexical: a temp root that reaches the profile through subst, an 8.3 short name or a case variant is not recognised;
      - it does not prove the test created the directory: any directory inside the temp root passes. Naming conventions are the lint's job
        (verify-no-automatic-variable-assignment.ps1), not a runtime refusal;
      - it does not look inside the tree. UNVERIFIED: whether Remove-Item -Recurse follows a link nested inside the tree.

    A refusal throws. It does not warn and carry on, because a swallowed refusal leaves the caller believing cleanup happened. Call it
    from a `finally` inside its own try/catch if a cleanup failure must not mask the test's real failure.

    -TempRoot and -ProtectedPath default to the real temp directory and the real profile. Tests override them to exercise the refusals
    against fixtures, so no test ever needs to point a delete at the real profile.
#>

function Get-OwnedTempFullPath([string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $fsRoot = [IO.Path]::GetPathRoot($full)
    # A filesystem root keeps its separator so it stays recognisable; every other path loses trailing ones.
    if ($full.Length -le $fsRoot.Length) { return $fsRoot }
    return $full.TrimEnd('\', '/')
}

function Test-OwnedTempInside([string] $Child, [string] $Parent) {
    $cmp = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = $Parent.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $Child.StartsWith($prefix, $cmp)
}

function Test-OwnedTempSame([string] $A, [string] $B) {
    $cmp = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals($A.TrimEnd('\', '/'), $B.TrimEnd('\', '/'), $cmp)
}

function Get-OwnedTempRefusal {
    <# Returns the reason a path may not be deleted, or $null when every check holds. Reads the filesystem; changes nothing. #>
    param([string] $Path, [string] $TempRoot, [string[]] $ProtectedPath)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'empty path' }
    if ($Path -match '[*?\[\]]') { return 'wildcard characters in path' }
    if (-not [IO.Path]::IsPathRooted($Path)) { return 'path is not absolute' }
    if ([string]::IsNullOrWhiteSpace($TempRoot)) { return 'no temp root' }
    $protectedList = @($ProtectedPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not $protectedList.Count) { return 'no protected path supplied, so a poisoned temp root cannot be ruled out' }

    $full = Get-OwnedTempFullPath $Path
    $root = Get-OwnedTempFullPath $TempRoot
    if (Test-OwnedTempSame $root ([IO.Path]::GetPathRoot($root))) { return 'temp root is a filesystem root' }
    foreach ($protected in $protectedList) {
        $p = Get-OwnedTempFullPath $protected
        if ((Test-OwnedTempSame $root $p) -or (Test-OwnedTempInside $p $root)) { return "temp root '$root' is or contains protected path '$p'" }
    }
    if (Test-OwnedTempSame $full $root) { return 'path is the temp root itself' }
    if (-not (Test-OwnedTempInside $full $root)) { return "path is not inside the temp root '$root'" }

    try { $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop } catch { return "cannot inspect the temp root: $($_.Exception.Message)" }
    if (-not $rootItem.PSIsContainer) { return 'temp root is not a directory' }
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { return "temp root '$root' is a reparse point" }

    $walk = $root
    foreach ($segment in ($full.Substring($root.Length + 1) -split '[\\/]')) {
        $walk = Join-Path $walk $segment
        if (-not (Test-Path -LiteralPath $walk)) { break }
        try { $item = Get-Item -LiteralPath $walk -Force -ErrorAction Stop } catch { return "cannot inspect '$walk': $($_.Exception.Message)" }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return "'$walk' is a reparse point" }
    }
    if ((Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath $full -PathType Container)) { return 'path is not a directory' }
    return $null
}

function Remove-OwnedTempTree {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string] $Path,
        [string] $TempRoot = [IO.Path]::GetTempPath(),
        [string[]] $ProtectedPath = @($HOME, $env:USERPROFILE, $env:HOME)
    )
    $reason = Get-OwnedTempRefusal -Path $Path -TempRoot $TempRoot -ProtectedPath $ProtectedPath
    if ($reason) { throw "Refusing to delete '$Path': $reason" }
    $full = Get-OwnedTempFullPath $Path
    if (-not (Test-Path -LiteralPath $full)) { return }
    Write-Information "Remove-OwnedTempTree: $full" -InformationAction Continue
    if ($PSCmdlet.ShouldProcess($full, 'Remove recursively')) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
}
