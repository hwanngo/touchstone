# gRPC & Protobuf Standards

The deep home for gRPC and Protocol Buffers: schema design, field-number evolution, the four RPC
shapes, the status/rich-error model, deadlines, interceptors, and the security/transport edges.
General API-contract rules — versioning philosophy and the contract-in-CI discipline — live in
[./api-design.md](./api-design.md) (this is the gRPC home it points to from §8); failure mechanics
(timeouts, retries, breakers) in [./resilience.md](./resilience.md); streaming-as-messaging in
[./event-driven.md](./event-driven.md); authN/authZ and input handling in
[../practices/app-security.md](../practices/app-security.md). This doc owns only what is
gRPC/protobuf-specific.

> **One law:** the `.proto` is the contract and field numbers are forever — you may add to a
> message but you may never reuse, renumber, or repurpose a tag, because old bytes on the wire are
> decoded by number, not by name.

---

## 1. Schema-first — the `.proto` is the source of truth, buf is the toolchain

Hand-written stubs and a drifting `.proto` rot. **Commit the `.proto`, generate every stub, lint and
breaking-check in CI** (the contract-first rule from [./api-design.md](./api-design.md) §7 applied to
RPC).

- **`buf` is the default toolchain**, not raw `protoc`. It pins plugins, vendors deps, and gives you
  `buf lint`, `buf breaking`, and `buf generate` from two config files — no fragile `protoc -I…`
  invocations.
- **Configure two files and commit them:** `buf.yaml` (modules, lint + breaking rules) and
  `buf.gen.yaml` (codegen plugins/outputs). Codegen is reproducible from the repo, not a local script.
- **Publish to a schema registry — the Buf Schema Registry (BSR)** _(scale-up)_ — so consumers pull
  versioned, generated SDKs instead of vendoring raw `.proto`, and the breaking check runs across teams.

```yaml
# buf.yaml — the contract's guardrails
version: v2
modules:
  - path: proto
lint:
  use: [STANDARD]            # enforces package/file/field naming below
breaking:
  use: [FILE]               # the wire-compat ruleset; runs in CI against main
```

## 2. Field numbers & evolution — additive only, `reserved` forever

Backward-compat is a discipline enforced by `buf breaking`, not a hope. A field number is a permanent
identity on the wire.

| Change | Safe? | Rule |
|---|---|---|
| Add a new field with a new number | yes | additive; old readers ignore unknown tags |
| Add a new message / RPC | yes | additive |
| Remove a field | only with `reserved` | reserve the **number and the name** so neither is recycled |
| Renumber / change a field's type | **no** | breaks every existing encoded message — new field instead |
| Repurpose a field's meaning | **no** | semantic break with no compiler warning — the worst kind |

- **`reserve` retired numbers *and* names** the moment you delete a field, so a future edit can't
  recycle the tag and silently mis-decode old data.
- **Numbers 1–15 cost one byte; 16+ cost two.** Spend the low numbers on hot, frequently-set fields.
- **`19000–19999` are reserved by protobuf itself** — don't use them.

```protobuf
message Order {
  reserved 4, 7;                 // retired tags — never recycle
  reserved "legacy_status";      // and the names
  string id = 1;                 // low numbers for hot fields
  google.type.Money total = 2;
  google.protobuf.Timestamp created_at = 3;
}
```

## 3. Message & package design — proto3, wrappers, well-known types

- **proto3 semantics:** no `required` (it can never be safely removed), scalars have implicit
  zero-value defaults. Use the **`optional` keyword for explicit field presence** when "unset" must be
  distinguishable from "zero" (e.g. a nullable `int32`).
- **One dedicated request/response message per RPC** — `rpc CreateOrder(CreateOrderRequest) returns
  (CreateOrderResponse)`, even when a field would do. You can then add fields without changing the
  method signature; bare scalars and shared messages paint you into a corner.
