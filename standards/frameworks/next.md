# Next.js (App Router)

Meta-framework over React — component rules → [react.md](react.md); language → [typescript.md](../languages/typescript.md). Dependencies and supply-chain defer to [typescript.md](../languages/typescript.md) + [security.md](../practices/security.md).

Choose Next.js over a Vite SPA ([react.md](react.md)) when you need SSR, SSG, streaming, edge
rendering, or SEO — i.e., when the server/routing layer earns its keep. If you're building a
purely client-side tool or an internal dashboard where none of those apply, stay with Vite.

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
| `route.ts` | Route Handler (API); no UI — see §5 |
| `template.tsx` | Like layout but **re-mounts** on navigation (rare) |

**Colocation rule**: keep components, hooks, and utilities next to the route that owns them. Only
promote to `components/` or `lib/` when two or more routes share the code.

Group routes with `(group)/` folders (no URL impact) to share layouts without polluting the path.
Use `[param]` for dynamic segments; `[...slug]` for catch-all; `[[...slug]]` for optional catch-all.

**Top-level layout** (Blazity/T3 convention). Dependencies flow **one way: `app/` → `components/` → `lib/`**.

| Folder | Holds | Rule |
|---|---|---|
| `app/` | Routes, pages, layouts, `route.ts` handlers | The only routable layer |
| `components/` | Shared UI promoted from routes | May import `lib/`, never `app/` |
| `lib/` | The app core: data-access layer, Server Actions, Zod schemas, auth, db client, utils | Imports nothing from `app/` or `components/` |
| `env.mjs` | Zod-validated env (`@t3-oss/env-nextjs`) | Import this, never raw `process.env` |
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

Use `import 'server-only'` at the top of any module that must never be bundled client-side.

## 3. Data fetching & caching

Fetch in Server Components or Route Handlers — not in `useEffect`.

```ts
// Server Component — opt into caching explicitly (Next 15 default: no-store)
const data = await fetch('https://api.example.com/items', {
  next: { revalidate: 60, tags: ['items'] },   // ISR-style revalidation
});

// On-demand revalidation from a Server Action or Route Handler
import { revalidateTag } from 'next/cache';
revalidateTag('items');
```

**Next 15 caching defaults changed**: `fetch` is `no-store` by default (dynamic). Opt into caching
explicitly with `{ next: { revalidate: N } }` or `{ cache: 'force-cache' }`. `cookies()` /
`headers()` / `searchParams` opt a route into dynamic rendering automatically.

Use `unstable_cache` (or `'use cache'` in canary) for non-`fetch` data sources (ORM, Redis).

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
  // ... persist, then revalidateTag('items')
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
  const session = await decrypt(cookies().get('session')?.value);
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

- **Middleware is not auth.** CVE-2025-29927 let attackers bypass middleware-only auth via a forged
  header. Middleware does *optimistic* redirects (reads the cookie, no DB hit); the real check lives
  in the DAL. Never make middleware your only line of defense.
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
| **PPR** _(scale-up)_ | Partial Prerendering — static shell + dynamic holes; opt in per route |

Use the Metadata API for SEO — never raw `<head>` tags:

```ts
// app/products/[id]/page.tsx
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const product = await getProduct(params.id);
  return { title: product.name, description: product.description };
}
```

Export `generateStaticParams` for dynamic routes that should be pre-rendered at build time.

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

GET handlers are **uncached by default in Next 15** (was cached in 14) — opt in explicitly if a
response is shareable. Prefer Server Actions for form mutations that stay within the Next.js app;
reserve Route Handlers for external/mobile clients, webhooks, large uploads, and streaming.

## 7. Build & deploy

| Concern | Standard |
|---|---|
| Dev bundler | **Turbopack** (`next dev --turbo`); ~10× faster rebuilds than webpack |
| Production build | `next build` — stays webpack by default until Turbopack reaches stable |
| Output mode | `standalone` for Docker/container deploys; `export` for fully static; default for Vercel |
| Image optimization | Use `next/image` — never raw `<img>` for user-facing images |
| Font optimization | `next/font` — self-hosted, no FOUT, no layout shift |

**Env vars**: `NEXT_PUBLIC_*` is a **public boundary** — values are inlined into the client bundle
at build time. Treat them exactly like `VITE_*`: no secrets, no tokens, no internal URLs. Server-only
secrets go in plain `process.env.*` and are never forwarded to Client Components. See
[app-security.md](../practices/app-security.md).

Validate all env vars at startup with Zod (or `@t3-oss/env-nextjs`) so missing config fails fast
rather than at runtime in production.

## 8. Performance

Bundle size and Web Vitals budgets follow [react.md](react.md). Next-specific rules:

- **No client-component waterfalls**: if a Client Component fetches data, it will waterfall after
  hydration. Move the fetch to the Server Component parent and pass data as props.
- Dynamic-import (`next/dynamic`) with `{ ssr: false }` for heavy client-only widgets (charts,
  editors, maps) to keep the initial HTML lean.
- `next/image` enforces size, lazy-loading, and modern format (WebP/AVIF) automatically.
- Check bundle size with `@next/bundle-analyzer`; the RSC payload is separate from the JS bundle —
  profile both.

## 9. Testing

- **Component/unit tests**: follow [react.md](react.md) (Vitest + React Testing Library).
- **E2E (Playwright)**: required for routing flows, SSR correctness, auth redirects, and streaming
  UI. Tests that depend on the actual server are not meaningful in jsdom. See
  [testing-strategy.md](../practices/testing-strategy.md).
- Test Server Actions and Route Handlers as HTTP endpoints in integration tests — not just via
  the UI path.

---

## Definition of done

- [ ] All routes in `app/`; no Pages Router (`pages/`) mixing.
- [ ] Dependency direction holds: `app/` → `components/` → `lib/`; absolute imports only.
- [ ] Components are Server by default; `'use client'` only at interaction leaves.
- [ ] No secrets or server-only imports reachable from Client Components.
- [ ] `NEXT_PUBLIC_*` vars contain no credentials; env validated with Zod (`env.mjs`) at startup.
- [ ] Reads and writes go through a DAL that calls `verifySession()`; auth is **not** done only in
      middleware or `layout.tsx`; responses are DTOs, not raw rows.
- [ ] Mutations use Server Actions (verify session → Zod validate → authorize) or Route Handlers.
- [ ] Caching strategy is explicit — no accidental `no-store` on pages that should be cached.
- [ ] `next/image` used for all user-facing images; `next/font` for typefaces.
- [ ] Playwright e2e covers critical routing, auth-redirect, and SSR paths.
- [ ] `pnpm build` passes with no TS errors; bundle analyzer checked for regressions.

---

**Sources:** [Blazity/next-enterprise](https://github.com/Blazity/next-enterprise) · [t3-oss/create-t3-app](https://github.com/t3-oss/create-t3-app) · [Next.js: Authentication (DAL, DTO, authZ)](https://nextjs.org/docs/app/guides/authentication) · [Next.js: Security in Server Components & Actions](https://nextjs.org/blog/security-nextjs-server-components-actions) · [Next.js 15 release notes (caching defaults)](https://nextjs.org/blog/next-15) · [CVE-2025-29927 — middleware auth bypass](https://github.com/vercel/next.js/security/advisories/GHSA-f82v-jwr5-mffw)
