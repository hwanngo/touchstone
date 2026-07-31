---
name: typescript-standards
description: Use when writing or configuring TypeScript at the LANGUAGE level (any framework) — tsconfig, pnpm, Biome, module/import hygiene, Vitest config, type patterns — in a touchstone repo. Triggers on .ts/.tsx, tsconfig.json, package.json. For framework rules use the framework skill (react/next/nuxt).
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# TypeScript (language)

Full standard: **`standards/languages/typescript.md`**. For framework specifics see `frameworks/`.
Load-bearing rules:

## Always
- **pnpm only** (pin `packageManager` + Corepack); commit `pnpm-lock.yaml`; CI `--frozen-lockfile`; keep lifecycle-script blocking on; `pnpm audit`.
- **Biome** for lint+format (no ESLint/Prettier); enable `react`/`test` domains + `a11y`; CI runs **`biome ci`**.
- **Strict `tsconfig`** + `noUncheckedIndexedAccess`, `verbatimModuleSyntax`, `isolatedModules`, `moduleDetection: force`. `tsc --noEmit` green in CI.
- No `any` — `unknown` + narrowing, generics, or a schema. `import type` for type-only.

## Don't get burned
- **Absolute imports**; **ban barrel files** (`index.ts` re-export hubs) — tree-shaking + cycle hazard.
- **Vitest** with enforced coverage thresholds; mock the network (MSW), not `fetch`.
- Monorepo: pnpm workspaces + `workspace:*` + shared base `tsconfig`/`biome.json`.

## Done
`biome ci` · `tsc --noEmit` · `vitest` (coverage ≥ floor) all green. See `standards/languages/typescript.md`.
