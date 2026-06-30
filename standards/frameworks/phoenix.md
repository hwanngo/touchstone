# Phoenix Standards

Framework layer; language rules → [elixir.md](../languages/elixir.md).

Current Phoenix (target the **1.7+** floor; verify the release) with **LiveView 1.1** — a productive, fault-tolerant web layer
over OTP. This doc owns only the Phoenix-shaped decisions. Cross-cutting concerns are **deferred, not
repeated**: schema/migrations → [database.md](../platform/database.md), authN/authZ/OWASP →
[app-security.md](../practices/app-security.md), telemetry/metrics/tracing →
[observability.md](../platform/observability.md), PubSub/broker patterns →
[event-driven.md](../design/event-driven.md), test strategy →
[testing-strategy.md](../practices/testing-strategy.md), dependencies/supply-chain → [elixir.md](../languages/elixir.md) + [security.md](../practices/security.md). Siblings: [rails.md](rails.md), [django.md](django.md).

---

## 1. Contexts: the domain boundary

**Contexts are the core organizing principle** — a context (`Accounts`, `Billing`, `Catalog`) is a
public module that exposes a domain's use cases as plain functions. The web layer and other contexts
call those functions; **nobody reaches past them into Ecto**. This is the one rule that keeps a Phoenix
app from rotting into controllers full of queries.

| Rule | Why |
|---|---|
| **Ecto never leaks across a context boundary** | Callers get structs + result tuples (`{:ok, %Order{}}` / `{:error, changeset}`), never a `Repo` call, a query, or a bare changeset to fiddle with. The schema is an implementation detail of the context that owns it. |
| **One context owns each schema** | `Accounts` owns `User`; `Billing` references a user by **id**, not by `alias`-ing the schema and querying it. Cross-context reads go through the owning context's API. |
| **Functions are use cases, not CRUD** | `Accounts.register_user/1`, `Billing.charge_order/2` — name the intent. A context that is just `create_*/update_*/delete_*` passthroughs is an anemic wrapper, not a boundary. |
| **Web layer stays thin** | Controllers and LiveViews orchestrate (params → context call → render); business logic, validation, and transactions live **in the context**. |

Don't over-split early: start with a few coarse contexts and extract when a boundary earns it. Bounded
contexts that talk via events rather than direct calls → [event-driven.md](../design/event-driven.md).

## 2. Ecto

Ecto is explicit by design — schemas, changesets, and queries are separate concerns. Conventions
(naming, PK choice, indexes, `timestamptz`/UTC) → [database.md](../platform/database.md).

