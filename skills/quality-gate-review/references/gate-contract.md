# Quality gate contract

## Contents

- [Evidence domains](#evidence-domains)
- [What each consumed skill must return](#what-each-consumed-skill-must-return)
- [Verdict matrix](#verdict-matrix)
- [Output](#output)
- [Quality Gate — <repo> @ <branch>](#quality-gate--repo--branch)
- [Domain Results](#domain-results)
- [Adversarial-review findings](#adversarial-review-findings)
- [Ponytail](#ponytail)
- [Composition](#composition)
- [Evidence Gaps](#evidence-gaps)
- [Required Actions](#required-actions)
- [Recommended Actions](#recommended-actions)
- [Verdict](#verdict)


## Evidence domains

Classify supplied evidence and known gaps only; the mandatory Ponytail check is the sole new-review exception.

| Domain | Evidence to classify |
|---|---|
| Scope | Changed components, public API, migration/configuration, and deployment impact. |
| Correctness | Existing findings and validation evidence for logic, boundaries, failure handling, state, retry, idempotency, and concurrency. |
| Testing | Proof of happy, failure, boundary, integration, and concurrency behaviour; coverage alone is insufficient. |
| Architecture | Existing evidence of dependency direction, boundaries, coupling, cohesion, and justified complexity. |
| Operations | Logging, metrics, health, alerting, configuration, failure detection, and diagnosis evidence. |
| Security | Validation, secrets, authentication, authorisation, injection, tenant boundaries, permissions, and PII evidence. |
| Performance | Existing N+1, allocation, collection-bound, query, and API/DB-call evidence. |
| CI + reviewers | Current build/test/tool outcomes, committed Review Tier, required current-HEAD reviewer verdicts, and unresolved threads. |

Read the relevant canonical note before classification: `~/.agents/notes/dotnet-runtime-traps.md`, `deploy-and-ci-traps.md`, `web-ui-traps.md`, or `npm-publishing-traps.md` (if that note is not present, proceed and record the assumption).

For Domain 8, an expected enabled tool with no result is a gap. An estate-disabled paid GitHub product is `N/A — intentionally disabled`. CodeRabbit's passing check is not a verdict; skipped, errored, rate-limited, or pre-HEAD coverage is a coverage gap. A policy absent at the base ref means `NORMAL`; an unreadable policy or unavailable changed-file evidence means `UNCLASSIFIED`. Stryker is required only when the repository's committed policy or schedule requires that result for this gate. Use `ai-findings-ledger` for owned GitHub disposition routing.

## What each consumed skill must return

**`adversarial-review` Phase 4.** That skill verifies every Critical, every High and every
contested finding, so a finding of one of those kinds arriving with no
`CONFIRMED`/`REFUTED`/`INDETERMINATE` verdict is a **coverage gap** and FAILs, exactly
like a missing required reviewer. Phase 4 IS optional on an uncontested Medium or Low: its
absence there is not a gap, and its presence is recorded the same way. `REFUTED` closes;
`INDETERMINATE` stays open and blocks as its severity would.

**`composition-review` answers.** Each slot carries different support, and demanding a
"mechanism" from all three would make a fully conforming all-`clear` return read as five
gaps. Per that skill's own output contract:

| Slot | What it must carry |
|---|---|
| `finding` | the *mechanism* — the concrete sequence that corrupts or loses |
| `clear` | *why it holds*, naming what makes it hold: dedup key, session id, `using` scope, outbox row |
| `N/A` | why the question does not apply to this diff; on Q1, Q2 or Q5 it must name the absent subject |

An answer missing its slot's support is a coverage gap. A bare "looks fine" answers
nothing.

## Verdict matrix

Use this matrix as the only verdict aggregation rule. A domain is applicable unless recorded as `N/A — reason`.

| Evidence row | Evidence | Verdict |
|---|---|---|
| required-negative-reviewer | A tier-required reviewer ran and reported an explicit negative verdict such as `CHANGES_REQUESTED`; all other applicable domains are PASS. | FAIL |
| optional-negative-reviewer | A reviewer not required by the tier ran and reported an explicit negative verdict; all other applicable domains are PASS. | FAIL |
| unresolved-thread | Any reviewer thread is unresolved. | FAIL |
| policy-absent | The base-ref policy is absent, so the tier is `NORMAL`; all applicable domains and required reviewer evidence are clean. | PASS |
| policy-unreadable | The policy cannot be read or changed-file evidence is unavailable, so the tier is `UNCLASSIFIED`. | FAIL |
| classifier-disagreement | The PR-gate hook released the PR as `NORMAL` after a read failure while this gate reads `UNCLASSIFIED`. **One classifier, one posture:** the hook is the classifier and its fall-through to `NORMAL` on error is a defect in the hook, not a tier this gate may adopt. Record `UNCLASSIFIED`, say the hook released it, and leave the decision with a human — re-running until the read succeeds is the self-classification the skill forbids in its own first clause. | FAIL |
| required-domain-warning | An applicable domain has an unaccepted warning, validation gap, or coverage gap. | FAIL |
| accepted-explicit-condition | No blocker exists; an accepted, bounded gap has a named, verifiable condition. | PASS WITH CONDITIONS |
| unaccepted-validation-gap | Required validation is broken or missing and the gap is not explicitly accepted. | FAIL |
| no-adversarial-review | No `adversarial-review` run covers this PR's HEAD. The adversarial panel is the class-C control and is **not a per-PR gate** — it runs as a scheduled sweep against merged `main` — so its absence is `N/A — not a per-PR control`, not a domain warning, and every other applicable domain decides the verdict. | N/A (does not block) |
| stale-adversarial-review | A run exists but covers a range that does not include this HEAD. Record it and read its findings; do NOT credit it as coverage of the unreviewed commits, and do not treat the shortfall as a domain warning either — same reasoning as the row above. | N/A (does not block) |

Aggregate every applicable domain once: `PASS` requires every domain to be `PASS` or `N/A`; `PASS WITH CONDITIONS` requires no failure and only accepted bounded gaps with named, verifiable conditions; otherwise `FAIL`. An explicit negative reviewer verdict, any unresolved thread, or any unaccepted warning, validation gap, or coverage gap is a failure. A user-accepted reviewer coverage gap remains explicit. An unaccepted Ponytail finding, composition finding, or composition coverage gap is an unaccepted gap. A composition review recorded `N/A — no stateful or messaging path touched` is a valid `PASS` state **only when the PR gate did not emit `COMPOSITION REVIEW REQUIRED` for that PR**; where it did, that `N/A` is a coverage gap and FAILs — the assertion is written by the reviewed party and cross-checked by nothing, so a false one is indistinguishable from a valid one here. A Phase-4 `REFUTED` adversarial-review finding closes for verdict purposes (its producer never counts it as open) while keeping its severity and refuting evidence on the record; `INDETERMINATE` stays open and blocks as its severity would.

## Output

```markdown
## Quality Gate — <repo> @ <branch>

**Overall: PASS | PASS WITH CONDITIONS | FAIL**
Review Tier: HIGH | NORMAL | LOW | UNCLASSIFIED — <match reason>
Reviewer Gate: Gitar <status> | CodeRabbit <status> | unresolved threads <count>
Adversarial Review: <run folder | absent — gap>

### Domain Results
| Domain | Result | Evidence / gap |
|---|---|---|
| Scope | PASS | <summary> |
| Correctness | PASS | <evidence> |
| Testing | WARNING | <gap> |
| Architecture | PASS | <evidence> |
| Operations | N/A | <reason> |
| Security | PASS | <evidence> |
| Performance | PASS | <evidence> |
| CI + reviewers | FAIL | <blocking gap> |

### Adversarial-review findings
| Severity | Consensus | Phase 4 | Finding |
|---|---|---|---|
| High | [contested] | INDETERMINATE | <finding and preserved dissent> |

### Ponytail
<Lean already. Ship. | findings plus net-lines metric>

### Composition
<five questions clear/N/A | finding with mechanism, or coverage gap>

### Evidence Gaps
- <missing or stale evidence>

### Required Actions
1. <specific merge blocker>

### Recommended Actions
1. <non-blocking item already present in supplied evidence>

### Verdict
**FAIL** — <one-line reason>.
```

Do not create Confirmed, Disputed, or Dismissed AR headings. Phase 3 consensus and optional Phase 4 verification are separate fields. Never add a free-form second-review section.
