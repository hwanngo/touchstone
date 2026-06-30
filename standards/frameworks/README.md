# Frameworks

Framework-specific standards, **layered on the language docs**. Each doc covers only what's true
once you've chosen that framework (component model, routing, DI, SSR) and **defers** language
rules to `../languages/` and cross-cutting concerns to `../design/`, `../platform/`, `../practices/`
rather than repeating them.

| Framework | Language | Doc |
|---|---|---|
| React | [typescript](../languages/typescript.md) | [react.md](react.md) |
| Next.js (App Router) | [typescript](../languages/typescript.md) | [next.md](next.md) |
| Nuxt (Vue 3) | [typescript](../languages/typescript.md) | [nuxt.md](nuxt.md) |
| FastAPI | [python](../languages/python.md) | [fastapi.md](fastapi.md) |
| Litestar | [python](../languages/python.md) | [litestar.md](litestar.md) |
| Gin | [go](../languages/golang.md) | [gin.md](gin.md) |
| Node.js backend (Fastify/Nest/Express) | [typescript](../languages/typescript.md) | [node-backend.md](node-backend.md) |
| Django | [python](../languages/python.md) | [django.md](django.md) |
| Svelte / SvelteKit | [typescript](../languages/typescript.md) | [svelte.md](svelte.md) |
| Vue 3 | [typescript](../languages/typescript.md) | [vue.md](vue.md) |
| Angular | [typescript](../languages/typescript.md) | [angular.md](angular.md) |
| SolidJS | [typescript](../languages/typescript.md) | [solid.md](solid.md) |
| Astro | [typescript](../languages/typescript.md) | [astro.md](astro.md) |
| Spring Boot | [java-kotlin](../languages/java-kotlin.md) | [spring-boot.md](spring-boot.md) |
| ASP.NET Core | [csharp](../languages/csharp.md) | [aspnet-core.md](aspnet-core.md) |
| Ruby on Rails | [ruby](../languages/ruby.md) | [rails.md](rails.md) |
| Laravel | [php](../languages/php.md) | [laravel.md](laravel.md) |
| Phoenix | [elixir](../languages/elixir.md) | [phoenix.md](phoenix.md) |
| Axum (Rust backend) | [rust](../languages/rust.md) | [axum.md](axum.md) |
| React Native (Expo) | [typescript](../languages/typescript.md) | [react-native.md](react-native.md) |
| Flutter | dart | [flutter.md](flutter.md) |
| SwiftUI | [swift](../languages/swift.md) | [swiftui.md](swiftui.md) |
| Jetpack Compose | [java-kotlin](../languages/java-kotlin.md) | [jetpack-compose.md](jetpack-compose.md) |

## When a framework earns a doc (the anti-sprawl rule)

> A framework gets a file **only when a real repo in your portfolio uses it AND you have at least
> one opinionated rule the language doc can't host.** Until both are true, it does not exist here.

- **In use + opinions to state** → its own `frameworks/<name>.md`.
- **In use but you'd only say "follow the official docs"** → don't create a file; the language doc
  and the cross-cutting docs already cover it.
- **Not used anywhere** → no file. No speculative `qwik.md` / `remix.md` / `quarkus.md`.
- **Build tools** (Vite, etc.) fold into their consuming framework's doc — no standalone file.
- **Meta-frameworks** (Next, Nuxt, Remix) get their own doc when adopted, and defer component-level
  rules to the base framework (`next.md` → `react.md`; `nuxt.md` carries Vue inline until a repo
  needs a standalone `vue.md`).

Naming: flat, framework-named, language implicit — `react.md`, `next.md` (never `typescript-react.md`).
