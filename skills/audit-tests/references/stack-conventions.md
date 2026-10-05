<!-- Read directly by the fix-slice subagent (Phase 5). These are binding rules, not background reading — a conflict between a slice's instructions and this file gets reported, never silently resolved by picking one (see fix-slice.md). -->

# Stack conventions — test-adequacy audit fix pass

Apply the row matching the stack of the code under test. Do not mix conventions across stacks within one slice.

| Stack | Framework | Assertions | Mocking | Coverage | Mutation |
|---|---|---|---|---|---|
| .NET | xUnit v3 (`xunit.v3`) — or match the project's existing framework rather than mixing versions | AwesomeAssertions (`using AwesomeAssertions;`), `.Should()`. Never `Assert.*`. Never the `FluentAssertions` package (it went commercially licensed at v8; AwesomeAssertions is the Apache-2.0 fork, same API, `AwesomeAssertions` namespace since v9) | NSubstitute in unit tests. Real instances in integration tests — never empty substitutes | `dotnet-coverage` | Stryker.NET |
| Frontend | Vitest | Vitest matchers + React Testing Library | Vitest mocks, sparingly | `vitest run --coverage` | Stryker (JS) only if already present — do not introduce |
| Python (uv) | pytest, run as `uv run pytest` | Plain `assert` | Hand-written fakes and `monkeypatch`; match what the repo already has | coverage.py branch coverage: `uv run coverage run -m pytest -rs`, then `uv run coverage report`. Per-test durations from `pytest --durations`, since there is no TRX | No house tool. Hand-written mutants run by the orchestrator, recorded in the report; do not introduce one |

### Architecture tests

There is **no single house tool** for this. Match whatever the repo already uses:
- .NET: **TngTech.ArchUnitNET**, **NetArchTest.Rules**, or the house **`<YourOrg.CodeStyle>.ArchRules`** package — whichever the repo already has. Do not introduce a second one alongside it.
- Frontend: **archunit** (npm package).
- Only when a repo has **no** architecture test at all does a house default apply: TngTech.ArchUnitNET (.NET) or archunit (frontend). Do not hand-roll a reflection-based or AST-based check that an already-adopted tool covers.
- Never mix architecture-test frameworks within one repo, same rule as every other row on this page.

### Contract tests

There is **no house standard** for contract testing. Match whatever the repo already uses for this. If the repo has none:
- Prefer serialization round-trip assertions (serialize, deserialize, compare) and golden-file assertions against the real wire format, using the existing test framework from the table above.
- Do **not** introduce a contract-testing framework (Pact or otherwise) without explicit approval — that is a new dependency and a new CI shape, not a slice-sized fix.

### Configuration tests

Assert against the real configuration binding/startup path (the actual `IConfiguration`/host-builder pipeline, or the frontend's real env/config loader) — not a hand-built substitute config object. A test that constructs its own POCO and checks it binds correctly proves nothing about whether the real startup path binds it correctly.

## Rules that apply regardless of stack

- Async and timing tests follow `scaffold-tests/references/async-and-timing.md`:
  await a real signal where possible and use one generous diagnostic hang
  ceiling. Under xUnit Conservative scheduling or disabled parallelism that
  ceiling may be the Fact/Theory Timeout; under Aggressive or unknown scheduling
  use operation-local `WaitAsync(TimeSpan)` or a linked token with `CancelAfter`.
  `Thread.Sleep`, a bare `Task.Delay` used for synchronization, and elapsed-time
  assertions remain defects.
- Prefer one well-parameterized `[Theory]` over several near-duplicate `[Fact]`s.
- A test that "flakes only under coverage" may be a TOOLING bug, not a timing bug — coverlet 10.0.1 emits invalid IL on .NET 10 (`InvalidProgramException`). Read the CI log before rewriting the test.
- End-to-end tests only where an e2e slice was explicitly approved.
- Do not add any tool to this file that you have not been told is in use in this estate.
