# SolidJS Standards

Framework layer over Solid 1.x + SolidStart 1.x; language rules → [typescript.md](../languages/typescript.md).
This doc owns the fine-grained reactivity model, component shape, control flow, async data, and the
server boundary — defer language/tsconfig/test-runner mechanics to TypeScript, API shape to
[api-design.md](../design/api-design.md), and a11y to [accessibility.md](../practices/accessibility.md).
Coming from React? Read §1 first, then [react.md](react.md) for the VDOM/hooks contrasts.

Applies to all new apps on **Solid 1.x** (latest stable — verify the current release) and the **SolidStart 1.x** meta-framework (Vinxi/Nitro).
Type-checked with **tsc**, tested with **Vitest** + **@solidjs/testing-library**.

> **One law:** the component is not the unit of reactivity — the signal is. Components run once;
> only the reactive computations you wire up re-run.

---

## 1. The reactivity model — and why React intuition misfires

**Solid has no virtual DOM and no re-render.** A component is a *factory* that runs **exactly once**
to wire up a reactive graph; after that, only fine-grained computations (memos, effects, JSX
expressions) re-run when the signals they read change. This is the **#1 mental-model trap for React
devs**: there is no render loop, so the rules of `useState`/`useEffect`/deps arrays do not transfer.

| Primitive | Use for | Don't |
|---|---|---|
| `createSignal(v)` → `[get, set]` | reactive state; **read by calling** `get()` | …read `count` instead of `count()` and lose the subscription |
| `createMemo(fn)` | pure, cached derived value | …recompute in an effect and write it back to a signal |
| `createEffect(fn)` | **sync with the outside world** (DOM, logging, subscriptions) | …derive state, or run setup that belongs in `onMount` |
| `createResource` | async/server data (§6) | …`fetch` in a bare `createEffect` |

```tsx
function Counter() {
  const [count, setCount] = createSignal(0)           // runs ONCE
  const doubled = createMemo(() => count() * 2)        // re-runs only when count() changes
  createEffect(() => console.log('count is', count())) // tracks count() automatically
  return <button onClick={() => setCount((c) => c + 1)}>{count()}</button>
}
```

- **Signals are read by calling them**, and tracking is automatic — whatever signal you *call* inside
  a tracking scope (JSX, memo, effect) is subscribed. There is no dependency array.