- **Use the well-known and common types**, don't reinvent them: `google.protobuf.Timestamp` /
  `Duration` / `FieldMask` / `Struct` / `Any`, and `google.type.Money` / `Date`. A hand-rolled
  `int64 epoch_millis` loses the shared tooling and invites unit bugs.
- **Naming, enforced by `buf lint`:** package is lower-snake with a **version segment**
  (`acme.orders.v1`); messages/enums `PascalCase`; fields `lower_snake_case`; enums `SCREAMING_SNAKE`
  with a zero-value `*_UNSPECIFIED = 0`; one top-level concern per file.

## 4. The four RPC types — pick the simplest that fits

Default to **unary**. A stream is a long-lived HTTP/2 connection with real lifecycle and flow-control
cost; reach for one only when the data shape demands it.

| RPC type | Signature | Use when | Avoid for |
|---|---|---|---|
| **Unary** | `(Req) → Resp` | the overwhelming default — request/response | — |
| **Server-streaming** | `(Req) → stream Resp` | large/unbounded result sets, live feeds, progress | small fixed lists (just return them) |
| **Client-streaming** | `(stream Req) → Resp` | uploads, batch ingest, telemetry roll-up | anything needing a per-item reply |
| **Bidirectional** | `(stream Req) → stream Resp` | interactive/chatty sessions, multiplexed channels | a durable event bus → [./event-driven.md](./event-driven.md) |

- **A gRPC stream is not a message queue.** It has no durability, replay, or consumer groups; if you
  need those, publish to a broker ([./event-driven.md](./event-driven.md)), don't hold a bidi stream
  open as a bus.

## 5. Error model — canonical codes + `google.rpc.Status`, don't overload

gRPC has **16 canonical status codes**; they are the contract for *how a client should react*. Map
failures to the right code and never overload one.

| Code | Use for | Retryable? |
|---|---|---|
| `INVALID_ARGUMENT` / `FAILED_PRECONDITION` | bad input / wrong system state | no |
| `NOT_FOUND` / `ALREADY_EXISTS` | missing / duplicate resource | no |
| `UNAUTHENTICATED` / `PERMISSION_DENIED` | no identity / forbidden | no |
| `RESOURCE_EXHAUSTED` | quota / rate limit | yes, with backoff |
| `UNAVAILABLE` / `ABORTED` | transient down / contention | yes (§7) |
| `DEADLINE_EXCEEDED` | budget blown (§6) | maybe — only if idempotent |
| `INTERNAL` / `UNKNOWN` | our bug — never leak why | no |

- **Distinguish `INVALID_ARGUMENT` from `FAILED_PRECONDITION`:** the former means "fix the request and
  it'll never work as-is"; the latter "retrying the *same* request could succeed once state changes."
  Clients branch on the difference.
- **Attach machine-readable detail with `google.rpc.Status` rich errors** — typed
  `google.rpc.error_details` (`ErrorInfo`, `BadRequest`, `RetryInfo`, `QuotaFailure`) in the `details`
  list, mirroring the RFC 9457 `type` taxonomy in [./api-design.md](./api-design.md) §6. Clients read
  the structured detail, not a free-text string.
- **Never leak internals** — strip stack traces, SQL, hostnames from the message; log them server-side
  with a correlation id ([../practices/app-security.md](../practices/app-security.md)).

## 6. Deadlines & cancellation — mandatory, propagated

This is the single most important reliability rule and it is gRPC-native: every call carries a
deadline on the wire.

- **Every client call sets a deadline** — never an unbounded wait. An RPC with no deadline ties up a
  server handler until something else breaks ([./resilience.md](./resilience.md) §1).
- **Propagate the remaining deadline downstream, don't reset it.** A 2s budget that fans out to three
  calls shares that 2s — pass the inbound `context`/deadline into every outbound call (Go
  `context.Context`, Java `Context`, Python `grpc.aio` timeouts).
- **Honour cancellation.** When the deadline expires or the client hangs up, the server's context is
  cancelled — check it and abandon the work (stop DB queries, close streams) instead of computing a
  result nobody will read.

