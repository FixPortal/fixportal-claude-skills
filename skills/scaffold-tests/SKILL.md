---
name: scaffold-tests
description: Use when creating or normalizing .NET/C# test projects (xUnit or NUnit) — adding a test project for a src/ project, scaffolding unit tests, or aligning test project structure. Triggers - add tests, create test project, scaffold unit tests, a src/ project missing its test project. .NET/C# only; for JS/TS frontend tests see scaffold-frontend.
---

# Scaffold Tests

Create .NET test projects that mirror `src/`, preserve the repository's framework, and defend meaningful behaviour.

## Project contract

- Put new projects in `tests/{ProjectName}.Tests`; preserve established names such as `.UnitTests`.
- Use `Microsoft.NET.Sdk`, the matching `ProjectReference`, and the solution's `tests` folder.
- With central package management, put concrete `PackageVersion` entries in `Directory.Packages.props` and versionless `PackageReference` entries in the test project.
- Restore, build, and run the repository's real test command before declaring success.

## Framework decision

Before adding a test project, inspect test `.csproj` files and `Directory.Packages.props` for `PackageReference`/`PackageVersion` entries. Use this branch:

| Detected framework | Add to an existing solution |
|---|---|
| xUnit v2 | Keep xUnit v2 and its established runner/package layout. |
| xUnit v3 | Keep xUnit v3 and its established runner/package layout. |
| NUnit | Keep NUnit and its established runner/package layout. |

If there is no existing test framework it is a new solution: use xUnit v3, with packages `xunit.v3`, `xunit.runner.visualstudio`, `Microsoft.NET.Test.Sdk`, `NSubstitute`, and `AwesomeAssertions` at target-compatible versions. These `xunit.v3` package and layout instructions apply only to a new project with no existing test framework. New xUnit v3 projects set `<OutputType>Exe</OutputType>`; retain `Microsoft.NET.Test.Sdk` and `xunit.runner.visualstudio`, and do not set `UseMicrosoftTestingPlatformRunner` merely for Stryker.

For an existing suite, keep its framework and runner; add `NSubstitute` and `AwesomeAssertions` if absent at target-compatible versions, without upgrading or converting either. Never convert an existing suite while scaffolding.

## Test style

- Name classes `{ClassName}Tests` and methods `Method_Scenario_ExpectedResult`.
- In xUnit, prefer `[Theory]`/`[InlineData]`; in NUnit use `[Test]` for one case and `[TestCase]` for inputs.
- Give each new test method an XML summary explaining what it validates and why; do not retrofit comments across an existing suite.
- Test behaviour, not trivial getters or implementation details.
- Assert with `using AwesomeAssertions;` and `.Should()`; never add `FluentAssertions` or use xUnit `Assert.*`.
- Use NSubstitute only for interceptable, app-owned dependencies in unit tests. Integration tests use real collaborators except at genuine external boundaries.
- Inject NodaTime `IClock`, or `TimeProvider` where NodaTime is not in play; never read static "now" in tested code.

xUnit example (v2/v3 only):

```csharp
using AwesomeAssertions;
using NSubstitute;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

public sealed class Fruit
{
    public Fruit(string name) => Name = name;

    public string Name { get; }
}

public interface IFruitCache
{
    Task<Fruit> GetAsync(string key, CancellationToken cancellationToken);
}

public sealed class FruitLookup
{
    private readonly IFruitCache _cache;

    public FruitLookup(IFruitCache cache) => _cache = cache;

    public Task<Fruit> FindAsync(string key, CancellationToken cancellationToken) =>
        _cache.GetAsync(key, cancellationToken);
}

public sealed class FruitLookupTests
{
    /// <summary>Returns the cached fruit so callers preserve the cache contract.</summary>
    [Fact]
    public async Task FindAsync_WhenFruitExists_ReturnsCachedFruit()
    {
        var expected = new Fruit("Apple");
        var cache = Substitute.For<IFruitCache>();
        cache.GetAsync("apple", Arg.Any<CancellationToken>())
            .Returns(Task.FromResult(expected));

        var found = await new FruitLookup(cache).FindAsync("apple", CancellationToken.None);

        found.Should().Be(expected);
    }
}
```

Do not substitute a concrete library merely to configure its extension methods: NSubstitute can only intercept virtual/interface calls. Wrap the external boundary in an existing app-owned interface; do not invent a wrapper unless production code genuinely needs that seam.

## Async and timing

Read [references/async-and-timing.md](references/async-and-timing.md) before writing async, concurrent, transport, or shutdown tests. The enforceable rules are:

- Await a real signal or poll the condition; never sleep then assert.
- Every operation that can miss completion gets one generous diagnostic hang ceiling.
- Use xUnit `[Fact(Timeout = ...)]` only after inspecting `xunit.runner.json` and confirming conservative scheduling or that parallelization is disabled. Aggressive or unknown scheduling requires an operation-local `WaitAsync(TimeSpan)` or a token backed by `CancelAfter`.
- A ceiling answers "did completion go missing?"; it is not a performance assertion.
- Gate negative assertions on a later positive signal; absence after an arbitrary delay proves nothing.
- A duration passed to production code is configuration, not a test timer.

## CI eligibility

Read [references/ci-test-budgets.md](references/ci-test-budgets.md) whenever tests or test projects will run in CI. PR eligibility is a cost contract with per-test, per-job, and aggregate ceilings; end-to-end, stress/load/soak, repeated concurrency, slow packaging, and compatibility matrices run weekly/manual in a structurally separate lane.

xUnit v3 only: when its runner permits a framework ceiling, keep cancellation attribution precise and fail through AwesomeAssertions:
```csharp
private const int HangCeilingMs = 30_000;

// Blocking teardown, off the pool.
private static Task RunOnDedicatedThread(Action action) =>
    Task.Factory.StartNew(action, CancellationToken.None,
        TaskCreationOptions.LongRunning, TaskScheduler.Default);

[Fact(Timeout = HangCeilingMs)]
public async Task Shutdown_WhenSendIsBlocked_ReturnsWithoutCompletingSend()
{
    try
    {
        await sender.Entered.WaitAsync(TestContext.Current.CancellationToken);
        await RunOnDedicatedThread(() => sink.Dispose())
            .WaitAsync(TestContext.Current.CancellationToken);
        sender.CompletedSends.Should().Be(0);
    }
    catch (OperationCanceledException)
        when (TestContext.Current.CancellationToken.IsCancellationRequested)
    {
        false.Should().BeTrue("the test's diagnostic hang ceiling expired");
    }
}
```

xUnit v2 lacks `TestContext.Current` and its timeout is undefined under parallelization; a kept v2 suite uses a token source:

```csharp
using var ceiling = new CancellationTokenSource();
ceiling.CancelAfter(HangCeilingMs);
// Pass ceiling.Token to WaitAsync; the catch filters on ceiling.IsCancellationRequested.
```

## Common mistakes

| Mistake | Use instead |
|---|---|
| One fact per input | One parameterized theory |
| `Assert.*` or `FluentAssertions` | AwesomeAssertions `.Should()` |
| Substituting extension methods | An existing interceptable app boundary |
| Sleep, stopwatch, or tight timeout assertions | A real signal plus a generous hang ceiling |
| Framework timeout under aggressive/unknown scheduling | Operation-local `WaitAsync`/`CancelAfter` |
| Empty substitutes in integration tests | Real collaborators |
| Slow or inherently expensive coverage in PR CI | A separate weekly/manual extended-test project |

## Completion check

Confirm framework, structure, test style/timing/CI, and a green restore/build/test run.

For adequacy review rather than scaffolding, use `audit-tests`.
