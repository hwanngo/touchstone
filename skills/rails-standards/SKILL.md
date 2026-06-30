---
name: rails-standards
description: Use when building or reviewing a Ruby on Rails 7.2/8 app in a touchstone repo — structure, ActiveRecord, strong params, routing, Hotwire, jobs, caching, security. Triggers on `rails`/`railties` in the Gemfile, `config/routes.rb`, `app/models`, `app/controllers`, `db/migrate`. Ruby-language rules live in the ruby skill; this is the framework layer.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Ruby on Rails (framework)

Full standard: **`standards/frameworks/rails.md`** (layers on `standards/languages/ruby.md`). Rules:

## Always
- **Thin controllers** (authenticate → strong-params → one service/model call → respond); multi-step business logic in **service objects / POROs** under `app/services`, not fat models.
- **Strong parameters** at every controller boundary (`params.require(...).permit(...)`); `permit!` banned; multi-model input goes through a form/request object.
- **ActiveRecord hygiene:** `includes` + `bullet` for N+1; canonical filters as **scopes**; uniqueness backed by a DB index; **no callbacks for business logic** (mail/charges/cross-aggregate writes).
- **Migrations:** reviewed + committed; `strong_migrations` gates unsafe ops; expand→contract for zero-downtime; backfill in a separate job; indexes added `concurrently`.
- **Hotwire is the default frontend** (Turbo + Stimulus); serializers/jbuilder are the API boundary — never `render json: model`.
- Background work on **Active Job** (Solid Queue / Sidekiq) — idempotent, pass **ids** not records, enqueue **after commit**.

## Defer (don't duplicate)
- Schema/migrations/expand-contract → `../platform/database.md`; API contract/errors/versioning → `../design/api-design.md`; authN/authZ/OWASP → `../practices/app-security.md`; job retries/idempotency → `../design/resilience.md`; Ruby-language idioms → `../languages/ruby.md`; test strategy → `../practices/testing-strategy.md`.

## Done
thin controllers + service layer · strong params everywhere · N+1 guarded (bullet) · no business-logic callbacks · strong_migrations + expand/contract · Hotwire frontend · idempotent Active Job · brakeman/bundle-audit clean · encrypted credentials · factory_bot on real Postgres · Kamal deploy. See `standards/frameworks/rails.md`.
