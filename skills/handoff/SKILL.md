---
name: handoff
description: Use when work must cross a session boundary and context will be lost. Triggers — "/handoff", "hand this off to Codex", "I'm out of usage, move this to another agent", "I need to reboot, save where we are", "pick this up in a new session".
---

# Handoff

## Overview

Context does not survive a session boundary, and the artefacts normally left
behind are lossy: git records what changed but not what was tried and
rejected; memory records durable facts but excludes ephemeral state — the
half-finished thought, the one command that was about to run. `handoff`
writes the missing artefact, and writes it BEFORE the loss, not after.

It is not `close` (which parks a session and persists durable memory for
*this* agent to find later) or a current-state repository sweep. Those operate
from durable artefacts; `handoff` writes the brief before the context is lost. `handoff` produces
one thing: a brief a *different* session — possibly a different agent entirely —
can pick up cold, plus one resume line to invoke it with.

Canonical in ~/.agents/skills/, junctioned into ~/.claude/skills/,
~/.gemini/config/skills/, ~/.gemini/antigravity-cli/skills/, ~/.pi/skills/,
and ~/.pi/agent/skills/ — keep it
host-agnostic and MCP-free.

## Modes

| Invocation | Direction | Rules-diff |
|---|---|---|
| `/handoff codex` | this host -> Codex CLI | runs |
| `/handoff antigravity` | this host -> Antigravity / Gemini | runs |
| `/handoff claude` | this host -> Claude Code (run this *from* Codex) | runs |
| `/handoff kimi` | this host -> Kimi Code | runs |
| `/handoff copilot` | this host -> Copilot CLI | runs |
| `/handoff self` | this host -> fresh session, same host | skipped |
| `/handoff` | unknown | ask, then proceed |

The source is whichever agent is running this skill right now; the target is
the argument. Neither is baked into this file — resolve both at runtime. If
invoked bare, ask which target before doing anything else, then run the full
procedure below for the answer given.

## Procedure

### 1. Resolve the target and read its rule file

