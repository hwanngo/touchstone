# Caching Standards

The canonical home for cache *systems* and data-caching operations — the hierarchy, read/write
patterns, invalidation, key design, and **Redis/Valkey** specifics. Caching as a *resilience pattern*
(stampede protection, stale-while-serve, fail-open) is framed in [resilience.md](../design/resilience.md)
— link there for the failure-mode reasoning, don't restate it. Queues and async fan-out live in
[event-driven.md](../design/event-driven.md); the system of record and its buffer cache in
[database.md](./database.md); hit-rate and eviction metrics in [observability.md](./observability.md).

> **One law:** a cache is a performance optimization you must be able to delete at any moment —
> correctness lives in the source of truth, never in the cache.

---

## 1. The cache hierarchy — cache as close to the user as freshness allows

Every layer trades freshness for latency. Push data outward only as far as its staleness tolerance
permits, and let each layer own a different freshness budget.

| Layer | Lives in | TTL feel | Owns |
|---|---|---|---|
| **Client / browser** | `Cache-Control`, local/SW cache | seconds–days | Per-user, immutable assets |
| **CDN / edge** | Cloudflare, Fastly, CloudFront | minutes–hours | Public, shared, geo-distributed reads |
| **App / in-process** | Caffeine, `lru_cache`, local map | seconds | Hot, tiny, per-instance lookups |
| **Distributed** | **Redis / Valkey**, Memcached | seconds–hours | Shared cross-instance state, sessions |
| **DB buffer pool** | Postgres `shared_buffers` | implicit | Page cache — tune, don't bypass |

- **In-process before distributed.** A local cache has no network hop and no serialization — but it's
  per-instance, so it drifts across replicas and can't be invalidated centrally. Use it for small,
  hot, churn-tolerant data; reach for Redis when replicas must agree.
- **Don't cache what the DB buffer already caches.** A well-indexed point lookup hitting warm
  `shared_buffers` is often faster than a Redis round-trip. Measure before adding a layer.

## 2. Read/write patterns — cache-aside is the default

| Pattern | Who fills | Consistency | Use when |
|---|---|---|---|
| **Cache-aside (lazy)** *(default)* | App, on miss | Eventual (TTL) | The 90% — reads dominate, app owns the miss |
| **Read-through** | Cache library/provider | Eventual | You want the miss logic centralized in the cache layer |
| **Write-through** | App writes cache + DB synchronously | Strong-ish, write-cost | Read-after-write must hit fresh cache |
| **Write-behind (write-back)** | App writes cache, async flush to DB | **Lossy** | Extreme write throughput, loss-tolerant counters |

- **Cache-aside is the default.** Read: check cache → on miss, load from DB → populate → return. The
  app owns the contract; the cache stays a dumb store. Simple, debuggable, survives a cache flush.
- **Write-through buys read-after-write** at the cost of a slower write and a populated-but-unread
  cache. Pair it with a TTL so cold entries still expire.
- **Write-behind is a footgun.** A crash between the cache write and the async flush *loses committed
  data*. Only for genuinely loss-tolerant data (view counts, last-seen) — never orders or balances.
- **Always write the DB first or transactionally.** On a write, the safe move is *update DB, then
  delete the cache key* (not update it) — let the next read repopulate. Updating the cache races with
  concurrent writers and re-introduces stale values.

```python
def get_user(uid: str) -> User:
    key = f"v2:user:{uid}"                       # cache-aside read path
    if (cached := redis.get(key)) is not None:
        return User.parse_raw(cached)
    user = db.fetch_user(uid)                     # miss -> source of truth
    redis.set(key, user.json(), ex=300 + random.randint(0, 60))  # TTL + jitter (§5)
    return user

def update_user(uid: str, patch: dict) -> None:
    db.update_user(uid, patch)                    # source of truth FIRST
    redis.delete(f"v2:user:{uid}")                # invalidate, don't rewrite (avoids the race)
```

