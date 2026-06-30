# Laravel Standards

Framework layer; language rules → [php.md](../languages/php.md). The full-stack PHP framework —
use the **latest stable major** (verify the current release). Laravel has **no LTS tier** (none
since Laravel 6): every major gets ~18 months of bug fixes and 2 years of security fixes, so an
older major such as 11.x is already past security-EOL — track the support window, don't pin. This
doc owns only the Laravel-shaped
decisions. Cross-cutting concerns are **deferred, not repeated**: API contracts →
[api-design.md](../design/api-design.md), schema/migrations → [database.md](../platform/database.md),
retries/idempotency → [resilience.md](../design/resilience.md), authN/authZ/OWASP →
[app-security.md](../practices/app-security.md), test strategy →
[testing-strategy.md](../practices/testing-strategy.md), dependencies/supply-chain → [php.md](../languages/php.md) + [security.md](../practices/security.md). Siblings: [rails.md](rails.md),
[django.md](django.md).

> **One law:** controllers stay thin, models stay honest — business logic lives in services/actions,
> and nothing untrusted reaches Eloquent unvalidated.

---

## 1. Application structure

Laravel 11+ ships the **slim skeleton**: no `app/Http/Kernel.php` or `Console/Kernel.php` — routing,
middleware, exceptions, and scheduling are configured in **`bootstrap/app.php`**; one
`AppServiceProvider`. Don't resurrect the old kernels; configure in `bootstrap/app.php`.

| Concern | Rule |
|---|---|
| Thin controllers | Controllers **orchestrate**: validate (via a Form Request §5) → call a service/action → return a Resource/response. No queries, no business rules, no multi-step writes in the controller. Prefer **single-action controllers** (`__invoke`) for one-job endpoints. |
| Service / action layer | Business logic lives in **`app/Services`** (stateful collaborators) or **`app/Actions`** (one public `handle()`/`execute()` per use case). Jobs, commands, and controllers are thin callers of the same action — logic is written once. |
| Avoid fat models | Models hold **field-local** concerns only: casts, relationships, scopes, accessors. Push cross-entity workflows out to actions. A model with `sendInvoiceAndChargeCard()` on it is a refactor. |
| Domain grouping | Group by **feature/domain** once the app grows (`app/Billing/{Actions,Models,...}`) rather than one giant `app/Models` _(scale-up)_. Keep the dependency direction visible. |
| FormRequests, Resources, Jobs | Use the framework's seams (`app/Http/Requests`, `app/Http/Resources`, `app/Jobs`) instead of inventing parallel structures. |

```php
// app/Http/Controllers/CreateOrderController.php — single-action, thin
public function __invoke(StoreOrderRequest $request, PlaceOrder $placeOrder): JsonResponse
{
    $order = $placeOrder->handle($request->user(), $request->validated());
    return OrderResource::make($order)->response()->setStatusCode(201);
}
```

## 2. Config & secrets

Read config through the **`config/*.php`** layer, never `env()` outside config files — once config is
cached, `env()` returns `null` at runtime and silently breaks. Call `env()` only inside `config/`.

- **No secrets in source.** `.env` is git-ignored; commit a sanitised **`.env.example`**. Real secrets
  come from the platform's secret manager / CI vars, never the repo. A missing required key should
  **fail at boot**, not on first request.
- **Cache config in prod:** `php artisan config:cache` + `route:cache` + `event:cache` as a deploy step;
  clear on rollback. Never ship an uncached prod app.
- `APP_DEBUG=false` and `APP_ENV=production` in prod — `true` leaks stack traces and config to users.
  Encrypt at-rest secrets you must store with `php artisan env:encrypt` _(scale-up)_.

## 3. Eloquent & the database

Eloquent is the default for the 80% (CRUD, lookups); drop to the query builder or raw SQL for hot
reporting/window queries and own the plan. Conventions (naming, PK choice, indexes, `timestamptz`/UTC,
expand→contract) → [database.md](../platform/database.md).

| Concern | Rule |
|---|---|
| Migrations | Every schema change is a **reviewed, committed migration**; `php artisan migrate` runs as a deploy step. Never edit a shipped migration — add a new one. Backfills run in a **separate command/job**, not a heavy migration that holds locks (expand→contract → [database.md](../platform/database.md)). |
| N+1 | **Eager-load** relations (`with()`, `load()`, `loadMissing()`); a Blade view or Resource that walks `$order->customer->name` per row without it is an N+1. Enable **`Model::preventLazyLoading()`** (and `shouldBeStrict()`) in non-prod so lazy loads throw in tests, not in prod. |
| Mass assignment | Guard every model: an explicit **`$fillable` allowlist** (preferred) or `$guarded`. **Never `Model::unguard()`** or `$guarded = []` on user-facing input — that's the mass-assignment CVE class. Pass only `$request->validated()` to `create()`/`update()`. |
| Query scopes | Encapsulate canonical filters as **query scopes** (`scopeActive()`) or dedicated query classes, not copy-pasted `->where('status', …)` chains. |
| Transactions | Wrap multi-write actions in **`DB::transaction(...)`**; keep them short (no HTTP calls inside). Use `lockForUpdate()` for read-modify-write races. |
| Reads | `select()` explicit columns on wide tables; `exists()` not `count()`; `chunkById`/`cursor()` for large scans; `->lazy()` not loading 1M rows into memory. |

