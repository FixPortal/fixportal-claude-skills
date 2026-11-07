<!-- Read directly by the fix-slice subagent (Phase 5). These are binding rules, not background reading — a conflict between a slice's instructions and this file gets reported, never silently resolved by picking one (see fix-slice.md). -->

# Stack conventions — test-adequacy audit fix pass

Apply the row matching the stack of the code under test. Do not mix conventions across stacks within one slice.

| Stack | Framework | Assertions | Mocking | Coverage | Mutation |
|---|---|---|---|---|---|
| .NET | xUnit v3 (`xunit.v3`) — or match the project's existing framework rather than mixing versions | AwesomeAssertions (`using AwesomeAssertions;`), `.Should()`. Never `Assert.*`. Never the `FluentAssertions` package (it went commercially licensed at v8; AwesomeAssertions is the Apache-2.0 fork, same API, `AwesomeAssertions` namespace since v9) | NSubstitute in unit tests. Real instances in integration tests — never empty substitutes | `dotnet-coverage` | Stryker.NET |
| Frontend | Vitest | Vitest matchers + React Testing Library | Vitest mocks, sparingly | `vitest run --coverage` | Stryker (JS) only if already present — do not introduce |
| Node TypeScript (Vitest) | Vitest (tests import `describe`/`it`/`expect` from `vitest`, no globals; match the project's existing setup) | Vitest `expect` (no React Testing Library, no jsdom) | Vitest mocks and fake timers, sparingly | `vitest run --coverage` (v8 provider with `coverage.include` covering all of `src` so thresholds are not vacuous) | Stryker (JS) only if already present — do not introduce |
| Python (uv) | pytest, run as `uv run pytest` | Plain `assert` | Hand-written fakes and `monkeypatch`; match what the repo already has | coverage.py branch coverage: `uv run --with coverage coverage run --branch -m pytest -rs`, then `uv run --with coverage coverage report` (`--with` supplies coverage without editing `pyproject.toml` or `uv.lock`; the house layout declares no coverage dependency). Per-test durations from `uv run --locked pytest --durations=0 --durations-min=0` (a stale `uv.lock` makes it fail: report durations as unavailable, never let `uv run` rewrite the lockfile), since there is no TRX | No house tool. The only mutation step is the per-slice break-and-revert in `fix-slice.md`; do not introduce a mutation tool |

### Architecture tests

There is **no single house tool** for this. Match whatever the repo already uses:
- .NET: **TngTech.ArchUnitNET**, **NetArchTest.Rules**, or the house **`<YourOrg.CodeStyle>.ArchRules`** package — whichever the repo already has. Do not introduce a second one alongside it.
- Frontend: **archunit** (npm package).
- Node TypeScript (Vitest): no house default tool. `scaffold-typescript/references/architecture-tests.md` documents an optional ArchUnitTS recipe; if a repo already uses archunit that way, keep it. Match what the repo already uses and do not introduce a second one.
- Only when a repo has **no** architecture test at all does a house default apply: TngTech.ArchUnitNET (.NET) or archunit (frontend). Do not hand-roll a reflection-based or AST-based check that an already-adopted tool covers.
- Never mix architecture-test frameworks within one repo, same rule as every other row on this page.

### Contract tests

There is **no house standard** for contract testing. Match whatever the repo already uses for this. If the repo has none:
- Prefer serialization round-trip assertions (serialize, deserialize, compare) and golden-file assertions against the real wire format, using the existing test framework from the table above.
- Do **not** introduce a contract-testing framework (Pact or otherwise) without explicit approval — that is a new dependency and a new CI shape, not a slice-sized fix.

### Configuration tests

Assert against the real configuration binding/startup path (the actual `IConfiguration`/host-builder pipeline, the frontend's real env/config loader, or a Node service's real env-parsing path, parsed once at startup) — not a hand-built substitute config object. A test that constructs its own POCO and checks it binds correctly proves nothing about whether the real startup path binds it correctly.

## Rules that apply regardless of stack

- Async and timing tests follow `scaffold-tests/references/async-and-timing.md`:
  await a real signal where possible and use one generous diagnostic hang
  ceiling. Under xUnit Conservative scheduling or disabled parallelism that
  ceiling may be the Fact/Theory Timeout; under Aggressive or unknown scheduling
  use operation-local `WaitAsync(TimeSpan)` or a linked token with `CancelAfter`.
  `Thread.Sleep`, a bare `Task.Delay` used for synchronization, and elapsed-time
  assertions remain defects.
- Node TypeScript (Vitest): the injected-clock and event-driven async test rules are in `scaffold-typescript/references/language-rules.md`; follow them there.
- Python (uv): the event-driven async and timing rules are in `scaffold-python/SKILL.md` (the "Async and timing tests" bullet); follow them there.
- Prefer one well-parameterized `[Theory]` over several near-duplicate `[Fact]`s (Python: `@pytest.mark.parametrize`).
- A test that "flakes only under coverage" may be a TOOLING bug, not a timing bug — coverlet 10.0.1 emits invalid IL on .NET 10 (`InvalidProgramException`). Read the CI log before rewriting the test.
- End-to-end tests only where an e2e slice was explicitly approved.
- Do not add any tool to this file that you have not been told is in use in this estate.
