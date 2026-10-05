---
name: composition-review
description: Use when a change touches stateful or messaging paths — Wolverine/ASB handlers, FIX session state, EF stores, sagas, outbox/inbox — and composition defects need checking before merge. Trigger phrases include "composition review", "class-A review", "check restart-replay", "is this idempotent", and the COMPOSITION REVIEW REQUIRED line the PR gate emits.
---

# Composition review

Five questions against the diff: ordinary PR reviewers (CodeRabbit, Gitar) find local
implementation defects; these find composition ones — how the parts behave together
under restart, redelivery, contention and partial failure.

Five questions; no phases.

## Dispatch

Read `~/.agents/notes/dotnet-runtime-traps.md` (if absent, proceed; record the assumption).

Resolve tier `frontier` through `model-registry` when supported. Send **one** reviewer
through the runtime's native subagent facility; assume no particular tool or alias.
Supply the diff, questions and output contract.

With no subagent, run it in the current agent and label it `single-agent fallback`.
Without an enforceable read-only allowlist, capture `git status --short`,
`git rev-parse HEAD`, `git diff --binary HEAD`, and hashes of reported untracked files
before and after. Any change stops the review as a coverage gap; never discard it.

Scope it past the diff: Q1, Q2 and Q5 turn on the collaborators the changed code calls,
the store and context configuration, and the queue or endpoint registration — it must
read those too. Where the available code does not settle a question, report a
finding-shaped gap naming what could not be read, never `clear`.

## The five questions

| | Question | What refutes a "clear" |
|---|---|---|
| Q1 | **Restart-replay.** Process dies mid-handler, broker redelivers. Does re-running from the top land on the same state? | Any write that happens before the point of no return and is not keyed to survive a second pass |
| Q2 | **Idempotency.** ASB is at-least-once. Is the effect keyed on something stable, or does redelivery apply it twice? | An unkeyed `+=`, insert, publish, or external call |
| Q3 | **Ordering.** Does correctness depend on arrival order, and is that order guaranteed — session id, partition key — or assumed? | Order-dependent logic on a non-sessioned queue |
| Q4 | **Fence pairing.** Every lock/lease/fence acquired: released on every path, exception included? Two fences taken in a consistent order? | An early return or throw between acquire and release; two paths taking A to B and B to A |
| Q5 | **Partial failure.** Handler performs N side effects (EF write, publish, external call) and fails after k. What state is left? | A torn write with no outbox and no compensation |

Q1 checks restart replay across collaborators; Q4 checks acquire/release pairing across every exit path. Both require reading beyond the changed method.

## Output contract

Per question, exactly one of three slots. There is no fourth, and no question may be
left unanswered.

- **`finding`** — carries the *mechanism*: the concrete sequence that corrupts or loses.
  "Replay of message N after crash re-applies the delta; balance increments twice."
  No mechanism, no finding.
- **`clear`** — carries *why* it holds, naming the thing that makes it hold: dedup key,
  session id, `using` scope, outbox row.
- **`N/A`** — carries why the question does not apply to this diff.

`N/A` means the subject does not exist in the change; `clear` means it exists and
holds. On a stateful or messaging path, `N/A` on Q1, Q2 or Q5
must name the absent subject — the write, the effect, the side effect — and why the
change cannot reach it. A bare "does not apply" there is a coverage gap.

A bare "looks fine" answers nothing. Return one row per question, Q1 to Q5:

| Q | slot | mechanism / why |
|---|---|---|
| Qn | `clear` | dedup key on `OrderId` |

## What happens to a finding

Any finding blocks `quality-gate-review` PASS until it is fixed or the user explicitly
accepts it — same rule as `ponytail:ponytail-review` findings.
