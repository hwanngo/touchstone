# GraphQL Standards

The deep home for GraphQL: schema design, the N+1 footgun, pagination, typed errors, and the
security limits a public graph needs. General API-contract rules — status/transport semantics,
versioning philosophy, the contract-in-CI discipline — live in [api-design.md](./api-design.md);
failure mechanics (timeouts, retries, caching edges) in [./resilience.md](./resilience.md); authN/authZ
and input handling in [../practices/app-security.md](../practices/app-security.md). This doc owns
only what is GraphQL-specific.

> **One law:** the schema is your public contract and a single attacker-shaped query can fan out to
> thousands of resolver calls — design the types deliberately and bound the blast radius before you
> expose the endpoint.

---

## 1. Schema-first — SDL is the source of truth

Hand-written resolvers and a drifting schema rot. **Commit the SDL, generate the types, check it in
CI** (the contract-first rule from [api-design.md](./api-design.md) §7 applied to graphs).

- **Author SDL, don't infer it from code.** A schema-first `.graphql` file is the reviewable
  artifact; code-first (Nexus/Pothos/`graphql-ruby`) is acceptable *only if* it emits a committed
  SDL snapshot that CI diffs. The generated SDL is what reviewers and `schema-check` read.
- **One schema, many resolvers.** Keep the type system in `schema/*.graphql`; resolvers map 1:1 to
  fields. Don't let resolver files invent fields the SDL doesn't declare.
- **Lint and diff on every PR** — see §12.

## 2. Nullability discipline — non-null by default is a trap

GraphQL is null-by-default, and that is the right default. **A non-null (`!`) field that errors
nulls its entire parent object** — the error bubbles up to the nearest nullable ancestor, so one
flaky downstream can blank a whole response.

| Field | Default | When `!` is safe |
|---|---|---|
| Scalars from your own DB row (`id`, `createdAt`) | `String!` | the column is `NOT NULL` and always present |
| A field backed by a network/3rd-party call | **nullable** | never — a timeout shouldn't null the parent |
| List itself | `[T!]` (nullable list, non-null items) | items can't be null; the list can be empty/absent |
| Required list of required items | `[T!]!` | only when both invariants truly hold |

- **Make outputs non-null sparingly; make inputs non-null deliberately.** Tightening an input arg to
  non-null is a breaking change (§10); loosening an output from `!` to nullable is too.
- **Prefer a nullable field + a typed error (§6) over a non-null field that throws.**

## 3. Naming & type modelling

- **Conventions, enforced by lint:** `PascalCase` types, `camelCase` fields/args, `SCREAMING_SNAKE`
  enum values, mutations are `verbNoun` (`createOrder`, not `orderCreate` — pick one and lint it).
- **Separate input and output types.** Never reuse an object type as an input; declare `input
  CreateOrderInput`. Mutations take **one** input arg (`input:`) and return a **payload** type
  (`CreateOrderPayload { order, userErrors }`) so fields can be added without breaking the call.
- **Avoid over-generic types.** No `JSON` scalar grab-bags, no `type Entity { type, data }`. Model
  real fields; a typed schema is the entire point. Use custom scalars (`DateTime`, `URL`, `UUID`)
  with serialize/parse validation instead of raw `String`.
- **Design the graph, not your tables.** Expose domain relationships (`order.customer`), not foreign
  keys (`customerId` only). Nodes should be reachable by `id` via the Relay `Node` interface.

## 4. The N+1 problem → DataLoader (the headline footgun)

A naive resolver that fetches per-item turns one query into one-per-row. `posts → author` over 100
posts = 1 + 100 DB calls. **This is the defining GraphQL performance bug; batch it.**

- **Wrap every per-entity fetch in a DataLoader** (`graphql/dataloader`, or the framework's
  equivalent). It coalesces the keys requested within one tick into a single batched call and caches
  by key for the request.
- **One DataLoader instance per request, never global** — a process-wide loader leaks one user's
  data into another's cache. Construct loaders in the per-request context.
- **The batch function must preserve order and arity:** return one result per input key, in key
  order, `null` for misses. A length/order mismatch silently maps the wrong row to the wrong field.

```ts
// per-request context — new loaders each request
const userLoader = new DataLoader<string, User | null>(async (ids) => {
  const rows = await db.user.findMany({ where: { id: { in: [...ids] } } });
  const byId = new Map(rows.map((r) => [r.id, r]));
  return ids.map((id) => byId.get(id) ?? null); // one entry per key, in order
});
// resolver: Post.author -> ctx.loaders.user.load(post.authorId)  // batched, not N+1
```

