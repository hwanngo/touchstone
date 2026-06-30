# Vue 3 Standards

Framework layer; language rules → [typescript.md](../languages/typescript.md). Owns Vue 3 SFC,
reactivity, component, store, and router conventions for a **plain Vue 3 SPA** (Vite). Defers
component testing depth to [testing-strategy.md](../practices/testing-strategy.md), a11y to
[accessibility.md](../practices/accessibility.md), and shared API contracts to
[api-design.md](../design/api-design.md), and dependencies/supply-chain to [typescript.md](../languages/typescript.md) + [security.md](../practices/security.md). SSR/SSG, file-based routing, auto-imports, and
server routes are **not** here — meta-framework specifics → [nuxt.md](nuxt.md).

> **One law:** keep reactivity intact end-to-end — every place a `ref` is unwrapped, destructured,
> or reassigned is where it silently goes dead.

---

## 1. Composition API + `<script setup>` only

**`<script setup lang="ts">` is the default and the only sanctioned component style.** No Options
API in new code, no `defineComponent({ setup() })` boilerplate — the macro form gives better type
inference, less ceremony, and compile-time props/emits.

```vue
<script setup lang="ts">
const props = defineProps<{ label: string; count?: number }>()
const emit = defineEmits<{ change: [value: number] }>()
const doubled = computed(() => (props.count ?? 0) * 2)
</script>
```

| Rule | Rationale |
|---|---|
| `<script setup>` + Composition API everywhere | Best inference, smallest output, no `this` |
| Options API only when wrapping a legacy mixin you can't yet port | Migration seam, not a new-code option |
| One concern per SFC; lift shared logic into a composable (§5) | SFCs stay readable and independently testable |
| `<script setup>` order: macros → state → computed → watchers → lifecycle → functions | Predictable scan path |

Reserve `defineComponent` for non-SFC render-function components (rare); never wrap an SFC in it.

## 2. Reactivity — `ref` first

- **`ref()` is the default for all state — primitives *and* objects.** It survives reassignment,
  reads/writes explicitly through `.value` (so reactivity is visible), and unwraps automatically in
  templates. Reach for `reactive()` only for a never-reassigned local object, and never `export`
  one — see the loss pitfalls below.
- **`reactive()` loses reactivity on reassignment and on destructure.** `state = { …}` orphans the
  proxy; `const { x } = reactive(…)` copies a snapshot. If you must spread props/state into locals,
  use `toRefs()` / `toRef()` to keep the link.
- **`computed()` for any derived value** — cached, recomputes only when a dependency changes. Never
  compute in a template-called method (re-runs every render) and never write a `watch` that just
  mirrors one ref into another (that's a `computed`).
- **`shallowRef` / `shallowReactive` for large inert payloads** (parsed API blobs, geometry,
  editor docs) — skips deep proxying so reads/writes don't pay a recursive-tracking tax. _(scale-up)_
- **`watch` is targeted; `watchEffect` auto-tracks.** Prefer `watch(source, cb)` with explicit
  sources for clarity; reserve `watchEffect` for "run this whenever anything it reads changes."

| Pitfall | Fix |
|---|---|
| `const { user } = reactive(store)` → dead | `const { user } = toRefs(store)` |
| `state.value = await fetch()` reassign on `reactive` | use a `ref`, assign `.value` |
| `watch({ deep: true })` on a big tree | watch a specific path or a `computed` getter |
| Forgetting `.value` outside templates | lint catches via Vue's official ESLint plugin |

## 3. Component design — typed props, emits, models, slots

- **Type props and emits with the generic macro form**, never the runtime-object form — it's the
  single source of truth and needs no parallel `type`. Vue 3.5's **reactive props destructure** lets
  you destructure with defaults inline and keep reactivity:
  ```vue
  <script setup lang="ts">
  const { count = 0, variant } = defineProps<{
    count?: number
    variant: 'primary' | 'secondary' | 'danger'   // discriminated variant, not boolean soup
  }>()
  </script>
  ```
- **`defineModel()` for two-way binding** (stable since 3.4) — replaces the `prop + update:` emit
  pair. One `const model = defineModel<string>()` gives a writable ref that syncs `v-model`.
- **Props down, events up — never mutate a prop.** Emit a typed event and let the owner change state.
- **Name slots and type their props.** Prefer slots/`children`-style composition over a tenth prop;
  a ballooning prop list is the signal to split or expose a slot.
- **`useTemplateRef('el')` for template refs** (3.5+) over the bare `ref(null)` + matching-name
  trick — clearer and works with dynamic names.
- **Validate every external/API boundary with Zod** and work with the inferred type inward
  ([typescript.md](../languages/typescript.md) §7); share request/response schemas via
  [api-design.md](../design/api-design.md).

## 4. State management — Pinia, used sparingly

**Pinia is the store**, and the **setup-store** form is the default — it reads like a composable and
types itself with zero boilerplate:

```ts
export const useCartStore = defineStore('cart', () => {
  const items = ref<CartItem[]>([])
  const total = computed(() => items.value.reduce((n, i) => n + i.price, 0))
  function add(item: CartItem) { items.value.push(item) }
  return { items, total, add }
})
```

- **Don't overuse global state.** Most state is local (`ref` in a component) or server-cache. A store
  is for genuinely cross-component, app-lifetime client state (auth/session, cart, theme) — not a
  dumping ground for props you didn't want to thread.
- **Server data is a cache, not store state.** Keep it in a query layer (TanStack Query for Vue, or
  `useFetch`/`useAsyncData` under Nuxt) — don't copy fetched data into Pinia and hand-reimplement
  caching, dedup, and invalidation.
- **Destructure stores through `storeToRefs()`** — a raw `const { total } = store` breaks reactivity
  (§2); actions can be destructured directly.
- One store per domain; no single god-store. Reset with `store.$reset()` (setup stores need an
  explicit reset function).

## 5. Composables — the `use*` pattern

- **Extract reusable stateful logic into `use*` composables**; this is Vue's unit of reuse (the
  mixins replacement). Name every one `useThing`, place in `src/composables/`, return a **named
  object** with a stable shape — changing the shape is a breaking API change.
