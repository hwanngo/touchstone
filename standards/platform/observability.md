# Observability Standards

How we make a running system explain itself: structured logs, metrics, and traces unified under
**OpenTelemetry**, plus the SLOs and alerts that turn telemetry into action. This is the **canonical
home** for instrumentation and telemetry; the infra that ships it (Prometheus/Grafana operators,
Kubernetes wiring) lives in [./devops.md](./devops.md) and the CI that gates it in
[./ci-cd.md](./ci-cd.md). SLO-driven rollbacks and error-budget *policy* are shared with
[../design/resilience.md](../design/resilience.md); never-log-this rules defer to
[../practices/data-privacy.md](../practices/data-privacy.md) and [../practices/security.md](../practices/security.md).

> **One law:** you can only operate what you can observe — instrument for the question you'll ask at
> 3am during an incident, not the dashboard you'll demo. If a signal can't drive an alert or answer
> "is the user hurting?", it's cost, not telemetry.
>
> **Scope:** items tagged _(scale-up)_ are for teams running real production traffic — adopt them as
> volume and bill grow. The three signals, structured logs, and SLOs apply to any deployed service.

---

## 1. The three signals + OpenTelemetry

The signals are complementary, not interchangeable — each answers a different question:

| Signal | Answers | Cardinality | Cost shape |
|---|---|---|---|
| **Metrics** | *Is* something wrong? (rates, latencies, saturation) | low (bounded labels) | cheap, constant |
| **Traces** | *Where* is it wrong? (which hop in the request) | high (per-request) | sampled |
| **Logs** | *Why* is it wrong? (the specific error + context) | unbounded | most expensive per GB |

- **Instrument once with OpenTelemetry (OTel), export over OTLP.** OTel is the CNCF vendor-neutral
  standard for all three signals — the SDK in your app, **OTLP** on the wire, and a backend you can
  swap without re-instrumenting. Don't wire vendor agents into application code; emit OTLP and let
  the Collector route. This is the single biggest lock-in decision you'll make — get it right once.
- **Run the OTel Collector as the single telemetry egress.** Apps export OTLP to a Collector
  (agent DaemonSet → gateway deployment); the Collector batches, enriches (k8s/resource attributes),
  redacts, samples, and fans out to backends. It is the **one place** to change a backend, add a
  PII scrubber, or turn on tail sampling — never the app fleet.
- **Auto-instrument first, add manual spans where they pay.** Language auto-instrumentation
  (`opentelemetry-instrument` for Python, the Java/Node agents, eBPF auto-instrumentation) gives you
  HTTP/DB/gRPC spans for free. Reserve **manual spans** for business-meaningful operations
  (`charge_card`, `render_invoice`) the framework can't name.

```python
# Manual span around a business operation; attributes are queryable, not log scraping
from opentelemetry import trace
tracer = trace.get_tracer("billing")

with tracer.start_as_current_span("charge_card") as span:
    span.set_attribute("payment.provider", provider)   # low-cardinality dimension
    span.set_attribute("payment.amount_cents", cents)
    result = gateway.charge(cents)                      # auto-instrumented HTTP child span
    span.set_attribute("payment.outcome", result.code)
```

- **Pick a stack and commit:** **Prometheus** (metrics) + **Grafana** (dashboards) + **Tempo**
  (traces) + **Loki** (logs) + **Alertmanager** — the OTLP-native, OSS default. Vendors
  (Datadog/Honeycomb/Grafana Cloud) are a drop-in OTLP backend swap, never a re-instrument. Escape
  hatch: a managed backend is the right call before you have a platform team to run the stack.

## 2. Structured logging

- **JSON, one event per line, machine-first.** Never `printf` prose. A log line is a queryable
  event with typed fields, emitted to **stdout** (the 12-factor contract — the platform ships it,
  the app never writes files or talks to a log backend).