- **`createMemo`, never `createEffect`, for derived state** — a memo is pure, cached, and glitch-free;
  an effect that writes a signal it reads is the classic loop/stale-value bug (same rule as
  [react.md](react.md)'s "you might not need an effect").
- **The function body does not re-run** — a value read once at the top (`const v = count()`) freezes.
  Keep signal reads *inside* the JSX/memo/effect that should react to them.

## 2. Props — never destructure (the framework's sharpest edge)

**Props are a live, getter-backed object; destructuring or spreading them eagerly reads the getters
and severs reactivity.** This is the single most common Solid bug. Keep `props` intact and read
`props.x` at the point of use.

```tsx
// ✗ breaks reactivity — value is read once, frozen
function Hi({ name }: { name: string }) { return <h1>Hello {name}</h1> }

// ✓ reactive — props.name is read inside JSX every time it changes
function Hi(props: { name: string }) { return <h1>Hello {props.name}</h1> }
```

- **Use `splitProps` to "destructure"** when you must separate local from forwarded props — it keeps
  each slice reactive: `const [local, rest] = splitProps(props, ['name'])`.
- **Use `mergeProps` for defaults**, not destructuring defaults — `mergeProps({ size: 'md' }, props)`
  preserves the getter chain that `{ size = 'md' }` would collapse.
- **Forward `rest` with the spread in JSX** (`<button {...rest} />`) — spreading *into JSX* is
  reactive; spreading into a plain object is not.

## 3. Component structure

- **`.tsx` with typed props as a single `props` object** (§2) — no `React.FC`, no signature
  destructure. Order: imports → component factory → local `export`ed helpers.
- **One concern per component.** A ballooning prop list is the signal to split or compose via
  `children` — they're lazy, so wrap with `children(() => props.children)` to inspect/transform them.
- **Wrap third-party widgets** behind a thin local component so a swap is a one-file change. **Route
  logging through a `logger` module**, not raw `console.*` (Biome `noConsole`,
  [typescript.md](../languages/typescript.md) §5).

## 4. Stores for nested & shared state

**Reach for `createStore` once state is a nested object/array you update by path.** Stores are
fine-grained proxies — updating `setStore('user', 'name', v)` notifies only subscribers of that leaf,
not the whole object.

```tsx
const [state, setState] = createStore({ user: { name: 'Ada' }, todos: [] as Todo[] })
setState('user', 'name', 'Grace')                    // surgical, path-based update
setState('todos', (t) => t.id === id, 'done', true)  // update matching row only
```

- **Signals for primitives/leaf values; stores for trees.** Don't wrap a single boolean in a store,
  and don't hold a deep object in a signal and replace it wholesale on every edit.
- **Mutate immutably by path, or with `produce`** (an Immer-style draft) for complex updates;
  **`reconcile`** when replacing store data from a fetch so identity/keys are diffed, not replaced.
- **Never destructure a store** either — same getter rule as props (§2). Read `state.user.name` live.

## 5. Control flow — components, not `.map`/ternaries

**Use Solid's control-flow components, not JS array/ternary tricks.** `arr.map()` and `cond ? a : b`
re-create the whole subtree because Solid can't diff them; the built-ins are keyed and reactive.

| Instead of | Use | Because |
|---|---|---|
| `list.map(...)` | `<For each={list}>{(item) => …}</For>` | keyed by **reference**; rows move, not re-create — for dynamic lists |
| `list.map(...)` (stable list, changing values) | `<Index each={list}>{(item) => …}</Index>` | keyed by **index**; `item` is a signal — for primitives/fixed-length |
| `cond ? <A/> : <B/>` | `<Show when={cond()} fallback={<B/>}><A/></Show>` | mounts/unmounts once on toggle |
| `if/else if` chains | `<Switch><Match when={a()}>…</Match></Switch>` | one branch live at a time |
| try/catch in render | `<ErrorBoundary fallback={…}>` | catches render + resource errors |

- **`<For>` vs `<Index>` is a real decision:** `<For>` when items are objects that reorder/insert
  (keyed by identity); `<Index>` when the list is primitives or the slot position is stable.
- **`<Show>` with a callback** (`{(user) => …}`) narrows `when` to non-null inside the block — the
  idiomatic null-guard.

## 6. Async data with resources

**`createResource` is the boundary for async/server data** — it integrates with `<Suspense>` and
`<ErrorBoundary>`, tracks loading/error state, and refetches when its source signal changes. Never
hand-roll `fetch` inside a `createEffect`.

```tsx
const [userId, setUserId] = createSignal(1)
const [user] = createResource(userId, (id) => fetchUser(id))   // refetches when userId() changes
// in JSX: <Suspense fallback={<Spinner/>}>{user()?.name}</Suspense>  — user.loading / user.error
```

- **Validate the response with Zod at the fetcher**, not in the component — parse, don't cast
  ([typescript.md](../languages/typescript.md) §7, [api-design.md](../design/api-design.md)).
- **Drive loading/error structurally** with `<Suspense>` + `<ErrorBoundary>`, not per-component
  `if (loading)` ladders. In SolidStart, prefer `createAsync` (§8) over raw resources for routed data.

## 7. Context for ambient state

- **`createContext` + `useContext`** for app-wide ambient state (theme, auth, i18n) — pass a store or
  signal tuple as the value so consumers stay reactive, and expose a `useX()` hook that throws when
  used outside its provider. **Props over context for reuse** ([react.md](react.md) §9).

## 8. SolidStart — the meta-framework (SSR, routing, server functions)

SolidStart 1.x adds file-based routing (`@solidjs/router`), SSR/streaming, and server functions on
Vinxi/Nitro. Follow [api-design.md](../design/api-design.md) for endpoint naming and error shape.

- **`"use server"` marks a server function** — a function that always runs on the server (DB,
  secrets) and is called like a normal async function from the client. Secrets never reach the
  bundle; treat every server function as a **public HTTP endpoint** — validate input (Zod) and
  authorize on every call.
- **Read data with `query` + `createAsync`.** Wrap a server function in `query(fn, 'key')` for
  dedupe/caching, expose it from a route `preload`, and consume it with `createAsync` so navigation
  doesn't waterfall:

  ```tsx
  const getTodos = query(async () => { 'use server'; return db.todo.findMany() }, 'todos')
  export const route = { preload: () => getTodos() }
  // component: const todos = createAsync(() => getTodos())
  ```

- **Mutate with `action`** (the `<form>`-friendly mutation primitive) — it works without JS and
  enables **single-flight mutations** (the mutation + the refreshed `query` data return in one
  round-trip) when the action runs on the server and the data was preloaded. `revalidate` the
  affected `query` key after a write; don't refetch everything.
- **Pick the rendering/adapter per deploy target** in `app.config.ts` (Nitro presets: node, vercel,
  cloudflare, static). _(scale-up)_ Hold a Core Web Vitals budget (LCP ≤ 2.5 s, INP ≤ 200 ms,
  CLS ≤ 0.1) via Lighthouse-CI.

## 9. Effects, lifecycle & cleanup

- **`onMount` for one-time DOM setup** (measuring, focus, third-party init) — runs once on the
  client, never during SSR. **`createEffect` only to react** to signal changes.
- **Pair every subscription/timer with `onCleanup`** — it teardowns when the owner is disposed or
  before an effect re-runs; an unmatched subscription is a leak.
- **`batch`** many `set`s into one update; **`untrack`** to read without subscribing; **`on(src, fn,
  { defer: true })`** for explicit deps that skip the initial run. Surgical tools, not defaults.

## 10. Performance — why it's fast, and where reactivity leaks

Solid is fast *by default* — no VDOM diff, updates pinpointed to the exact DOM node a signal feeds.
You rarely "optimize"; you mostly avoid **breaking** the model.

- **The performance bug is lost reactivity, not slow rendering.** Destructuring props/stores (§2/§4),
  reading a signal once at the top of a factory (§1), or `.map`-ing a list (§5) all sever tracking —
  the fix is to restore the getter chain, not to memoize.
- **`createMemo` only for expensive or multiply-read derivations** — Solid recomputes JSX expressions
  cheaply, so wrapping a trivial once-read value is pure overhead. **Keys matter in `<For>`**: mutate
  items in place rather than replacing references so DOM nodes move instead of re-create.

## 11. Accessibility

Target **WCAG 2.2 AA**; a11y is a build requirement, not a polish step. The CI gate and details live
in [accessibility.md](../practices/accessibility.md).

- **Semantic HTML first** — real `<button>`/`<nav>`/`<main>`/headings; ARIA supplements, never
  replaces, semantics. JSX uses standard DOM attributes (`class`, `for`, `tabindex`) — no React-isms;
  don't over-ARIA. Manage focus on route change and dialog open/close (`onMount`, §9).
- **CI gate:** an **axe / Lighthouse-a11y** run so runtime violations (contrast, focus order, missing
  labels) fail the build, driven by behaviour tests (roles/labels, §12).

## 12. Testing

| Layer | Tool |
|---|---|
| Unit (signals, stores, utils) | **Vitest** (`node` for logic, `jsdom` for components) |
| Component | **@solidjs/testing-library** + `@testing-library/user-event` |
| Server functions / routing / SSR | **Vitest** as functions + Playwright for E2E _(scale-up)_ |

- **Test behaviour and accessibility** — roles, labels, user events — not signal internals. Render
  with `@solidjs/testing-library` and assert on the DOM. Mock the network with **MSW**, not `fetch`.
- **Server functions are server code** — test them as plain async functions (auth, validation,
  return shape), not only through the rendered UI. Runner/coverage mechanics →
  [typescript.md](../languages/typescript.md) §11; strategy → [testing-strategy.md](../practices/testing-strategy.md).

## Definition of done

- [ ] Language DoD met ([typescript.md](../languages/typescript.md)): `biome ci`, `tsc`, tests, supply chain
- [ ] Derived state via `createMemo`, never a `createEffect` that writes the signal it reads (§1)
- [ ] Props never destructured/spread into objects; `splitProps`/`mergeProps` used instead (§2)
- [ ] Nested/shared state in `createStore` with path updates (`produce`/`reconcile`); stores not destructured (§4)
- [ ] Lists/conditionals use `<For>`/`<Index>`/`<Show>`/`<Switch>`, not `.map`/ternaries (§5)
- [ ] Async data via `createResource`/`createAsync` under `<Suspense>` + `<ErrorBoundary>`; responses Zod-parsed (§6/§8)
- [ ] Every `"use server"` function validates input (Zod) and authorizes; mutations via `action`, `query` revalidated surgically (§8)
- [ ] Every subscription/timer paired with `onCleanup`; one-time DOM setup in `onMount` (§9)
- [ ] A11y gate green (axe/Lighthouse-a11y) — labels, contrast, keyboard/focus (§11)
- [ ] `@solidjs/testing-library` covers behaviour; server functions tested as functions (§12)

**Sources:** [Solid docs — Reactivity](https://docs.solidjs.com/concepts/intro-to-reactivity) ·
[Solid docs — Props](https://docs.solidjs.com/concepts/components/props) ·
[Solid docs — Stores](https://docs.solidjs.com/concepts/stores) ·
[Solid docs — Control Flow](https://docs.solidjs.com/concepts/control-flow/list-rendering) ·
[Solid docs — `createResource`](https://docs.solidjs.com/reference/basic-reactivity/create-resource) ·
[SolidStart — Data fetching](https://docs.solidjs.com/solid-start/building-your-application/data-loading) ·
[SolidStart — Data mutation](https://docs.solidjs.com/solid-start/building-your-application/data-mutation) ·
[Testing Library — Solid](https://testing-library.com/docs/solid-testing-library/intro)