## 4. Routing & middleware

- Split routes: **`routes/web.php`** (session + CSRF) vs **`routes/api.php`** (stateless, token auth).
  **Name every route** and use `route('orders.show', $id)` — never hand-build URL strings.
- Bind models with **route-model binding** (`Route::get('/orders/{order}')`) and scope bindings to the
  owner so an attacker can't enumerate IDs. Cache routes in prod (`route:cache`) — which forbids
  closures in route files, so use controller classes.
- Cross-cutting request logic (auth, throttling, tenancy) goes in **middleware** registered in
  `bootstrap/app.php`, not copied into controllers. Rate-limit public/auth endpoints with the
  `throttle` middleware and a named `RateLimiter`.

## 5. Validation — Form Requests

**Untrusted input is validated at the boundary in a Form Request**, never with inline `$request->validate([...])`
scattered across fat controllers. The Form Request is the contract: it authorizes and shapes the input
before any action runs.

```php
class StoreOrderRequest extends FormRequest
{
    public function authorize(): bool { return $this->user()->can('create', Order::class); }

    public function rules(): array
    {
        return [
            'sku'      => ['required', 'string', Rule::exists('products', 'sku')],
            'quantity' => ['required', 'integer', 'min:1', 'max:999'],
        ];
    }
}
```

- Put **authorization in `authorize()`** (or a Policy) — a Form Request that returns `true`
  unconditionally has disabled access control. Hand the action **`$request->validated()`**, never
  `$request->all()`.
- Use **`Rule` objects / FormRequest classes** over giant string rules; custom rules as invokable
  `Rule` classes, reused not duplicated.

## 6. APIs

The **API Resource is the boundary** — Eloquent rows never serialize themselves to the wire. Map model →
DTO shape in a `JsonResource`; clients depend on the Resource, not the table.

| Piece | Rule |
|---|---|
| Resources | Shape every response through **`JsonResource`/`ResourceCollection`**; never `return $model` (leaks columns you add later, including hidden ones if `$hidden` slips). Version the resource shape, not the model. |
| Auth | **Sanctum** for SPA/first-party tokens and mobile; **Passport** only when you genuinely need full **OAuth2** (third-party clients, authorization-code grant). Don't hand-roll token auth. Policy/RBAC model → [app-security.md](../practices/app-security.md). |
| Authorization | **Deny by default** via **Policies** (`authorize()`/`can()`); gate every object-level action. Public endpoints are the explicit exception. |
| Errors | Map domain exceptions → status centrally in `bootstrap/app.php`'s exception handler; emit a consistent JSON error body (RFC 9457 `problem+json` where possible). Contract/versioning/pagination → [api-design.md](../design/api-design.md). |

## 7. Queues, jobs & events

Out-of-request work (email, webhooks, exports, third-party calls) goes to a **queued job** on a
real driver (**Redis** + database fallback), processed by `queue:work` under a supervisor. Never
`sleep()` or call slow third-parties synchronously in the request path; use `dispatch()`.

- **Jobs must be idempotent and retry-safe** — they will run more than once. Key on an idempotency
  token, make replay a no-op, set `$tries`/`backoff` and a `failed()` handler, and use
  **`ShouldBeUnique`** to prevent duplicate dispatch. Patterns → [resilience.md](../design/resilience.md).
- **Don't serialize fat state** — pass an ID and re-fetch, or rely on `SerializesModels` (which stores
  the PK). Dispatch **after commit** with `->afterCommit()` so a rolled-back write can't enqueue a job
  for a row that never persisted.
- **Events/listeners** decouple side-effects (an `OrderPlaced` event with queued listeners); keep
  listener bodies thin wrappers over the same action layer (§1). Run **Horizon** for Redis queues to get
  metrics, retries, and supervisor config as code _(scale-up)_.

## 8. Caching

- Use a **shared store (Redis)** in prod, not the `file`/`array` driver, so cache survives across
  workers and deploys. Tag and **invalidate on write** — a cache you can't bust is a bug.
- Reach for **`Cache::remember()`** for expensive reads; cache the *query result*, not whole models you
  then mutate. Guard hot keys against stampede with locks (`Cache::lock()`) _(scale-up)_.
- Config/route/event caches (§2) are a **deploy concern**, separate from application data caching.

## 9. Frontend

Pick **one** rendering model per app and commit to it:

| Stack | When |
|---|---|
| **Livewire** (+ Flux/Volt) | Server-driven, PHP-first teams; least JS. The default for CRUD-heavy internal apps. |
| **Inertia** (React/Vue + TypeScript) | SPA feel with server-side routing/auth, a real JS component layer, no separate API to maintain. |
| **API + separate SPA** | Only when the frontend is a genuinely independent client (mobile, third-party) — then it's a §6 API consumer. |

