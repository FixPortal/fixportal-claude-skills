$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$main = Get-Content (Join-Path $root 'SKILL.md') -Raw
$runner = Join-Path $root 'scripts' 'run-diagram-verifiers.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('scaffold-doc-' + [guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
$words = ([regex]::Matches($main, '\b[\p{L}\p{N}][\p{L}\p{N}''.-]*\b')).Count

if ($words -gt 500) { throw "SKILL.md is $words words; templates and reference detail belong in references" }
if ($main -match 'document this estate/system') { throw 'broad architecture trigger still overlaps document-architecture' }
foreach ($needle in 'supplied findings or content', 'Do not use for discovering, mapping, or analyzing', 'document-architecture') {
    if ($main -notmatch [regex]::Escape($needle)) { throw "missing selector boundary: $needle" }
}

foreach ($name in 'conventions.md','templates.md','report-shape.md','common-mistakes.md','diagram-renderers.md') {
    if (-not (Test-Path (Join-Path $root "references" "$name"))) { throw "missing reference: $name" }
    # The SKILL.md -> references/ split left "above"/"below" pointers behind in files where
    # the target no longer sits above or below anything - the sub-templates moved to
    # templates.md. A deictic reference across a file boundary can only ever be wrong, so
    # they must be real links.
    $refText = Get-Content (Join-Path $root 'references' $name) -Raw
    foreach ($dangling in 'sub-template\*? below', 'sub-templates above', '§\*README sub-template\*') {
        if ($refText -match $dangling) { throw "references/$name has a dangling cross-file pointer: $dangling" }
    }
}

foreach ($needle in 'Choose the destination first', 'Core conventions', 'Compact checklist') {
    if ($main -notmatch [regex]::Escape($needle)) { throw "main router missing: $needle" }
}

$conventions = Get-Content (Join-Path $root 'references' 'conventions.md') -Raw
$mistakes = Get-Content (Join-Path $root 'references' 'common-mistakes.md') -Raw
$templates = Get-Content (Join-Path $root 'references' 'templates.md') -Raw
$reportShape = Get-Content (Join-Path $root 'references' 'report-shape.md') -Raw
$diagramRenderers = Get-Content (Join-Path $root 'references' 'diagram-renderers.md') -Raw
$docs = $main, $conventions, $mistakes, $templates, $reportShape, $diagramRenderers

if (($docs -join "`n") -match '(?i)without tags? (?:are|is) invisible in (?:the )?Obsidian graph view') {
    throw 'scaffold-doc must not claim that untagged notes are invisible in Obsidian Graph view'
}
if (($docs -join "`n") -match '(?i)(?:standalone )?GitHub(?:-only)? README may (?:use|retain) frontmatter') {
    throw 'scaffold-doc must not recommend YAML frontmatter for an ordinary GitHub README'
}
if ($conventions -notmatch '(?i)untagged notes .* graph') {
    throw 'conventions must state that untagged notes remain visible in Graph view'
}
if ($conventions -notmatch '(?is)ordinary GitHub README .* do not' -or
    $conventions -notmatch '(?is)omit it there') {
    throw 'conventions must scope frontmatter to destinations that consume it'
}

# The vault destination has its own SOURCE wrapping rule, distinct from the rendered
# page width that follows it in conventions.md. Set 2026-08-15 (292 notes reflowed),
# re-broken 2026-09-13 by a vault document written straight past it - so it belongs in
# the skill that writes vault documents, not only in a memory line.
if ($conventions -notmatch '(?is)vault documents are never hard-wrapped' -or
    $conventions -notmatch '(?is)one paragraph per line') {
    throw 'conventions must forbid hard-wrapping Obsidian vault documents'
}
if ($conventions -notmatch '(?is)stays hard-wrapped at roughly 78 columns') {
    throw 'conventions must keep repo-committed Markdown hard-wrapped'
}
if ($mistakes -notmatch '(?is)Hard-wrapped prose in an Obsidian vault document') {
    throw 'common mistakes must list hard-wrapped vault prose'
}

foreach ($guide in $conventions, $mistakes) {
    foreach ($needle in 'tags alone do not decide visibility', 'Graph Search', 'tag filter', 'Orphans toggle', 'excluded-file patterns') {
        if ($guide -notmatch "(?is)$([regex]::Escape($needle))") {
            throw "scaffold-doc must describe the Obsidian visibility control: $needle"
        }
    }
}
if ($reportShape -notmatch '(?is)parser-backed\s+destination') {
    throw 'report shape must make the frontmatter skeleton conditional on a parser-backed destination'
}
if ($reportShape -notmatch '(?is)ordinary repo/GitHub reports .* omit .* frontmatter') {
    throw 'report shape must omit frontmatter for ordinary repo/GitHub reports'
}

