---
name: scaffold-minimal
description: Use when converting controllers in an existing ASP.NET project to minimal APIs, or adding minimal endpoints, OpenAPI, or Scalar to an existing project. Triggers include "convert controllers", "migrate to minimal APIs", and "add OpenAPI/Scalar". Do not use to create a new project; run scaffold-dotnet first, then use this skill only for the minimal-API/OpenAPI delta.
---

# Scaffold Minimal APIs

## Overview

Convert or augment an existing ASP.NET application without changing its observable HTTP, authorization, binding, validation, routing, or response contract.

Before converting any controller, read [the complete conversion contract](references/controller-conversion.md). Do not perform a partial inventory from this summary.

## Procedure

1. Inventory project-, assembly-, controller-, action-, and parameter-level behavior before editing. Include routes, methods, authorization, filters, binding, validation, content negotiation, status/results, endpoint metadata, MVC options, and pipeline dependencies.
2. For each behavior, record the minimal-API equivalent and a parity test. If an equivalent cannot be represented and tested, stop, report it, and keep that controller plus its required MVC services.
3. Derive effective routes exactly: combine controller/action templates, preserve absolute templates and multiple providers, expand tokens, and retain constraints, defaults, optionality, names, order, and HTTP methods. Conventional/custom routing requires inspecting runtime endpoints.
4. Map handlers and metadata. Use a route group only when factoring a literal common prefix preserves every final route and metadata set.
5. Compare before/after `EndpointDataSource` route tables as exact multisets. Exercise authorization, validation failures, binding sources, filters, content types, headers, and status codes.
6. Remove a controller or MVC registration only after all dependent behavior is mapped and verified. Add OpenAPI/Scalar only when requested, and only in the development environment — and when the app already exposes them, preserve its existing gating rather than re-wrapping it.

## Load-bearing rules

- `[Authorize]`, `[AllowAnonymous]`, filters, formatters, binding attributes, and `[ApiController]` behavior do not transfer automatically.
- A green build is not behavioral parity.
- Keep `app.UseAuthorization()` whenever any endpoint, controller, or pipeline behavior requires its semantics or order.
- Remove `AddControllers()` and `MapControllers()` only when nothing retained needs them.
- Match `Microsoft.AspNetCore.OpenApi` to the target framework major and use central package management when present.
- Before enabling ASP.NET OpenAPI source generation, inspect the target framework and the resolved `Microsoft.AspNetCore.OpenApi` dependency, then inspect the direct or centrally managed `Microsoft.OpenApi` declaration. Keep 2.x for ASP.NET Core 10 and earlier source-generation stacks; use the supported 3.x line for ASP.NET Core 11 and later. Do not force a universal Microsoft.OpenApi ceiling.
- Delete `Controllers/` only when every controller and ledger row is converted and verified.

## Compact checklist

- [ ] Behavior ledger complete before edits.
- [ ] Unsupported behavior retained and reported.
- [ ] Effective route/metadata multisets match.
- [ ] Authorization, binding, validation, and response parity tested.
- [ ] Newly introduced OpenAPI and Scalar are development-only; existing surfaces keep their gating.
- [ ] Required endpoint classes are registered.
- [ ] Build and parity tests pass.
