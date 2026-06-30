# Search & Retrieval Standards

How we make a corpus *findable*: full-text relevance, faceting, and vector/hybrid retrieval on a
dedicated search engine kept in sync with the system of record. The database that owns the truth
and the alias-swap reindex pattern lean on [./database.md](./database.md); embeddings as the input
to a RAG pipeline (chunking, reranking, grounding, eval-as-tests) belong to
[../practices/ai-engineering.md](../practices/ai-engineering.md) — this doc owns the *retrieval
layer*, not the generation on top of it. Query-latency SLOs and dashboards defer to
[./observability.md](./observability.md); what may never be indexed and per-tenant isolation to
[../practices/data-privacy.md](../practices/data-privacy.md).

> **One law:** the search index is a derived, rebuildable projection of the source of truth — never
> the system of record. If you can't drop it and reindex from the DB, you've built a database with
> none of the guarantees.

---

## 1. When search ≠ a `LIKE` query (and when the DB is enough)

Reach for a search engine only when the query is about *relevance*, not equality. `LIKE '%term%'`
and a B-tree get you a long way; don't stand up a cluster to avoid an index.

| You need | Use | Not |
|---|---|---|
| Exact / prefix match, a known column, low volume | **Postgres** B-tree / trigram (`pg_trgm`) | a search cluster |
| Full-text on one language, modest corpus | **Postgres `tsvector` + GIN** | Elasticsearch (yet) |
| Ranked relevance, typo tolerance, facets, synonyms, multi-field scoring | **a search engine** | `LIKE`, which can't rank |
| Semantic "find similar" / meaning over keywords | **vector search** (§6) | lexical search alone |

- **`LIKE '%x%'` can't use an index and can't rank** — it scans, returns unordered rows, and has no
  notion of "best match". The moment requirements include *ordering by relevance*, you've outgrown it.
- **Postgres full-text is the right first step.** `to_tsvector`/`to_tsquery` with a GIN index handles
  stemming and boolean queries for a single corpus without new infra — adopt a dedicated engine when
  you need cross-field scoring, faceting, typo tolerance, or analyzers Postgres can't express.
- **One source of truth, one derived index.** The engine is a read-optimized *copy*; writes go to the
  DB ([./database.md](./database.md)) and flow to the index (§7). Never let search be the only home
  for a record.

## 2. The default engine

| Engine | Reach for | Trade-off |
|---|---|---|
| **Elasticsearch / OpenSearch** *(default)* | Relevance tuning, aggregations, vectors, scale, the 80% | Operationally heavy; JVM; you own mappings |
| **Typesense / Meilisearch** *(escape hatch)* | Instant-search UX, small/medium corpus, fast setup | Less tuning surface, weaker aggregations/analytics |
| **Postgres FTS** | Single corpus, no new infra (§1) | No faceting/typo-tolerance at scale |

- **Default to Elasticsearch or OpenSearch.** Both descend from the same Lucene core; **OpenSearch**
  is the Apache-2.0 fork (after Elastic's 2021 license change — Elasticsearch is now AGPL/Elastic
  v2 again as of 2024). Pick on licensing and managed-offering fit, not features; the index/query
  model in this doc applies to both.
- **Typesense or Meilisearch when "good enough, today" beats tunable.** For autocomplete and
  search-as-you-type over a bounded catalog they're a single binary with sane defaults — the right
  call before you have anyone to tune relevance. Outgrow them when you need deep aggregations,
  custom scoring, or billion-doc scale.
- **One engine.** Don't run Elasticsearch *and* Typesense *and* pgvector for three features — pick
  the one that covers the hardest requirement and serve the rest from it.

## 3. Index design — mappings, analyzers, and the explosion to avoid

The mapping is your schema; get it wrong and you reindex. Define it explicitly — never ship dynamic
mapping to prod.

- **`text` vs `keyword` is the load-bearing distinction.** `text` is analyzed (tokenized, lowercased,
  stemmed) for *full-text relevance*; `keyword` is the raw string for *exact match, sort, facet, and
  aggregate*. A field that's both gets a `keyword` sub-field (`title` + `title.keyword`).
- **Choose the analyzer per field and per language.** The analyzer = char filters → tokenizer →
  token filters (lowercase, stop-words, stemmer, synonyms). Use the language analyzer that matches
  the content; **index and query must use the same analyzer** or scores are nonsense.
