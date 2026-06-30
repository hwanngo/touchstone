# Monorepo Tooling Standards

The build tooling that makes one repository hold many packages without melting CI: the task graph,
caching, affected-only builds, workspace boundaries, and release. This doc owns the **tooling**;
the monorepo-vs-polyrepo *topology* decision (and the trade-off table) lives in
[git-workflow.md](../practices/git-workflow.md) §6 — defer there, don't re-litigate it here.
Package-manager choice and version policy live in [dependencies.md](../practices/dependencies.md);
the CI wiring (path filters, the aggregator, merge queues) in [ci-cd.md](ci-cd.md).

> **One law:** never rebuild or retest what didn't change — the task graph plus a remote cache is
> the whole game; everything else is plumbing around those two.

---

## 1. When a monorepo earns its keep

A monorepo is a tooling commitment, not a free `mkdir`. Adopt the tooling in this doc once the repo
holds **more than one independently buildable package** and the naïve "run everything on every PR"
loop has started to hurt. The *topology* call (one repo vs many) belongs to
[git-workflow.md](../practices/git-workflow.md) §6 — this doc assumes you've made it.

- **It pays off** when packages share code, refactors cross package boundaries, and you want one
  dependency graph and one atomic PR per change.
- **It doesn't** when components have genuinely independent release cadences, ownership, or security
  boundaries — that's a polyrepo signal, decided in [git-workflow.md](../practices/git-workflow.md).
- **The tipping point** is CI time: when a one-line change to one app reruns the entire suite, you
  need an affected-graph (§5), not a faster runner.

## 2. Tool choice by ecosystem

Pick one orchestrator and one package layer per repo; pinning both is non-negotiable (mixing two
task runners means two mental models and two cache stores).

| Layer | JS / TypeScript | Polyglot / scale | Notes |
|---|---|---|---|
| **Task runner** | **Turborepo** (default) · **Nx** (when you need generators/plugins) | **Bazel** / **Buck2** _(scale-up)_ | Owns the task graph + cache |
| **Package layer** | **pnpm** workspaces | uv (Python), go workspaces | Owns dependency resolution + linking |

- **Turborepo is the JS default.** It's a thin, config-light layer over your existing `package.json`
  scripts — adopt it when you mostly need caching + affected builds and don't want a framework.
- **Reach for Nx** when you want code generators, an enforced module-boundary lint
  (`@nx/enforce-module-boundaries`), and a richer plugin ecosystem — it's more opinionated and more
  to learn, so don't reach for it just for caching.
- **Bazel / Buck2 are the scale-up answer** _(scale-up)_ for polyglot trees (JS + Go + Python + C++)
  or thousands of targets needing hermetic, content-addressed, remote-executed builds. They are a
  large investment (BUILD files everywhere, a learning cliff) — adopt only when ecosystem-native
  tools genuinely can't span your languages.
- **The package layer is separate from the task runner.** pnpm/uv/go *workspaces* resolve and link
  dependencies; Turbo/Nx/Bazel *schedule and cache tasks* over them. You need both.

## 3. The task graph

Every task (`build`, `test`, `lint`) declares what it depends on, so the runner schedules
topologically — a package's `build` waits for its dependencies' `build` to finish and be cached.

```jsonc
// turbo.json — ^ means "this task depends on the same task in upstream package deps"
{
  "tasks": {
    "build": { "dependsOn": ["^build"], "outputs": ["dist/**"] },
    "test":  { "dependsOn": ["build"], "outputs": ["coverage/**"] },
    "lint":  { "dependsOn": [] }
  }
}
```

- **Declare dependencies explicitly** — the graph is only as correct as its edges; a missing `^build`
  edge means stale upstream artifacts and a flaky green.
- **Declare `outputs` precisely** — the runner caches exactly these paths; list too little and the
  cache restores an incomplete build, too much and you cache junk.
- **Tasks must be pure functions of their inputs** — same inputs → same outputs, no reaching outside
  the declared graph (network, `Date.now()`, machine state). Impurity is what makes a cache lie (§11).

## 4. Caching — local plus remote

A task's cache key is a hash of **all its inputs** — source files, dependency lockfile, the task's
config, environment variables it reads, and the keys of its upstream dependencies. Same key → the
runner replays stored stdout and `outputs` instead of re-running. This is the **single biggest
speedup** in a monorepo; everything else is rounding error.

