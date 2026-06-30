# Python Standards

Applies to any Python project/package. Python is managed end-to-end with **uv**, formatted
and linted with **ruff**, type-checked with **Pyright**, and tested with **pytest**.

---

## 1. Toolchain

| Concern | Tool | Notes |
|---|---|---|
| Python version | **Latest stable** | Declared in `pyproject.toml` (`requires-python`). `uv` installs/pins it. |
| Package / env manager | **uv** | Never `pip`, `poetry`, `pipenv`, or a hand-rolled venv. |
| Formatter + linter | **ruff** | Config in `pyproject.toml` (`[tool.ruff]`). |
| Type checker | **Pyright** (default) | mypy only for a plugin you need (§4). Config in `pyrightconfig.json` / `pyproject.toml`. |
| Test runner | **pytest** | Tests under `tests/`. |
| Web apps | ASGI (any framework) | Serve with a production ASGI server in containers. |

## 2. Everyday commands

```bash
uv sync                       # create/update the venv from the lockfile
uv run <entrypoint>           # run the app
uv run pytest -q              # run the test suite
uv run ruff format .          # auto-format
uv run ruff format --check .  # verify formatting (what CI runs)
uv run ruff check .           # lint
uv run ruff check . --fix     # lint + safe autofixes
uvx pyright                   # type-check (or: uv run mypy)
```

Add a dependency with `uv add <pkg>` (runtime) or `uv add --dev <pkg>` (dev). This updates
`pyproject.toml` **and** `uv.lock` together — commit both.

### Dependency groups (PEP 735)

`uv add --group <name> <pkg>` writes the standard **`[dependency-groups]`** table (PEP 735) —
non-publishable, never installed by `pip install yourpkg`. `--dev` is an alias for the `dev`
group, which `uv sync` installs **by default**; other groups are opt-in.

- **Split dev tooling into focused groups** so CI jobs install only what they need:
  ```bash
  uv add --group lint ruff
  uv add --group typecheck pyright
  uv add --group docs mkdocs-material
  uv sync --group lint        # install one group; --no-default-groups to skip dev
  ```
- **Migrate legacy `[tool.uv.dev-dependencies]`** to `[dependency-groups]` (`dev` group). While
  the legacy table exists, `uv add --dev` keeps writing to it and the two are *merged* — move the
  entries once, then delete the old table so there's a single source of truth.

## 3. Formatting & linting (ruff)

- **Formatting is automated and non-negotiable.** Use `ruff format`; never hand-format.
  Line length **88** (ruff/Black default) unless the project sets otherwise.
- **CI enforces both** `ruff check` and `ruff format --check`. A red lint = a red build.
- **Enable more than the `E`/`F` default** — each group below catches a real bug class in CI
  instead of review, at near-zero cost. Use an explicit `select` (auditable) and pin
  `target-version` so rewrite rules only target your supported floor:
  ```toml
  [tool.ruff]
  target-version = "py312"
  [tool.ruff.lint]
  select = ["E","F","W","I","B","C4","UP","SIM","PT","S","RUF","ASYNC",
            "PIE","PTH","RET","TID","TC","FA","PERF","DTZ","ISC","G","LOG"]
  [tool.ruff.lint.per-file-ignores]
  "tests/**" = ["S101"]   # allow assert in tests (bandit S)
  ```
  Keep `target-version` in sync with your `requires-python` floor (§1), or **omit it** — ruff
  infers it from `requires-python` automatically. Only pin it explicitly when the two must differ.
  Highlights: `B` (mutable defaults, loop-closure bugs), `S` (bandit security), `DTZ` (naive
  datetimes), `PTH` (os.path → pathlib), `PERF` (accidental O(n²)), `UP` (modern syntax),
  `SIM`/`C4` (review-noise removal), `ASYNC` (blocking calls inside `async def` — §7). Fix
  findings — don't blanket-ignore.
- **Encode intentional structural patterns as `per-file-ignores`** in `pyproject.toml`
  (with a one-line comment each), not scattered `# noqa`. Common legitimate cases:
  - **`sys.path` bootstrapping before imports** (`E402`) — entry points / test bootstraps.
  - **Star-import "facade" modules** (`F403`/`F405`) — packages that re-aggregate submodules;
    guard the public surface with a namespace test.
  - **Re-export modules** (`F401`) — modules that import names purely to re-export them.
    **Don't "clean up" these imports** — removing a re-export silently breaks its consumers.
