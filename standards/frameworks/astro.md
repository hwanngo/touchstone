# Astro Standards

Framework layer; language rules → [typescript.md](../languages/typescript.md). This doc owns the
islands model, `.astro` components, content collections, and rendering modes — defer
language/tsconfig/test-runner mechanics to TypeScript, the framework islands you embed to
[react.md](react.md) / [svelte.md](svelte.md), a11y to [accessibility.md](../practices/accessibility.md),
budgets to [performance.md](../practices/performance.md), and auth/secrets to
[security.md](../practices/security.md).

Applies to new content-driven sites on **Astro 5** (Vite-based; verify the current release). Type-checked with **`astro check`** +
**tsc**, tested with **Vitest** (`getViteConfig`) and **Playwright**.

> **One law:** ship HTML, not a runtime — every kilobyte of client JS must be earned by an island,
> and the default is zero.

---

## 1. Choose Astro for content, not for apps

Astro's whole advantage is shipping **zero JavaScript by default**; it earns its keep when the page
is mostly content and interactivity is local and sparse.

| Reach for Astro | Reach elsewhere |
|---|---|
| Marketing sites, blogs, docs, landing pages | Highly-interactive SPAs / dashboards → [react.md](react.md) |
| Content-heavy pages with a few interactive islands | App-shell behind auth with shared client state → [svelte.md](svelte.md) |
| SEO-critical, fast-LCP, mostly-static output | A single stateful UI graph spanning the whole page |

- **If most of the page is interactive, you're fighting the framework** — an island per widget is
  right; "the entire page is one big island" means you wanted a SPA framework. Pick the tool by how
  much of the page is content vs. application.

## 2. Islands architecture & zero-JS by default

A page is **static HTML with isolated interactive islands**. Astro renders every component to HTML
at build/request time and ships **no client JS** unless an island opts in.

- **`.astro` components are always zero-JS** — they render to HTML and vanish; their frontmatter
  runs only on the server. Use them for everything that doesn't need browser interactivity.
- **An island is a framework component (React/Vue/Svelte/…) with a `client:*` directive.** Without
  a directive it is server-rendered to static HTML like everything else — the directive is the only
  thing that ships a hydration bundle.
- **Islands are isolated** — each hydrates independently and shares no client state by default;
  cross-island state needs an explicit store (nanostores) or the URL.
- **Server islands** (`server:defer`) render a placeholder in the static shell and stream the
  dynamic component per-request — personalize a cached page without making the whole route dynamic. _(scale-up)_

## 3. `.astro` components & frontmatter

```astro
---
// Frontmatter: runs on the SERVER only — never shipped to the browser.
import Card from '../components/Card.astro';
import { getCollection } from 'astro:content';
interface Props { title: string }       // typed props — the component contract
const { title } = Astro.props;
const posts = await getCollection('blog');   // top-level await, server-side
---
<h1>{title}</h1>
{posts.map((p) => <Card title={p.data.title} href={`/blog/${p.id}`} />)}

<style>h1 { color: var(--accent); }</style>  /* scoped by default */
```

- **Frontmatter is server-only** — DB calls, secrets, and `import`s of heavy SDKs stay here and
  never reach the client. Treat it as the trust boundary; the markup below is what ships.
- **Type `Props`** with an `interface`/`type` so the component has a checked contract; `astro check`
  verifies usages. Scoped `<style>` is the default — reach for `is:global` only at theme seams.
- **Route logging through a `logger` module**, not raw `console.*`; keep frontmatter side-effect-light
  so prerender stays pure.

## 4. Client directives — choose the minimum

The directive picks **when** an island hydrates. Default to the laziest one that still feels instant;
every upgrade toward `client:load` costs main-thread time on first paint.

| Directive | Hydrates | Use for |
|---|---|---|
| *(none)* | never — static HTML | anything non-interactive (the default) |
| `client:visible` | when it scrolls into view (`IntersectionObserver`) | **below-the-fold** widgets — the right default for most islands |
| `client:idle` | when the main thread goes idle | low-priority above-the-fold UI (newsletter box) |
| `client:load` | immediately on page load | critical above-the-fold interactivity only (nav, hero carousel) |
| `client:media={query}` | when a media query matches | mobile-only menus — skip the JS on desktop |
| `client:only="react"` | client only, **no SSR HTML** | components that break under SSR (must name the framework) |

