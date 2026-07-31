---
name: aspnet-core-standards
description: Use when building or reviewing an ASP.NET Core (.NET 8/9) HTTP service in a touchstone repo — minimal APIs vs controllers, DI lifetimes, options/config, ProblemDetails, EF Core, auth policies, middleware, resilience, integration tests. Triggers on `Microsoft.AspNetCore` in a .csproj, `WebApplication.CreateBuilder` / `app.MapGet` in Program.cs, `[ApiController]` controllers, `DbContext`. C#-language rules (nullable, async, analyzers, packaging) live in the csharp skill.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# ASP.NET Core (framework)

Full standard: **`standards/frameworks/aspnet-core.md`** (layers on `standards/languages/csharp.md`).
This skill inlines the load-bearing rules so it stays useful when installed standalone in
`~/.claude/skills/`:

## Always
- **Minimal APIs by default**; `[ApiController]` MVC when the surface is richer. Endpoints stay thin (validate → service → result), grouped with `MapGroup` carrying shared auth/filters/tags.
- **Organize by feature / vertical slice**, not technical layers; register each feature behind one `Add*` extension; keep `Program.cs` thin.
- **DI lifetimes:** `DbContext` and per-request work are **scoped**; never inject scoped into a singleton; keep `ValidateScopes`/`ValidateOnBuild` on.
- **Options pattern** for all config — bind typed `IOptions<T>`, `.ValidateOnStart()`. No scattered `Environment.GetEnvironmentVariable`.
- **No secrets in the repo:** `dotnet user-secrets` in dev, Key Vault / Secrets Manager + Managed Identity in prod.
- **Async to the wire:** flow `CancellationToken` to EF/`HttpClient`/downstream; no sync-over-async (`.Result`/`.Wait()`).

## Don't get burned
- **Bind requests to DTOs, never to EF entities** (over-posting). Validate with DataAnnotations/FluentValidation; `[ApiController]` auto-400s.
- **Errors are `ProblemDetails` (RFC 9457):** `AddProblemDetails()` + `UseExceptionHandler()` + one `IExceptionHandler` mapping domain errors → status. No stack traces in prod (dev exception page is `IsDevelopment()`-only).
- **EF:** migrations reviewed + applied at deploy — **never `Migrate()`/`EnsureCreated()` on startup**. `AsNoTracking()` on reads; kill N+1 with `Include`/`.Select` projections; `DbContext` is not thread-safe.
- **Deny by default:** set a fallback authorization policy requiring an authenticated user; opt out with `[AllowAnonymous]`. Validate JWT issuer/audience. Policies named, not inline role strings.
- **Middleware order is behavior:** `UseRouting → UseCors → UseAuthentication → UseAuthorization`. Never `AllowAnyOrigin()` + `AllowCredentials()`.
- **Outbound HTTP via `IHttpClientFactory`** typed clients (never `new HttpClient()`); add `AddStandardResilienceHandler()` (retry/timeout/circuit-breaker).

## Defer (don't duplicate)
- C# language (nullable, async, analyzers, CPM, packaging) → `../../standards/languages/csharp.md`; API contract/errors → `../../standards/design/api-design.md`; schema + EF migrations → `../../standards/platform/database.md`; authZ policy/OWASP → `../../standards/practices/app-security.md`; OpenTelemetry → `../../standards/platform/observability.md`; retry/timeout budgets → `../../standards/design/resilience.md`; test pyramid → `../../standards/practices/testing-strategy.md`.

## Done
Minimal-API/controller endpoints thin · feature slices · scoped `DbContext`, no scoped-into-singleton · typed options `ValidateOnStart` · no repo secrets · DTO-bound + validated, `ProblemDetails` errors · EF migrations at deploy, `AsNoTracking`, N+1 guarded · deny-by-default auth, JWT validated · middleware order correct, explicit CORS · `CancellationToken` to the wire · OpenTelemetry exported · `IHttpClientFactory` + resilience handler · `WebApplicationFactory` + Testcontainers integration tests. See `standards/frameworks/aspnet-core.md`.
