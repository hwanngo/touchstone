# ASP.NET Core Standards

Framework layer; language rules → [csharp.md](../languages/csharp.md).

ASP.NET Core on a current .NET LTS (verify the release; .NET 8 is the floor, .NET 10 the current LTS), hosted by the generic host (`WebApplication`). This doc covers only
the framework-shaped decisions for HTTP services. Cross-cutting concerns are owned elsewhere and are
**deferred, not repeated**: API contracts → [api-design.md](../design/api-design.md), schema/EF
migrations → [database.md](../platform/database.md), authZ policy/OWASP →
[app-security.md](../practices/app-security.md), traces/metrics →
[observability.md](../platform/observability.md), timeouts/retries →
[resilience.md](../design/resilience.md), the test pyramid →
[testing-strategy.md](../practices/testing-strategy.md), dependencies/supply-chain → [csharp.md](../languages/csharp.md) + [security.md](../practices/security.md). Siblings: [fastapi.md](fastapi.md),
[node-backend.md](node-backend.md), [gin.md](gin.md).

> **One law:** the request pipeline is the contract — endpoints are thin, the work lives in
> injected services, and every async path carries a `CancellationToken` to the wire.

---

## 1. API style: Minimal APIs first, controllers when richer

| Surface | Choose | Why |
|---|---|---|
| Service / internal API, focused endpoints | **Minimal APIs** (`app.MapGet`, route groups) | Less ceremony, faster startup, AOT-friendly; the default for new services. |
| Large surface, model binding-heavy, content negotiation, OData | **MVC controllers** (`[ApiController]`) | Filters, conventions, and `ApiExplorer` scale better past ~20 endpoints. |
| Real-time push | **SignalR hubs** | Don't hand-roll WebSocket framing. |

- **Group related endpoints with `MapGroup`** and hang shared metadata, filters, and auth off the
  group — not copy-pasted per endpoint:
  ```csharp
  var orders = app.MapGroup("/orders")
      .RequireAuthorization("orders:read")
      .AddEndpointFilter<ValidationFilter>()
      .WithTags("Orders");

  orders.MapGet("/{id:guid}", GetOrder).WithName("GetOrder");
  orders.MapPost("/", CreateOrder).RequireAuthorization("orders:write");
  ```
- **Endpoints delegate to a handler method or injected service** — never inline business logic in
  the lambda. A handler that grows past validate → call service → shape result belongs in a class.
- **`[ApiController]` on every controller** — it turns on automatic 400s for invalid models,
  binding-source inference, and `ProblemDetails` responses (§5). Don't write controllers without it.
- **Mark each endpoint's results** with `.Produces<T>()` / `TypedResults` so the OpenAPI document is
  accurate — the generated contract is governed by [api-design.md](../design/api-design.md).

## 2. Project structure: feature folders / vertical slices

Organize by **feature (vertical slice), not by technical layer.** A `Controllers/ Services/ Models/`
split forces every feature to touch every folder; a slice keeps a change in one place.

```text
src/
  Features/
    Orders/    CreateOrder.cs  GetOrder.cs  OrderEndpoints.cs  Order.cs  OrderService.cs
    Billing/   ...                                            # request + handler + result + DI co-located
  Infrastructure/   Db (DbContext, configs), Auth, Telemetry
  Program.cs        Extensions/  ServiceCollection registration per feature
tests/
  <Project>.IntegrationTests   <Project>.UnitTests
```

- **One feature owns its request, handler, validator, and result types** — co-locate them so the
  slice is a unit you can read, move, or delete whole.
- **Register a feature's services behind one extension method** (`services.AddOrders()`); `Program.cs`
  stays a readable assembly of `Add*` calls, not a 300-line wiring dump.
- **Keep `Program.cs` as top-level statements** (one `WebApplication`); push the wiring into
  `IServiceCollection`/`IEndpointRouteBuilder` extension methods, not the file body.
- _(scale-up)_ Reach for **MediatR or a thin dispatcher** only when cross-cutting pipeline behaviors
  (logging, validation, transactions) repeat across many slices — not by default; it adds indirection.

## 3. Dependency injection & lifetimes

Use the **built-in container** — it covers services, options, and hosted background work. Reach for a
third-party container (Autofac) only for features the built-in one lacks (assembly scanning,
decorators), never reflexively.

| Lifetime | Use for | Trap |
|---|---|---|
| **Singleton** | Stateless services, caches, `IOptions<T>`, `HttpClientFactory` | Must be thread-safe; never hold per-request state. |
| **Scoped** | `DbContext`, unit-of-work, anything per-request | One instance per request — the default for app services. |
| **Transient** | Cheap, stateless, short-lived helpers | A new instance every resolve; don't use for expensive objects. |

