# Event-Driven & Messaging Standards

The canonical home for async/messaging *architecture* — when to use events, which backbone, how to
shape and evolve them, and how producers/consumers stay correct under duplication and reordering.
The *failure-handling mechanics* (retries, backoff, DLQs, backpressure) live in
[resilience.md](resilience.md) — link there, don't restate. Siblings: [architecture.md](architecture.md)
(sync vs async coupling), [api-design.md](api-design.md) (contract evolution), [database.md](../platform/database.md)
(the outbox, CDC), and [observability.md](../platform/observability.md) (tracing, lag/DLQ alerting).

> **One law:** assume at-least-once delivery; make every consumer idempotent. Everything else here
> is a corollary.

---

## 1. When to go event-driven (and when not)

Events decouple *availability* at the cost of eventual consistency, ordering work, and debugging
across hops. That tax is real — don't pay it before you have to.

- **Start as a modular monolith; call in-process.** A synchronous function call is debuggable,
  transactional, and ordered for free. Reach for a broker only when a real force demands it (see
  [architecture.md](architecture.md) §3) — not because "event-driven is modern."
- **Go async when** you need to fan out one fact to many consumers, smooth spiky load, decouple
  deploy/scaling between teams, or survive a downstream being offline.
- **Stay sync when** the caller needs the result *now* to proceed (read-your-write, request/response),
  or the work is one consumer inside one module. Don't turn a function call into a queue for fashion.

| Signal | Lean sync (call) | Lean async (event) |
|---|---|---|
| Caller needs the result to continue | yes | no — fire and forget |
| One known consumer vs many/unknown | one | many / future |
| Work tolerates seconds–minutes of lag | no | yes |
| Spiky load you want to buffer | no | yes |

## 2. Pick the backbone by use case

One law per job: **commands/work → a queue; facts/events → a log or pub-sub.** Don't run Kafka to
move 100 jobs/day, and don't fake a replayable event log on top of a work queue.

| Need | Use | Why | Escape hatch |
|---|---|---|---|
| Distribute *work* (one consumer per message, ack/retry/DLQ) | **SQS** (managed) / **RabbitMQ** (self-host, routing) | Per-message ack, visibility timeout, built-in DLQ | Kafka only if you also need replay |
| Durable, replayable *event log* (many consumers, ordered per key, high throughput) | **Kafka** (default) / **Pulsar** (tiered storage, multi-tenant) | Retained partitions, consumer groups, replay from offset | NATS JetStream for lighter ops |
| Fan-out one event to N independent subscribers | **SNS** → SQS, or Kafka topic | Decouples producer from subscriber count | EventBridge for content routing/filtering |

