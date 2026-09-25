# Audit Brief — one skill, five axes, six runtime surfaces

You are auditing **one** skill the user authored. Read its `SKILL.md` (and any
supporting files in its directory). Score the five axes below, **verify every
reference on disk**, and return the JSON contract at the end. Report only —
make no edits to any skill.

## The Iron Law

Every path, file, directory, command, package, and constant the skill names is
**verified by you, now**, with the runtime's filesystem glob/read/search
capabilities, `Test-Path`, a shell existence check, or a package
lookup. **Never** write "verify X exists" and hand it back — that is the failure
this audit exists to prevent. If you named it, you checked it: report RESOLVED or
BROKEN with the evidence (the path you tested, the result).

Use capabilities, not vendor tool names: filesystem glob/read/search, a shell
existence test, and official web or registry lookup. Map those capabilities to
the current runtime's native tools.

## Axis 1 — Reach (trigger reliability)

Grade the frontmatter `description` against `writing-skills` CSO rules:
- State the intended capability and concrete use conditions without summarizing
  the workflow. A process summary is a 🟧 finding because an agent can
  follow it instead of reading the body.
- Third person; starts with "Use when…"; concrete triggers/symptoms/keywords.
- Technology scoping explicit if the skill is technology-specific.
- `name`: letters/numbers/hyphens only. Frontmatter ≤ 1024 chars total.

Note any trigger phrases that look likely to collide with another skill in the
inventory you were given (the main thread confirms overlaps in synthesis — you
just flag candidates).

## Axis 2 — Implementation

Against `writing-skills` structure conventions:
- Required frontmatter present; sensible sections (overview/core principle,
  when-to-use, quick reference, common mistakes as applicable to the type).
