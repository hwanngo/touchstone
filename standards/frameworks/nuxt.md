# Nuxt (Vue 3) Standards

Meta-framework over Vue 3 — language rules → [typescript.md](../languages/typescript.md). (No standalone vue.md yet; extract one if a non-Nuxt Vue app appears.) Dependencies and supply-chain defer to [typescript.md](../languages/typescript.md) + [security.md](../practices/security.md).

---

## 1. Vue 3 essentials (condensed)

**Composition API + `<script setup lang="ts">` only.** No Options API. No `defineComponent` wrappers (use `defineNuxtComponent` only when you need Options API lifecycle outside SFCs).

```vue
<script setup lang="ts">
const props = defineProps<{ label: string; count?: number }>()
const emit = defineEmits<{ change: [value: number] }>()

const doubled = computed(() => (props.count ?? 0) * 2)
</script>
```

| Rule | Rationale |
|---|---|
| `defineProps<T>()` / `defineEmits<T>()` — always typed generics | Compiler inference; no runtime overhead |
| `ref()` for primitives, `reactive()` for objects you'll never replace | `reactive()` loses reactivity on reassign |
| `computed()` for derived values; never a method called in template | Cached; method re-runs every render |
| `v-for` → always `:key` — **never the array index** for mutable lists | Index keys corrupt state on insert/delete |
| Avoid `watch({ deep: true })` | Expensive traversal; use targeted `watchEffect` or specific paths |
| `shallowRef` / `v-memo` / `v-once` for large inert data | Avoids full reactive traversal on static subtrees |
| One concern per component; extract composables for reuse | Keeps SFCs readable and independently testable |

`toRefs()` or `toRef()` when spreading props into a composable — raw destructure breaks reactivity.

---

## 2. Nuxt project structure

Nuxt 4 layout (preferred for all new apps — set `compatibilityVersion: 4` in `nuxt.config.ts`):

```text
app/
  components/     # auto-imported; subdirs namespaced (Base/Button.vue → <BaseButton>)
  composables/    # auto-imported top-level only — re-export nested from index.ts
  utils/          # auto-imported pure helpers (no Vue reactivity side-effects)
  pages/          # file-based routing
  layouts/        # default.vue + named layouts
  plugins/        # run once at startup; typed via module augmentation
  app.vue         # root component
server/
  api/            # Nitro route handlers (→ §5)
  middleware/     # server middleware
  utils/          # server-only helpers (NOT sent to client)
app.config.ts     # public, reactive, no rebuild — theme/feature flags
nuxt.config.ts    # build config + runtimeConfig secrets
```

**Auto-import rules:**
- `composables/` and `utils/` scan **top-level files only**. Nested composables (`composables/user/useProfile.ts`) are invisible — re-export from `composables/index.ts` or add `imports.dirs` in `nuxt.config.ts`.
- All composables must be called synchronously inside `<script setup>` or a setup function — calling them outside throws "Nuxt instance is unavailable".
- Prefix every composable with `use`; return a **named object** (not bare refs) for a stable API surface.

**`app.config` vs `runtimeConfig`:**

| | `app.config` | `runtimeConfig` |
|---|---|---|
| Audience | Client-visible, theme/feature flags | Server-only secrets (private block) |
| At runtime | Hot-patched without rebuild | Process env (`NUXT_` prefix overrides) |
| Client exposure | Always public | `runtimeConfig.public.*` only — inlined into bundle, same risk as `VITE_` |

Never put credentials in `runtimeConfig.public` or `app.config`. See [app-security.md](../practices/app-security.md).

---

## 3. Rendering & routing

SSR is the default. Choose per-route via `routeRules` in `nuxt.config.ts`:

```ts
routeRules: {
  '/':              { prerender: true },          // SSG — fully static
  '/blog/**':       { isr: 3600 },                // ISR — stale-while-revalidate, 1 h
  '/dashboard/**':  { ssr: false },               // SPA — no server render
  '/api/**':        { cors: true, headers: { 'cache-control': 's-maxage=0' } },
}
```

