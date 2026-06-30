# Performance Standards

Cross-cutting performance discipline: how to set budgets, find the real bottleneck, prove a change
helped, and stop regressions at the gate. This doc owns the **method and the budgets**; the
mechanics live in siblings and are linked, not restated — caching/timeouts/backpressure in
[resilience.md](../design/resilience.md), SLOs + observability in [observability.md](../platform/observability.md),
query/index/N+1 detail in [database.md](../platform/database.md), frontend Core Web Vitals + bundle
budgets in [react.md](../frameworks/react.md), and load-test ownership/cadence in
[testing-strategy.md](testing-strategy.md). Per-stack profilers point at the language docs.

> **One law:** measure, don't guess. A profile beats an opinion; an optimization without a
> before/after number is a guess that costs complexity and buys nothing.

---

## 1. The discipline — measure before you optimize

Premature optimization burns time and adds complexity to code that isn't hot. Work the loop:

1. **Set a budget first** (§2) — without a target, "faster" is unfalsifiable and never ends.
2. **Measure the real workload** — profile production-shaped traffic, not a microbenchmark of the
   function you *assume* is slow. The bottleneck is almost never where you'd guess.
3. **Profile to find the hot path** (§3) — let the flamegraph, not intuition, pick the target.
4. **Change one thing, re-measure** — keep the win only if the number moved past noise.
5. **Gate it** (§7) — lock the gain in CI so the next commit can't quietly give it back.

- **Optimize the dominant cost.** Amdahl's law: shaving 50% off code that's 5% of latency buys
  2.5%. Find the 80% first.
- **Tails matter more than means.** Users feel p99, not the average; one slow dependency in a
  fan-out drags the whole request. Track percentiles, never just the mean (§2).
- **Algorithmic beats micro.** An O(n²)→O(n log n) fix dwarfs any constant-factor hand-tuning;
  reach for the data structure before the bit-twiddle.
- **Keep the slow path observable.** You can't profile what you can't see — instrument spans and
  RED/USE metrics ([devops.md](../platform/devops.md)) so the hot path is visible in prod, not only
  reproducible on your laptop.

## 2. Performance budgets — make "fast enough" a number

A budget is a threshold a CI gate (§7) or alert can enforce. Set one per surface and write it down.

**Backend latency (SLOs).** Quote percentiles, never the mean — define and alert on these in
[devops.md](../platform/devops.md):

| Percentile | Reads "fast enough" when | Use it for |
|---|---|---|
| **p50** | the median request is snappy | day-to-day UX baseline |
| **p95** | the slow tail stays bounded | the SLO most teams gate on |
| **p99** | the worst 1% is still survivable | fan-out / capacity headroom |

- **Budget the dependency chain, not just the endpoint.** A 200ms p95 endpoint that fans out to
  three 150ms calls is over budget — propagate deadlines ([resilience.md](../design/resilience.md) §1).
- **Throughput + saturation:** state target **RPS** and the **memory/CPU ceiling** at that load
  (e.g. "2k RPS at < 70% CPU, < 512 MiB RSS/pod"). A latency budget with no throughput target
  passes right up until it falls over.

**Frontend.** Hold a **Core Web Vitals** budget (LCP/INP/CLS, 75th percentile) and a **bundle-size**
budget — thresholds, tooling (`size-limit`, Lighthouse-CI), and image/lazy-load rules live in
[react.md](../frameworks/react.md) §11–12. Don't restate them here; gate them there.

## 3. Profiling — one profiler per stack

Profile, don't print-timestamp. Pick CPU vs. allocation vs. wall-clock deliberately — they answer
different questions. Defaults per stack (deep flags live in the language docs):

| Stack | CPU / wall | Memory / allocation | Notes |
|---|---|---|---|
| **Go** | `pprof` (`runtime/pprof`, `net/http/pprof`) | `pprof` heap + `-benchmem` | built-in; see [golang.md](../languages/golang.md) |
| **Python** | **py-spy** (sampling, no code change) | **Scalene** / `tracemalloc` | py-spy attaches to a live PID; see [python.md](../languages/python.md) |
| **Node / browser** | `--prof` / Chrome DevTools, **clinic.js** | heap snapshots | browser runtime perf → [react.md](../frameworks/react.md) §7 |

- **Sampling over instrumenting** for live systems — a sampling profiler (py-spy, pprof) has
  near-zero overhead and is safe to attach in staging/prod; instrumenting profilers distort the
  very timings you're measuring.
- **Read flamegraphs by width, not height** — width is time spent; the widest plateau is your
  target. Height is just call depth.
- **Continuous profiling** _(scale-up)_ — **Pyroscope** or **Parca** (eBPF) for always-on prod
  profiles, so you debug yesterday's incident from a stored flamegraph instead of trying to
  reproduce it.

## 4. Load & stress testing — prove it before prod does

Functional tests say it works; load tests say it works *at traffic*. Run them against an isolated,
production-shaped environment — never shared staging unless the traffic is synthetic and flagged
(see [testing-strategy.md](testing-strategy.md) §7).

