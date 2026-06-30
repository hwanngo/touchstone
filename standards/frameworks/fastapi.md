# FastAPI Standards

Framework layer; language rules → [python.md](../languages/python.md).

FastAPI on Starlette + Pydantic v2, served under an ASGI server (uvicorn or granian).
This doc covers only the FastAPI-shaped decisions. Cross-cutting concerns are owned elsewhere
and are **deferred, not repeated**: API contracts → [api-design.md](../design/api-design.md),
DB → [database.md](../platform/database.md), retries/timeouts/caching →
[resilience.md](../design/resilience.md), authN/authZ/OWASP →
[app-security.md](../practices/app-security.md), dependencies/supply-chain →
[python.md](../languages/python.md) + [security.md](../practices/security.md).

---

## 1. App & module structure

| Concern | Rule |
|---|---|
| App construction | A `create_app() -> FastAPI` **factory**, not a module-global instance. Wire deps/middleware/routers inside it so tests build fresh apps. |
| Layout | **Module-by-domain, not by file-type.** Group `router.py`, `schemas.py`, `models.py`, `service.py`, `dependencies.py`, `exceptions.py` under each domain package (`src/orders/`, `src/billing/`). The flat `routers/ services/ schemas/` split stops scaling once you have many domains — every feature touches every folder. |
| Routers | One **`APIRouter` per domain** (`orders/router.py`), `prefix=` + `tags=` on the router; `app.include_router(...)` in the factory. Routers stay thin: validate → call service → shape response. |
| Cross-module imports | When a domain needs another's service, **import by explicit module path** (`from src.billing import service as billing`) — keeps the dependency direction visible. |
| Startup/shutdown | A **`lifespan` async context manager** (`@asynccontextmanager`) passed to `FastAPI(lifespan=...)`. The `@app.on_event(...)` hooks are deprecated — do not use. |

```text
src/
  orders/   router.py schemas.py models.py service.py dependencies.py exceptions.py
  billing/  router.py schemas.py models.py service.py …
  config.py  database.py  main.py        # global: settings, engine/session, factory
```

## 2. Settings

Use **`pydantic-settings`** (`BaseSettings`) — typed, validated config from env. Expose a **cached
instance as a dependency** so tests override it; never read `os.environ` scattered through the code.

- **Secrets** (`JWT_SECRET`, `DATABASE_URL`) are typed fields from env/secret-manager — never
  committed; validated at startup so a bad value fails fast, not on first request.
- _(scale-up)_ Once domains multiply, **split settings per module** (`auth/config.py` →
  `AuthConfig`), keeping only cross-cutting keys global — one mega-config couples every domain.

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="APP_")
    db_url: PostgresDsn

@lru_cache
def get_settings() -> Settings: return Settings()
```

## 3. Dependency injection

`Depends` is the seam for everything request-scoped — **avoid module-global mutable state**.

- **`yield` dependencies for cleanup** (db session, unit-of-work): code after `yield` runs as
  teardown even on error.
- **Push existence/ownership checks into deps**, not handler bodies — a `valid_order_id` dep loads
  the row or raises 404, so the handler receives a guaranteed-present object. FastAPI **caches each
  dep once per request**, so chained deps (`valid_order_id` → `owned_order`) don't re-query.
- **Make dependencies `async`** unless they do genuinely blocking work — a `def` dep is dispatched
  to the threadpool, and that overhead is wasted on a small non-I/O check.
- **Tests override deps** via `app.dependency_overrides[get_db] = fake_db` — the canonical seam
  for fakes/stubs (no monkeypatching internals).

```python
async def valid_order_id(order_id: UUID, db=Depends(get_db)) -> Order:
    if (order := await service.get(db, order_id)) is None:
        raise OrderNotFound()    # → 404 via exception handler (§8)
    return order