foreach ($placeholder in '<clone>', '<skill-dir>') {
    if ($diagramRenderers -match [regex]::Escape($placeholder)) {
        throw "diagram verifier command retains unresolved root: $placeholder"
    }
}
foreach ($needle in '$diagramVerifierRoot = Resolve-Path $env:DIAGRAM_DESIGN_VERIFIER_ROOT',
                    '$diagramVerifierRunner = Join-Path $scaffoldDocRoot ''scripts/run-diagram-verifiers.ps1''',
                    'Test-Path -LiteralPath $diagramVerifierRunner -PathType Leaf',
                    'pwsh -NoProfile -File $diagramVerifierRunner -File $diagramFile -VerifierRoot $diagramVerifierRoot') {
    if ($diagramRenderers -notmatch [regex]::Escape($needle)) {
        throw "diagram verifier root is not executable or owned: $needle"
    }
}
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw 'diagram verifier runner is missing'
}

try {
    $skillRoot = Join-Path $tempRoot 'diagram-design'
    $verifierRoot = Join-Path $tempRoot 'verifiers'
    $diagram = Join-Path $tempRoot 'diagram.html'
    $log = Join-Path $tempRoot 'invocations.log'
    $commandRoot = Join-Path $tempRoot 'commands'
    New-Item -ItemType Directory -Path (Join-Path $skillRoot 'scripts'), (Join-Path $verifierRoot 'scripts'), $commandRoot -Force | Out-Null
    Set-Content -LiteralPath $diagram -Value '<svg></svg>' -NoNewline
    $stub = @'
import os
import pathlib
import sys
with pathlib.Path(os.environ["DIAGRAM_VERIFIER_LOG"]).open("a", encoding="utf-8") as stream:
    stream.write(pathlib.Path(__file__).name + "\n")
if not pathlib.Path(sys.argv[1]).is_file():
    raise SystemExit(2)
'@
    Set-Content -LiteralPath (Join-Path $skillRoot 'scripts' 'self_check.py') -Value $stub
    Set-Content -LiteralPath (Join-Path $verifierRoot 'scripts' 'verify-geometry.py') -Value $stub
    Set-Content -LiteralPath (Join-Path $verifierRoot 'scripts' 'lint-skin.py') -Value $stub
    $env:DIAGRAM_VERIFIER_LOG = $log
    $actualPython = @('python3', 'python') |
        ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $actualPython) { throw 'test fixture needs python3 or python' }
    $env:DIAGRAM_TEST_PYTHON = $actualPython.Source
    Set-Content -LiteralPath (Join-Path $commandRoot 'python3.ps1') -Value @'
& $env:DIAGRAM_TEST_PYTHON @args
exit $LASTEXITCODE
'@

    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $env:PATH = $commandRoot
    $fallbackOutput = & $pwsh -NoProfile -File $runner -File $diagram -VerifierRoot $verifierRoot -DiagramSkillRoot $skillRoot 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "diagram verifier runner rejected a python3-only PATH fixture:`n$fallbackOutput" }
    $invocations = @(Get-Content -LiteralPath $log)
    $expectedInvocations = 'self_check.py', 'verify-geometry.py', 'lint-skin.py'
    if (($invocations -join ',') -ne ($expectedInvocations -join ',')) {
        throw "diagram verifier runner did not invoke every resolved script (got: $($invocations -join ', '))"
    }

    $env:PATH = Join-Path $tempRoot 'no-python'
    New-Item -ItemType Directory -Path $env:PATH | Out-Null
    $missingPythonOutput = & $pwsh -NoProfile -File $runner -File $diagram -VerifierRoot $verifierRoot -DiagramSkillRoot $skillRoot 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $missingPythonOutput -notmatch 'python3 or python') {
        throw 'diagram verifier runner must fail clearly when no Python interpreter is on PATH'
    }
    $env:PATH = $originalPath

    $missingRootOutput = & pwsh -NoProfile -File $runner -File $diagram -VerifierRoot (Join-Path $tempRoot 'missing') -DiagramSkillRoot $skillRoot 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $missingRootOutput -notmatch 'verifier root') {
        throw 'diagram verifier runner must fail when the explicit verifier root is missing'
    }

    Remove-Item -LiteralPath (Join-Path $verifierRoot 'scripts' 'lint-skin.py')
    $missingScriptOutput = & pwsh -NoProfile -File $runner -File $diagram -VerifierRoot $verifierRoot -DiagramSkillRoot $skillRoot 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $missingScriptOutput -notmatch 'lint-skin.py') {
        throw 'diagram verifier runner must fail when a required script is missing'
    }
}
finally {
    Remove-Item Env:DIAGRAM_VERIFIER_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:DIAGRAM_TEST_PYTHON -ErrorAction SilentlyContinue
    $env:PATH = $originalPath
    if ($tempRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

"scaffold-doc contract OK — $words words"