- **Disable dynamic mapping; map explicitly.** `"dynamic": "strict"` (or `"runtime"`) so an
  unexpected field is rejected, not silently typed. **Mapping explosion** — thousands of fields from
  dynamic keys (e.g. indexing an arbitrary JSON blob's keys as fields) — bloats the cluster state and
  can take a node down; cap with `index.mapping.total_fields.limit` and use `flattened` for
  open-ended objects.
- **Map only what you query.** Set `"index": false` on display-only fields and `"enabled": false` on
  blobs you only retrieve — every analyzed field costs index size and indexing time.

```json
{ "mappings": { "dynamic": "strict",
  "properties": {
    "title":     { "type": "text", "analyzer": "english",
                   "fields": { "keyword": { "type": "keyword" } } },
    "tags":      { "type": "keyword" },
    "price_cents": { "type": "integer" },
    "created_at":  { "type": "date" },
    "body_vector": { "type": "dense_vector", "dims": 1024, "index": true, "similarity": "cosine" }
  } } }
```

## 4. Relevance — BM25, query vs filter, and the tuning loop

Relevance is **measured, not vibed**. Treat a scoring change like a code change: it needs an eval.

- **BM25 is the default scorer** — Lucene's tuned TF-IDF, the out-of-the-box ranking. Understand its
  knobs (`k1` term-frequency saturation, `b` length normalization) before reaching for custom scoring.
- **Query context scores; filter context filters.** Put relevance clauses (`match`, `multi_match`)
  in `must`/`should` where they contribute to `_score`; put exact constraints (status, tenant, price
  range, dates) in `filter` — **no scoring, and cached**. Misusing query context for a boolean
  constraint wastes CPU and pollutes the score.
- **Boost deliberately, at query time.** `boost` per field (`title^3`) or `function_score` for
  recency/popularity — keep boosts in versioned query templates, not scattered magic numbers.
- **Run the relevance-tuning loop.** Maintain a **judgment list** (queries → graded relevant docs),
  score the engine against it (nDCG / MRR / precision@k), change one thing, re-measure. Without a
  judgment list, "improving relevance" is guesswork; with **Quepid** / a rank-eval API it's a
  regression test. Wire it into CI the same way [../practices/ai-engineering.md](../practices/ai-engineering.md)
  gates on evals.

## 5. Querying — bool, facets, and deep pagination

- **Compose with the `bool` query:** `must` (scored AND), `should` (OR / boost), `filter` (cached
  AND), `must_not` (exclude). It's the workhorse; learn it before exotic query types.
- **Facets are aggregations.** `terms`/`range`/`date_histogram` aggregations power the filter
  sidebar; run them alongside the search in one request. Watch cardinality — a `terms` agg over a
  high-cardinality field is the aggregation equivalent of a mapping explosion.
- **Never deep-paginate with `from`/`size`.** `from: 10000` makes every shard collect and sort
  `from + size` hits — cost grows linearly and the cluster caps it (`max_result_window`, default
  10k). Use **`search_after`** with a stable tie-broken sort for user-facing "next page", and the
  **scroll** or **PIT (point-in-time)** API for full exports.

```json
{ "size": 20,
  "query": { "bool": {
    "must":   [ { "multi_match": { "query": "wireless headset", "fields": ["title^3","body"] } } ],
    "filter": [ { "term": { "tenant_id": "acme" } },
                { "range": { "price_cents": { "lte": 20000 } } } ] } },
  "sort": [ { "_score": "desc" }, { "id": "asc" } ],
  "search_after": [ 12.7, "prod_8431" ] }
```

## 6. Vector & hybrid search

Lexical search matches *tokens*; vector search matches *meaning*. Modern relevance wants both.

- **Embed, then kNN over HNSW.** Encode docs and queries with a pinned embedding model (a model
  change = a full re-embed, a migration not a config flip — owned by
  [../practices/ai-engineering.md](../practices/ai-engineering.md)) and retrieve nearest neighbors.
  **HNSW** is the default ANN index — fast approximate recall; tune `m`/`ef_construction` for
  recall-vs-memory and `ef_search`/`num_candidates` for recall-vs-latency.
- **Pick the vector store by what you already run:**

  | Store | Reach for | Trade-off |
  |---|---|---|
  | **pgvector** | You already run Postgres; modest scale; filters live in SQL | Slower/heavier at very high dims + volume |
  | **Elasticsearch/OpenSearch kNN** | You already run it for lexical → **one engine** for hybrid | Vector tuning less rich than a dedicated DB |
  | **Qdrant / Weaviate** *(scale-up)* | Vector-first workload, billions of vectors, rich filtering | Another system to run and sync |

- **Hybrid > either alone — fuse with RRF.** Run BM25 and vector retrieval, then combine with
  **Reciprocal Rank Fusion** (rank-based, no score normalization needed) rather than hand-weighting
  two incomparable score scales. Pure-vector misses exact terms (codes, names); pure-lexical misses
  paraphrase — hybrid covers both.
- **This is retrieval, not RAG.** Reranking, chunking, grounding, and answer eval live in
  [../practices/ai-engineering.md](../practices/ai-engineering.md); stop at "returns the right
  documents, measured against §4's judgment list".

## 7. Indexing pipelines — bulk, idempotent, alias-swapped

- **Bulk, never per-doc.** Use the **`_bulk`** API in batched requests for backfills and steady
  ingest; single-doc indexing in a loop melts throughput. Tune batch size to a few MB, not a fixed
  count.
- **Indexing is idempotent.** Use the source row's stable ID as `_id` so a replay upserts instead of
  duplicating — reindexing must be safe to run twice (it will be).
- **Zero-downtime reindex via alias swap.** The application always queries an **alias**
  (`products`), never a concrete index. To change a mapping/analyzer: build `products_v2`, backfill
  from the DB, then atomically repoint the alias. No read ever sees a half-built index, and rollback
  is repointing the alias back.

```bash
# atomically swap the alias from the old index to the freshly-built one
curl -XPOST localhost:9200/_aliases -H 'Content-Type: application/json' -d '{
  "actions": [
    { "remove": { "index": "products_v1", "alias": "products" } },
    { "add":    { "index": "products_v2", "alias": "products" } } ] }'
```

- **Keep the DB the source of truth** ([./database.md](./database.md)). Stream changes via outbox/CDC
  (Debezium) or a transactional outbox — *never* dual-write to DB and index in app code without a
  reconcile job; they will drift. A periodic full reindex from the DB is the backstop that proves the
  index is rebuildable (the One law).

## 8. Operations _(scale-up)_

- **Shards are a capacity decision, set at creation and hard to change.** Aim for **10–50 GB per
  shard**; too many small shards waste heap on cluster state, too few prevents parallelism. Size from
  projected corpus growth, not today's data — you can't reshard without a reindex (§7).
- **Replicas buy read throughput and HA**, not write capacity — at least one replica in prod so a
  node loss isn't data loss. Reads fan out across primary + replicas.
- **Snapshot to object storage on a schedule** (`_snapshot` → S3-class) and **rehearse a restore** —
  an untested snapshot is a hope, the same discipline as DB backups ([./database.md](./database.md)).
- **Right-size heap (≤ ~31 GB, leave the rest to the OS page cache)** and watch JVM GC — a search
  cluster lives and dies by heap pressure and the filesystem cache.

## 9. Observability

Detailed dashboards/alerting belong to [./observability.md](./observability.md); the search-specific
signals you must emit:

- **Query latency as a histogram (p99), not a mean** — the slow tail is what users feel; bucket near
  your latency SLO. Split lexical vs vector vs hybrid paths.
- **Relevance metrics over time.** Track the §4 judgment-list scores (nDCG/MRR) as a first-class
  metric and alert on regression — and watch the **zero-results rate** and result CTR as the
  production signal that offline relevance is drifting.
- **Indexing lag and queue depth.** How stale is the index vs the DB? A growing CDC/ingest lag is a
  correctness problem (users search and don't find a just-written record); alert on it.
- **Cluster health** — red/yellow status, heap pressure, rejected bulk queue — page on red, ticket on
  sustained yellow.

## 10. Security & PII

- **Don't index what you can't expose.** A search index is a wide, queryable, often-replicated copy —
  the worst place to leak. Never index secrets/tokens, and field-level restrict or omit PII you don't
  search on; classification and retention rules are owned by
  [../practices/data-privacy.md](../practices/data-privacy.md).
- **Per-tenant isolation is a `filter`, enforced server-side.** Inject the `tenant_id` filter
  (§4–5) from the authenticated session — **never** from a client-supplied parameter, or a user
  paginates into another tenant's data. For strong isolation _(scale-up)_, an index-per-tenant or
  document-level security; for the common case, a mandatory filter applied below the API boundary.
- **Lock the cluster down.** Search engines have shipped with auth-off defaults and been mass-breached
  — require authentication, TLS, and network isolation; the engine is never on the public internet.

## Definition of done

- [ ] Engine justified over `LIKE`/Postgres FTS — the need is *ranked relevance*, faceting, or semantic match
- [ ] One engine chosen deliberately (Elasticsearch/OpenSearch default; Typesense/Meilisearch escape hatch)
- [ ] Mappings explicit (`dynamic: strict`), `text` vs `keyword` correct, analyzers matched index↔query, field-count capped (no mapping explosion)
- [ ] Relevance clauses in query context, constraints in `filter` (cached); boosts in versioned templates
- [ ] A **judgment list** scores relevance (nDCG/MRR) and gates changes in CI
- [ ] Pagination uses `search_after`/PIT — no deep `from`/`size`; facets are aggregations with bounded cardinality
- [ ] _(vector)_ embedding model pinned; HNSW kNN tuned; store chosen by existing stack; **hybrid BM25+vector via RRF**
- [ ] Indexing is **bulk + idempotent** (stable `_id`); reindex is **zero-downtime via alias swap**
- [ ] DB is the source of truth; index synced via outbox/CDC with a full-reindex backstop — the index is rebuildable
- [ ] _(scale-up)_ shards sized (10–50 GB), ≥1 replica, snapshots with a **tested** restore, heap ≤ ~31 GB
- [ ] Query latency (p99 histogram), relevance score, zero-results rate, and indexing lag emitted and alerted ([./observability.md](./observability.md))
- [ ] No secrets/unneeded PII indexed; per-tenant `filter` enforced server-side; cluster authenticated + TLS + network-isolated

**Sources:** [Elasticsearch Guide](https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html) · [OpenSearch docs](https://opensearch.org/docs/latest/) · [Lucene BM25](https://lucene.apache.org/core/) · [pgvector](https://github.com/pgvector/pgvector) · [Reciprocal Rank Fusion](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf)