| Concern | Rule |
|---|---|
| Changesets | **Validation lives at the boundary in a changeset**, not scattered in controllers. `cast/3` allowlists fields (never `cast(struct, params, __schema__(:fields))` blanket-casts — that is Phoenix's mass-assignment footgun); `validate_*` for rules; `unique_constraint`/`foreign_key_constraint` to surface **DB** errors as changeset errors. Use distinct changesets per use case (`registration_changeset` vs `profile_changeset`). |
| Preloads | **Preload every association a template or serializer walks** — Ecto does **not** lazy-load; an unpreloaded access raises, and preloading inside a loop is the N+1. Preload in the query (`from o in Order, preload: [:line_items]`) or batch with `Repo.preload/2`. |
| Transactions | Multi-step writes go through **`Ecto.Multi`** — it composes named steps, threads results, and rolls back atomically while returning *which* step failed (`{:error, :step, reason, changes}`). Keep transactions short; no network calls inside (see [database.md](../platform/database.md)). |
| Query hygiene | Compose queries with the `Ecto.Query` DSL; `select` only the columns you need; `Repo.stream/1` inside a transaction for large scans; `Repo.insert_all`/`update_all` for bulk. Push filtering into SQL, not Elixir. |
| One Repo, explicit | `Repo` is called from contexts only. No `Repo.all` in a controller or LiveView. |

```elixir
def charge_order(order, card) do
  Ecto.Multi.new()
  |> Ecto.Multi.update(:order, Order.charging_changeset(order))
  |> Ecto.Multi.insert(:payment, Payment.changeset(%Payment{}, %{order_id: order.id}))
  |> Ecto.Multi.run(:capture, fn _repo, %{payment: p} -> Gateway.capture(p, card) end)
  |> Repo.transaction()
end
```

### Migrations

Every schema change is a **reviewed, committed migration**; `mix ecto.migrate` runs as a **deploy
step** (or via `Release.migrate/0`, §10). **Zero-downtime = expand → contract**
([database.md](../platform/database.md)): additive migration first, backfill in a **separate
idempotent task/Oban job** (never a heavy inline `update_all` holding locks during deploy), drop the
old column in a *later* release. Renames and `NOT NULL`-on-existing are expand/contract in disguise.

- Add indexes with `create index(..., concurrently: true)` + `@disable_ddl_transaction true` +
  `@disable_migration_lock true` so you don't block writes.
- `mix ecto.migrate` and `mix ecto.rollback` against a throwaway DB are CI gates; check in a clean
  `priv/repo/structure.sql` (or `schema`) so drift is visible.

## 3. Web layer: controllers, plugs, router

The endpoint is a **plug pipeline**; the router composes named pipelines onto scopes. Keep the request
path explicit and thin.

- **Verified routes (`~p`)** are mandatory — `~p"/orders/#{order}"` is compile-time-checked against the
  router. Never hand-build path strings; the old `Routes.*_path` helpers are legacy.
- **Pipelines** (`:browser`, `:api`) bundle plugs (CSRF, session, `accepts`, auth). Put cross-cutting
  request logic in a **plug**, not copy-pasted into every action. A custom plug that assigns the
  current scope (`:require_authenticated_user`) gates a `scope` block.
- **Controllers stay thin**: `action → params → context call → render`. No business logic, no `Repo`,
  no multi-step writes. Map domain errors centrally with an `action_fallback` controller that turns
  `{:error, changeset}` / `{:error, :not_found}` into the right status + body.
- JSON APIs render through a **view/JSON module** (an explicit `data/1`), never a schema field-for-field
  (`render(conn, :show, order: order)` with an allowlisted map) — leaking columns you add later is the
  classic mistake. Contract/versioning/errors → API design standards.

## 4. LiveView

**LiveView is the headline and the default for interactive UI** — server-rendered HTML over a
stateful WebSocket, with the diff computed on the server and patched into the DOM. You write one
language (Elixir), keep state on the server, and get real-time updates without a separate API + SPA.

**Mental model:** a LiveView is a process holding a `socket`. `mount/3` sets initial `assigns`;
events (`phx-click`, `phx-submit`) arrive as `handle_event/3` messages; PubSub/`send` arrive as
`handle_info/2`; each callback returns an updated socket and LiveView ships **only the diff**. HEEx
templates (`.heex`) are compile-checked and built from **function components** (`<.button>`,
`<.input>`).

| Concern | Rule |
|---|---|
| Large collections | Use **streams** (`stream/3`, `stream_insert/3`, `stream_delete/2`) — the server does **not** keep the list in memory and patches single rows surgically. This is the foundational tool for feeds, tables, and infinite scroll; replacing a 500-item assign every PubSub tick is the canonical perf bug. |
| `assigns` discipline | Keep assigns minimal; derive in the template, don't store. Heavy/ephemeral render-once data uses **`temporary_assigns`** so it isn't retained between renders. |
| Forms | `to_form/2` + `<.form for={@form}>` + `<.input>`; validate on `phx-change` against a changeset (`Map.put(changeset, :action, :validate)`) so errors show inline before submit. |
| Boundaries | A LiveView is still **web layer** — it calls **contexts** (§1), never `Repo`. Business logic does not move into `handle_event`. |
| Optimistic UI | Reach for **JS commands** (`Phoenix.LiveView.JS`) and hooks for client-side interactions (show/hide, transitions) before adding a JS framework. |

**LiveView vs API + SPA:** default to LiveView for first-party, server-driven, real-time UI — it
collapses the stack. Choose a separate **JSON API + SPA/native client** when you need offline support,
a public third-party API, a large client-side app team, or heavy client-only interactivity (canvas,
editors). The two compose: a mostly-LiveView app can expose an API for the cases that need one.

## 5. Channels, PubSub & Presence

For real-time fan-out beyond a single LiveView, use the OTP-native primitives.

- **`Phoenix.PubSub`** is the backbone — broadcast domain events (`Phoenix.PubSub.broadcast(MyApp.PubSub, "orders:#{id}", msg)`)
  and let LiveViews/Channels subscribe in `mount`/`join`. It's distributed across the cluster for free.
- **Channels** for bidirectional messaging to non-LiveView clients (mobile, JS) — `join/3` authorizes,
  `handle_in/3` handles client messages. Authorize on join; never trust the topic.
- **Presence** (`Phoenix.Presence`) for "who's online"/shared state — CRDT-backed, conflict-free across
  nodes; don't hand-roll presence in ETS.
- PubSub is in-cluster, at-most-once, no persistence — for durable/cross-system events use a broker
  ([event-driven.md](../design/event-driven.md)), not raw PubSub.

## 6. Authentication & scopes

Generate auth with **`mix phx.gen.auth`** — it produces a reviewed, salted-token, timing-safe
implementation. **Don't hand-roll auth.** On Phoenix 1.8 the generator defaults to **magic-link**
login and adds a `require_sudo_mode` plug for sensitive operations (recent-auth re-check).

- **Scopes are the 1.8 secure-data-access pattern**: `phx.gen.auth` emits a `%MyApp.Accounts.Scope{}`
  carrying the current user (and, when you extend it, their org/tenant). Thread the scope through
  context functions so authorization is the default, not an afterthought — `Billing.list_invoices(scope)`
  filters to the caller's rows rather than trusting a param. Add multi-tenancy by augmenting the scope.
- Authorize at the **context boundary** (does *this* scope own *this* row), not only in the controller.
- AuthN/authZ policy, password/session model, OWASP coverage → [app-security.md](../practices/app-security.md).

## 7. Background work

Out-of-request work (mail, webhooks, exports, third-party calls) goes through **Oban** (Postgres-backed
job queue) — durable, observable, with retries/cron/uniqueness built in. Don't `spawn`/`Task.start` a
fire-and-forget process in the request path for work that must not be lost.

- **Jobs must be idempotent and retry-safe** — Oban retries with backoff, so key on an idempotency
  token and make replays a no-op. Use Oban's **unique** options to dedupe.
- **Pass ids, not structs**, in `args` (JSON-serialized) and re-fetch in `perform/1`; enqueue **inside
  the `Ecto.Multi`/transaction** (`Oban.insert`) so a rolled-back write can't dispatch a job for a row
  that never committed.
- Jobs are thin wrappers over **context** functions (§1) — no business logic in the worker body.
- `Task.Supervisor` is fine for truly ephemeral, loss-tolerant concurrency; **Oban** for anything that
  must survive a restart.

## 8. Telemetry & observability

Phoenix and Ecto emit **`:telemetry`** events out of the box — wire them, don't reinvent. Full
metrics/tracing/logging strategy → [observability.md](../platform/observability.md).

- Keep the generated **`Telemetry` supervisor** and export metrics (`telemetry_metrics` +
  `_prometheus`/OTLP reporter) for endpoint latency, Ecto query time, and queue depth.
- Add **OpenTelemetry** (`opentelemetry_phoenix`, `opentelemetry_ecto`, `opentelemetry_liveview`) for
  distributed traces _(scale-up)_; propagate context across PubSub/Oban boundaries.
- Attach custom `:telemetry` spans for context use cases; structured logs carry the request/trace id.
- **LiveDashboard** in dev (and locked-down in prod) for live process/metric inspection.

## 9. Testing

ExUnit with the Phoenix helpers; strategy/coverage → [testing-strategy.md](../practices/testing-strategy.md).

- **`Ecto.Adapters.SQL.Sandbox`** gives each test a rolled-back transaction, so tests run **`async:
  true`** safely — keep them async; only the few that can't (global state, shared external) opt out.
- **`Phoenix.ConnTest`** for controllers/JSON (assert **status + decoded body shape**, not internals);
  **`Phoenix.LiveViewTest`** (`live/2`, `render_click`, `render_submit`, `element/2`) for LiveView
  interactions — drive the UI like a user, assert on rendered HTML.
- Test **contexts directly** for business logic — that's where it lives. Use a factory
  (**`ExMachina`** or simple builder functions), not committed fixtures.
- Run against **real Postgres**, not an in-memory fake. Cover the **error and authorization-denied
  paths** (changeset errors, `{:error, :unauthorized}`), not just the happy path.

## 10. Releases & deploy

Ship a **`mix release`** (OTP release) — a self-contained binary, no Mix/Hex on the prod box. Build it
in a multi-stage Docker image.

- **Runtime config in `config/runtime.exs`** reads `System.fetch_env!/1` so a missing required var
  **fails at boot**, not on first request. Secrets come from env / a secret manager, never source.
- Run migrations as a **release command** (a `Release.migrate/0` module), not by shipping Mix — invoke
  it as a deploy step before traffic shifts; keep migrations expand/contract (§2) so old and new app
  versions coexist during a rolling deploy.
- Set the `RELEASE_COOKIE` and node naming for **clustering** (`libcluster`) so PubSub/Presence span
  nodes _(scale-up)_; set `WEB_CONCURRENCY`/pool sizes from the runtime config.
- Health/readiness endpoints gate the rollout; pool sizing + timeouts → [database.md](../platform/database.md).

## Definition of done

- [ ] Contexts are the boundary: Ecto/`Repo` never leaks past a context; web layer calls context functions returning result tuples; functions named as use cases.
- [ ] Changesets validate at the boundary with allowlisted `cast`; DB constraints surfaced via `*_constraint`; `Ecto.Multi` for multi-step writes; no blanket-cast mass assignment.
- [ ] Every walked association is preloaded (no N+1, no lazy-load); `Repo` confined to contexts; bulk/stream ops for large data.
- [ ] Schema changes are reviewed migrations; expand/contract for zero-downtime; backfills in separate idempotent jobs; indexes built `concurrently`; migrations run via release command in CI + deploy.
- [ ] Verified routes (`~p`) everywhere; thin controllers with `action_fallback`; cross-cutting logic in plugs/pipelines; JSON rendered through an allowlist, never schema-for-schema.
- [ ] LiveView is the default interactive UI; **streams** for large collections; minimal assigns + `temporary_assigns`; forms validate on `phx-change`; LiveViews call contexts, not `Repo`.
- [ ] Real-time via PubSub/Channels/Presence with authorization on join/subscribe; durable cross-system events use a broker, not raw PubSub.
- [ ] Auth via `phx.gen.auth` (magic-link, sudo mode); **scopes** thread current user/tenant through contexts; authorization checked at the context boundary.
- [ ] Background work on Oban — idempotent, unique-keyed, pass ids, enqueued inside the transaction; workers wrap contexts; no fire-and-forget in the request path for durable work.
- [ ] `:telemetry`/Telemetry supervisor wired to a metrics reporter; OpenTelemetry traces across PubSub/Oban _(scale-up)_; LiveDashboard locked down in prod.
- [ ] Tests on ExUnit with the SQL Sandbox running `async: true`; `ConnTest`/`LiveViewTest` for the web layer; contexts tested directly on real Postgres; error/authz paths covered.
- [ ] Deploy a `mix release` with `runtime.exs` failing fast on missing env; clustering cookie/node naming set where PubSub/Presence span nodes.

**Sources:** [Phoenix docs](https://hexdocs.pm/phoenix/overview.html) · [Phoenix 1.8 release](https://www.phoenixframework.org/blog/phoenix-1-8-released) · [Contexts guide](https://hexdocs.pm/phoenix/contexts.html) · [LiveView docs](https://hexdocs.pm/phoenix_live_view/welcome.html) · [LiveView 1.1 release](https://www.phoenixframework.org/blog/phoenix-liveview-1-1-released) · [Ecto](https://hexdocs.pm/ecto/Ecto.html) · [Oban](https://hexdocs.pm/oban/Oban.html) · [mix phx.gen.auth](https://hexdocs.pm/phoenix/mix_phx_gen_auth.html)
