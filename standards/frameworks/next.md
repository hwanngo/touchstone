# Next.js (App Router)

Meta-framework over React — component rules → [react.md](react.md); language → [typescript.md](../languages/typescript.md). Dependencies and supply-chain defer to [typescript.md](../languages/typescript.md) + [security.md](../practices/security.md).

Choose Next.js over a Vite SPA ([react.md](react.md)) when you need SSR, SSG, streaming, edge
rendering, or SEO — i.e., when the server/routing layer earns its keep. If you're building a
purely client-side tool or an internal dashboard where none of those apply, stay with Vite.

**Baseline: Next.js 16** (App Router). It requires **Node.js 20.9+** and **TypeScript 5.1+**, and
targets Chrome/Edge/Firefox 111+ and Safari 16.4+. Upgrading from 15 is not a no-op — the removals
and changed defaults are collected in §7; the two that touch every file are **async Request APIs**
(§3) and **`middleware` → `proxy`** (§4). Run `npx @next/codemod@canary upgrade latest` first, then
fix what it can't.

---

## 1. App Router structure

All routes live under `app/`. Route segments = folders; the file name determines the role.

| File | Role |
|---|---|
| `page.tsx` | Publicly routable UI; receives `params` / `searchParams` |
| `layout.tsx` | Persistent shell; wraps children without re-mounting |
| `loading.tsx` | Suspense boundary shown while the segment streams |
| `error.tsx` | Error boundary (`'use client'`); receives `error` + `reset` |
| `not-found.tsx` | Renders when `notFound()` is called in the segment |
| `route.ts` | Route Handler (API); no UI — see §6 |
| `template.tsx` | Like layout but **re-mounts** on navigation (rare) |
| `default.tsx` | Fallback for a parallel-route slot — **required** for every slot in Next 16 |

**Colocation rule**: keep components, hooks, and utilities next to the route that owns them. Only
promote to `components/` or `lib/` when two or more routes share the code.

Group routes with `(group)/` folders (no URL impact) to share layouts without polluting the path.
Use `[param]` for dynamic segments; `[...slug]` for catch-all; `[[...slug]]` for optional catch-all.

**Every parallel-route slot (`@modal`, `@sidebar`) needs an explicit `default.tsx`** — Next 16
fails the build without one, where 15 silently inferred a fallback. Return `null`, or call
`notFound()` to reproduce the old behaviour.

**Top-level layout** (Blazity/T3 convention). Dependencies flow **one way: `app/` → `components/` → `lib/`**.

| Folder | Holds | Rule |
|---|---|---|
| `app/` | Routes, pages, layouts, `route.ts` handlers | The only routable layer |
| `components/` | Shared UI promoted from routes | May import `lib/`, never `app/` |
| `lib/` | The app core: data-access layer, Server Actions, Zod schemas, auth, db client, utils | Imports nothing from `app/` or `components/` |
| `env.mjs` | Zod-validated env (`@t3-oss/env-nextjs`) | Import this, never raw `process.env` |
| `proxy.ts` | App-entry request rewrites/redirects (was `middleware.ts`) | **Not an auth boundary** — see §4 |
| `instrumentation.ts` | OpenTelemetry / tracing bootstrap | _(scale-up)_ |

Enforce absolute imports (`@/lib/...`) and the dependency direction with an ESLint boundary rule.

## 2. Server vs Client Components

**Server Components are the default.** Add `'use client'` only at the leaf that actually requires
browser APIs, event handlers, or React state/effects. Keep the client bundle small.

| Stays on server | Moves to client |
|---|---|
| Data fetching, DB access | `onClick`, `onChange` handlers |
| Secrets, tokens, env vars | `useState`, `useEffect`, `useRef` |
| Large third-party imports (parsers, SDKs) | Browser APIs (`window`, `navigator`) |
| SEO-critical markup | Third-party client widgets |

**The Server → Client boundary is a trust boundary.** Never import server-only modules (`server-only`
package) from Client Components; never pass secrets or server tokens as props into a Client
Component — they become part of the serialized payload and are exposed to the browser. See
[app-security.md](../practices/app-security.md).

Use `import 'server-only'` at the top of any module that must never be bundled client-side. For
defense in depth on the values themselves, enable the `taint` config option and taint secrets and
whole user records, so passing one into a Client Component throws at render instead of shipping.

## 3. Data fetching & caching

Fetch in Server Components or Route Handlers — not in `useEffect`.

