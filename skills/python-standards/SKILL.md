---
name: python-standards
description: Use when writing, reviewing, testing, formatting, or configuring any Python code in a repo that follows touchstone (uv, ruff, pytest, Pyright). Invoke before adding deps, editing tests, touching imports/sys.path, or changing deterministic output.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Python Standards

Full standard: **`standards/languages/python.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **uv only** (`uv add`/`sync`/`run`). Never pip. Commit `uv.lock` with `pyproject.toml`; CI runs `uv lock --check`.
- Format + lint with **ruff** (expanded rule set incl. `B`/`S`/`UP`/`SIM`/`PTH`/`DTZ`); CI enforces `ruff check` + `ruff format --check`.
- Type-check (**Pyright**/mypy). "Could not be resolved" → fix the import-root config, not the code.

## Don't get burned
- **Async:** never block inside `async def` (offload via `asyncio.to_thread`/anyio); `asyncio.TaskGroup` + `asyncio.timeout()`; don't mix sync/async DB drivers. Enable ruff `ASYNC` rules.
- **Validation:** pydantic v2 at external boundaries (+ `pydantic-settings` for config); `@dataclass(slots=True, frozen=True)` for internal value objects.
- **Tests self-skip when fixtures are absent** (`@unittest.skipUnless(...)`, `if ran == 0: self.skipTest(...)`) — never hard-assert on missing seed/sample data.
- **Never remove "unused" imports from re-export/facade modules** — intentional (`per-file-ignores`); removing breaks consumers.
- Harden pytest: `--strict-markers --strict-config`, `xfail_strict`, `filterwarnings=["error"]`, branch-coverage floor.
- Changing deterministic output ⇒ regenerate the golden + explain.
- `uvx pip-audit` clean.

## Done
`ruff check` + `ruff format --check` clean · type-checker clean · `pytest` green (coverage ≥ floor) · `uv lock --check` passes.
