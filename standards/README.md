# Standards

The canonical engineering standards. Each doc is opinionated, tool-agnostic, and maps every rule
to an enforceable gate. Items only relevant at production scale are tagged _(scale-up)_.

Docs are grouped by domain — **`languages/`** (per-stack tooling), **`frameworks/`** (layered on a
language), **`platform/`** (build, ship, run), **`practices/`** (cross-cutting), **`design/`**
(system & API design) — with `self-audit.md` scoring a repo against all of them.

**Language vs framework:** a rule lives in `languages/` if it's true for *any* program in that
language (tooling, types, idioms); in `frameworks/` if it only makes sense once you've chosen that
framework (components, routing, DI). Framework docs defer to their language doc and to the
cross-cutting docs rather than repeat them.

> **Rule of thumb:** if a tool, version, or convention here disagrees with what's in a repo, the
> repo is wrong — open a PR to align it, or a PR to change the standard. Don't let them drift.

## Index

### `languages/` — per-stack tooling, testing, conventions

| Standard | Covers |
|---|---|
| [python.md](languages/python.md) | uv · ruff · pytest · Pyright · async |
| [typescript.md](languages/typescript.md) | pnpm · Biome · strict tsconfig · Vitest · module hygiene |
| [golang.md](languages/golang.md) | gofumpt · golangci-lint v2 · `-race` · slog · distroless |
| [rust.md](languages/rust.md) | cargo · rustfmt · clippy `-D warnings` · thiserror/anyhow · tokio · unsafe policy |
| [java-kotlin.md](languages/java-kotlin.md) | Gradle (Kotlin DSL) · Spotless/ktlint · null-safety · JUnit · coroutines/virtual threads |
| [csharp.md](languages/csharp.md) | dotnet CLI · central package mgmt · Roslyn analyzers · nullable refs · xUnit |
| [shell.md](languages/shell.md) | bash safety · shellcheck · shfmt · when to stop bashing |
| [swift.md](languages/swift.md) | SwiftPM · swift-format · strict concurrency · Swift Testing · typed throws |
| [php.md](languages/php.md) | Composer · Pint · PHPStan max · Pest · strict types |
| [ruby.md](languages/ruby.md) | Bundler · RuboCop · RBS/Sorbet · RSpec · YJIT |
| [elixir.md](languages/elixir.md) | mix · Credo · Dialyzer · OTP/GenServer · ExUnit · releases |
| [zig.md](languages/zig.md) | pinned compiler · build.zig · comptime · allocators · cross-compile (pre-1.0) |
| [solidity.md](languages/solidity.md) | Foundry · reentrancy/CEI · fuzz+invariant tests · Slither · audits |

### `frameworks/` — framework-specific, layered on the language docs

Added only for frameworks a repo actually uses (see the [threshold](frameworks/README.md)).

| Standard | Language | Covers |
|---|---|---|
| [react.md](frameworks/react.md) | typescript | components · hooks · state boundaries · Vite/PWA · a11y |
| [next.md](frameworks/next.md) | typescript | App Router · RSC boundary · Server Actions · caching |
| [nuxt.md](frameworks/nuxt.md) | typescript | Vue 3 · composables · SSR/`routeRules` · Nitro · Pinia |
| [fastapi.md](frameworks/fastapi.md) | python | domain modules · DI · pydantic boundaries · async routes |
| [litestar.md](frameworks/litestar.md) | python | controllers · DI · msgspec/DTOs · advanced-alchemy |
| [gin.md](frameworks/gin.md) | go | handler→service→repo · middleware · binding · shutdown |
| [node-backend.md](frameworks/node-backend.md) | typescript | Fastify/Nest/Express · layering · Zod DTOs · pino · graceful shutdown |
| [django.md](frameworks/django.md) | python | apps · ORM/migrations · DRF · settings split · async · `check --deploy` |
| [svelte.md](frameworks/svelte.md) | typescript | runes · SvelteKit load/actions · SSR adapters · a11y |
| [vue.md](frameworks/vue.md) | typescript | Composition API · `<script setup>` · Pinia · composables · Router |
| [angular.md](frameworks/angular.md) | typescript | standalone · signals · OnPush · typed forms · `inject()` |
| [solid.md](frameworks/solid.md) | typescript | fine-grained signals · stores · `<For>`/`<Show>` · resources · SolidStart |
| [astro.md](frameworks/astro.md) | typescript | islands · zero-JS default · content collections · view transitions |
| [spring-boot.md](frameworks/spring-boot.md) | java-kotlin | constructor DI · Spring Data JPA · ProblemDetail · Actuator |
| [aspnet-core.md](frameworks/aspnet-core.md) | csharp | minimal APIs · DI/options · EF Core · ProblemDetails · auth policies |
| [rails.md](frameworks/rails.md) | ruby | ActiveRecord · service objects · Hotwire · Solid Trifecta · Kamal |
| [laravel.md](frameworks/laravel.md) | php | Eloquent · Form Requests · queues/Horizon · Pest · Octane |
| [phoenix.md](frameworks/phoenix.md) | elixir | contexts · Ecto/changesets · LiveView · PubSub · Oban |
| [axum.md](frameworks/axum.md) | rust | extractors · Tower middleware · IntoResponse errors · sqlx · graceful shutdown |
| [react-native.md](frameworks/react-native.md) | typescript | Expo/EAS · New Architecture · Expo Router · FlashList |
| [flutter.md](frameworks/flutter.md) | dart | FVM · Riverpod · const widgets · go_router · golden tests |
| [swiftui.md](frameworks/swiftui.md) | swift | Observation framework · NavigationStack · MV · previews · a11y |
| [jetpack-compose.md](frameworks/jetpack-compose.md) | java-kotlin | state hoisting · recomposition/stability · StateFlow · Material 3 |