- **No top-level side effects.** A composable that fires a request at the top of its body runs on
  every caller mount. Kick off work in a lifecycle hook or behind an explicit function the caller
  invokes.
- **Accept `MaybeRefOrGetter<T>` and normalise with `toValue()`** so callers pass a ref, a getter, or
  a plain value; `watch` the input when the composable must react to changes.
- **Register lifecycle/cleanup inside the composable** (`onMounted`/`onScopeDispose`) so a consumer
  can't leak listeners — composables own their own teardown.

## 6. Routing — Vue Router, lazy and guarded

- **Vue Router with typed routes**; co-locate route definitions and **lazy-load every route
  component** with a dynamic import so the first load ships only the shell:
  ```ts
  const routes = [
    { path: '/', component: () => import('@/pages/HomePage.vue') },
    { path: '/orders/:id', component: () => import('@/pages/OrderPage.vue'), props: true },
  ]
  ```
- **`props: true` to pass route params as props** — keeps page components decoupled from `useRoute()`.
- **Auth/data guards via `beforeEach` / `beforeEnter`**, returning a route or `false` to redirect;
  keep guards synchronous-fast and push slow work into the page. Never trust a client guard for
  authorization — it's UX, the server enforces access ([app-security.md](../practices/app-security.md)).
- **Manage focus on navigation** (§9) and restore scroll via `scrollBehavior`.

## 7. Forms & validation — VeeValidate + Zod

- **VeeValidate with the Zod `toTypedSchema` resolver** — schema-driven validation that **reuses the
  same Zod schema as the API boundary** (§3), so client and server agree on shape by construction:
  ```ts
  const schema = toTypedSchema(z.object({ email: z.email(), age: z.number().int().nonnegative() }))
  const { handleSubmit, errors } = useForm({ validationSchema: schema })
  ```
- **Don't hand-roll a `ref`-per-field + manual `@input` + ad-hoc checks** — it drifts from the API
  contract and re-validates by hand on every keystroke.
- **Validate on blur/submit, not every keystroke**; surface the first error per field and announce it
  (§9). One submit handler parses once and emits typed data.

## 8. Performance — measure, then trim

| Lever | Use when |
|---|---|
| `v-memo="[dep]"` | Large list rows / static subtrees that re-render needlessly _(scale-up)_ |
| `v-once` | Render-once static content |
| `defineAsyncComponent` | Heavy/below-the-fold components — defers their JS |
| `shallowRef` (§2) | Large inert reactive payloads |
| `:key` on every `v-for` | **Stable id, never the array index** for mutable lists |

