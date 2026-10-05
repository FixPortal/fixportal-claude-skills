---
name: audit-dotnet-estate
description: Use when auditing or comparing multiple .NET/C# repositories for integrated estate conformance across solution structure, shared code style, formatting, tests, documentation, and CI. Use audit-dotnet-analyzers for analyzer diagnostic or provenance investigations, audit-tests for test adequacy, and audit-ci for CI-only comparisons.
---

# Audit .NET Estate

## Overview

Run one evidence-backed, read-only conformance sweep across the .NET estate. Read the
current scaffold skills as the standard, save one vault report, and include one
self-contained remediation prompt for each non-conforming repository.

**The audit reports; it never remediates.** Do not edit repositories, create branches or
worktrees, commit, push, open PRs, or invoke scaffold skills to make changes. Restore,
build, test, formatter-check, and analyzer commands may create normal ignored outputs.

## Sources of truth

Read these skills completely at audit time; values such as tool versions and action pins
drift, so do not copy them into this skill:

- **REQUIRED:** `scaffold-dotnet`
- **REQUIRED:** `scaffold-tests`
- **REQUIRED:** `scaffold-ci` and `audit-ci` for the CI dimension
- **REQUIRED:** `scaffold-doc` for the vault report
- **OPTIONAL COVERAGE SOURCE:** `audit-dotnet-performance`'s report contract and
  publication validator, when that skill is installed and its report directory is
  accessible. Use them only to classify existing audit coverage.

Use `audit-ci`'s evaluation mechanics, but consolidate its evidence into this audit. This
skill's single-report contract overrides `audit-ci`'s standalone sweep-report location.

Use applicable user and repository `AGENTS.md` instructions as higher-priority
constraints. Repository configuration is evidence, not the standard. A deviation counts
as `Compliant with exception` only when an explicit, scoped, current instruction or ADR
states the deviation and its rationale. A suppression or existing setting alone is not an
exception.

Build a rule ledger before auditing repositories. For every rule record its source,
applicability test, evidence check, and whether it is required or advisory. Do not grade a
dimension that the source skills do not define.

Declare `Audit mode` before collecting repository evidence:

- `Independent` — freeze current evidence before reading prior reports.
- `Baseline-assisted` — prior reports may guide collection, but every check records
  `Evidence origin` as `inherited`, `rechecked`, or `new`.

Inherited evidence is not independent corroboration. Record an absolute observation time,
repository SHA, command or static source, and evidence origin; never carry relative wording
such as "today" from a prior report.

Only normative requirements enter the ledger. Examples, explanatory version thresholds,
and descriptions of future behavior are context, not mandatory pins. Before enforcing an
exact tool command, package version, action pin, or other mechanically verifiable fact,
compare it with the authoritative installed metadata or configured upstream source. When
the source skill contradicts that evidence, or requires a release absent from a reachable
authoritative feed, record one `Baseline defect`, exclude that rule from repository grading
and remediation prompts, and continue with the remaining rules. If the authoritative source
cannot be queried, mark only the baseline validation `Not assessed`; never turn uncertainty
about the standard into a repository failure.

## Scope and discovery

The estate root must be supplied explicitly. The report directory defaults to the path
below and may be overridden:

| Setting | Value |
|---|---|
| Estate root | `<estate-root>` — the parent folder holding the repositories; supply it explicitly |
| Report directory | `<vault>/Claude/Estate Audit/Dotnet` |
| Candidate | Git repository containing at least one `.slnx` or `.sln` |

Explicit repository paths or estate roots are required inputs.

For each estate root:

1. Include the root itself when it is a Git repository; otherwise inspect its immediate
   child directories.
2. Keep physical checkouts with a `.git` directory. Exclude linked worktrees whose `.git`
   is a file, GitHub-archived repositories when that state is verifiable, and paths under
   `.audit-worktrees`, `.worktrees`, `.claude`, `.codex`, `archive`, `archives`, `vendor`,
   `third_party`, `node_modules`, `bin`, or `obj`.
3. Keep repositories containing `.slnx` or `.sln` anywhere in the tracked tree. A
   `.sln`-only repository remains a candidate. Existing solution formats are conforming
   unless migration is explicitly authorized by an applicable scoped instruction or ADR;
   `.slnx` is required for new solutions and authorized migrations, not retroactively for
   every existing repository.
