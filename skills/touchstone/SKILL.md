---
name: touchstone
description: Use at the START of any non-trivial task in a repository that follows touchstone (look for AGENTS.md + a standards/ folder, or a .touchstone marker). Establishes the universal hard rules and routes to the right per-stack standard. Invoke before editing code, config, CI, or committing.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# touchstone — universal rules & router

This repo follows **touchstone**. Read `AGENTS.md` and the relevant `standards/*.md`. The hard rules
below apply to every task regardless of stack; the per-stack skills carry the details.

## Hard rules (always)
1. **uv** (Python) · **pnpm** (Node) · **go modules** (Go). Never pip/npm/yarn. Commit lockfiles; CI installs frozen.
2. **Format + lint with the standard tool, enforced in CI:** ruff · Biome · gofumpt+golangci-lint.
3. **Tests self-skip when fixtures are absent** (clean-checkout CI); run Go tests with `-race`.
4. **Latest stable deps**; treat advisories as priority work.
5. **Containers:** small current base images (slim/alpine/distroless), multi-stage, non-root, digest-pinned.
6. **Never commit** secrets, per-developer AI-assistant scratch/settings, or AI-generated TDD/SDD
   planning docs. Generated artifacts stay out of git too, with one sanctioned exception: a
   deterministic file, marked as generated, whose freshness CI enforces by regenerating it and
   failing on any diff (e.g. `skills/CATALOG.md`). Shared, reviewed rule files (`AGENTS.md`,
   `.cursor/rules/*.mdc`, …) ARE committed — see `standards/practices/collaboration.md` §4.

## Collaboration & git (from `standards/practices/collaboration.md`)
- **Conventional Commits**, atomic; branch + PR, never push to main directly; `--force-with-lease` only.
- Run gates via the task runner: **`just ci`** (or `just lint test build`); show output — evidence before claims.
- Enforce locally with **pre-commit**; keep `.editorconfig`/`.gitattributes`/CODEOWNERS in place.

## Router — load the matching skill / standard

> **Language vs framework:** load the **language** skill for tooling/types (fires on the file
> extension) AND the **framework** skill for the app model (fires on the dependency). Both firing
> on a `.tsx`/`.py` edit is correct — they layer.

| Working on… | Skill / doc |
|---|---|
| Python · TypeScript · Go · Rust · Java/Kotlin · C# · Swift · PHP · Ruby · Elixir · Zig · Solidity · Shell (language) | `{python,typescript,go,rust,java-kotlin,csharp,swift,php,ruby,elixir,zig,solidity,shell}-standards` · `standards/languages/*.md` |
| React · Next · Nuxt · Svelte · Vue · Angular · Solid · Astro (frontend) | `{react,next,nuxt,svelte,vue,angular,solid,astro}-standards` · `standards/frameworks/*.md` |
| FastAPI · Litestar · Django · Gin · Node.js · Spring Boot · ASP.NET Core · Rails · Laravel · Phoenix · Axum (backend) | `{fastapi,litestar,django,gin,node-backend,spring-boot,aspnet-core,rails,laravel,phoenix,axum}-standards` · `standards/frameworks/*.md` |
| React Native · Flutter · SwiftUI · Jetpack Compose (mobile) | `{react-native,flutter,swiftui,jetpack-compose}-standards` · `standards/frameworks/*.md` |
| Dockerfile / compose | `docker-standards` · `standards/platform/docker.md` |
| IaC / Terraform / OpenTofu | `terraform-standards` · `standards/platform/terraform.md` |
| Kubernetes / manifests / Helm | `kubernetes-standards` · `standards/platform/kubernetes.md` |
| GitOps / deploy / SRE | `devops-standards` · `standards/platform/devops.md` |
| Logs / metrics / traces / SLOs / OTel | `observability-standards` · `standards/platform/observability.md` |
| Monorepo / Turborepo / Nx / Bazel | `monorepo-standards` · `standards/platform/monorepo.md` |
| Caching / Redis / rate limiting | `caching-standards` · `standards/platform/caching.md` |
| Data pipelines / dbt / warehouse | `data-engineering-standards` · `standards/platform/data-engineering.md` |
| Search / Elasticsearch / vector | `search-standards` · `standards/platform/search.md` |
| CI workflows / dependabot / releases | `ci-cd-standards` · `standards/platform/ci-cd.md` |
| DB schema / migrations / SQL | `database-standards` · `standards/platform/database.md` |
| Secrets / deps / supply chain | `security-standards` · `standards/practices/security.md` |
| Auth / permissions / OWASP / threat model | `app-security-standards` · `standards/practices/app-security.md` |
| REST / API contracts / OpenAPI | `api-design-standards` · `standards/design/api-design.md` |
| GraphQL schema / resolvers | `graphql-standards` · `standards/design/graphql.md` |
| gRPC / protobuf / buf | `grpc-standards` · `standards/design/grpc.md` |
| Queues / streams / messaging / outbox | `event-driven-standards` · `standards/design/event-driven.md` |
| LLM features / prompts / RAG / evals / agents | `ai-engineering-standards` · `standards/practices/ai-engineering.md` |
| Tests (cross-cutting / flaky / contract) | `testing-strategy-standards` · `standards/practices/testing-strategy.md` |
| Profiling / perf budgets / load tests | `performance-standards` · `standards/practices/performance.md` |
| UI a11y / WCAG / keyboard / ARIA | `accessibility-standards` · `standards/practices/accessibility.md` |
| Reviewing a PR | `standards/practices/code-review.md` |
| Naming / function size / clean code (any language) | `code-quality-standards` · `standards/practices/code-quality.md` |
| Branching / releases / monorepo | `git-workflow-standards` · `standards/practices/git-workflow.md` |
| READMEs / docs / runbooks / diagrams | `documentation-standards` · `standards/practices/documentation.md` |
| Architecture / resilience / retries / caching | `standards/design/{architecture,resilience}.md` |
| PII / data retention / GDPR | `standards/practices/data-privacy.md` |
| Package mgrs / version policy | `standards/practices/dependencies.md` |

When in doubt, open `standards/self-audit.md` and check the work against it before calling it done.
