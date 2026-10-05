# Controller-to-minimal conversion contract

## Contents

- [Conversion Rules](#conversion-rules)
- [Behavior Inventory — Required Before Editing](#behavior-inventory--required-before-editing)
- [Controller to Endpoints](#controller-to-endpoints)
- [Program.cs Updates](#programcs-updates)
- [Package Requirements](#package-requirements)
- [Self-contained route example](#self-contained-route-example)


Read this entire reference before converting any controller. Partial conversion is unsafe.

## Conversion Rules

### Behavior Inventory — Required Before Editing

Create a project/assembly/controller/action/parameter ledger before conversion.
For every row, record the source behavior, its minimal-API equivalent, and the
test that proves parity. Inventory at least:

- `AddControllers(...)`, `ApiBehaviorOptions`, global filters, MVC conventions,
  formatters, and JSON configuration
- effective route templates, HTTP methods, route names, order, constraints,
  defaults, optional parameters, and link-generation behavior
- authorization and anonymity: `[Authorize]` policies, roles, schemes, and
  `[AllowAnonymous]`
- MVC filters, custom attributes, conventions, CORS, antiforgery, rate limits,
  caching, API versioning, names, and tags
- binding source, name, optionality, and defaults for route, query, header,
  body, form, and service parameters
- `[ApiController]` inference, model validation, automatic 400 responses, and
  problem details
- request and response content types, formatters, status codes, headers,
  content negotiation, link generation, and declared response metadata

Map each behavior explicitly: for example, use `.RequireAuthorization(...)`,
`.AllowAnonymous()`, typed handler parameter attributes, endpoint filters,
`.Accepts(...)`, `.Produces(...)`, `.WithMetadata(...)`, and `Results` or
`TypedResults` where they preserve the original contract. A successful build is
not parity. MVC filters, formatters, and `[ApiController]` behavior do not carry
over automatically; implement and test an equivalent or stop and report the
unsupported behavior. Keep the controller and its required MVC registrations
until every ledger row is mapped and verified.

### Controller to Endpoints

- Each `{Name}Controller.cs` becomes `{Name}Endpoints.cs` in an `Endpoints/` folder
- The class becomes a `static class` named `{Name}Endpoints`
- A single extension method is added: `static IEndpointRouteBuilder Map{Name}Endpoints(this IEndpointRouteBuilder app)`
- Inventory every controller- and action-level `IRouteTemplateProvider`, including
  its template, HTTP methods, `Name`, and `Order`
- Derive each final attribute route exactly as ASP.NET Core does:
  1. Combine every controller template with every relative action template; a
     missing action template contributes an empty suffix.
  2. Treat an action template beginning with `/` or `~/` as absolute: strip the
     marker and do not combine it with a controller template.
  3. Expand `[controller]`, `[action]`, and `[area]` using their effective names
     after combination; preserve escaped tokens and configured transformers.
  4. Preserve every HTTP method, constraint, default, optional parameter,
     catch-all, route name, and order value.
- Map the full derived templates directly. Use `MapGroup` only when factoring a
  common literal prefix leaves the exact same final route and metadata set.
- For conventional routes, inherited/custom route providers, transformers, or
  conventions, inspect the effective runtime endpoints. If any route cannot be
  represented exactly, stop and keep the controller.
- Compare the controller and minimal route tables through `EndpointDataSource`
  before deletion, including template, HTTP methods, name, and order; require an
  exact multiset match for the converted actions
- Constructor-injected dependencies become lambda parameters
- The extension method returns the `IEndpointRouteBuilder` for chaining
- Delete the `Controllers/` folder only after all controllers and every behavior
  ledger row have been converted and verified

### Program.cs Updates

- Remove `builder.Services.AddControllers()` only when no retained controller or
  mapped behavior still depends on MVC services
- Remove `app.UseAuthorization()` only when no retained controller, converted
  endpoint, or other pipeline behavior requires its authorization semantics or
  ordering
- Remove `app.MapControllers()` only when no retained controller remains
- Add `app.Map{Name}Endpoints()` for each converted endpoint class

**OpenAPI and Scalar are CONDITIONAL, not part of a conversion.** Add them only when the
caller asked for them, or when the app already exposes those surfaces. A controller→minimal
conversion promises no change to the observable HTTP contract; adding a documentation
endpoint and a new package dependency to every conversion breaks that promise for a caller
who asked only for parity. The skill's frontmatter separates the two triggers deliberately.

When they ARE wanted:

- If the app **already exposes** OpenAPI/Scalar, preserve its existing environment
  gating exactly — converting controllers must not change when those surfaces are
  served. The development-only wrapper below is for **newly introduced** endpoints.
- Add `builder.Services.AddOpenApi()` in the services section
- Add a development-only block for OpenAPI and Scalar:
  ```csharp
  if (app.Environment.IsDevelopment())
  {
      app.MapOpenApi();
      app.MapScalarApiReference();
  }
  ```
- Add `using Scalar.AspNetCore;` (or a global using) so `MapScalarApiReference()` resolves

### Package Requirements

- `Microsoft.AspNetCore.OpenApi` — the major version **must match the target
  framework major version**: use the `9.x` series for `net9.0` projects and the
  `10.x` series for `net10.0` projects. Do not use "latest" blindly — `10.x`
  targets `net10.0` only and will not resolve on a `net9.0` project.
- `Scalar.AspNetCore` — latest version
- If the project uses central package management (`Directory.Packages.props`), add `PackageVersion` entries there and use versionless `PackageReference` in the project file
- If not using central package management, add versioned `PackageReference` entries directly in the project file
- Before enabling ASP.NET OpenAPI source generation, inspect the target framework and the resolved `Microsoft.AspNetCore.OpenApi` dependency, then check the `Microsoft.OpenApi` version in whichever of the two schemes the project uses — they are **alternatives, not layers**: a centrally managed project pins in `Directory.Packages.props` and carries versionless `PackageReference` entries, while a direct project pins in the `.csproj`. A versionless `PackageReference` under central management is correct and is not a missing pin.

  | Target stack | Target framework | Compatible `Microsoft.OpenApi` line |
  |---|---|---|
  | ASP.NET Core 10 and earlier | `net10.0` or earlier | `2.x` (`<3.0.0`) |
  | ASP.NET Core 11 and later | `net11.0` or later | supported `3.x` |

  Verified 2026-10-03: [Microsoft.AspNetCore.OpenApi 11.0.0-rc.1.26425.128](https://www.nuget.org/packages/Microsoft.AspNetCore.OpenApi/11.0.0-rc.1.26425.128) targets `net11.0` and declares `Microsoft.OpenApi >= 3.10.0 && < 4.0.0`. Use the resolved package's supported range; check it again when adopting a later prerelease or stable version.

  Preserve 2.x for ASP.NET Core 10 and earlier source-generation stacks because
  `Microsoft.OpenApi 3.x` is incompatible there — that half IS observed. For ASP.NET Core
  11 and later, follow the supported dependency line of the matching
  `Microsoft.AspNetCore.OpenApi` package; do not force a universal Microsoft.OpenApi ceiling.
  For a brand-new project, run `scaffold-dotnet` first, then add this
  minimal-API/OpenAPI delta.

## Self-contained route example

Source controller:

```csharp
[ApiController]
[Route("api/[controller]")]
public sealed class GreetingController : ControllerBase
{
    [HttpGet("{name}", Name = "GetGreeting")]
    public ActionResult<string> Get(string name) => $"Hello, {name}";
}
```

After token expansion, its route is `api/Greeting/{name}`. This equivalent endpoint uses framework types only:

```csharp
public static class GreetingEndpoints
{
    public static IEndpointRouteBuilder MapGreetingEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("api/Greeting/{name}", (string name) =>
            Results.Text($"Hello, {name}", "text/plain"))
            .WithName("GetGreeting")
            .Produces<string>(contentType: "text/plain");

        return app;
    }
}
```

**Why `Results.Text` and not `TypedResults.Ok` here.** `ActionResult<string>` returning a
bare string goes through MVC's `StringOutputFormatter` for a default `Accept: */*`
request: the body is `Hello, Ada` with content type `text/plain`. `TypedResults.Ok("Hello, Ada")` JSON-serialises instead — the
body becomes `"Hello, Ada"`, quotes included, as `application/json`. Both the payload and
the content type change, which is exactly the observable contract this skill promises not
to touch, and `.Produces<string>()` only sets metadata so it hides the difference rather
than fixing it. A `string`-returning action is the one case where the minimal-API default
is not the faithful conversion. Where the action returns a DTO, `TypedResults.Ok` is
correct only when both sides serialise identically — and that is a configuration
question, not a default. MVC and minimal APIs carry independent JSON options (naming
policies, converters, null handling), so a `JsonOptions` drift on either side changes
the DTO body even though both "JSON-serialise". Check both configurations and add a
body/content-type parity test before replacing the controller; if the serialisers
cannot be made equivalent, retain the controller.

One caveat on the default above: `text/plain` is what MVC serves for the default
`Accept: */*` case. A request with a concrete `Accept: application/json` negotiates
past `StringOutputFormatter` and gets a JSON-serialised, quoted body
(`"Hello, Ada"` as `application/json`) — verified against a `net10.0` project. An
unconditional `Results.Text(..., "text/plain")` answers `text/plain` to that client
too. If the inventory shows callers that send a concrete JSON `Accept` header, record
the difference and reproduce it deliberately (for example `Results.Json` when JSON is
requested), or keep the controller; do not let the example's default case read as the
whole contract.

Verify the route table and response contract before deleting the controller.
