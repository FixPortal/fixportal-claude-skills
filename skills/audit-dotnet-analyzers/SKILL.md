---
name: audit-dotnet-analyzers
description: Use when a .NET/C# analyzer or code-style diagnostic is in question — a rule is blamed for blocking modern C#, a build-breaking analyzer error forced a code change, .editorconfig / globalconfig / TreatWarningsAsErrors policy needs auditing, analyzer enforcement differs between projects or CI, an SDK or analyzer upgrade needs assessing, or someone says "Sonar wants X". Also for generating a remediation prompt from accepted analyzer findings.
type: prompt
when_to_use: When a .NET/C# analyzer or code-style diagnostic is in question, or someone says "Sonar wants X".
---

# Audit .NET Analyzers

## Overview

Evidence-backed, **read-only** audit of effective .NET analyzer and code-style policy. Establishes which diagnostics actually apply, which analyzer owns each one, how configuration precedence produces the effective severity, and whether a rule genuinely conflicts with intentional modern C#.

**Core principle: a diagnostic is not understood until you can name the rule, the analyzer that emitted it, and the config layer that set its effective severity.** "Sonar wants X" is an evidential smell, not a finding.

## The authority boundary (non-negotiable)

This skill **audits**. It does not remediate.

1. **Review** — the skill discovers facts and recommends dispositions.
2. **Resolution** — the *user* accepts, rejects or constrains each finding.
3. **Remediation** — a separately-chosen agent runs a portable prompt containing only authorised work.

The skill never collapses these. **Its own recommendation is not authorisation.**

### Read-only means read-only

During audit, do not: edit source; edit `.editorconfig`, `*.globalconfig`, MSBuild, project, package or CI config; add suppressions; change severities; install or update anything; commit; or do opportunistic cleanup.

Non-mutating inspection is allowed. `restore`/`build` may populate ignored `obj`/`bin`. Scratch repro projects are fine **outside** the audited repo. Check `git status` before and after; report any unexpected mutation. Preserve a dirty tree — never revert or stash work you did not create.

**"Just sort it out" does not lift the boundary.** Urgency, a demo deadline, "don't give me a menu of options", or an explicit "just fix it" mean *deliver the audit and a ready-to-run remediation prompt fast* — not edit files. If the user wants direct edits with no audit, that is not this skill; say so and stop.

## Two proof obligations

Baseline testing showed capable agents fail in exactly two ways. Both are mandatory checks.

### 1. Never accept the premise

The request will hand you a culprit: *"S3878 is fighting our collection expressions."* **That claim is a hypothesis, not a fact.** Reproduce the diagnostic before you explain, configure around, or accommodate it.

A rule that cannot be reproduced is reported as **unreproducible** — never quietly designed around.

### 2. Prove the actual receiving overload

For any rule about call shape — `params` rules (S3878), collection expressions, array creation, argument patterns — the finding is **not established** until you show the *real receiving method signature and the overload actually selected at that call site*.

**Verifying the rule against a proxy method you wrote is not verification.** Confirming S3878 fires on your own `Foo(params int[])` says nothing about whether it fires on `BeEquivalentTo(...)`. This failure arrives wearing evidence — a real reproduction, of the wrong method — which makes it far more dangerous than hand-waving, and it is the single likeliest way to reach a confident wrong verdict here.

Establish, from the real API: the parameter type, whether it is genuinely `params`, every candidate overload, and which one binds. Then judge.

A control is cheap and worth it: confirm the rule *does* fire on a genuine instance of the pattern, so a non-firing result proves the rule doesn't apply rather than that your rig was dead.

## Modes

| Mode | Trigger |
|---|---|
| Repository audit | "Audit the analyzers in this repo" |
| Finding investigation | "Was this change actually required by <rule>?" |
| Workspace audit | Multiple repos under a folder; compare and find drift |
| Configuration comparison | Drift across repos or shared CodeStyle-package consumers |
| Upgrade readiness | Assess an SDK/analyzer upgrade without applying it |
| Remediation prompt | **Only after** the user resolves findings |

## Workflow

   <!-- routing: scope -->

1. **Scope** — one repo, a workspace, or a single finding.
   <!-- routing: inventory -->

2. **Inventory** — run `scripts/inventory-dotnet-analysis.ps1` for the deterministic sweep (SDK, TFM, LangVersion, analyzer packages, config hierarchy, warning policy). Read `references/audit-checklist.md` for what else to inspect and how to resolve effective config. A non-empty `UnreadablePaths`, `UnreadableFiles`, or `ParseErrors` collection makes every conclusion that depends on the affected path **undeterminable**; never report missing configuration, package references, or bundled analyzer dependencies as absent when their source did not parse.
   <!-- routing: attribute -->

3. **Attribute** — assign every diagnostic to its owning analyzer. Prefix is a hint, not proof: analyzers arrive bundled (a shared CodeStyle package may ship Sonar transitively). Do not attribute to Sonar merely because Sonar is installed.
   <!-- routing: reproduce -->