- **Turn on the remote cache.** A local cache only helps one machine; a **remote cache** (Vercel
  Remote Cache / Nx Cloud / a self-hosted S3-backed store / Bazel remote cache) lets CI and every
  teammate reuse each other's build outputs — the first CI run warms it, the rest hit it.

  ```bash
  turbo run build --remote-only        # CI: read+write the shared cache, skip local
  nx affected -t build --cache         # Nx reads Nx Cloud automatically when configured
  ```

- **Get the cache key inputs right** — under-hashing (forgetting an env var the build reads) serves a
  stale artifact; over-hashing (hashing `node_modules/` or a timestamp) makes every key unique and
  the cache never hits. Hash the **lockfile**, never loose manifests (mirrors
  [ci-cd.md](ci-cd.md) §2).
- **Segregate untrusted writers** — a PR from a fork must not be able to poison the cache the release
  job reads. Make CI read-write but PR-from-fork read-only, or prefix keys by trust level (§11,
  [ci-cd.md](ci-cd.md) §4).

## 5. Affected / incremental builds

The point of the graph is to build and test **only what a change can reach** — the changed packages
plus everything downstream of them, nothing else.

| Tool | Affected command |
|---|---|
| **Turborepo** | `turbo run build test --filter=...[origin/main]` |
| **Nx** | `nx affected -t build test --base=origin/main` |
| **Bazel** | `bazel test $(bazel query 'rdeps(//..., set(<changed targets>))')` |

- **Compute "affected" against the merge base**, not the previous commit — a PR with three commits
  must consider everything changed since it forked from `main`, or it under-tests.
- **Filter forward (downstream), not just the changed package** — `--filter=...pkg` /
  `rdeps(...)` pulls in reverse dependencies, because a change to a shared lib can break its
  consumers even though the lib's own tests pass.
- **Affected is an optimization, not a correctness boundary** — a full `turbo run build` (no filter)
  must still be runnable and must still pass; the affected set only narrows *which* of those tasks
  CI bothers to run on a given PR.

## 6. Workspace layout & boundaries

```text
apps/          # deployable units — depend on packages/, never on each other
  web/
  api/
packages/      # shared libraries — versioned internally, no app imports
  ui/
  config/
```

- **`apps/` for deployables, `packages/` for shared libraries.** An app may depend on packages; a
  package must **never** import from an app, and apps should not import each other (extract the
  shared bit into a package instead).
- **No cross-package import without a declared dependency.** Reaching into another package's
  internals by relative path (`../../packages/ui/src/Button`) bypasses the graph, so the cache and
  affected calc miss it. Import via the package name; if there's no declared dep, the import is a bug.
- **Enforce the boundary in CI, don't trust convention** — `@nx/enforce-module-boundaries`,
  `eslint-plugin-boundaries`, or Bazel `visibility` rules fail the build on an illegal edge. An
  unenforced boundary erodes to spaghetti within a quarter.

## 7. Dependency management

| Policy | What it means | Use when |
|---|---|---|
| **Single-version** (default) | One version of each external dep across the whole repo | You want zero version skew and atomic upgrades |
| **Independent** _(scale-up)_ | Packages may pin different versions | Migrating a giant repo incrementally; teams on different cadences |

- **Default to a single-version policy.** One `react`, one `typescript` across the tree — it kills
  duplicate-bundle bloat and the "works in app A, breaks in app B" class of bug, and makes upgrades a
  single PR. Detail and rationale live in [dependencies.md](../practices/dependencies.md).
- **Use catalogs to centralize versions.** pnpm **catalogs** (`pnpm-workspace.yaml`) let every
  package reference `catalog:` instead of a literal version, so one edit bumps the whole repo:

  ```yaml
  # pnpm-workspace.yaml
  catalog:
    react: 19.2.0
    typescript: 5.9.3
  ```

- **Encode the policy as a constraint, enforced in CI** — Nx `lint` rules, pnpm
  `overrides`, or a `syncpack` check fail the build when two packages disagree on a version, so the
  single-version policy is a gate, not a hope.

## 8. Versioning & release

- **JS monorepos: use Changesets.** Each PR adds an intent file (`.changeset/*.md`) declaring which
  packages bump and by how much; the release action aggregates them into version bumps + a generated
  `CHANGELOG.md` + a publish. It's the only per-package release tool that handles a JS workspace
  cleanly. The git-side release strategy (tags, SemVer derivation) lives in
  [git-workflow.md](../practices/git-workflow.md) §4.
- **Pick independent vs locked versioning deliberately.** *Independent* (each package versions on its
  own) suits a library collection where consumers pin individual packages; *locked / fixed* (all
  packages share one version) suits an app suite shipped as a unit. Don't default to independent for
  internal-only packages — it adds version-matrix overhead nobody consumes.