- **Never inject a scoped service into a singleton** — it captures the first request's instance and
  leaks it forever. `DbContext` (scoped) into a singleton is the classic bug; the container's scope
  validator catches it in Development — keep `ValidateScopes`/`ValidateOnBuild` **on**.
- **Use a service in a hosted/background worker via `IServiceScopeFactory`** — create a scope per unit
  of work; don't resolve scoped services from the root provider.
- **Options pattern for all config-bound settings:** bind a typed `record`/class and inject
  `IOptions<T>` (or `IOptionsSnapshot<T>` for per-request reload, `IOptionsMonitor<T>` for
  change-notified singletons). **Validate at startup** so a bad value fails the boot, not a request:
  ```csharp
  builder.Services.AddOptions<JwtOptions>()
      .BindConfiguration("Jwt")
      .ValidateDataAnnotations()
      .ValidateOnStart();        // fail fast at boot, not on first /token
  ```

## 4. Configuration & secrets

- **Layered configuration, last-wins:** `appsettings.json` → `appsettings.{Environment}.json` →
  **User Secrets** (Development) / environment variables / Key Vault (prod). Read it through
  `IConfiguration`/options (§3), never `Environment.GetEnvironmentVariable` scattered in code.
- **No secrets in the repo — ever.** `appsettings.json` holds non-secret defaults only. Local secrets
  live in **`dotnet user-secrets`** (outside the repo tree); prod secrets come from **Azure Key Vault
  / AWS Secrets Manager** via a configuration provider, surfaced with **Managed Identity**, not a
  connection string with a password.
  ```bash
  dotnet user-secrets init                                   # adds a UserSecretsId to the .csproj
  dotnet user-secrets set "ConnectionStrings:Db" "Host=…"    # stored in ~/.microsoft, never committed
  ```
- **`ASPNETCORE_ENVIRONMENT` drives behavior** (`IsDevelopment()` gates the developer exception page,
  Swagger UI, detailed errors). Production must never expose stack traces — see §5.
- **Validate required config at startup** (options `ValidateOnStart`) so a missing connection string
  is a failed deploy, not a 2am 500.

## 5. Model binding, validation & ProblemDetails

Validate at the boundary; return machine-readable errors. **Never let an unvalidated DTO reach a
service.**

| Concern | Rule |
|---|---|
| Request/response shapes | Separate DTOs per direction; bind requests to a DTO `record`, never to an EF entity (mass-assignment / over-posting risk). |
| Simple rules | **DataAnnotations** (`[Required]`, `[Range]`, `[EmailAddress]`) — `[ApiController]` auto-400s on failure. |
| Cross-field / conditional rules | **FluentValidation** — register validators and run them via an endpoint filter / MVC filter; keeps rules out of handlers. |
| Errors | **RFC 9457 `application/problem+json`** via `ProblemDetails` — the one error shape for the whole API. |

- **Wire `AddProblemDetails()` + a global exception handler** so every unhandled error and every
  status-code response is a `ProblemDetails`, not an HTML page or a leaked trace:
  ```csharp
  builder.Services.AddProblemDetails();
  app.UseExceptionHandler();          // maps unhandled → 500 ProblemDetails (no stack trace in prod)
  app.UseStatusCodePages();
  ```
- **Map domain exceptions to status codes** in one `IExceptionHandler`, not `try/catch` in every
  handler — `OrderNotFound` → 404, `ConcurrencyConflict` → 409. The contract for shapes lives in
  [api-design.md](../design/api-design.md).
- **Never echo raw exception detail to clients in production.** The developer exception page is
  `IsDevelopment()`-only; prod returns a correlation id, not a message.

## 6. EF Core

EF Core is the default data access. Schema changes, migration discipline, and N+1 rules are owned by
[database.md](../platform/database.md); this section is the EF-shaped slice.

- **Migrations are code-reviewed and run as a deploy step** — `dotnet ef migrations add`, review the
  generated SQL, apply with `dotnet ef database update`/a migration bundle. **Never `EnsureCreated()`
  or `Database.Migrate()` on startup in prod** (it races across instances and skips review):
  ```bash
  dotnet ef migrations add AddOrderStatus
  dotnet ef migrations script --idempotent -o migrate.sql   # reviewed + applied by the deploy
  ```
- **`AsNoTracking()` on every read-only query** — the change tracker is pure overhead when you won't
  save. Make it the default for query endpoints; track only when you intend to mutate.
