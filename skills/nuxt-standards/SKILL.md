---
name: nuxt-standards
description: Use when building a Nuxt (Vue 3) app in a touchstone repo — pages/composables, rendering modes, data fetching, Nitro server routes, state. Triggers on `nuxt` in package.json, nuxt.config, pages/ + composables/. Language rules live in the typescript skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Nuxt (Vue 3 meta-framework)

Full standard: **`standards/frameworks/nuxt.md`** (layers on `languages/typescript.md`; carries Vue 3
inline until a standalone `vue.md` exists). Rules:

## Always
- **Composition API + `<script setup lang="ts">`** only; typed `defineProps<T>()`/`defineEmits<T>()`; `:key` on `v-for` (not index).
- **`runtimeConfig` secret boundary**: secrets only in private `runtimeConfig`; `public` is client-exposed. DB clients/secrets live in `server/utils/`, never in components/composables.
- **SSR cross-request state leak**: never module-level mutable state (`export const x = ref()` leaks across users); use `useState`/Pinia; `callOnce()` for server seeding.
- Data via **`useFetch`/`useAsyncData`** (dedup + SSR-safe), not bare `fetch` in setup; Nitro `server/api/` handlers validate input (Zod) + authorize every request.

## Defer
- API contract → `../design/api-design.md`; authN/authZ → `../practices/app-security.md`; language/tsconfig → `../languages/typescript.md`.

## Done
biome/tsc/test/build green · no SSR state leak · secrets in `runtimeConfig`/`server/` · handlers authorized. See the doc.
