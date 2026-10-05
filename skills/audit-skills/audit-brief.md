# Audit Brief — one skill, five axes, six runtime surfaces

You are auditing **one** skill the user authored. Read its `SKILL.md` (and any
supporting files in its directory). Score the five axes below, **verify every
reference on disk**, and return the JSON contract at the end. Report only —
make no edits to any skill.

## Contents

- The Iron Law
- The standard: official skill guidance
- Axis 1 — Reach
- Axis 2 — Implementation
- Axis 3 — Correctness of references + conventions
- Axis 5 — Exposure
- Cross-home drift
- Axis 4 — Utility
- Severity
- Return EXACTLY this JSON

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

## The standard: official skill guidance

Axes 1 and 2 grade against three published pages, snapshotted in this skill's
`assets/guidance/` directory: the Agent Skills specification (`specification.md`),
Anthropic's skill authoring best practices (`best-practices.md`), and the Claude
Code skills page (`claude-code-skills.md`). Read the snapshot section a rule comes
from when a case is unclear. Superpowers' `writing-skills` is third-party and is
used for one rule only, the workflow-summary rule below; where it disagrees with
the official pages, the official pages win.

If the main thread tells you the guidance has drifted (`suspended_axes` names
`reach` and `impl`), do not grade those two axes: set their grades to Polish and give
each a finding that cites the drift, so a stale rule is never applied as current.

## Axis 1 — Reach (trigger reliability)

Grade the frontmatter against the official pages:
- The `description` says what the skill does **and** the conditions that trigger
  it, in either order, in third person, with concrete keywords. A description may
  begin "Use when"; nothing requires it. Missing capability or missing triggers
  is Polish; both vague is Reliability.
- State the capability and use conditions without summarizing the workflow. A
  process summary is a Reliability finding because an agent can follow it instead of
  reading the body (the one `writing-skills` rule kept: it has a recorded failure
  behind it).
- Technology scoping explicit if the skill is technology-specific.
- `name`: 1–64 characters of `a-z`, `0-9` and hyphens, no leading or trailing
  hyphen, no `--`, equal to the directory name, and no `anthropic` or `claude`.
  A violation is Broken: the skill fails to load or upload.
- `description`: 1–1024 characters, no XML tags (Broken over the limit).
  `description` plus `when_to_use` over 1536 characters is truncated in the
  Claude Code listing (Reliability); the key use case belongs in the first sentence.
- Frontmatter keys: a key Claude Code does not recognise is silently ignored, so
  a near-miss spelling (`whenToUse`, `disableModelInvocation`) is Reliability — its text
  never takes effect. `owner: <your-org>` is outside the spec's six fields but is
  the house ownership marker and an intended local exception: never a finding.
  Other non-spec keys are context only, since no owned skill is uploaded to
  claude.ai, where the upload rejects them.
- If the main thread reports this skill's description as dropped from the Claude
  Code listing, that outranks every wording finding: record it as Reliability.

Note any trigger phrases that look likely to collide with another skill in the
inventory you were given (the main thread confirms overlaps in synthesis — you
just flag candidates).

## Axis 2 — Implementation

Against the official pages. No section is required (the spec sets no format
restrictions); check that the body gives steps, examples, and edge cases where
the task needs them.

Size and disclosure:
- `SKILL.md` body under 500 lines (Polish over). Cut what the agent already knows.
- Claude Code re-attaches only the first 5,000 tokens of a skill after
  compaction. In a longer skill, a rule that must survive compaction sitting past
  that point is Reliability. Estimate tokens as characters / 4 and say so.
- Every supporting file is named from `SKILL.md`, with what it holds and when to
  read it (Polish unnamed).
- References one level deep from `SKILL.md`: a file reachable only through
  another reference is Polish, because agents read nested files partially.
- A reference file over 100 lines opens with a contents list (Polish without). Verbatim prompt payloads, such as `endgame-review/references/stage2-refute.md`, are exempt: inserting headings would change the prompt sent to reviewers.
- Skill-relative paths use forward slashes (Polish).

Workflows, scoped to skills whose task needs them:
- Complex multistep task: numbered steps, and a copyable checklist where steps
  are easy to skip (Polish).
- Quality-critical output: a validate, fix, repeat loop with a stated pass
  condition (Polish; Reliability when the skill's own record shows a skipped validation).
- Batch, destructive or high-stakes work: plan, validate the plan, execute,
  verify (Reliability when absent).
- A rule that must hold every time, enforced only by prose where a hook exists
  or is feasible (Polish).

Content:
- No time-conditional instruction (one that is correct only before or after a
  date) (Polish). Dated evidence such as "measured 2026-09-19" is provenance, not
  this.
- One term per concept; a default with an escape hatch rather than a menu of
  options (Polish).
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
- Scripts the skill ships → the skill says whether to run or read each one,
  lists what it needs installed, and explains its constants; MCP tools are named
  `ServerName:tool_name`. Missing is Polish, a script that cannot run is Broken.

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
   skill is mounted in no third-party home, grade Good and record that as the
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
bodies are a Reliability finding; a deliberately single-home skill is `drift` context,
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

- **Broken** — a reference doesn't resolve / the skill can't work as written.
- **Reliability** — won't self-trigger (including a description dropped from
  the Claude Code listing or a silently ignored frontmatter key), violates active
  runtime instructions, or cross-home drift.
- **Polish** — bloat, a disclosure or workflow gap above, weak example. A
  missing named section is not a finding.

Utility grades represent lifecycle decisions, not defect severities. Use Good for `keep`, Polish for
`insufficient-evidence`, Reliability for `narrow`/`merge`/`archive`, and Broken for `retire`.
A utility Broken requires affirmative evidence of obsolete or net-negative behavior,
not merely no usage. Record lifecycle decisions in `lifecycle`, not `findings`;
a sound but superseded skill is not technically broken.

## Return EXACTLY this JSON (no prose around it)

```json
{
  "skill": "<name>",
  "homes": ["<every runtime surface where the skill exists>"],
  "grades": { "reach": "Good|Polish|Reliability|Broken", "impl": "Good|Polish|Reliability|Broken", "correctness": "Good|Polish|Reliability|Broken", "utility": "Good|Polish|Reliability|Broken", "exposure": "Good|Polish|Reliability|Broken" },
  "references_checked": [
    { "ref": "<path/command/package/constant>", "kind": "path|command|package|constant|crossref", "status": "resolved|broken", "evidence": "<what you ran / result>" }
  ],
  "findings": [
    { "severity": "Broken|Reliability|Polish", "axis": "reach|impl|correctness", "evidence": "<exact path/line/phrase>", "fix": "<precise fix, described not applied>" }
  ],
  "exposure_findings": [
    { "severity": "Broken|Reliability|Polish", "class": "credential|identity-topology|attribution|runtime-fetch", "evidence": "<exact path:line and the disclosing text>", "third_party_homes": ["<home that exports it>"], "fix": "<precise fix, described not applied>" }
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
A Good exposure grade with no stated scope is the failure this axis exists to prevent:
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
