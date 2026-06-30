# Litestar

Framework layer; language rules → [python.md](../languages/python.md). Dependencies and supply-chain defer to [python.md](../languages/python.md) + [security.md](../practices/security.md).

Litestar 2.x is an opinionated, type-driven ASGI framework. Signatures *are* the schema, msgspec
is the fast default, and DI is layered. Lean into those; don't reinvent them. Sibling: [fastapi.md](fastapi.md).

The reference is the official [litestar-fullstack](https://github.com/litestar-org/litestar-fullstack) app:
**domain-driven**, **advanced-alchemy** service/repo layer, msgspec everywhere. Mirror it.

---

## 1. Project structure

Organize by **bounded context (domain)**, not by file type. The fullstack reference:

```text
app/
  server/         # app assembly: core.py (InitPlugin), plugins.py, asgi.py
  config.py       # plugin config objects (alchemy, log, vite, problem_details…)
  db/models/      # SQLAlchemy models — one shared model package
  lib/            # cross-cutting: deps.py, schema.py, service.py, settings.py, crypt.py
  domain/<ctx>/   # e.g. accounts/, teams/ — the unit of ownership
    controllers/  # thin HTTP layer
    services/     # business logic (advanced-alchemy services)
    schemas/      # msgspec Structs (wire models)
    deps.py       # service providers for this domain
    guards.py     # authz functions for this domain
```

| Concern | Rule |
|---|---|
| App assembly | Build the app from **plugins**, not a giant `Litestar(...)` call. Wrap your wiring in an `InitPluginProtocol` (`on_app_init`) — the reference's `ApplicationCore`. |
| Resource = controller | Class-based `Controller` per resource; share `path`, `dependencies`, `guards`, `tags`. |
| Domain plugin | A `DomainPlugin` collects each domain's controllers into `route_handlers`; keep handlers thin. |
| Config | Plugin **config objects** in one `config.py`, fed by `pydantic-settings`/msgspec settings. Never read `os.environ` in handlers. |

## 2. Data layer — advanced-alchemy (repository + service)

Don't hand-roll CRUD or wire `AsyncSession` yourself. Use **[advanced-alchemy](https://github.com/litestar-org/advanced-alchemy)**
(the official SQLAlchemy 2.0 integration) and split persistence into two layers:

| Layer | Class | Holds |
|---|---|---|
| Repository | `SQLAlchemyAsyncRepository[Model]` (or `…SlugRepository`) | Typed CRUD, bulk ops, `list_and_count`. No business rules. |
| Service | `SQLAlchemyAsyncRepositoryService[Model]` | Business logic; owns a nested `Repo`, `match_fields`, `to_model_on_create/update` hooks. |

```python
class TeamService(SQLAlchemyAsyncRepositoryService[m.Team]):
    class Repo(SQLAlchemyAsyncSlugRepository[m.Team]):
        model_type = m.Team
    repository_type = Repo
    match_fields = ["name"]
```

- **Models** inherit `UUIDBase`/`BigIntBase` (audit columns + sentinel) from one `db/models` package.
- Filters are first-class: `LimitOffset`, `SearchFilter`, id/created/updated — inject them, don't parse query params by hand.
- Map out at the boundary with `service.to_schema(obj, total, filters, schema_type=Team)` → never touch ORM rows in the controller.

## 3. Dependency injection

DI is a Litestar **strength** — use scope deliberately. Define `dependencies` at the narrowest
layer that needs them: **app → router → controller → handler**, with inner scopes overriding outer.

| Need | Do |
|---|---|
| Service provider | `create_service_provider(TeamService, load=[…], error_messages={…})` (advanced-alchemy) — wires session + eager loads. |
| Controller deps | `create_service_dependencies(TeamService, key="teams_service", load=[…], filters={…})` — service + filters in one shot. |
| Per-request resource | Generator factory: `yield session` then clean up (close/rollback) after the response. |
| Pure / cacheable | `Provide(fn, use_cache=True)` — only for side-effect-free factories. |
| Shared across routes | Hoist to app/controller scope, not copy-pasted per handler. |

Don't put request-scoped state (a DB session) at app scope. Don't `use_cache` anything with effects.

## 4. Serialization, schemas & DTOs

| Path | Choice |
|---|---|
| Wire models (default) | **msgspec `Struct`** — Litestar's native fast encode/decode. The reference uses a `CamelizedBaseStruct` base. |
| Partial updates | Fields typed `T \| msgspec.UnsetType = msgspec.UNSET` + `omit_defaults=True`; `to_dict()` drops `UNSET`. |
| Generate from ORM | **DTOs** (`SQLAlchemyDTO` + `DTOConfig`) — exclude/rename fields, read-only, `max_nested_depth`. |
| Need the pydantic ecosystem | pydantic models are supported; pay the cost only where you use it. |

- **Never return ORM objects raw.** Emit a `Struct` (via `service.to_schema`) or a DTO; raw models leak columns and break on lazy loads.
- One inbound schema (`TeamCreate`/`TeamUpdate`), one outbound (`Team`) per resource — don't reuse the DB model as the API shape.
- Exclude secrets explicitly: `DTOConfig(exclude={"password_hash"})`.

## 5. Validation & typing

Type-driven: the **signature is the contract**. A `data: OrderIn` param parses + validates the body;
return type drives the response schema. Add constraints inline, not in handler bodies.

```python
@get("/{order_id:uuid}")
async def get(
    self,
    order_id: UUID,
    limit: Annotated[int, Parameter(ge=1, le=100)] = 20,
) -> OrderOut: ...
```

Constraints live on `Parameter` (query/path/header) and `Body`; msgspec `Meta` for struct fields.
No manual `if not x: raise` for shape validation.

## 6. Async

Handlers are **async-first**. Never block the event loop — wrap unavoidable sync/CPU work in a
threadpool (see [python.md](../languages/python.md)). Use an **async** DB driver in the async path;
a sync driver inside an `async def` handler stalls the loop. DB specifics → [database.md](../platform/database.md).

## 7. Guards & auth

| Layer | Mechanism |
|---|---|
| AuthN | A first-party JWT backend — `OAuth2PasswordBearerAuth` / `JWTCookieAuth` — with a `retrieve_user_handler`. Call `auth.on_app_init(app_config)` to register it (don't hand-roll middleware unless you must). |
| AuthZ | `guards=[...]` at app/router/controller/handler scope; **deny-by-default**, allow explicitly. |
| Current user | Inject via a `provide_user` dependency that reads `connection.user`; resolve the record once. |

Guards are plain `(connection, handler) -> None` functions that raise `NotAuthorizedException` /
`PermissionDeniedException` — keep them per-domain in `guards.py` (e.g. `requires_team_admin`).
Set guards at the highest scope that fits, then narrow. Token/session/RBAC model → [app-security.md](../practices/app-security.md).

## 8. OpenAPI = the contract

The schema is **auto-generated** from your types — treat it as the API contract, not a byproduct.
Export it in CI, version it, and lint for breaking changes. Tag handlers and document responses so
the spec stays usable. Render with `ScalarRenderPlugin`. Contract rules (versioning, errors, pagination) → [api-design.md](../design/api-design.md).

## 9. Errors & logging

- Use the first-party **`ProblemDetailsPlugin`** so exceptions surface as **`application/problem+json`** (RFC 9457), not bare strings.
- Map domain errors → Litestar `HTTPException` subclasses (or a domain-error→response hook); never leak tracebacks in prod. Let advanced-alchemy's `error_messages` turn integrity/duplicate-key errors into clean 4xx.
- Structured logging via the first-party **`StructlogPlugin`**; attach a **correlation id** per request
  and propagate it. Resilience/retry posture → [resilience.md](../design/resilience.md).

## 10. Serving

| Concern | Rule |
|---|---|
| Server | **granian** (Rust, `litestar-granian` plugin) or uvicorn — both behind the same lifespan. |
| Startup/shutdown | Use `lifespan` context managers / `on_startup`/`on_shutdown` for pools, clients, warmup. |
| Graceful shutdown | Drain in-flight requests; close DB pools and clients in the lifespan teardown. |
| Workers | Multiple workers by default; **single worker** if you hold in-memory state or SSE/websocket fan-out. _(scale-up: move that state to Redis and re-enable workers.)_ |

Background jobs (email, OAuth refresh) belong in a queue — the reference uses **SAQ** via the
`litestar-saq` plugin, not fire-and-forget tasks in the request path. Container/process model → [docker.md](../platform/docker.md).

## 11. Testing

- `TestClient` (sync) / `AsyncTestClient` (async) against the real app — no mocking the framework.
- Override deps with `app.dependency_overrides` (or `create_test_client(dependencies=...)`) for fakes.
- Test guards and auth as part of the route, not in isolation. Strategy/coverage → [testing-strategy.md](../practices/testing-strategy.md).

---

## Definition of done

- [ ] Code organized by domain (`domain/<ctx>/{controllers,services,schemas,deps,guards}`); app assembled from plugins.
- [ ] Persistence uses advanced-alchemy repository **+** service; no hand-rolled CRUD or raw session wiring.
- [ ] One controller per resource; deps via `create_service_dependencies`/`create_service_provider` at the narrowest scope.
- [ ] Wire models are msgspec `Struct`s; ORM rows mapped out via `to_schema`/DTOs, never returned raw; secrets excluded.
- [ ] Partial updates use `msgspec.UNSET`; validation lives in signatures/`Parameter`/`Body`, not handler bodies.
- [ ] Handlers async; no blocking calls or sync DB drivers on the loop.
- [ ] AuthN via a first-party JWT backend (`auth.on_app_init`); guards deny-by-default and live per-domain.
- [ ] OpenAPI exported, versioned, lint-checked in CI; `ProblemDetailsPlugin` emits problem+json; structlog carries a correlation id.
- [ ] Lifespan opens/closes all resources; background work on SAQ; worker count matches the state model.
- [ ] `TestClient`/`AsyncTestClient` tests with dependency overrides.

---

**Sources:** [litestar-org/litestar-fullstack](https://github.com/litestar-org/litestar-fullstack) (official full-stack reference) · [litestar-org/litestar](https://github.com/litestar-org/litestar) · [litestar-org/advanced-alchemy](https://github.com/litestar-org/advanced-alchemy) · [litestar-org/litestar-pg-redis-docker](https://github.com/litestar-org/litestar-pg-redis-docker) · [Litestar docs — usage & DI](https://docs.litestar.dev/latest/)
