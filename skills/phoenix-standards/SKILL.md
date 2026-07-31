---
name: phoenix-standards
description: Use when building or reviewing a Phoenix 1.7+/LiveView app in a touchstone repo — contexts, Ecto, the web layer, LiveView, channels/PubSub, auth/scopes, Oban, releases. Triggers on `phoenix` in `mix.exs`, a `*_web/` directory, `.heex` templates, `use Phoenix.LiveView`. Elixir-language idioms (OTP, GenServer, supervision) live in the elixir skill; this is the framework layer.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Phoenix (framework)

Full standard: **`standards/frameworks/phoenix.md`** (layers on `standards/languages/elixir.md`). Rules:

## Always
- **Contexts are the boundary** — Ecto/`Repo` never leaks past a context; the web layer calls context functions returning `{:ok, _}`/`{:error, changeset}`, never queries the schema itself.
- **Changesets validate at the boundary** with allowlisted `cast` (no blanket-cast mass assignment); DB constraints surfaced via `*_constraint`; **`Ecto.Multi`** for multi-step writes.
- **Preload every walked association** — Ecto does not lazy-load; preloading in a loop is the N+1.
- **LiveView is the default interactive UI** — **streams** for large collections (never replace a big assign every tick), minimal assigns + `temporary_assigns`, forms validate on `phx-change`; LiveViews call contexts, not `Repo`.
- **Verified routes (`~p`)** everywhere; thin controllers with `action_fallback`; JSON rendered through an allowlist, never schema field-for-field.
- **Auth via `phx.gen.auth`** (magic-link, sudo mode); **scopes** thread the current user/tenant through contexts so authorization is the default. Background work on **Oban** — idempotent, pass ids, enqueue inside the transaction.

## Defer (don't duplicate)
- Schema/migrations/expand-contract → `../../standards/platform/database.md`; authN/authZ/OWASP → `../../standards/practices/app-security.md`; telemetry/metrics/tracing → `../../standards/platform/observability.md`; durable cross-system events → `../../standards/design/event-driven.md`; Elixir/OTP idioms → `../../standards/languages/elixir.md`; test strategy → `../../standards/practices/testing-strategy.md`.

## Done
contexts own Ecto · changesets validate + `Multi` · associations preloaded (no N+1) · expand/contract migrations · `~p` routes + thin controllers · LiveView with streams · `phx.gen.auth` + scopes · idempotent Oban · ExUnit SQL Sandbox `async: true` + LiveViewTest on real Postgres · `mix release` with `runtime.exs` fail-fast. See `standards/frameworks/phoenix.md`.
