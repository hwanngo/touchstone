# Database & Data Standards

Where most prod incidents and nearly all *irreversible* data loss originate. Schema changes are
deploys: gate them, version them, and make them survivable. Examples lean Postgres; principles
port to any RDBMS. Runtime failure modes live in [resilience.md](../design/resilience.md); the
pipeline wiring in [ci-cd.md](ci-cd.md); DR/backups in [devops.md](devops.md).

---

## 1. Migrations: one home, forward-only, reviewed, run in CI

| Rule | Why |
|---|---|
| **One `migrations/` dir**, ordered, in the app repo | A single source of truth; no out-of-band `ALTER`s in a console |
| **Forward-only**, each migration reversible *in principle* | Down-migrations rot; roll *forward* with a new migration to fix prod |
| **Reviewed like code** + **run in CI** against a throwaway DB | Catches lock/destructive ops before they reach prod |
| **No data backfill inside a DDL migration** | Long-running `UPDATE`s hold locks and block the deploy; backfill in a job |

**Lint every migration for destructive/locking ops.** **Atlas** (`atlas migrate lint`, GA v1.0
Dec 2025) ships 50+ analyzers that flag drops, table-rewriting locks, and backward-incompatible
changes — wire it as a CI gate. Pick by ecosystem: **Atlas** (schema-as-code, best linting),
**Flyway**/**Liquibase** (JVM, enterprise), **golang-migrate** (Go), **Alembic** (Python/SQLAlchemy).
_Escape hatch:_ a destructive op is allowed only when lint is explicitly overridden in the PR with
a one-line justification and a deprecation window already elapsed.

### Zero-downtime: expand → migrate → contract

The contract during any rollout is **N-1 compatibility**: the old and new app versions run *at the
same time* against *one* schema. Never break the version you're replacing.

| Step | Release | Action |
|---|---|---|
| **Expand** | R1 | Add the new column/table (nullable, defaulted). Additive only. |
| **Dual-write / backfill** | R1 | App writes both old+new; a batched job backfills history. |
| **Switch reads** | R2 | App reads the new shape once backfill is verified complete. |
| **Contract** | R3+ | Drop the old column/table — a *separate, later* release. |

Renames and `NOT NULL`-on-existing are expand/contract in disguise: add-new → backfill → swap →
drop. A column drop and an app deploy in the same release is the classic N-1 violation that pages
you at 2am.

## 2. Schema conventions

| Topic | Standard |
|---|---|
| **Naming** | `snake_case`; plural tables (`users`); `fk`/`ix`/`uq` prefixes on constraints |
| **Primary key** | `bigint` identity for single-node simplicity; **UUIDv7** when IDs are client/distributed-generated or externally exposed |
| **Foreign keys** | Always declared (`REFERENCES … ON DELETE …`); they document intent *and* index targets |
| **NOT NULL by default** | Nullable is an explicit, justified choice — `NULL` breaks aggregates and invites bugs |
| **Timestamps** | `created_at`, `updated_at`, `timestamptz`, **UTC** everywhere; never store local time |
| **Soft delete** | `deleted_at timestamptz NULL` + a partial index `WHERE deleted_at IS NULL`; never overload status |
| **Enums** | Lookup table (FK) when values evolve or carry metadata; DB-native `enum` only for truly static, append-only sets |

**PK choice — the real trade-off:** Postgres 18 (2025) ships native `uuidv7()`, which is
time-ordered, so it keeps the index-locality and sequential-insert speed of `bigserial` while
being globally unique. `bigint` is still smaller (8 vs 16 bytes) and leaks nothing. _Caveat:_
UUIDv7 encodes a creation timestamp in its high bits — if IDs are visible to untrusted users and
creation time is sensitive, expose a separate opaque/UUIDv4 handle.

## 3. Indexing & query review

- **Index every FK** and every column that appears in a hot `WHERE`/`JOIN`/`ORDER BY`. Postgres
  does *not* auto-index FKs — unindexed FKs cause slow cascades and lock contention on the parent.
- **`EXPLAIN (ANALYZE, BUFFERS)` gate** for hot or new queries: review the plan in the PR. Reject
  unexpected `Seq Scan` on large tables and runaway row estimates. Cheap discipline, huge payoff.
- **Ban `SELECT *`** — list columns explicitly. `*` breaks under schema change, defeats
  covering indexes, and ships data you don't need.
- **Keyset (cursor) pagination, not `OFFSET`.** `OFFSET 100000` scans and discards 100k rows;
  keyset (`WHERE (created_at, id) < (:c, :id) ORDER BY … LIMIT n`) stays O(page).
- **Watch N+1.** A loop issuing one query per row is the most common latency killer — batch,
  join, or `IN (…)`. See [resilience.md](../design/resilience.md) and the API-design standard.
- Build prod indexes `CREATE INDEX CONCURRENTLY` (outside a txn) so you don't lock writes.

## 4. SQL discipline

| Rule | Detail |
|---|---|
| **Parameterized queries ONLY** | Never string-concatenate input. This is *the* SQL-injection control — see [security.md](../practices/security.md). No exceptions, including "internal" tools. |
| **Explicit column lists** | Reads *and* writes — `INSERT INTO t (a, b)`, never positional |
| **Format + lint** | **sqlfluff** (`sqlfluff lint`/`fix`) in pre-commit and CI; one dialect, one config |
| **Migration SQL ≠ runtime SQL** | Migrations are DDL run once under review; runtime SQL is parameterized DML in app code. Keep them in separate places and review them differently. |

Dynamic SQL (identifiers that must be interpolated) uses an allowlist + the driver's quoting API,
never raw concatenation.

## 5. Access patterns

- **Connection pooling, bounded.** A pool's zero-value is often *unbounded* — set
  `max_open_conns` deliberately so a traffic spike can't open thousands of connections and topple
  the DB. Size from `(cores × N) + headroom`, not optimism. Front Postgres with **PgBouncer**
  (transaction mode) when many app instances connect.
- **Short transactions.** Open late, commit early; never hold a txn across a network/RPC call or
  user think-time. Long txns block VACUUM and pile up locks.
- **Statement & lock timeouts** on every connection (`statement_timeout`, `lock_timeout`,
  `idle_in_transaction_session_timeout`) — a runaway query should die, not hang the pool.
- **Read replicas** _(scale-up)_ for heavy read/analytics traffic; route explicitly and design
  for replication lag (read-your-writes goes to primary).

## 6. ORM vs raw SQL

| Use | For |
|---|---|
| **ORM** | CRUD, simple lookups, the 80% — productivity and safety by default |
| **Raw SQL / query builder** | Hot paths, reporting, complex joins, window functions, bulk ops |

The ORM is a default, not a religion. Its biggest trap is **lazy-loading N+1**: eager-load
(`selectinload`/`JOIN`/`Include`) on collection access, and log/assert query counts in tests for
hot endpoints. When a query is performance-critical, write the SQL and own the plan.

## 7. Operational

- **Backups + a *tested* restore.** An untested backup is a hope, not a backup. Automate
  point-in-time recovery (PITR), and **rehearse a full restore on a schedule** — measure RTO/RPO
  against the target. DR runbook lives in [devops.md](devops.md).
- **Retention & PII.** Define retention per table; expire/anonymize on schedule. Know where PII
  lives, encrypt at rest, and gate access — see [data-privacy.md](../practices/data-privacy.md).
  Atlas PII analyzers can flag sensitive columns entering the schema.
- **Migrations are observable:** alert on long-running migrations and lock waits; have a documented
  rollback-forward path before you run anything in prod.

---

## Definition of done

- [ ] Single `migrations/` home; forward-only, reviewed, run in CI against a real DB
- [ ] Destructive/locking ops linted (`atlas migrate lint` or equivalent) as a gate
- [ ] Schema changes follow expand/contract; N-1 compatibility verified across the rollout
- [ ] No backfill inside DDL migrations; backfills batched in a separate job
- [ ] Conventions enforced: NOT NULL default, `timestamptz`/UTC, FKs declared + indexed
- [ ] PK choice deliberate (`bigint` vs UUIDv7) with the exposure trade-off considered
- [ ] Hot queries have an `EXPLAIN ANALYZE` plan reviewed; no `SELECT *`; keyset pagination
- [ ] All SQL parameterized; sqlfluff lints in CI
- [ ] Pool bounded; statement/lock/idle timeouts set; txns kept short
- [ ] ORM N+1 guarded (eager loads + query-count assertions on hot paths)
- [ ] Backups automated with a **tested** restore/PITR; retention + PII handling defined
