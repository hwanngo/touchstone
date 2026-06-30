# Axum (Rust Backend) Standards

Framework layer; language rules → [rust.md](../languages/rust.md). How to build an async Rust web
service. Cross-cutting concerns are **deferred, not repeated**: async/timeout/cancellation depth →
[rust.md](../languages/rust.md) + [resilience.md](../design/resilience.md), API contracts →
[api-design.md](../design/api-design.md), authN/authZ/OWASP → [app-security.md](../practices/app-security.md),
persistence → [database.md](../platform/database.md), logs/metrics/traces →
[observability.md](../platform/observability.md), test philosophy → [testing-strategy.md](../practices/testing-strategy.md), dependencies/supply-chain → [rust.md](../languages/rust.md) + [security.md](../practices/security.md).

> **One law:** every handler returns `Result<T, AppError>` — no `unwrap()` on the request path, ever.

---

## 1. Framework choice

**Axum is the default.** It's the Tokio team's own framework — built on **Tower** (middleware),
**Hyper** (HTTP/1+2), and **Tokio** (runtime), so it shares the ecosystem your `rust.md` async rules
already assume. No macros, no magic: handlers are plain `async fn`, extraction is type-driven.

| You have… | Use | Why |
|---|---|---|
| A typical JSON/HTTP service | **Axum 0.8** (this doc's default) | Tower middleware reuse, typed extractors, first-class Tokio. |
| Extreme throughput / actor-style internal state | **Actix-web 4** _(escape hatch)_ | Its own runtime + actor model; reach for it only with a measured reason. |

- **Pin `axum = "0.8"`** — 0.8 (Jan 2025) is a breaking release; the **path syntax changed from
  `/:id` to `/{id}`** (matchit 0.8). Don't copy 0.7-era `:param` routes.
- Companion versions: **`tokio` 1.x**, **`tower` 0.5**, **`tower-http` 0.6**, **`hyper` 1.x**.

## 2. Project layout & layering

**Module-by-domain, not by file-type** (mirrors gin.md/node-backend.md). Group everything a feature
owns; reserve the crate root for the composition root and shared wiring.

```text
src/
  orders/   mod.rs  routes.rs  service.rs  repository.rs  error.rs  models.rs
  billing/  mod.rs  routes.rs  service.rs  repository.rs  …
  config.rs  state.rs  error.rs  telemetry.rs  main.rs   # global: config, AppState, app error, tracing, bootstrap
```

- **Strict layering: handler → service → repository.** The handler extracts and validates input and
  shapes the response; the **service** owns business logic; the **repository** owns persistence.
  Dependencies point inward — a handler never touches `PgPool` directly.
- **Split `lib` from `bin`** (rust.md §8) so the router and services are testable; `main.rs` only
  builds state, the `Router`, and calls `axum::serve`.

## 3. Routing

Build routers per domain and `nest` them under a versioned prefix; `merge` sibling routers. Keep
handlers thin — delegate to the service and return early on error with `?`.

```rust
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/orders/{id}", get(get_order))     // 0.8 brace syntax, not ":id"
        .route("/orders", post(create_order))
        .with_state(state)
}
// in main: Router::new().nest("/api/v1", orders::router(state.clone()))
```

- **One `MethodRouter` per path** so a wrong method returns 405 automatically; **`with_state` once**,
  at the top — wiring state per-route invites mismatches.

## 4. Extractors & rejection handling

Extractors are how typed data enters a handler; **argument order matters** — at most one
body-consuming extractor (`Json`, `Bytes`, `String`), and it must come **last**.

```rust
async fn create_order(
    State(svc): State<OrderService>,   // FromRequestParts — borrows, any position
    headers: HeaderMap,                // FromRequestParts
    Json(body): Json<CreateOrder>,     // FromRequest — consumes the body, MUST be last
) -> Result<Json<Order>, AppError> { … }
```

- **Prefer typed extractors** (`Path<T>`, `Query<T>`, `Json<T>`) over pulling raw strings — they
  parse and reject malformed input before your code runs.
- **Handle rejections deliberately.** A bare `Json<T>` returns a plain-text 400 on bad input; wrap
  with a custom extractor (or `WithRejection`) so failures flow through your `AppError` (§7) as
  problem+json — never two error shapes for one API.

## 5. State & dependency injection

`State<AppState>` is the DI container. `AppState` is **cheap to clone** — hold shared resources
behind `Arc`/pool handles (which are already `Arc` internally), never clone the data itself.

```rust
#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,                 // sqlx pool is Clone (Arc inside)
    pub orders: OrderService,
}
```

- **Construct once in `main`, inject everywhere** — no `static`/`lazy_static` singletons (rust.md
  forbids globals-as-state). Build the pool, build services, build the `Router`.
- **Sub-states via `FromRef`** so a handler can extract `State<PgPool>` directly without unpacking
  the whole struct. Derive `FromRef` on `AppState`.

## 6. Request validation

Parsing (§4) proves *shape*; validation proves *rules*. Use **`garde`** (or `validator`) derives on
the DTO, then validate inside a custom extractor so no handler forgets.

```rust
#[derive(Deserialize, garde::Validate)]
struct CreateOrder {
    #[garde(length(min = 1, max = 64))] sku: String,
    #[garde(range(min = 1))]            qty: u32,
}
// ValidatedJson<T>: runs T::validate after Json extraction; rejection → AppError::Validation
```

- **Validate at the edge; the service works only with validated data.** Don't scatter `if x > 0`
  checks through business logic. Business *invariants* still belong in the service _(scale-up)_.
- **Validation errors → problem+json** with field detail. See [api-design.md](../design/api-design.md).

## 7. Error handling

**One app error type that implements `IntoResponse`** is the only thing handlers return on failure.
This is the framework face of rust.md §4 — `thiserror` enum, **no `unwrap()`/`expect()`** in a
handler.

```rust
#[derive(thiserror::Error, Debug)]
pub enum AppError {
    #[error("not found")]            NotFound,
    #[error("validation")]           Validation(#[from] garde::Report),
    #[error(transparent)]            Db(#[from] sqlx::Error),
}
impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let status = match self {
            AppError::NotFound => StatusCode::NOT_FOUND,
            AppError::Validation(_) => StatusCode::UNPROCESSABLE_ENTITY,
            AppError::Db(_) => StatusCode::INTERNAL_SERVER_ERROR,   // log source internally; never leak
        };
        (status, Json(problem(&self))).into_response()   // application/problem+json
    }
}
```

- **`?` everywhere; map the source to a status in one place.** Never `match` on errors and write
  responses inside handlers. **Never leak** a `sqlx::Error` string or stack trace to the client.

## 8. Async & concurrency

Axum runs on Tokio — **all of rust.md §7 applies**: never block the executor, own every
`JoinHandle`, don't hold a `std::sync::Mutex` across `.await`. Timeouts/cancellation here are the
async face of [resilience.md](../design/resilience.md).

- **Bound every request with a server-wide timeout** via `tower-http`'s `TimeoutLayer` (§9 ordering),
  and bound each outbound DB/HTTP await with `tokio::time::timeout` — an un-timed `await` hangs a task.
- **Cancellation is free but real:** if the client disconnects, Axum drops the handler future at the
  next `.await`. Make work cancel-safe — don't leave a half-written row; use a transaction that rolls
  back on drop.
- **Offload CPU-bound work** (hashing, image/PDF) to `spawn_blocking` or a job queue — it stalls the
  worker thread and every concurrent request otherwise.

## 9. Middleware ordering

Compose Tower layers with a **`ServiceBuilder`** so ordering is explicit: layers apply **top-to-bottom
= outermost-to-innermost** (the first listed sees the request first and the response last).

```rust
let app = router.layer(
    ServiceBuilder::new()
        .layer(TraceLayer::new_for_http())          // 1 outermost: sees every request + final status
        .layer(SetSensitiveHeadersLayer::new([AUTHORIZATION]))
        .layer(CorsLayer::new().allow_origin(origins))   // explicit allow-list, never Any in prod
        .layer(RequestBodyLimitLayer::new(1024 * 1024))  // cap body size
        .layer(TimeoutLayer::new(Duration::from_secs(10)))
        .layer(from_fn_with_state(state.clone(), auth)), // innermost: closest to the handler
);
```

`TraceLayer` must stay outermost (it has to observe a request even when a later layer rejects it);
CORS/body-limit/timeout reject early; auth sits innermost so tracing and the timeout already wrap it.

## 10. Database

**`sqlx` is the default** — async, compile-time-checked queries (`query!`) against a real schema, no
ORM ceremony. Hold a `PgPool` in `AppState` (§5). Reach for **SeaORM** only when you need a full
entity/relationship ORM _(scale-up)_. Schema, migrations, and pool-sizing policy →
[database.md](../platform/database.md).

```rust
let order = sqlx::query_as!(Order, "select id, sku, qty from orders where id = $1", id)
    .fetch_optional(&self.db).await?       // ? → AppError::Db
    .ok_or(AppError::NotFound)?;
```

- **The repository owns SQL; the service never sees a `Row`.** Map driver errors to `AppError` at the
  boundary. Run migrations (`sqlx migrate`) at deploy, not lazily on first request.

## 11. Config & secrets

**Parse the environment once, at boot, into a typed `Config`** (serde + `envy`/`figment`) that the
rest of the app holds in `AppState`. Mirror node-backend.md: fail fast, never read env scattered.

- **A missing/invalid var aborts startup** with a clear message — not a 500 on first request;
  `DATABASE_URL`/`JWT_SECRET` are required, never defaulted.
- **No secrets in the image or repo** — inject at runtime (env/secret manager); `.env` is dev-only and
  git-ignored. See [app-security.md](../practices/app-security.md).

## 12. Graceful shutdown

A pod gets **`SIGTERM`, a grace window, then `SIGKILL`.** Use the window to drain in-flight requests.
`axum::serve(...).with_graceful_shutdown(signal)` stops accepting connections and waits for active
ones to finish.

```rust
let listener = TcpListener::bind("0.0.0.0:8080").await?;
axum::serve(listener, app)
    .with_graceful_shutdown(shutdown_signal())   // awaits SIGTERM *and* ctrl_c via tokio::select!
    .await?;
// after serve returns: pool.close().await — drain connections last
```

- **Listen for both `SIGTERM` and Ctrl-C**; the function returns on either. Pair with the
  `TimeoutLayer` (§9) so a hung request can't block the rollout past the grace period.
- **Close the pool and flush telemetry after `serve` returns**, in order. Make shutdown idempotent.

## 13. Observability

**`tracing` is the logging/span API; `tracing-subscriber` formats it.** Initialize the subscriber once
in `main`, before the server. `tower-http`'s `TraceLayer` (§9) emits a span per request.

- **Structured JSON in prod, request-id on every span**, propagated downstream and echoed in the
  response; instrument service methods with `#[tracing::instrument(skip(self))]`.
- **Export OTel traces** via `tracing-opentelemetry` + `opentelemetry-otlp`. Metrics, SLOs, and
  sampling policy → [observability.md](../platform/observability.md) _(scale-up)_.

## 14. Auth & testing

- **AuthN in a middleware/extractor, AuthZ deny-by-default in the service.** A `FromRequestParts`
  extractor (`AuthUser`) validates the JWT (`jsonwebtoken`) once and injects the claims; protected
  routes require it, public routes are the explicit exception. Mechanism here; policy →
  [app-security.md](../practices/app-security.md).
- **Test handlers in-process with `tower::ServiceExt::oneshot`** — no socket, no runtime server:
  ```rust
  let res = app.oneshot(Request::builder().uri("/api/v1/orders/1").body(Body::empty())?).await?;
  assert_eq!(res.status(), StatusCode::OK);
  ```
  Assert on **status + response body**, and cover the error path (it must return problem+json, not a
  500). Spin a real Postgres with **`testcontainers`** for repository integration tests _(scale-up)_.
  Mechanics → [rust.md](../languages/rust.md) §5; strategy → [testing-strategy.md](../practices/testing-strategy.md).

## Definition of done

- [ ] Framework chosen deliberately — Axum 0.8 default; Actix-web justified (§1)
- [ ] `axum 0.8` brace path syntax (`/{id}`); `tokio`/`tower`/`tower-http`/`hyper` versions aligned (§1)
- [ ] Code grouped **by domain module**; strict handler → service → repository; `lib`/`bin` split (§2)
- [ ] Routers nested under a versioned prefix; `with_state` once; handlers thin (§3)
- [ ] Typed extractors; one body extractor, declared **last**; rejections flow through `AppError` (§4)
- [ ] `AppState` cheap-Clone behind `Arc`/pools, built once in `main`; no static singletons; `FromRef` substates (§5)
- [ ] Every boundary validated (`garde`/`validator`) via a shared extractor; errors → problem+json (§6)
- [ ] One `AppError: IntoResponse` (thiserror); **no `unwrap()`/`expect()` in handlers**; internals never leaked (§7)
- [ ] Server-wide `TimeoutLayer` + per-await `tokio::time::timeout`; cancel-safe work; CPU work off the loop (§8)
- [ ] Middleware composed via `ServiceBuilder`; Trace outermost, auth innermost; explicit CORS allow-list + body limit (§9)
- [ ] `sqlx` compile-checked queries in the repository; driver errors mapped; migrations at deploy (§10)
- [ ] Env parsed once into a typed `Config`; missing/invalid var aborts boot; no secrets in image (§11)
- [ ] `with_graceful_shutdown` on `SIGTERM`+Ctrl-C; pool closed after drain; bounded by the request timeout (§12)
- [ ] `tracing` subscriber + `TraceLayer`; request-id per span; OTel export wired (§13)
- [ ] JWT authN via `FromRequestParts`, deny-by-default authZ; handler tests via `oneshot`; Testcontainers for DB (§14)

**Sources:** [Axum docs (docs.rs)](https://docs.rs/axum/latest/axum/) · [Announcing axum 0.8.0](https://tokio.rs/blog/2025-01-01-announcing-axum-0-8-0) · [tokio-rs/axum examples](https://github.com/tokio-rs/axum/tree/main/examples) · [axum graceful-shutdown example](https://github.com/tokio-rs/axum/blob/main/examples/graceful-shutdown/src/main.rs) · [tower-http docs](https://docs.rs/tower-http/latest/tower_http/) · [sqlx](https://github.com/launchbadge/sqlx) · [garde](https://github.com/jprochazk/garde) · [Tower guide](https://docs.rs/tower/latest/tower/)
