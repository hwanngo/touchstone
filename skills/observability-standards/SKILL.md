---
name: observability-standards
description: Use when adding instrumentation, OpenTelemetry/OTLP/Collector config, metrics or structured logging, distributed tracing, dashboards, alert rules, or SLOs/error budgets in a touchstone repo — covers the three signals, cardinality discipline, and burn-rate alerting. Invoke before wiring telemetry or paging. NOT the deploy-time infra (Prometheus/Grafana operators, k8s) — that's devops-standards.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Observability Standards

Full standard: **`standards/platform/observability.md`** in the touchstone repo (canonical home for
telemetry; infra wiring lives in `standards/platform/devops.md`). This skill inlines the
load-bearing rules so it stays useful standalone in `~/.claude/skills/`:

## Always
- **Instrument with OpenTelemetry, export OTLP to a Collector** — no vendor agents in app code. The
  Collector is the one place to batch, redact, sample, and swap backends. Auto-instrument first; add
  manual spans only for business operations.
- **Logs are JSON to stdout** with `timestamp`/`level`/`service`/`message` + **`trace_id`/`span_id`**
  and a correlation ID. **No PII or secrets, ever** (defer to data-privacy/security).
- **RED per service** (rate/errors/duration) + **USE per resource**; latency is a **histogram** (p99),
  never an average.
- **Page on SLO burn-rate, not raw CPU.** Multi-window multi-burn-rate; every page is actionable and
  links a runbook.

## Don't get burned
- **Cardinality is the #1 cost/stability footgun.** Never put `user_id`, `email`, `request_id`,
  `trace_id`, or raw URLs in a metric label — each unique combo is a new time series and will OOM
  Prometheus. High-cardinality IDs go on **traces/logs**, not metrics.
- **Propagate W3C `traceparent` at 100%** even when you sample storage — a dropped header orphans the
  trace and can't be fixed downstream. Prefer **tail sampling** at the Collector at volume.
- **An SLO with no error-budget policy is a vanity number** — write the freeze-on-exhaustion policy
  (shared with `standards/design/resilience.md`).
- **Symptom-based alerts only.** A cause-based page (full disk, high CPU) that isn't hurting users is
  a false alarm; make it a ticket.

## Done
OTel→OTLP→Collector · JSON logs w/ trace_id, no PII · RED+USE, histogram p99 · cardinality disciplined · `traceparent` 100% + deliberate sampling · SLOs + error-budget policy · multi-window burn-rate pages w/ runbooks · dashboards as code. See `standards/platform/observability.md`.
