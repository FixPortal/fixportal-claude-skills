# Adversarial Review — v2 methodology (all-frontier, subscription-backed)

## Contents

- [Motivation](#motivation)
- [Panel roster (5 reviewers / 5 vendors)](#panel-roster-5-reviewers--5-vendors)
- [Where Kimi sits, and why](#where-kimi-sits-and-why)
- [Subscription-first, API-fallback](#subscription-first-api-fallback)
- [Wrapper contract](#wrapper-contract)
- [Cost & tokens under subscriptions](#cost--tokens-under-subscriptions)
- [Phase design](#phase-design)
- [Phase 1 — blind independent find (5 reviewers, parallel)](#phase-1--blind-independent-find-5-reviewers-parallel)
- [Phase 2 — cross-examine (same 5, parallel)](#phase-2--cross-examine-same-5-parallel)
- [Phase 3 — adjudicate (Opus judge)](#phase-3--adjudicate-opus-judge)
- [Phase 3.5 — judge-audit (mandatory on a merge-gating or HIGH-tier target, else opt-in)](#phase-35--judge-audit-mandatory-on-a-merge-gating-or-high-tier-target-else-opt-in)
- [Phase 4 — verify (NOW cross-vendor pool)](#phase-4--verify-now-cross-vendor-pool)
- [Telemetry (Observatory)](#telemetry-observatory)
- [Files](#files)
- [Non-goals / guardrails](#non-goals--guardrails)


Status: implemented v2 methodology. This document records the contract shared by
the wrappers, `reviewers.json`, the driver, and Observatory telemetry.

## Motivation

V2 is built on two changes:

1. **Every frontier vendor is now reachable on a flat-rate subscription**, not
   metered API credits — Anthropic (Claude Max 20x, incl. Fable in perpetuity),
   OpenAI (ChatGPT Pro 20x via the Codex CLI), Moonshot (Kimi Allegretto via the
   Kimi Code CLI), Google (Gemini via Google One). Cost stops being a design
   constraint; methodology quality is the only axis.
2. **Kimi Code and Codex are headless agentic CLIs** (`kimi -p`,
   `codex exec`) — direct analogues of `claude -p`. So a second and third
   non-Anthropic vendor can now walk the repository, not just read the diff.

V2 addresses two structural weaknesses in the v1 panel:

- **Repo-blind abstention.** Only the Anthropic reviewers had repo access; the
  cross-vendor reviewers (Gemini, OpenAI-API) abstained ("needs evidence")
  whenever a mechanism lived outside the diff. Those abstentions masqueraded as
  doubt at adjudication.
- **Judge and verifier were an Anthropic monoculture.** The two most
  decision-heavy steps — Phase-3 adjudication and Phase-4 verification — ran on a
  single vendor, re-correlating the error the panel exists to decorrelate.

## Panel roster (5 reviewers / 5 vendors)

| id | vendor | registry constraint | primary wrapper | fallback wrapper | repoAccess |
|----|--------|---------------------|-----------------|------------------|------------|
| F  | anthropic | `frontier`, family `claude-fable` | `claude` | — | yes |
| X  | openai | `frontier` | `codex` (ChatGPT Pro sub) | `openai` (API) | yes (sandbox read-only) |
| K  | moonshot | `workhorse` | `kimi` (Allegretto sub) | — | no (hermetic; see note) |
| G  | google | `frontier` | `agy` (paid Google plan) | — | no (diff + `-ContextPath`) |
| R  | xai | `frontier` | `grok` (grok.com sub, OAuth) | — | no (hermetic; no read-only flag) |

Seat **B** (anthropic `workhorse`) was retired to `alternates` when R was seated, leaving
one seat per vendor. `reviewers.json` carries the evidence and the re-enable condition;
it is deliberately not repeated here.

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
  seat per vendor that is **five vendor votes** and nothing merges. The weighting
  survives the roster because it is defined per vendor: seat B and F once shared
  Anthropic's single vote, and a second same-vendor seat would share one again,
  including in telemetry, which emits one `anthropic/reviewer` row either way.
- **Two of five finders are repo-aware** — F (Claude, hard read-only plan
  mode) and X (Codex, hard read-only sandbox). Gemini, Kimi and Grok stay diff-blind,
  fed the key files via `-ContextPath`. Kimi and Grok ship blind deliberately and
  for the same reason: neither CLI has a per-invocation read-only flag (Kimi Code's
  global mode is `yolo`; grok-review.ps1 passes `--always-approve`), so pointing either at
  the live checkout would let it WRITE the tree it is reviewing, which the
  hard-sandbox reviewers cannot. That is a **write-isolation** constraint, not a
  claim it is untrusted with the source — a detached-commit worktree satisfies it,
  and `SKILL.md` §4 states the one case (a target carrying uncommitted work) where
  the worktree route is not sufficient on its own. Flip
  `repoAccess:true` to enable `--add-dir` tracing, guarded only by prompt +
  git-tree. This still fixes v1's repo-blind abstention (v1 had only Anthropic
  repo-aware; v2 adds Codex).
- **Kimi's seat is `workhorse` and that is a COST constraint, not a capability
  one.** It resolves to whichever Moonshot model the registry ranks highest in the
  `workhorse` tier, independent of the user's current CLI default — read the current
  answer with `resolve.py --tier workhorse --vendor moonshot --channel cli` rather
  than off this page, which records the SHAPE of the panel and not its occupants.
  (Observed 2026-09-05: `kimi-code/kimi-for-coding`, K2.7 Coding, Standard. Named
  only so the cost reasoning below is checkable against something; it is not a pin,
  and it is exactly the sort of line the paragraph above warns against writing.)
  The seat previously used `-highspeed`, but that variant
  bills ~3x the credits for equivalent review output (the highspeed multiplier,
  not extra work), so a modest panel burned ~30% of the weekly allowance; Standard
  is the credit-sane default. `kimi-code/k3` (1M context, deeper) is a DISTINCT
  model — not the Standard tier of K2.7 — and was capacity-congested at its
  mid-Jul 2026 launch; swap to it per chunk only if the 1M window is needed, or
  to `-highspeed` only when speed is worth the 3x burn.
- The judge stays the **Opus lineage** (Anthropic frontier, family `claude-opus`) —
  one coherent adjudicating voice, whose inputs are already five-vendor.
  Reviewer≠judge decorrelation is preserved, and now structurally: F, the only
  Anthropic seat, is constrained to the Fable family, so it cannot drift onto the
  judge's model when Anthropic's frontier ranking changes. Under a bare `frontier`
  constraint it could, silently, and the panel would still report five vendors.

## Where Kimi sits, and why

Kimi is placed where it fixes v1's weaknesses, not merely as a fifth voice:

1. **Diff-blind Phase-1 finder** (with `-ContextPath`) — a fourth vendor whose
   errors decorrelate from the other three. (Design intent was repo-aware, but it
   ships blind for the yolo trust-boundary reason above; Codex is the
   non-Anthropic vendor that carries the repo-aware role instead.)
2. **Phase-4 verifier pool member** — see below; it breaks the Sonnet-only
   verification monoculture with an agentic, repro-constructing skeptic from a
   different vendor.

## Subscription-first, API-fallback

`reviewers.json` uses a `fallbackWrapper` field. The driver resolves a
reviewer's wrapper as: **try `wrapper` (the sub-backed CLI); on non-zero exit
(CLI missing, not logged in, sub lapsed) fall back to `fallbackWrapper` (the API
path) and mark the run degraded-to-API for that vendor.** The v1 API wrappers
(`openai-review.ps1`, `gemini-review.ps1`) are retained on disk, but only OpenAI
is wired as an automatic fallback. The retired Gemini CLI path is dormant for a
possible deliberate API re-enable.

Only OpenAI carries a fallback today (`codex` → `openai`). Google runs through
Antigravity (`agy`) with no fallback; Kimi is also sub-only. Anthropic runs in-process
via the Agent tool under Claude Code (no fallback needed).

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
non-zero exit on failure.
Read-only and hermetic: `codex exec --sandbox read-only`; Kimi (`kimi -p`, which
cannot combine with `--plan`) is run hermetically instead — throwaway scratch cwd,
copied context, repo not in the workspace, prompt forbids mutation;
`claude --permission-mode plan`. Repo access, when granted, is read-only
(`--add-dir` / `--add-dir` / `-RepoPath`).

### Cost & tokens under subscriptions

Sub-backed calls are flat-rate, so **real per-token cost is ~0**. Telemetry
therefore reports **putative cost** (the v1 treatment for Claude), computed from
best-effort token counts extracted from each CLI's JSON output
(`codex exec --json`, `kimi --output-format stream-json`, `claude -p
--output-format json`). V2 added registry-backed pricing and an explicit
unknown-cost state because unavailable pricing and zero marginal subscription spend are
different facts. The live lookup and rendering policy now sits in `SKILL.md` beside the
emission rules. Collectors recorded zero tokens when a CLI exposed no usage (including
`agy`), without changing outcome telemetry (issuesRaised / issuesAccepted).

## Phase design

### Phase 1 — blind independent find (5 reviewers, parallel)
Kimi (K) participates; X (Codex) is repo-aware, while K (Kimi) is
diff-blind (hermetic; fed `-ContextPath`). Gemini via Antigravity remains
diff-blind with `-ContextPath`. Each reviewer is blind to the others.

### Phase 2 — cross-examine (same 5, parallel)
Unchanged. All five attack the pooled, anonymised findings.

### Phase 3 — adjudicate (Opus judge)
Unchanged. Vendor-weighted consensus over five vendors. Judge reads the repo to
settle contested mechanisms.

### Phase 3.5 — judge-audit (mandatory on a merge-gating or HIGH-tier target, else opt-in)
A single cross-vendor pass (default a non-Anthropic vendor — Kimi or Codex)
that audits the Opus judge's report for: findings silently dropped between the
pooled set and the report, severity mis-rating vs the evidence, and consensus
tags that don't match the vendor split. It does **not** re-review the code; it
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

### Phase 4 — verify (NOW cross-vendor pool)
Every Critical/High and every `[contested]` finding is verified by a fresh agent
that took no part in the report. v2 draws verifiers from a **cross-vendor pool**
— Sonnet, Kimi, Codex — assigned round-robin by vendor, so no single vendor
owns verification. For a finding with more than one failure mode, assign
**diverse lenses** across vendors (correctness / security / does-it-reproduce).
Verifiers are agentic and construct repros where cheap. Verdicts fold back
exactly as v1 (CONFIRMED / REFUTED / INDETERMINATE, additive annotations).

## Telemetry (Observatory)

The controller owns the live emission, attribution, and unknown-cost rules. The
Observatory schema was designed around participant-and-role identity because it upserts
on `(runId, reviewer, role)`; a repeated identity replaces that row. Attribution was
based on pooled Phase-1 provenance so the dashboard measures what each vendor found,
not which consensus labels it later supported. Unknown-cost state exists separately
from numeric cost because subscription usage and missing registry prices cannot safely
be represented by the same zero.

## Files

Canonical skill (`~/.agents/skills/adversarial-review`), surfaced to other
runtimes through their configured junctions/discovery roots:
- `codex-review.ps1`, `kimi-review.ps1`, `agy-review.ps1`, `grok-review.ps1`
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
- `src/AiObservatory.Web/src/components/adversarialReviewGrouping*` + `api/client.ts` — vendor completeness count, label/colour + test

OUTSTANDING for `xai` as of 2026-09-18: `Provider.cs` on `main` already carries `Xai`,
but `adversarialReviewGrouping.ts` still hardcodes
`REVIEWER_ORDER = ['anthropic','google','openai','moonshot']` and derives
`EXPECTED_REVIEWER_VENDORS` from its length. xAI rows are therefore filtered out of the
completeness count, so a full five-vendor run renders "4 of 4 reviewers · complete" while
xAI is invisible — it reads as success, which is why it needs writing down rather than
noticing later.

## Non-goals / guardrails

- No transcript/DOM scraping. Every vendor runs headless via its CLI; the
  Observatory ingests telemetry, never transcripts.
- No retiring of the API wrappers — they remain the documented fallback.
- Opus stays judge-only, never a blind reviewer (preserves reviewer≠judge).
