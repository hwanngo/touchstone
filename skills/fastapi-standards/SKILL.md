---
name: fastapi-standards
description: Use when building a FastAPI service in a touchstone repo — routers, dependencies, pydantic schemas, async endpoints, serving. Triggers on `fastapi` in pyproject/imports, `APIRouter`, `app = FastAPI()`. Language rules live in the python skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# FastAPI (framework)

Full standard: **`standards/frameworks/fastapi.md`** (layers on `languages/python.md`). Rules:

## Always
- **Domain/module structure** (`src/<domain>/{router,schemas,service,deps}`), NOT file-type folders.
- **Sync vs async routes:** `async def` only for non-blocking I/O; blocking I/O → plain `def` (FastAPI runs it in a threadpool); CPU-bound → a worker. Don't make everything `async`.
- **Pydantic v2** request/response/db schemas separated; `response_model`; never return ORM objects raw. Settings via `pydantic-settings`.
- DI via `Depends` (db session per request, auth, pagination); `yield` deps for cleanup; override in tests.

## Defer (don't duplicate)
- API contract/errors → `../design/api-design.md`; DB + Alembic → `../platform/database.md`; authN/authZ → `../practices/app-security.md`; async correctness → `../languages/python.md`.

## Done
ruff/pyright/pytest green · domain modules · async routes correct · OpenAPI versioned. See the doc.
