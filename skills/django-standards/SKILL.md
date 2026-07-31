---
name: django-standards
description: Use when building or reviewing a Django 5.x app in a touchstone repo — apps, settings, the ORM, DRF APIs, async, tasks, admin. Triggers on `django` in deps, `manage.py`, `settings.py`, `models.py`, `APIView`/viewsets. Language rules live in the python skill; this is the framework layer.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Django (framework)

Full standard: **`standards/frameworks/django.md`** (layers on `standards/languages/python.md`). Rules:

## Always
- **Apps by domain** (`orders/`, `billing/`), thin views/tasks, business logic in a **service/selector layer** — not in views or fat serializers.
- **Settings split** (`base/dev/prod/test`) via `django-environ`/`pydantic-settings`; no secrets in source; `DEBUG=False` in prod; `manage.py check --deploy` gates CI.
- **ORM hygiene:** `select_related`/`prefetch_related` + `assertNumQueries` for N+1; indexes/constraints in `Meta`; short `transaction.atomic()`; reviewed migrations with `makemigrations --check`.
- **DRF:** read/write serializers as the boundary (never `fields = "__all__"`); viewsets with scoped, eager-loaded querysets; permissions **deny-by-default** (`IsAuthenticated` + object-level).
- Background work on **Celery/RQ** — idempotent, pass PKs, enqueue via `transaction.on_commit`.

## Defer (don't duplicate)
- Schema/migrations/expand-contract → `../../standards/platform/database.md`; API contract/errors → `../../standards/design/api-design.md`; authN/authZ/OWASP → `../../standards/practices/app-security.md`; task retries/idempotency → `../../standards/design/resilience.md`; async correctness → `../../standards/languages/python.md`; test strategy → `../../standards/practices/testing-strategy.md`.

## Done
check --deploy clean · domain apps + service layer · N+1 guarded · DRF deny-by-default · idempotent tasks · pytest-django + factory_boy on real Postgres. See `standards/frameworks/django.md`.
