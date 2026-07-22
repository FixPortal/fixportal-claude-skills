# Adversarial Review — v2 methodology (all-frontier, subscription-backed)

Status: spec for the v2 panel. Supersedes the v1 roster description in `SKILL.md`
once implemented. This document is the contract the wrappers, `reviewers.json`,
the driver, and the Observatory changes are built against.

## Motivation

Two changes make v2 possible:

1. **Every frontier vendor is now reachable on a flat-rate subscription**, not
   metered API credits — Anthropic (Claude Max 20x, incl. Fable in perpetuity),
   OpenAI (ChatGPT Pro 20x via the Codex CLI), Moonshot (Kimi Allegretto via the
   Kimi Code CLI), Google (Gemini via Google One). Cost stops being a design
   constraint; methodology quality is the only axis.
2. **Kimi Code and Codex are headless agentic CLIs** (`kimi -p`,
   `codex exec`) — direct analogues of `claude -p`. So a second and third
   non-Anthropic vendor can now walk the repository, not just read the diff.

The v1 panel had two structural weaknesses this release targets:

- **Repo-blind abstention.** Only the Anthropic reviewers had repo access; the
  cross-vendor reviewers (Gemini, OpenAI-API) abstained ("needs evidence")
  whenever a mechanism lived outside the diff. Those abstentions masqueraded as
  doubt at adjudication.
- **Judge and verifier were an Anthropic monoculture.** The two most
  decision-heavy steps — Phase-3 adjudication and Phase-4 verification — ran on a
  single vendor, re-correlating the error the panel exists to decorrelate.

## Panel roster (5 reviewers / 4 vendors)

| id | label | vendor | primary wrapper | fallback wrapper | repoAccess |
|----|-------|--------|-----------------|------------------|------------|
| B  | Claude Sonnet | anthropic | `claude` (Agent tool under Claude Code) | — | yes |
| F  | Claude Fable 5 | anthropic | `claude` | — | yes |
| X  | GPT (Codex) | openai | `codex` (ChatGPT Pro sub) | `openai` (API) | yes (sandbox read-only) |
| K  | Kimi (K2.7 Standard) | moonshot | `kimi` (Allegretto sub) | — | no (hermetic; see note) |
| G  | Gemini | google | `agy` (paid Google plan) | — | no (diff + `-ContextPath`) |

- Consensus is **vendor-weighted**: Anthropic (B+F) = one vote; OpenAI, Google,
  Moonshot one each → **four vendor votes**. B+F telemetry merges into one
  `anthropic/reviewer` row, as v1.
- **Three of five finders are repo-aware** — B, F (Claude, hard read-only plan
  mode) and X (Codex, hard read-only sandbox). Gemini and Kimi stay diff-blind,
  fed the key files via `-ContextPath`. Kimi ships blind deliberately: Kimi Code
  has no per-invocation read-only flag (global mode is `yolo`), so pointing it at
  the repo is a trust-boundary risk the hard-sandbox reviewers don't carry — flip
  `repoAccess:true` to enable `--add-dir` tracing, guarded only by prompt +
  git-tree. This still fixes v1's repo-blind abstention (v1 had only Anthropic
  repo-aware; v2 adds Codex).