**Request APIs are async, and Next 16 removed the synchronous fallback.** `cookies()`, `headers()`,
`draftMode()`, and the `params` / `searchParams` props must be awaited — reading them synchronously
no longer warns, it fails. Generate the prop types with `npx next typegen` and use the
`PageProps` / `LayoutProps` / `RouteContext` helpers rather than hand-writing them:

```ts
// app/items/[id]/page.tsx
export default async function Page(props: PageProps<'/items/[id]'>) {
  const { id } = await props.params;               // params is a Promise
  const { sort } = await props.searchParams;       // so is searchParams
  const data = await fetch(`https://api.example.com/items/${id}`, {
    next: { revalidate: 60, tags: ['items'] },     // ISR-style revalidation
  });
  // ...
}
```

**Caching is opt-in.** `fetch` is uncached by default (dynamic); opt in explicitly with
`{ next: { revalidate: N } }` or `{ cache: 'force-cache' }`. Awaiting `cookies()` / `headers()` /
`searchParams` opts a route into dynamic rendering automatically.

**On-demand invalidation — pick the one that matches the semantics you owe the user:**

| API | Semantics | Use when |
|---|---|---|
| `revalidateTag(tag, profile)` | stale-while-revalidate | Blog posts, catalogs, docs — a short delay is fine |
| `updateTag(tag)` | read-your-writes; expires **and** refreshes in the same request | The user just changed this and must see it now |
| `refresh()` | re-renders the client router from a Server Action | A header count or badge changed out of band |

`revalidateTag` **now requires the second `cacheLife` profile argument** — the single-argument form
is deprecated and is a TypeScript error. `updateTag` and `refresh` are Server-Action-only.

```ts
'use server';
import { revalidateTag, updateTag } from 'next/cache';

revalidateTag('items', 'max');   // others may see stale data briefly
updateTag(`user-${userId}`);     // this user sees their own write immediately
```

**Explicit caching for non-`fetch` sources** (ORM, Redis): enable `cacheComponents` in
`next.config.ts` and mark the function with `'use cache'`, then scope it with `cacheLife` /
`cacheTag` — both stable in Next 16, so drop any `unstable_`-prefixed imports and aliases.

**Server Actions for mutations** — every action: verify session → validate input → authorize → persist:

```ts
'use server';
import { z } from 'zod';
import { verifySession } from '@/lib/dal';   // see §4

const Schema = z.object({ name: z.string().min(1) });

export async function createItem(formData: FormData) {
  const { role } = await verifySession();                  // authN
  const parsed = Schema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) return { error: parsed.error.flatten() };
  if (role !== 'editor') return { error: 'forbidden' };    // authZ
  // ... persist, then revalidateTag('items', 'max')
}
```

Server Actions are **public HTTP endpoints** — a generated ID lets anyone POST to them. Validate
input with Zod and authorize on every call; never assume the caller is trusted because the function
looks internal, and never branch authZ on a value passed in as a hidden form field.

## 4. Auth & the Data Access Layer

Authorize **at the data source**, not at the route edge. Centralize every read/write behind a Data
Access Layer in `lib/dal.ts` whose functions call `verifySession()` first, so a missing check is
impossible to ship by forgetting it in one place.

```ts
// lib/dal.ts
import 'server-only';
import { cache } from 'react';

export const verifySession = cache(async () => {       // cache() dedupes per render
  const cookieStore = await cookies();                 // async in Next 16 — see §3
  const session = await decrypt(cookieStore.get('session')?.value);
  if (!session?.userId) redirect('/login');
  return { userId: session.userId, role: session.role };
});

