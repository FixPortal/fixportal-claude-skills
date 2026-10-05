---
name: ef-core
description: 'Use when Entity Framework Core design or implementation is in scope — DbContext / DbSet and entity design, OnModelCreating and IEntityTypeConfiguration mappings, query shaping and EF Core query debugging, migrations, value-converter / NodaTime mapping, or porting data-access logic into EF Core in a .NET project.'
---

# Entity Framework Core

## Overview

Use EF Core as the data-access boundary, keeping provider behavior explicit and
testing consequential mappings and queries against a real relational database.

Apply the active runtime instructions first, including the repository's existing
framework, provider, testing stack, and date/time boundaries.

Before non-trivial raw SQL, trigger mappings, or query-shape changes, read the EF
Core section of `~/.agents/notes/dotnet-runtime-traps.md`.

## Context and Model

- Keep one `DbContext` per bounded data model and use the normal scoped lifetime
  for web requests.
- Put reusable entity mappings in `IEntityTypeConfiguration<T>`; reserve
  `ConfigureConventions` for truly model-wide rules.
- Make keys, requiredness, lengths, indexes, relationships, delete behavior,
  concurrency tokens, precision, and provider column types explicit where the
  database contract depends on them.
- For SQL Server tables with triggers, configure
  `ToTable(..., table => table.UseSqlOutputClause(false))` on **EF Core 8+**. On EF Core 7
  the equivalent is `ToTable(tb => tb.HasTrigger("name"))` — `UseSqlOutputClause` does not
  exist there and will not compile. Honour the repository's existing framework version.

## Queries and Writes

- Project only the required columns and use `AsNoTracking()` for read-only work.
- Make pagination ordering deterministic; prefer keyset pagination when offsets
  become expensive.
- Prevent N+1 queries deliberately with projection, explicit loading, or a
  justified `Include`; inspect generated SQL for consequential query changes.
- Keep user data parameterized. In `SqlQuery<T>`, interpolation holes are
  parameters—even identifiers—so aliases and identifiers must be trusted literal
  SQL. Pass typed nullable values directly to `ExecuteSqlInterpolatedAsync`, not
  `DBNull.Value`.
- Use one `SaveChanges` transaction for one unit of work. Add an explicit
  transaction only when the unit spans multiple saves or external coordination.

## Migrations

- Keep migrations focused and inspect the generated SQL before production.
- Test migrations against the real provider when provider behavior matters.
- Verify trigger-bearing tables, destructive operations, data backfills, security
  policies, defaults, indexes, and NodaTime column types explicitly.

## Testing

- Match an existing test framework. New test projects use xUnit v3,
  NSubstitute, and AwesomeAssertions.
- Do not mock `DbContext` or `DbSet`. Use a real context with SQLite for ordinary
  relational integration tests and the production provider for provider-specific
  SQL, migrations, triggers, or query translation.
- Do not introduce a repository or specification merely to make EF mockable.
  Reuse one when the codebase already has that boundary or when repeated query
  composition demonstrates a real need; otherwise test pure collaborators
  directly and integration-test the real context.
- When replacing a provider in `WebApplicationFactory` on EF Core 8+, remove
  `IDbContextOptionsConfiguration<TContext>` as well as the context and options.

## NodaTime

Use NodaTime for domain time and keep BCL types at provider/I/O boundaries, as
defined by the active runtime instructions. Inject `IClock`; never read a static
clock in domain code.

- Npgsql: install `Npgsql.EntityFrameworkCore.PostgreSQL.NodaTime` and call
  `UseNodaTime()`.
- SQL Server: use explicit converters and verify `date`/`datetime2` migration
  types. Prefer these converters over a community package unless repetition is
  demonstrably costly.

### SQL Server mapping

```csharp
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using NodaTime;

public sealed class TradeConfiguration : IEntityTypeConfiguration<Trade>
{
    public void Configure(EntityTypeBuilder<Trade> builder)
    {
        builder.ToTable("Trades");
        builder.HasKey(trade => trade.Id);

        // LocalDate → DateTime (SQL Server date)
        builder.Property(trade => trade.SettlementDate)
            .HasColumnType("date")
            .HasConversion(
                value => value.ToDateTimeUnspecified(),
                value => LocalDate.FromDateTime(value));

        builder.Property(trade => trade.CreatedAt)
            .HasColumnType("datetime2")
            .HasConversion(
                value => value.ToDateTimeUtc(),
                value => Instant.FromDateTimeUtc(
                    DateTime.SpecifyKind(value, DateTimeKind.Utc)));
    }
}
```

For model-wide conventions and reusable converter classes, use
[the central-conventions alternative](references/nodatime-sql-server.md).

Supporting files: Run `test/verify-guidance-contract.ps1` for local contract checks.
