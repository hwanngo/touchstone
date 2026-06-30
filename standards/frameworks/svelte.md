# Svelte & SvelteKit Standards

Framework layer over Svelte 5 + SvelteKit 2; language rules → [typescript.md](../languages/typescript.md).
This doc owns the reactivity model, component shape, routing, and the server boundary — defer
language/tsconfig/test-runner mechanics to TypeScript, API shape to
[api-design.md](../design/api-design.md), auth/CORS/secrets to [security.md](../practices/security.md).

Applies to all new apps on **Svelte 5** (runes) and **SvelteKit 2** (Vite-based; verify the current release). Type-checked with
**`svelte-check`**, tested with **Vitest** + **@testing-library/svelte** and **Playwright**.

> **One law:** the compiler is the framework — let its runes, route config, and a11y warnings do
> the work instead of hand-rolling reactivity, caching, or accessibility.

---

## 1. Runes are the reactivity model

**Svelte 5 runes (`$state`, `$derived`, `$effect`, `$props`) are mandatory for new code.** The
legacy reactive `let` + `$:` model is a compiler-magic footgun that only worked at the top of a
`.svelte` component; runes are explicit, work in `.svelte.ts` modules, and compose into functions.

| Rune | Use for | Don't |
|---|---|---|
| `$state(v)` | mutable reactive value (deep-proxied for objects/arrays) | …mutate a plain `let` and expect re-render |
| `$derived(expr)` / `$derived.by(fn)` | pure computed values | …recompute in `$effect` and assign to `$state` |
| `$effect(fn)` | **sync with the outside world** (DOM, subscriptions, logging) | …derive state, fetch, or mutate `$state` it reads |
| `$props()` | destructure component inputs (defaults, `...rest`) | …mutate a prop directly |
| `$bindable()` | opt a prop into two-way `bind:` | …make every prop bindable by default |

- **`$derived`, never `$effect`, for computed state.** An effect that writes the state it depends
  on is the classic infinite-loop / stale-value bug — `$derived` is glitch-free and lazy.
- **`$effect` is an escape hatch, not a lifecycle** — bridge to non-reactive systems only; it runs
  after DOM update, is skipped during SSR, and returns a teardown for cleanup.
- **Shared reactive logic lives in `.svelte.ts` modules** — runes work there, so a factory
  returning getters replaces the old store boilerplate.

```svelte
<script lang="ts">
  let { items, onSelect }: { items: Item[]; onSelect: (id: string) => void } = $props();
  let query = $state('');
  let matches = $derived(items.filter((i) => i.name.includes(query))); // pure, cached
</script>
```

## 2. Component structure

- **`<script lang="ts">` always** — typed `$props()` destructure is the prop contract; no
  `export let`. Order each component: script → markup → `<style>`.
- **Scoped styles by default** — CSS in the `<style>` block; `:global()` only at documented theme
  seams. Use `class:`/`style:` directives over string concatenation.
- **One concern per component.** A ballooning prop list is the signal to split or use **snippets**
  (`{#snippet}` / `{@render}`) — the typed replacement for slots. Wrap third-party widgets behind a
  thin local component so a swap is a one-file change.
- **Route logging through a `logger` module**, not raw `console.*` (enforced by Biome `noConsole`).

## 3. SvelteKit project structure & file routing

Routing is **directory-based** under `src/routes/`; the filename determines the role.

| File | Runs on | Role |
|---|---|---|
| `+page.svelte` | client + SSR | the page UI; reads `data` / `form` props |
| `+page.ts` | server + client | **universal** `load` — runs on both, output must be serializable |
| `+page.server.ts` | server only | server `load` + form `actions`; safe for DB/secrets |
| `+layout.svelte` / `+layout(.server).ts` | as above | persistent shell + inherited `load` data |
| `+server.ts` | server only | API endpoint (`GET`/`POST`/…) — see §9 |
| `+error.svelte` | client + SSR | nearest error boundary for the segment |
| `hooks.server.ts` | server only | request middleware (`handle`, `handleFetch`) — §9 |