- **Pair with caching for hot reference data** (request-scoped loader cache → process/Redis cache for
  cross-request reuse), respecting the stampede and TTL rules in [./resilience.md](./resilience.md) §7.

## 5. Pagination — Relay cursor connections

Standardize on **Relay Cursor Connections** for every list that can grow. It's the de-facto spec,
plays well with clients (Relay/Apollo), and gives stable, opaque cursors — the cursor pagination
[api-design.md](./api-design.md) §4 mandates, in GraphQL shape.

```graphql
type Query { orders(first: Int!, after: String): OrderConnection! }
type OrderConnection { edges: [OrderEdge!]!, pageInfo: PageInfo! }
type OrderEdge { node: Order!, cursor: String! }
type PageInfo { hasNextPage: Boolean!, hasPreviousPage: Boolean!, endCursor: String, startCursor: String }
```

- **Cursors are opaque** (base64 over a stable sort key) — clients must not parse them. No
  offset/`page` args; offset drifts on insert and is O(n) deep.
- **Bound `first`/`last`.** Reject or clamp page sizes server-side (e.g. max 100); an unbounded
  `first: 1000000` is a denial-of-service vector (§7).
- **Total counts are optional and expensive** — expose `totalCount` only when cheap; don't promise it.

## 6. Errors — typed results over throwing

GraphQL returns `200` with a top-level `errors[]`; a thrown resolver nulls the field (§2) and leaks a
generic message. **Model expected, recoverable failures as data; reserve `errors[]` for the
unexpected.**

- **Use a union or a result/payload type for domain errors** so clients handle them exhaustively and
  the happy path stays non-null:

```graphql
union OrderResult = Order | OrderNotFound | InsufficientFunds
type Mutation { payOrder(input: PayOrderInput!): OrderResult! }
```

- **Partial results are a feature.** When one field of a multi-field query fails, return the rest plus
  a path-scoped entry in `errors[]` — don't fail the whole operation.
- **Put machine-routable detail in `error.extensions.code`** (`UNAUTHENTICATED`, `FORBIDDEN`,
  `BAD_USER_INPUT`, …), mirroring the `type` taxonomy in [api-design.md](./api-design.md) §6. Clients
  branch on `code`, not on message strings.
- **Never leak internals.** Strip stack traces, SQL, and resolver paths in production; log them
  server-side with a correlation id ([../practices/app-security.md](../practices/app-security.md)).

## 7. Security — bound the graph, deny by default

A graph is a query language you handed to the internet; an unbounded one is a DoS and data-exfil
surface. Layer these controls — none is sufficient alone. AuthN/session/JWT rules live in
[../practices/app-security.md](../practices/app-security.md); this is the GraphQL-specific surface.

| Risk | Control |
|---|---|
| Deeply nested / cyclic query | **Depth limit** (e.g. ≤ 10) — reject before execution |
| Expensive fan-out | **Query cost / complexity analysis** — weight fields, cap the budget |
| Unbounded lists | **Paginate + clamp `first`** (§5); cap aliases & node count |
| Schema reconnaissance | **Disable introspection in prod**; turn off field suggestions |
| Arbitrary ad-hoc queries | **Persisted / trusted documents** — allowlist hashed operations |
| Object access | **Field-level authz, deny-by-default** — check on the resolver, per object |

- **Field-level authorization is deny-by-default and enforced in the resolver**, not the gateway: the
  resolver re-derives identity and checks *this caller may read this object* (IDOR/BOLA,
  [../practices/app-security.md](../practices/app-security.md) §2) — UI hiding a field is not security.
- **Persisted queries (APQ → trusted documents):** clients send a hash; the server runs only
  operations on the build-time allowlist. Kills arbitrary queries and shrinks request size. Required
  for public/high-traffic graphs _(scale-up)_.
- **Use a hardened library** (`graphql-armor`, Apollo/Yoga plugins) for depth/cost/alias limits rather
  than hand-rolling. Rate-limit by cost, not request count ([api-design.md](./api-design.md)).

## 8. Performance — fetch what's asked, no more

- **Avoid over- and under-fetching in resolvers.** The client picks fields; your resolver shouldn't
  `SELECT *` then drop columns, nor make a call per field. Inspect the `info` selection set or use a
  projection layer to fetch only requested columns. DataLoader (§4) handles the relational fan-out.
- **`@defer` / `@stream` for slow or large fields** — return the fast shell immediately and stream the
  expensive parts incrementally. Now part of the GraphQL incremental-delivery spec; gate behind client
  support _(scale-up)_.
