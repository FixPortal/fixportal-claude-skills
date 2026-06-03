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
