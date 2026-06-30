# Django Standards

Framework layer; language rules → [python.md](../languages/python.md).

Django 5.x (target the **5.2 LTS** floor) — batteries-included, ORM-centric, served under WSGI or
ASGI. This doc owns only the Django-shaped decisions. Cross-cutting concerns are **deferred, not
repeated**: API contracts → [api-design.md](../design/api-design.md), schema/migrations →
[database.md](../platform/database.md), retries/idempotency → [resilience.md](../design/resilience.md),
authN/authZ/OWASP → [app-security.md](../practices/app-security.md), test strategy →
[testing-strategy.md](../practices/testing-strategy.md), dependencies/supply-chain → [python.md](../languages/python.md) + [security.md](../practices/security.md). Sibling: [fastapi.md](fastapi.md).

---

## 1. Project & app structure

| Concern | Rule |
|---|---|
| Apps by domain | One app **per bounded context** (`orders/`, `billing/`), not per layer. Each owns its `models.py`, `services.py`, `selectors.py`, `serializers.py`, `urls.py`, `views.py`, `admin.py`, `migrations/`. A `core/`/`common/` app holds shared base models and mixins. |
| Thin views, fat services | Business logic lives in a **service layer** (`services.py` for writes, `selectors.py` for reads), never in views or model methods that reach across domains. Views orchestrate: parse → call service → shape response. Models hold field-local invariants only. |
| Cross-app imports | Import another domain's **service/selector**, never reach into its ORM models directly — keeps the dependency direction visible and the app a real boundary. |
| Settings package | `config/settings/{base,dev,prod,test}.py`, selected by `DJANGO_SETTINGS_MODULE`. No environment branching (`if DEBUG:`) inside one giant `settings.py`. |
| App config | Give each app an `AppConfig` with an explicit `default_auto_field = "django.db.models.BigAutoField"`; wire signals in `ready()` (the only place signals get registered). |

```text
src/
  config/         settings/{base,dev,prod,test}.py  urls.py  asgi.py  wsgi.py
  orders/         models.py services.py selectors.py serializers.py views.py urls.py admin.py migrations/
  billing/        models.py services.py selectors.py …
  core/           models.py (TimeStampedModel, …)  permissions.py
```

## 2. Settings & secrets

Split settings as above; load all environment-dependent values through **`django-environ`** (or
`pydantic-settings` if you want typed validation shared with non-Django code) — **never read
`os.environ` ad hoc**, never branch on hostnames.

- **No secrets in source.** `SECRET_KEY`, `DATABASE_URL`, API keys come from env / a secret
  manager, parsed once in `base.py`; a missing required var **fails at boot**, not on first request.
- `DEBUG` defaults to **`False`**; only `dev.py` flips it on. `test.py` sets a fast password hasher
  and an in-memory/throwaway DB.
- Keep `base.py` env-agnostic; `prod.py`/`dev.py` import from it and override. One source of truth
  per key.

```python
# config/settings/base.py
import environ
env = environ.Env(DEBUG=(bool, False))
SECRET_KEY = env("DJANGO_SECRET_KEY")          # raises if unset → fail fast
DEBUG = env("DEBUG")
DATABASES = {"default": env.db("DATABASE_URL")}
ALLOWED_HOSTS = env.list("ALLOWED_HOSTS", default=[])
```

## 3. The ORM

The ORM is the default for the 80% (CRUD, lookups); drop to raw SQL for hot reporting/window
queries and own the plan. Conventions (naming, PK choice, indexes, `timestamptz`/UTC) →
[database.md](../platform/database.md).

| Concern | Rule |
|---|---|
| N+1 | **`select_related`** for FK/one-to-one (SQL `JOIN`), **`prefetch_related`** for M2M/reverse-FK (batched second query). A template or serializer that walks relations without them is an N+1 — assert query counts on hot paths (`assertNumQueries`). |
| QuerySet hygiene | `.only()`/`.defer()` to trim columns (never `SELECT *` semantics on wide tables); `.exists()` not `len(qs)`; `.iterator()` for large scans; `.bulk_create`/`.bulk_update` for batches. Push filtering into the DB, not Python. |
| Indexes & constraints | Declare in `Meta.indexes` / `Meta.constraints` (`UniqueConstraint`, `CheckConstraint`) — they live in migrations and are enforced **in the DB**, not just in `clean()`. Index every FK and hot `WHERE`/`ORDER BY` column. |
| Transactions | Wrap multi-write services in `transaction.atomic()`; keep them short (no network calls inside). Use `select_for_update()` for read-modify-write races. |
| Managers | Encapsulate canonical filters in a custom `Manager`/`QuerySet` (`objects.active()`), not copy-pasted `.filter(deleted_at__isnull=True)`. |

### Migrations

