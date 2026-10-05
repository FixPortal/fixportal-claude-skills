[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $File,

    [Parameter(Mandatory)]
    [string] $VerifierRoot,

    [string] $DiagramSkillRoot = (Join-Path $HOME '.agents/skills/diagram-design')
)

$ErrorActionPreference = 'Stop'

$diagramFile = (Resolve-Path -LiteralPath $File -ErrorAction Stop).Path
try {
    $verifierRootPath = (Resolve-Path -LiteralPath $VerifierRoot -ErrorAction Stop).Path
}
catch {
    throw "diagram verifier root does not exist: $VerifierRoot"
}
try {
    $skillRootPath = (Resolve-Path -LiteralPath $DiagramSkillRoot -ErrorAction Stop).Path
}
catch {
    throw "diagram-design skill root does not exist: $DiagramSkillRoot"
}

$checks = @(
    Join-Path $skillRootPath 'scripts/self_check.py'
    Join-Path $verifierRootPath 'scripts/verify-geometry.py'
    Join-Path $verifierRootPath 'scripts/lint-skin.py'
)
$python = @('python3', 'python') |
    ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $python) {
    throw 'Python interpreter not found on PATH; install python3 or python'
}

foreach ($check in $checks) {
    if (-not (Test-Path -LiteralPath $check -PathType Leaf)) {
        throw "required diagram verifier does not exist: $check"
    }
    # The CommandInfo itself, not `.Source`. `.Source` is the executable path only for an
    # Application; for an alias or a shell function named `python` - which is how a
    # pyenv or conda shim commonly lands on PATH - it is the module name or empty, and
    # `& ''` then fails with a message about an empty command rather than about python.
    # Invoking the CommandInfo works for every command type.
    & $python $check $diagramFile
    if ($LASTEXITCODE -ne 0) {
        throw "diagram verifier failed with exit code $LASTEXITCODE`: $check"
    }
}

'diagram verifier suite OK'
