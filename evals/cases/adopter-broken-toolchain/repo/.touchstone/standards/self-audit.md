# Self-Audit Checklist

Run this to measure this repo against the vendored standards. Score each item, then turn the gaps
into issues.

## Python

- [ ] Managed with **uv**; `uv.lock` committed; CI runs `uv sync --locked`
- [ ] **ruff** check + format clean in CI
- [ ] Type checker configured (Pyright/mypy)
- [ ] pytest hardened (`--strict-markers --strict-config`)

## Repo hygiene

- [ ] Task runner (`just`) with the `setup/lint/fmt/test/build/ci` contract
- [ ] `.editorconfig` + `.gitattributes`
- [ ] pre-commit config with hook ids valid at their pinned revs