- A genuinely unused import/variable is a defect — remove it. Reserve the ignore list for the
  structural cases above.

## 4. Type checking

- Configure import roots for the project's layout (e.g. Pyright `extraPaths`) so the checker
  resolves first-party imports. "Import could not be resolved" in the IDE is usually a
  **path-config** issue — Pyright can't follow runtime `sys.path` mutations. Fix the config,
  don't restructure working code; reload the language server afterward.
- Annotate new public functions. Prefer narrowing the *value* (`if err is not None:`) over a
  correlated boolean so the checker can follow your intent.

### Pyright vs mypy

- **Default to Pyright** — fast, no plugins, ships in the editor (Pylance). New code starts at
  `typeCheckingMode = "strict"`; **ratchet strict per-directory** so legacy modules stay `basic`
  while new code is held to the bar:
  ```toml
  [tool.pyright]
  typeCheckingMode = "basic"
  executionEnvironments = [{ root = "src/newpkg", typeCheckingMode = "strict" }]
  ```
- **Choose mypy only for a plugin you actually need** — `pydantic.mypy`, `sqlalchemy[mypy]`,
  `django-stubs`. These teach the checker framework-specific semantics Pyright can't infer.
- **Don't run both.** Two checkers double the CI cost and disagree at the edges; pick one per repo.

### Modern typing

- **Built-in generics and unions:** `list[int]`, `dict[str, int]`, `X | None` — not `List`,
  `Dict`, `Optional` (the `UP` ruff rules autofix these).
- `from __future__ import annotations` **only** when you support <3.10 or genuinely need lazy
  annotation evaluation — it's not a blanket default and breaks runtime annotation introspection
  (e.g. pydantic, dataclasses with `eval`-based resolution).
- Pull newer constructs (`Self`, `override`, `TypeIs`, `assert_never`) from **`typing_extensions`**
  so they work below the version that added them; switch to `typing` once your floor catches up.

## 5. Testing

- **Framework:** `pytest` (it discovers `unittest.TestCase` classes too).
- **Tests that need data fixtures must self-skip when the data is absent — never hard-fail.**
  CI runs on a clean checkout; gitignored seeds/fixtures won't be there. Patterns:
  - `@unittest.skipUnless(<fixture_available()>, "reason")` for DB/seed-dependent tests.
  - `if ran == 0: self.skipTest(...)` instead of asserting a count when iterating fixtures.
  - `@unittest.skipUnless(os.path.exists(<path>), "reason")` for binary/external deps.
- **Golden / snapshot tests:** if output is deterministic, assert it byte-for-byte against a
  committed fixture, plus a repeat-run determinism test. Changing output on purpose ⇒
  regenerate the golden **in the same PR** and explain why.
- **`xfail` is a tripwire, not a TODO graveyard.** Use it only for a known, deliberate gap
  (awaiting a decision or upstream fix) — never to silence a real regression.
- Write the test first for new behaviour and bugfixes (TDD). Keep tests deterministic — no
  wall-clock or network dependencies.
- **Harden the pytest config** — these are cheap, high-signal forcing functions:
  ```toml
  [tool.pytest.ini_options]
  addopts = "-ra --strict-markers --strict-config"
  testpaths = ["tests"]
  xfail_strict = true              # an xfail that passes = failure (pairs with the tripwire rule)
  filterwarnings = ["error"]       # DeprecationWarnings become red CI before the dep removes them
  markers = ["slow: long-running", "integration: needs external services"]
  ```
  `--strict-markers` turns a typo'd `@pytest.mark.slo` (a silent no-op) into an error;
  `filterwarnings=error` surfaces upstream deprecations *before* the upgrade breaks you (keep a
  documented allowlist for noisy third-party warnings).
- **Coverage as a ratchet, not a vanity number:** `pytest-cov` with **branch** coverage and a
  `--cov-fail-under` floor (start ~80, ratchet up). Branch coverage catches untested `if/else`
  arms that line coverage misses.