- Token-efficient (no bloat; detail pushed to supporting files when heavy).
- Flowcharts only for non-obvious decisions — not for reference or linear steps.
- One good example, not multi-language dilution.
- Internally consistent (steps don't contradict the overview or each other).

## Axis 3 — Correctness of references + conventions

**3a. References (verify each — see Iron Law):**
- File/dir/path constants → `Test-Path` / `Glob`.
- Commands/tools → exist and spelled right.
- Package names → resolve / not renamed (e.g. `FluentAssertions` →
  `AwesomeAssertions` is exactly this rot).
- Internal constants (hardcoded paths like a `VAULT_DIR`) → point at something
  real.
- Cross-references / `[[memory]]` links → the named target exists.

**3b. Convention adherence — open active runtime instructions, cite the rule.**
Read each applicable file that exists: `~/.claude/CLAUDE.md`,
`~/.codex/AGENTS.md`, `~/.kimi-code/AGENTS.md`, and `~/.gemini/GEMINI.md`.
Check only the conventions relevant to this skill's domain. Do NOT assert
"follows conventions" — name the specific rule and whether it is honoured:
- **.NET / scaffold / test skills:** xUnit v3 + NSubstitute + AwesomeAssertions
  (never `FluentAssertions`); assert with `.Should()` not `Assert.*`; NodaTime
  for domain date/time with BCL kept at I/O boundaries and an injected clock;
  prefer one parameterized `[Theory]`.
- **Any skill emitting shell for the user:** single-line copy-pasteable
  PowerShell, no backtick continuation; discrete single-purpose commands (no
  `&&`-chaining allowlisted commands).
- **Config-touching skills:** global scope (`~/.claude/`) default unless the
  change is inherently repo-specific.
- **PR/git skills:** rebase-merge style; review passes in the dedicated review
  worktree.
- **Azure/CI skills:** point at `~/.agents/notes/deploy-and-ci-traps.md`;
  EF/Wolverine/SignalR skills point at `dotnet-runtime-traps.md`.

## Axis 5 — Exposure

**What this skill discloses when its text leaves this machine.** Read
`references/exposure-classes.md` in this skill's directory for the grade table,
the token sweep pattern, and the three classes the pattern cannot catch.

Two steps, in order:

1. **Scope.** From the `homes` you found, name every one that is a **third-party**
   runtime — a runtime configured to a model vendor other than the user's own
   first-party provider. `~/.pi/skills` and `~/.pi/agent/skills` are the current
   case: PI is routinely pointed at OpenRouter-hosted third-party models. If the
   skill is mounted in no third-party home, grade 🟩 and record that as the
   reason. Do not grade content you have established nobody exports.
2. **Content.** Run the token sweep over the skill directory and read for the
   three unscannable classes. Grade to the worst class present.

A skill body is loaded from the runtime's home, **not** from the working
directory, so a workspace sandbox restricts file access and never prompt
contents. Never treat a directory restriction as exposure containment; if a
finding's fix depends on that assumption, the fix is wrong.

Record exposure hits in `exposure_findings`, not `findings` — a skill that
discloses the org name is not technically broken, and mixing the two makes the
defect buckets unreadable.

## Cross-home drift (this skill only)

You were told this skill's path(s). Compare the **six runtime surfaces**:
`~/.claude/skills`, `~/.agents/skills`, `~/.kimi-code/skills`,
`~/.gemini/config/skills`, `~/.gemini/antigravity-cli/skills`, and
`~/.pi/skills` (with `~/.pi/agent/skills`, which PI reads as a second root). If
it exists in two or more, diff the bodies pairwise and report divergence. If it
exists in only one home, report which (e.g. Claude-home-only, or
gemini-home-only for a skill authored only in Antigravity).

Report the cross-home result **only** in the `drift` field — do **not** record
a sibling home as a `references_checked` entry, and never mark an absent
home as a `broken` reference (a single-home skill is not broken). Diverged
bodies are a 🟧 finding; a deliberately single-home skill is `drift` context,
not a finding unless the absence is clearly accidental.

## Axis 4 — Utility

Judge whether the skill still earns a place in the active inventory from the
utility evidence supplied by the main thread. Record every source and its
observation window. Never manufacture invocation counts from general session or
token totals.

Weight the evidence in this order:
1. Demonstrated outcomes, including avoided failures and successful rare events.
2. Distinct capability versus overlap with owned, built-in, plugin, or
   third-party skills.
3. Invocation frequency and recency, adjusted for realistic opportunities to
   trigger during the observation window.
4. Ongoing maintenance cost, staleness pressure, and evidence of supersession.

Choose exactly one lifecycle disposition:

| Disposition | Use when |
|---|---|
| `keep` | Evidence supports continued value, including a justified rare high-impact capability. |
| `narrow` | The useful core remains, but its trigger or scope is broader than demonstrated need. |
| `merge` | Its useful capability belongs in another maintained skill. |
| `archive` | No current demand is demonstrated, but the distinct capability is worth preserving outside the active inventory. |
| `retire` | Evidence shows the skill is obsolete, net-negative, or fully superseded with no worthwhile distinct value. |
| `insufficient-evidence` | The evidence or observation window cannot support a lifecycle decision. |

Low or zero use alone never means `retire`. A new or seasonal skill with no
realistic trigger opportunity is `insufficient-evidence`; a rarely used skill
that succeeded in a high-severity event can be `keep`.

## Severity

- 🟥 **Broken** — a reference doesn't resolve / the skill can't work as written.
- 🟧 **Reliability** — won't self-trigger, violates active runtime instructions, or
  cross-home drift.
- 🟨 **Polish** — bloat, missing section, weak example.

Utility glyphs are grades, not defect severities. Use 🟩 for `keep`, 🟨 for
`insufficient-evidence`, 🟧 for `narrow`/`merge`/`archive`, and 🟥 for `retire`.
A utility 🟥 requires affirmative evidence of obsolete or net-negative behavior,
not merely no usage. Record lifecycle decisions in `lifecycle`, not `findings`;
a sound but superseded skill is not technically broken.

## Return EXACTLY this JSON (no prose around it)

```json
{
  "skill": "<name>",
  "homes": ["<every runtime surface where the skill exists>"],
  "grades": { "reach": "🟩|🟨|🟧|🟥", "impl": "🟩|🟨|🟧|🟥", "correctness": "🟩|🟨|🟧|🟥", "utility": "🟩|🟨|🟧|🟥", "exposure": "🟩|🟨|🟧|🟥" },
  "references_checked": [
    { "ref": "<path/command/package/constant>", "kind": "path|command|package|constant|crossref", "status": "resolved|broken", "evidence": "<what you ran / result>" }
  ],
  "findings": [
    { "severity": "🟥|🟧|🟨", "axis": "reach|impl|correctness", "evidence": "<exact path/line/phrase>", "fix": "<precise fix, described not applied>" }
  ],
  "exposure_findings": [
    { "severity": "🟥|🟧|🟨", "class": "credential|identity-topology|attribution|runtime-fetch", "evidence": "<exact path:line and the disclosing text>", "third_party_homes": ["<home that exports it>"], "fix": "<precise fix, described not applied>" }
  ],
  "exposure_scope": "<first-party-only: no third-party home | swept: <third-party homes>>",
  "utility_evidence": [
    { "source": "<path/report/history/user-supplied evidence>", "window": "<dates or unknown>", "signal": "<observed fact, not inference>" }
  ],
  "lifecycle": { "disposition": "keep|narrow|merge|archive|retire|insufficient-evidence", "confidence": "high|medium|low", "rationale": "<one evidence-backed sentence>" },
  "drift": "<none | claude-home-only | agents-home-only | gemini-home-only | diverged: …>",
  "overlap_candidates": ["<other skill whose triggers may collide>"],
  "top_issue": "<one line>"
}
```

`references_checked` must be non-empty and must include every concrete reference
in the skill body. An empty or token `references_checked` means you didn't do the
job — go back and verify.

`exposure_findings` may be empty only after one of two things: the skill has no
third-party home, recorded as `exposure_scope: first-party-only`, or the sweep over
its third-party homes actually ran and found nothing, recorded as
`exposure_scope: swept: <those homes>`. `exposure_scope` is where that decision
lives; it is not an overload of `top_issue` or the grade rationale.
A 🟩 exposure grade with no stated scope is the failure this axis exists to prevent:
it reads identically whether the skill is clean or was never scanned.

`utility_evidence` must also be non-empty. If no attributable evidence exists,
record the searched source and window with that negative result, then choose
`insufficient-evidence`; never silently omit the utility assessment.

`lifecycle.confidence` is a claim about the EVIDENCE behind the disposition, not about how
sure you feel. Pick it from what `utility_evidence` actually holds:

| Value | The evidence looks like |
|---|---|
| `high` | Two or more independent attributable observations agreeing, inside a stated window — e.g. session history plus a committed report, or invocations across two runtimes. A `retire` or `merge` needs this. |
| `medium` | One attributable observation in a stated window, with nothing contradicting it; or several observations that agree on direction but not on magnitude. |
| `low` | The window is unknown or very short, the source is indirect (the skill is mentioned but not shown running), or two sources disagree. |

If the disposition is `insufficient-evidence`, confidence is `low` by construction — there
is no evidence to be confident about, and any other value would be reporting an opinion as
a measurement. A `high` alongside a single source is the specific error this table exists
to prevent: it is what makes an unread skill look like a measured one.
