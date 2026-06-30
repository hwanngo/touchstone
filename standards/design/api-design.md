# API Design

The API is a contract — clients depend on its shape long after you forget you shipped it. Design
it deliberately, version it honestly, and let a committed spec be the source of truth.

---

## 1. REST: resources & URLs

Model **nouns (resources)**, not verbs. The HTTP method is the verb.

| Rule | Do | Don't |
|---|---|---|
| Collections plural | `GET /orders` | `GET /order` |
| Nesting = ownership | `GET /orders/{id}/items` | `GET /getOrderItems?o=id` |
| No verbs in paths | `POST /orders` | `POST /createOrder` |
| Kebab-case paths, snake/camel JSON | `/shipping-labels` | `/ShippingLabels` |
| Actions that aren't CRUD | `POST /orders/{id}/cancel` | `POST /cancelOrder` |
| Identifiers are opaque | UUID/ULID | leaky auto-increment ints |

Stay shallow: nest **one level max**; deeper relations become query filters, not path segments.

## 2. Status-code discipline

Use codes clients can branch on; don't return `200 {error:...}`.

| Code | Meaning |
|---|---|
| `200/201/204` | OK / created (return `Location`) / no body |
| `400` | malformed/invalid input (validation → [app-security.md](../practices/app-security.md)) |
| `401 / 403` | unauthenticated / authenticated-but-forbidden |
| `404 / 409 / 410` | not found / conflict / gone (after sunset) |
| `422` | semantically invalid (well-formed but unprocessable) |
| `429` | rate-limited — include `Retry-After` |
| `5xx` | our fault — never leak why (§7) |

## 3. Versioning & deprecation

**Recommended: URI versioning** (`/v1/...`) — visible, cache-friendly, trivial to route.
_Escape hatch:_ header/media-type versioning (`Accept: application/vnd.acme.v2+json`) when you
need many fine-grained variants and control both ends — but it's invisible in logs and CDNs.

- **Bump major only for breaking changes.** Additive changes ship within the same version.
- Run **N-1**: keep the previous major alive through the deprecation window.
- Announce removal with standard headers, then return `410 Gone`:

```http
Deprecation: Sun, 01 Mar 2026 00:00:00 GMT
Sunset: Wed, 01 Jul 2026 00:00:00 GMT
Link: <https://api.acme.com/docs/deprecations#orders-v1>; rel="deprecation"
```

See [architecture.md](architecture.md) for service-boundary versioning and
[database.md](../platform/database.md) for expand/contract migrations behind the contract.

## 4. Pagination, filtering, sorting

**Cursor pagination by default** — offset (`LIMIT/OFFSET`) drifts when rows are inserted/deleted
mid-scan and gets O(n) slow on deep pages. A cursor is an opaque token over a stable sort key.

```http
GET /orders?limit=50&cursor=eyJpZCI6IjAxSF...
→ { "data": [...], "next_cursor": "eyJpZCI6IjAxSj...", "has_more": true }
```

_Escape hatch:_ offset is fine for small, bounded, human-paged admin lists.

| Concern | Convention |
|---|---|
| Filter | `?status=open&created_after=2026-01-01` |
| Sort | `?sort=-created_at,name` (`-` = desc) |
| Sparse fields | `?fields=id,status,total` |

## 5. Idempotency & content negotiation

- Unsafe retries (`POST`/`PATCH`) carry a client-generated **`Idempotency-Key`**; the server stores
  the first response per key and replays it, so a retried payment charges once. Pair with
  retry/timeout policy in [resilience.md](resilience.md).
- `PUT`/`DELETE` are idempotent by definition; `GET`/`HEAD` safe. Honour `Accept`/`Content-Type`;
  default to JSON, return `406`/`415` on mismatch.

## 6. Error envelope — RFC 9457

Standardize on **`application/problem+json`** (RFC 9457, successor to 7807). One shape everywhere,
machine-routable `type`, human `detail`.

