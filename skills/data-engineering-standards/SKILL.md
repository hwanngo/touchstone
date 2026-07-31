---
name: data-engineering-standards
description: "Use when building analytics pipelines, dbt models, Airflow/Dagster DAGs, or warehouse/lakehouse SQL in a touchstone repo — medallion layering, ELT, idempotent/backfillable transforms, dimensional modeling, data tests/contracts, lineage, and PII governance. Triggers on dbt models, Dagster/Airflow DAGs, BigQuery/Snowflake/Databricks/DuckDB SQL, Iceberg/Delta tables, Kafka+Flink streaming. Boundary: OLTP schema/migrations/indexing live in database-standards; this owns analytical data movement."
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Data Engineering

Full standard: **`standards/platform/data-engineering.md`** in the touchstone repo. Defers async
*architecture* to [standards/design/event-driven.md](../../standards/design/event-driven.md), pipeline instrumentation to
[standards/platform/observability.md](../../standards/platform/observability.md), and PII rules to
[standards/practices/data-privacy.md](../../standards/practices/data-privacy.md). Load-bearing rules:

## Always
- **Reproducible or it isn't a pipeline** — idempotent writes (`MERGE`/partition-overwrite, never blind `INSERT`), deterministic transforms (no `now()`/`random()`), backfillable from append-only Bronze.
- **ELT, layered Bronze→Silver→Gold** — land raw immutable, clean in Silver, curate dimensional marts in Gold; transform in-warehouse with **dbt**.
- **Use the defaults** — dbt (transform) · Dagster or Airflow (orchestrate) · managed warehouse + DuckDB local · Iceberg/Delta (table format); name the escape hatch, don't assemble per-pipeline.
- **Partition by event time, process incrementally** — high-water mark/CDC, not nightly full-refresh; a retry rewrites one partition.

## Don't get burned
- **Tests run in the DAG and fail the run** — dbt schema/data tests + Great Expectations; *block* on hard invariants (null PK), *warn* on soft anomalies (volume drift). Untested data is unverified data.
- **Schema evolution is additive; breaking = a new version run in parallel** — dbt model contracts + producer data contracts (standards/design/event-driven.md §8) gate downstream breakage.
- **Pipelines fail silently** — monitor the *data*: freshness, volume, distribution, schema. Green job + wrong data is the failure mode; alert on data, page on user impact (standards/platform/observability.md).
- **No raw PII in Gold/analytics** — minimize at ingest, mask in non-prod, and make GDPR erasure cascade into Bronze/Silver/Gold + backups (standards/practices/data-privacy.md §3).

## Done
Reproducible (idempotent · deterministic · backfillable) · ELT Bronze→Silver→Gold · stack defaults or named escape hatch · event-time partitioned + incremental · dimensional Gold with one definition per metric · tests in the DAG · data + model contracts, versioned schema evolution · freshness-aware DAG with SLAs · OpenLineage + catalog · freshness/volume/distribution/schema monitoring · no raw PII, erasure cascades · _(scale-up)_ cost-controlled warehouses. See `standards/platform/data-engineering.md`.
