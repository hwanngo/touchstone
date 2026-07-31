---
name: grpc-standards
description: "Use when designing or changing a gRPC service or Protocol Buffers schema in a touchstone repo — `.proto` field-numbering/evolution, the four RPC types, the status-code + google.rpc.Status error model, deadlines/cancellation, retries via service config, interceptors/metadata, mTLS, and the gRPC-Web/grpc-gateway browser edge. Triggers on `.proto` files, `buf.yaml`/`buf.gen.yaml`, gRPC service/stub code, Connect/grpc-gateway. Boundary: REST → api-design-standards, GraphQL → graphql-standards, general contract/versioning rules → api-design-standards; this owns the wire."
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# gRPC & Protobuf (design)

Full standard: **`standards/design/grpc.md`** in the touchstone repo. Defers general API-contract and
versioning rules to [standards/design/api-design.md](../../standards/design/api-design.md), failure mechanics
(timeouts, retries, breakers) to [standards/design/resilience.md](../../standards/design/resilience.md),
streaming-as-messaging to [standards/design/event-driven.md](../../standards/design/event-driven.md), and authN/authZ
to [standards/practices/app-security.md](../../standards/practices/app-security.md). Load-bearing rules:

## Always
- **The `.proto` is the contract — field numbers are forever.** Add fields freely; never reuse, renumber, or repurpose a tag. `reserve` retired numbers **and** names so they can't be recycled.
- **`buf` is the toolchain** — commit `buf.yaml` + `buf.gen.yaml`; CI runs `buf lint` and `buf breaking --against main`; stubs are `buf generate`d, never hand-edited. BSR for cross-team SDKs _(scale-up)_.
- **Every call sets a deadline and propagates the remaining budget** — no unbounded waits; pass the inbound context into every outbound call; honour cancellation when it fires.
- **proto3, one dedicated request/response message per RPC**; versioned packages (`acme.x.v1`); well-known types (`Timestamp`, `Money`, `FieldMask`) over hand-rolled scalars; `optional` only where presence matters.

## Don't get burned
- **Map failures to the right canonical status code — don't overload one.** `INVALID_ARGUMENT` (fix the request) vs `FAILED_PRECONDITION` (retry once state changes); attach typed detail via `google.rpc.Status`; never leak stack traces/SQL.
- **Retry only retryable codes (`UNAVAILABLE`) on idempotent RPCs, via service-config `retryPolicy`, at one layer** — never `INVALID_ARGUMENT`/`NOT_FOUND`; hedge only idempotent calls.
- **mTLS between services + per-RPC token validated server-side in an auth interceptor; authz deny-by-default per object** (channel auth is not authorization — IDOR/BOLA). Cap message size; set keepalives.
- **A gRPC stream is not a durable queue** — no replay/consumer groups; publish to a broker instead. Drain/close streams, handle half-close, and don't defeat HTTP/2 flow control with unbounded buffering.
- **Browsers can't speak native gRPC** — bridge via gRPC-Web/Connect or expose REST with grpc-gateway from `google.api.http` annotations; pick one and keep it in sync with the `.proto`.

## Done
`.proto` committed + `buf generate`d stubs · numbers never reused, retired tags `reserved` · per-RPC request/response messages + versioned packages · correct status codes + `google.rpc.Status` detail · deadlines set + propagated + cancellation honoured · service-config retries on retryable/idempotent only · interceptors for auth/logging/tracing · mTLS + per-RPC authz deny-by-default · streams drained/closed, flow control respected · one documented browser/REST bridge · CI runs `buf lint` + `buf breaking`. See `standards/design/grpc.md`.