- **Tool: [k6](https://k6.io)** (scriptable in JS, CI-native, thresholds as pass/fail). Escape
  hatch: **Locust** when the team lives in Python, **Gatling** on the JVM. Pick one per repo.
- **Run the right shape of test** — they fail in different ways:

| Test | Question it answers | Profile |
|---|---|---|
| **Load** | "does it hold the SLO at expected peak?" | steady target RPS for ~10 min |
| **Stress** | "where does it break, and how?" | ramp past peak until errors/latency spike |
| **Spike** | "does a traffic surge recover gracefully?" | instant jump, then drop |
| **Soak** _(scale-up)_ | "does it leak or degrade over hours?" | hold moderate load 2–24 h |

- **Soak tests catch what load tests miss** — memory leaks, FD/connection-pool exhaustion, cache
  unbounded growth only show up under duration, not peak.
- **Encode the budget as a threshold** so the run self-judges:

```js
// k6: the run FAILS (non-zero exit) when the budget is breached
export const options = {
  thresholds: {
    http_req_duration: ['p(95)<200', 'p(99)<500'], // ms — your §2 SLO
    http_req_failed: ['rate<0.01'],                 // < 1% errors
  },
};
```

- **Where in CI:** a quick smoke load test can gate PRs; the full load/stress/soak suite runs
  **scheduled** (nightly/pre-release) _(scale-up)_, not on every commit — it's too slow and noisy
  for the inner loop.

## 5. Common bottlenecks — where the time actually goes

Most latency is one of a handful of usual suspects. Check these before inventing a novel cause:

| Bottleneck | Tell | Fix (and where it's owned) |
|---|---|---|
| **N+1 queries** | query count scales with row count | batch / `JOIN` / eager-load — [database.md](../platform/database.md) §3 |
| **Chatty I/O** | many small sequential round-trips | batch calls, parallelize fan-out, paginate |
| **Serialization** | CPU hot in JSON/encode/decode | stream large payloads; a faster codec; don't over-fetch fields |
| **Lock contention** | throughput flat as you add cores | shrink the critical section; sharded/lock-free structures |
| **Cold starts** | first request after idle is slow | provisioned concurrency / warm pool; trim init work + deps |
| **Allocation churn** | GC time dominates the profile | reuse buffers / pools; cut per-request allocations |

- **N+1 is the #1 backend latency killer** — a loop issuing one query per row. Catch it in PR
  review via the `EXPLAIN`/query-count gate in [database.md](../platform/database.md), not in prod.
- **Concurrency is not parallelism, and neither is free** — added goroutines/threads add
  coordination cost; profile (§3) before assuming more workers helps.
- **Connection-pool exhaustion masquerades as "the DB is slow."** When every worker blocks waiting
  to acquire a connection, latency spikes with no slow query in sight — size and time-box the pool
  ([resilience.md](../design/resilience.md) §1, [database.md](../platform/database.md)).

## 6. Caching — the highest-leverage lever, deferred

Caching is the biggest single performance win and the most bug-prone. The full treatment —
cache-aside vs. write-through, TTL + jitter discipline, **stampede / single-flight** protection,
and per-cache invalidation strategy — lives in [resilience.md](../design/resilience.md) §7. The
performance rule here: **a cache without a measured hit rate is a guess.** Emit hit/miss metrics
([devops.md](../platform/devops.md)), set a target hit rate, and treat a cold or thrashing cache as
a budget breach — don't add a cache and assume it helped.

## 7. Regression gates — lock the win in CI

An optimization with no gate rots. Make the budget (§2) a build-breaker so the next commit can't
silently undo it.

- **Latency/throughput:** the k6 thresholds (§4) are the gate — the load job fails on a breached
  p95/p99 or error rate. Run it scheduled; alert on the SLO continuously in
  [devops.md](../platform/devops.md).
- **Microbenchmarks:** for hot library code, gate on a benchmark delta — **benchstat** (Go),
  **pytest-benchmark** (Python), **hyperfine** for CLI wall-clock. **Fail on statistically
  significant regression**, not on a single noisy sample.
- **Frontend size:** `size-limit` already fails CI on bundle bloat ([react.md](../frameworks/react.md) §12).
- **Ratchet, don't just floor.** Set the budget at the current number and tighten it as you
  improve — same pattern as the coverage ratchet in [testing-strategy.md](testing-strategy.md) §6.
- **Capacity headroom** _(scale-up)_ — track the load at which the saturation budget (§2) breaks
  and alert *before* you hit it, so scaling is planned, not reactive.

## Definition of done

- [ ] Every optimized change has a **before/after number** from a profile, not a guess
- [ ] Each surface has a written **budget**: backend p50/p95/p99 + RPS/memory ceiling; frontend CWV + bundle (defer to [react.md](../frameworks/react.md))
- [ ] The right **profiler** is wired per stack (pprof / py-spy+Scalene / clinic.js); sampling in prod
- [ ] **Load + stress** tests (k6) exist for critical paths with **thresholds as pass/fail**; soak test for long-running services _(scale-up)_
- [ ] Known bottlenecks checked: **no N+1** (EXPLAIN gate), no chatty I/O, lock contention profiled
- [ ] Caches emit **hit-rate metrics** with a target; mechanics follow [resilience.md](../design/resilience.md) §7
- [ ] A CI **regression gate** fails the build on a significant latency/throughput/bundle regression, ratcheted
- [ ] Latency SLOs and saturation are **alerted on** continuously ([devops.md](../platform/devops.md))