4. Ignore loose `.csproj` or C# files unless the user supplied that repository explicitly.
5. List every excluded or skipped repository and the reason in the report. Never silently
   broaden the scan to archives, vendor trees, linked worktrees, or loose source.

Record path, remote, branch, HEAD SHA, dirty state, solution files, SDK selection, and
applicable scoped instructions before running checks.

### Performance audit coverage (informational, non-graded)

For each candidate, inspect the newest paired performance report and manifest in the
location defined by `audit-dotnet-performance`. Group pairs by the filename timestamp and
select the latest minute. Validate every manifest in that minute; if any fails, classify
the coverage `Not assessed` without falling back. Otherwise select the greatest
`audit.completedUtc`, breaking an exact tie by ordinal full filename, then compare
`repository.head` with the estate audit's HEAD:

- `Current` — the newest valid manifest matches HEAD.
- `Stale` — the newest valid manifest records another commit.
- `Not found` — the report location is accessible but has no paired audit.
- `Not assessed` — the skill or validator is unavailable, the location is unavailable, or
  the newest pair cannot be validated.

Record the status, manifest path, audited HEAD, completion time, and reason when not
current; use `—` for fields unavailable under `Not found` or `Not assessed`. This proves
coverage and manifest validity only, not report quality or independent immutability.

Under the `Performance audit coverage` label, report three separate named values rather
than an overloaded count:

- `Audit freshness` — the `Current`, `Stale`, `Not found`, or `Not assessed` result above.
- `Audit depth` — schema v2 `audit.depth`; report immutable schema v1 output as
  `Legacy-unspecified`, never infer depth from an empty findings array.
- `Retained harness` — `Retained`, `Promotion candidate`, `None`, or `Not assessed`.

In the estate matrix, render those values in one compact cell as
`Freshness: <value>; Depth: <value>; Harness: <value>`. Label the test dimension
`Test conformance`: it covers the structural and execution checks sourced from
`scaffold-tests`, not the risk-based adequacy review performed by `audit-tests`.

Classify a retained harness from the current tracked repository independently of audit freshness:
a BenchmarkDotNet project, an explicitly opt-in performance qualification with its documented
command, or a repository-owned load/qualification executable with correctness checks qualifies.
Free-form timing snippets do not. A v2 `Promote` workload is `Promotion candidate` until the
proposed destination exists in the tracked tree. Use `Not assessed` when bounded discovery is
incomplete. This separation preserves useful harness coverage when a promotion commit makes the
immutable audit SHA stale.

Performance audit coverage never changes a check result, repository verdict, finding, or
remediation prompt. Never invoke `audit-dotnet-performance`, build, test, benchmark, or
profile to fill a coverage gap; hand stale, missing, and unavailable entries off as future
one-repository-at-a-time audits.

After discovering the solution format and findings, run
`scripts/get-remediation-plan.ps1` with `SolutionFormat`,
`SolutionMigrationAuthorized`, `CSharpierWidthMigration`, and `HasOtherFindings`.
Use its `SolutionAction` for solution-format grading and its `PullRequests` unchanged when
shaping remediation. Do not independently infer either policy in prose.

Two of those inputs are judgements, and both are DEFINED HERE. This skill forbids reasoning
about the policy in prose, so leaving the predicates undefined meant two operators passing
different values for identical evidence and getting different PR plans:

- **`CSharpierWidthMigration` is true when adopting the house print width would reformat
  files this audit is not otherwise touching** — `dotnet csharpier check .` fails on files
  carrying no other finding. That reformatting is what earns a standalone PR: a width
  migration mixed into a findings PR buries the review. It is false when CSharpier is
  already clean, or when its only failures are in files the remaining findings change
  anyway.
- **`SolutionFormat` names the solution that GOVERNS the repository** — the one CI builds.
  A repository holding both a `.sln` and a `.slnx`, or one mid-migration, is graded on
  whichever CI actually invokes, and the evidence record says which. There is no `mixed`
  value because a build has one entry point, and grading against a file CI never opens
  grades nothing.

## Audit workflow

Use a task per candidate so the sweep survives compaction. Complete one repository's
evidence record before moving to the next.

### 1. Preserve state

<!-- routing: preserve-state -->
Capture `git status --short --untracked-files=all` before and after each repository. Do not
clean, reset, revert, stash, or otherwise alter user state. If an audit command changes a
tracked or meaningful untracked file, stop checks for that repository, mark it
`Incomplete`, and report the change without deleting it.