| Target | Rule file |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` |
| Codex | `~/.codex/AGENTS.md` |
| Copilot CLI | `~/.copilot/copilot-instructions.md` |
| Kimi Code | `~/.kimi-code/AGENTS.md` |
| Antigravity / Gemini | `~/.gemini/GEMINI.md` |

Codex and Copilot CLI are separate targets with separate rule files — do not
read one and assume it covers the other.

The table keys on CLI names, but a handoff is sometimes requested by **model**
("hand this to GPT Astra"). Never map a model name to a vendor from memory —
resolve it against the registry, matching on id and display name:

```text
python -c "import json, re; ms = json.load(open(r'<skills-home>/model-registry/registry.json'))['models']; t = lambda s: [x for x in re.split(r'[^a-z0-9]+', s.lower()) if x]; q = t('<name>'); print([(k, v.get('vendor'), v.get('tier')) for k, v in ms.items() if all(any(x in c for c in t(k) + t(v.get('display_name', ''))) for x in q)])"
```

Read the vendor off the result and continue as the CLI that serves that vendor
here: anthropic -> Claude Code, openai -> Codex, moonshot -> Kimi Code,
google -> Antigravity / Gemini. A vendor with no CLI on this box has no direct
target — say so in the brief rather than routing to a lookalike. Multiple hits
from ONE vendor still identify the vendor, which is all this step needs. But
an empty result, or one whose entries span more than one vendor, does not
identify a single vendor: the empty case is a model the registry does not
know, the multi-vendor case a query too loose to route, and both end the same
way — name no target and record what was asked for instead.

Read it at runtime — do not recall it from memory or from this session's own
rule file. Do not assume the rule files have reached parity; they have not,
and closing that gap on every handoff is why this step exists. Where the
target has no rule file, say so plainly in the brief rather than implying a
coverage that does not exist.

### 2. Gather git state — read-only

If no repository is in scope, this is an estate handoff: skip Git and PR discovery.
Fill the brief's state with these honest values:

- Repository: `estate`
- Branch: `none`
- Worktree: `none`
- Working tree: `N/A`
- Unpushed commits: `N/A`
- Open PR: `N/A`

Otherwise gather the repo name, branch, whether the cwd is a review worktree,
`git status --short`, unpushed commits (`git log '@{u}..HEAD' --oneline` or note
the branch has no upstream), and the open PR if `gh` is available and authenticated.

This step never writes: no commit, no stash, no push, no clean. A dirty tree
is reported so the receiver knows what they are inheriting; it is not
resolved on the receiver's behalf.

### 3. Establish the task from the conversation

Not from git — from what actually happened in this session: the goal; what
is done; the ONE concrete next action (a command or an edit, not a plan);
dead ends; decisions already made. If the next concrete action cannot be
stated, say so — "I do not know what comes next, here is where I got stuck"
is a usable handoff; an invented next step is not.

### 4. Diff the rules

Work out which convention areas this task actually touches — PR flow, review
worktrees, testing stack, EF Core, Azure/CI, QuickFIX/n, npm, Windows shell
selection, whatever is live for this task. For each one, check whether the
rule file read in step 1 already covers it. Inline only the gaps — the
target's existing coverage needs no restating. Skip this step entirely for
`self`: same host, same rule file, inlining it would be pure noise.

### 5. Recommend a model

| Task shape | Tier | Reasoning effort |
|---|---|---|
| Mechanical — exact-string edits, renames, executing a fully specified plan | `mechanical` | `low` |
| Implementation needing codebase understanding | `workhorse` | `medium` |
| Architecture, novel design, adversarial review | `frontier` | `high` |

Never name a model from memory or inspect raw roster slugs. Resolve the canonical
tier through `model-registry` at handoff time:

```text
python <skills-home>/model-registry/resolve.py --tier <tier> [--vendor <vendor>]
```

Use a vendor filter only when the target fixes the vendor (Claude → Anthropic,
Codex → OpenAI, Kimi → Moonshot, Antigravity → Google). Copilot remains tier-only
unless its current rule file defines a vendor. If resolution returns no model,
recommend the tier and say no available match was found. For a Claude tool surface,
translate a resolved family to its supported short alias as documented by
`model-registry`; do not pass a full API ID where the host accepts aliases only.

Routing facts that outlive any roster live in
`~/.agents/notes/model-routing-traps.md` — which vendor CLI fails where, and why (if that note is not present, proceed and record the assumption).
Read it here rather than restating its contents, so the two cannot drift apart.
That applies to entry 1 in particular: it has already been corrected once, so read
its current status before routing around any vendor CLI and **do not assume it still
means what it meant** when it was written.

A written brief is the handoff mechanism because context does not survive a session
boundary — not because any particular CLI cannot be invoked. That reason holds
whatever entry 1 says this week.

Recommend the tier the task warrants. Do not add an approval caveat for the
`frontier` tier — read the target's rule file (step 1) for whatever gating it actually
states today, and say nothing if it states none.

### 6. Write the brief and hand off

The output is a file, always — never chat text. When a repository is in scope, write it
under `<repo>/.claude/handoff`. No repository is in scope means an estate handoff: use the
stable estate key `estate`, not the cwd or host name, and `~/.agents/handoff/estate`.

**The filename is unique per request, and nothing in this directory is ever overwritten.**
Several agents work the same repository at once, so a shared or predictable output name is
one agent's brief silently destroying another's. The date and slug describe the request;
a random token makes the name collision-proof without coordinating with the other agents,
whose existence this skill cannot see.

In PowerShell, construct these paths with `Join-Path` — PowerShell 5.1 has no
path-safe string interpolation shortcut:

```powershell
$estateKey = 'estate'
$estateHome = Join-Path $HOME '.agents'
$estateHandoffRoot = Join-Path $estateHome (Join-Path 'handoff' $estateKey)
$handoffRoot = if ($repoRoot) { Join-Path $repoRoot (Join-Path '.claude' 'handoff') } else { $estateHandoffRoot }
# The request token, NOT a counter and NOT the slug: a counter has to read the
# directory to pick its next value, which is exactly the race between two agents
# that this name exists to survive.
$token = [guid]::NewGuid().ToString('n').Substring(0, 8)
$briefFile = Join-Path $handoffRoot "$date-$slug-$token.md"
$briefTemp = Join-Path $handoffRoot ".$date-$slug-$token.md.tmp"
```

Write through the temporary sibling so the rename into place is atomic — a
concurrent reader sees a whole brief or no brief, never a half-written one:

```powershell
New-Item -ItemType Directory -Force -Path $handoffRoot | Out-Null
Set-Content -LiteralPath $briefTemp -Value $brief -Encoding UTF8
[System.IO.File]::Move($briefTemp, $briefFile)
```

**The `File.Move` throw IS the never-overwrite guard** — it refuses an existing
destination, which is exactly the wanted behaviour, so do not add a `Test-Path` before it
and do not wrap it in a try that continues. With the token in the name it should never
fire; if it does, regenerate the token and re-run rather than reusing the name. What the
throw leaves behind is a `.tmp` sibling: the content was already written, and nothing
removes it. Clean it up on the failure path:

```powershell
Remove-Item -LiteralPath $briefTemp -WhatIf   # then, once the path is confirmed, without -WhatIf
```

Show the `-WhatIf` line and the path before removing anything. The file holds a brief that
was just written and not yet published, so it is the only copy of that content; the cleanup
is a convenience, and an unattended delete of the one artefact the operator might still
want is not.

Left in place, that file sits beside the briefs with a name close enough to be mistaken
for one, and the next run's directory listing shows a brief that was never published.

Every publish only ever **adds** a file, so no approval gate is needed and none of this
step may be turned into one that replaces or prunes. Do not write a `latest.md`, a
`current.md`, or any other fixed-name pointer alongside the briefs: a pointer is shared
mutable state between agents that cannot see each other, so the last writer wins and the
brief another session was about to resume from is gone with no trace that it existed.
The resume line below already carries the one path the receiver needs. A receiver who has
lost that line reads the directory instead — the names sort by date, and the newest for
this task is the current one:

```powershell
Get-ChildItem -LiteralPath $handoffRoot -Filter '*.md' | Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

