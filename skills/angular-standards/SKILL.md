---
name: angular-standards
description: Use when building Angular (v18/19+) apps in a touchstone repo — standalone components, signals, change detection, DI, routing, RxJS, forms, HttpClient, control flow, state. Triggers on *.component.ts, angular.json, `@angular/*` in package.json. Language-level TS rules live in the typescript skill; for React/Nuxt use those skills.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Angular (framework)

Full standard: **`standards/frameworks/angular.md`** (layers on `standards/languages/typescript.md`).
Load-bearing rules:

## Always
- **Standalone only** — no new `NgModule`; bootstrap with `bootstrapApplication` + provider functions (`provideRouter`, `provideHttpClient`).
- **Signals are the primitive** — `signal`/`computed`/`effect`, and `input`/`output`/`model`/`viewChild` over decorators; effects do side effects, never derive state.
- **`OnPush` on every component**; go zoneless on new apps; never call `detectChanges()` to "fix" a view.
- **`inject()` + `providedIn: 'root'`**; functional guards/resolvers/interceptors (class-based are legacy); lazy-load every feature route.
- **Typed reactive forms** (`nonNullable`); type HTTP responses and Zod-parse at the boundary.

## Don't get burned
- **No bare `subscribe()` without `takeUntilDestroyed()`** (or `AsyncPipe`/`toSignal`) — it leaks. Signals for state, RxJS for event/async streams.
- **`@for` needs `track`** by stable id, never `$index`; use built-in `@if`/`@for`/`@switch` and `@defer` for heavy blocks.
- **No secrets in `environment.ts`** — it ships plaintext. Migrate off Karma/Protractor (Jest/Vitest + Testing Library + Playwright).

## Done
no new NgModule · standalone + signals + `OnPush` · `takeUntilDestroyed` on subscriptions · esbuild builder + budgets · a11y/tests green. See `standards/frameworks/angular.md`.
