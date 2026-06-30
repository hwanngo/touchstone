# Data Engineering Standards

How analytical data is moved, modeled, and trusted: pipelines, transformations, the warehouse/lakehouse,
and the contracts that keep derived data correct. This is the home for *analytics* data movement; the
OLTP schema, migrations, and indexing live in [database.md](./database.md), the event/streaming
*architecture* in [event-driven.md](../design/event-driven.md), pipeline *instrumentation* in
[observability.md](./observability.md), test discipline in
[testing-strategy.md](../practices/testing-strategy.md), and PII/governance rules in
[data-privacy.md](../practices/data-privacy.md) — link there, don't restate.

> **One law:** every pipeline must be reproducible — rerun it on the same input and get the same
> output, byte for byte. Idempotent + deterministic + backfillable, or it isn't a pipeline, it's a
> one-off script you'll be debugging at 3am.

---

## 1. Architecture: batch by default, streaming only when latency demands

Pick the processing model from the *latency the consumer actually needs*, not from novelty. Streaming
multiplies operational cost and debugging surface — earn it.

| Need | Use | Why |
|---|---|---|
| Dashboards, reports, ML training, daily/hourly rollups | **Batch** (micro-batch down to minutes) | Cheap, replayable, trivially backfillable; the 90% case |
| Sub-minute reaction (fraud, alerting, live ops) | **Streaming** (Kafka + Flink) _(scale-up)_ | True low latency, at a real ops + correctness tax |
| "Real-time dashboards" that tolerate 1–5 min | **Micro-batch / incremental** | Streaming's perceived benefit without its cost |

- **ELT over ETL.** Land raw data first, transform *inside* the warehouse/lakehouse with SQL. Modern
  warehouse compute is cheaper and more elastic than a bespoke transform tier, and raw landing means
  you can re-derive everything when logic changes — the foundation of backfillability (§3).
- **Layer with the medallion architecture.** Three named zones, each a contract:

  | Layer | Holds | Rule |
  |---|---|---|
  | **Bronze** (raw) | Source data as-ingested, append-only, immutable | Never edit; it's your replay tape |
  | **Silver** (cleaned) | Deduped, typed, conformed, PII handled | One row per real-world event |
  | **Gold** (curated) | Business-level marts, dimensional models (§4) | What BI/ML consumes |

- **Lakehouse, not a swamp.** Object storage + an open table format (§2) gives warehouse semantics
  (ACID, schema, time-travel) over cheap storage. A "data lake" of bare Parquet with no table layer
  is a swamp — no transactions, no schema enforcement, no safe concurrent writes.

## 2. The modern stack — opinionated defaults

One default per job, with the escape hatch named. Don't assemble a stack per pipeline.

| Concern | Default | Escape hatch |
|---|---|---|
| **Transformation** | **dbt** — SQL models, versioned, tested, DAG-aware | Spark/PySpark when logic exceeds SQL or data is too big for warehouse compute |
| **Orchestration** | **Dagster** — asset-centric, typed, lineage + testing built in | **Airflow** when the org already runs it or you need its vast operator ecosystem |
| **Warehouse / query** | **BigQuery / Snowflake / Databricks** — managed, elastic, separates storage+compute | Self-managed only with a platform team and a hard cost case |
| **Local / embedded** | **DuckDB** — run the same SQL on a laptop for dev, tests, and CI | — |
| **Table format** | **Apache Iceberg** — open, engine-agnostic, hidden partitioning, schema/partition evolution | **Delta Lake** in a Databricks-centric shop |
| **Streaming** _(scale-up)_ | **Kafka** (log) + **Flink** (stateful processing, exactly-once *within* Flink) | Spark Structured Streaming if already on Spark |

- **Orchestrate assets, not tasks.** Dagster models the *data asset* a step produces (the Gold table),
  not just "a task ran" — so lineage, freshness, and partition-aware backfills come for free. Airflow's
  task-centric DAGs make you reconstruct what data exists by hand. Default to Dagster on greenfield.
