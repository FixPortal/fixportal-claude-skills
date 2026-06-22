---
name: scaffold-tests
description: Use when creating or normalizing .NET/C# test projects (xUnit) — adding a test project for a src/ project, scaffolding unit tests, or aligning test project structure. Triggers - add tests, create test project, scaffold unit tests, a src/ project missing its test project. .NET/C# only; for JS/TS frontend tests see scaffold-frontend.
---

# Scaffold Tests

## Overview

Create and maintain xUnit test projects that mirror the `src/` structure, using NSubstitute for mocking and AwesomeAssertions for assertions. Prioritize brevity and meaningful coverage — one well-parameterized theory replaces many redundant facts.

## When to Use

- Creating test projects for existing source projects
- Adding tests to a project that has none
- When asked to "add tests", "scaffold tests", or "create unit tests"
- When a `src/` project is missing its corresponding test project under `tests/`

## Test Project Structure

- Each `src/{ProjectName}` gets a corresponding `tests/{ProjectName}.UnitTests`
- Test projects use `Microsoft.NET.Sdk`
- Test projects must reference their corresponding source project via `ProjectReference`
- Test projects are added to the solution under the `tests` solution folder

## Naming Conventions

- Test project: `{ProjectName}.UnitTests`
- Test class: `{ClassName}Tests` (e.g., `CompanyEndpointsTests`)
- Test method: `MethodName_Scenario_ExpectedResult` (e.g., `GetDatabase_WithValidName_ReturnsCompany`)

## Test Style

### Prefer Theory over Fact

Use `[Theory]` with `[InlineData]` whenever a test can be parameterized — when multiple test cases differ only by input and expected output. Do not write multiple `[Fact]` methods that test the same logic with different values.

```csharp
// Preferred: one Theory covers multiple cases
[Theory]
[InlineData("Apple", true)]
[InlineData("NonExistent", false)]
public void GetByName_WithVariousNames_ReturnsExpectedResult(string name, bool shouldExist)
{
    var result = FakeDatabase.GetFruitByName(name);
    (result is not null).Should().Be(shouldExist);
}

// Avoid: separate Facts for each input
[Fact]
public void GetByName_WithApple_ReturnsFruit() { /* ... */ }
[Fact]
public void GetByName_WithNonExistent_ReturnsNull() { /* ... */ }
```

### Documentation

Every test method must have an XML doc comment explaining:
1. What the test validates
2. Why this test is a valid choice (what risk it mitigates or behavior it confirms)

```csharp
/// <summary>
/// Verifies that the cache is consulted before the database, returning cached values
/// when available. This ensures the caching layer is actually wired up and not bypassed.
/// </summary>
[Fact]
public void GetCached_WithCachedValue_ReturnsCachedResult()
```

### Assertions

Use AwesomeAssertions (`.Should()`) instead of xUnit's `Assert.*`. AwesomeAssertions is the free, Apache-2.0 fork of FluentAssertions. Import it with `using AwesomeAssertions;` — the 9.x line renamed the namespace from `FluentAssertions`, though the `.Should()` API is otherwise unchanged. Do not use the `FluentAssertions` package (v8+ is commercially licensed).

```csharp
// Preferred
result.Should().NotBeNull();
result!.Name.Should().Be("Apple");

// Avoid
Assert.NotNull(result);
Assert.Equal("Apple", result.Name);
```

### Mocking

Use NSubstitute for mocking dependencies:

```csharp
var cache = Substitute.For<IFusionCache>();
cache.GetOrSet(Arg.Any<string>(), Arg.Any<Func<CancellationToken, Fruit?>>())
    .Returns(expectedFruit);
```

NSubstitute is for **unit** tests. In integration tests use real instances, not empty
substitutes — substitute only the genuine external boundary. For time-dependent code,
inject NodaTime `IClock` (or .NET `TimeProvider` where NodaTime isn't in play) and supply
a fake/fixed clock in the test rather than reading `DateTime.UtcNow` / `SystemClock.Instance`.

### Async and timing

Tests that exercise async or concurrent behaviour (a fill landing, a race
resolving, a pipeline disposing, a message arriving) must be **event-driven**.
Await a real completion signal or poll a condition with a generous timeout —
never `Thread.Sleep`/`Task.Delay` "long enough" and then assert immediately,
and never assert a duration is `BeLessThan(tightThreshold)`.

A fixed sleep races the system under test: locally the machine is idle so it
passes, but on a contended CI runner the work either hasn't finished (the
assertion sees an empty or short collection) or an extra emission slips in (it
sees too many), or a tight duration ceiling is exceeded. The result is a test
that is green locally and flaky in CI — a structural defect, not bad luck.
Re-running masks it; converting it to event-driven fixes it.

```csharp
// Preferred: gate the assertion on an awaited signal / polled condition
await WaitForAsync(() => sink.Fills.Count == 1, timeout: TimeSpan.FromSeconds(5));
sink.Fills.Should().ContainSingle();

// Avoid: sleep-then-assert (races the runner) and tight duration ceilings
await Task.Delay(200);
sink.Fills.Should().ContainSingle();
elapsed.Should().BeLessThan(TimeSpan.FromMilliseconds(50));
```

Expose a completion hook the test can await (e.g. a `TaskCompletionSource` the
sink signals) rather than guessing a delay. Combine with the injected clock
above so the *passage* of time is controlled, not slept through.

### Brevity

- Do not write ten tests where one will do
- One well-parameterized `[Theory]` replaces many `[Fact]` methods
- Only test meaningful behavior — skip trivial getters/setters unless they contain logic
- Prefer fewer, comprehensive tests over many narrow ones, provided coverage is maintained

## Package Requirements

All packages must be at the latest versions compatible with .NET 10:

- `xunit.v3` — xUnit v3 for new solutions. When adding a test project to an existing solution, match the xUnit major version already in use (`xunit` for a v2 solution); do not mix v2 and v3.
- `xunit.runner.visualstudio`
- `Microsoft.NET.Test.Sdk`
- `NSubstitute`
- `AwesomeAssertions` — free Apache-2.0 fork of FluentAssertions; imported via `using AwesomeAssertions;` (9.x renamed the namespace). Do not use the `FluentAssertions` package (v8+ is commercially licensed).

If the solution uses central package management (`Directory.Packages.props`), add `PackageVersion` entries there and use versionless `PackageReference` entries in the test project files.

## Checklist

When scaffolding test projects, verify:

- [ ] Each `src/` project has a corresponding `tests/{Name}.UnitTests` project
- [ ] Test projects added to solution under `tests` solution folder
- [ ] Test projects reference their source project via `ProjectReference`
- [ ] All required packages added (`xunit.v3`, `xunit.runner.visualstudio`, `Microsoft.NET.Test.Sdk`, `NSubstitute`, `AwesomeAssertions`); xUnit major version matches the solution
- [ ] Packages use central package management if `Directory.Packages.props` exists
- [ ] `[Theory]`/`[InlineData]` used instead of `[Fact]` where inputs vary
- [ ] Each test method has an XML doc comment explaining what and why
- [ ] No redundant tests — brevity maintained with meaningful coverage
- [ ] AwesomeAssertions used for all assertions (no `Assert.*`)
- [ ] NSubstitute used for all mocking
- [ ] Async/timing tests are event-driven (await a signal or poll-with-timeout) — no `Thread.Sleep`/`Task.Delay`-then-assert, no tight `BeLessThan(TimeSpan)` ceilings
- [ ] Tests build and pass
