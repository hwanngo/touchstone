# Caching (local notes)

Cache expensive Django queryset results behind a short TTL before reaching for a dedicated
caching layer, and invalidate on write rather than on a timer where correctness matters more
than latency.

Prefer per-view caching over a blanket site-wide cache — it keeps invalidation scoped to the
data that actually changed.