**Hydration discipline:**
- No `window`/`document`/DOM access in setup — wrap in `onMounted` or `<ClientOnly>`.
- Keep templates deterministic across server/client (no `Date.now()`, `Math.random()` in templates).
- Use `<NuxtLink>` (not `<a>`) — gets smart viewport-based prefetching for free.
- `<NuxtImg>` over `<img>` — automatic WebP/AVIF conversion, responsive sizing, fetch priority.

_(scale-up)_ Nuxt 4 `app/` layout narrows Vite's file watcher scope → faster HMR; migrate new projects immediately.

---

## 4. Data fetching

| Primitive | When to use |
|---|---|
| `useFetch(url, opts)` | Template-driven fetch — SSR dedup + reactivity; URL can be reactive |
| `useAsyncData(key, fn)` | Custom async logic (SDK calls, multi-step); stable `key` prevents duplicate requests |
| `$fetch(url, opts)` | Mutations (POST/PUT/DELETE) and imperative calls inside event handlers |
| `useLazyFetch` / `useLazyAsyncData` | Non-blocking navigation; handle `pending` state explicitly |

**Rules:**
- **Never** use bare `fetch()` in `<script setup>` — runs on both server and client with no dedup.
- **Never** fire requests at composable initialisation top-level (outside a lifecycle or explicit call) — fires on every component instance including SSR before the response is sent.
- Always supply a **stable, unique `key`** to `useAsyncData`; key collisions silently share cached data.
- Nuxt deduplicates identical keys in the SSR payload — lean on this instead of manual caching.

```ts
const { data, error } = await useFetch('/api/items', {
  transform: (raw) => itemsSchema.parse(raw), // Zod validation at the boundary
})
```

---

## 5. API layer (Nitro `server/api/`)

Nitro route handlers are the canonical backend for Nuxt. Follow [api-design.md](../design/api-design.md) for naming, versioning, and response shape.

```ts
// server/api/items/[id].get.ts
export default defineEventHandler(async (event) => {
  const { id } = getRouterParams(event)
  const body = await readValidatedBody(event, itemUpdateSchema.parse) // Zod — built-in
  await assertAuthorized(event)                                        // authZ every handler
  return db.item.findUniqueOrThrow({ where: { id } })
})
```

- **Validate input** with `readValidatedBody` / `getValidatedQuery` — Nitro has native Zod support.
- **Authorize every handler** — no implicit "logged-in = allowed"; always check resource ownership.
- Never trust client-supplied IDs without a DB ownership check.
- `server/utils/` exports are auto-imported server-side only — safe place for secrets and DB clients.
- See [app-security.md](../practices/app-security.md) for CORS, CSRF, rate-limiting, and secret handling.

---

## 6. State management

| Tool | Use case |
|---|---|
| **Pinia** | Shared/cross-component state, server-primed stores, complex actions |
| `useState<T>(key, init)` | SSR-safe lightweight state; serialised into payload, hydrated without refetch |
| `useFetch` / `useAsyncData` | Remote state — keep it here, don't copy into a store |

**SSR cross-request leak rules — enforce strictly:**

1. **Never** declare `const state = ref(…)` or `export const myState = ref(…)` at module scope — Node.js reuses module instances across requests; that ref is shared between users.
2. **Never** call Pinia stores or `useRuntimeConfig()` outside a setup function, plugin, or route middleware — pass the `pinia` instance explicitly if needed in navigation guards.
3. Use `callOnce()` in store actions that seed server-side data — prevents re-execution on client hydration.
4. Prefer `useState()` over `ref()` for any state that must survive SSR → client hydration; `ref()` is not serialised into the page payload.

```ts
// WRONG — shared across all requests on the server
export const currentUser = ref<User | null>(null)

// RIGHT — per-request, SSR-safe
const currentUser = useState<User | null>('currentUser', () => null)
```

---

## 7. Composables discipline

Beyond the auto-import rules in §2:

