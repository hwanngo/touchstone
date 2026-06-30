---
name: react-standards
description: Use when building React UIs in a touchstone repo — components, hooks, state, data fetching, forms, Vite/PWA, accessibility. Triggers on .tsx with JSX, `react` in package.json, vite.config. Language-level TS rules live in the typescript skill; for Next.js/Nuxt use those skills.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# React (framework)

Full standard: **`standards/frameworks/react.md`** (layers on `languages/typescript.md`).
Load-bearing rules:

## Always
- **Feature-based folders** (`features/<name>/{api,components,hooks,...}`); unidirectional imports `shared → features → app` (enforce in CI). Absolute imports; no barrel files.
- **Split server-state from client-state**: server cache → **TanStack Query** (query-key factories; don't treat the cache as a state manager); UI/local → `useState`/`useReducer`; app-global → Zustand/context. Never copy server data into `useState` or Redux.
- Wrap in **error boundaries**; **forms = React Hook Form + Zod**; validate every API boundary with Zod.
- a11y (WCAG 2.2 AA) + Web-Vitals/bundle budgets are gates, not nice-to-haves.

## Components & perf
- Function components; type props with `type` (not `React.FC`); colocate; abstract on the *second* repetition.
- Profile before memoizing; adopt **React Compiler** and stop hand-writing `useMemo`/`useCallback`. Don't suppress `useExhaustiveDependencies`.

## Don't get burned
- **No source maps in prod** (`build.sourcemap:false`); `VITE_*` is a public boundary — no secrets. Keep the PWA working.

## Done
`biome ci` · `tsc` · `vitest` · build green; PWA installs if touched. See `standards/frameworks/react.md`.