```go
// remaining inbound budget flows straight into the outbound call — no reset
ctx, cancel := context.WithTimeout(parentCtx, 2*time.Second)
defer cancel()
resp, err := downstream.GetItem(ctx, req) // cancels if the budget or the caller is gone
```

## 7. Retries & hedging — via service config, on retryable codes only

gRPC has a built-in, declarative retry/hedging policy in the **service config** (JSON) — prefer it
over hand-rolled loops, and obey the retry discipline in [./resilience.md](./resilience.md) §2.

- **`retryPolicy`** — bounded `maxAttempts`, exponential backoff, and an explicit
  `retryableStatusCodes` allowlist (`UNAVAILABLE`, often `RESOURCE_EXHAUSTED`). **Never retry
  `INVALID_ARGUMENT`/`NOT_FOUND`/`FAILED_PRECONDITION`** — they won't change.
- **`hedgingPolicy`** _(scale-up)_ — fire a second attempt after a delay without waiting for the first
  to fail, to cut tail latency. Only for **idempotent** RPCs; hedging a non-idempotent write
  double-executes it.
- **Retry at one layer only** ([./resilience.md](./resilience.md) §2) — client + proxy + server retries
  multiply into a storm.

```json
{ "methodConfig": [{
  "name": [{ "service": "acme.orders.v1.Orders" }],
  "retryPolicy": {
    "maxAttempts": 3, "initialBackoff": "0.1s", "maxBackoff": "1s",
    "backoffMultiplier": 2, "retryableStatusCodes": ["UNAVAILABLE"]
  }
}]}
```

## 8. Interceptors & metadata — cross-cutting concerns, off the handler

- **Put auth, logging, tracing, metrics, and retries in interceptors** (unary *and* stream), not in
  every handler. One auth interceptor that validates the token and injects identity beats N
  hand-copied checks.
- **Metadata is the header channel** — `lower-case` keys, `-bin` suffix for binary values. Carry the
  bearer/JWT in `authorization` and the `traceparent` so one trace spans client → server → downstream
  ([./event-driven.md](./event-driven.md) §11 is the async analog). **Don't smuggle large payloads
  through metadata**; it's for small, request-scoped context.

## 9. Security — mTLS by default, per-RPC auth in metadata

Transport and call-level identity are separate layers; gRPC wants both. AuthN/AuthZ policy and token
handling live in [../practices/app-security.md](../practices/app-security.md); this is the
gRPC-specific surface.

- **mTLS for service-to-service** — channel credentials authenticate *both* ends. Plaintext (`h2c`) is
  for localhost/tests only; never in prod.
- **Per-RPC credentials in metadata** — a bearer/JWT in `authorization`, validated in an auth
  interceptor (§8) that re-derives identity server-side. The channel proves *which service*; the call
  proves *which user*.
- **Authorize deny-by-default in the interceptor/handler, per object** — channel auth is not
  authorization (IDOR/BOLA, [../practices/app-security.md](../practices/app-security.md) §2).
- **Cap message size and set keepalives** — `MaxRecvMsgSize` bounds a malicious payload; tuned
  keepalive/`MAX_CONNECTION_AGE` recycles connections and reaps half-open ones.

## 10. Browser & REST edges — gRPC-Web, Connect, grpc-gateway

Browsers can't speak native gRPC (it needs HTTP/2 trailers the Fetch API doesn't expose) and some
clients want JSON/REST. Bridge deliberately.

| Need | Use | Notes |
|---|---|---|
| Call gRPC from a browser | **gRPC-Web** (via Envoy/proxy) or **Connect** (`connectrpc`) | Connect speaks gRPC, gRPC-Web, *and* a JSON-over-HTTP protocol — browser-native, no proxy _(scale-up)_ |
| Expose a REST/JSON facade | **grpc-gateway** | generates a reverse proxy from `google.api.http` annotations; one `.proto`, two surfaces |
| Public REST contract | keep the OpenAPI in sync | the gateway can emit OpenAPI; the `.proto` stays source of truth ([./api-design.md](./api-design.md)) |