## 3. Invalidation — TTL-first, explicit second, versioned for whole classes

"There are only two hard things in computer science…" — invalidation is a design decision per cache,
written down, not an afterthought.

- **TTL-first.** Every entry has a TTL — a self-healing safety net so a missed invalidation expires on
  its own. Pick the TTL from the data's staleness tolerance, not a default `3600`.
- **Explicit invalidation** (delete-on-write) on top of TTL for data that must be fresh fast. Belt and
  braces: explicit delete for the common path, TTL for the bust you forgot.
- **Versioned keys for class-wide busts.** Embed a version (`v3:user:{id}`) or a generation counter in
  the key; bump it to invalidate an entire class *without* a `FLUSH` or a key scan — old keys age out
  via TTL. The cleanest way to invalidate "everything about users."
- **Never `KEYS *` to invalidate.** It blocks the single thread (§6); use a versioned prefix or a
  secondary index set you maintain.

## 4. Key design & namespacing

| Rule | Example | Why |
|---|---|---|
| **Namespace by domain** | `cart:{user}:items` | Greppable, ownable, safe to bulk-reason about |
| **Version the schema** | `v2:profile:{id}` | Bump on shape change → instant class invalidation (§3) |
| **Encode the type** | `set:`, `z:`, `h:` prefixes | Self-documenting; prevents type-mismatch ops |
| **Keep keys short but legible** | not `u:{id}`, not `the_user_profile_for:{id}` | Memory is per-key; cluster routes on the hash |
| **Hash-tag for cluster co-location** | `{user:42}:cart`, `{user:42}:wishlist` | Same slot → multi-key ops work in cluster mode |

- **Keys are a public contract** across every service that touches the cache — document the scheme and
  evolve it with versioning, the same discipline as an event schema ([event-driven.md](../design/event-driven.md) §8).

## 5. Stampede / dogpile protection

When a hot key expires, every concurrent reader misses at once and stampedes the DB — the classic
cache-induced outage. This is the *resilience-pattern* face of caching; the mechanics live in
[resilience.md](../design/resilience.md) §7. Owned here: how you implement it.

- **Jitter every TTL.** `ttl = base + random(0, spread)` so a million keys set together don't expire in
  lockstep. The cheapest stampede defense; non-negotiable on bulk-populated caches.
- **Request coalescing / single-flight.** On a miss, one caller fetches and populates while the rest
  wait on the result — not N parallel DB hits. In-process: Go `singleflight`, Python an async lock per
  key. Distributed: a short per-key `SET NX` lock; losers poll or serve stale.
- **Early recompute (probabilistic).** Recompute *before* expiry with a probability that rises as the
  TTL nears (XFetch) so the refresh happens off the critical path while the old value still serves.
- **Stale-while-revalidate.** Serve the expired value and refresh in the background — bounded staleness
  beats a stampede. Standard at the HTTP layer (§11) and worth replicating in app caches.

## 6. Redis / Valkey — the distributed cache

**Valkey** is the Linux Foundation fork of Redis OSS (after the 2024 license change) and is the default
new choice; it's a drop-in protocol-compatible replacement. Pick the data structure for the access
pattern — not everything is a string.

| Structure | Use for | Don't |
|---|---|---|
| String / `SETEX` | Serialized objects, counters (`INCR`) | Store a 10 MB blob (§8 big-key) |
| Hash | Object fields you update individually | Grow unbounded — it never shrinks slots |
| Sorted set (`ZSET`) | Leaderboards, rate windows, time-ordered | Treat as a queue ([event-driven.md](../design/event-driven.md)) |
| Set | Tags, dedup, membership | Use for ordered data |
| Stream | Lightweight event log | Replace Kafka at scale |

