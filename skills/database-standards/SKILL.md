---
name: database-standards
description: Use when designing a database schema, writing a migration, tuning queries/indexes, or writing SQL in a touchstone repo. Invoke before adding a migration, a destructive schema change, or a query on a hot path.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Database & Data

Full standard: **`standards/platform/database.md`** in the touchstone repo. Load-bearing rules:

## Always
- **Migrations forward-only + reviewed + run in CI**; one `migrations/` home; lint destructive changes (e.g. `atlas migrate lint`).
- **Zero-downtime = expand/contract**: add new → dual-write/backfill → switch reads → drop old in a LATER release. **N-1 compatible** — two app versions run at once during rollout, so never a one-shot `RENAME`/`DROP` with code that assumes it.
- **Parameterized queries only** (injection — see standards/practices/app-security.md).
- Index FKs + query predicates; **EXPLAIN hot queries**; ban `SELECT *`; **keyset (cursor) pagination**, not OFFSET. Bound the connection pool (the zero-value pool is unbounded); short transactions; statement timeouts.

## Schema
- NOT NULL by default; explicit FKs; UTC timestamps; deliberate PK choice (UUIDv7 vs bigserial); format SQL with sqlfluff.

## Access & ops
- ORM for CRUD, raw SQL for hot paths; watch ORM N+1.
- Backups with **tested** restore/PITR (standards/platform/devops.md); PII retention (standards/practices/data-privacy.md).

## Done
Migration forward-only + expand/contract (N-1 safe) · destructive changes linted · FKs/predicates indexed, hot queries EXPLAINed, no `SELECT *` · parameterized queries only · pool bounded + statement timeouts. See `standards/platform/database.md`.
