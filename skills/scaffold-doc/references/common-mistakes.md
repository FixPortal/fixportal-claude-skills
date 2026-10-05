# Markdown common mistakes

Use this as the final rendering and portability check.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Bold `**Key:**` header block instead of destination-supported YAML frontmatter | Use a real `---` YAML block only where the destination consumes it, such as an Obsidian vault note |
| Scope/caveats parked at the bottom | Lead with the orientation blockquote under the H1 |
| Tables only, zero diagrams | Add a load-bearing diagram wherever shape/hierarchy/relationship matters |
| Renderer chosen by where the file is stored | Route by the figure's JOB. Mermaid when it tracks a moving target and is maintained alongside the code; the `diagram-design` skill when landing with a non-author reader is the deliverable — onboarding, an architecture guide, hand-over material. A `docs/` path predicts neither. See [diagram-renderers.md](diagram-renderers.md) |
| A guide written to be explained out loud left on renderer-default diagrams | That is the `diagram-design` row. Comprehension is the deliverable there, and flat Dagre output with no focal hierarchy actively works against it |
| Hand-authoring branded SVG inside this skill | Invoke `diagram-design` — it owns the skin, the focal rule, the node budget, and three checkers this skill does not have |
| Committing a `diagram-design` figure into a theme-aware page unpinned | Its hexes are literal and single-theme. Pin a light plate behind it, or maintain a light and a dark file |
| Bare identifiers in data rows | Add a plain-English description column named for what it carries |
| Truncated IDs (`1234abcd-…`) anywhere | Full IDs in the appendix; truncation only ever in inline prose |
| Slow build-up to the finding | Executive summary states the conclusion first |
| Diagram added for decoration | If it carries no information a table couldn't, cut it |
| Unquoted mermaid node label starting with `/` or containing `(` | **Quote the label** — `P["/api/parse"]`, not `P[/api/parse]`; `P["Cost (USD)"]`, not `P[Cost (USD)]`. A label starting with `/` is read as the *parallelogram* shape (`[/ … /]`) and never closes; an unquoted `(` is read as node-shape syntax. Both fail with `Lexical error … Unrecognized text`. Quoting makes `["` the opener and disambiguates. Bare `:` and `,` inside an unquoted label render fine in practice — quoting them is optional, not required. Same shape-collision risk applies to inline `:::class` (prefer a separate `class A,B name` statement) and `-.text.->` (prefer `-.->\|"text"\|`) |
| Mermaid block shipped unvalidated | Render it before shipping: `npx -y @mermaid-js/mermaid-cli@11.16.0 -i d.mmd -o d.svg`. Exit 0 = it parses. Cheaper than the reader finding the error. **Pin the version** — a bare `npx -y <pkg>` runs whatever the registry serves at that moment, which is a rug-pull surface |
| Using report skeleton for a README | README has its own sub-template — no ledger, no executive summary, no appendix of infra IDs |
| Hard-wrapped prose in an Obsidian vault document | Vault notes take one paragraph per line and soft-wrap to the pane; hard wrapping leaves the reading pane half empty in source and live-preview. Hard wrap at ~78 columns is for repo-committed Markdown only, where diffs are read |
| `author` in a repo-committed README | Author is vault-doc convention; omit it from anything in source control |
| Treating missing `tags` as a visibility failure | Untagged notes remain visible by default when no graph filters hide them; tags alone do not decide visibility—Graph Search/tag filters, the Orphans toggle, and excluded-file patterns can hide notes. Add a `tags` array when taxonomy or tag-based filtering needs it |
| CSharpier repo documents only `check`, or a global install | Give contributors `dotnet tool restore` then `dotnet csharpier format .`; describe the read-only CI check separately. |
| Plain `>` for warnings/notes/important caveats (audit/report/runbook/ADR, or vault docs) | Use `> [!WARNING]` / `> [!NOTE]` / `> [!IMPORTANT]` callout blocks — rendered by both GitHub and Obsidian. Exception: a README rendered by the NuGet gallery (see [templates.md](templates.md#doc-type-sub-templates)) stays plain `>` — that renderer doesn't support GFM alerts; a non-package repo README may use callouts |
| Actions-taken ledger in a new package README | Ledger is for post-hoc audit reports; omit from READMEs authored fresh |
