---
name: next-standards
description: Use when building a Next.js (App Router) app in a touchstone repo — server/client components, data fetching/caching, Server Actions, routing. Triggers on `next` in package.json, app/ directory, route.ts. Component rules live in the react skill; language rules in the typescript skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Next.js (meta-framework)

Full standard: **`standards/frameworks/next.md`** (builds on `frameworks/react.md` + `languages/typescript.md`).
Choose Next over a Vite SPA when you need SSR/SSG/streaming/SEO/edge. Rules:

## Always
- **Server Components by default**; `'use client'` only at interactive leaves; never pass secrets/server-only code across the client boundary (it's a real trust boundary).
- **Auth = a Data Access Layer + `verifySession()`**, checked in the DAL/page, NOT in middleware. **Middleware is not authorization** (CVE-2025-29927); don't gate auth there.
- **Server Actions** order: verify session → validate input (Zod) → authorize → mutate. Treat each as a public endpoint.
- Know the **Next 15 caching defaults** (GET route handlers + fetch uncached by default); set `revalidate`/tags deliberately.

## Defer
- Components/hooks/state → `react.md`; API contract → `../design/api-design.md`; authN/authZ → `../practices/app-security.md`; language/tsconfig → `../languages/typescript.md`.

## Done
biome/tsc/test/build green · server/client boundary clean · actions authorized · no secrets in client. See the doc.
