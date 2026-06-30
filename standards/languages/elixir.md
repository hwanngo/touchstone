# Elixir Standards

Applies to any Elixir project/library (1.18+, tracking the current stable line, on Erlang/OTP 27+). Versions are pinned
with **asdf/mise + `.tool-versions`**, dependencies locked with **Hex + `mix.lock` committed**,
formatted with **`mix format`**, linted with **Credo**, type-checked with **typespecs + Dialyzer
(Dialyxir)**, and tested with **ExUnit + Mox** — built and shipped as a **`mix release`**.
Cross-cutting concerns defer to siblings: supply-chain to
[../practices/security.md](../practices/security.md), dependency policy to
[../practices/dependencies.md](../practices/dependencies.md), the test pyramid to
[../practices/testing-strategy.md](../practices/testing-strategy.md), timeouts/retries/circuit
breakers to [../design/resilience.md](../design/resilience.md), Ecto/SQL depth to
[../platform/database.md](../platform/database.md), and pipelines to
[../platform/ci-cd.md](../platform/ci-cd.md).

> **One law:** let it crash at the process boundary and supervise the recovery — never `rescue`
> your way around a broken state, and never hide an error a caller is supposed to match on.

---

## 1. Toolchain

| Concern | Tool | Notes |
|---|---|---|
| Elixir version | **1.18 (floor); track current stable** | Built-in `JSON`, set-theoretic type checking of calls. Pin in `.tool-versions`. |
| Erlang/OTP | **27 (floor), 28+ recommended** | OTP 27 is the floor for 1.18+; new projects track the latest stable OTP. |
| Version manager | **asdf** or **mise** | Reads `.tool-versions` (both `elixir` *and* `erlang` lines). Never a distro/system Erlang. |
| Build tool | **Mix** | `mix.exs` is the project manifest; one task interface for build/test/release. |
| Dependencies | **Hex** | `deps` in `mix.exs` + **`mix.lock` committed** — for apps *and* libraries. |
| Formatter | **`mix format`** | Config in `.formatter.exs`. Non-negotiable, zero-config, ships with Elixir (§3). |
| Linter | **Credo** | `--strict` in CI; config in `.credo.exs`. |
| Type checker | **Dialyzer via Dialyxir** | PLT cached; typespecs on public functions (§4). |
| Test runner | **ExUnit** | Ships with Elixir; `async: true` by default (§9). |

## 2. Everyday commands

```bash
mix deps.get                      # install from mix.lock
mix compile --warnings-as-errors  # warnings are build failures (what CI runs)
mix format --check-formatted      # format gate (CI); `mix format` to apply
mix credo --strict                # lint
mix test                          # run the suite (async by default)
mix dialyzer                      # type-check against the PLT
mix deps.audit                    # CVE scan of mix.lock (mix_audit)
mix hex.outdated                  # dependency drift
```

Add a dependency by editing `deps/0` in `mix.exs`, then `mix deps.get` (writes/updates
**`mix.lock`** — commit it). `mix deps.unlock --unused` prunes stale lock entries.

## 3. Formatting & linting

- **`mix format` is the formatter — non-negotiable and never hand-tuned.** It ships with Elixir,
  is config-light, and removes style from review entirely. CI runs `mix format --check-formatted`;
  a diff is a red build. List `import_deps` (e.g. `:ecto`, `:phoenix`) in `.formatter.exs` so macro
  DSLs format correctly.
- **Compile with `--warnings-as-errors`.** Unused variables, unreachable clauses, and the
  set-theoretic type warnings (1.18+) are real defects — never let them accumulate.
- **Credo is the linter, not the formatter** — it catches complexity, refactoring opportunities,
  and consistency the formatter can't. Run `--strict` in CI; tune `.credo.exs` rather than
  scattering inline disables. A `# credo:disable-for-next-line Check.Name` is scoped and justified,
  never repo-wide.

## 4. Types & typespecs

Elixir is gaining a built-in **set-theoretic type system** (inference of patterns in 1.18, of
guards/returns through 1.19–1.20) that flags many errors at compile time for free — keep
`--warnings-as-errors` on to surface them. Dialyzer remains the explicit success-typing checker.

- **Write `@spec` on every public function**, plus `@type`/`@typep` for non-trivial shapes. Specs
  are checkable documentation; Dialyzer verifies them against actual code paths.
  ```elixir
  @type id :: pos_integer()
  @spec fetch_user(id()) :: {:ok, User.t()} | {:error, :not_found}
  def fetch_user(id) when is_integer(id) and id > 0, do: # ...
  ```