Start from an **official Laravel 12 starter kit** (React/Vue on **Inertia 2**, or **Livewire**) for
auth scaffolding rather than hand-rolling login/registration/2FA. SPA component-layer rules (React/TS)
live in the relevant frontend standard.

## 10. Testing

**Pest** is the default test runner; **feature tests** are the backbone — hit a route, assert
status + JSON/DB state. Strategy/coverage → [testing-strategy.md](../practices/testing-strategy.md).

- **Model factories** for all test data (`Order::factory()->create()`) — never hand-built fixtures or
  committed SQL dumps; factories stay resilient to added non-null columns.
- Run feature tests against a **real database** (a disposable Postgres/MySQL), not SQLite in-memory —
  SQLite hides constraint, JSON, and transaction differences that bite in prod. Use
  `RefreshDatabase`/transactions for isolation.
- Assert on **status + serialized shape + DB rows** (`assertDatabaseHas`), and cover the
  **authorization-denied and validation-error paths** (403/422), not just the happy path. Lock N+1 with
  `preventLazyLoading` enabled under test (§3).

## 11. Tooling & deploy

| Concern | Tool | Notes |
|---|---|---|
| Formatter | **Laravel Pint** | `pint --test` gates CI; zero-config PHP-CS-Fixer wrapper. |
| Static analysis | **Larastan** (PHPStan) | Run at a committed level (raise it over time); `phpstan analyse` in CI. Also → [php.md](../languages/php.md). |
| Tests | **Pest** | `php artisan test` / `pest` in CI. |
| Runtime | **PHP-FPM** default; **Octane** (FrankenPHP/Swoole/RoadRunner) _(scale-up)_ | Octane keeps the app booted in memory for big throughput gains — but **watch for state leakage between requests** (static props, container singletons holding request state). Only adopt it once you've audited for that. |

```bash
vendor/bin/pint --test          # format check (CI)
vendor/bin/phpstan analyse      # Larastan static analysis (CI)
php artisan test                # Pest feature + unit suite (CI)
php artisan migrate --force     # deploy step, after config:cache/route:cache
```

- Deploy is **migrate → cache config/routes/events → restart workers** (`queue:restart`). Run
  `php artisan about` / `health` checks post-deploy. Keep `composer install --no-dev --optimize-autoloader`
  for prod builds.

## Definition of done

- [ ] Controllers thin (prefer single-action); business logic in `app/Services`/`app/Actions`; no fat models; configured in `bootstrap/app.php` (no resurrected kernels).
- [ ] `env()` only inside `config/`; `.env` git-ignored with a committed `.env.example`; no secrets in source; config/route/event caches built in prod; `APP_DEBUG=false`.
- [ ] Schema changes are reviewed migrations; backfills are separate jobs (expand/contract); N+1 guarded with eager loads + `preventLazyLoading`/`shouldBeStrict` in non-prod.
- [ ] Mass assignment guarded (`$fillable` allowlist, never `unguard()`); only `validated()` data reaches `create()`/`update()`; scopes encapsulate canonical filters; writes in short `DB::transaction`.
- [ ] Validation in Form Requests with real `authorize()`; routes named + cached; cross-cutting logic in middleware; public/auth endpoints throttled.
- [ ] APIs returned through `JsonResource` (never raw models); auth via Sanctum (Passport only for OAuth2); Policies deny-by-default; errors mapped centrally.
- [ ] Out-of-request work on queued jobs — idempotent, `ShouldBeUnique`/retries/`failed()`, dispatched `afterCommit`; Horizon for Redis queues; listeners thin over actions.
- [ ] Caching on a shared store with invalidation-on-write; one frontend model chosen (Livewire/Inertia) from an official starter kit.
- [ ] Tests in Pest — feature tests with factories against a real DB; authorization/validation-error paths covered.
- [ ] Pint, Larastan/PHPStan, and `php artisan test` gate CI; deploy runs migrate → cache → `queue:restart`; Octane adopted only after auditing request-state leakage.

**Sources:** [Laravel docs — Eloquent](https://laravel.com/docs/12.x/eloquent) · [Laravel docs — Validation / Form Requests](https://laravel.com/docs/12.x/validation#form-request-validation) · [Laravel docs — Eloquent: API Resources](https://laravel.com/docs/12.x/eloquent-resources) · [Laravel docs — Queues](https://laravel.com/docs/12.x/queues) · [Laravel docs — Sanctum](https://laravel.com/docs/12.x/sanctum) · [Laravel docs — Configuration & caching](https://laravel.com/docs/12.x/configuration) · [Laravel 11 release notes — streamlined structure](https://laravel.com/docs/11.x/releases) · [Laravel Starter Kits](https://laravel.com/starter-kits) · [Laravel Octane](https://laravel.com/docs/12.x/octane) · [Laravel Pint](https://laravel.com/docs/12.x/pint) · [Larastan](https://github.com/larastan/larastan) · [Pest](https://pestphp.com/)