- **DuckDB is the local mirror.** The same dbt SQL runs against DuckDB locally and BigQuery in prod, so
  CI tests transformations without a cloud warehouse — fast, free, deterministic.

## 3. Pipeline principles — idempotent, backfillable, incremental

The load-bearing trio. A pipeline that fails any one of these is a liability.

- **Idempotent writes.** Rerunning a step must not double-count. Use `MERGE`/upsert keyed on a stable
  business key, or **delete-and-insert by partition** — never blind `INSERT` into a target. The cheapest
  recovery from a failed run is "just run it again."
- **Partition by event time, process by partition.** Partition on the logical date the data describes
  (`event_date`), not wall-clock load time. A retry or backfill then rewrites exactly one partition and
  leaves the rest untouched.
- **Incremental, not full-refresh.** Process only new/changed rows via a high-water mark or CDC; reserve
  full rebuilds for small dims or a logic change. Full-refreshing a fact table nightly is a cost and
  latency bomb.
- **Deterministic + side-effect-free transforms.** No `now()`, `random()`, or `current_user` inside a
  model — inject the run timestamp as a parameter so a backfill of last March produces March's numbers.
  Non-determinism makes backfills lie.
- **Backfillable by construction.** Because raw landed in Bronze (§1) and transforms are deterministic,
  any historical window can be recomputed. Test it: pick a past partition, rerun, diff against current.

```sql
-- dbt incremental model: idempotent, partitioned, backfillable.
{{ config(materialized='incremental', unique_key='order_id',
          incremental_strategy='merge', partition_by={'field':'event_date','data_type':'date'}) }}
select
    order_id,
    cast(ordered_at as date)            as event_date,
    customer_id,
    amount_cents
from {{ ref('bronze_orders') }}
{% if is_incremental() %}
  -- only reprocess the window since the last run; a backfill overrides this var
  where ordered_at >= (select coalesce(max(event_date), '1900-01-01') from {{ this }})
{% endif %}
```

## 4. Data modeling — dimensional, one source of truth

- **Star schema for Gold marts.** Narrow **fact** tables (one grain, additive measures, FK to dims)
  surrounded by wide **dimension** tables (descriptive attributes). It's the model BI tools and analysts
  reason about; resist one-big-table sprawl and snowflaking past what's needed.
- **Declare the grain first.** "One row per order line per day." Every measure must be additive at that
  grain, or it's a modeling bug waiting to mislead a dashboard.
- **Slowly-changing dimensions — pick the type per attribute:**

  | Type | Behavior | Use for |
  |---|---|---|
  | **SCD1** | Overwrite in place | Corrections, attributes where history is noise |
  | **SCD2** | New row + `valid_from`/`valid_to`/`is_current` | Attributes whose history matters (price tier, region) |

- **One source of truth per metric.** "Revenue" is defined once, in one Gold model, and everything reads
  it — no metric redefined in five dashboards. Encode shared metrics in a **dbt semantic layer / metrics**
  so the definition lives in version control, not in BI tool config.

## 5. Data quality & contracts — tests are first-class

Untested data is unverified data. Quality checks run *in the DAG* and fail the run, not in a Monday email.

- **Test with dbt.** Schema tests (`not_null`, `unique`, `accepted_values`, `relationships`) on every
  model; data tests for business invariants (margins ≥ 0, totals reconcile). For richer statistical
  expectations use **Great Expectations** / dbt-expectations.
- **Stop bad data at the boundary, two tiers:** *block* on hard invariants (a null primary key fails the
  run); *warn* on soft anomalies (volume off 20%) so they alert without halting the pipeline.
- **Data contracts at producer boundaries.** The producer of an event/source owns its schema as a
  versioned contract — the same registry + backward/forward-compatibility discipline as
  [event-driven.md](../design/event-driven.md) §8. dbt **model contracts** enforce the *output* shape so
  downstream consumers can't be silently broken.