- **`$lib`** (`src/lib/`) is the only shared layer — import via the `$lib` alias, never `../../../`.
  Anything under `src/lib/server/` is **compile-time guaranteed** to never reach the client; put DB
  clients, secrets, and server utils there.
- `[param]` for dynamic, `[...rest]` for catch-all, `(group)/` for layout grouping with no URL
  impact, `[[optional]]` for optional segments.

## 4. Load functions: universal vs server

**Default to `+page.server.ts` `load` when the data touches a DB, secret, or private API; use
`+page.ts` only when the fetch is public and you want it to continue on the client.**

```ts
// +page.server.ts — server-only: DB access, secrets, never shipped to the browser
import type { PageServerLoad } from './$types';
export const load: PageServerLoad = async ({ params, locals, depends }) => {
  depends('app:item');                              // tag for targeted invalidation (§8)
  const item = await locals.db.item.findUnique({ where: { id: params.id } });
  return { item: itemSchema.parse(item) };          // serialized to the page payload
};
```

- **Use the generated `./$types`** (`PageLoad`, `PageServerLoad`, …) — never hand-type the event;
  they give typed `params`, `data`, and the load chain.
- **Use the event-scoped `fetch`** inside `load`, not the global — it forwards cookies/headers,
  dedupes against SSR, and inlines the response into the payload (no client refetch on hydration).
- **Validate every external boundary with a schema (Zod)** in `load`/actions — parse, don't cast.
  See [api-design.md](../design/api-design.md).
- **Don't waterfall.** Run independent fetches with `Promise.all`; return promises directly to
  stream non-critical data via `{#await}` instead of blocking navigation.

## 5. Rendering modes via route config

SSR is the default. Set the mode **per route** by exporting page options — don't bolt on a separate
SPA framework when one route needs to be static or client-only.

```ts
// +page.ts (or +layout.ts to apply to a subtree)
export const prerender = true;   // SSG — build-time HTML; requires no per-request data
export const ssr = false;        // CSR-only — skip server render (app-shell behind auth)
export const csr = true;         // keep hydration; set false for zero-JS static pages
```

| You need… | Set |
|---|---|
| Public/marketing page, fixed at build | `prerender = true` |
| Per-request data, SEO, personalization | default (SSR) |
| Authenticated dashboard, no SEO | `ssr = false` (CSR) |
| Pure content, no interactivity | `csr = false` (ship zero JS) |

`prerender = true` on a route that reads `url.searchParams` or per-request `locals` is a build
error by design — keep prerendered routes pure. _(scale-up)_ Set `prerender.entries` for dynamic
routes that should be crawled at build time.

## 6. Form actions + progressive enhancement

**Mutations go through `+page.server.ts` form `actions`, not client-side `fetch` to a JSON
endpoint.** Actions work without JS (native form POST), then `use:enhance` upgrades them to no-reload
fetches — progressive enhancement for free.

```ts
// +page.server.ts
import { fail } from '@sveltejs/kit';
export const actions = {
  create: async ({ request, locals }) => {
    await requireSession(locals);                         // authZ every action
    const parsed = createSchema.safeParse(Object.fromEntries(await request.formData()));
    if (!parsed.success) return fail(400, { errors: parsed.error.flatten() });
    await locals.db.item.create({ data: parsed.data });
    return { success: true };
  },
} satisfies Actions;
```

```svelte
<form method="POST" action="?/create" use:enhance>...</form>
```

- **Actions are public HTTP endpoints.** Validate with Zod and authorize on every call — a named
  action ID lets anyone POST to it; never trust a hidden field for authZ.
- **Keep the no-JS path working**: the bare `<form>` must submit before `use:enhance` is added. Use
  the `enhance` callback for optimistic UI/pending state, not to replace validation.

## 7. State management: runes, context, stores

