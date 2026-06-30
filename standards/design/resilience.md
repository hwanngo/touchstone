# Error Handling, Resilience & Reliability

Code-level patterns that decide whether a dependency's bad day is a **hiccup or a cascade**. This is
the in-process toolkit — timeouts, retries, breakers, backpressure, idempotency, caching, async.
System shape lives in [architecture.md](architecture.md); contracts in [api-design.md](api-design.md).
SLOs, error budgets, and observability are operational → [devops.md](../platform/devops.md).

> **One law:** every component that calls something it doesn't own assumes that thing is slow, down,
> or lying. Design for that, not for the happy path.

---

## 1. Timeouts everywhere

- **Every outbound, network, and DB call has a deadline.** No unbounded waits — ever. A missing
  timeout is the single most common cause of total outages (one stuck pool exhausts every worker).
- **Propagate deadlines, don't reset them.** A request with a 2s budget that fans out to three calls
  shares that 2s — pass the remaining deadline down (Go `context.Context`, see
  [golang.md](../languages/golang.md); Python `asyncio.timeout()`, see [python.md](../languages/python.md)).
- **Two timeouts, not one:** connection timeout (fast, ~1s) vs. overall/read timeout (the budget).
- **Default libraries lie.** Most HTTP/DB clients default to *no* timeout or minutes. Set them explicitly.

| Layer | Timeout | Notes |
|---|---|---|
| HTTP client | 1–5s typical | Always < caller's remaining budget |
| DB query | statement_timeout | Kill runaway queries at the DB, not just the client |
| Connection acquire | 100ms–1s | Fail fast when the pool is drained |
| Total request | hard cap | Drop work that's already exceeded its budget |

## 2. Retries — bounded, idempotent, budgeted

Retries turn transient failures invisible — and amplify outages into **retry storms** if naive.

- **Only retry idempotent operations** (GET, PUT, DELETE; POST only with an idempotency key — §5).
- **Never retry 4xx.** A 400/401/403/404/422 won't change on retry; you're just burning capacity.
  Retry on 429/503/connection-reset/timeout — and honor `Retry-After`.
- **Bounded attempts:** 2–3 total, not "until it works."
- **Exponential backoff + full jitter** — `sleep = random(0, base * 2^attempt)`. Jitter is mandatory;
  synchronized retries (no jitter) re-collide and DDoS your own backend.
- **Retry budget** — cap retries at a % of live traffic (e.g. 10%). When the budget is spent, fail
  immediately. This is the circuit breaker for retries and the real defense against storms.
- **Retry at one layer only.** Retries at client + gateway + service multiply (3×3×3 = 27 calls).

```text
attempt 1: t=0
attempt 2: t += random(0, 100ms)
attempt 3: t += random(0, 200ms)   # cap at e.g. 2s; stop at budget
```

## 3. Circuit breakers & bulkheads

- **Circuit breaker** — trip open after an error/latency threshold so you stop hammering a sick
  dependency; serve a fallback (§6) instantly. States: **closed → open → half-open** (probe a few
  requests before fully closing). Tune on *error rate*, not raw count.
- **Bulkheads** — isolate resource pools so one slow dependency can't drown the rest. Separate
  connection pools / thread pools / concurrency limits per downstream. The ship metaphor is literal:
  one flooded compartment shouldn't sink the boat.
- **Combine them:** breaker stops the bleeding, bulkhead contains the blast radius.

## 4. Backpressure & load shedding

Accepting work you can't finish is worse than rejecting it — queued work still consumes memory and
adds latency to requests that will time out anyway.

- **Bounded queues only.** An unbounded queue is a memory leak and a latency bomb. Full queue → reject.
- **Shed load early** — return 429/503 at the edge *before* doing expensive work, when over capacity.
- **Prioritize** — drop low-value traffic (health-check spam, retries) before user-facing requests.
- **Concurrency limits beat thread-per-request** — adaptive limiters (e.g. Netflix concurrency-limits,
  TCP-Vegas-style) self-tune to the real ceiling.

## 5. Idempotency

At-least-once delivery is the default reality of networks and queues — **assume every call can arrive
twice.** Make duplicates harmless.

- **Idempotency keys** — client sends a unique key per logical operation; server stores
  `(key → result)` and returns the stored result on replay. Standard for payments, order creation,
  any "exactly-once" user intent. (See [api-design.md](api-design.md) for the header contract.)
- **Natural idempotency** — prefer `SET balance = 100` over `ADD 50`; `UPSERT` over blind `INSERT`.
- **Dedup window** — key store needs a TTL long enough to cover all retries (hours, not seconds).
- This is what makes safe retries (§2) and idempotent consumers (§7) possible.