Every schema change is a **reviewed, committed migration** (`makemigrations` → inspect → commit);
`migrate` runs as a **deploy step**, never `migrate --run-syncdb` or model edits without a migration.
CI gates `manage.py makemigrations --check --dry-run` (fails if a model drifted from its migrations).

- **Zero-downtime = expand → contract** ([database.md](../platform/database.md)): additive migration
  first, backfill in a **separate management command/job** (never a heavy `RunPython` `UPDATE` that
  holds locks during deploy), drop the old column in a *later* release. Renames and `NOT NULL`-on-
  existing are expand/contract in disguise.
- Data migrations declare `elidable=True` when squashable; pair every `RunPython` with a real
  reverse or `RunPython.noop`.

## 4. Views & URLs

Default to **class-based views** (`ListView`/`DetailView`/`CreateView`) for server-rendered pages
and **DRF viewsets** for APIs (§5); reach for a function view only for a genuinely trivial endpoint.

- Views stay **thin** — no business logic, no multi-step writes. Call a service; render or serialize
  the result. Validation lives in forms/serializers, not `if request.POST.get(...)` chains.
- `urls.py` per app, `include()`d from `config/urls.py`; name every route and use `reverse()` —
  never hand-build URL strings.
- Fail fast with the right status before expensive work; let domain errors map to responses centrally
  (§5), don't `try/except` in every view.

## 5. Django REST Framework

DRF is the API standard. The **serializer is the boundary** — untrusted input is parsed and
validated there, typed objects flow inward; ORM rows never serialize themselves to the wire.

| Piece | Rule |
|---|---|
| Serializers | Separate **read vs write** serializers (or `read_only`/`write_only` fields); never expose a model field-for-field with `fields = "__all__"` — it leaks columns you add later. Cross-field rules in `validate()`; object creation delegates to a service, not fat `create()`/`update()`. |
| ViewSets + routers | `ModelViewSet`/`GenericViewSet` + a `DefaultRouter`; override `get_queryset()` to scope rows to the caller and to apply `select_related`/`prefetch_related`. |
| Permissions | **Deny by default**: set `DEFAULT_PERMISSION_CLASSES = [IsAuthenticated]` globally and add object-level `has_object_permission`. Public endpoints are the explicit `AllowAny` exception. Policy/RBAC model → [app-security.md](../practices/app-security.md). |
| Auth | Token auth via a vetted library (`SimpleJWT` for JWT, or DRF `TokenAuthentication`/session for first-party clients) — don't hand-roll. Set `DEFAULT_AUTHENTICATION_CLASSES` explicitly. |
| Errors | A custom exception handler emits **`application/problem+json`** (RFC 9457); map domain exceptions → status centrally. Throttling via `DEFAULT_THROTTLE_*`. Contract/versioning/pagination → [api-design.md](../design/api-design.md). |

```python
class OrderViewSet(ModelViewSet):
    serializer_class = OrderReadSerializer
    permission_classes = [IsAuthenticated, IsOrderOwner]

    def get_queryset(self):                       # scope + eager-load in one place
        return Order.objects.filter(owner=self.request.user).select_related("customer")
```

## 6. Async views & ASGI

Django supports `async def` views, async ORM methods (`aget`, `acreate`, `async for`), and async
middleware — but the **ORM is not natively async**: async query methods run on a threadpool under
the hood. Async pays off for I/O fan-out (concurrent outbound HTTP, streaming), not for CPU or
straight DB CRUD.

- **Never call sync work inside `async def`** unwrapped — wrap with `sync_to_async(...)`; conversely
  `async_to_sync(...)` to call async from sync. A sync DB driver or `requests` call stalls the loop
  (see [python.md](../languages/python.md) §7).
- Serve async stacks (Channels/WebSockets, SSE, async views) under **uvicorn/granian via Gunicorn's
  ASGI worker**; pure sync apps stay on **Gunicorn (sync workers)**. Don't mix paradigms in one view.
- **DRF is sync-only** today — don't write `async def` DRF actions expecting concurrency; keep the
  async surface in plain Django async views or Channels consumers.

## 7. Security

Django ships strong defaults — the job is to **not undo them** and to turn on the prod hardening
settings. Gate every deploy on **`manage.py check --deploy`** in CI.

| Setting | Value | Why |
|---|---|---|
| `DEBUG` | **`False`** in prod | `True` leaks settings/tracebacks/SQL to users — the canonical breach. |
| `ALLOWED_HOSTS` | explicit list | Blocks Host-header poisoning; `["*"]` is never acceptable in prod. |
| `SECURE_SSL_REDIRECT` / `SECURE_HSTS_SECONDS` (+`_INCLUDE_SUBDOMAINS`,`_PRELOAD`) | on | Force HTTPS + HSTS. |
| `SESSION_COOKIE_SECURE` / `CSRF_COOKIE_SECURE` | `True` | Cookies only over TLS. |
| `SECURE_CONTENT_TYPE_NOSNIFF`, `SECURE_PROXY_SSL_HEADER`, `CSRF_TRUSTED_ORIGINS` | set | Behind a proxy, trust forwarded TLS correctly; list trusted POST origins. |