- **Stable `:key` is non-negotiable** — index keys corrupt component state on insert/reorder/delete
  and defeat the diff. Use a domain id.
- **Lazy-load routes (§6) and async components**; let Vite/Rollup auto-chunk — don't hand-write
  `manualChunks`. Audit with `rollup-plugin-visualizer` and gate CI on `size-limit`.
- **Profile with Vue DevTools before optimising** — most components aren't the bottleneck, and
  untargeted `v-memo` adds dependency-array bugs for no win.
- Hold a **Core Web Vitals** budget (LCP ≤ 2.5 s, INP ≤ 200 ms, CLS ≤ 0.1) via Lighthouse-CI.

## 9. Accessibility — a build requirement

Target **WCAG 2.2 AA**; full checklist in [accessibility.md](../practices/accessibility.md).

- **Semantic HTML first** — real `<button>`/`<nav>`/`<main>`/headings; ARIA supplements, never
  replaces, and a wrong `role` is worse than none.
- **Keyboard + focus**: every interactive element reachable; move focus on route change and
  dialog open/close; visible focus rings. `useId()` (3.5+) for stable label/`aria-describedby` ids.
- **Honour `prefers-reduced-motion`** — gate `<Transition>`/non-essential animation behind it.
- **CI gate**: Vue's official ESLint a11y plugin (`eslint-plugin-vuejs-accessibility`) on the JSX/
  template + an **axe / Lighthouse-a11y** runtime check so contrast/focus/label violations fail the
  build, not just review.

## 10. Testing — Vitest, Testing Library, Playwright

| Layer | Tool |
|---|---|
| Unit / component | **Vitest** + **`@vue/test-utils`** (or Vue Testing Library for behaviour-first queries), jsdom |
| Network | **MSW** handlers — one seam shared with dev and tests |
| E2E | **Playwright** — see [testing-strategy.md](../practices/testing-strategy.md) |

```ts
import { mount } from '@vue/test-utils'
import ItemCard from '@/components/ItemCard.vue'

it('renders the label', () => {
  const wrapper = mount(ItemCard, { props: { label: 'Foo' } })
  expect(wrapper.text()).toContain('Foo')
})
```

- **Test behaviour** (rendered text, ARIA roles, user events) — not internal refs or method calls.
- **Mock the network, not `fetch`** (MSW), asserting against the same Zod schemas the app uses.
- Mechanics (runner config, coverage ratchet) live in [typescript.md](../languages/typescript.md) §11.

---

## Definition of done

- [ ] `<script setup lang="ts">` only; props/emits typed via generic macros; no prop mutation
- [ ] No reactivity loss: no `export`ed/destructured `reactive`; `storeToRefs`/`toRefs` at seams
- [ ] Derived values are `computed`, not methods or mirror-`watch`; `:key` is a stable id, never index
- [ ] Pinia setup stores for cross-component state only; server data stays in the query layer
- [ ] Composables are `use*`, side-effect-free at top level, return a stable named object, self-clean
- [ ] Routes lazy-loaded; guards present (and server still enforces authorization)
- [ ] Forms use VeeValidate + a Zod schema shared with the API boundary; no per-field `ref` soup
- [ ] A11y gate passes (vuejs-accessibility lint + axe/Lighthouse): semantics, labels, keyboard/focus
- [ ] Web Vitals budget met (Lighthouse-CI: LCP / INP / CLS); bundle within `size-limit`
- [ ] `pnpm test` green (Vitest + @vue/test-utils, MSW); no real network; behaviour-tested

---

**Sources:** [vuejs/core — Composition API `<script setup>`](https://vuejs.org/api/sfc-script-setup.html) · [vuejs.org — Reactivity Fundamentals](https://vuejs.org/guide/essentials/reactivity-fundamentals.html) · [vuejs.org — `defineModel` & reactive props destructure (3.4 / 3.5)](https://vuejs.org/guide/components/v-model.html) · [vuejs.org — Composables](https://vuejs.org/guide/reusability/composables.html) · [vuejs/pinia — Setup stores](https://pinia.vuejs.org/core-concepts/) · [router.vuejs.org — Lazy loading & navigation guards](https://router.vuejs.org/guide/advanced/navigation-guards.html) · [vee-validate — Zod schema validation](https://vee-validate.logaretm.com/v4/guide/composition-api/typed-schema/) · [test-utils.vuejs.org](https://test-utils.vuejs.org/)