- **N+1 is the EF footgun:** eager-load with `Include`/`ThenInclude` or project straight to a DTO with
  `.Select(...)` — never lazy-load in a loop. Assert query counts on hot paths (see database.md).
- **`DbContext` is scoped, not thread-safe** — never share one across concurrent requests or parallel
  awaits; use `IDbContextFactory<T>` for a short-lived context off the request. Project to DTOs in the
  query (`.Select(o => new OrderDto(...))`) so SQL fetches only the columns you need.
- _(scale-up)_ **Compiled queries** (`EF.CompileAsyncQuery`) for the hottest, repeatedly-executed
  queries cut per-call expression-tree compilation; measure before adding the ceremony.

## 7. AuthN / AuthZ

Mechanism only here; **policy, threat model, and OWASP live in
[app-security.md](../practices/app-security.md).**

- **JWT bearer for APIs**, ASP.NET Core **Identity** when you own the user store and login UI.
  Configure the authority/issuer/audience and **validate them** — a bearer scheme that doesn't check
  `ValidateIssuer`/`ValidateAudience` accepts any signed token.
- **Deny by default.** Set a fallback policy that requires an authenticated user for *every* endpoint,
  then opt public routes out with `[AllowAnonymous]`. Don't rely on remembering to add `[Authorize]`:
  ```csharp
  builder.Services.AddAuthorizationBuilder()
      .SetFallbackPolicy(new AuthorizationPolicyBuilder()
          .RequireAuthenticatedUser().Build())            // every endpoint protected unless opted out
      .AddPolicy("orders:write", p => p.RequireClaim("scope", "orders:write"));
  ```
- **Authorize with policies, not scattered role strings** — name a policy (`"orders:write"`) and bind
  it to claims/requirements in one place; controllers/endpoints reference the name.
- **`UseAuthentication()` before `UseAuthorization()`**, both after routing — order in the pipeline is
  load-bearing (§8). Resource-based checks (does *this* user own *this* order) use
  `IAuthorizationService`, not an `if` in the handler.

## 8. Middleware pipeline & async

- **Order is the behavior.** The pipeline is ordered; a misplaced middleware silently breaks security.
  The canonical order:
  ```csharp
  app.UseExceptionHandler();        // outermost: catches everything below
  app.UseHsts();                    // prod
  app.UseHttpsRedirection();
  app.UseRouting();
  app.UseCors();                    // after routing, before auth
  app.UseAuthentication();
  app.UseAuthorization();           // after authN, after routing
  app.MapEndpoints();               // terminal
  ```