### 2. Evaluate every applicable scaffold rule

<!-- routing: evaluate-scaffold-rules -->
Derive the checklist from the source skills rather than this summary. At minimum, cover:

- solution/project layout, `.slnx`, target frameworks, central package management,
  nullable/implicit usings, and repository support files;
- `<YourOrg.CodeStyle>`, thin `.editorconfig`, analyzer ownership, package-source mapping,
  Roslyn diagnostics, and justified local overrides;
- CSharpier's current pinned local-tool setup, ignore and line-ending files, absence of
  competing integrations, formatting conformance, CI check, and contributor commands;
- applicable test-project structure, packages, runner configuration, assertions, mocking,
  and obvious timing anti-patterns from `scaffold-tests`;
- CI conformance using `audit-ci`/`scaffold-ci`, including checks not represented by a
  repository file such as CodeQL default setup — a `Fail` whose only defect is a GitHub
  SETTING is a settings finding: it is corrected by an API/UI disposition, and never
  justifies an empty PR; and
- documentation conformance using `scaffold-doc`.

Also evaluate conditional rules from the source skills only when repository evidence makes
them applicable. Do not turn a structural standardisation sweep into a general code,
security, architecture, dependency-vulnerability, or test-adequacy review.

That exclusion limits investigation scope; it does not weaken required execution gates. A
required restore, Release build, test, formatter, or analyzer command returning non-zero is
`Fail`, even when the decisive cause is a dependency advisory, flaky test, or application
defect. Record that smallest cause without expanding into a general vulnerability or
test-adequacy review.

Text presence is not configuration evidence. Ignore comments and examples, and verify an
active assignment in an applicable section. For `.editorconfig`, pass
`scripts/get-editorconfig-assignment.ps1` a concrete tracked C# file and the key. The helper
walks applicable nested files and returns the effective assignment with its source path and
section; a commented value or one under an unrelated glob does not configure that file.

### 3. Run the smallest decisive checks

<!-- routing: run-decisive-checks -->
Prefer repository-declared CI commands. Where applicable and available, run read-only
equivalents for:

- local tool restore and `dotnet csharpier check .`;
- Release restore/build/test for each solution entry point;
- Roslyn semantic style/analyzer verification with `dotnet format --verify-no-changes`;
- the repository's established ReSharper InspectCode command, or InspectCode against each
  solution when a compatible `jb` tool is already resolvable; and
- CI inspection from `audit-ci`, including live settings/API checks when credentials allow.

Do not install global tools, upgrade packages, run `dotnet csharpier format`, run mutating
`dotnet format`, or invent a replacement check. A missing executable, credential, service,
or SDK is `Not assessed`, never a pass. Capture the exact command, exit code, and minimal
decisive output; keep giant logs out of the report.

### 4. Classify consistently

<!-- routing: classify -->

| Check result | Meaning |
|---|---|
| `Pass` | The check executed or static evidence proved conformance. |
| `Fail` | Evidence proves an applicable house rule is violated. |
| `Not applicable` | The rule's applicability condition is false. |
| `Compliant with exception` | A valid documented exception authorizes the deviation. |
| `Not assessed` | Environment, tooling, auth, or time prevented a decisive check. |

Repository verdicts are `Compliant`, `Non-conforming`, or `Incomplete`. Any `Fail` makes
the repository non-conforming. Otherwise, any required `Not assessed` makes it incomplete.
Exceptions remain visible but do not fail the repository.

Each finding must name the repository, rule source, observed evidence, expected state,
smallest remediation, and an exact acceptance check. Deduplicate repeated root causes
within a repository; do not create one finding per symptom.

## Report contract

<!-- routing: report -->
Write exactly one Markdown report to the default or overridden report directory. Name it
`YYYY-MM-DD-HHmm-dotnet-estate-audit.md`; if it exists, append `-02`, `-03`, and so on.
Never overwrite an existing vault file.

Follow `scaffold-doc`'s vault conventions and use this order:

1. YAML frontmatter and orientation blockquote.
2. Executive summary with candidate, compliant, non-conforming, incomplete, and excluded
   counts.
3. A load-bearing verdict distribution diagram.
4. Scope, exclusions, audit environment, and source-of-truth ledger, including any
   `Baseline defect` or baseline-validation `Not assessed` entries.
