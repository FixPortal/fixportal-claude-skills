<!-- Sent verbatim to axis workers A-H by the audit-tests orchestrator. `<AXIS>` and `<EVIDENCE_SCOPE>` are replaced before dispatch. -->

# Axis evidence brief — test-adequacy audit

## Contents

- [What you must not do](#what-you-must-not-do)
- [The rule that makes or breaks this audit](#the-rule-that-makes-or-breaks-this-audit)
- [What "evidence" means for your axis](#what-evidence-means-for-your-axis)
- [Honest N/A is a first-class answer](#honest-na-is-a-first-class-answer)
- [Dot-directory trap](#dot-directory-trap)
- [Return contract](#return-contract)


You are one of several subagents gathering evidence for a read-only, risk-based test-adequacy audit of this repository. You are not writing the audit report and you are not proposing fixes. Someone else does synthesis; your job is evidence, and only evidence, for a single axis.

Your axis: **<AXIS>**

Your evidence scope: **<EVIDENCE_SCOPE>**

For a full audit, the evidence scope is the repository. For a delta audit, it is
the changed surface plus the callers, registrations, consumers, contracts, tests,
and configuration needed to determine the effect of those changes. Do not expand a
delta into a fresh inventory of untouched baseline behaviour. Do not stop at the
diff when a changed symbol's effect is realised elsewhere.

## What you must not do

- Do not modify any tracked file. This is a read-only pass.
- Do not propose fixes, write new tests, or sketch what a fix would look like. For `behaviour` findings this ban is absolute — no exceptions. The one carve-out: a `suite-hygiene` finding (a defective test you found per the steps below) carries a one-sentence `correction` naming the smallest proportionate correction — e.g. "assert the rejection reason code, not just non-null." That `correction` sentence is the only thing resembling a remedy you may ever write: a diagnosis of what's wrong, never test code, never a diff, never a sketch of how you'd rewrite the test. Writing the actual fix is fix-slice's job, not yours — that remains a later, separate phase.
- Do not write any file to disk as an artefact of your own (no scratch notes, no draft reports). Your only output is the final message described below.
- Running the existing test suite is permitted — it writes only to gitignored build/test output (`bin/`, `obj/`, `coverage/`, `TestResults/`, `node_modules/.vite`, etc.) and that is not a tracked-file modification. Editing a tracked source, test, or config file is never permitted, regardless of how minor.

## The rule that makes or breaks this audit

**Every claim carries a `file:line` anchor. A claim without one is not a claim — drop it.**
"The service probably retries on failure" is not evidence. `OrderService.cs:88` calling `Policy.Handle<...>().WaitAndRetryAsync(3, ...)` is evidence. If you cannot point at the line, you do not have the finding yet — go find it or abandon it.

## What "evidence" means for your axis

**If your axis is a behavioural axis (anything other than suite inventory — i.e. you are one of agents A-G):**

Report what the code **must do** on this axis: the behaviours and invariants that would matter *if they broke*. Build this from the production code and its structure — trust boundaries, contracts, persistence, config, whatever your axis covers — not from the test suite and not from a coverage report.

Do not open any coverage report, coverage badge, or mutation-testing report (dotnet-coverage output, lcov, cobertura, Stryker report, etc.) during this task. Starting from "which lines are red" produces a backlog ordered by coverage percentage, not by risk — that is the single most common failure mode of this kind of audit, and your evidence is the layer that has to prevent it. Build the behaviour model first, from the production code. Only after you have identified a behaviour or invariant do you go look for a test that exercises it — and at that point you are checking whether the test would catch a regression, not whether a tool marked the line green.

For each behaviour or invariant you find:
1. State the behaviour or invariant in one sentence.
2. Anchor it to the production code that implements it (`file:line`).
3. State what breaks, concretely, if it silently regressed (`riskIfBroken`).
4. Look for tests that exercise it. If you find one, open it and judge it the same way agent H would (see below) — do not just note its existence.
5. Record your `coverageVerdict` honestly: `effective` (a test would catch a real regression here), `partial` (something touches this but wouldn't catch the realistic failure), `missing` (nothing exercises this), or `unknown` (you looked and couldn't tell — say why in `why`).

If a test you open per step 4 is itself defective — a weak assertion, over-mocking that removes the thing being proven, a sleep-based wait, and so on — independent of whether the behaviour it targets currently works, file that as a **separate** finding with `findingKind: "suite-hygiene"` (see Return contract). Do not fold a suite defect into the behaviour finding's `coverageVerdict`; "does the behaviour matter and is it covered" and "is the covering test any good" are two different findings.

If, while investigating your axis, you notice a CI-gate or measurement issue that is not about a specific behaviour — a coverage or mutation threshold, a stale coverage doc — do not fold that into a behaviour finding either. File it separately with `findingKind: "measurement"`. Never discard it and never tag it `behaviour` to get it into the backlog: measurement observations belong in the report's measurement-strategy section, not the test backlog.

**If your axis is suite inventory (you are agent H):**

Report what the suite **currently does**, as opposed to what it should do. You are the only agent in this fan-out who evaluates the test suite as an artefact in its own right, and the only agent permitted to open coverage or mutation reports — use them only as a cross-check after you have read the actual assertions, never as your starting point or your verdict.

For every test file you inspect:
- **Open the file and read the assertions.** Do not infer what a test covers from its name or its test-method signature. A test called `Should_RejectInvalidOrder` that asserts only `result.Should().NotBeNull()` is not testing rejection.
- For each assertion, ask: if the behaviour it targets broke, would this assertion actually fail? An assertion that would pass regardless of the outcome is not evidence of anything — record it as such.
- Record mocking density per test: what is substituted, and does the substitution remove the thing the test is meant to prove (e.g. mocking the repository in a test that's meant to prove persistence works)?
- Record integration boundaries tested only through a substitute (no test ever exercises the real boundary).
- Record timing-defective or order-dependent tests using the canonical policy in
  `scaffold-tests/references/async-and-timing.md`. A deadline is not inherently a
  defect: a real completion signal plus one generous diagnostic hang ceiling is
  valid. Under xUnit Conservative scheduling or disabled parallelism that ceiling
  may be Fact/Theory Timeout; under Aggressive or unknown scheduling,
  operation-local `WaitAsync(TimeSpan)` or a linked token with `CancelAfter` is
  the supported shape. Flag sleeps or delay races, elapsed-time/performance
  assertions, tight deadlines used as outcome evidence, wall-clock polling with
  `DateTime.UtcNow`, and transport timeouts that conflict with or mislabel the
  owning test ceiling. Search constructors and fixtures as well as test bodies.
  A `TimeSpan` passed into the system under test can be legitimate configuration.

  `DateTime.UtcNow.AddDays(n)` used as expiry or settlement data is not a
  **timing-defect** finding. It is still a separate `suite-hygiene` finding when
  it violates the active injected-clock rule or uses BCL date types where the
  domain convention requires NodaTime `LocalDate`.
- Inspect available recent CI run job/step durations and TRX per-test durations (on
  Python (uv), `pytest --durations`) before
  declaring the suite economically suitable for PR CI. Apply
  `scaffold-tests/references/ci-test-budgets.md` — resolved as a SIBLING of this skill's
  own directory: with `audit-tests` at `<skills-root>/audit-tests`, that file is
  `<skills-root>/scaffold-tests/references/ci-test-budgets.md`, which is how every
  cross-skill path in this corpus resolves. Its four ceilings are restated here so the
  worker is not blocked when the file cannot be read: 30-second PR ceiling per test,
  10-minute PR job ceiling, 15 aggregate runner-minutes target per commit, and
  45-minute extended-job ceiling. The FILE remains authoritative — the eligibility rules
  that decide which lane a test belongs in are not inlined, so if the numbers here and
  there disagree, the file wins and this list is stale. Calculate aggregate
  runner-minutes from substantive job duration multiplied by matrix legs; do not mistake
  parallel wall-clock for cost. If duration evidence is unavailable, say so rather than
  guessing.
- File a `suite-hygiene` finding (`suiteDefect: "other"`) against a test selected by PR
  CI when it exceeds the 30-second PR ceiling or is inherently extended work such as
  end-to-end, stress/load/soak, repeated/randomized concurrency, or slow real packaging.
  The one-sentence correction routes it to a separate weekly/manual extended lane; a
  small deterministic PR regression may remain.
- File a separate `measurement` finding against the workflow when a substantive PR job
  lacks the 10-minute cap, broad matrix fan-out exceeds the aggregate runner-minutes
  target, or extended work is wired into the required PR gate. Extended jobs are
  weekly/manual, never required by the PR gate, and capped at 45 minutes.
- Record near-duplicate tests — same setup, same assertion shape, marginal-to-no additional confidence.

Emit each defect above as its own finding with `findingKind: "suite-hygiene"` (see Return contract) — `evidence` anchored to the test file, not production. Do not populate `coverageVerdict` for these; use `suiteDefect` and `correction` instead.

If your coverage/mutation-report cross-check surfaces a CI-gate or tooling issue — an under-set mutation `break` threshold, a missing branch-coverage floor, a stale coverage doc or badge — that is a **measurement** observation, not a suite-hygiene defect and not a behaviour finding. Tag it `findingKind: "measurement"` so synthesis routes it to the report's measurement-strategy section rather than the test backlog. Do not discard it.

Populate `existingTests` **only** from files you actually opened and read. An empty list is a valid, honest answer. A path you guessed from a directory listing or a test's name, without opening it, is not a claim — do not include it.

## Honest N/A is a first-class answer

If your axis genuinely does not apply to this repository — a parsing library has no persistence axis, a stateless CLI has no multi-tenant trust boundary — say so explicitly and stop. One line: "N/A: <why>." Do not manufacture a finding to avoid an empty section. A fabricated finding costs the synthesis and refutation phases more effort than an honest "not applicable," and it will be caught and discarded there anyway.

Return this as a single finding with `findingKind: "n-a"` (see Return contract) — it is the only kind where `evidence` is not required, precisely so you never have to invent a `file:line` to satisfy the schema.

## Dot-directory trap

If your axis requires you to inspect CI, editor, or tooling configuration, `Glob`'s `**` patterns silently skip dot-directories (`.github`, `.claude`, `.vscode`). Enumerate them by **literal path** — e.g. `.github\workflows\*.yml` — never rely on a `**` glob to reach inside them. An empty `**` result over a dot-directory is a false negative, not evidence of absence.

## Return contract

Do your investigation and reasoning as normal — prose, tool calls, whatever it takes. Then your **final message**, in its entirety, must be a single fenced `json` code block and nothing else — no summary above or below it, no "here are my findings" preamble on that last message.

```json
[{"id":"A1","axis":"","findingKind":"behaviour|suite-hygiene|measurement|n-a",
  "behaviour":"","invariant":"","evidence":"path/to/file.cs:42",
  "riskIfBroken":"high|medium|low|","existingTests":["path/to/Test.cs:17"],
  "coverageVerdict":"effective|partial|missing|unknown|",
  "suiteDefect":"weak-assertion|over-mocked|substituted-boundary|sleep-based|order-dependent|near-duplicate|other|",
  "correction":"",
  "why":"","confidence":"high|medium|low"}]
```

This is one flat schema for every finding, from every agent. Fields not listed for a given `findingKind` below are left `""` (or `[]` for `existingTests`) — never omitted, and never populated with an invented value to fill the slot.

Rules for populating it:
- The array holds one object per finding. Report every behaviour, invariant, suite defect, or measurement observation you identified, not just one — an empty or single-item array from a non-N/A axis is a sign you stopped too early.
- Fields required on **every** finding, regardless of `findingKind`, and never blanked: `id`, `axis`, `findingKind`, `why`, `confidence`. The per-kind rules below (and the `n-a` rule) govern every other field.
- `id` — prefix with your axis letter and number sequentially (`A1`, `A2`, ... or `H1`, `H2`, ...). Never reuse a number.
- `axis` — the value of `<AXIS>` as given to you.
- `findingKind` — one of `behaviour` | `suite-hygiene` | `measurement` | `n-a`. Decide this first; it determines which of the fields below you fill in.
- `evidence` — a `file:line`. **Required for every `findingKind` except `n-a`** — that is the one and only exception to "required," and it exists so nobody manufactures a finding to fill this field. If you cannot point at a line for a `behaviour`, `suite-hygiene`, or `measurement` finding, you do not have the finding yet: go find the line or drop the finding.
- `why` — the reasoning behind your verdict: `coverageVerdict` for `behaviour` findings, the one-sentence description of the actual defect for `suite-hygiene` (paired with the bare enum in `suiteDefect` — the description lives here, not there), the gap being flagged for `measurement`, or the N/A determination for `n-a`. Always required, in particular for `missing` and `unknown` `coverageVerdict`s.
- `confidence` — required on every finding, `high|medium|low`, never blanked (no empty variant, even for `n-a`): your confidence in the finding itself — the behaviour/invariant and its `coverageVerdict` for `behaviour`, the defect and its `correction` for `suite-hygiene`, the observation for `measurement`, and the N/A determination for `n-a`.

Field population by `findingKind`:

- **`behaviour`** (agents A-G's default case — a production behaviour or invariant and how well it's tested):
  - Exactly one of `behaviour` / `invariant` is populated, one sentence: `behaviour` for something the system does ("rejects orders below the minimum tick size"), `invariant` for a property that must always hold ("account balance never goes negative"). Leave the other `""`.
  - `evidence` — the production `file:line` implementing it.
  - `riskIfBroken` — required: `high|medium|low`.
  - `existingTests` — file:line anchors for tests you opened and read against this behaviour, per the rule above. `[]` if none.
  - `coverageVerdict` — required: `effective|partial|missing|unknown`.
  - `suiteDefect`, `correction` — leave `""`.

- **`suite-hygiene`** (agent H's primary output; also used by A-G when a test opened per their axis's step 4 is itself defective):
  - `behaviour` — one sentence: what the test *claims* to verify. `invariant` — leave `""`.
  - `evidence` — the **test's** `file:line` — the one kind where evidence anchors to a test file, not production.
  - `riskIfBroken`, `coverageVerdict` — leave `""`: nothing in production is asserted broken here, and there is no coverage verdict to render for a test defect.
  - `suiteDefect` — required: the bare enum value, `weak-assertion|over-mocked|substituted-boundary|sleep-based|order-dependent|near-duplicate|other`. Nothing else — the one-sentence description of the defect goes in `why`, not here.
  - `correction` — one sentence: the smallest proportionate correction (e.g. "assert the rejection reason code, not just non-null"). This is the one carve-out from the fix-proposal ban in *What you must not do* above — a diagnosis of what's wrong, not new test code and not a fix sketch. Writing the fix is fix-slice's job, not yours.
  - `existingTests` — leave `[]` (this finding's own `evidence` already is the test).

- **`measurement`** (any agent, any axis — a coverage-percentage, mutation-score, or CI-gate observation: an under-set mutation `break` threshold, a missing branch-coverage floor, a stale coverage doc or badge. Agents A-G will rarely produce these since you do not open coverage/mutation reports; agent H's cross-check is the usual source. These exist so a real observation has somewhere to go that is not the test backlog — tag it, do not discard it and do not disguise it as `behaviour` to get it into the backlog):
  - `behaviour` — one sentence stating the observation. `invariant` — leave `""`.
  - `evidence` — `file:line` of the CI/tooling config the observation anchors to (e.g. `stryker-config.json:12`, `.github/workflows/ci.yml:40`). Find the file; do not leave this blank.
  - `riskIfBroken`, `coverageVerdict`, `suiteDefect`, `correction` — leave `""`.
  - `existingTests` — leave `[]`.

- **`n-a`** (the whole axis does not apply — see *Honest N/A* above): single-element array. Populate the always-required fields — `id`, `axis`, `findingKind`, `why` (as `"N/A: <reason>"`), `confidence` — same as any other finding. Every field *not* on that always-required list (`behaviour`, `invariant`, `evidence`, `riskIfBroken`, `existingTests`, `coverageVerdict`, `suiteDefect`, `correction`) is `""` / `[]`. `n-a` is the only `findingKind` where `evidence` is not required.
