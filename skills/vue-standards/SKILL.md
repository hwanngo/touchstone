---
name: vue-standards
description: Use when building a plain Vue 3 SPA in a touchstone repo — SFCs, reactivity, props/emits/models, Pinia, composables, Vue Router, forms, perf, a11y, testing. Triggers on .vue files, `vue` in package.json, vite.config with the Vue plugin. Language-level TS rules live in the typescript skill; for SSR/file-routing/server-routes (Nuxt) use the nuxt skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Vue 3 (framework)

Full standard: **`standards/frameworks/vue.md`** (layers on `languages/typescript.md`).
Load-bearing rules inlined so this stays useful installed standalone:

## Always
- **`<script setup lang="ts">` + Composition API only** — no Options API in new code; type props/emits with the generic macros (`defineProps<T>()` / `defineEmits<T>()`), `defineModel()` for two-way binding, never mutate a prop.
- **`ref` first** for state (primitives and objects); `computed` for derived values; targeted `watch`. `shallowRef` for large inert payloads.
- **`:key` on every `v-for` is a stable id, never the array index** — index keys corrupt state on insert/reorder.
- **Pinia setup stores for cross-component client state only** — don't overuse global state; server data stays in the query layer, not copied into a store.
- **Composables are `use*`**, side-effect-free at top level, return a stable named object, and own their own cleanup.

## Don't get burned (reactivity loss)
- **Never `export` a `reactive()`** or destructure one raw (`const { x } = reactive(s)` is dead) — use `toRefs()`/`toRef()`; destructure stores through `storeToRefs()`.
- `reactive()` dies on reassignment — assign through a `ref`'s `.value` instead.
- Don't mirror one ref into another with `watch` — that's a `computed`.
- Lazy-load every route component; client route guards are UX — the **server** enforces authorization (`../practices/app-security.md`). Forms = VeeValidate + a Zod schema **shared with the API boundary** (`../design/api-design.md`).

## Done
`<script setup>` + typed macros · no reactivity loss · stable `:key` · Pinia for shared state only · routes lazy + guarded · a11y gate (vuejs-accessibility + axe) · Web Vitals budget · `pnpm test` green (Vitest + @vue/test-utils, MSW). See `standards/frameworks/vue.md`.