- **Caching is field- and response-scoped, not URL-scoped.** POST-by-default defeats HTTP caches; use
  persisted-query GETs for CDN cacheability, per-type cache hints (`@cacheControl`/`maxAge`), and the
  layered cache/TTL/stampede rules in [./resilience.md](./resilience.md) §7.

## 9. Federation — compose, don't stitch _(scale-up)_

When multiple teams own slices of one graph, use **Apollo Federation v2 subgraphs** behind a gateway
(or router), not legacy schema stitching.

- **Each subgraph owns its types and resolves its own fields;** entities are joined by `@key`. The
  router builds the query plan — services never call each other synchronously to compose.
- **Prefer federation over stitching:** declarative ownership, composition checks in CI, no brittle
  hand-merged schema. Schema stitching is legacy — don't start there.
- **Run composition checks** (`rover subgraph check`) so one subgraph can't break the supergraph.

## 10. Versioning — evolve, never `/v2`

GraphQL versions by **continuous evolution of one schema**, not parallel endpoints. The client asks
for the fields it wants, so additive change is free.

- **Add, don't mutate.** New fields/types/optional args are safe. Removing a field, tightening an arg
  to non-null, or changing a type is breaking — gate it (§12).
- **Deprecate with `@deprecated(reason: "use newField")`**, watch field-usage metrics, and remove only once
  traffic hits zero. Never ship `Query2` or a `/v2` graph.

```graphql
type User {
  fullName: String @deprecated(reason: "Use `displayName`; removal 2026-09-01")
  displayName: String!
}
```

## 11. Codegen — typed resolvers and clients

Generate both ends from the SDL; a hand-typed resolver or client drifts from the schema.

- **Server:** generate resolver types (GraphQL Code Generator `typescript-resolvers`, gqlgen for Go,
  Pothos' inferred types) so a schema change fails the build, not production.
- **Client:** generate typed operations and hooks from the queries (`client-preset`, Apollo/urql/Relay
  codegen). Validate operations against the schema in CI.

## 12. Tooling, lint & CI checks

| Concern | Tool | Gate |
|---|---|---|
| Schema/operation lint | **GraphQL-ESLint** (`@graphql-eslint/eslint-plugin`) | naming, no-unreachable-types, deprecations |
| Breaking-change diff | **GraphQL Inspector** / `rover subgraph check` | fail PR on breaking diff vs `main` |
| Composition (federated) | **`rover supergraph compose` / check** | supergraph builds & is valid |
| Security limits | **`graphql-armor`** / gateway plugins | depth + cost + alias caps enforced |

- **Run schema-diff against the deployed schema, not just `main`** — catch breaking changes before a
  client in prod relies on the removed field.
- **Resolver/integration tests** drive the schema with real queries (N+1 counts asserted, authz paths
  covered) per [../practices/testing-strategy.md](../practices/testing-strategy.md).

---

## Definition of done

- [ ] SDL is committed and the source of truth; code-first schemas emit a CI-diffed SDL snapshot.
- [ ] Nullability is deliberate — network-backed fields nullable; `!` only on guaranteed-present data.
- [ ] Inputs/outputs are distinct types; mutations take one `input` and return a payload; no `JSON` grab-bags.
- [ ] Every per-entity fetch goes through a **request-scoped DataLoader** with order/arity-correct batching.
- [ ] Lists use **Relay cursor connections** with opaque cursors and a clamped, bounded `first`.
- [ ] Expected failures are typed (union/payload + `extensions.code`); partial results returned; no internals leaked.
- [ ] Depth + complexity/cost limits enforced; introspection off in prod; field-level authz deny-by-default.
- [ ] Persisted/trusted queries allowlisted on public graphs _(scale-up)_; rate-limited by cost.
- [ ] Resolvers fetch only requested fields; `@defer`/`@stream` and cache hints used where they pay _(scale-up)_.
- [ ] Schema evolves additively; removals go through `@deprecated` + usage metrics — no `/v2` graph.
- [ ] Resolver and client types are generated from the SDL; operations validated in CI.
- [ ] CI lints (GraphQL-ESLint), blocks breaking diffs (GraphQL Inspector / `rover check`), and enforces query limits.
- [ ] _(scale-up)_ Multi-team graphs use Apollo Federation v2 subgraphs with composition checks, not stitching.

**Sources:** [GraphQL spec](https://spec.graphql.org) · [Relay connections](https://relay.dev/graphql/connections.htm) · [DataLoader](https://github.com/graphql/dataloader) · [Apollo Federation](https://www.apollographql.com/docs/federation/) · [graphql-armor](https://github.com/escape-technologies/graphql-armor)
