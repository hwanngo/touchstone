---
name: graphql-standards
description: "Use when designing or changing a GraphQL schema, resolvers, or client in a touchstone repo — SDL/nullability, the N+1/DataLoader footgun, Relay cursor pagination, typed errors, depth/cost/persisted-query limits, federation. Triggers on `.graphql`/`.gql` schema files, resolver code, Apollo/urql/Relay/Yoga/gqlgen/Pothos. Boundary: REST/gRPC and general contract/versioning rules → api-design-standards; this owns the graph."
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# GraphQL (design)

Full standard: **`standards/design/graphql.md`** in the touchstone repo. Defers general API-contract
rules to [standards/design/api-design.md](../../standards/design/api-design.md), failure mechanics to
[standards/design/resilience.md](../../standards/design/resilience.md), and authN/authZ to
[standards/practices/app-security.md](../../standards/practices/app-security.md). Load-bearing rules:

## Always
- **SDL is the source of truth** — commit the `.graphql`, generate resolver + client types from it, lint and schema-diff in CI. Code-first only if it emits a CI-diffed SDL snapshot.
- **Wrap every per-entity fetch in a request-scoped DataLoader** — the N+1 footgun; one loader instance per request (never global), batch function returns one result per key in key order.
- **Nullability is deliberate** — network/3rd-party-backed fields stay nullable (a `!` field that errors nulls its whole parent); separate `input` types from output types; mutations take one `input`, return a payload.
- **Relay cursor connections** for every growable list; opaque cursors, clamp/bound `first` server-side.

## Don't get burned
- **Bound the blast radius before exposing the endpoint** — depth limit + query cost/complexity analysis, introspection off in prod, persisted/trusted queries on public graphs _(scale-up)_; use `graphql-armor`/gateway plugins, not hand-rolled.
- **Field-level authz is deny-by-default, enforced in the resolver per object** (IDOR/BOLA) — not the gateway, not UI hiding (see standards/practices/app-security.md).
- **Model expected failures as typed data** (union/payload + `extensions.code`) and return partial results; reserve top-level `errors[]` for the unexpected; never leak stack traces/SQL.
- **Evolve additively — no `/v2` graph;** remove fields only via `@deprecated` + zero usage. Gate breaking diffs with GraphQL Inspector / `rover check`.

## Done
SDL committed + typed codegen · DataLoader per request (no N+1) · deliberate nullability · Relay pagination with bounded `first` · typed errors + partial results · depth/cost limits + introspection off + field authz · additive evolution via `@deprecated` · CI lints (GraphQL-ESLint) + breaking-diff gate · _(scale-up)_ Apollo Federation v2 subgraphs with composition checks. See `standards/design/graphql.md`.
