---
name: documentation-standards
description: Use when writing or updating a README, docs/, runbooks, API/reference docs, diagrams, docstrings, or the changelog in a touchstone repo — anything docs-as-code. Triggers on README.md, docs/**, *.mmd/mermaid blocks, CHANGELOG.md, docstring/comment edits. Boundary: ADR *process* lives in collaboration-standards, *when* to ADR in architecture; runbook/observability content in devops-standards; API contract in api-design-standards.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Documentation

Full standard: **`standards/practices/documentation.md`** in the touchstone repo.
This skill inlines the load-bearing rules so it stays useful when installed standalone in
`~/.claude/skills/`:

## Always
- **A doc that contradicts the code is a bug** — update docs in the *same PR* as the behaviour,
  and delete docs for deleted features.
- **Docs as code**: live in-repo under `docs/` (README is the entry point), reviewed via PR + CI +
  CODEOWNERS — not a wiki that drifts.
- **README is a contract**: quickstart uses the task-runner targets (`just setup`/`test`/`run`)
  and is CI-executed where practical.
- **Reference is generated, not hand-typed**: from the API contract or docstrings (Redocly/TypeDoc/
  Sphinx/`go doc`/rustdoc), built in CI with **warnings-as-errors**.
- **Diagrams as code** — Mermaid by default (D2/PlantUML/C4 escape hatch); never a binary blob as source.
- **Comments explain *why*, not what**; docstring style enforced by the stack linter (Ruff `D` /
  tsdoc / `go vet` / clippy), not review nags.

## Defer, don't restate
- ADR **process** → `collaboration.md` §6; *when* to ADR → `architecture.md` §4.
- API **contract** (OpenAPI/proto/SDL source of truth) → `api-design.md`.
- Runbooks / SLOs / observability → `devops.md` §7–8.
- `CHANGELOG.md` (Keep a Changelog, generated from Conventional Commits) → `ci-cd.md` §11.

## Done
README quickstart CI-executed · reference generated + built warnings-as-error · Mermaid diagrams-as-code ·
markdownlint + link-check green in pre-commit/CI · docs changed in the same PR as the behaviour. See `standards/practices/documentation.md`.