- **Internal-only packages don't need to publish.** Mark them `"private": true` and reference by
  `workspace:*`; only packages with external consumers go through the publish flow.

## 9. CI integration

The CI mechanics — path-filtered triggers, the `ci-required` aggregator, merge queues — are
specified in [ci-cd.md](ci-cd.md) §3–§4. The monorepo-specific policy layered on top:

- **Run affected-only on PRs, full on `main`.** PRs run `turbo run … --filter=...[origin/main]`;
  the post-merge / nightly build runs the full graph so nothing rots behind a stale cache.
- **Persist the remote cache across CI runs** — point CI at the shared cache (§4) so the first job
  warms it and parallel/later jobs replay it. Without this, CI re-does work every run.
- **Shard wide test suites** _(scale-up)_ — split the affected test set across N runners
  (`nx affected --parallel` / matrix shards) when even the affected suite is slow; the aggregator
  in [ci-cd.md](ci-cd.md) §4 is what branch protection requires, not the individual shards.

## 10. Code ownership

- **`CODEOWNERS` by path is the ownership map.** In a monorepo the directory *is* the boundary, so
  route review with path-keyed `CODEOWNERS` — keyed to **teams, not individuals**, most-specific path
  winning, with a catch-all fallback (`* @org/core`). Validate it in CI; invalid lines are silently
  ignored. Mechanics in [ci-cd.md](ci-cd.md) §8 and [collaboration.md](../practices/collaboration.md).

  ```text
  /apps/web/        @org/web
  /packages/ui/     @org/design-systems
  *                 @org/core
  ```

## 11. Pitfalls

- **Cache poisoning.** An untrusted PR writing to the shared cache can substitute a malicious
  artifact a later trusted job replays. Segregate writers by trust (§4) and keep PR-from-fork caches
  read-only — same supply-chain logic as [ci-cd.md](ci-cd.md) §4.
- **Non-deterministic inputs.** A task that reads the clock, the network, an undeclared env var, or
  absolute paths produces outputs that don't match its key — you get false cache hits (stale output)
  or false misses (never caches). Make tasks pure (§3); pin toolchain versions in the hashed inputs.
- **The giant-checkout problem.** Past tens of GB, a full clone is a per-dev, per-CI tax. Clone
  blobless + sparse and expand to the paths you touch — the technique and command live in
  [git-workflow.md](../practices/git-workflow.md) §6 _(scale-up)_:

  ```bash
  git clone --filter=blob:none --sparse git@github.com:org/monorepo.git
  cd monorepo && git sparse-checkout set apps/web packages/ui
  ```

- **Implicit cross-package coupling.** Tests that pass only because of build order, or shared global
  state between packages, hide broken edges the graph can't see. Enforce boundaries (§6) and treat a
  full-graph build as the source of truth (§5).

## Definition of done

- [ ] One task runner pinned (Turborepo/Nx for JS; Bazel/Buck2 only at polyglot scale) over one package layer (pnpm/uv/go workspaces)
- [ ] Every task declares `dependsOn` edges and precise `outputs`; tasks are pure functions of declared inputs
- [ ] Remote cache enabled and shared by CI + developers; cache keys hash the lockfile (not loose manifests); untrusted writers segregated
- [ ] PRs build/test the affected set against the merge base (downstream included); full graph still builds on `main`
- [ ] Layout is `apps/` + `packages/` with no app→app or relative cross-package imports; boundaries enforced by a lint/visibility gate in CI
- [ ] Single-version dependency policy via catalogs, enforced as a CI constraint (independent only with a documented reason) _(scale-up)_
- [ ] JS releases via Changesets with generated `CHANGELOG.md`; independent-vs-locked versioning chosen deliberately; internal packages `private`
- [ ] CI runs affected-only on PRs with a persisted remote cache; wide suites sharded; the aggregator is the sole required check _(scale-up)_
- [ ] `CODEOWNERS` keyed to teams by path, with a fallback, validated in CI
- [ ] Large trees use sparse + `--filter=blob:none` checkout; tasks have no non-deterministic inputs _(scale-up)_

**Sources:** [Turborepo: caching](https://turborepo.com/docs/crew/caching) · [Nx: affected](https://nx.dev/ci/features/affect) · [pnpm catalogs](https://pnpm.io/catalogs) · [Changesets](https://github.com/changesets/changesets) · [Bazel remote caching](https://bazel.build/remote/caching)