```json
{
  "type": "https://api.acme.com/problems/insufficient-funds",
  "title": "Insufficient funds",
  "status": 402,
  "detail": "Wallet balance 12.00 is below the 49.99 charge.",
  "instance": "/orders/01HX.../pay",
  "errors": [{ "field": "amount", "code": "too_large" }]
}
```

- `type` is a stable URI that resolves to docs; clients branch on it, not on `detail` strings.
- **Never** leak stack traces, SQL, internal hostnames, or library versions — log them server-side,
  correlate by a request id. See [app-security.md](../practices/app-security.md).

## 7. Contract-first (source of truth in the repo)

Hand-written specs and hand-written clients drift. **Commit the contract, generate the code, lint in
CI.** Fail the PR on lint errors and breaking changes.

| Style | Source of truth | Lint | Breaking-change gate |
|---|---|---|---|
| REST | **OpenAPI 3.1** (JSON Schema 2020-12) | **Spectral** | **oasdiff** |
| gRPC | **protobuf** | **buf lint** | **buf breaking** |
| GraphQL | **SDL** | graphql-schema-linter | schema-diff / inspector |

```yaml
# CI gate (see ../platform/ci-cd.md)
- run: spectral lint openapi.yaml --fail-severity=warn
- run: oasdiff breaking origin/main:openapi.yaml openapi.yaml --fail-on ERR
```

Generate clients/servers from the contract — don't hand-write what a generator guarantees stays in
sync.

## 8. gRPC: proto evolution

Backward-compat is a discipline, not a hope. **buf breaking** enforces it in CI.

- **Never reuse or renumber a field tag.** `reserve` removed numbers/names.
- Additive only: new fields/messages/RPCs are safe; changing a field's type or number is not.
- Don't change `required`-ness semantics or repurpose a field's meaning.

```protobuf
message Order {
  reserved 4, 7;            // retired tags — never recycle
  reserved "legacy_status";
  string id = 1;
  Money total = 2;
}
```

## 9. GraphQL _(scale-up)_

Reach for GraphQL when many clients need divergent shapes over a rich graph; otherwise REST is less
to operate.

| Risk | Control |
|---|---|
| N+1 resolvers | **DataLoader** batching per request |
| Unbounded queries | **depth + complexity limits** |
| Hot-path cost | **persisted queries** (allowlist of hashed ops) |
| Schema recon | **disable introspection in prod** |

Errors stay top-level `errors[]`; map to the same `type` taxonomy as §6.

## 10. Cross-cutting (link, don't duplicate)

| Concern | Owner doc |
|---|---|
| AuthN/AuthZ, rate limiting, input validation | [app-security.md](../practices/app-security.md) |
| Timeouts, retries, circuit breakers, backoff | [resilience.md](resilience.md) |
| Service boundaries, sync vs async | [architecture.md](architecture.md) |
| Schema migrations behind the contract | [database.md](../platform/database.md) |
| Lint/diff/test gates | [ci-cd.md](../platform/ci-cd.md) |

---

## Definition of done

- [ ] Resources are nouns; URLs shallow, plural, kebab-case; HTTP methods carry the verb.
- [ ] Status codes are used semantically; no `200`-with-error bodies.
- [ ] Versioning strategy chosen (URI default); breaking changes bump major; **N-1** supported.
- [ ] Deprecations emit `Deprecation`/`Sunset`/`Link`, then `410 Gone` after the window.
- [ ] List endpoints use cursor pagination; filtering/sorting follow the conventions.
- [ ] Unsafe retried writes honour `Idempotency-Key`.
- [ ] All errors are RFC 9457 `application/problem+json`; no internals leaked.
- [ ] Contract (OpenAPI 3.1 / protobuf / SDL) is committed and the source of truth.
- [ ] CI lints the contract (Spectral / buf lint) and blocks breaking changes (oasdiff / buf breaking).
- [ ] Clients/servers are generated from the contract, not hand-written.
- [ ] gRPC protos never reuse field numbers; retired tags are `reserved`.
- [ ] _(GraphQL)_ DataLoader, depth/complexity limits, persisted queries, introspection off in prod.
