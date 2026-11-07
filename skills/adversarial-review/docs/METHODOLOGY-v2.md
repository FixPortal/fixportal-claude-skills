# Adversarial Review — v2 methodology (cross-vendor, six seats)

## Contents

- [Motivation](#motivation)
- [Panel roster (6 reviewers / 6 vendors)](#panel-roster-6-reviewers--6-vendors)
- [How seats are billed, and what happens when one fails](#how-seats-are-billed-and-what-happens-when-one-fails)
- [Wrapper contract](#wrapper-contract)
- [Cost & tokens](#cost--tokens)
- [Phase design](#phase-design)
- [Phase 1 — blind independent find (6 reviewers, parallel)](#phase-1--blind-independent-find-6-reviewers-parallel)
- [Phase 2 — cross-examine (same 6, parallel)](#phase-2--cross-examine-same-6-parallel)
- [Phase 3 — adjudicate (Opus judge)](#phase-3--adjudicate-opus-judge)
- [Phase 3.5 — judge-audit (mandatory on a merge-gating or HIGH-tier target, else opt-in)](#phase-35--judge-audit-mandatory-on-a-merge-gating-or-high-tier-target-else-opt-in)
- [Phase 4 — verify (cross-vendor pool)](#phase-4--verify-cross-vendor-pool)
- [Telemetry (Observatory)](#telemetry-observatory)
- [Files](#files)
- [Non-goals / guardrails](#non-goals--guardrails)

Status: implemented v2 methodology. This document records the contract shared by
the wrappers, `reviewers.json`, the driver, and Observatory telemetry. It records
the **shape** of the panel, not its occupants: `reviewers.json` says who sits where
and why, and each seat's `_comment` carries the evidence and the conditions for
changing it. Anything below that names a seat is a description of the manifest on
the day it was written; read the manifest, not this page, when the two disagree.

## Motivation

V2 is built on two changes:

1. **Every frontier vendor is reachable without a per-call meter.** Most seats run
   on a flat-rate subscription through a headless CLI; the rest run on a metered
   API whose balance is a deliberate, visible cost. Either way, methodology
   quality is the axis that matters, and the cost of a seat is a fact to disclose,
   not a reason to drop a vendor.
2. **Headless agentic CLIs exist for more than one vendor** (`claude -p`,
   `codex exec`). A non-Anthropic vendor can therefore walk the repository, not
   just read the diff.

V2 addresses two structural weaknesses in the v1 panel:

- **Repo-blind abstention.** Only the Anthropic reviewers had repo access; the
  cross-vendor reviewers abstained ("needs evidence") whenever a mechanism lived
  outside the diff. Those abstentions masqueraded as doubt at adjudication.
- **Judge and verifier were an Anthropic monoculture.** The two most
  decision-heavy steps — Phase-3 adjudication and Phase-4 verification — ran on a
  single vendor, re-correlating the error the panel exists to decorrelate.

## Panel roster (6 reviewers / 6 vendors)

| id | vendor | registry constraint | wrapper (fallback) | billing route | repoAccess |
|----|--------|---------------------|--------------------|---------------|------------|
| Z  | zai | `frontier`, channel `cli` | `glm` (isolated Claude Code on the GLM Coding Plan) | coding plan | no (no tools, no repo) |
| F  | anthropic | `frontier`, family `claude-opus` | `claude` | subscription | yes (read-only plan mode) |
| X  | openai | `frontier`, channel `cli` | `codex` (`openai` API as the declared fallback) | subscription, API on fallback | yes (sandbox read-only) |
| D  | deepseek | `frontier`, channel `api` | `deepseek` | metered API | no (one HTTPS call, no tools) |
| G  | google | `workhorse`, channel `cli` | `agy` | subscription | no (diff + `-ContextPath`) |
| M  | moonshot | `workhorse`, channel `api` | `moonshot` | metered API | no (one HTTPS call, no tools) |

Retired or disabled seats live in `alternates` with their evidence and re-enable
conditions, deliberately not repeated here: **K** (Moonshot over the Kimi Code CLI,
retired when the subscription lapsed), **R** (xAI Grok, unavailable), **B**
(Anthropic `workhorse`, retired as the lowest-yielding seat) and **O** (a legacy
duplicate of F). Moving a seat between `reviewers` and `alternates` is how the
panel changes; this table follows the manifest, not the other way round.

**The roster names constraints, not models.** A seat carries a `select` block that
`run-review.ps1` resolves against the canonical model registry at run time, so a release
reaches the panel by being triaged in the registry rather than by an edit here. Writing
model ids into this table would reintroduce exactly the drift the constraint removes —
this document records the *shape* of the panel; `reviewers.json` and the registry
between them decide who fills each seat. A constraint that resolves to nothing is fatal:
degrading to "run without that vendor" produces a panel one axis short that reads
identically to a panel that reviewed and found nothing.

The registry is optional to the driver. A seat (or a judge/verifier entry) may carry a
literal `model` beside `select`: with `../model-registry` present, `select` resolves as
above and the literal is ignored; without it, the literal runs. A select-only seat on a
host with no registry dies naming the seat, for the same one-axis-short reason. Cost
lookups degrade the same way — no registry means `costUnknown`, never an invented
price.

- Consensus is **vendor-weighted**: one vote per vendor, not per seat. With one
  seat per vendor that is **six vendor votes** and nothing merges. The weighting
  is defined per vendor so that it survives roster changes: a second same-vendor
  seat would share its vendor's single vote, including in telemetry, which emits
  one row per vendor-participant either way.
- **`minVendors` is 3, below the seat count on purpose.** It is enforced up front
  and again at runtime when a phase produces its findings, and a seat drops out of
  those counts through a wrapper outage or an off-contract finding heading. Set
  at the seat count, one outage plus one formatting quirk would kill the chunk and
  force every seat to re-run; at 3 it absorbs that and still cannot be satisfied
  by a self-review panel.
- **A counted seat is a hard dependency.** The driver dies when an enabled seat has
  no passing pre-flight, rather than skipping it, because a silently dropped vendor
  reads as a clean review. That is why a metered seat needs a funded balance before a
  run, and why adding a seat is an owner decision with a stated way back out.
- **Two of six finders are repo-aware** — F (Claude, hard read-only plan mode) and
  X (Codex, hard read-only sandbox). The other four are repo-blind, for different
  reasons: D and M are single API calls with every input inlined and no tools; Z runs a
  tool-less isolated CLI; G is diff-only. Blind seats are fed the key files via
  `-ContextPath`. For the CLI wrappers that have no per-invocation read-only mode
  (the retired Kimi and Grok ones, listed in `noSandboxWrappers`) blindness is a
  **write-isolation** constraint, not a claim they are untrusted with the source:
  pointing them at the live checkout under their global auto-approve default would let
  them WRITE the tree they are reviewing, which the hard-sandbox reviewers cannot. A
  detached-commit worktree satisfies it, and `SKILL.md` §4 states the one case (a
  target carrying uncommitted work) where the worktree route is not sufficient on its
  own. This still fixes v1's repo-blind abstention: v1 had only Anthropic repo-aware;
  v2 adds Codex.
- **A seat's tier is an honest label, not a ranking of worth.** G sits at
  `workhorse` because the best Gemini its CLI still serves is a Flash-class model; M
  sits at `workhorse` while it is new to the registry and has had no full panel run.
  Both are owner decisions recorded with the condition that would change them. Weigh
  a workhorse seat's findings accordingly, and read the current answer with
  `resolve.py --tier <tier> --vendor <vendor> --channel <channel>` rather than off
  this page.
- The judge stays the **Opus lineage** (Anthropic frontier, family `claude-opus`) —
  one coherent adjudicating voice, whose inputs are already six-vendor. Seat F is also
  Opus, an owner decision that accepts reviewer/judge lineage overlap in exchange for
  running on the plan already paid for; the cross-vendor judge-audit (Phase 3.5) is the
  check that overlap leaves in place. F is one Anthropic vendor vote, not an
  independent vote from the judge.

## How seats are billed, and what happens when one fails

`reviewers.json` uses a `fallbackWrapper` field. The driver resolves a
reviewer's wrapper as: **try `wrapper` (the subscription-backed CLI); on non-zero exit
(CLI missing, not logged in, subscription lapsed) fall back to `fallbackWrapper` (the API
path) and mark the run degraded-to-API for that vendor.** Only OpenAI carries a
fallback today (`codex` → `openai`). Google runs through Antigravity (`agy`) with none,
and the GLM seat has none by construction (its credential and isolation are the point).

Two seats are metered by design and have no subscription path to fall back from:
DeepSeek and Moonshot are API-only seats, each with a DPAPI-held credential on the
Windows host and a funded account balance. For them an exhausted balance is an outage.
An outage found at pre-flight stops the run, because the seat counts; one that happens
mid-run drops the seat from the phase's counts (marked unavailable, unpooled), and the
run continues only while `minVendors` is still met. Anthropic runs in-process under
Claude Code with no fallback needed.

## Wrapper contract

Every wrapper declares this required minimum:

```
-Instruction <text>
-DiffPath <file>
-FindingsPath <file>
-ContextPath "a;b;c"
-Model <id>
```

`-InstructionPath`, `-Effort`, `-RepoPath`, `-OutPath`, and
`-UsageSidecarPath` are optional capabilities. The driver introspects them and
passes only supported flags. Every wrapper returns review text on stdout and a
non-zero exit on failure, and declares a `PREFLIGHT_COMMAND` the host runs before
fan-out so an unauthenticated CLI or an unfunded API account is found before the
parallel round, not inside it.

Read-only and hermetic, by whatever the wrapper's tool allows: `codex exec
--sandbox read-only`; `claude --permission-mode plan`; for the API wrappers, a single
request with every input inlined. Repo access, when granted, is read-only
(`-RepoPath`). The two metered-API wrappers check that the response's own model field
equals the id they asked for, so a silent substitution fails loudly instead of being
scored as the seat's vote.

### Cost & tokens

Subscription-backed calls are flat-rate, so **real per-token cost is ~0**. Telemetry
therefore reports **putative cost** (the v1 treatment for Claude), computed from
best-effort token counts extracted from each CLI's JSON output
(`codex exec --json`, `claude -p --output-format json`). The two metered API seats
report a usage sidecar with `billingRoute: api`, priced at the registry list rate, which
is an upper bound because cache discounts are not modelled; the coding-plan seat
reports tokens with the cost left unknown. V2 added registry-backed pricing and an
explicit unknown-cost state because unavailable pricing and zero marginal subscription
spend are different facts. The live lookup and rendering policy sits in `SKILL.md`
beside the emission rules. Collectors recorded zero tokens when a CLI exposed no usage
(including `agy`), without changing outcome telemetry (issuesRaised / issuesAccepted).

## Phase design

### Phase 1 — blind independent find (6 reviewers, parallel)
F (Claude) and X (Codex) are repo-aware; Z, D, G and M are repo-blind and fed
`-ContextPath`. Each reviewer is blind to the others.

### Phase 2 — cross-examine (same 6, parallel)
All six attack the pooled, anonymised findings. Output is the per-finding verdict
format the phase brief owns; a seat that cannot take part is marked unavailable and
uncounted rather than substituted.

### Phase 3 — adjudicate (Opus judge)
Vendor-weighted consensus over six vendors. Judge reads the repo to settle contested
mechanisms.

### Phase 3.5 — judge-audit (mandatory on a merge-gating or HIGH-tier target, else opt-in)
A single cross-vendor pass (a non-Anthropic vendor; the manifest's `judgeAudit` pool
names it, today Codex) that audits the Opus judge's report for: findings silently
dropped between the pooled set and the report, severity mis-rating vs the evidence, and
consensus tags that don't match the vendor split. It does **not** re-review the code; it
checks the adjudication against its own inputs. Output: a short list of
`{findingId, issue, suggested correction}` the host folds back before Phase 4.
**Required** when the review gates a merge or the target classifies HIGH under the
repo's `.claude/review-policy.json` (see `SKILL.md` §3.5 for how a non-PR target is
tiered); optional otherwise, and the host runs it on request. There is no driver
flag: `run-review.ps1`
stops at the judgment boundary, so Phases 3 onward belong to the host and a flag
on the driver could never reach this phase.

The panel's multi-vendor inputs do not make it redundant. Those cover Phases 1-2;
Phase 3 is a single judge, and the one stage that can lose a finding outright.
Phase 4 cannot cover for it either — it only sees findings that reached the
report, verifies only Criticals/Highs/contested, and never inspects consensus
tags, so dropped, demoted and mislabelled findings all pass it untouched.

### Phase 4 — verify (cross-vendor pool)
Every Critical/High and every `[contested]` finding is verified by a fresh agent
that took no part in the report. Verifiers are drawn from the manifest's `verifier`
pool, assigned round-robin by vendor so no single vendor owns verification; the pool
is today an Anthropic workhorse member and Codex, both repo-aware. For a finding with
more than one failure mode, assign **diverse lenses** across vendors (correctness /
security / does-it-reproduce). Verifiers are agentic and construct repros where cheap.
Verdicts fold back as CONFIRMED / REFUTED / INDETERMINATE, additive annotations.
Access is declared per pool member, never role-wide, so a member without a hard
read-only mode can never be handed the live tree.

## Telemetry (Observatory)

The controller owns the live emission, attribution, and unknown-cost rules. The
Observatory schema was designed around participant-and-role identity because it upserts
on `(runId, reviewer, role)`; a repeated identity replaces that row. Attribution was
based on pooled Phase-1 provenance so the dashboard measures what each vendor found,
not which consensus labels it later supported. Unknown-cost state exists separately
from numeric cost because subscription usage and missing registry prices cannot safely
be represented by the same zero.

The dashboard compares each run to a roster of active reviewer vendors that is
**mirrored by hand** from `reviewers.json` into the web app. A seat change is therefore
two edits, one per repository, and forgetting the second fails silently in both
directions: a vendor missing from the mirror is ignored when counting, so a full panel
reads "complete" with that vendor invisible and a panel that lost the vendor reads
"complete" too. It reads as success, which is why it is written down. Seats retired
from the manifest move to the mirror's retired list, where their historical runs still
sort among the reviewers and count toward validity but not completeness.

## Files

Canonical skill (`~/.agents/skills/adversarial-review`), surfaced to other
runtimes through their configured junctions/discovery roots:
- `codex-review.ps1`, `agy-review.ps1`, `glm-review.ps1`, `deepseek-review.ps1`,
  `moonshot-review.ps1` — the live wrappers; `kimi-review.ps1`, `grok-review.ps1` stay
  on disk, with their tests, for a reinstatement
- `reviewers.json` — roster + `fallbackWrapper` + wrapper mapping (a wrapper file
  that exists but is absent from `wrappers` is unreachable; that is how `grok` sat
  unused after audit-ai-quality already had it)
- `emit-review-telemetry.ps1` — the vendor in `-Reviewer`'s ValidateSet. Omitting it
  loses that vendor's rows silently; `verify-audit-contract.ps1` now fails the build
  instead
- `run-review.ps1` — fallback resolver; roster already data-driven
- `briefs/phase3.5-judge-audit.txt`; `briefs/phase4-verify.txt` (note the pool)
- `SKILL.md` — roster, prerequisites, phase procedure, telemetry, cost
- retained legacy/API paths: `openai-review.ps1`, `gemini-review.ps1`

Observatory (its own repository, separate GitHub PR):
- `src/AiObservatory.Data/Entities/Provider.cs` — the provider enum member
- runs endpoint / `AdversarialReviewService.cs` — accept the vendor id
- `src/AiObservatory.Web/src/components/adversarialReviewGrouping*` + `api/client.ts` — the
  active and retired vendor lists that decide "N of M reviewers · complete", label/colour,
  and the test that pins both directions

## Non-goals / guardrails

- No transcript/DOM scraping. Every vendor runs headless via its CLI or a single API
  call; the Observatory ingests telemetry, never transcripts.
- No deleting a wrapper when its seat is retired — it stays on disk with its tests as
  the documented route back.
- The judge adjudicates and takes no Phase-1 seat of its own; the Opus lineage of
  seat F is the accepted overlap described under the roster.
- A new or materially updated model enters through a contained slot with its exit
  condition stated, never straight into a solo low-verifiability role; routing selects
  who does the work and never changes how the work is checked.
