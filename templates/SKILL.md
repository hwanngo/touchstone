---
name: example-standards
description: Use when <triggering situation> in a touchstone repo — <what it covers>. Triggers on <file globs / deps / signals>. <Boundary: what this is NOT; point to sibling skills>.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Example (language|framework|platform|practice)

<!-- Canonical SKILL.md template. Copy to skills/<name>/SKILL.md, set name == directory,
     keep the spine: Full standard pointer -> ## Always -> one domain section -> ## Done.
     Validated by scripts/check-skills.sh. See CONTRIBUTING.md "Authoring conventions". -->

Full standard: **`standards/<domain>/<file>.md`** (layers on `standards/languages/<lang>.md`).
This skill inlines the load-bearing rules so it stays useful when installed standalone in
`~/.claude/skills/`:

## Always
- **<tool/command>** — <the non-negotiable, one clause why>.
- <invariant 2>.

## Don't get burned
<!-- Domain-specific middle section. Rename to fit (e.g. "Defer", "Migrations", "AuthN/AuthZ"),
     but keep exactly one and keep it scannable. -->
- <the sharp-edge / footgun rules a senior would flag>.

## Done
<gate1 · gate2 · gate3 — the exact definition of done>. See `standards/<domain>/<file>.md`.