- **No top-level side effects** — a composable that fires a `$fetch` at the top of its body runs on every component mount, including during SSR before the response ships.
- Accept parameters as `MaybeRef<T>` / `MaybeRefOrGetter<T>` so callers can pass reactive or static values.
- Watch reactive parameters with `watch`/`watchEffect` when the composable needs to react to changes.
- Return a **consistent named object** — changing the shape is a breaking API change for consumers.
- Composables can compose other composables freely (auto-import chain works inside `composables/`).

---

## 8. Build, deploy & env

- **Vite** (dev + build) + **Nitro** (server + deploy adapters): pick adapter via `nitro.preset` (`node`, `cloudflare`, `vercel`, `netlify`, `bun`, etc.).
- Env vars flow through `runtimeConfig`; access at runtime via `useRuntimeConfig()`. Never hard-code secrets; keep `.env` out of version control.
- `nuxt generate` for full SSG; `nuxt build` for SSR/edge deployments.
- **Bundle budget:** audit with `nuxi analyze` (Rollup visualizer); gate on `size-limit` in CI for client chunks.
- Lazy-load non-critical components with the `Lazy` prefix (`<LazyHeavyChart>`) — defers JS until render.
- Web Vitals targets: LCP ≤ 2.5 s, INP ≤ 200 ms, CLS ≤ 0.1 — enforce Lighthouse-CI in pipeline.

---

## 9. Testing

| Layer | Tool |
|---|---|
| Unit / component | **Vitest** + `@nuxt/test-utils/unit` + **Vue Testing Library** |
| Nuxt integration | `@nuxt/test-utils` (`setup`, `$fetch`, `mountSuspended`) |
| Network mocking | **MSW** — shared handlers across component, integration, and Storybook |
| E2E | **Playwright** — see [testing-strategy.md](../practices/testing-strategy.md) |

```ts
// component test — prefer Vue Testing Library queries over wrapper internals
import { mountSuspended } from '@nuxt/test-utils/runtime'
import ItemCard from '~/components/ItemCard.vue'

it('renders label', async () => {
  const wrapper = await mountSuspended(ItemCard, { props: { label: 'Foo' } })
  expect(wrapper.text()).toContain('Foo')
})
```

- Test **behaviour** (ARIA roles, labels, user events) not implementation details.
- MSW handlers are the network seam — define once, reuse in dev, Storybook, and tests.
- Vitest coverage ratchet: `thresholds.autoUpdate: true` — floor only rises.

---

## Definition of done

- [ ] `nuxi typecheck` clean (strict + `verbatimModuleSyntax`; no `any` escapes)
- [ ] `pnpm lint` (Biome) clean; `useExhaustiveDependencies` not suppressed
- [ ] `pnpm test` green; coverage ≥ floor; no real network calls in tests
- [ ] `pnpm build` succeeds; client bundle within size budget
- [ ] No secrets in `runtimeConfig.public`, `app.config`, or committed `.env`
- [ ] No module-scope mutable state (`ref`/`reactive` outside setup) — SSR leak prevention
- [ ] Every Nitro handler validates input (Zod) and checks authorization
- [ ] No DOM access in SSR-executed setup code; hydration mismatch-free
- [ ] `routeRules` rendering mode matches the route's SEO/performance needs
- [ ] Web Vitals budget met (Lighthouse-CI: LCP / INP / CLS)

---

**Sources:** [nuxt/nuxt — Auto-imports v4](https://nuxt.com/docs/4.x/guide/concepts/auto-imports) · [nuxt/nuxt — Composables directory v4](https://nuxt.com/docs/4.x/directory-structure/app/composables) · [nuxt/nuxt — Performance best practices v4](https://nuxt.com/docs/4.x/guide/best-practices/performance) · [nuxt/nuxt — State management v4](https://nuxt.com/docs/4.x/getting-started/state-management) · [vuejs/pinia — SSR with Nuxt](https://pinia.vuejs.org/ssr/nuxt.html) · [certificates.dev — Composable best practices in Nuxt](https://certificates.dev/blog/composable-best-practices-in-nuxt)