5. Estate conformance matrix: one row per candidate, with each major dimension, a
   `Test conformance` column, the non-graded `Performance audit coverage` column in the
   compact format above, and the repository verdict.
6. Cross-estate findings, surprising and repeated issues first.
7. Per-repository evidence: identity, `Test conformance`, `Performance audit coverage`
   with its separate freshness/depth/harness evidence and handoff, a check table with
   `Evidence origin` and `Observed at` columns, exceptions, unavailable checks, and
   numbered findings.
8. Remediation prompts: one prompt per `Non-conforming` repository; none for compliant or
   merely incomplete repositories.
9. Audit actions ledger recording read-only checks and confirming that no remediation ran.
10. Appendix containing exact commands and untruncated repository identifiers.

Use these exact level-2 headings, once each and in that order:

`Executive summary`, `Verdict distribution`, `Scope and source-of-truth`,
`Estate conformance matrix`, `Cross-estate findings`, `Per-repository evidence`,
`Remediation prompts`, `Audit actions ledger`, and `Appendix`.

Draft outside the vault, run `scripts/test-estate-report.ps1 -Path <draft>`, and publish
to the unused final filename only after it passes. A validator failure forbids publication.

Do not create a report bundle, CSVs, evidence folders, or separate prompt files. Link the
single report in the final response.

## Remediation prompt contract

<!-- routing: remediation-prompt -->

Every remediation prompt must be copy-ready for a fresh agent and contain:

```markdown
### Remediate <repository>

Repository: <absolute path>
Audit snapshot: <HEAD SHA>
Findings: <all finding IDs>
Solution action: <the emitted SolutionAction>
PR plan: <one ordered entry per emitted PullRequests item>

#### Outcome
Resolve every listed finding using the recorded PR plan above.

#### Required context
- Read all applicable AGENTS.md files and repository documentation.
- Use the current scaffold skills named by each finding as the desired state.
- Confirm the audit SHA and report material drift before editing.
- Follow the dedicated review-worktree and numbered reviewer-branch rules applicable to
  this repository; do not work in its primary checkout.

#### Finding checklist
- [ ] <ID> — <title>
  - Evidence: <decisive evidence>
  - Required change: <smallest root-cause correction>
  - Acceptance: `<exact command or static check>`

#### Constraints
- Follow the emitted PR purposes exactly. A `CSharpierFormatting` PR contains only the
  formatter configuration and mechanical reformat; `RemainingFindings` contains every
  other finding. `AllFindings` is the normal single-PR plan.
- Do not change another repository, suppress diagnostics to obtain a pass, edit the audit
  report, or perform unrelated refactoring.
- Preserve unrelated work and follow the repository's test, commit, PR, review, and merge
  instructions.

#### Verification and return
Run every finding's acceptance check plus the repository's normal formatting check,
Release build, and tests. Return each applicable branch, commits, PR URL,
finding-to-change mapping, verification results, and remaining blockers.
```

Populate every field from evidence. Do not leave placeholders or tell the remediation
agent to rediscover what the audit already established.

## Common mistakes

| Mistake | Correction |
|---|---|
| Treating current repo config as the standard | Read the current scaffold skills first. |
| Treating examples or future-version notes as required pins | Admit only normative requirements to the rule ledger. |
| Enforcing a scaffold fact contradicted by authoritative metadata | Record one `Baseline defect`; do not fail or remediate repositories for it. |
| Checking CSharpier only where already configured | Its absence is drift when the current standard requires it. |
| Fixing an obvious issue during the audit | Record it and generate the repository prompt. |
| Auditing worktrees, archives, loose projects, or vendor code | Keep the agreed Git-repository candidate boundary. |
| Treating unavailable InspectCode or API access as pass | Mark the check `Not assessed` and the verdict `Incomplete` when required. |
| Producing many evidence and prompt files | Produce one vault report. |
| Generating one PR or prompt per finding | Consolidate all findings into one prompt and one PR per repository, except the required standalone CSharpier width reformat. |

## Red flags — stop

- About to edit, branch, commit, push, or open a PR in an audited repository.
- About to run `format` rather than a check/verify mode.
- About to infer a rule from estate majority practice instead of a source skill.
- About to generate repository remediation for an unavailable or mechanically false baseline requirement.
- About to omit an excluded repository, exception, or unavailable check from the report.
- About to publish a report without a copy-ready prompt for every non-conforming repo.