- **CSRF** middleware stays on for cookie/session forms; DRF token/JWT APIs are CSRF-exempt by
  design (no cookie auth) — don't blanket-disable it.
- ORM parameterizes by default — keep it that way; `.raw()`/`extra()` use params, **never**
  f-strings. Templates auto-escape — don't `|safe` untrusted data.
- AuthN/authZ policy, password/session model, OWASP coverage → [app-security.md](../practices/app-security.md).

## 8. Background tasks

Out-of-request work (email, webhooks, exports, third-party calls) goes to a **broker-backed queue —
Celery** (the default; Redis/RabbitMQ broker) or **RQ** for simpler Redis-only setups. Never
fire-and-forget threads in the request path.

- **Tasks must be idempotent and retry-safe** — they will run more than once. Key on an idempotency
  token, make the effect a no-op on replay, and bound retries with backoff. Patterns →
  [resilience.md](../design/resilience.md).
- **Don't pass ORM objects** to tasks; pass the **PK** and re-fetch inside the task (the object may
  have changed or vanished). Enqueue **after commit** (`transaction.on_commit(...)`) so a rolled-back
  write can't dispatch a task for a row that never persisted.
- Tasks are thin wrappers over the same **service layer** (§1) — no business logic duplicated in the
  task body.

## 9. Testing

`pytest` + **`pytest-django`** (not bare `manage.py test`); strategy/coverage →
[testing-strategy.md](../practices/testing-strategy.md).

- **`factory_boy`** (or `model_bakery`) for test data — never hand-built fixtures or committed JSON
  dumps. Factories keep tests resilient to added non-null fields.
- Run against a **real Postgres via Testcontainers** (or `pytest-django`'s managed test DB), not
  SQLite — SQLite hides constraint/transaction/JSON differences that bite in prod.
- Use **`assertNumQueries`** on hot endpoints to lock N+1 regressions (§3); use DRF's `APIClient`
  for API tests and assert on **status + serialized shape**, not ORM internals.
- Cover the **permission-denied and error paths**, not just the happy path — a viewset must return
  403/404/`problem+json`, not a 500.

## 10. Admin hardening

The admin is powerful and a prime target — treat it as privileged infrastructure.

- **Move it off `/admin/`** to an unguessable path; put it behind SSO/MFA and an IP allow-list / VPN
  _(scale-up)_. Never expose it on the public internet unauthenticated.
- Register models with explicit `list_display`/`search_fields`/`readonly_fields`; mark audit and
  computed fields read-only so staff can't corrupt them. Scope `get_queryset` per staff role.
- The admin is for **operators, not as your API** — don't build customer-facing flows on it.

## Definition of done

- [ ] Apps split by domain; business logic in a service/selector layer, views and tasks stay thin.
- [ ] Settings split (`base/dev/prod/test`); all env values via `django-environ`/`pydantic-settings`; no secrets in source; `DEBUG=False` in prod.
- [ ] Schema changes are reviewed migrations; `makemigrations --check` gates CI; backfills run as separate jobs (expand/contract).
- [ ] N+1 guarded with `select_related`/`prefetch_related` + `assertNumQueries`; indexes/constraints declared in `Meta`; writes wrapped in short `atomic()` blocks.
- [ ] APIs use DRF viewsets with read/write serializers as the boundary; no `fields = "__all__"`; querysets scoped + eager-loaded.
- [ ] Permissions deny-by-default (`IsAuthenticated` global + object-level); auth via a vetted library; errors → `application/problem+json`.
- [ ] Async only where it pays (I/O fan-out); sync work wrapped in `sync_to_async`; async served under an ASGI worker; DRF kept sync.
- [ ] `manage.py check --deploy` clean: `ALLOWED_HOSTS` set, `SECURE_*`/cookie flags on, CSRF intact, no raw-SQL string interpolation.
- [ ] Out-of-request work on Celery/RQ; tasks idempotent, pass PKs, enqueued via `on_commit`.
- [ ] Tests via `pytest-django` + `factory_boy` against real Postgres (Testcontainers); error/permission paths covered.
- [ ] Admin relocated, behind SSO/MFA, with read-only audit fields and role-scoped querysets.

**Sources:** [HackSoftware/Django-Styleguide](https://github.com/HackSoftware/Django-Styleguide) · [cookiecutter/cookiecutter-django](https://github.com/cookiecutter/cookiecutter-django) · [Django docs — async support](https://docs.djangoproject.com/en/5.2/topics/async/) · [Django docs — deployment checklist](https://docs.djangoproject.com/en/5.2/howto/deployment/checklist/) · [Django REST framework](https://www.django-rest-framework.org/) · [django-environ](https://django-environ.readthedocs.io/)
