---
name: monorepo-standards
description: Use when setting up or scaling a monorepo's build tooling — task graph, caching, affected/incremental builds, workspace boundaries, and release — in a touchstone repo. Triggers on turbo.json, nx.json, WORKSPACE/BUILD (Bazel/Buck2), pnpm-workspace.yaml, go.work, or an apps/ + packages/ layout. The monorepo-vs-polyrepo topology decision lives in the git-workflow skill; CI wiring in the ci-cd skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Monorepo Tooling Standards

Full standard: **`standards/platform/monorepo.md`** in the touchstone repo (defers the
monorepo-vs-polyrepo topology call to `practices/git-workflow.md` §6, CI wiring to
`platform/ci-cd.md`, package/version policy to `practices/dependencies.md`). This skill inlines the
load-bearing rules so it stays useful when installed standalone in `~/.claude/skills/`:

## Always
- **One task runner over one package layer** — Turborepo (default) or Nx for JS/TS over pnpm workspaces; Bazel/Buck2 only for polyglot scale. Pin one; never mix two runners.
- **Explicit task graph** — every task declares `dependsOn` (`^build` for upstream deps) and precise `outputs`; tasks are pure functions of their declared inputs, or the cache lies.
- **Remote cache, shared by CI and developers** — the single biggest speedup; cache keys hash the lockfile, never loose manifests; segregate untrusted (fork-PR) writers to read-only.
- **Affected-only on PRs** — `turbo run … --filter=...[origin/main]` / `nx affected --base=origin/main`, computed against the merge base and pulling in downstream consumers. Full graph still builds on `main`.
- **`apps/` + `packages/` with enforced boundaries** — no app→app imports, no relative cross-package reaches; import by package name behind a declared dep; a lint/visibility gate fails illegal edges in CI.

## Don't get burned
- **Cache poisoning** — a fork PR writing the shared cache can substitute an artifact a trusted job replays; keep fork-PR caches read-only (mirrors ci-cd §4).
- **Non-deterministic inputs** — clock/network/undeclared-env reads break the key into false hits (stale) or false misses (never caches); pin toolchain versions into the hashed inputs.
- **Giant checkout** — past tens of GB, clone blobless + sparse (`git clone --filter=blob:none --sparse` then `git sparse-checkout set …`); see git-workflow §6.
- **Single-version drift** — use pnpm catalogs and enforce one version per dep as a CI constraint, not a convention.

## Done
One pinned runner + package layer · explicit `dependsOn`/`outputs` · shared remote cache with lockfile-hashed keys · affected-on-PR + full-on-`main` · enforced `apps/`+`packages/` boundaries · single-version catalogs · Changesets release · CODEOWNERS by path. See `standards/platform/monorepo.md`.
