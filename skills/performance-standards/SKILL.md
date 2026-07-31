---
name: performance-standards
description: Use when setting performance budgets, profiling a hot path, writing load/stress tests, or optimizing latency/throughput in a touchstone repo — covers the measure-first discipline, p50/p95/p99 SLOs, per-stack profilers, k6 load testing, common bottlenecks, and CI regression gates. Invoke before optimizing anything (caching mechanics live in the resilience skill; frontend CWV/bundle in the react skill).
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Performance

Full standard: **`standards/practices/performance.md`** in the touchstone repo. Load-bearing rules:

## Always
- **Measure, don't guess** — profile production-shaped traffic before optimizing; keep a change only if a before/after number moved past noise. Optimize the dominant cost (Amdahl), not the function you assume is slow.
- **Budget as a number** — backend p50/p95/p99 latency **+ RPS/memory ceiling**; quote percentiles, never the mean (tails are what users feel). Frontend CWV + bundle defer to the react skill.
- **One profiler per stack** — Go `pprof`, Python **py-spy** + Scalene, Node/browser **clinic.js**/DevTools; sampling profilers are safe in prod, instrumenting ones distort timings. Read flamegraphs by width.
- **Load test with thresholds** — **k6** (escape hatch: Locust/Gatling) with budgets encoded as pass/fail thresholds; run load/stress in CI scheduled, soak tests for long-running services _(scale-up)_.

## Common bottlenecks (check before inventing a cause)
- **N+1 queries** are the #1 backend killer — catch via the EXPLAIN/query-count gate (database skill), not in prod.
- **Chatty I/O** (batch/parallelize), **serialization** CPU, **lock contention** (flat throughput as cores rise), **cold starts**, **allocation churn** (GC dominates the profile).
- **Caching** is the biggest lever — mechanics (TTL/jitter, stampede/single-flight, invalidation) live in the resilience skill; here: a cache without a measured **hit rate** is a guess.

## Done
Optimized changes carry a before/after profile number · each surface has a written budget (p50/p95/p99 + RPS/memory) · profiler wired per stack · k6 load/stress with pass/fail thresholds · no N+1 / chatty I/O · caches emit hit-rate metrics · a CI regression gate fails on significant latency/throughput/bundle regression, ratcheted · SLOs alerted on. See `standards/practices/performance.md`.
