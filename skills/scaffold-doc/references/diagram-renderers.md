# Choosing the diagram renderer

Read this before drawing anything. Two renderers are available and they are not interchangeable.

## Route by what the figure is FOR, not by where the file is stored

The first cut of this rule routed on destination — Mermaid for repo-committed Markdown, `diagram-design` for decks. It was wrong, and it was wrong in a specific way worth remembering: it sent a walk-someone-through-it architecture guide to Mermaid purely because the file lived in `docs/`. Storage location is not the signal. Ask what the figure has to do.

| The figure's job | Renderer | Why |
|---|---|---|
| **Track a moving target.** It describes code that changes, it is edited in the same pull requests, and its readers are the people maintaining it. | **Mermaid**, fenced inline | Diffs as text, so a reviewer sees exactly which edge changed; renders natively on GitHub; follows the reader's light/dark theme with no extra work |
| **Land with a reader who is not the author.** Onboarding, an architecture guide, hand-over or interview material, a client-facing summary, a talk, a hero figure. | **`diagram-design` skill** | Deliberate layout, brand skin, enforced focal hierarchy and node budget. Comprehension *is* the deliverable, and it wins the trade |

A repo-committed Markdown document can be either. A README whose one diagram is a module tree nobody reads twice is the first row. A `docs/` guide written so someone can explain the system out loud is the second — and living in `docs/` says nothing about which.

**When the rows pull in different directions, ask what the document is for.** If a reader opens it to *understand the system* rather than to *maintain the description of it*, the figure is doing communication work. Spend the hour.

> [!NOTE]
> The node budget is part of the value, not a tax on it. Being pushed under nine nodes reliably
> surfaces that some box was standing in for a label, or that two boxes were always one thing. Those
> edits improve the Mermaid version too, so the exercise is worth running even when the answer is
> row one.

Invoke `diagram-design` through the Skill tool. **Never hand-author branded SVG inside `scaffold-doc`** — that skill owns the skin, the focal rule, the connector grammar and three checkers this one does not have. If `diagram-design` is not installed in the environment you are running in, fall back to Mermaid and note the substitution in the document — the routing table above still applies.

## Mixing them in one document

A `diagram-design` figure is a committed SVG or PNG asset referenced by path. It does not render from a fence, so it cannot be the default for a document that will be edited.

Promoting a single figure is the supported pattern, and usually the right one:

1. Regenerate that one figure through `diagram-design`.
2. Commit the asset beside the document.
3. Keep the Mermaid source in the file as the maintained version.

Do not convert a whole document. The cost is per-figure and so is the benefit.

## Three constraints before choosing `diagram-design`

**Single-theme.** Generated files carry literal hex values, so a figure commits to light or dark. In a theme-aware page it needs a pinned plate behind it, or two maintained files per figure. A Mermaid fence has no such problem.

**Nine-node budget, enforced.** Usually a feature rather than a limit: being pushed under it tends to surface that a node was standing in for a label, or that two boxes were really one. But it will force an edit, so do not reach for it when the diagram genuinely needs to be dense — split it instead.

**Cost.** Roughly an order of magnitude more authoring effort than a Mermaid fence, because every coordinate is placed by hand on a 4px grid. Spend it where the figure is the deliverable rather than documentation of a moving target.

## Validating either one

The installed `diagram-design` skill ships its portable self-check, but its
geometry and skin gates live only in a full verifier checkout. Set
`DIAGRAM_DESIGN_VERIFIER_ROOT` to the root of that checkout, the directory whose
`scripts/` holds `verify-geometry.py` and `lint-skin.py`; the runner fails closed
when the root or any required script is absent. No machine-specific clone path is
assumed.

**Where that checkout comes from.** The verifier scripts
(`scripts/verify-geometry.py`, `scripts/lint-skin.py`) are not part of the installed
skill — the install carries `scripts/self_check.py` and nothing else — so on a machine
that has only ever installed the skill, the root does not exist and the runner is
fail-closed by design rather than misconfigured. Acquire it by cloning the upstream
repository and pointing the variable at the clone's root. The installed skill does not
record where it came from — its frontmatter carries only name, description, licence and
version — so the source is stated here: `https://github.com/cathrynlavery/diagram-design`,
listed on skills.sh as `cathrynlavery/diagram-design@diagram-design`. Checked 2026-09-25:
an installed `SKILL.md` (version 2.3) was byte-identical to that repository's
`skills/diagram-design/SKILL.md` at commit `a5e3978088cf89c7caff5c20cabd99fbc2a301de`,
and the verifiers sit at the repository root under `scripts/`. Nothing here vendors or
fetches the checkout, deliberately: it is third-party code.

**Pin the revision and record it.** These scripts are third-party Python that the runner
EXECUTES, so a floating clone means the gate's behaviour changes without a review — the
same mutable-dependency problem a review-bound skill install exists to close. Check out a
reviewed tag or commit, not a branch:
`git -C <verifier-root> checkout --detach <reviewed-sha>`, verify it with
`git -C <verifier-root> rev-parse HEAD`, and record that SHA beside the gate result. A
verifier whose revision is not recorded has produced an unattributable pass.

If the checkout is unavailable, the geometry and skin gates are **not run**, and that
is a coverage gap to state — say which gates were skipped and why. The portable
self-check passing on its own is not a substitute for them and must not be reported as
one.

```powershell
$diagramVerifierRoot = Resolve-Path $env:DIAGRAM_DESIGN_VERIFIER_ROOT
```

Resolve the file and installed runner:

```powershell
$diagramFile = Resolve-Path './diagram.html'
```

```powershell
$scaffoldDocRoot = Resolve-Path (Join-Path $HOME '.agents/skills/scaffold-doc')
```

```powershell
$diagramVerifierRunner = Join-Path $scaffoldDocRoot 'scripts/run-diagram-verifiers.ps1'
```

Assert that the runner exists, then run all three Python verifiers. The runner
also asserts each child script exists before invoking it.

```powershell
if (-not (Test-Path -LiteralPath $diagramVerifierRunner -PathType Leaf)) { throw "Diagram verifier runner not found: $diagramVerifierRunner" }
```

```powershell
pwsh -NoProfile -File $diagramVerifierRunner -File $diagramFile -VerifierRoot $diagramVerifierRoot
```

Validate Mermaid separately with its pinned parser:

```powershell
npx -y @mermaid-js/mermaid-cli@11.16.0 -i d.mmd -o d.svg
```

> [!NOTE]
> On Windows, `diagram-design`'s `mermaid_extract.py` fails on the default console encoding —
> `UnicodeEncodeError: 'charmap' codec can't encode character '⏎'` — because its digest emits a
> line-break glyph cp1252 cannot represent. Set the encoding in the same call, using the syntax of
> the shell you are actually in:
>
> - PowerShell — `$prev = $env:PYTHONIOENCODING; try { $env:PYTHONIOENCODING='utf-8'; python <script> <file> } finally { $env:PYTHONIOENCODING = $prev }`
>   (a bare `$env:PYTHONIOENCODING='utf-8'; python ...` mutates the caller's session;
>   the `try`/`finally` scopes it to the one call)
> - cmd.exe — `set PYTHONIOENCODING=utf-8 && python <script> <file>`
> - bash — `PYTHONIOENCODING=utf-8 python <script> <file>`
>
> The bare `VAR=value <command>` prefix is POSIX-only: PowerShell rejects it as a parse error and
> cmd treats it as a literal argument. Windows is the primary shell here, so reach for the
> PowerShell form first.
