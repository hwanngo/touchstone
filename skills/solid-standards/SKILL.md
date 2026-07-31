---
name: solid-standards
description: Use when building a SolidJS app in a touchstone repo — signals/stores, props, control flow, resources, context, SolidStart SSR/routing/server functions. Triggers on `solid-js`/`@solidjs/start` in package.json, .tsx using Solid (createSignal/createStore), app.config.ts, src/routes. Language-level TS rules live in the typescript skill; for React (VDOM, hooks, re-render) use the react skill.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# SolidJS (framework)

Full standard: **`standards/frameworks/solid.md`** (layers on `standards/languages/typescript.md`).
Load-bearing rules:

## Always
- **The signal is the unit of reactivity, not the component.** Components run **once**; only memos, effects, and JSX expressions re-run. Read signals by calling them (`count()`), and keep that read *inside* the JSX/memo/effect that should react.
- **Derived state is `createMemo`, never a `createEffect` that writes the signal it reads.** `createStore` for nested/shared trees (path updates, `produce`/`reconcile`); signals for leaf values.
- **Control flow is components**: `<For>`/`<Index>`/`<Show>`/`<Switch>`, not `.map`/ternaries. Async data is `createResource`/`createAsync` under `<Suspense>` + `<ErrorBoundary>`, Zod-parsed at the fetcher.
- **SolidStart:** `"use server"` functions are public endpoints — validate (Zod) + authorize every call; read via `query`+`createAsync` from a route `preload`, mutate via `action`, revalidate the `query` key surgically.

## Don't get burned
- **Never destructure or spread props into an object** — props are getter-backed; destructuring reads them once and severs reactivity. Use `splitProps` to split, `mergeProps` for defaults, spread `{...rest}` only *into JSX*. **Stores have the same rule** — never destructure a store.
- **No render loop.** React intuition (deps arrays, re-render, `useEffect` setup) does not transfer — reading a signal once at the top of a factory freezes it; a lost-reactivity bug looks like "slow rendering" but the fix is restoring the getter chain, not memoizing.
- Pair every subscription/timer with `onCleanup`; one-time DOM setup goes in `onMount`, not `createEffect`.

## Done
`biome ci` · `tsc` · `vitest` (+ `@solidjs/testing-library`) green; no destructured props/stores; derived state via memos; server functions validate + authorize. See `standards/frameworks/solid.md`.