- **Run order-randomized and parallel** (`pytest-randomly` + `pytest-xdist -n auto`): random
  order surfaces hidden inter-test coupling *as failures*; parallelism cuts wall-clock. The
  failures are the feature — they pair naturally with the determinism rule above.

## 6. Project layout & imports

- Prefer an installable package (`src/` layout) so imports resolve without `sys.path` hacks.
  When a project runs **as scripts** instead, keep import-root conventions consistent and
  documented, and bootstrap `sys.path` only in entry points / test setup.
- **`src/` layout needs a real build backend** — a minimal `hatchling` (or uv's `uv_build`)
  block makes the package installable so tests import the *installed* copy, not the source tree:
  ```toml
  [build-system]
  requires = ["hatchling"]
  build-backend = "hatchling.build"

  [project]
  name = "mypkg"
  requires-python = ">=3.12"
  dynamic = ["version"]

  [tool.hatch.build.targets.wheel]
  packages = ["src/mypkg"]
  ```
  Point pytest at the installed package with **`importmode=importlib`** (no `__init__.py` in
  `tests/`, no `sys.path` shimming):
  ```toml
  [tool.pytest.ini_options]
  importmode = "importlib"
  ```
- Keep request/IO handlers thin; push logic into well-named modules. Validate input at the
  boundary and **fail fast with the correct status code** before starting expensive work.
- Prefer `except Exception:` over bare `except:`; catch the narrowest type you can. `except
  Exception` is the right floor precisely because it **excludes `KeyboardInterrupt` and
  `SystemExit`** (they derive from `BaseException`) — a bare `except:` swallows Ctrl-C and
  `sys.exit()`, hanging the process. Never broaden to `except BaseException` to "be safe".
- **No catch-log-continue.** A handler that logs and falls through hides failures and corrupts
  downstream state. Either **re-raise** (`raise` / `raise NewError() from err`), record the
  failure as a real result the caller checks, or don't catch it.
- **Narrow, deliberate ignores** use `contextlib.suppress(SpecificError)` — clearer than an
  empty `except SpecificError: pass`, and it can't accidentally hide a second exception type.
- **Surface `ExceptionGroup`/`except*`** from `asyncio.TaskGroup` (§7): one failed child cancels
  the siblings and re-raises the group. Handle it with `except* SomeError:` — a plain
  `except SomeError:` won't match a group and the error escapes unhandled.
- Don't duplicate modules; if duplicates exist, consolidate rather than letting them drift.

## 7. Async (the doc mandates ASGI — §1; this is the contract)

The event loop is single-threaded: one blocking call stalls **every** in-flight request. The
ruff `ASYNC` ruleset (§3) is the enforcement layer for most of these rules.

- **Never call blocking I/O inside `async def`** — no `requests`, sync DB drivers, `time.sleep`,
  `open()`/`pathlib` reads, or CPU-bound loops. Use an async client (`httpx.AsyncClient`,
  `asyncpg`) or offload the blocking call to a thread:
  ```python
  result = await asyncio.to_thread(blocking_fn, arg)      # stdlib
  result = await anyio.to_thread.run_sync(blocking_fn, arg)  # anyio
  ```
- **Structured concurrency with `asyncio.TaskGroup`** (3.11+). It awaits all children, and on any
  failure cancels the siblings and raises an `ExceptionGroup` (handle with `except*` — §6):
  ```python
  async with asyncio.TaskGroup() as tg:
      tg.create_task(fetch(a))
      tg.create_task(fetch(b))
  ```
  **No bare `create_task` without keeping a reference** — the loop only holds a *weak* ref, so a
  fire-and-forget task can be GC'd mid-flight and vanish silently. Use a TaskGroup, or hold the
  task in a set and discard on completion.
- **Bound every await with `asyncio.timeout()`** (3.11+) at the call site — an un-timed `await`
  on a network/DB op can hang a worker forever:
  ```python
  async with asyncio.timeout(5):
      await client.get(url)
  ```
- **Don't mix sync and async DB drivers** in one path — a sync driver inside the loop blocks it,
  and a sync/async split fractures connection pooling and transactions. Pick the async stack
  (`asyncpg` / SQLAlchemy async) end-to-end. See [database.md](../platform/database.md).
- **Library code: prefer `anyio`** (`to_thread.run_sync`, `create_task_group`, `move_on_after`)
  so it runs on both asyncio and Trio — don't hard-couple a reusable package to one backend.
- Timeouts and cancellation are the async face of the resilience rules in
  [resilience.md](../design/resilience.md).

## 8. Validation & data models

Mirror the boundary rule from [react.md](../frameworks/react.md) (Zod at the edge): parse
untrusted input into typed objects **once, at the boundary**; trust the types inward.

| Use | Tool | Why |
|---|---|---|
| External / untrusted input (request bodies, webhooks, API responses) | **pydantic v2 `BaseModel`** | Runtime validation + coercion at the boundary; fail fast with a clear error. |
| App / service configuration | **`pydantic-settings`** | Typed, validated env/`.env` loading — no scattered `os.environ` reads. |
| Internal value objects (already-trusted data) | `@dataclass(slots=True, frozen=True)` | Zero-dependency, immutable, low-overhead; no validation tax on trusted paths. |

- **Don't validate trusted internal data with pydantic** on hot paths — the coercion cost is real;
  a frozen slotted dataclass is the right tool once data is past the boundary.
- `frozen=True` makes value objects hashable and prevents accidental mutation; `slots=True` cuts
  memory and blocks typo'd attribute assignment.

## 9. Profiling & performance

- **Profile before optimizing** — measure the actual hot path; never guess. Optimize the function
  the profiler names, then re-measure.
- **CPU:** `cProfile` (deterministic, stdlib) for a function-level breakdown; **`py-spy`** to
  sample a *running* process (incl. prod) with no code changes or restart.
- **Memory:** `tracemalloc` (stdlib, allocation tracebacks) for leaks; **`memray`** for deep
  heap/allocation flamegraphs.
- **Reach for stdlib/algorithmic fixes before native code** — the right data structure or removing
  an accidental O(n²) (ruff `PERF`, §3) usually beats a premature C/Rust extension, which adds
  build, packaging, and portability cost.

## 10. Security, dependencies & enforcement

- **Lockfile is law in CI.** Use `uv lock --check` (fails if `uv.lock` is stale vs
  `pyproject.toml`) and `uv sync --locked` (errors on drift) — don't let CI silently re-lock
  and ship an untested dependency graph.
- **Vulnerability scanning:** run `uvx pip-audit` in CI against the resolved environment; the
  ruff `S` rules add static SAST in the same lint pass. See [security.md](../practices/security.md).
- **Dependency updates** via Dependabot/Renovate with a cooldown (see [security.md](../practices/security.md)).
- **Logging:** libraries use stdlib `logging` + a `NullHandler` on the package logger and
  **never** configure handlers (that hijacks the consumer's setup); applications configure
  structured JSON logging (e.g. `structlog`) with correlation IDs bound at the request edge.
- **Enforce locally with pre-commit** (ruff-check → ruff-format → `uv-lock` hooks) so CI rarely
  fails on style. See [ci-cd.md](../platform/ci-cd.md).
- **Distributable packages:** build with `uv build`, validate with `uvx twine check dist/*`,
  publish via OIDC trusted publishing (no long-lived token); emit an SBOM
  (`uv export --format cyclonedx1.5`).

## Definition of done

- [ ] `ruff check .` clean (with the expanded rule set, incl. `ASYNC`)
- [ ] `ruff format --check .` clean
- [ ] Type checker has no new errors (new code at Pyright `strict`)
- [ ] No blocking I/O inside `async def`; awaits are timeout-bounded; tasks owned by a TaskGroup
- [ ] Untrusted input parsed into a pydantic model at the boundary; config via `pydantic-settings`
- [ ] `pytest` green (fixtures present; 0 unexpected skips), coverage ≥ floor
- [ ] `uv lock --check` passes; new deps added via `uv add`, `uv.lock` committed
- [ ] `pip-audit` clean (or advisories triaged)
- [ ] Any deterministic-output change ships with a regenerated golden + rationale
