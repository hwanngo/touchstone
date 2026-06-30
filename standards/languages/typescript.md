# TypeScript Standards

How to write good TypeScript — the **language layer**, true for any TS project regardless of
framework. Building on top of a framework? Defer framework concerns there: React rules →
[react.md](../frameworks/react.md); SSR/RSC/routing → [next.md](../frameworks/next.md). This doc
owns the language, the compiler, and the local toolchain only.

Managed with **pnpm**, linted/formatted with **Biome**, type-checked with **tsc**, run with
**tsx**, tested with **Vitest**.

> **One law:** parse untrusted data into a type once at the boundary, then trust the types
> inward — `any` and `as` are how that contract leaks.

---

## 1. Toolchain

| Concern | Tool | Notes |
|---|---|---|
| Runtime | **Node, current LTS** | Pinned via `package.json` `engines` + `engine-strict=true` and CI. |
| Package manager | **pnpm** | Never `npm` or `yarn`. `pnpm-lock.yaml` is committed; pinned via `packageManager` (§3). |
| Language | **TypeScript** (`strict`) | Strict family on (§4). `tsc --noEmit` is the gate. |
| Run a `.ts` file | **tsx** | `tsx script.ts` / `tsx watch` — ESM-native, no `ts-node` loader flags. Dev/scripts only; bundle for prod. |
| Lint + format | **Biome** (v2) | Config in `biome.json`. No Prettier; ESLint only per-framework where Biome can't express a rule (§5). |
| Tests | **Vitest** (v3) | See [testing-strategy.md](../practices/testing-strategy.md). |
| Boundary validation | **Zod** (v4) | Validate all external/API boundaries (§7). |

## 2. Everyday commands

```bash
pnpm install                  # install deps from the lockfile
pnpm typecheck                # tsc --noEmit  (a type error is a broken build)
pnpm lint                     # biome check  (lint + format check)
pnpm lint:fix                 # biome check --write  (lint + safe fixes + format)
pnpm format                   # biome format --write
pnpm test                     # vitest run
tsx scripts/seed.ts           # run a TS file directly (dev/scripts only)
```

Add a dependency with `pnpm add <pkg>` (runtime) or `pnpm add -D <pkg>` (dev). Commit the
updated `package.json` **and** `pnpm-lock.yaml`. CI runs **`biome ci`** (§5) — not the local
`pnpm lint`.

## 3. pnpm specifics

- **Pin the package manager** so every machine and CI runner resolves identically:
  an exact `"packageManager": "pnpm@<version>"` (a pinned release, not a range) in `package.json`,
  enabled by Corepack. A floating pnpm
  version silently changes resolution and lockfile shape. **`engine-strict=true`** (`.npmrc`) +
  `engines` makes a wrong Node/pnpm a hard install failure, not a warning nobody reads.
- **CI installs with `--frozen-lockfile`** — install must *fail* if `package.json` and the
  lockfile disagree, never silently re-resolve. Add `pnpm dedupe --check` to catch duplicate
  versions. The lockfile is the law (§13).
- **Lifecycle scripts are blocked by default** (pnpm v10+): a dependency's `postinstall` can't
  run until you allowlist it. Keep the block on; allow the few that need it, version-scoped:
  ```yaml
  # pnpm-workspace.yaml
  onlyBuiltDependencies:
    - esbuild
    - '@biomejs/biome'
  minimumReleaseAge: 1440          # install cooldown (mins): refuse a version <24h old
  ```
  `minimumReleaseAge` is a supply-chain seatbelt — it blunts the window where a freshly
  compromised release lands in your tree before the registry pulls it.

## 4. TypeScript compiler config

- **`strict` is on and stays on**, and you go *beyond* it — the flags below close real
  soundness and per-file-transpile holes for near-zero friction. Keep one base `tsconfig.json`:
  ```jsonc
  {
    "compilerOptions": {
      "strict": true,
      "noUncheckedIndexedAccess": true,   // strict's biggest gap: arr[i] / rec[k] is T | undefined
      "exactOptionalPropertyTypes": true, // `{ x?: number }` ≠ `{ x: number | undefined }`
      "noImplicitOverride": true,
      "noFallthroughCasesInSwitch": true,
      "noUnusedLocals": true,             // dead code fails the build, not review
      "noUnusedParameters": true,
      "forceConsistentCasingInFileNames": true,
      // per-file transpile correctness — tsc and the bundler must agree
      "verbatimModuleSyntax": true,       // forces explicit `import type`; no elision guesswork
      "isolatedModules": true,            // single-file transpile (esbuild/swc) stays sound
      "moduleDetection": "force",
      // module + target
      "module": "preserve",
      "moduleResolution": "bundler",      // apps bundled by Vite/Next/esbuild
      "target": "ES2023",
      "lib": ["ES2023", "DOM", "DOM.Iterable"],  // drop DOM libs for pure-Node packages
      "skipLibCheck": true
    }
  }
  ```