Do not prune old briefs on the way past. They are another agent's context until that agent
says otherwise.

Briefs are session ephemera and must never reach a PR, so confirm the directory
is ignored — but test whether it is *ignored*, not whether it is *listed*:

```text
git -C <repo-root> check-ignore -q .claude/handoff/
```

Pass `-C <repo-root>` explicitly: `check-ignore` resolves its path against the
current directory, so running it from a subdirectory tests the wrong path,
reports the brief directory as unignored, and walks you into adding the very
`.gitignore` entry this step exists to avoid.

Exit 0 means ignored; do nothing. Only if that fails does `.gitignore` need a
new entry. A repo whose `.gitignore` is a fail-safe allow-list (`/*`, `/.*`)
already ignores the directory without naming it — appending a redundant rule
there would dirty a tracked file on the very branch you are about to hand over.
For the estate location, no repository is in scope, so there is no `.gitignore`
check or repository mutation.

Use this template. Every heading is a required slot; an empty slot gets an
honest "none" or "unknown", never padding:

```markdown
# Handoff: <source> -> <target>
**Date:** YYYY-MM-DD · **Repo:** <name or `estate`> · **Branch:** <branch or "none"> · **Worktree:** <path, "primary", or "none">

## Task
<goal, one or two sentences>

## State
- Working tree: <clean | N files modified, listed>
- Unpushed commits: <none | list>
- Open PR: <none | #N title, status>

## Done
## Next  (one concrete action — a command or an edit, not a plan)
## Dead ends  (tried and rejected, with the reason)
## Decisions already made

## Rules the target is missing
<only the gaps, only for areas this task touches. Omit entirely for `self`.>

## Traps that apply
<excerpt + pointer to the source agent's notes directory for the active runtime
(~/.agents/notes/*-traps.md).
Excerpt, do not dump.>

## Model recommendation
<tier, roster-bound name or an honest "roster unreadable", plus caveats>
```

Then print the resume line, naming **this request's own brief** by its **absolute** path —
the receiving CLI may not start in the repo root, and a receiver that cannot resolve the
path cannot read the brief that would have told it where the brief is. Print the full
filename including the token; an abbreviated or guessed name resolves to nothing:

```text
read <workdir>\repo\.claude\handoff\2026-09-16-fix-envelope-mapper-9f2c41ab.md and continue
```

## Red flags — STOP

- You are about to write a model name you did not read from a roster file.
- You are about to inline `CLAUDE.md` wholesale instead of diffing what the
  target already has.
- You are writing the brief into the chat instead of to a file. It dies with
  the session — that is the whole failure this skill exists to prevent.
- You cannot state the next concrete action and you are about to write a plan
  to cover for it.
- You are about to commit, stash, or push to "tidy up before the handoff".
  Report the dirty tree; do not resolve it.
- You are about to write a fixed-name output (`latest.md`, `current.md`, `handoff.md`) or
  otherwise produce a name a second agent in this repo could produce too. The brief you
  overwrite is one nobody gets to read again, and the agent relying on it finds out by
  resuming the wrong task.