- **`client:visible` is the house default; `client:load` is the exception** you justify. Most
  interactivity is below the fold and can wait.
- **`client:only` ships no server HTML** — it flashes empty until hydrated and is invisible to
  crawlers; use it only for genuinely browser-only widgets, and always pass the framework name.

## 5. Framework islands are framework-agnostic

Astro embeds React, Vue, Svelte, Solid, Preact via official integrations — **mix them in one
project**, but follow each framework's own standard for the component internals.

- **Add the integration, then author the component normally** — React island rules → [react.md](react.md),
  Svelte island rules → [svelte.md](svelte.md). Astro only owns the `client:*` boundary.
- **Don't render an Astro component inside a framework island** — the island is a client tree; Astro
  components are server-only. Pass static content down via `<slot />` from the `.astro` parent instead.
- **One framework per island purpose** — multiple UI frameworks ship multiple runtimes; if two
  islands use two you pay for both. Consolidate unless a library forces the split.

## 6. Content collections via the Content Layer API

Markdown/MDX/data lives in **type-safe collections** defined in `src/content.config.ts`. Astro 5's
**Content Layer** replaces the old folder-convention collections — a `loader` is now mandatory.

```ts
// src/content.config.ts
import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';            // built-in: glob (files) / file (single data file)

const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({                              // Zod schema — validated at build (§7 typescript.md)
    title: z.string(),
    publishDate: z.coerce.date(),
    draft: z.boolean().default(false),
  }),
});
export const collections = { blog };
```

- **Every collection has a Zod `schema`** — frontmatter is untrusted input; parse it once and the
  inferred type flows into `getCollection`/`getEntry`. A bad date or missing title fails the **build**,
  not production. Mirrors the boundary rule in [typescript.md](../languages/typescript.md).
- **Use the built-in `glob`/`file` loaders for local content; a custom loader for a CMS/API** — the
  Content Layer caches loader output between builds, so external sources build incrementally.
- **Query with `getCollection`/`getEntry`**, never `import.meta.glob` or raw `fs` — you lose the
  schema, the types, and the cache. Reference entries across collections with `reference()`.

## 7. Rendering modes — static by default, on-demand where it pays

`output: 'static'` is the default: every route is prerendered to HTML at build. Opt individual
routes into on-demand rendering rather than flipping the whole site to a server.

```js
// astro.config.mjs
import { defineConfig } from 'astro/config';
import node from '@astrojs/node';                 // or @astrojs/vercel, @astrojs/cloudflare, @astrojs/netlify
export default defineConfig({
  output: 'static',                               // default; SSR routes opt in per-page
  adapter: node({ mode: 'standalone' }),          // required for ANY on-demand route
});
```

```astro
---
export const prerender = false;   // this route renders per-request (reads cookies, user data)
---
```

| You need… | Do |
|---|---|
| Marketing/blog/docs page fixed at build | default (prerendered) — no adapter, ship zero JS |
| A few dynamic routes in a mostly-static site | keep `output: 'static'`, set `prerender = false` per route (hybrid) |
| Mostly dynamic, per-request app | `output: 'server'`, prerender the static routes back with `prerender = true` |

- **An adapter is required the moment one route is on-demand** — pick the concrete adapter for the
  target (`@astrojs/node` for containers → [docker.md](../platform/docker.md), or Vercel/Netlify/Cloudflare).
  Don't ship `adapter`-less SSR; it's a build error.
- **A prerendered route that reads `Astro.request`/cookies is a bug** — keep static routes pure;
  move per-request reads behind `prerender = false` or a server island (§2).

## 8. View transitions via `<ClientRouter />`

Astro 5 renames the router component to **`<ClientRouter />`** (was `<ViewTransitions />`). Add it
to a shared `<head>` for animated, SPA-like navigation over multi-page output.

```astro
---
import { ClientRouter } from 'astro:transitions';
---
<head><ClientRouter /></head>
```

- **It's a progressive enhancement** — navigation still works without it; don't make content depend
  on a transition firing. Persist islands across navigations with `transition:persist` only where a
  player/state must survive the swap.
- **Respect `prefers-reduced-motion`** — the View Transitions API does by default; don't override it.
  Keep animations off the critical interaction path. See [accessibility.md](../practices/accessibility.md).

## 9. Image optimization is built in