4. **Reproduce** — see the two proof obligations above.
   <!-- routing: assess -->

5. **Assess** — technical merit against repository intent. Read `references/finding-taxonomy.md` for categories, severity, disposition vocabulary and the report shape.
   <!-- routing: report-and-stop -->

6. **Report** — facts, inferences and recommendations kept visibly distinct. Every finding carries rule ID, analyzer, version, effective severity, config provenance, evidence, confidence.
7. **STOP.** Present findings for resolution. Ask. Do not proceed.
   <!-- routing: remediation-prompt -->

8. **Remediate — only on request, after resolution.** Read `references/remediation-prompt.md`. Emit an agent-neutral, self-contained prompt containing *only* accepted / accepted-with-constraints / validation-authorised findings.

`GitStatusBefore` and `GitStatusAfter` each carry `Success`, `Status`, `ExitCode`, and
`Error`. Mutation proof exists only when both probes succeeded. If either failed,
`Mutated` is null and `MutationState` is `Unknown`: mark the read-only proof incomplete
and report the failed probe rather than treating unknown state as unchanged.

## Modern C# stance

Use the newest constructs the repo's declared C# version supports where they improve clarity, concision or correctness. **Do not replace modern syntax merely to satisfy an analyzer preference.** Resolve a genuine conflict by rule ID through upgrade, configuration, documented exception, or code change — on the rule's technical merit.

Novelty is not a virtue either. Judge clarity, correctness, semantics, maintainability.

Do not recommend disabling correctness or security rules to reduce noise.

## Version currency

Classify as: obsolete/incompatible · behind but supported · current enough · **undeterminable without external verification**. Being behind the newest release is not itself a finding. Offline, say currency was not externally verified — never invent it.

## Artefacts

- Report → `<vault>\Claude\Analyzer Audit\<repo>\<YYYY-MM-DD>.md`
- Remediation prompt → `<vault>\Claude\Prompts\`

Writing these is not a repo mutation. Never write into the audited repo during audit.

If the report path already exists (a re-audit on the same day), write `<YYYY-MM-DD>-2.md` and so on. Vault writes are additive — never overwrite or delete an earlier report, even your own.

## Red flags — STOP

- About to edit `.editorconfig`, `Directory.Build.props`, or a severity — **stop, you are auditing**
- "The user said just fix it, so the read-only rule doesn't apply"
- "I'll apply the obvious ones and report the rest"
- Explaining *why* a rule fires before reproducing *that* it fires
- Confirming a rule on a method you wrote, then concluding about a method you didn't
- Writing "Sonar wants" / "the analyzer requires" with no rule ID and no provenance
- Generating a remediation prompt the user never resolved
- Stating a package is stale with no version evidence

## Rationalizations

| Excuse | Reality |
|---|---|
| "They asked me to sort it out" | Sort it out = audit + ready-to-run prompt. Not edits. |
| "There's a demo in 40 minutes" | Deadline pressure is when unauthorised policy changes get made. Report faster; don't edit. |
| "The fix is obviously correct" | A technically correct fix still invents a policy the owner never chose. Correctness is not authority. |
| "Config isn't really code" | A severity change is a policy decision. It is the owner's, not yours. |
| "I reproduced the rule, so I've verified it" | On *which* method? A proxy proves nothing about the real call site. |
| "The user already told me the rule ID" | That's the hypothesis you're testing, not a premise you inherit. |
| "It's just adding it to WarningsNotAsErrors" | That silently rewrites the repo's enforcement contract. |

## Worked example

**Claim:** *"S3878 is fighting our collection expressions — it wants us to use
`new[]` instead."*

1. **Reproduce on the real receiving method, not a proxy.**
   Find the actual call site flagged by the build. Do not write a scratch
   `Foo(params int[])` to "see if S3878 fires"; that only proves the rule fires
   on *your* method, not on the call site in question.

2. **Prove the actual overload and parameter type.**
   Inspect the real API's metadata or use the compiler/IDE to show the parameter
   type, whether it is genuinely `params`, every candidate overload, and which
   overload the compiler actually selects. Example findings:
   - `MyAssert.Contains(IEnumerable<string> expected, string actual)` — **not**
     `params`, so S3878 is irrelevant here.
   - `Should().BeEquivalentTo(params string[] items)` — genuinely `params`; a
     collection expression can bind directly.

3. **Control: confirm the rule fires on a genuine instance.**
   A quick positive control proves a non-firing result means "does not apply
   here" rather than "my repro was broken".

4. **Verdict options:**
   - **Unreproducible on the real method** — report as unreproducible; do not
     change code.
   - **Reproduces, but the fix degrades clarity** — propose a suppression or
     config change with evidence.
   - **Reproduces and the modern syntax is genuinely better** — propose the code
     change.
   - **Wrong overload selected** — flag as an API-usage bug separate from the
     analyzer.

Every finding must still carry rule ID, owning analyzer, effective severity,
config provenance, evidence, and confidence.
