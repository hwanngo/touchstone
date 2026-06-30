---
name: search-standards
description: Use when adding full-text or semantic search, standing up Elasticsearch/OpenSearch or a vector DB (pgvector/Qdrant/Weaviate), designing index mappings/analyzers, tuning relevance, or reindexing in a touchstone repo — covers when search beats a SQL LIKE, BM25 relevance, vector/hybrid retrieval, and zero-downtime alias-swap reindexing. Boundary: RAG generation (chunking, reranking, grounding, eval) → ai-engineering-standards; the source-of-truth DB → database-standards.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Search & Retrieval (platform)

Full standard: **`standards/platform/search.md`** in the touchstone repo. It defers RAG specifics
(chunking, reranking, grounding, eval) to `ai-engineering-standards`, the source-of-truth DB and
alias-swap analog to `database-standards`, and latency SLOs to `observability-standards`. Load-bearing
rules inlined so this stays useful standalone in `~/.claude/skills/`:

## Always
- **The index is a derived, rebuildable projection** — the DB is the source of truth; if you can't drop the index and reindex from the DB, stop.
- **Reach for an engine only for ranked relevance/facets/typo-tolerance/semantic match.** `LIKE '%x%'` can't index or rank; Postgres FTS (`tsvector`+GIN) is the right first step.
- **Default to Elasticsearch/OpenSearch**; Typesense/Meilisearch are the lighter escape hatch for instant-search over a bounded catalog. One engine, not three.
- **Explicit mappings (`dynamic: strict`)** — `text` (analyzed, relevance) vs `keyword` (exact/sort/facet); index and query must share the analyzer.
- **Relevance is measured, not vibed** — a judgment list (nDCG/MRR) gates scoring changes in CI, the same way evals gate AI changes.

## Don't get burned
- **Mapping explosion**: dynamic keys mint thousands of fields and can topple a node — `dynamic: strict`, cap `total_fields.limit`, `flattened` for open-ended objects.
- **Query vs filter context**: relevance clauses go in `must`/`should` (scored); constraints (tenant, status, ranges) in `filter` (cached, unscored) — mixing them wastes CPU and pollutes `_score`.
- **Deep pagination**: `from: 10000` makes every shard sort `from+size` and hits `max_result_window` — use `search_after`/PIT, not `from`/`size`.
- **Vectors**: pin the embedding model (a change = full re-embed/migration); HNSW kNN; **hybrid BM25+vector fused with RRF** beats either alone — pure-vector misses exact terms.
- **Reindex without downtime**: query an **alias**, build `_v2`, backfill, **atomically swap the alias**; bulk + idempotent (stable `_id`); sync via outbox/CDC, never an unreconciled dual-write.
- **Security**: never index secrets/unneeded PII (a wide queryable copy); enforce the per-tenant `filter` **server-side** from the session, never a client param; auth + TLS + network isolation on the cluster.

## Done
Engine justified over LIKE/FTS · one engine chosen · mappings explicit, `text`/`keyword` correct, no mapping explosion · relevance in query context, constraints filtered · judgment list gates relevance in CI · `search_after`/PIT pagination · embedding pinned, HNSW kNN, hybrid via RRF · bulk+idempotent indexing, zero-downtime alias swap · DB is source of truth, index rebuildable · _(scale-up)_ shards sized, replica, tested snapshot · latency/relevance/zero-results/lag alerted · no PII indexed, per-tenant filter server-side, cluster locked down. See `standards/platform/search.md`.