```yaml
# schema.yml — contract on a Gold model: enforced columns + tests run in the DAG
models:
  - name: gold_orders
    config: { contract: { enforced: true } }   # column names/types are a breaking-change gate
    columns:
      - name: order_id
        data_type: string
        constraints: [{ type: not_null }, { type: primary_key }]
        data_tests: [unique]
      - name: amount_cents
        data_type: integer
        data_tests:
          - dbt_utils.accepted_range: { min_value: 0 }   # block: negatives fail the run
```

## 6. Schema evolution — additive, never breaking

- **Additive-only by default.** Add nullable columns; never repurpose, retype, or drop a column under a
  live consumer. Iceberg/Delta evolve schema by stable **field ID**, so a rename doesn't rewrite data or
  break readers — but the *semantic* contract (§5) still gates breaking changes in review.
- **A breaking change is a new version, run in parallel.** Stand up `v2` of the model, dual-populate,
  migrate consumers, then retire `v1` — same expand→migrate→contract dance as schema migrations in
  [database.md](./database.md), applied to derived tables.
- **Backfill on widen.** A new column is `NULL` for history until backfilled — schedule the backfill and
  document the gap so a dashboard doesn't read the hole as zero.

## 7. Orchestration patterns — DAGs, sensors, retries, SLAs

- **DAGs encode real dependencies.** A step runs only after its inputs are *fresh*, not on a hopeful
  `sleep`-and-pray schedule. Asset-based orchestration (§2) derives the DAG from `ref()` lineage.
- **Sensors, not fixed clocks, for cross-system triggers.** Wait on the *arrival* of upstream data (a file
  landed, a partition materialized) rather than guessing it's ready by 2am. Eliminates the brittle
  "upstream was late so we processed yesterday's data" class of bug.
- **Retries with bounded backoff; isolate the poison run.** Transient failures retry with exponential
  backoff + jitter; after N, fail loudly and alert — never silently skip a partition (that's silent data
  loss). Retry mechanics mirror [event-driven.md](../design/event-driven.md) §7.
- **SLAs on freshness, alert on miss.** Each Gold asset declares "fresh within X"; a missed SLA pages
  *before* a stakeholder notices a stale dashboard. Idempotency (§3) makes any retry safe.

## 8. Lineage & catalog — know what feeds what

- **Emit lineage with OpenLineage.** The vendor-neutral standard (Dagster, Airflow, dbt, Spark all emit
  it) captures dataset→job→dataset edges automatically. When Gold is wrong, lineage answers "which source
  and which run" in seconds instead of a tribal-knowledge hunt.
- **Catalog every dataset** — owner, schema, freshness, classification — in a data catalog (DataHub /
  OpenMetadata / Unity Catalog). An undiscoverable table gets re-derived wrongly by the next team.
- **Lineage powers impact analysis.** Before changing a source, the catalog shows every downstream model
  and dashboard it breaks — a review gate, not a post-incident discovery.

## 9. Observability — freshness, volume, distribution

Pipelines fail *silently*: the job is green but the data is wrong. Monitor the data, not just the run —
instrumentation and alerting route through [observability.md](./observability.md).

| Monitor | Detects | Example signal |
|---|---|---|
| **Freshness** | Stalled/late pipeline | Gold table not updated in > SLA window |
| **Volume** | Partial loads, source outage | Row count drops 40% vs trailing 7-day median |
| **Distribution** | Silent logic/source drift | Null rate, mean, or cardinality shifts beyond a band |
| **Schema** | Upstream broke the contract | New/removed/retyped column appears |

- **Alert on the data, page on user impact.** A freshness miss on a critical Gold mart pages; a warn-tier
  distribution drift tickets. Emit these as metrics so they live beside service telemetry, not in a silo.
