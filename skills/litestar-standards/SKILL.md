---
name: litestar-standards
description: Use when building a Litestar service in a touchstone repo — controllers, dependencies, DTOs/msgspec, guards, plugins, serving. Triggers on `litestar` in pyproject/imports, `Litestar(...)`, Controller classes. Language rules live in the python skill.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Litestar (framework)

Full standard: **`standards/frameworks/litestar.md`** (layers on `standards/languages/python.md`). Rules:

## Always
- **Domain-driven structure** (`domain/<ctx>/{controllers,services,schemas,deps,guards}`); app composed via plugins (`InitPluginProtocol`).
- **msgspec `Struct`** for hot paths (Litestar's fast default) + **DTOs (`DTOConfig`)** to decouple wire from DB models; `msgspec.UNSET` for partial updates; never return ORM objects raw.
- **advanced-alchemy** repository + service layer for persistence; type-driven validation (signature types ARE the schema).
- Layered **DI** (`Provide`, scopes, `use_cache`); **guards** for deny-by-default authZ; first-party JWT/session auth over hand-rolled middleware.

## Defer
- API contract → `../../standards/design/api-design.md`; DB → `../../standards/platform/database.md`; authN/authZ model → `../../standards/practices/app-security.md`; async → `../../standards/languages/python.md`.

## Done
ruff/pyright/pytest green · DTOs at the boundary · OpenAPI versioned · guards enforce authZ. See the doc.
