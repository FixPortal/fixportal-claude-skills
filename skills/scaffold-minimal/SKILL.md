---
name: scaffold-minimal
description: Use when converting traditional ASP.NET controllers to minimal APIs, or when setting up minimal API projects with OpenAPI and Scalar support. Triggers include requests to convert controllers, migrate to minimal APIs, or add OpenAPI/Scalar to a project.
---

# Scaffold Minimal APIs

## Overview

Convert traditional ASP.NET controller-based projects to minimal API style with OpenAPI and Scalar support for development builds.

## When to Use

- Converting existing controller-based projects to minimal APIs
- Adding OpenAPI and Scalar support to an existing minimal API project
- When asked to "convert controllers", "use minimal APIs", or "add Scalar"

## Conversion Rules

### Controller to Endpoints

- Each `{Name}Controller.cs` becomes `{Name}Endpoints.cs` in an `Endpoints/` folder
- The class becomes a `static class` named `{Name}Endpoints`
- A single extension method is added: `static IEndpointRouteBuilder Map{Name}Endpoints(this IEndpointRouteBuilder app)`
- Inside the method, create a route group using the original controller name with casing preserved: `var group = app.MapGroup("{Name}")`
- Each controller action becomes a mapping on the group, using the appropriate HTTP method (`MapGet`, `MapPost`, `MapPut`, `MapDelete`, etc.)
- Route templates from `[Http*("route")]` attributes are preserved on the group mappings
- Constructor-injected dependencies become lambda parameters
- The extension method returns the `IEndpointRouteBuilder` for chaining
- Delete the `Controllers/` folder once all controllers have been converted and no files remain

### Program.cs Updates

- Remove `builder.Services.AddControllers()`
- Remove `app.UseAuthorization()` if only present for controllers (keep if other auth is configured)
- Remove `app.MapControllers()`
- Add `builder.Services.AddOpenApi()` in the services section
- Add a development-only block for OpenAPI and Scalar:
  ```csharp
  if (app.Environment.IsDevelopment())
  {
      app.MapOpenApi();
      app.MapScalarApiReference();
  }
  ```
- Add `app.Map{Name}Endpoints()` for each converted endpoint class

### Package Requirements

- `Microsoft.AspNetCore.OpenApi` — latest version compatible with .NET 10
- `Scalar.AspNetCore` — latest version
- If the project uses central package management (`Directory.Packages.props`), add `PackageVersion` entries there and use versionless `PackageReference` in the project file
- If not using central package management, add versioned `PackageReference` entries directly in the project file

## Example

A controller like this:

```csharp
[ApiController]
[Route("[controller]")]
public class CompanyController(IFusionCache cache) : ControllerBase
{
    [HttpGet("database/{name}")]
    public Company? GetDatabase(string name)
    {
        return FakeDatabase.GetCompanyByName(name);
    }

    [HttpGet("cached/{name}")]
    public Company? GetCached(string name)
    {
        return cache.GetOrSet(name, _ => FakeDatabase.GetCompanyByName(name));
    }
}
```

Becomes:

```csharp
public static class CompanyEndpoints
{
    public static IEndpointRouteBuilder MapCompanyEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("Company");

        group.MapGet("database/{name}", (string name) =>
        {
            return FakeDatabase.GetCompanyByName(name);
        });

        group.MapGet("cached/{name}", (string name, IFusionCache cache) =>
        {
            return cache.GetOrSet(name, _ => FakeDatabase.GetCompanyByName(name));
        });

        return app;
    }
}
```

## Checklist

When converting a project to minimal APIs, verify:

- [ ] Each controller converted to a static endpoint class in `Endpoints/`
- [ ] Route groups preserve original controller name casing
- [ ] All HTTP verb mappings and route templates preserved
- [ ] Constructor-injected dependencies moved to lambda parameters
- [ ] `Controllers/` folder deleted if empty
- [ ] `builder.Services.AddControllers()` removed from `Program.cs`
- [ ] `app.MapControllers()` removed from `Program.cs`
- [ ] `builder.Services.AddOpenApi()` added to `Program.cs`
- [ ] `app.MapOpenApi()` and `app.MapScalarApiReference()` added in development block
- [ ] `app.Map{Name}Endpoints()` added for each endpoint class
- [ ] Required packages added (`Microsoft.AspNetCore.OpenApi`, `Scalar.AspNetCore`)
- [ ] Packages use central package management if `Directory.Packages.props` exists
- [ ] Project builds successfully

## Common Mistakes

- **Removing `app.UseAuthorization()` when other middleware still needs it.** Only remove it if it was there *solely* for controllers; keep it when any auth is configured — and mind its order in the pipeline.
- **Forgetting to register an endpoint class.** Every `Map{Name}Endpoints()` must be called in `Program.cs`, or that group's routes silently 404.
- **Exposing OpenAPI/Scalar in production.** Keep `MapOpenApi()` / `MapScalarApiReference()` inside the `IsDevelopment()` guard — don't lift them out.
- **Hardcoding .NET 10.** Package versions track the project's target framework; on a `net9.0` project use the latest `net9.0`-compatible `Microsoft.AspNetCore.OpenApi`.