| Kind | Home | Don't |
|---|---|---|
| Component-local UI | `$state` in the component | …lift to a global "just in case" |
| Shared logic / cross-component | a **`.svelte.ts` rune module** (factory returns getters) | …export a mutable `$state` at module top level |
| Request-scoped / per-user (SSR) | **`setContext`/`getContext`** from a `load` value or root layout | …use module-global state on the server |
| Server cache (load data) | the `load` payload + invalidation (§8) | …copy into a separate client store |

- **Runes over stores for new code.** The `writable`/`readable` store API still works (and the `$`
  auto-subscribe prefix is fine for existing code and `page`/`navigating`), but a `.svelte.ts`
  factory is the idiomatic Svelte 5 pattern.
- **Never export module-scope mutable `$state` that holds per-user data** — on the server the module
  is shared across requests, leaking one user's state into another's. Use `context` keyed off a
  per-request `load` value, or keep it strictly client-only.

## 8. Data loading & invalidation

- **`load` is the cache.** SvelteKit re-runs the relevant `load` when route params or a tracked
  dependency change — don't reimplement caching in a store.
- **Invalidate surgically.** After a mutation, `invalidate('app:item')` (matches the `depends()` tag
  from §4) or `invalidate(url)` re-runs only the affected `load`s; **`invalidateAll()` is the blunt
  instrument** for "log out / switch tenant". A form action already re-runs the page's `load` — don't
  stack `invalidateAll()` on top.

## 9. Server endpoints & hooks

`+server.ts` handlers are the API for external/mobile clients, webhooks, and streaming; prefer form
actions (§6) for same-app mutations. Follow [api-design.md](../design/api-design.md) for naming,
status codes, and error shape.

```ts
// src/routes/api/items/+server.ts
import { json, error } from '@sveltejs/kit';
export const GET: RequestHandler = async ({ locals }) => {
  if (!locals.user) error(401);                 // same trust model as any public API
  return json(await getItems(locals));
};
```

- **`hooks.server.ts` `handle` is the single auth/session seam** — resolve the session once, attach
  it to `event.locals` (typed in `app.d.ts`), read `locals` everywhere; don't re-parse cookies per
  handler.
- **Authorize at the data source**, not only in `handle` — a middleware-only check is one refactor
  from bypass. Validate input on every endpoint and action.
- See [security.md](../practices/security.md) for CORS, CSRF (SvelteKit checks `Origin` on form
  POSTs by default — keep it on), rate-limiting, and secret handling.

## 10. Env & the public boundary

SvelteKit splits env into four modules — the static/dynamic and public/private axes are enforced by
the compiler.

| Module | Contents | Exposure |
|---|---|---|
| `$env/static/private` | secrets, build-time inlined | **server only** — import from a Client Component is a build error |
| `$env/static/public` | `PUBLIC_`-prefixed, build-time inlined | shipped to the browser — **no secrets** |
| `$env/dynamic/private` | runtime server env | server only |
| `$env/dynamic/public` | runtime `PUBLIC_` env | browser |

- **The `PUBLIC_` prefix is a boundary, not a safeguard** — `$env/*/public` values are bundled as
  plaintext. Never put tokens or internal URLs there.
- Prefer `$env/static/*` so missing config fails the **build**, not a production request. Use
  `$env/dynamic/*` only when the value genuinely isn't known until runtime (e.g. container env).

## 11. Adapters & deployment

- **Pick the adapter for the target** in `svelte.config.js`: `adapter-node` (containers →
  [docker.md](../platform/docker.md)), `adapter-vercel`, `adapter-cloudflare`, or `adapter-static`
  (fully prerendered sites). `adapter-auto` is for getting started — pin a concrete one for
  production so the build is deterministic.
- **`adapter-static` requires `prerender = true`** app-wide (or a SPA `fallback`); it can't serve
  per-request `load` — match the adapter to your rendering modes (§5).
- **Bundle hygiene:** the build is Vite/Rollup — inspect with `rollup-plugin-visualizer`, gate CI on
  `size-limit`. _(scale-up)_ Hold a Core Web Vitals budget (LCP ≤ 2.5 s, INP ≤ 200 ms, CLS ≤ 0.1)
  via Lighthouse-CI.