## 6. Graceful degradation & fallbacks

- **Degrade, don't collapse.** Recommendations down → show popular items. Personalization down →
  serve generic. A degraded feature beats a 500.
- **Fail fast vs. fail open/closed — decide per dependency:**

| Dependency | On failure | Why |
|---|---|---|
| Auth / authz | **fail closed** (deny) | Security default — never fail open |
| Feature flags | fail to **last-known / safe default** | Don't break the app over a flag service |
| Recommendations / ads | fail **open** (skip, serve core) | Non-critical; degrade silently |
| Payment | **fail fast** + surface error | Don't fake success; let the user retry |

- **Cache stale-but-serviceable data** as a fallback (§7 below). A 5-min-stale price beats no page.

## 7. Caching — the sharp edges

Caching is the highest-leverage and most bug-prone lever. "There are only two hard things…"

- **Layers:** client → CDN → app (in-mem / Redis) → DB buffer. Cache as close to the user as the
  data's freshness tolerance allows.
- **Pattern:** **cache-aside** (lazy, app owns the miss — default) vs. **write-through** (consistency
  at write cost). Write-behind only when you can tolerate loss.
- **Key design** — explicit, versioned (`v3:user:{id}:profile`); bump the version to invalidate a whole
  class without a flush.
- **TTL discipline** — every entry has a TTL; jitter TTLs so they don't expire in lockstep.
- **Stampede protection** — on a hot-key miss, thousands hit the DB at once. Use **single-flight /
  request coalescing** (one fetch, others wait) or a short per-key lock. Mandatory for hot keys.
- **Invalidation strategy is a design decision, not an afterthought** — TTL-only, event-driven bust,
  or version-bump. Pick one per cache and write it down. Stale-while-revalidate for read-heavy paths.

## 8. Async messaging & queues

- **At-least-once is the norm; "exactly-once" is mostly a myth** — brokers give effectively-once via
  dedup, but your consumer must still be idempotent (§5). Don't design as if delivery is unique.
- **Idempotent consumers** — process the same message twice → same result. Track processed message IDs.
- **Ordering isn't free** — global ordering kills throughput; use per-key/partition ordering (Kafka
  partition key) when you actually need it, and don't assume it otherwise.
- **DLQ / poison-message handling** — after N failed processing attempts, route to a dead-letter queue;
  alert on DLQ depth. A poison message must never block the partition forever.
- **Outbox pattern** — to publish an event *and* commit a DB write atomically, write the event to an
  `outbox` table in the same transaction; a relay polls and publishes. Kills the dual-write problem.
- **Monitor consumer lag** — lag (not queue depth alone) is the leading indicator that consumers can't
  keep up; alert before the backlog becomes unrecoverable → [devops.md](../platform/devops.md).

## 9. Anti-patterns

| Anti-pattern | Why it bites | Do instead |
|---|---|---|
| No timeout on a call | One stuck call exhausts the pool → total outage | §1 deadlines everywhere |
| Retry without jitter/budget | Retry storm; you DDoS yourself | §2 backoff + jitter + budget |
| Retrying a POST blindly | Duplicate charges/orders | §5 idempotency key |
| Unbounded queue "for safety" | Memory blow-up + latency bomb | §4 bounded + shed |
| Cache with no stampede guard | Hot-key miss melts the DB | §7 single-flight |
| Dual-write (DB + queue) | Partial failure → lost/ghost events | §8 outbox |
| Failing open on auth | Security hole under load | §6 fail closed |

## Definition of done

- [ ] Every outbound/network/DB call has an explicit timeout; request deadlines are propagated (context).
- [ ] Retries are limited to idempotent ops, bounded (≤3), use exponential backoff **+ jitter**, never fire on 4xx.
- [ ] A retry budget caps retry traffic; retries happen at exactly one layer.
- [ ] Critical dependencies sit behind a circuit breaker; resource pools are bulkheaded per downstream.
- [ ] Queues are bounded; the service sheds load (429/503) before saturation.
- [ ] State-changing public operations accept an idempotency key with a dedup store + TTL.
- [ ] Each dependency has a documented fallback and an explicit fail-fast / fail-open / fail-closed decision.
- [ ] Every cache entry has a TTL; hot keys have stampede protection; invalidation strategy is documented per cache.
- [ ] Message consumers are idempotent; DLQ + poison-message handling exist; consumer lag is alerted on.
- [ ] DB-write-plus-publish flows use the outbox pattern (no dual writes).