- **Run Dialyzer in CI via Dialyxir**, with the **PLT cached** (it's slow to build cold) — key the
  cache on the OTP/Elixir/`mix.lock` hash. Treat new warnings as failures; a long-lived ignore file
  is a ratchet to burn down, not grow.
- **Define structs with `@enforce_keys` and a `t()` type** so callers get a precise contract and
  required fields fail at construction, not three calls later.

## 5. OTP fundamentals

- **Model stateful, long-lived concerns as processes — `GenServer` is the default.** Reach for it
  when you need to *hold state*, *serialize access*, or *own a resource*; don't wrap pure functions
  in a process. Keep `handle_call/3` work short — offload slow work so the mailbox can't back up.
- **Everything runs under a supervision tree.** Your `Application.start/2` returns a root
  `Supervisor`; processes are started as children with explicit `child_spec`, never bare `spawn`.
  Pick the restart strategy deliberately — `:one_for_one` by default, `:rest_for_one`/`:one_for_all`
  only when children genuinely depend on each other.
  ```elixir
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      {MyApp.Worker, []}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
  ```
- **"Let it crash" — for the *unexpected*.** Don't defensively `rescue` programmer errors or
  corrupt state; let the process die and let the supervisor restart it from a known-good state.
  This is *not* a license to ignore *expected* failures, which you match and handle (§8).
- **Name and reach processes correctly** — `Registry` or `:via` tuples over global atoms; never
  build process names from user input (atoms aren't GC'd). Use `DynamicSupervisor` for
  runtime-spawned children (per-connection, per-job) and `Task.Supervisor` for supervised tasks.

## 6. Processes & concurrency

- **`Task.async_stream/3` for bounded parallel I/O** — it caps concurrency (`max_concurrency`),
  propagates failures, and applies back-pressure, unlike a naive `Enum.map` over `Task.async`.
  Always set a `:timeout` and decide `on_timeout:`.
  ```elixir
  urls
  |> Task.async_stream(&fetch/1, max_concurrency: 10, timeout: 5_000, on_timeout: :kill_task)
  |> Enum.reduce(...)
  ```
- **For data pipelines with back-pressure, use Broadway** (built on GenStage) — it handles
  batching, rate-limiting, acknowledgements, and graceful shutdown against SQS/Kafka/RabbitMQ. Use
  raw **GenStage** only when you need custom producer/consumer wiring Broadway doesn't cover.
  _(scale-up)_
- **Never share mutable state across processes** — pass immutable data in messages. Reach for
  **ETS** for shared read-heavy caches, not as a mutable global; size and own it under a process.
- **Bound every external call with the client's own timeout**, not a wrapping process. Retries,
  circuit breakers, and deadlines live in [../design/resilience.md](../design/resilience.md).

## 7. Pattern matching & `with`

- **Pattern-match in function heads and destructure at the boundary** — multiple clauses with
  guards beat nested `if`/`case`. Match the shape you expect; let a non-match crash loudly rather
  than silently coercing.
- **Use `with` to chain happy-path `{:ok, _}` steps** and funnel failures into one `else`. It's the
  idiom for "do these fallible steps in order, bail on the first error" — far clearer than nested
  `case`. Keep the `else` explicit so an unexpected error tag isn't swallowed.
  ```elixir
  with {:ok, user}  <- fetch_user(id),
       {:ok, cart}  <- load_cart(user),
       {:ok, order} <- checkout(cart) do
    {:ok, order}
  else
    {:error, :not_found} -> {:error, :user_missing}
    {:error, reason}     -> {:error, reason}
  end
  ```
- **Prefer `case`/`with` over `cond`** for tagged tuples; reserve `cond` for genuinely unrelated
  boolean branches. Don't over-match — destructure only the fields you use.

## 8. Error handling

- **Expected failures are values: return `{:ok, result}` / `{:error, reason}`** and let callers
  match. Reserve `raise`/exceptions for *exceptional, unrecoverable* conditions and programmer
  errors — not for control flow a caller is expected to handle.
- **Bang functions (`fetch!`) are the raising twin of a `{:ok, _}`/`{:error, _}` function** — offer
  both when it helps, but raise only where the caller can't sensibly recover (startup, scripts,
  invariant violations). Don't `rescue` your own bang in the same flow; call the non-bang version.
- **`{:error, reason}` uses a structured, matchable reason** (`:not_found`, `{:invalid, field}`) —
  never a bare string a caller must parse. Define custom exceptions with `defexception` for library
  boundaries so consumers can `rescue MyApp.Error`.
- **Don't `try/rescue` around expected errors** — it defeats supervision and hides the failure
  shape. Use `try/after` (or `Process.flag(:trap_exit, true)` deliberately) only for genuine
  resource cleanup. Validate input at the boundary and fail fast.

## 9. Testing

- **ExUnit, `async: true` by default.** Most tests share no global state and should run
  concurrently; mark `async: false` only when a test touches a global resource (some Ecto sandbox
  modes, application env, the registry). `setup`/`setup_all` over hand-rolled fixtures.
- **Mock *behaviours*, not modules — use Mox.** Define a behaviour, inject the implementation via
  application config, and `Mox.defmock` a test double against the behaviour so the mock can't drift
  from the real contract. Mox is concurrency-safe (`verify_on_exit!`, `set_mox_from_context`), so
  mocked tests stay `async: true`. Don't reach for runtime module-replacement libraries by default.
  ```elixir
  # test/support/mocks.ex
  Mox.defmock(MyApp.HTTPMock, for: MyApp.HTTPClient)
  # test
  expect(MyApp.HTTPMock, :get, fn _url -> {:ok, %{status: 200}} end)
  ```