- **`moduleResolution`: `"bundler"` for bundled apps; `"nodenext"` for a package Node resolves
  itself** (a published library, a backend run from source) — it enforces extensioned specifiers
  and `package.json` `exports`. Don't ship `"bundler"`-resolved code to a raw Node runtime.
- **`exactOptionalPropertyTypes` is in the baseline**, not held back — it stops "optional" from
  quietly meaning "or explicitly `undefined`". Expect a one-time pass on prop/config types.
- Keep **`tsc --noEmit` green** — it runs in `build` and CI. tsc type-checks; the bundler (or
  `tsc -b`, §12) emits.

## 5. Formatting & linting (Biome)

- **Biome owns formatting and general linting** — no Prettier, and no ESLint for style or for the
  rules Biome already covers. One Rust binary, one `biome.json`, one dependency to patch, and it's
  10–100× faster than the ESLint+Prettier pair (which also fight over formatting). **The one
  sanctioned exception:** a thin ESLint config for the framework rules Biome can't express yet —
  module-boundary/import rules ([react.md](../frameworks/react.md), [next.md](../frameworks/next.md)),
  `eslint-plugin-vue` ([vue.md](../frameworks/vue.md)), and `eslint-plugin-jsx-a11y`
  ([accessibility.md](../practices/accessibility.md)) — added **per-framework, never for formatting
  or style**. Prettier stays out regardless.
- House style lives in `biome.json` and stays auditable: **2-space indent, 100-char width**,
  single quotes, no semicolons, trailing commas. Introducing Biome to an existing repo? Match
  the prevailing style first to keep the first diff mechanical.
