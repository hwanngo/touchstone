---
name: elixir-standards
description: Use when writing, reviewing, testing, formatting, or configuring any Elixir code (.ex/.exs files, mix.exs, mix.lock) in a touchstone repo — asdf/.tool-versions pin, Hex with committed mix.lock, mix format + Credo, typespecs + Dialyzer, OTP supervision trees, {:ok,_}/{:error,_} idioms, ExUnit + Mox, mix release with runtime.exs. Invoke before adding deps, editing tests, wiring supervisors, or changing error handling. Phoenix-specific concerns (controllers, LiveView, contexts-as-web) → phoenix skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Elixir Standards

Full standard: **`standards/languages/elixir.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- Pin Elixir + OTP in **`.tool-versions`** (1.18+ floor, target 1.20 / OTP 27+) via asdf/mise — never a system Erlang; same strings CI installs.
- **Hex deps with committed `mix.lock`** (apps **and** libraries); `mix deps.get` from the lock, `mix deps.unlock --unused` clean.
- Format with **`mix format`** (CI: `--check-formatted`); compile with **`--warnings-as-errors`**; lint with **`mix credo --strict`**.
- **`@spec` public functions**; run **`mix dialyzer`** with a cached PLT — new warnings fail the build.
- Test with **ExUnit `async: true`**; mock **behaviours via Mox**, not modules; `start_supervised!/1` for processes.

## Don't get burned
- **"Let it crash" is for the *unexpected*** — supervise the recovery; don't `rescue`/`try` around expected failures, which return **`{:ok, _}`/`{:error, reason}`** with matchable reasons (not bare strings). Bang functions raise only where a caller can't recover.
- **Everything under a supervision tree** — explicit `child_spec`, never bare `spawn`; pick `:one_for_one`/`:rest_for_one`/`:one_for_all` deliberately. `Registry`/`:via` for names; never build process names from user input (atoms aren't GC'd). `DynamicSupervisor`/`Task.Supervisor` for runtime children.
- **`with`/`else` to chain `{:ok, _}` steps** — keep `else` explicit so an error tag isn't swallowed. Pattern-match in function heads.
- **`Task.async_stream`** (bounded `max_concurrency` + `:timeout`) for parallel I/O; **Broadway/GenStage** for back-pressured pipelines _(scale-up)_. Never share mutable state across processes; ETS for shared read-heavy caches.
- **Prod runs a `mix release`** — no Mix at runtime; **all runtime config in `config/runtime.exs`**, fail-fast on missing env (`System.fetch_env!`). Run migrations from a release command, not `mix ecto.migrate`.
- `mix deps.audit` clean; emit `:telemetry` at boundaries; structured `Logger` metadata, no secrets. Ecto/SQL depth → `standards/platform/database.md`.

## Done
`mix format --check-formatted` + `compile --warnings-as-errors` clean · `mix credo --strict` clean · `mix dialyzer` clean (specs on public fns) · `mix test` green (async, Mox) · `mix.lock` committed, `mix deps.audit` clean · supervised, no bare `spawn` · `mix release` with `config/runtime.exs`. See `standards/languages/elixir.md`.
