---
name: svelte-standards
description: Use when building a Svelte 5 + SvelteKit 2 app in a touchstone repo — runes, components, file routing, load functions, form actions, hooks, rendering modes, env. Triggers on .svelte files, `svelte`/`@sveltejs/kit` in package.json, svelte.config.js, src/routes. Language-level TS rules live in the typescript skill; for React/Next/Nuxt use those skills.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Svelte & SvelteKit (framework)

Full standard: **`standards/frameworks/svelte.md`** (layers on `languages/typescript.md`).
Load-bearing rules:

## Always
- **Runes only** (`$state`/`$derived`/`$effect`/`$props`); no legacy `$:`/`export let` in new code. Computed state is `$derived`, never an `$effect` that writes the state it reads. Shared reactive logic → `.svelte.ts` modules.
- **Load the right way**: DB/secret data in `+page.server.ts` `load`; universal `+page.ts` only for public fetches. Use generated `./$types` and the event-scoped `fetch`; validate boundaries with Zod.
- **Mutations are form `actions` + `use:enhance`** (progressive enhancement — the no-JS `<form>` must work first); never a client `fetch` to a JSON endpoint for same-app writes.
- **Authorize every action/endpoint**; `hooks.server.ts` `handle` resolves session into `event.locals`. Pick rendering mode per route (`prerender`/`ssr`/`csr`) — don't bolt on a SPA framework.

## Defer
- API contract → `../design/api-design.md`; authN/authZ/CORS/CSRF → `../practices/security.md`; a11y (Svelte compiler warnings + axe gate) → `../practices/accessibility.md`; test layers → `../practices/testing-strategy.md`; language/tsconfig → `../languages/typescript.md`.

## Don't get burned
- **No module-scope mutable `$state`** holding per-user data — the server shares the module across requests and leaks state between users; use `context` off a per-request `load` value.
- **`$env/*/public` (`PUBLIC_`) is a public boundary** — no secrets; prefer `$env/static/*` so misconfig fails the build. Invalidate surgically (`invalidate(tag)`), not reflexive `invalidateAll()`. Pin a concrete adapter for production.

## Done
`biome ci` · `svelte-check` (a11y warnings fail) · `tsc` · `vitest` · `playwright` green; no SSR state leak; secrets out of `PUBLIC_`. See `standards/frameworks/svelte.md`.