export const getUser = cache(async () => {
  const { userId } = await verifySession();
  // return a DTO — only the columns the client may see, never the whole row
  return db.user.findUnique({ where: { id: userId }, select: { id: true, name: true } });
});
```

Rules, in order of importance:

- **`proxy.ts` is not auth.** Next 16 renamed `middleware.ts` → **`proxy.ts`** (and the exported
  `middleware` function → `proxy`) precisely to stop it reading as a security layer: it is a
  network/routing hook. CVE-2025-29927 let attackers bypass middleware-only auth via a forged
  header, and the rename doesn't fix that class — it names it. `proxy.ts` does *optimistic*
  redirects (reads the cookie, no DB hit); the real check lives in the DAL. Never make it your only
  line of defense. Config flags renamed with it (`skipMiddlewareUrlNormalize` →
  `skipProxyUrlNormalize`). `proxy` runs on the **Node.js runtime only** — the `edge` runtime is
  not supported there, so an edge-runtime middleware has to stay on the old filename for now.
- **Don't auth in `layout.tsx`.** Layouts don't re-render on navigation (partial rendering), so the
  check goes stale. Verify in the page, the DAL, or the leaf component that renders sensitive data.
- **Return DTOs, not rows.** `select` the exact columns; never serialize a full user record (it
  carries password hashes, tokens, PII) into the RSC payload.
- Use an auth library (Auth.js, Clerk, WorkOS, Supabase) over hand-rolled sessions. See
  [app-security.md](../practices/app-security.md).

## 5. Rendering modes & SEO

| Mode | When to use |
|---|---|
| **Static** (SSG) | Content fixed at build time; no per-request data |
| **Dynamic** (SSR) | Per-request data; personalization; auth-gated pages |
| **Streaming** | Long data fetches; wrap slow subtrees in `<Suspense>` |
| **PPR** _(scale-up)_ | Partial Prerendering — static shell + dynamic holes |

**PPR is now reached through Cache Components.** Next 16 removed the `experimental.ppr` flag and
the per-route `experimental_ppr` segment config; set top-level `cacheComponents: true` instead
(which also replaces the removed `experimental.dynamicIO` and `experimental.useCache`). The model
differs from the Next 15 canaries — if you have PPR in production today, migrate deliberately
rather than by bumping the version.

Use the Metadata API for SEO — never raw `<head>` tags:

```ts
// app/products/[id]/page.tsx
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { id } = await params;                    // async in Next 16 — see §3
  const product = await getProduct(id);
  return { title: product.name, description: product.description };
}
```

Export `generateStaticParams` for dynamic routes that should be pre-rendered at build time. The
metadata **image** conventions went async too: `opengraph-image`, `twitter-image`, `icon`, and
`apple-icon` receive `params` and `id` as Promises, as does `sitemap`'s `id` — but
`generateImageMetadata` still receives `params` synchronously.

## 6. Route Handlers

`app/api/**/route.ts` is the API layer. Follow [api-design.md](../design/api-design.md) for
resource naming, status codes, error shape, and versioning.

```ts
// app/api/items/route.ts
import { NextResponse } from 'next/server';
import { verifySession } from '@/lib/dal';