- **Shipped Kimi model is `kimi-code/kimi-for-coding`** (K2.7 Coding, Standard —
  the CLI's own `default_model`). Was previously `-highspeed`, but that variant
  bills ~3x the credits for equivalent review output (the highspeed multiplier,
  not extra work), so a modest panel burned ~30% of the weekly allowance; Standard
  is the credit-sane default. `kimi-code/k3` (1M context, deeper) is a DISTINCT
  model — not the Standard tier of K2.7 — and was capacity-congested at its
  mid-Jul 2026 launch; swap to it per chunk only if the 1M window is needed, or
  to `-highspeed` only when speed is worth the 3x burn.
- The judge stays **Opus** (Anthropic) — one coherent adjudicating voice, whose
  inputs are already four-vendor. Reviewer≠judge decorrelation is preserved
  (Opus never reviews).

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

`reviewers.json` gains a `fallbackWrapper` field. The driver resolves a
reviewer's wrapper as: **try `wrapper` (the sub-backed CLI); on non-zero exit
(CLI missing, not logged in, sub lapsed) fall back to `fallbackWrapper` (the API
path) and mark the run degraded-to-API for that vendor.** The v1 API wrappers
(`openai-review.ps1`, `gemini-review.ps1`) are retained on disk, but only OpenAI
is wired as an automatic fallback. The retired Gemini CLI path is dormant for a
possible deliberate API re-enable.

Only OpenAI carries a fallback today (`codex` → `openai`). Google runs through
Antigravity (`agy`) with no fallback; Kimi is also sub-only. Anthropic runs in-process
via the Agent tool under Claude Code (no fallback needed).

## Wrapper contract (unchanged, uniform)

Every active wrapper — `claude`, `codex`, `kimi`, `agy`, `openai` — honours the same
contract so the driver treats them interchangeably:

```
-Instruction <text> | -InstructionPath <file>   (brief; file form preferred)
-DiffPath <file>                                 (required)
-FindingsPath <file>                             (Phase 2 only)
-ContextPath "a;b;c"                             (optional; ';'-joined repo files)
-Model <id>
-Effort <low|medium|high|xhigh|max>              (honoured where the CLI supports it)
-RepoPath <dir>                                  (optional; enables repo access where supported)
-OutPath <file>                                  (optional; else stdout)
-UsageSidecarPath <file>                         (optional; writes {inputTokens,outputTokens,costUsd})
```

Returns the review text on stdout (or `-OutPath`), non-zero exit on failure.
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
--output-format json`). When a CLI does not surface usage (including `agy`), tokens are 0 and cost
putative-from-0. Outcome telemetry (issuesRaised / issuesAccepted) is unaffected.

## Phase design

### Phase 1 — blind independent find (5 reviewers, parallel)
Unchanged in shape. New: Kimi (K) joins; X (Codex) is repo-aware, K (Kimi) is
diff-blind (hermetic; fed `-ContextPath`). Gemini via Antigravity remains
diff-blind with `-ContextPath`. Each reviewer is blind to the others.

### Phase 2 — cross-examine (same 5, parallel)
Unchanged. All five attack the pooled, anonymised findings.

### Phase 3 — adjudicate (Opus judge)
Unchanged. Vendor-weighted consensus over four vendors. Judge reads the repo to
settle contested mechanisms.

### Phase 3.5 — judge-audit (NEW, opt-in)
A single cross-vendor pass (default a non-Anthropic vendor — Kimi or Codex)
that audits the Opus judge's report for: findings silently dropped between the
pooled set and the report, severity mis-rating vs the evidence, and consensus
tags that don't match the vendor split. It does **not** re-review the code; it
checks the adjudication against its own inputs. Output: a short list of
`{findingId, issue, suggested correction}` the host folds back before Phase 4.
Off by default (flag `-JudgeAudit`); the panel's inputs are already multi-vendor,
so this is belt-and-braces for high-stakes runs.

### Phase 4 — verify (NOW cross-vendor pool)
Every Critical/High and every `[contested]` finding is verified by a fresh agent
that took no part in the report. v2 draws verifiers from a **cross-vendor pool**
— Sonnet, Kimi, Codex — assigned round-robin by vendor, so no single vendor
owns verification. For a finding with more than one failure mode, assign
**diverse lenses** across vendors (correctness / security / does-it-reproduce).
Verifiers are agentic and construct repros where cheap. Verdicts fold back
exactly as v1 (CONFIRMED / REFUTED / INDETERMINATE, additive annotations).

## Telemetry (Observatory)

- Per-run outcome events: one per vendor participant + judge. v2 = **5 emits**
  (anthropic merged B+F, openai, google, moonshot, + anthropic/judge).
- `emit-review-telemetry.ps1` `-Reviewer` ValidateSet gains `moonshot`.
- Observatory server: `Provider` enum gains `Moonshot`; the runs endpoint accepts
  `reviewer=moonshot`; the dashboard's "complete panel" notion moves from
  3-vendors+judge to **4-vendors+judge**, with a label/colour for Moonshot.
- Cost for all sub-backed vendors is putative; the dashboard already renders
  putative cost for subscription vendors.

## Files

Skill (`~/.claude/skills/adversarial-review`, git-tracked under `~/.claude`):
- NEW `codex-review.ps1`, `kimi-review.ps1`, `agy-review.ps1`
- `reviewers.json` — roster + `fallbackWrapper` + `moonshot` wrapper mapping
- `emit-review-telemetry.ps1` — `moonshot` in ValidateSet
- `run-review.ps1` — fallback resolver; roster already data-driven
- `briefs/phase3.5-judge-audit.txt` (NEW); `briefs/phase4-verify.txt` (note the pool)
- `SKILL.md` — roster, prerequisites, phase procedure, telemetry, cost
- retained legacy/API paths: `openai-review.ps1`, `gemini-review.ps1`

your observability service (`<workdir>/ai-observatory`, GitHub PR):
- `src/AiObservatory.Data/Entities/Provider.cs` — `+ Moonshot`
- runs endpoint / `AdversarialReviewService.cs` — accept `moonshot`
- `src/AiObservatory.Web/src/components/adversarialReviewGrouping*` + `api/client.ts` — 4-vendor completeness, Moonshot label/colour + test

## Non-goals / guardrails

- No transcript/DOM scraping. Every vendor runs headless via its CLI; the
  Observatory ingests telemetry, never transcripts.
- No retiring of the API wrappers — they remain the documented fallback.
- Opus stays judge-only, never a blind reviewer (preserves reviewer≠judge).
