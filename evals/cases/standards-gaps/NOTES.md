# Maintainer notes — standards-gaps

`scripts/check-evals.sh`'s leak check (added alongside `evals/cases/adopter-broken-toolchain`'s
fix — see that case's `NOTES.md` for the full rationale) also fired on this case: `repo/`'s
`pyproject.toml`, `scripts/setup.sh`, `.github/workflows/ci.yml`, `README.md`, `tests/test_health.py`
and `src/widget_api/__init__.py` all named this case (`evals/cases/standards-gaps`) or the literal
word "fixture" in a way that handed an agent under test the answer key. That provenance is moved
here rather than deleted.

## The four catalogued, required defects

- No `uv.lock` committed alongside `pyproject.toml`, though the project declares itself uv-managed
  (`[dependency-groups]`, `[tool.ruff]`) — violates
  `.touchstone/standards/languages/python.md`'s L1 item "Managed with uv; `uv.lock` committed; CI
  runs `uv sync --locked` + `uv lock --check`".
- `.github/workflows/ci.yml` pins every action to a mutable tag (e.g. `actions/checkout@v7`), not a
  commit SHA — `pinact run` was never run after this CI starter (adapted from
  `templates/github/workflows/ci.yml`) was copied in. Violates `ci-cd.md`'s "Pin every action to a
  full commit SHA" (never `@v4`/`@main`/any other floating tag).
- `scripts/setup.sh` calls `pip install` directly, contradicting the uv-managed toolchain declared
  in `pyproject.toml` — violates `.touchstone/standards/languages/python.md`'s toolchain rule:
  "Package / env manager: uv. Never pip, poetry, pipenv, or a hand-rolled venv."
- No `SECURITY.md` at the repo root.

## The 18 catalogued `optional` entries

Unchanged by this cleanup — see `answer-key.txt` and `evals/BASELINE.md`'s "standards-auditor vs
evals/cases/standards-gaps" section for how they were adjudicated (all 18 true, zero
hallucinations, on the blind run that found them).

## What was NOT touched

`repo/.touchstone/standards/self-audit.md` contains the line `**Data-dependent tests self-skip**
when fixtures absent` — the word "fixture" there is ordinary testing vocabulary (pytest fixtures),
not a leak of this case's own identity, and it is real content copied from this kit's own
`standards/self-audit.md`. The leak check in `scripts/check-evals.sh` deliberately does not use a
bare "fixture" marker for exactly this reason: a bare-word marker flags this line, which is genuine
vendored standards content and gives an agent under test nothing about this case's identity. The
markers it does use — `fixture repo` and `(fixture)`, alongside `evals/cases/`, the case id,
`answer-key`, `eval case`, `DELIBERATELY BROKEN` and `reproducing a real` — catch every leak this kit
has actually shipped without that false positive. See that script's own comments for the full list.

## `reference-findings.txt`

Committed verbatim from the blind run scored in `evals/BASELINE.md`'s "standards-auditor vs
evals/cases/standards-gaps" section — `agent: standards-auditor`, model **sonnet**, run
**2026-08-17**. `.github/workflows/eval.yml` replays this file through `scripts/score-eval.sh` on a
schedule; that only proves `answer-key.txt` and the scorer still agree on this frozen text, not that
`agents/standards-auditor.md` would still find these defects today — see `evals/README.md`.