- **Pick one bridge and document it** — running gRPC-Web *and* grpc-gateway *and* Connect on one
  service is three surfaces to secure and version.

## 11. Streaming pitfalls & flow control

- **Respect HTTP/2 flow control — it's automatic backpressure.** A slow reader stalls the sender via
  the connection window; don't defeat it by buffering unbounded in the app. Bounded concurrency, like
  [./resilience.md](./resilience.md) §4.
- **Always drain, close, and half-close streams.** A client that stops reading without cancelling
  leaks the server's handler and window; on client-streaming the server only replies after the client
  signals end-of-stream, so a client that never closes hangs the RPC until the deadline.
- **Bidi ordering is per-stream only.** Messages within one stream are ordered; across streams or
  reconnects they are not — carry a sequence/version if order matters and design for resume, rather
  than assuming the stream never drops.

## 12. Tooling, lint & CI gates

| Concern | Tool | Gate |
|---|---|---|
| Schema lint (naming, style) | **`buf lint`** | fail PR on lint errors |
| Breaking-change diff | **`buf breaking`** | fail PR on wire-incompatible diff vs `main` |
| Codegen | **`buf generate`** | stubs regenerated from `.proto`, never hand-edited |
| Registry / cross-team compat | **BSR** _(scale-up)_ | hosted breaking check + versioned SDKs |

```bash
buf lint                                          # naming + style
buf breaking --against '.git#branch=main'         # wire-compat gate — CI runs this
buf generate                                      # regenerate all stubs from the contract
```

- **Integration-test the service through generated stubs** — real RPCs over a real channel, asserting
  status codes, deadline behaviour, and auth paths, per
  [../practices/testing-strategy.md](../practices/testing-strategy.md).

---

## Definition of done

- [ ] `.proto` is committed and the source of truth; `buf.yaml` + `buf.gen.yaml` drive reproducible codegen.
- [ ] Field numbers are never reused/renumbered/repurposed; retired tags and names are `reserved`.
- [ ] proto3 with no `required`; explicit `optional` only where presence matters; well-known/common types used.
- [ ] Every RPC has its own request/response message; packages are versioned (`acme.x.v1`) and lint-clean.
- [ ] Streaming type matches the data shape; streams aren't used as a durable bus.
- [ ] Failures map to the correct canonical status code (no overloading); rich detail via `google.rpc.Status`; no internals leaked.
- [ ] Every call sets a deadline; the remaining budget is propagated and cancellation is honoured.
- [ ] Retries/hedging are declared in service config, restricted to retryable codes and idempotent RPCs, at one layer.
- [ ] Auth/logging/tracing live in interceptors; metadata carries only small request-scoped context.
- [ ] mTLS between services; per-RPC tokens validated server-side; authz is deny-by-default per object; message size capped.
- [ ] Browser/REST access goes through one documented bridge (gRPC-Web / Connect / grpc-gateway), kept in sync with the `.proto`.
- [ ] Streams drain, close, and handle half-close; flow control isn't defeated by unbounded buffering.
- [ ] CI runs `buf lint` and `buf breaking` against `main`; stubs are generated, not hand-written.

**Sources:** [Protocol Buffers / proto3](https://protobuf.dev/programming-guides/proto3/) · [buf](https://buf.build/docs) · [Buf Schema Registry](https://buf.build/docs/bsr/) · [gRPC status codes](https://grpc.io/docs/guides/status-codes/) · [google.rpc error model](https://cloud.google.com/apis/design/errors) · [gRPC deadlines](https://grpc.io/docs/guides/deadlines/) · [service config retry](https://grpc.io/docs/guides/retry/) · [Connect](https://connectrpc.com) · [grpc-gateway](https://grpc-ecosystem.github.io/grpc-gateway/)
