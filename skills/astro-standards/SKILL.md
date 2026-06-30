---
name: astro-standards
description: Use when building an Astro 5 content site in a touchstone repo — islands, zero-JS-by-default, .astro components, client directives, content collections, rendering modes, view transitions, astro:env. Triggers on .astro files, `astro`/`@astrojs/*` in package.json, astro.config.mjs, src/content.config.ts. For the interactive framework inside an island use the react/svelte/vue skills; language-level TS rules live in the typescript skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Astro (framework)

Full standard: **`standards/frameworks/astro.md`** (layers on `languages/typescript.md`).
Load-bearing rules:

## Always
- **Zero JS by default** — `.astro` components render to HTML and ship nothing; an island only hydrates when a framework component carries a `client:*` directive. Frontmatter is server-only: secrets, DB calls, heavy imports stay there and never reach the browser.
- **Choose the minimum directive**: `client:visible` is the house default, `client:idle`/`client:media` for low priority, `client:load` only for critical above-the-fold UI (justify it), `client:only` only for genuinely browser-only widgets (names the framework, ships no SSR HTML).
- **Content collections get a Zod `schema` + a `loader`** (Content Layer API, `src/content.config.ts`); frontmatter is untrusted input parsed once at build. Query via `getCollection`/`getEntry`, never raw `fs`/`import.meta.glob`.
- **`output: 'static'` is the default**; opt routes into on-demand rendering per-page with `export const prerender = false` and a concrete `adapter` pinned — don't flip the whole site to a server, and don't ship SSR without an adapter.

## Defer
- Island internals → `react.md` / `svelte.md` / `vue.md`; language/tsconfig/test-runner → `../languages/typescript.md`; a11y (astro check warnings + axe gate) → `../practices/accessibility.md`; Core Web Vitals budgets → `../practices/performance.md`; secrets/auth → `../practices/security.md`.

## Don't get burned
- **Whole-page interactivity means you picked the wrong tool** — Astro is for content; a single stateful UI graph spanning the page wants a SPA framework. Don't render an `.astro` component inside a client island, and don't ship two UI frameworks without cause (two runtimes).
- **A prerendered route reading cookies/`Astro.request` is a bug** — keep static routes pure or move per-request reads behind `prerender = false` / a server island. `astro:env` `access: 'public'` is inlined plaintext — no secrets; server vars in an island is a build error. Use `<Image />`/`<Picture />` (not raw `<img>`) with dimensions set.

## Done
`astro check` (a11y warnings fail) · `tsc` · `biome ci` · `vitest` · `playwright` green; zero unjustified client JS; collections schema-validated; secrets out of public env. See `standards/frameworks/astro.md`.