export async function GET() {
  const session = await verifySession();        // same trust model as a public API
  if (!session) return new Response(null, { status: 401 });
  return NextResponse.json(await getItems());
}
```

GET handlers are **uncached by default** (they were cached in Next 14) — opt in explicitly if a
response is shareable. `params` in `route.ts` is a Promise like everywhere else in Next 16; type it
with the generated `RouteContext<'/items/[id]'>` helper. Prefer Server Actions for form mutations
that stay within the Next.js app; reserve Route Handlers for external/mobile clients, webhooks,
large uploads, and streaming.

## 7. Build & deploy

| Concern | Standard |
|---|---|
| Bundler | **Turbopack**, the default for both `next dev` and `next build` in Next 16 — drop the `--turbopack` flag from your scripts |
| Webpack escape hatch | `next build --webpack`. A `webpack` config present with the default bundler **fails the build** by design — migrate it or opt out explicitly |
| Turbopack config | Top-level `turbopack: {}` in `next.config.ts` (was `experimental.turbopack`) |
| Output mode | `standalone` for Docker/container deploys; `export` for fully static; default for Vercel |
| Image optimization | Use `next/image` — never raw `<img>` for user-facing images |
| Font optimization | `next/font` — self-hosted, no FOUT, no layout shift |
| Linting | `next lint` is **removed**; run ESLint or Biome directly, and `next build` no longer lints — so the lint gate must be its own CI step ([ci-cd.md](../platform/ci-cd.md)) |
| React Compiler | `reactCompiler: true` — stable config in Next 16, off by default; adopt it per [react.md](react.md) |

**Removed in Next 16 — these fail rather than warn**: AMP (`next/amp`, `export const config = { amp: true }`),
`serverRuntimeConfig` / `publicRuntimeConfig` (use env vars), `unstable_rootParams`, the
`eslint` key in `next.config`, and several `devIndicators` options. `next/legacy/image` and
`images.domains` are deprecated — move to `next/image` and `images.remotePatterns`.

**`next/image` defaults tightened** (each is a behaviour change on upgrade, and most of them are
security or cost fixes rather than cosmetics): `minimumCacheTTL` 60s → **4h**; `qualities`
restricted to **`[75]`**; `16` dropped from `imageSizes`; local sources with query strings now
require an `images.localPatterns.search` entry (blocks enumeration); optimizing **local IPs is
blocked** unless you set `dangerouslyAllowLocalIP`; and redirects are capped at **3**
(`maximumRedirects`). Audit these before assuming an upgrade is transparent.

**Env vars**: `NEXT_PUBLIC_*` is a **public boundary** — values are inlined into the client bundle
at build time. Treat them exactly like `VITE_*`: no secrets, no tokens, no internal URLs. Server-only
secrets go in plain `process.env.*` and are never forwarded to Client Components. See
[app-security.md](../practices/app-security.md).

Validate all env vars at startup with Zod (or `@t3-oss/env-nextjs`) so missing config fails fast
rather than at runtime in production. `serverRuntimeConfig` being gone means genuinely *runtime*
values (read from the environment at request time, not baked in at build) need `await connection()`
before the `process.env` read, or they get inlined during prerender.

## 8. Performance

Bundle size and Web Vitals budgets follow [react.md](react.md). Next-specific rules:

- **No client-component waterfalls**: if a Client Component fetches data, it will waterfall after
  hydration. Move the fetch to the Server Component parent and pass data as props.
- Dynamic-import (`next/dynamic`) with `{ ssr: false }` for heavy client-only widgets (charts,
  editors, maps) to keep the initial HTML lean.
- `next/image` enforces size, lazy-loading, and modern format (WebP/AVIF) automatically.
- Check bundle size with `@next/bundle-analyzer`; the RSC payload is separate from the JS bundle —
  profile both. **Next 16 removed the `Size` / `First Load JS` columns from `next build` output**
  (they were wrong for RSC architectures), so a CI budget can no longer scrape them — measure with
  Lighthouse/CWV against a deployed build instead ([performance.md](../practices/performance.md)).
- Next 16 rewrote prefetching: layouts shared across prefetched URLs download once, and only the
  parts not already cached are fetched. Expect **more requests at a lower total transfer size** —
  don't read the request-count rise in a waterfall as a regression.

## 9. Testing

- **Component/unit tests**: follow [react.md](react.md) (Vitest + React Testing Library).
- **E2E (Playwright)**: required for routing flows, SSR correctness, auth redirects, and streaming
  UI. Tests that depend on the actual server are not meaningful in jsdom. See
  [testing-strategy.md](../practices/testing-strategy.md).
- Test Server Actions and Route Handlers as HTTP endpoints in integration tests — not just via
  the UI path.

---

## Definition of done

- [ ] Next.js **16** on Node 20.9+ / TypeScript 5.1+; the v16 codemod has been run and its leftovers fixed.
- [ ] All routes in `app/`; no Pages Router (`pages/`) mixing. Every parallel slot has a `default.tsx`.
- [ ] Dependency direction holds: `app/` → `components/` → `lib/`; absolute imports only.
- [ ] Components are Server by default; `'use client'` only at interaction leaves.
- [ ] No secrets or server-only imports reachable from Client Components.
- [ ] `NEXT_PUBLIC_*` vars contain no credentials; env validated with Zod (`env.mjs`) at startup.
- [ ] Request APIs are awaited everywhere (`cookies`, `headers`, `draftMode`, `params`,
      `searchParams`); prop types come from `next typegen`, not hand-written.
- [ ] Reads and writes go through a DAL that calls `verifySession()`; auth is **not** done only in
      `proxy.ts` or `layout.tsx`; responses are DTOs, not raw rows.
- [ ] Mutations use Server Actions (verify session → Zod validate → authorize) or Route Handlers.
- [ ] Caching strategy is explicit — no accidental uncached rendering on pages that should be
      cached; `revalidateTag` passes a `cacheLife` profile; `updateTag` used where the user must
      see their own write.
- [ ] `next/image` used for all user-facing images; `next/font` for typefaces; the v16 image
      defaults (quality, TTL, local patterns, redirects) reviewed rather than inherited blindly.
- [ ] Lint runs as its own CI step — `next build` no longer lints and `next lint` is gone.
- [ ] Playwright e2e covers critical routing, auth-redirect, and SSR paths.
- [ ] `pnpm build` passes with no TS errors under Turbopack; bundle analyzer checked for regressions.

---

**Sources:** [Blazity/next-enterprise](https://github.com/Blazity/next-enterprise) · [t3-oss/create-t3-app](https://github.com/t3-oss/create-t3-app) · [Next.js: Authentication (DAL, DTO, authZ)](https://nextjs.org/docs/app/guides/authentication) · [Next.js: Security in Server Components & Actions](https://nextjs.org/blog/security-nextjs-server-components-actions) · [Next.js 16 release notes](https://nextjs.org/blog/next-16) · [Next.js: Upgrading to version 16](https://nextjs.org/docs/app/guides/upgrading/version-16) · [CVE-2025-29927 — middleware auth bypass](https://github.com/vercel/next.js/security/advisories/GHSA-f82v-jwr5-mffw)
