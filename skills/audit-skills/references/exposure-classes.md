# Exposure classes — what a skill discloses when its text leaves this box

A skill body is not private. Any runtime that mounts it puts the whole file into
a model prompt, and the model's vendor is whoever that runtime is pointed at.
A workspace sandbox does **not** contain this: skills are loaded from the
runtime's own home, not from the working directory, so restricting an agent to
one project folder restricts its file access and not its prompt contents.

Grade exposure on the defect scale, from what the skill body actually contains:

| Grade | Class | Examples |
|---|---|---|
| 🟥 | Credential material | API key, PAT, connection string, private key, `AccountKey=` |
| 🟧 | Identity and topology | personal email, machine-local absolute paths, private repo slugs, deployment hostnames, vault paths |
| 🟨 | Attribution | org or product name, bare drive letters, generic internal vocabulary |
| 🟩 | Generic | nothing beyond public technical content |

A 🟨 is not automatically a defect. Deliberate attribution (a CV-linked author
name, the `owner:` ownership marker) is a decision, not rot — record it as a
finding only when the mounting runtime is third-party and the user has not
accepted it.

## The token sweep

Run this case-insensitively over the skill directory. Build the alternation from your own
private identifiers - personal email prefixes, your user-profile path, vault path, org and
product names, internal codenames - plus a drive-path alternative. It is the same pattern
your public-mirror port gate should use, if you publish a sanitised copy of your skills.

```
<your-private-tokens>|(^|[^A-Za-z])[CDE]:\\
```

Three things the pattern cannot catch, so look for them by reading:

- **A hostname or endpoint containing no token.** A deployment URL names
  infrastructure whether or not the org appears in it.
- **A worked example that is a real private repo.** `project: <a real slug>`
  reads as illustrative and discloses the estate.
- **An instruction that makes the agent fetch private context at runtime.** A
  skill telling the agent to recall from a cross-project memory store, read a
  vault, or open a sibling repo exports whatever that returns — which is
  unbounded and invisible to any scan of the skill text itself. This is the
  highest-severity exposure a clean-scanning skill can carry.

## The `runtime-fetch` class

The JSON contract's `class` enum is `credential`, `identity-topology`,
`attribution`, `runtime-fetch`. Only the first three name rows in the grade table
above. `runtime-fetch` is the third unscannable risk — an instruction that makes
the agent fetch private context at runtime — and it has **no fixed severity**,
because the severity belongs to whatever the fetched store returns rather than to
the instruction. Grade it from what that store holds: read a sample of what the
command actually returns, from the directory the agent will run it in, and grade
the worst class in the output. Take that sample only in a first-party runtime.
When the audit itself runs through a third-party vendor, fetching the sample IS
the exposure the finding describes: grade from the store's documented contents
instead and record `sample not taken (third-party runtime)` in the evidence.

`generic` is a grade, not a class: a clean skill produces a 🟩 and no finding, so
it never appears in the enum.

## Accepted disclosures

Record here the disclosures the user has already accepted, and grade against them instead of
re-raising them on every run. A change to any of them is the user's call, not the audit's.
Typical entries:

- **Shared notes that name private repositories** (for example `~/.agents/notes`), which many
  skills tell the agent to read. If accepted, a skill whose only exposure is a pointer to them
  grades on its own body; report the shared-notes fetch once, in the cross-skill section.
- **Skills kept first-party only**, because they need real identifiers to work. Keep them out
  of third-party homes, and back the decision with a CI gate over the skill tree whose
  per-file allowlist names those skills (for example a `verify-private-identifiers.ps1`). One
  of them reappearing in a third-party home is a 🟧 reliability finding, not an exposure grade.
- **The ownership marker** (`owner: <your-org>`). A skill whose only hit is the marker grades 🟩.

## Scope gate

Exposure only bites where a skill is actually mounted. Grade it against the
`homes` the worker found, and say which of those homes is third-party. A skill
mounted only in first-party runtimes is 🟩 for exposure regardless of content,
recorded with that reason.