## 12. Accessibility

Target **WCAG 2.2 AA**; a11y is a build requirement, not a polish step. Details and the CI gate live
in [accessibility.md](../practices/accessibility.md).

- **Don't suppress Svelte's compiler a11y warnings.** It flags missing `alt`, label-less controls,
  `click` without keyboard handlers, and redundant roles at build time — fail CI on `svelte-check`
  warnings; don't `<!-- svelte-ignore -->` them away.
- **Semantic HTML first** — real `<button>`/`<nav>`/`<main>`/headings; ARIA supplements, never
  replaces, semantics. Manage focus on navigation and dialog open/close.
- **CI gate:** an **axe / Lighthouse-a11y** run so runtime violations (contrast, focus order) also
  fail the build, driven by behaviour tests (roles/labels, §13).

## 13. Testing

| Layer | Tool |
|---|---|
| Unit (rune modules, utils) | **Vitest** (jsdom for component tests, node for `.svelte.ts` logic) |
| Component | **@testing-library/svelte** + `@vitest/browser` for real-DOM interaction |
| E2E / routing / SSR / actions | **Playwright** |

- Use `vitest-browser-svelte` (or `@testing-library/svelte`) and test **behaviour and
  accessibility** — roles, labels, user events — not implementation details. Mock the network with
  **MSW**, not `fetch`.
- **`load` functions, form actions, and `+server.ts` are server code** — test them as functions /
  HTTP endpoints, not only through the rendered UI. SSR correctness, auth redirects, and progressive
  enhancement belong in Playwright. See [testing-strategy.md](../practices/testing-strategy.md).
- Run `svelte-check` in CI alongside `tsc` — it catches template type errors and a11y warnings the
  type-checker can't.

## Definition of done

- [ ] Language DoD met ([typescript.md](../languages/typescript.md)): `biome ci`, `svelte-check`,
      `tsc`, tests, supply chain
- [ ] Runes only (`$state`/`$derived`/`$effect`/`$props`); no legacy `$:`/`export let` in new code (§1)
- [ ] Computed state via `$derived`, not `$effect` writing the state it reads (§1)
- [ ] DB/secret data loaded in `+page.server.ts`; universal `load` only for public fetches (§4)
- [ ] Mutations are form `actions` with `use:enhance`; the no-JS form path still works (§6)
- [ ] Every action/endpoint validates input (Zod) and authorizes; `handle` resolves session to `locals` (§6/§9)
- [ ] No module-scope mutable `$state` holding per-user data (SSR cross-request leak) (§7)
- [ ] Invalidation is surgical (`invalidate(tag)`), not reflexive `invalidateAll()` (§8)
- [ ] No secrets behind `$env/*/public`; static env preferred so misconfig fails the build (§10)
- [ ] Concrete adapter pinned; rendering modes (`prerender`/`ssr`/`csr`) match each route (§5/§11)
- [ ] Svelte a11y warnings unsuppressed; `svelte-check` warnings fail CI; axe/Lighthouse-a11y green (§12)
- [ ] Playwright covers routing, SSR, auth-redirect, and form-action flows (§13)

**Sources:** [Svelte 5 docs — Runes](https://svelte.dev/docs/svelte/what-are-runes) ·
[Svelte — `$derived` vs `$effect`](https://svelte.dev/docs/svelte/$effect#When-not-to-use-$effect) ·
[SvelteKit — Loading data](https://svelte.dev/docs/kit/load) ·
[SvelteKit — Form actions](https://svelte.dev/docs/kit/form-actions) ·
[SvelteKit — Page options (ssr/csr/prerender)](https://svelte.dev/docs/kit/page-options) ·
[SvelteKit — `$env` modules](https://svelte.dev/docs/kit/$env-static-private) ·
[SvelteKit — Adapters](https://svelte.dev/docs/kit/adapters) ·
[Testing Library — Svelte](https://testing-library.com/docs/svelte-testing-library/intro)