- **Required fields on every line:** `timestamp` (ISO-8601 UTC), `level`, `service`, `message`,
  and **`trace_id`/`span_id`** so a log pivots straight to its trace. Thread a **correlation/request
  ID** from the edge through every hop.

```json
{"timestamp":"2026-06-30T14:22:01.882Z","level":"error","service":"checkout",
 "trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7",
 "message":"payment declined","order_id":"ord_8812","reason_code":"insufficient_funds"}
```

- **Levels mean something.** `ERROR` = a human must look (it pages or it's a bug); `WARN` =
  degraded/recovered, review in aggregate; `INFO` = lifecycle/state changes; `DEBUG` = off in prod,
  flippable per-request. If everything is `ERROR`, nothing is.
- **No PII or secrets in logs — ever.** No emails, tokens, full card/account numbers, or request
  bodies. Redact at the Collector as defense-in-depth, but the app must not emit them in the first
  place. Classification and field rules live in [../practices/data-privacy.md](../practices/data-privacy.md);
  secret-handling in [../practices/security.md](../practices/security.md).
- **Sample high-volume logs, keep all errors.** Drop 90% of identical success lines _(scale-up)_;
  never sample `ERROR`. Logs are the most expensive signal per GB — see §8.

## 3. Metrics: RED, USE, and cardinality discipline

- **Two complementary methods, by subject:**
  - **RED for every request-serving service** — **R**ate, **E**rrors, **D**uration. The minimum
    viable view of user-facing health, and the inputs to your SLOs (§5).
  - **USE for every resource** (CPU, memory, disk, pool, queue) — **U**tilization, **S**aturation,
    **E**rrors. Saturation (the *queue depth* / run-queue) is the leading indicator USE adds that
    RED misses.
- **Expose Prometheus/OpenMetrics; let it scrape.** Counters, gauges, and **histograms** on a
  `/metrics` endpoint (OpenMetrics is the IETF-track standard). Use OTel metrics → Prometheus
  exporter, or the Prometheus client directly — either way the wire format is OpenMetrics.
- **Latency is a histogram, never an average.** A mean hides the tail that hurts users. Emit
  `*_bucket` histograms and compute `histogram_quantile(0.99, …)` — and pick bucket boundaries
  around your SLO threshold so the p99 is *accurate* near the line that matters.

```promql
# RED: error ratio over a 5m window — the SLI behind the burn-rate alert (§5)
sum(rate(http_requests_total{service="checkout",code=~"5.."}[5m]))
  / sum(rate(http_requests_total{service="checkout"}[5m]))
```

- **Cardinality is the #1 cost and stability footgun.** A time series exists for **every unique
  label-value combination**; one `user_id` or `request_id` label can mint millions of series and
  OOM Prometheus. **Hard rules:**

  | Allowed as a label | Never a label |
  |---|---|
  | `service`, `route` (templated `/users/:id`), `method`, `status_class` (`5xx`) | `user_id`, `email`, `request_id`, `trace_id` |
  | `region`, `version`, low-cardinality `error_type` | raw URLs, full status codes split per value, unbounded enums |

  High-cardinality identifiers belong on a **trace or log** (§2, §4), not a metric label. Put a
  cardinality limit on the Collector/Prometheus and alert before it bites — see §8.

## 4. Distributed tracing

- **A trace is a tree of spans across services.** Each span is a timed operation with attributes;
  child spans nest under the request that caused them. Tracing is the only signal that shows *which
  hop* in a fan-out (see [../design/resilience.md](../design/resilience.md)) is slow or erroring.
- **Propagate context with W3C `traceparent` — no exceptions.** Every inbound and outbound call
  carries the `traceparent`/`tracestate` headers so the trace stays connected across service,
  queue, and language boundaries. A dropped header = an orphaned trace; auto-instrumentation
  handles this if you don't hand-roll HTTP clients.
- **Sample deliberately — head vs tail:**

  | Strategy | Where | Keeps | Use when |
  |---|---|---|---|
  | **Head** (probabilistic) | in the SDK | a fixed % decided at trace start | simple, low volume; cheap |
  | **Tail** _(scale-up)_ | OTel Collector | 100% of slow/error traces + a sample of the rest | you need every error trace but can't store every trace |

  **Tail sampling is the senior default at volume:** you decide *after* seeing the whole trace, so
  you keep the interesting ones (errors, p99 latency) and drop the boring 99%. Always **propagate to
  100%** even when you sample storage — a broken header can't be fixed downstream.
- **Link the signals: exemplars.** Attach trace exemplars to histograms so a Grafana latency spike
  is one click from the exact slow trace. The three signals are only worth their cost when they
  interconnect (§1).

## 5. SLOs, error budgets & burn-rate alerting

- **An SLO is a target on an SLI; the error budget is `1 − SLO`.** Pick **user-journey SLIs**
  (availability = success ratio, latency = % of requests under threshold) from your RED metrics —
  not CPU, not internal counters. Start with two or three that map to "is the user hurting?".

  ```yaml
  # OpenSLO — generate Prometheus recording/alert rules with Sloth or the OpenSLO toolchain
  apiVersion: openslo/v1
  kind: SLO
  metadata: { name: checkout-availability }
  spec:
    service: checkout
    objective: { target: 0.999 }            # 99.9% over the window → 0.1% error budget
    timeWindow: [{ duration: 28d, isRolling: true }]
    indicator:
      ratioMetric:
        good:  { metric: 'http_requests_total{service="checkout",code!~"5.."}' }
        total: { metric: 'http_requests_total{service="checkout"}' }
  ```

- **Alert on burn rate, multi-window multi-burn — not raw thresholds.** Page only when the budget
  is burning *fast enough to matter*. The Google SRE two-tier pattern: a **fast** window catches
  acute outages, a **slow** window catches steady erosion, and the short companion window stops a
  recovered blip from paging:

  | Severity | Burn rate | Long window | Short window | Budget gone in |
  |---|---|---|---|---|
  | **Page** | 14.4× | 1h | 5m | ~2 days → exhausted in hours |
  | **Page** | 6× | 6h | 30m | steady fast burn |
  | **Ticket** | 1× | 3d | 6h | slow erosion, no 3am page |

- **The error-budget *policy* is shared with [../design/resilience.md](../design/resilience.md).**
  Budget exhausted → freeze feature releases (P0/security excepted) until reliability work buys it
  back. This is the contract that lets [./devops.md](./devops.md) progressive delivery auto-roll-back
  on the same burn signal. Write the policy down; an SLO with no policy is a vanity number.

## 6. Dashboards

- **One golden-signal dashboard per service, auto-provisioned.** Top row = the RED/SLO view (rate,
  errors, p99, budget remaining); rows below = USE for its resources and dependencies. Dashboards
  are **code** — Grafana JSON / Grafonnet / Terraform in the repo, provisioned by the platform, not
  clicked together and lost.
- **Templated, not per-service forks.** A `$service`/`$region` variable drives one dashboard for
  the whole fleet; the golden-path scaffold ([./devops.md](./devops.md)) emits it pre-wired so a new
  service is observable on day one.
- **Built to answer, not to decorate.** Every panel earns its place by answering an on-call
  question; kill vanity gauges. Order top-down: user-facing symptom → service → resource → trace
  exemplar.

## 7. Alerting hygiene

- **Alert on symptoms, page on SLOs.** Page on **user-visible** burn-rate breaches (§5), never on a
  cause like high CPU or a full disk — those are *ticket*-worthy unless they're actually hurting
  users. A cause-based page is a false alarm waiting to fire.
- **Every page is actionable and carries a runbook.** If the responder can't *do* something, it's a
  dashboard, not an alert. The alert annotation links a version-controlled runbook (the same
  runbooks [./devops.md](./devops.md) requires) — symptom, diagnosis steps, mitigation, escalation.
- **Tier by urgency.** **Page** (wake someone) only for user-facing, time-critical, actionable
  breaches; **ticket** for slow burns and capacity; everything else is a dashboard. Route with
  Alertmanager (`severity` label → receiver), group and inhibit to kill storms.
- **Alert fatigue is an outage risk — measure it.** Track alerts-per-shift and the noisy-alert
  ratio; a pager that cries wolf gets ignored on the night it's real. Delete or tune any alert
  that's been actioned "no-op" twice. Defaults to silence-on-noise, not add-another-alert.

## 8. Cost & cardinality control _(scale-up)_

Observability bills scale with *cardinality and retention*, not traffic — and surprise the finance
team faster than compute. Control it at the Collector, the one choke point (§1):

- **Cap cardinality before it caps you.** Set series limits and a `limit`/`filter` processor on the
  Collector; **alert on `prometheus_tsdb_head_series`** trending up. A new high-cardinality label is
  the usual culprit behind a doubled bill or an OOM'd Prometheus.
- **Tier retention by signal.** Hot (queryable, 15–30d) vs cheap object-storage archive: **Mimir /
  Thanos** for metrics, **Loki/Tempo** already store in S3-class buckets. You almost never query raw
  traces older than a week — downsample metrics, drop the rest.
- **Drop and aggregate at the edge.** Tail-sample traces (§4), sample success logs (§2), and
  pre-aggregate or drop unused metrics in the Collector — cheaper than paying to ingest then ignore.

## 9. Continuous profiling _(scale-up)_

- **The fourth signal: profiling answers "which *line* burns the CPU/RAM?"** Once metrics and traces
  localize a regression to a service, continuous profiling (**Grafana Pyroscope**, or the emerging
  **OTel profiling** signal) gives flame graphs from production at low overhead — closing the loop
  from symptom → service → line of code without a repro.
- **Wire it through OTel and link to traces.** Same OTLP path, same `service`/`version` labels, so a
  slow trace span links to the flame graph of the code that ran during it.

## Definition of done

- [ ] App instrumented with **OpenTelemetry**, exporting **OTLP** to a **Collector** (no vendor
      agents in app code); auto-instrumentation on, manual spans for business operations
- [ ] Logs are **JSON to stdout** with required fields incl. `trace_id`/`span_id` + correlation ID;
      **no PII/secrets** (data-privacy/security); levels meaningful; errors never sampled away
- [ ] **RED** per service + **USE** per resource; latency is a **histogram** (p99), buckets near the
      SLO; exposed as Prometheus/OpenMetrics
- [ ] **Cardinality disciplined** — no `user_id`/`request_id`/unbounded labels; high-cardinality IDs
      live on traces/logs; series-limit alert wired
- [ ] Traces propagate **W3C `traceparent`** end-to-end at 100%; sampling is deliberate
      (**tail sampling** at the Collector _(scale-up)_); exemplars link metrics→traces
- [ ] **SLOs** defined on user-journey SLIs with an **error budget**; rules generated (Sloth/OpenSLO);
      a written **error-budget policy** shared with resilience
- [ ] Alerts are **multi-window multi-burn-rate** on SLOs — **page on symptoms**, ticket on slow burn;
      no raw-CPU pages; every page is actionable and links a **runbook**
- [ ] Dashboards are **code** (provisioned), one templated golden-signal board per service
- [ ] _(scale-up)_ Cost controlled at the Collector: cardinality cap + alert, **tiered retention**
      (Mimir/Thanos, S3-class), drop/sample at the edge
- [ ] _(scale-up)_ Continuous **profiling** (Pyroscope / OTel profiling) wired through OTel and
      linked to traces

**Sources:** [OpenTelemetry docs](https://opentelemetry.io/docs/) · [Google SRE Workbook — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/) · [Prometheus best practices](https://prometheus.io/docs/practices/naming/) · [OpenSLO](https://github.com/OpenSLO/OpenSLO)