### `platform/` — build, ship, run

| Standard | Covers |
|---|---|
| [docker.md](platform/docker.md) | slim/distroless · non-root · BuildKit · digest-pinning |
| [devops.md](platform/devops.md) | IaC · k8s · GitOps · secrets · observability · SRE |
| [ci-cd.md](platform/ci-cd.md) | SHA-pinned Actions · OIDC · release automation |
| [database.md](platform/database.md) | migrations (expand/contract) · indexing · SQL · pooling |
| [observability.md](platform/observability.md) | OpenTelemetry · logs/metrics/traces · RED/USE · SLOs · burn-rate alerts |
| [terraform.md](platform/terraform.md) | OpenTofu · remote state · version pinning · plan-on-PR/gated apply · policy-as-code |
| [kubernetes.md](platform/kubernetes.md) | requests/limits · probes · securityContext/PSA · NetworkPolicy · HPA/PDB |
| [monorepo.md](platform/monorepo.md) | Turborepo/Nx/Bazel · task graph · remote cache · affected builds · Changesets |
| [caching.md](platform/caching.md) | Redis/Valkey · cache-aside · invalidation/TTL · stampede · rate limiting |
| [data-engineering.md](platform/data-engineering.md) | ELT/dbt · Dagster/Airflow · medallion · data contracts · lineage |
| [search.md](platform/search.md) | Elasticsearch/OpenSearch · BM25 · vector/hybrid · alias-swap reindex |

### `practices/` — cross-cutting

| Standard | Covers |
|---|---|
| [security.md](practices/security.md) | secret scanning · dep/vuln scanning · SBOM · signing |
| [app-security.md](practices/app-security.md) | authN/authZ · OWASP Top 10 · threat modeling |
| [dependencies.md](practices/dependencies.md) | package managers · version policy · cooldowns |
| [testing-strategy.md](practices/testing-strategy.md) | pyramid · contract tests · flaky-test policy |
| [code-review.md](practices/code-review.md) | author/reviewer duties · PR size · review SLA |
| [code-quality.md](practices/code-quality.md) | naming · function/file size · KISS/YAGNI/DRY · error handling · no dead code |
| [data-privacy.md](practices/data-privacy.md) | PII classification · retention · right-to-erasure |
| [collaboration.md](practices/collaboration.md) | commits · pre-commit · task runner · repo meta |
| [git-workflow.md](practices/git-workflow.md) | trunk-based branching · merge/release strategy · SemVer · monorepo · LFS |
| [performance.md](practices/performance.md) | measure-first · budgets/SLOs · profiling · load testing · regression gates |
| [accessibility.md](practices/accessibility.md) | WCAG 2.2 AA · semantic HTML · ARIA · keyboard · contrast · axe |
| [documentation.md](practices/documentation.md) | docs-as-code · README contract · Diátaxis · diagrams · changelog |
| [ai-engineering.md](practices/ai-engineering.md) | prompts-as-code · structured outputs · RAG · evals · guardrails · cost/latency |

### `design/` — system & API design

| Standard | Covers |
|---|---|
| [architecture.md](design/architecture.md) | principles · 12-factor service design · boundaries · ADRs |
| [api-design.md](design/api-design.md) | REST/gRPC/GraphQL contracts · versioning · OpenAPI-first |
| [resilience.md](design/resilience.md) | timeouts · retries · circuit breakers · caching · queues |
| [event-driven.md](design/event-driven.md) | queues/streams · outbox · idempotency · ordering · DLQ · schema evolution |
| [graphql.md](design/graphql.md) | schema/SDL · DataLoader/N+1 · cursor pagination · depth/cost limits · federation |
| [grpc.md](design/grpc.md) | protobuf · buf lint/breaking · deadlines · status errors · streaming |

### Cross-cutting

- [self-audit.md](self-audit.md) — the checklist + maturity model (L1–L4) that scores a repo
  against all of the above.

Cross-references between docs are intentional — read a per-stack doc first, follow its links into
the shared mechanisms (`security.md`, `ci-cd.md`, `resilience.md`, …).