- **Track end-to-end lineage latency** — source event → queryable in Gold — as your pipeline's p99, the
  same way a service tracks request latency.

## 10. Governance & PII — no raw PII in analytics

Analytics multiplies copies of data; governance is the seatbelt. The classification, retention, erasure,
and DPA rules are owned by [data-privacy.md](../practices/data-privacy.md) — this is how they bind to a
warehouse.

- **Minimize at ingestion.** Don't land PII you won't use. Drop or tokenize identifiers at the Bronze→Silver
  boundary so Gold never holds raw PII.
- **Mask / pseudonymize in non-prod and analytics.** Analysts and ML get hashed/tokenized keys, not raw
  email or SSN; use dynamic data masking or column-level policies the warehouse enforces by role.
- **Erasure must reach the warehouse.** A GDPR delete cascades into Bronze/Silver/Gold and backups, not
  just the OLTP store — the deletion cascade in [data-privacy.md](../practices/data-privacy.md) §3 includes
  every derived table. Append-only Bronze needs a documented purge path.
- **Govern access by role and column.** Row/column-level security on PII-bearing tables; audit who queried
  sensitive data _(scale-up)_.

## 11. Cost control _(scale-up)_

Decoupled storage+compute means cost scales with *bytes scanned and warehouse uptime*, and surprises
finance fast.

- **Prune and cluster.** Partition + cluster Gold tables so queries scan partitions, not the whole table;
  ban `SELECT *` in scheduled jobs (it scans every column you bill for) — mirrors [database.md](./database.md) §3.
- **Incremental beats full-refresh on cost too** (§3) — reprocessing one partition scans a fraction of the
  bytes of a nightly rebuild.
- **Right-size and auto-suspend warehouses.** Separate compute pools per workload (BI vs ETL vs ad-hoc);
  auto-suspend idle warehouses so you don't pay for a cluster waiting for nobody.
- **Monitor spend per pipeline.** Tag jobs and alert on cost-per-run regressions the way you alert on
  latency — a runaway model should page finance-adjacent owners before the monthly bill does.

## Definition of done

- [ ] Batch vs streaming chosen by required latency; streaming has a stated forcing reason
- [ ] ELT into a warehouse/lakehouse; data layered Bronze→Silver→Gold with Bronze append-only
- [ ] Stack uses the defaults (dbt · Dagster/Airflow · managed warehouse · Iceberg/Delta · DuckDB local) or names the escape hatch
- [ ] Every pipeline is idempotent (merge/partition-overwrite), partitioned by event time, and incremental
- [ ] Transforms are deterministic (no `now()`/`random()`); a past partition backfills and diffs clean
- [ ] Gold modeled dimensionally (declared grain, additive measures, SCD type chosen per attribute); each metric defined once
- [ ] dbt/Great Expectations tests run in the DAG and fail the run on hard invariants; soft anomalies warn
- [ ] Producer data contracts + dbt model contracts enforce schema; breaking changes are versioned, not edited
- [ ] DAG runs on freshness-aware dependencies/sensors; retries bounded; freshness SLAs alert on miss
- [ ] OpenLineage emitted; datasets cataloged with owner + classification; impact analysis runs pre-change
- [ ] Freshness/volume/distribution/schema monitored via [observability.md](./observability.md); page on user impact
- [ ] No raw PII in Gold/analytics; minimized at ingest, masked in non-prod, erasure cascades to derived tables + backups
- [ ] _(scale-up)_ Cost controlled: partition/cluster pruning, incremental loads, auto-suspended right-sized warehouses, per-pipeline spend alerts

**Sources:** [dbt best practices](https://docs.getdbt.com/best-practices) · [Dagster docs](https://docs.dagster.io/) · [Apache Iceberg](https://iceberg.apache.org/docs/latest/) · [OpenLineage](https://openlineage.io/docs/) · [The Data Warehouse Toolkit (Kimball)](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/)