- **Cache-only vs. data store — decide and configure for it.** A *cache* sets `maxmemory` + an eviction
  policy and treats persistence as optional. A *data store* (sessions you can't rebuild) needs AOF
  persistence and you must *not* let it evict. Don't run both modes on one instance.
- **Eviction: set `maxmemory` and `maxmemory-policy` explicitly.** The default `noeviction` makes writes
  *fail* when full — for a pure cache use **`allkeys-lru`** (or `allkeys-lfu` for skewed access). For a
  store with TTLs, `volatile-ttl`. Never run a cache without a bound — OOM is worse than eviction.
- **Single-threaded command execution.** One slow command (`KEYS *`, big `SORT`, a million-element
  `SMEMBERS`) blocks *every* other client. Prefer O(1)/O(log n) ops; use `SCAN`, never `KEYS`.
- **Pipeline to kill round-trips.** Batch N commands into one network round-trip; for read-modify-write
  use a Lua script or `MULTI`/`EXEC` to stay atomic on the single thread.

```bash
# bound memory + evict LRU; the single most important cache config line
redis-cli CONFIG SET maxmemory 4gb
redis-cli CONFIG SET maxmemory-policy allkeys-lru
```

- **Replication & cluster** _(scale-up)_ — a primary with replicas gives read scale-out and failover
  (Sentinel/managed); **Cluster** shards the keyspace across primaries when one node's memory or
  throughput is the ceiling. Multi-key ops then require hash-tags (§4). Use a managed offering
  (ElastiCache, MemoryDB, Valkey Cloud) before operating your own.

## 7. Hot keys & big keys

- **Hot key** — one key takes a disproportionate share of traffic (a celebrity user, a global flag) and
  pins a single shard/thread. Fix by *client-side caching* the hot value in-process (§1), or sharding it
  across N replica keys (`flag:{0..9}`) and picking randomly. Cluster can't help — it's one slot.
- **Big key** — a single value/collection so large that fetching or expiring it stalls the thread and
  spikes the network. Cap collection sizes; split a giant hash/set into chunks; never serialize a whole
  table into one key. Audit with `redis-cli --bigkeys` / `--hotkeys`.

## 8. Distributed locks — usually you don't need one

- **Reach for a lock last.** A single-instance `SET key val NX PX 30000` (atomic acquire + TTL) covers
  the common "only one worker does this" case. The TTL is mandatory — a crashed holder must auto-release.
- **Redlock is contested and rarely warranted.** The multi-node Redlock algorithm is not a correctness
  guarantee under GC pauses/clock skew (Kleppmann's critique stands). If you need *correctness* (not just
  efficiency), use a real consensus store (etcd/ZooKeeper) or a DB lock — not Redis. For mere efficiency
  (avoid double-work, duplicates are harmless), single-instance `SET NX` with a fencing token is enough.

## 9. Rate limiting with Redis — token bucket

Redis is the natural home for distributed rate limits: atomic counters shared across all app instances.

- **Token bucket via a Lua script** for atomic check-and-decrement (refill on read). Avoids the
  race between `GET` and `SET` that lets bursts slip through under concurrency.
- **Sliding window with a `ZSET`** (timestamps as scores, `ZREMRANGEBYSCORE` to evict old) when you need
  precise per-window counts over fixed buckets.
- **Fail open or closed deliberately** — if Redis is down, decide whether the limiter denies all or
  allows all ([resilience.md](../design/resilience.md) §6). For abuse protection, fail closed; for a
  fairness throttle, fail open.

```python
# atomic token bucket — one Lua eval, no GET/SET race across instances
TOKEN_BUCKET = """
local tokens = tonumber(redis.call('GET', KEYS[1]) or ARGV[1])
if tokens < 1 then return 0 end
redis.call('SET', KEYS[1], tokens - 1, 'EX', ARGV[2])
return 1
"""
allowed = redis.eval(TOKEN_BUCKET, 1, f"rl:{user_id}", capacity, window_secs)
```

## 10. CDN & HTTP caching

Cache public, shared reads at the edge — it's the highest-leverage layer for read-heavy traffic.

| Directive | Meaning | Use |
|---|---|---|
| `Cache-Control: public, max-age=` | Shared caches may store, fresh for N s | Static, public assets |
| `private` / `no-store` | Per-user / never cache | Authenticated, sensitive responses (§11) |
| `ETag` + `If-None-Match` | Validator → `304 Not Modified` | Revalidate without re-sending the body |
| `stale-while-revalidate=` | Serve stale, refresh in background | Read-heavy pages tolerant of brief staleness |
| `immutable` | Never revalidate within `max-age` | Content-hashed asset URLs (`app.a1b2c3.js`) |

- **Version asset URLs, cache them forever.** Content-hash the filename and serve `max-age=31536000,
  immutable`; deploy a new file rather than invalidating the old one.
- **`Vary` correctly** (`Vary: Accept-Encoding`, and `Authorization`/cookie awareness) so a shared cache
  never serves one user's response to another.

## 11. What NOT to cache

- **PII and per-user secrets out of shared caches.** Never put tokens, PII, or auth material in a CDN or
  a shared response — `Cache-Control: private, no-store` for authenticated responses. Encryption,
  retention, and access rules are owned by [data-privacy.md](../practices/data-privacy.md).
- **Don't cache authorization decisions** longer than they're valid — a cached "allowed" outlives a
  revoked permission. Cache the *identity*, re-check the *grant*.
- **Don't cache write-once-read-once or rapidly-changing data** — the hit rate won't pay for the
  invalidation complexity. Measure hit rate before caching anything (§12).

## 12. Observability

Detailed metrics, dashboards, and alerting belong to [observability.md](./observability.md); the
cache-specific signals you must emit:

- **Hit rate per cache.** The number that justifies the cache's existence. A sub-80% hit rate on a cache
  you added for speed means wrong TTL, wrong keys, or a cache that shouldn't exist.
- **Evictions & `maxmemory` headroom.** Rising evictions mean the working set outgrew memory — the cache
  is thrashing, not caching. Alert before it does.
- **Latency (p99) and connection pool saturation.** A Redis round-trip is on the critical path; a
  saturated pool or a blocked single thread shows up as tail latency on *every* endpoint.
- **Stampede / miss-rate spikes** — a leading indicator of a key-expiry storm or a cold cache post-deploy.

## Definition of done

- [ ] Each cache layer is justified by freshness tolerance; no layer duplicates the DB buffer without measurement.
- [ ] Read/write pattern is chosen per cache (cache-aside default); writes hit the source of truth first and *delete* the key.
- [ ] Write-behind used only for explicitly loss-tolerant data.
- [ ] Every entry has a TTL; invalidation strategy (TTL / explicit-delete / versioned key) is documented per cache.
- [ ] Keys are namespaced, versioned, and type-prefixed; cluster co-location uses hash-tags where needed.
- [ ] Hot keys have stampede protection (TTL jitter + single-flight/early-recompute); no `KEYS`/blocking ops in hot paths.
- [ ] Redis/Valkey has `maxmemory` + an explicit `maxmemory-policy`; cache-vs-store persistence mode is deliberate.
- [ ] Hot-key and big-key risks audited (`--bigkeys`/`--hotkeys`); big values chunked.
- [ ] Distributed locks use `SET NX PX` with a TTL; Redlock avoided unless correctness genuinely demands consensus.
- [ ] Rate limiters are atomic (Lua/ZSET) with a deliberate fail-open/closed decision.
- [ ] HTTP/CDN responses set correct `Cache-Control`/`ETag`/`Vary`; assets are content-hashed + `immutable`.
- [ ] No PII/secrets in shared caches; authenticated responses are `private, no-store`; authz decisions re-checked.
- [ ] Hit rate, evictions, `maxmemory` headroom, and p99 latency are emitted and alerted on.