- **Turn on the type-aware, framework, and a11y coverage** and a non-fixing CI gate:
  ```jsonc
  {
    "linter": {
      "domains": { "project": "recommended", "test": "recommended" },
      "rules": {
        "suspicious": {
          "noExplicitAny": "error",                       // ban `any` (§6) at the lint layer
          "noFloatingPromises": "error",                  // type-aware: every promise awaited/handled (§9)
          "noConsole": { "level": "error", "options": { "allow": ["warn", "error"] } }
        },
        "style": {
          "useImportType": "error",                       // pairs with verbatimModuleSyntax (§4)
          "noDefaultExport": "error",                     // named exports only (§10)
          "noEnum": "error"                               // const objects over enums (§6)
        }
      }
    },
    "assist": { "actions": { "source": { "organizeImports": "on" } } }
  }
  ```
  Biome v2 **domains** toggle framework-aware rule bundles as a set; the `test` domain relaxes
  test-only rules. Import sorting moved out of the linter into **`assist`** (`organizeImports`).
  `noConsole` makes a `logger` module the only sanctioned console seam. In CI run **`biome ci`**
  (read-only — it can't auto-fix to mask drift), not `biome check`.
- **Fix findings; don't suppress them.** If a rule genuinely doesn't fit, disable it in
  `biome.json` with a comment — not scattered inline `// biome-ignore`.

## 6. Type-system idioms

- **No `any`.** It silently switches off checking and spreads through every call site it
  touches. Reach for **`unknown` + narrowing**, a generic, or a Zod parse (§7). Banned by the
  `noExplicitAny` lint (§5).
- **`type` over `interface` by default** — `type` covers unions, intersections, mapped/conditional
  types, and tuples; reach for `interface` only for declaration merging (augmenting a third-party
  type). Pick one rule per repo so diffs don't churn.
- **Discriminated unions over boolean explosion.** A single tagged union lets the compiler
  exhaustively narrow; a bag of optional booleans permits states that should be unrepresentable:
  ```ts
  type Result<T> = { ok: true; value: T } | { ok: false; error: AppError }
  ```
- **Exhaustiveness with `never`.** A `default` branch that assigns to `never` turns a new union
  member into a *compile* error, not a silent runtime fall-through:
  ```ts
  function assertNever(x: never): never { throw new Error(`unhandled: ${JSON.stringify(x)}`) }
  switch (r.kind) { case 'a': …; case 'b': …; default: return assertNever(r) }
  ```
- **`satisfies`, not a type annotation, to check a literal** while keeping its narrow inferred
  type: `const cfg: Config = {…}` widens, `const cfg = {…} satisfies Config` checks *and* keeps
  the literal types for downstream inference.
- **`as const` for literal data**; **branded types** for IDs that must not be interchangeable
  (`type UserId = string & { readonly __brand: 'UserId' }`) so a `UserId` can't be passed where
  an `OrderId` is wanted.
- **No `enum` — use a `const` object + a derived union.** TS `enum` emits runtime code, isn't a
  plain value, and `const enum` breaks under `isolatedModules` (§4). Banned by `noEnum` (§5):
  ```ts
  const Role = { Admin: 'admin', User: 'user' } as const
  type Role = (typeof Role)[keyof typeof Role]   // 'admin' | 'user'
  ```
- **Generics earn their type parameter.** Every `<T>` must be load-bearing (appear in 2+
  positions so it *relates* inputs to outputs); a one-use `T` is just `unknown` in disguise.
  Constrain tightly (`<T extends object>`) over bare `<T>`.

## 7. Validation at boundaries

Mirror the boundary rule from [react.md](../frameworks/react.md) and the pydantic rule in
[python.md](python.md): **parse, don't validate.** Untrusted input crosses the boundary *once*,
through a schema, and becomes a trusted static type — never an `as` cast.

- **Validate every external edge with Zod** (v4): request/response bodies, webhooks, env vars,
  queue payloads, `JSON.parse` output. The parsed type *is* your domain type — derive it with
  `z.infer`, never hand-write a parallel `type` that drifts from the validator:
  ```ts
  const User = z.object({ id: z.uuid(), email: z.email(), age: z.number().int().nonnegative() })
  type User = z.infer<typeof User>          // single source of truth — type derives from schema
  const user = User.parse(await res.json()) // throws on bad shape; `user` is User downstream
  ```
- **Don't validate already-trusted internal data** on hot paths — Zod's coercion has a real
  cost. Once data is past the boundary, work with the plain inferred type. Share one schema
  across client and server where the contract is shared — see [api-design.md](../design/api-design.md).

## 8. Error handling

- **No swallowed errors.** A `catch` that logs and falls through hides failures and corrupts
  downstream state. Either **rethrow** (`throw new AppError('…', { cause: err })`, preserving the
  chain via `cause`), return it as a value the caller must handle, or don't catch it.
- **`catch (e)` binds `unknown`** (under `strict`) — narrow before use (`e instanceof Error`);
  never assume `e.message` exists.
- **Throw typed errors, not strings.** A small `AppError extends Error` hierarchy with a
  discriminant `code` lets callers branch on the tag and a top-level handler map errors to status.
- **Result-style at boundaries you expect to fail; throw for the exceptional.** A `Result<T>`
  union (§6) forces the caller to handle expected, recoverable failures (parse, lookup-miss) in
  the type system. Reserve `throw` for the genuinely exceptional and let it reach a boundary
  handler rather than catching everywhere.

## 9. Async

- **No floating promises.** An un-awaited promise drops rejections (an unhandled-rejection crash)
  and runs out of order. `await` it, `return` it, or explicitly `void` a deliberate
  fire-and-forget. Enforced by Biome's type-aware **`noFloatingPromises`** (§5).
- **Bound every external await with a timeout via `AbortController`.** An un-timed `fetch`/DB
  call can hang a worker forever:
  ```ts
  const res = await fetch(url, { signal: AbortSignal.timeout(5_000) })   // throws TimeoutError
  ```
  Thread one `AbortSignal` from the request edge through to the network call so an upstream
  cancel propagates — the resilience contract in [resilience.md](../design/resilience.md).
- **Run independent work concurrently — but propagate failure.** `Promise.all` rejects on the
  first failure (cancel the rest via the shared signal); use `Promise.allSettled` only when you
  want every outcome. **Never `await` in a loop** over independent items — collect promises and
  `await Promise.all` so they overlap.

## 10. Module hygiene

- **ESM only.** `"type": "module"` in `package.json`; no CommonJS `require`/`module.exports` in
  new code. Use `import type { … }` for type-only imports (enforced by `verbatimModuleSyntax`, §4).
- **Named exports only — no default exports.** Defaults rename freely at each import site
  (refactors miss them), break tree-shaking heuristics, and weaken auto-import. Enforced by
  `noDefaultExport` (§5). _(Framework files that *require* a default — a Next.js page, a Vite
  config — are the documented exception; scope the rule off for those globs.)_
- **No barrel / `index.ts` re-export files.** They defeat tree-shaking, create import cycles, and
  bloat chunks — import the concrete path. _(scale-up: one barrel at a published package's public
  boundary only.)_
- **Don't "clean up" a re-export or facade module's imports.** A module that imports a name purely
  to re-export it (a public-surface facade) looks like an unused import to a linter — **removing
  it silently breaks every consumer.** Mark such files and guard the public surface with a test;
  this is a hard rule, same as python.md's re-export rule.
- **Enforce import direction in CI**, not review — keep shared code from importing features and
  features from importing each other. Prefer path aliases or workspace packages over deep
  `../../../` chains.

## 11. Testing (Vitest)

- **Vitest** is the runner; keep `pnpm test` deterministic (no real network/clock) — it runs in
  CI. Config in `vitest.config.ts`; pick the environment per project (`node` for libraries,
  `jsdom` for DOM code). Harden it:
  ```ts
  export default defineConfig({
    test: {
      environment: 'node',
      clearMocks: true,                  // reset mock state between tests — no cross-test bleed
      coverage: {
        provider: 'v8',
        include: ['src/**/*.{ts,tsx}'],
        thresholds: { autoUpdate: true, lines: 80, functions: 80, branches: 75, statements: 80 },
      },
    },
  })
  ```
- **Coverage is a ratchet, not a vanity number** — `thresholds` fail CI below the floor;
  `autoUpdate: true` only ever raises it. Ship conservative floors (~70–80), never `100`.
- **Fixture-dependent tests self-skip when the data is absent — never hard-fail.** CI runs on a
  clean checkout; gitignored seeds won't be there. Use `it.skipIf(!fixtureExists)`.
- **Write the test first** for new behaviour and bugfixes. Deterministic-output (golden/snapshot)
  changes regenerate the golden **in the same PR** with a rationale.

Component-testing strategy (RTL / MSW) lives in [react.md](../frameworks/react.md); broader
philosophy in [testing-strategy.md](../practices/testing-strategy.md).

## 12. Monorepo _(scale-up)_

- **pnpm workspaces** with `workspace:*` for internal deps, plus **catalogs** so a shared
  version is declared once and referenced everywhere — no more drift between packages:
  ```yaml
  # pnpm-workspace.yaml
  packages: ['packages/*', 'apps/*']
  catalog: { react: ^19.0.0, zod: ^4.0.0 }   # then any package.json → "react": "catalog:"
  ```
- **A shared base `tsconfig` + `biome.json`** every package extends, so the strict flags (§4) and
  house style (§5) live in exactly one place.
- **Project references for cached, incremental builds.** Each package sets `"composite": true`;
  the root composes them with `references`, and `tsc -b` builds only what changed in dependency
  order. Add **`isolatedDeclarations: true`** so each package emits its `.d.ts` from its own
  source alone — declaration emit parallelises and downstreams type-check against built `.d.ts`.
- A build orchestrator (**Turborepo or Nx**) layers cached, affected-only task graphs on top.

## 13. Security, dependencies & supply chain

- **The lockfile is law in CI.** `pnpm install --frozen-lockfile` (§3) must fail on any
  `package.json`/lockfile drift — never ship an unaudited dependency graph from a silent re-lock.
- **`pnpm audit --prod --audit-level high`** gates CI; keep the lifecycle-script block and
  install cooldown of §3 on. Automate updates via Renovate/Dependabot with a cooldown. See
  [dependencies.md](../practices/dependencies.md) and [security.md](../practices/security.md).
- **No secrets in a client bundle.** Anything imported into front-end code ships as plaintext —
  public config only; secrets stay server-side. Scan the built output for leaks; the
  client/server secret boundary is owned by [security.md](../practices/security.md).

## Definition of done

- [ ] `biome ci` clean (lint + format; `any`, floating promises, default exports all caught)
- [ ] `tsc --noEmit` clean with the strict family of §4 (incl. `noUncheckedIndexedAccess`,
      `exactOptionalPropertyTypes`, `verbatimModuleSyntax`)
- [ ] `vitest run` green; coverage ≥ floor; fixture-dependent tests self-skip, don't fail
- [ ] Untrusted input parsed through a Zod schema at the boundary; no `any`, no boundary `as`
- [ ] Errors typed and rethrown with `cause` (none swallowed); awaits timeout-bounded via `AbortSignal`
- [ ] ESM, named exports, no barrel files; re-export/facade imports left intact
- [ ] `pnpm install --frozen-lockfile` passes; new deps via `pnpm add`, `pnpm-lock.yaml` committed
- [ ] `pnpm audit` clean (or advisories triaged); no secrets in any client bundle