- **Use `<Image />` / `<Picture />` from `astro:assets`, never a raw `<img>`** for local or
  configured-remote images — they enforce dimensions (no layout shift), lazy-load, and emit modern
  formats (WebP/AVIF) at build. Import the asset so the optimizer can process it.
- **Always set `width`/`height`** so CLS stays at zero; pass `priority` only to the LCP image and
  let everything else lazy-load.

## 10. Env & the public boundary

Use **`astro:env`** for typed, validated env split across the server/client and secret/public axes —
the schema fails the build on misconfig instead of erroring in production.

```ts
// astro.config.mjs → env.schema
import { envField } from 'astro/config';
env: { schema: {
  API_URL:    envField.string({ context: 'client', access: 'public' }),   // shipped to the browser
  API_SECRET: envField.string({ context: 'server', access: 'secret' }),   // server-only, never bundled
}}
```

- **`access: 'public'` is a boundary, not a safeguard** — public values are inlined into the client
  bundle as plaintext. No tokens, no internal URLs; secrets are `context: 'server', access: 'secret'`.
- **Importing a server/secret var into a client island is a build error** — let the compiler enforce
  the boundary instead of trusting convention. Secret handling lives in [security.md](../practices/security.md).

## 11. Performance budgets

Zero-JS is the starting line, not the finish — guard it. Full budgets live in
[performance.md](../practices/performance.md).

- **Hold a Core Web Vitals budget** (LCP ≤ 2.5 s, INP ≤ 200 ms, CLS ≤ 0.1) via Lighthouse-CI; an
  Astro site that regresses here has usually added an unjustified `client:load` or a second UI framework.
- **Audit shipped JS per route.** The win is islands staying small and lazy — gate CI on bundle size
  and watch for islands that should be `client:visible` but ship on load. _(scale-up)_

## 12. Accessibility

Target **WCAG 2.2 AA**; a11y is a build requirement, not a polish step. Details and the CI gate live
in [accessibility.md](../practices/accessibility.md).

- **Don't suppress `astro check`'s a11y warnings** — it flags missing `alt`, label-less controls,
  and bad roles at build; fail CI on them. Semantic HTML first — real `<button>`/`<nav>`/`<main>`/
  headings in `.astro` markup; ARIA supplements, never replaces, semantics, and manage focus across
  `<ClientRouter />` navigations.

## Definition of done

- [ ] Language DoD met ([typescript.md](../languages/typescript.md)): `biome ci`, `tsc`, tests, supply chain
- [ ] Page is content-first; interactivity is islands, not a whole-page SPA (§1)
- [ ] No client JS without a `client:*` directive; `client:visible` is the default, `client:load` justified (§2/§4)
- [ ] `.astro` frontmatter holds secrets/DB calls only — none reach the client (§3)
- [ ] Framework islands follow their own standard; no Astro component inside a client island (§5)
- [ ] Every content collection has a Zod `schema` + a `loader`; queried via `getCollection`/`getEntry` (§6)
- [ ] `output: 'static'` default; on-demand routes opt in per-page with a concrete `adapter` pinned (§7)
- [ ] Prerendered routes are pure (no per-request reads); view transitions degrade gracefully (§7/§8)
- [ ] `<Image />`/`<Picture />` for all images with dimensions set; LCP image prioritized (§9)
- [ ] No secrets behind `astro:env` `access: 'public'`; server vars unreachable from islands (§10)
- [ ] Core Web Vitals budget held in CI; `astro check` a11y warnings unsuppressed (§11/§12)

**Sources:** [Astro 5.0 release](https://astro.build/blog/astro-5/) ·
[Astro — Islands architecture](https://docs.astro.build/en/concepts/islands/) ·
[Astro — Client directives](https://docs.astro.build/en/reference/directives-reference/#client-directives) ·
[Astro — Content collections & Content Layer](https://docs.astro.build/en/guides/content-collections/) ·
[Astro — On-demand rendering & adapters](https://docs.astro.build/en/guides/on-demand-rendering/) ·
[Astro — View transitions (`<ClientRouter />`)](https://docs.astro.build/en/guides/view-transitions/) ·
[Astro — Images (`astro:assets`)](https://docs.astro.build/en/guides/images/) ·
[Astro — Type-safe env (`astro:env`)](https://docs.astro.build/en/guides/environment-variables/) ·
[Upgrade to Astro v5](https://docs.astro.build/en/guides/upgrade-to/v5/)