async def get_db() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session            # one session per request; teardown closes it
```

## 4. Pydantic v2 at the boundary

Separate schemas per direction — **never return ORM objects raw**.

| Schema | Purpose |
|---|---|
| `OrderCreate` / `OrderUpdate` | Request bodies. Reject unknown fields (`model_config = {"extra": "forbid"}`). |
| `OrderOut` | Response. Set as `response_model=` — it filters fields and is the documented contract. |
| ORM model | DB only. Convert with `OrderOut.model_validate(obj)` (`from_attributes=True`). |

- `response_model` enforces the output shape; `response_model_exclude_none` / `_exclude` to trim.
- A response schema that omits secrets is **defense in depth** against leaking columns you added later.
- **Don't double-instantiate**: setting `response_model` and *also* building that model by hand in the
  handler makes FastAPI validate it twice. Return the ORM object (or a plain dict) and let
  `response_model` do the one conversion — or return the schema and drop `response_model`.
- FastAPI's 422 validation body → emit as RFC 9457 `application/problem+json` (see §9 and
  [api-design.md](../design/api-design.md)); don't ship the raw default for public APIs.

## 5. Persistence & migrations

| Concern | Rule |
|---|---|
| Session scope | **One session per request** via a `yield` dependency (§3) — open on entry, commit/rollback + close on teardown. Never a module-global session. |
| Migrations | **Every schema change is an Alembic migration**, autogenerate then review the diff; migrations are **static and reversible** (real `downgrade`). Run them as a deploy step, never `create_all()` in prod. Conventions → [database.md](../platform/database.md). |
| ORM stays in `db/service` | Pydantic schemas never import ORM models and vice-versa; the service layer maps between them. |

## 6. Async correctness

The single biggest FastAPI footgun: **blocking the event loop**. "Make every route `async`" is the
classic mistake — `async def` + a blocking call stalls *every* concurrent request, not just one.

**Decision rule — pick the keyword by what the route actually does:**

| Route does… | Declare it | Why |
|---|---|---|
| non-blocking I/O (async driver, `await`) | `async def` | event loop serves other requests while it waits |
| blocking I/O (sync driver/SDK, no async option) | plain `def` | FastAPI runs `def` routes in a threadpool — the loop stays free |
| blocking I/O but route must be `async` | `async def` + `run_in_threadpool(fn)` | offload the blocking call off the loop |
| CPU-bound work | neither | offload to a worker/process pool or task queue — threads can't dodge the GIL |

- **Use async drivers in the async path**: `asyncpg` / SQLAlchemy **async** engine, `httpx.AsyncClient`,
  `redis.asyncio`. **Never a sync driver** (`psycopg2`, `requests`) inside `async def`.
- See the broader async rules in [python.md](../languages/python.md).

## 7. Production serving

Run under **uvicorn** (mature default) or **granian** _(scale-up: single Rust binary, no gunicorn
manager)_. See [docker.md](../platform/docker.md) for the container.

| Setting | Value | Why |
|---|---|---|
| Workers | `= CPU cores` (async workers, one loop each) | Not the sync `2×cores+1` formula. |
| `--proxy-headers` + `--forwarded-allow-ips` | **on**, behind a proxy | Trust `X-Forwarded-*` for correct scheme/client IP. |
| Graceful shutdown | drain in-flight on `SIGTERM` | `lifespan` teardown + a shutdown timeout < orchestrator grace period. |
| Reload / `--workers` from code | **never** in prod | `--reload` is dev-only. |

**One worker** if the process holds **in-memory state, SSE/WebSocket fan-out, or a background
scheduler** — multi-worker means N independent copies. Push shared state to Redis/DB to scale out.

## 8. AuthN / AuthZ

Mechanism only here; policy and OWASP → [app-security.md](../practices/app-security.md).

- OAuth2 / OIDC via a **security dependency** (`Security(...)` with `scopes=`); attach
  `current_user` as a dep so handlers receive a typed principal.
- **Deny by default**: protected routers require the auth dep; public routes are the explicit
  exception. Authorization is a dependency, never an `if` buried in the handler.

## 9. OpenAPI, errors, middleware

| Concern | Rule |
|---|---|
| OpenAPI | **Generated — treat the schema as the contract.** Set explicit `operation_id`s and `tags`; lint and **version** the exported `openapi.json` in CI ([api-design.md](../design/api-design.md)). |
| Exception handlers | Register `app.exception_handler(...)` returning **`application/problem+json`** (RFC 9457). One handler maps domain errors → status; never leak tracebacks/internals. |
| Request ID | Middleware that reads/generates a request-id, binds it to structured logs and echoes it in responses. |
| Logging | **Structured JSON** logs (see python.md); one log line per request with method/path/status/latency/request-id. |
| CORS | `CORSMiddleware` with an **explicit allow-list** of origins/methods/headers. Never `allow_origins=["*"]` with credentials. |

## 10. Testing

- **`httpx.AsyncClient` against an ASGI transport** for async apps; Starlette `TestClient` for
  sync-style tests. Both run in-process — **no real network/sockets** (see
  [testing-strategy.md](../practices/testing-strategy.md)).
- Swap collaborators with **`app.dependency_overrides`** (db, auth, clock, external clients) — the
  factory from §1 makes each test a fresh app.
- Assert on **status + `response_model` shape**, not ORM internals. Cover the error path: a handler
  must return RFC 9457, not a 500.

## Definition of done

- [ ] App built by a `create_app()` factory; startup/shutdown via `lifespan` (no `@on_event`).
- [ ] Code grouped **by domain module** (router/schemas/models/service per package); routers thin, logic in services.
- [ ] Config via `pydantic-settings` behind a cached dependency; secrets typed and validated at startup.
- [ ] Existence/ownership checks live in `async` deps; sessions are one-per-request `yield` deps.
- [ ] Request/response/DB schemas separated; every route has a `response_model`; no raw ORM returned; no double-instantiation.
- [ ] Route keyword matches the work: `async def` for non-blocking I/O, plain `def` for blocking; async drivers throughout.
- [ ] Schema changes are reversible Alembic migrations run at deploy (no `create_all()` in prod).
- [ ] Served with workers = cores, `--proxy-headers` on, graceful shutdown; single worker iff in-memory state.
- [ ] Auth is a deny-by-default dependency with scopes.
- [ ] Errors → `application/problem+json`; request-id + structured logging; explicit CORS allow-list.
- [ ] `operation_id`s/`tags` set; `openapi.json` linted and versioned in CI.
- [ ] Tests use `AsyncClient`/`TestClient` with dependency overrides; no real network.

**Sources:** [zhanymkanov/fastapi-best-practices](https://github.com/zhanymkanov/fastapi-best-practices) · [fastapi/full-stack-fastapi-template](https://github.com/fastapi/full-stack-fastapi-template) · [Netflix/dispatch](https://github.com/Netflix/dispatch) · [FastAPI docs — Bigger Applications](https://fastapi.tiangolo.com/tutorial/bigger-applications/) · [FastAPI docs — async/await](https://fastapi.tiangolo.com/async/)
