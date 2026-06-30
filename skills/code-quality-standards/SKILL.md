---
name: code-quality-standards
description: Use when writing, refactoring, or reviewing any code in a touchstone repo regardless of language — naming, function/file size, single responsibility, simplicity (KISS/YAGNI/DRY), guard clauses, error-handling philosophy, comments, and anti-sprawl. Boundary: per-language formatting/linting lives in the language skills (python/go/shell/…); PR/review process in code-review; test doubles in testing-strategy.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Code Quality (practice)

Full standard: **`standards/practices/code-quality.md`** in the touchstone repo. This skill inlines the
load-bearing, language-agnostic rules so it stays useful when installed standalone in
`~/.claude/skills/`:

## Always
- **Read before you write** — load the README + surrounding code; match the local idiom; grep for an
  existing helper before adding a parallel one.
- **Intention-revealing names** — no abbreviations, no `util`/`Manager` filler; descriptive,
  kebab-case file names (defer casing to per-language convention).
- **One thing per unit** — small functions, single responsibility; treat the size/nesting/param
  ceilings as smells, not caps.
- **Keep it simple** — KISS/YAGNI; DRY only after the **rule of three**; delete before you add.
- **Flat happy path** — guard clauses + early returns; no `else` after a `return`.
- **Fail fast at the boundary** — validate untrusted input once at the edge; **no catch-log-continue**,
  no swallowed errors.
- **Comments say *why*** — no commented-out code; no deferral markers without a tracked issue.

## Defer, don't restate
- Per-language formatting / linting / line-length / error mechanics → the language skills
  (`python.md`, `golang.md`, `shell.md`).
- PR size, review priority, comment prefixes → `code-review.md`.
- What to mock, fakes-over-mocks, test data → `testing-strategy.md`.
- Docstring style, doc-as-code → `documentation.md`; file-sprawl-vs-git policy → `collaboration.md`.

## Done
Names reveal intent · units do one thing · simplest design (abstraction earned) · flat happy path ·
boundary validation, no swallowed errors · comments explain *why*, no dead/commented-out code · no fake-pass
stubs · edits over `-v2` duplicates. See `standards/practices/code-quality.md`.
