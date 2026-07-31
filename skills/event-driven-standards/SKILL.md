---
name: event-driven-standards
description: "Use when designing message/queue/stream flows, producers or consumers, an outbox, or event schemas in a touchstone repo — picking a broker, delivery semantics, idempotency, ordering, DLQs, and schema evolution. Triggers on Kafka/SQS/SNS/RabbitMQ/Pulsar, consumer/producer code, outbox tables, CloudEvents/Avro/Protobuf schemas. Boundary: retry/backoff/DLQ *mechanics* live in resilience-standards; this owns the messaging architecture."
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Event-Driven & Messaging

Full standard: **`standards/design/event-driven.md`** in the touchstone repo. Layers on
[standards/design/architecture.md](../../standards/design/architecture.md) (sync vs async) and defers failure mechanics
to [standards/design/resilience.md](../../standards/design/resilience.md). Load-bearing rules:

## Always
- **Assume at-least-once delivery; make every consumer idempotent** — stable message id + dedup store (TTL), commit offsets *after* the effect. Exactly-once across a network is a myth; you get effectively-once via dedup.
- **Atomic write-and-publish via the transactional outbox** — insert the event in the same DB txn as the state change; a relay (or CDC/Debezium) publishes. Never dual-write DB-then-broker.
- **Pick the backbone by use case** — queue (SQS/RabbitMQ) for work, log/stream (Kafka/Pulsar) for replayable facts, pub-sub (SNS/EventBridge) for fan-out. Managed first.
- **Events are past-tense, immutable, versioned facts** in a CloudEvents envelope; default to event-carried state for cross-service decoupling.

## Don't get burned
- **Ordering is per partition key, never global** — key by `aggregate_id`; consumers must tolerate cross-key reordering (use event version/time, not arrival order).
- **A poison message must never block the partition** — bounded backoff + jitter, then DLQ after N. Alert on DLQ depth > 0 and replay once fixed (standards/design/resilience.md §7/§8).
- **Evolve schemas in a registry** (Avro/Protobuf) with backward+forward compat enforced in CI — additive-only, never renumber/retype; a breaking change is a new event version (standards/design/api-design.md).
- **Propagate `traceparent` through the message** and alert on consumer *lag*, not just queue depth (standards/platform/devops.md).

## Done
At-least-once + idempotent consumers (offset after effect) · outbox for atomic publish (no dual write) · backbone fits use case · per-key ordering · DLQ after N + alerted/replayable · schemas in a registry with compat in CI · CloudEvents, past-tense versioned events · trace + lag/DLQ observability · _(scale-up)_ multi-service flows are sagas with idempotent compensations. See `standards/design/event-driven.md`.