- **Queue vs stream is the real fork.** A queue *consumes* a message (it's gone after ack); a stream
  *retains* it (consumers track their own offset and can replay). If you'll ever need to re-derive
  state or add a consumer that reads history, you need a stream.
- **Managed first.** Prefer SQS/SNS/EventBridge or a hosted Kafka (MSK/Confluent) over operating your
  own — a broker is undifferentiated infrastructure ([architecture.md](architecture.md) build-vs-buy).

## 3. Delivery semantics — at-least-once is the default reality

- **At-least-once is the norm.** Networks and brokers redeliver on ack loss; design for it. **Every
  message can arrive twice or out of order** — never assume unique delivery.
- **"Exactly-once" is mostly a myth across a network.** What brokers actually give is *effectively-once*
  via producer dedup + idempotent consumers. Kafka's exactly-once (idempotent producer + transactions)
  holds only *inside Kafka* (topic→topic); the moment you write to an external DB or call an API, you're
  back to at-least-once. Don't architect as if delivery is unique.
- **At-most-once** (fire-and-forget, no retry) is acceptable only for lossy telemetry where a dropped
  message is harmless. Default to at-least-once + idempotency for anything that matters.

| Guarantee | What you actually get | Use for |
|---|---|---|
| At-most-once | May drop, never duplicate | Metrics, best-effort signals |
| **At-least-once** *(default)* | May duplicate, never drop | Everything stateful — pair with §5 |
| Effectively-once | At-least-once + dedup makes duplicates harmless | The goal, achieved by §5, not by a flag |

## 4. Atomic write-and-publish — the transactional outbox

The **dual-write problem**: writing your DB *and* publishing to a broker as two separate steps means
a crash between them loses or ghosts an event. Two-phase commit across DB + broker is not the answer.

- **Transactional outbox (default).** In the *same DB transaction* as the state change, insert the
  event into an `outbox` table. A relay polls unsent rows and publishes, marking them sent — at-least-once
  by construction. Atomicity is local; no distributed transaction. Detail in [database.md](../platform/database.md).
- **CDC for the relay** _(scale-up)_ — instead of polling, tail the DB's write-ahead log with **Debezium**
  and publish committed rows to Kafka. Lower latency, no polling load; more moving parts to operate.

```sql
-- one transaction: the business write AND the event, committed together
BEGIN;
  UPDATE orders SET status = 'paid' WHERE id = $1;
  INSERT INTO outbox (id, aggregate_id, type, payload, created_at)
    VALUES (gen_random_uuid(), $1, 'order.paid', $2, now());  -- relay publishes, then marks sent
COMMIT;
```

## 5. Idempotent consumers — the load-bearing rule

Because delivery is at-least-once (§3), **processing a message twice must equal processing it once.**

- **Carry a stable message id.** Producer stamps a unique id (the event's own ULID, or a business
  idempotency key — see [api-design.md](api-design.md)). It must survive redelivery unchanged.
- **Dedup on the consumer side.** Before applying effects, check an `inbox`/processed-ids store inside
  the same transaction as the write; on a hit, ack and skip. TTL it long enough to cover all retries
  (hours, see [resilience.md](resilience.md) §5).
- **Prefer natural idempotency** — `SET status = 'paid'` over `INCREMENT attempts`; `UPSERT` over blind
  `INSERT`. The cheapest dedup is an operation that's safe to repeat.

```python
def handle(msg) -> None:
    with db.transaction():                      # dedup + effect commit atomically
        if db.execute(
            "INSERT INTO processed (msg_id) VALUES (%s) ON CONFLICT DO NOTHING",
            (msg.id,),
        ).rowcount == 0:
            return                              # already handled this id — ack and move on
        apply_effect(msg)                       # the real work, now exactly-once in effect
```

## 6. Ordering — per-key, never global

- **Global ordering kills throughput** (it forces a single partition / one consumer). Don't ask for it.
- **Order per entity with a partition key.** Key by `aggregate_id` (order id, user id) so all events
  for one entity land on one partition and are processed in order; unrelated entities stay parallel.
- **Design for reordering across keys.** Consumers must tolerate events arriving out of global order —
  use event timestamps/versions to reject stale updates, don't assume wall-clock arrival = causal order.

```yaml
# key by the aggregate so per-order events stay ordered; orders parallelise across partitions
produce:
  topic: orders
  key: "{{ order_id }}"     # same key -> same partition -> in-order, idempotent on the consumer
```

## 7. Poison messages, retries & DLQs

Failure *mechanics* live in [resilience.md](resilience.md) §2/§8 — this is the messaging contract.

- **Retry with bounded exponential backoff + jitter**, not a tight loop — a message that fails because
  a downstream is down should back off, not hammer it.
- **A poison message must never block the partition.** After N attempts, route it to a **Dead Letter
  Queue** and move on; one bad event can't wedge the consumer forever.
- **DLQ is an alert, not a graveyard.** Alarm on DLQ depth > 0; triage, fix, and **replay** from the DLQ
  once the bug is fixed. An unwatched DLQ is silent data loss.
- **Separate retryable from terminal failures** — a 503 downstream is worth retrying; a schema-invalid
  payload (§8) is terminal, send it straight to the DLQ.

## 8. Schema & contract evolution

An event is a published contract with more consumers than an API and no synchronous client to break
loudly — evolve it with the same discipline as [api-design.md](api-design.md).

- **Use a schema registry** (Confluent Schema Registry, AWS Glue) with **Avro** or **Protobuf** as the
  default wire format; reserve **JSON Schema** for human-facing/low-volume topics. The registry enforces
  compatibility *before* a producer can publish an incompatible schema.
- **Require backward+forward compatibility** (`FULL_TRANSITIVE`): new consumers read old events *and* old
  consumers read new ones. Producers and consumers deploy independently — neither may break the other.
- **Additive-only, like protobuf.** Add optional fields with defaults; **never** reuse/renumber a field
  tag, change a type, or repurpose a field's meaning. A breaking change is a *new event type/version*,
  not an edit — run both during the migration window.

| Change | Compatible? | How |
|---|---|---|
| Add an optional field (default) | yes | additive |
| Remove a field | only if it had a default | consumers tolerate absence |
| Rename / change type / renumber | **no** | new version, dual-publish, migrate |

## 9. Event design — state vs notification, versioned

- **Pick a flavour deliberately.** A **notification** (`order.paid {id}`) is small but forces consumers
  to call back for data (coupling, load). **Event-carried state transfer** (the full order snapshot) lets
  consumers act without a callback — default to this for cross-service decoupling; it trades payload size
  for autonomy.
- **Events are facts, past-tense, immutable.** Name them `OrderPaid`, not `PayOrder` (that's a command).
  An event states what *happened*; never mutate or retract a published one — emit a compensating event.
- **Wrap in a standard envelope — [CloudEvents](https://cloudevents.io).** A consistent metadata shell
  (id, source, type, time, **traceparent** for §11, schema ref) across every topic; the domain payload
  lives in `data`. Version the `type` (`com.acme.order.paid.v2`).

```yaml
specversion: "1.0"                      # CloudEvents envelope — uniform across all topics
id: 01HX8Z...                           # unique -> the consumer dedup key (§5)
source: /orders-service
type: com.acme.order.paid.v2            # past-tense, versioned event type
time: 2026-06-30T10:00:00Z
traceparent: 00-4bf92f...-01           # W3C trace context for cross-hop tracing (§11)
datacontenttype: application/avro
data: { order_id: "...", total: { amount: 4999, currency: USD }, items: [...] }
```

## 10. Consumer patterns & backpressure

- **Consumer groups for scale.** Partitions divide across a group so each is processed once; scale
  consumers up to the partition count (more consumers than partitions just idle). Pick the partition
  count for peak parallelism up front — it's painful to change later.
- **Commit offsets *after* the effect commits**, never before — committing first turns a crash into a
  lost message (silently at-most-once). At-least-once means: do the work, then ack.
- **Backpressure is pull + bounded concurrency.** A log consumer pulls at its own rate, so lag is the
  natural buffer; cap in-flight messages and prefetch so one slow consumer can't OOM. Backpressure
  patterns and bounded queues: [resilience.md](resilience.md) §4.

## 11. Observability of async flows

You can't `tail` a request across a broker — make async flows traceable by construction
([devops.md](../platform/devops.md)).

- **Propagate trace context through the message.** Inject W3C `traceparent` into the envelope (§9) on
  publish and continue the span on consume, so one trace spans producer → broker → consumer.
- **Alert on consumer lag, not just queue depth.** Lag (offset behind head) is the leading indicator
  that consumers can't keep up — page before the backlog is unrecoverable.
- **Alert on DLQ depth > 0 and on processing-failure rate.** A growing DLQ or redelivery rate is a
  silent incident. Emit per-message `event_id`/`trace_id` in logs for correlation.

## 12. Sagas — choreography vs orchestration _(scale-up)_

When one business transaction spans services, you can't use a distributed DB transaction — model it
as a **saga**: a sequence of local transactions, each with a **compensating action** to undo on failure.

- **Choreography** (services react to each other's events) for short, 2–3-step flows — no central
  coordinator, but the flow is implicit and hard to follow as it grows.
- **Orchestration** (a coordinator drives the steps, e.g. **Temporal**) for anything longer or with
  complex compensation — the flow is explicit and observable. Default here once a saga exceeds ~3 steps.
- **Design compensations up front** — no rollback, only forward-undo (refund, release inventory); each step and its compensation must be idempotent (§5).

## Anti-patterns

| Anti-pattern | Why it bites | Do instead |
|---|---|---|
| Dual-write (DB then publish) | Crash between → lost/ghost event | §4 outbox |
| Consumer assumes once-delivery | Double charge / double ship | §5 idempotency |
| Requiring global ordering | One partition, no throughput | §6 per-key |
| Poison message retried forever | Partition wedged, consumer stuck | §7 DLQ after N |
| Publishing without a schema registry | Silent breakage of downstream consumers | §8 registry + compat |
| Commit offset before processing | Crash → silent message loss | §10 ack after effect |

## Definition of done

- [ ] Async vs sync chosen per flow with a stated forcing reason; default stayed in-process until forced.
- [ ] Backbone fits the use case (queue for work, log/stream for replayable facts, pub-sub for fan-out); managed where possible.
- [ ] Delivery treated as at-least-once; no design relies on exactly-once across a network boundary.
- [ ] Write-and-publish is atomic via the transactional outbox (or CDC) — no dual writes.
- [ ] Every consumer is idempotent (stable message id + dedup store with TTL); offsets commit after the effect.
- [ ] Ordering is per partition key where needed, never global; consumers tolerate cross-key reordering.
- [ ] Retries use bounded backoff + jitter; poison messages go to a DLQ after N; DLQ depth is alerted and replayable.
- [ ] Event schemas live in a registry (Avro/Protobuf) with backward+forward compatibility enforced in CI.
- [ ] Events are past-tense, immutable, versioned, wrapped in a CloudEvents envelope; state-vs-notification chosen deliberately.
- [ ] Trace context propagates through messages; consumer lag, DLQ depth, and failure rate are alerted on.
- [ ] _(scale-up)_ Multi-service transactions modelled as sagas with idempotent compensating actions.