- **Stub at the boundary** (HTTP, the clock, external services) and use **real processes inward** —
  start the GenServer under test, don't mock it. Use `start_supervised!/1` so ExUnit tears the
  process down between tests.
- **Keep tests deterministic** — no `:timer.sleep` to "wait for" async work; assert via
  `assert_receive`/message passing or a supervised, awaited `Task`. The pyramid and coverage policy
  live in [../practices/testing-strategy.md](../practices/testing-strategy.md).
- **`@tag`-gate slow/integration tests** (`mix test --exclude integration`) so the default run stays
  fast. `mix test --warnings-as-errors` in CI.

## 10. Ecto & data access

- **Schemas are data contracts; changesets are the validation boundary** — cast and validate every
  external input through a changeset, never insert a raw map. Keep query/transaction logic in
  context modules, not in web controllers.
- **Always use `Ecto.Multi` for multi-step writes** so they're atomic and the failing step names
  itself. Use the `Ecto.Adapters.SQL.Sandbox` (with `async: true` ownership) for DB-backed tests.
- **Migration, pooling, indexing, and N+1 depth lives in
  [../platform/database.md](../platform/database.md)** — don't restate it here.

## 11. Releases & runtime config

- **Ship a `mix release`**, not `mix run`/`Mix` in prod — Mix isn't available at runtime in a
  release. The release bundles the BEAM, your app, and remote-console/`eval`/`rpc` tooling.
  ```bash
  MIX_ENV=prod mix release          # build the self-contained release
  _build/prod/rel/my_app/bin/my_app start
  ```
- **All runtime config goes in `config/runtime.exs`** (evaluated when the release boots), read from
  the environment and **fail-fast on missing values** (`System.fetch_env!/1`). `config/config.exs`
  and `config/prod.exs` are *compile-time* only — secrets and per-deploy values must not live there
  or they bake into the artifact.
  ```elixir
  # config/runtime.exs
  if config_env() == :prod do
    config :my_app, MyApp.Repo,
      url: System.fetch_env!("DATABASE_URL"),
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  end
  ```
- **Run migrations from a release module/command**, not `mix ecto.migrate` (no Mix in the release).
  Set `:included_applications`/`runtime.exs` deliberately; pipeline and image build steps live in
  [../platform/ci-cd.md](../platform/ci-cd.md).

## 12. Telemetry & observability

- **Emit `:telemetry` events at meaningful boundaries** (request, query, job) — it's the
  ecosystem-standard instrumentation interface; libraries already emit it, so attach handlers
  rather than wrapping calls. Aggregate with **`telemetry_metrics`** + a reporter
  (`telemetry_metrics_prometheus`/StatsD).
- **Structured logging via the stdlib `Logger`** with metadata (`request_id`, `user_id`); set the
  JSON/structured formatter in prod. Never log secrets or full request bodies.
- _(scale-up)_ **Keep `runtime_tools` in the release** so you can attach `:observer`/`recon`
  to a live node; the BEAM's introspection is a first-class production debugging tool. Supply-chain
  scanning and secret policy live in [../practices/security.md](../practices/security.md).

## 13. Dependencies & supply chain

- **`mix.lock` is committed and law in CI** — for apps *and* libraries. `mix deps.get` installs from
  it, CI fails on drift, and `mix deps.unlock --unused` (§2) keeps it free of stale entries.
- **Scan the resolved graph in CI with `mix deps.audit`** — the **mix_audit** package, checked
  against the `elixir-security-advisories` DB; a matched CVE fails the build. Pair it with the
  built-in **`mix hex.audit`**, which flags **retired** packages you should move off.
- **Stay current:** add the **latest stable** Hex release, bump regularly (`mix hex.outdated`), and
  treat published advisories as priority work, not backlog.
- **The cross-cutting policy** — update **cooldown**, SBOM, signing/provenance — lives in
  [../practices/dependencies.md](../practices/dependencies.md) and
  [../practices/security.md](../practices/security.md); this doc doesn't restate it.

## Definition of done

- [ ] `.tool-versions` pins Elixir 1.18+ and OTP 27+; CI installs the same strings
- [ ] `mix deps.get` from a committed `mix.lock` (apps **and** libraries); `mix deps.unlock --unused` clean
- [ ] `mix format --check-formatted` clean; `mix compile --warnings-as-errors` passes
- [ ] `mix credo --strict` clean; inline disables scoped + justified
- [ ] `@spec` on public functions; `mix dialyzer` clean (PLT cached); no growing ignore file
- [ ] Stateful work runs under a supervision tree; restart strategy chosen deliberately; no bare `spawn`
- [ ] Expected failures return `{:ok, _}`/`{:error, reason}` with matchable reasons; `with`/`else` explicit
- [ ] `mix test` green, `async: true` where possible; behaviours mocked with Mox; `start_supervised!` for processes
- [ ] `mix deps.audit` clean; deps vetted; `mix hex.outdated` triaged
- [ ] Prod runs a `mix release`; all runtime config in `config/runtime.exs`, fail-fast on missing env
- [ ] `:telemetry` emitted at boundaries; structured `Logger` metadata; no secrets logged
