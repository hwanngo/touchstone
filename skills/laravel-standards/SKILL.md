---
name: laravel-standards
description: Use when building or reviewing a Laravel 11/12 app in a touchstone repo — structure, Eloquent, Form Requests, API Resources, queues, frontend, testing. Triggers on `laravel/framework` in composer.json, `artisan`, `app/Http/`, `routes/web.php|api.php`, `*FormRequest`/`JsonResource`. PHP-language rules live in the php skill; this is the framework layer.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Laravel (framework)

Full standard: **`standards/frameworks/laravel.md`** (layers on `standards/languages/php.md`). Rules:

## Always
- **Thin controllers** (prefer single-action `__invoke`); business logic in `app/Services`/`app/Actions`; **avoid fat models** (casts/relations/scopes only). Configure in `bootstrap/app.php` — no resurrected kernels.
- **Validate at the boundary in a Form Request** with a real `authorize()`; hand actions `$request->validated()`, never `$request->all()`.
- **Eloquent hygiene:** guard mass assignment (`$fillable` allowlist, **never `unguard()`**); eager-load to kill N+1 and enable `preventLazyLoading`/`shouldBeStrict` in non-prod; reviewed migrations, backfills as separate jobs; short `DB::transaction`.
- **APIs through `JsonResource`** (never raw models); auth via **Sanctum** (Passport only for OAuth2); Policies **deny-by-default**.
- **Queued jobs** for out-of-request work — idempotent, `ShouldBeUnique`/retries/`failed()`, dispatched `afterCommit`; Horizon for Redis.
- `env()` only inside `config/`; secrets out of source; `config:cache`/`route:cache` in prod; **Pint + Larastan + Pest** gate CI.

## Defer (don't duplicate)
- Schema/migrations/expand-contract → `../../standards/platform/database.md`; API contract/errors → `../../standards/design/api-design.md`; authN/authZ/OWASP → `../../standards/practices/app-security.md`; job retries/idempotency → `../../standards/design/resilience.md`; PHP language/static-analysis baseline → `../../standards/languages/php.md`; test strategy → `../../standards/practices/testing-strategy.md`.

## Done
thin controllers + service/action layer · Form Request validation with `authorize()` · mass assignment guarded + N+1 killed · `JsonResource` APIs, Sanctum, deny-by-default Policies · idempotent queued jobs `afterCommit` · config cached, no secrets in source · Pest on a real DB · Pint/Larastan/Pest gate CI. See `standards/frameworks/laravel.md`.
