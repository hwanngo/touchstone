---
name: api-design-standards
description: Use when designing or changing an HTTP/REST, GraphQL, or gRPC API — endpoints, request/response shapes, error formats, pagination, versioning, or the OpenAPI/proto schema — in a touchstone repo. Invoke before adding or modifying a public API surface.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# API Design

Full standard: **`standards/design/api-design.md`** in the touchstone repo. Load-bearing rules:

## Always
- **Contract-first**: OpenAPI 3.1 (REST) / protobuf (gRPC) / SDL (GraphQL) is the source of truth,
  committed and **linted in CI** (Spectral · buf lint + buf breaking). Generate clients; don't hand-write.
- **Errors**: RFC 9457 `application/problem+json`, consistent shape; never leak internals/stack traces.
- **Pagination**: cursor-based (not OFFSET); bound page sizes.
- **Idempotency keys** for unsafe retries; correct status-code discipline; content negotiation.

## Compatibility
- **Backward-compatible by default**; N-1 compatibility during rollout (pairs with DB expand/contract).
- **Versioning**: pick one scheme (URI is the default); deprecate with `Deprecation`/`Sunset` headers.
- gRPC: never reuse/renumber proto fields — additive only; gate with buf breaking.

## Don't get burned
- AuthN/AuthZ, rate limiting, input validation → `standards/practices/app-security.md`. Timeouts/retries → `standards/design/resilience.md`.
- GraphQL: depth/complexity limits, dataloader for N+1, no prod introspection _(scale-up)_.

## Done
Contract committed + linted (Spectral/buf) · errors are RFC 9457 · breaking changes gated (buf breaking, N-1 during rollout) · versioning + `Deprecation`/`Sunset` on removals. See `standards/design/api-design.md`.