- **CORS is an explicit allow-list** — named policy with specific origins/methods/headers. Never
  `AllowAnyOrigin()` together with `AllowCredentials()` (the framework throws; don't work around it).
- **Async all the way to the wire, and flow the `CancellationToken`.** Every endpoint/handler takes a
  `CancellationToken` and forwards it to EF, `HttpClient`, and downstream calls — ASP.NET Core binds
  `HttpContext.RequestAborted` to it, so a disconnected client cancels the work instead of burning a
  thread (language rules → [csharp.md](../languages/csharp.md)):
  ```csharp
  orders.MapGet("/{id:guid}", async (Guid id, OrderService svc, CancellationToken ct) =>
      await svc.GetAsync(id, ct) is { } o ? Results.Ok(o) : Results.NotFound());
  ```
- **No sync-over-async in the pipeline** (`.Result`/`.Wait()`) — it starves the thread pool under
  load. `ConfigureAwait(false)` is a no-op in app code on ASP.NET Core (no sync context) — don't
  litter it; reserve it for shared libraries (see csharp.md §7).

## 9. Observability & resilience

- **OpenTelemetry is the wire format** — add `AddAspNetCoreInstrumentation()`,
  `AddHttpClientInstrumentation()`, and `AddEntityFrameworkCoreInstrumentation()`, export OTLP. Traces,
  metrics, and the request/trace-id correlation contract are owned by
  [observability.md](../platform/observability.md):
  ```csharp
  builder.Services.AddOpenTelemetry()
      .WithTracing(t => t.AddAspNetCoreInstrumentation().AddHttpClientInstrumentation())
      .WithMetrics(m => m.AddAspNetCoreInstrumentation().AddRuntimeInstrumentation())
      .UseOtlpExporter();
  ```
- **Structured logging** (`ILogger<T>` + message templates, not string interpolation); one log line
  per request with method/path/status/latency/trace-id.
- **Outbound HTTP goes through `IHttpClientFactory`** typed clients — never `new HttpClient()` (socket
  exhaustion) or a long-lived static one (stale DNS).
- **Resilience via `Microsoft.Extensions.Http.Resilience`** (the standard handler wrapping Polly):
  add a retry-with-jitter + timeout + circuit-breaker pipeline per client. The policy values (budgets,
  thresholds) are governed by [resilience.md](../design/resilience.md):
  ```csharp
  builder.Services.AddHttpClient<BillingClient>(c => c.BaseAddress = new(billingUrl))
      .AddStandardResilienceHandler();     // retry + circuit breaker + timeout, sane defaults
  ```

## 10. Testing

- **xUnit is the runner** (csharp.md §8). Unit-test handlers/services with fakes; reserve the HTTP
  layer for integration tests. The unit-vs-integration split is [testing-strategy.md](../practices/testing-strategy.md).
- **Integration tests use `WebApplicationFactory<TProgram>`** — it boots the real pipeline (routing,
  auth, filters, model binding) in-memory with no socket. Override registrations in
  `ConfigureWebHost` to swap fakes (clock, external clients):
  ```csharp
  public class OrdersApiTests(WebApplicationFactory<Program> factory)
      : IClassFixture<WebApplicationFactory<Program>>
  {
      [Fact]
      public async Task Get_unknown_order_returns_404()
      {
          var client = factory.CreateClient();
          var res = await client.GetAsync("/orders/" + Guid.NewGuid());
          res.StatusCode.Should().Be(HttpStatusCode.NotFound);
      }
  }
  ```
  Expose `Program` to the test project (`public partial class Program;` with top-level statements).
- **Test against a real database with [Testcontainers](https://testcontainers.com)** — a disposable
  Postgres per test class beats an in-memory provider that lies about SQL semantics and won't catch a
  bad migration. Trait-gate them out of the fast unit run.
- **Assert on status + response DTO shape**, not EF internals; always cover the error path — a handler
  must return `ProblemDetails`, not a bare 500.

## Definition of done

- [ ] Minimal APIs (or `[ApiController]` MVC when richer); endpoints thin, grouped with `MapGroup`, logic in services
- [ ] Code organized by feature/vertical slice; each feature registered behind one `Add*` extension; `Program.cs` thin
- [ ] DI lifetimes correct (scoped `DbContext`, no scoped-into-singleton); `ValidateScopes`/`ValidateOnBuild` on
- [ ] Settings bound to typed `IOptions<T>` with `ValidateOnStart`; no scattered env reads
- [ ] No secrets in repo: user-secrets in dev, Key Vault/Secrets Manager + Managed Identity in prod
- [ ] Requests bound to DTOs (no over-posting); validated (DataAnnotations/FluentValidation); errors are `ProblemDetails` (RFC 9457), no leaked traces in prod
- [ ] EF migrations reviewed + applied at deploy (no `Migrate()`/`EnsureCreated()` on startup); `AsNoTracking()` reads; N+1 guarded; DTO projections
- [ ] Deny-by-default fallback authorization policy; JWT issuer/audience validated; policies named, not inline role strings
- [ ] Middleware order correct (`Routing → CORS → AuthN → AuthZ`); explicit CORS allow-list; no `AnyOrigin`+credentials
- [ ] Async to the wire; `CancellationToken` flows to EF/HttpClient/downstream; no sync-over-async
- [ ] OpenTelemetry (ASP.NET Core + HttpClient + EF) exported; structured logging with trace-id
- [ ] Outbound HTTP via `IHttpClientFactory` typed clients with `AddStandardResilienceHandler()`
- [ ] Integration tests via `WebApplicationFactory<T>` + Testcontainers; assert status + DTO + error path

**Sources:** [Minimal APIs overview](https://learn.microsoft.com/aspnet/core/fundamentals/minimal-apis/overview) · [Dependency injection in ASP.NET Core](https://learn.microsoft.com/aspnet/core/fundamentals/dependency-injection) · [Options pattern](https://learn.microsoft.com/aspnet/core/fundamentals/configuration/options) · [Safe storage of app secrets](https://learn.microsoft.com/aspnet/core/security/app-secrets) · [Handle errors / ProblemDetails](https://learn.microsoft.com/aspnet/core/fundamentals/error-handling) · [EF Core querying](https://learn.microsoft.com/ef/core/querying/tracking) · [HTTP resilience](https://learn.microsoft.com/dotnet/core/resilience/http-resilience) · [Integration tests](https://learn.microsoft.com/aspnet/core/test/integration-tests)
