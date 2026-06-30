---
name: caching-standards
description: Use when adding or tuning a cache layer, configuring Redis/Valkey, designing cache keys/TTLs, setting CDN/HTTP cache headers, or building rate limiting in a touchstone repo — covers the cache hierarchy, read/write patterns, invalidation, and stampede protection. Boundary: caching as a resilience pattern (stale-serve, fail-open) → resilience-standards; queues/streams → event-driven-standards.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Caching (platform)

Full standard: **`standards/platform/caching.md`** in the touchstone repo. Load-bearing rules inlined
so this stays useful standalone:

## Always
- **TTL on every entry** — a self-healing net for the invalidation you forgot; jitter it (`base + random`) so keys don't expire in lockstep.
- **Cache-aside is the default**; on a write, update the source of truth FIRST then **delete** the key (never rewrite it — that races).
- **`maxmemory` + explicit `maxmemory-policy`** on Redis/Valkey (`allkeys-lru` for a cache); default `noeviction` makes writes fail when full.
- **Correctness lives in the source of truth** — a cache must be deletable at any moment without data loss.

## Don't get burned
- **Stampede**: a hot key expiring melts the DB — TTL jitter + single-flight/coalescing, or early-recompute/stale-while-revalidate (resilience.md §7).
- **Single thread**: `KEYS *`, big `SORT`, huge `SMEMBERS` block every client — use `SCAN`, pipeline, keep ops O(1)/O(log n).
- **Hot key / big key**: one slot pins a shard — client-cache or shard the key; audit with `--bigkeys`/`--hotkeys`; chunk giant values.
- **Redlock** is contested — for correctness use etcd/ZooKeeper; single-instance `SET NX PX <ttl>` covers efficiency locks.
- **Never cache PII/secrets/authz grants** in a shared cache — `private, no-store` for authenticated responses (data-privacy.md); re-check grants.

## Done
TTL + documented invalidation per cache · cache-aside writes delete the key · `maxmemory`+policy set · keys namespaced/versioned · stampede protection on hot keys · no blocking ops · locks use `SET NX PX` · no PII in shared caches · hit rate/evictions/p99 alerted. See `standards/platform/caching.md`.
