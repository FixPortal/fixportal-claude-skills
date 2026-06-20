# Intentionally divergent files

Files listed here differ **by design** between `~/.claude/skills/` and
`~/.agents/skills/`. `sync-private-skills` reports them as "intentionally
divergent — skipped" and **never** syncs or re-flags them. Add a row (with a
reason) whenever a divergence is confirmed deliberate; remove one to let the file
sync again.

Format: one entry per line — `<skill>/<relative-path>` — then a reason.

---

- `adversarial-review/reviewers.json` — panel composition is host-specific. The
  Claude Code copy honours the global "Opus needs explicit approval" rule (Opus
  parked in `alternates`, Gemini active); the Codex/Antigravity copy keeps Opus
  active and warns against pairing a Gemini reviewer with an Antigravity/`agy`
  adjudication (same-vendor judge). Reconciling them would break one host.
- `current-skills/CurrentSkills.md` — generated per-home skill inventory. Each
  home has a different installed skill set (e.g. Claude-only `graphify`/`hone`;
  Codex-only `repo-harmonizer`), so the doc is regenerated in each home by the
  `current-skills` skill and must NOT be cross-copied — doing so would put one
  host's inventory into the other.
- `sync-private-skills/.last-sync-manifest.json` — single source of truth lives
  in `.claude` only; `.agents`/`.gemini` copies are inert artefacts of
  folder-level sync and diverge after every run.
