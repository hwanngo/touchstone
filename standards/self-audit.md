# Self-Audit Checklist

Run this to measure any repo against these standards. Score each item ✅ in place · 🟡 partial ·
❌ missing, then turn the ❌/🟡 into issues. Skip sections for stacks the repo doesn't use; items
marked _(scale-up)_ apply to production-scale infra only.

## Maturity levels

Adopt in order — don't bounce off the full list. Declare your target in `.touchstone.toml` (`level`).

| Level | Name | What it requires | For |
|---|---|---|---|
| **L1** | Hygiene | Lockfiles committed · format + lint + type-check + tests pass locally · `.gitignore` covers secrets/artifacts/AI-folders · `.editorconfig` | any repo, prototypes |
| **L2** | Gated | All L1 enforced in **CI** · branch protection + required-check aggregator · pre-commit · CODEOWNERS · coverage floor | shared / team repos |
| **L3** | Hardened | All L2 + Actions SHA-pinned · least-privilege `permissions:` · OIDC · secret + dependency + image scanning · SBOM + signed provenance · digest-pinned images | anything deployed/published |
| **L4** | Scale-up | All L3 + SLOs & error-budget policy · tested DR/backups · progressive delivery · threat modeling · the _(scale-up)_ items | production / regulated |

Each item below is tagged with the level it first becomes required. A repo "conforms at Ln" when
every item up to and including Ln is ✅ (waivers documented in `.touchstone.toml`).

---

## Python (if present)

_Source: [languages/python.md](languages/python.md)._
- [ ] Managed with **uv**; `uv.lock` committed; CI runs `uv sync --locked` + `uv lock --check`
- [ ] **ruff** with the expanded rule set (`B`/`S`/`UP`/`SIM`/`PTH`/`DTZ`…); CI runs `ruff check` + `ruff format --check`
- [ ] Intentional lint exceptions are documented `per-file-ignores`, not scattered `# noqa`
- [ ] Type checker configured (Pyright/mypy) with correct import roots
- [ ] pytest hardened (`--strict-markers --strict-config`, `xfail_strict`, `filterwarnings=error`); branch-coverage floor
- [ ] **Data-dependent tests self-skip** when fixtures absent; deterministic outputs have golden tests
- [ ] `pip-audit` in CI; latest stable Python; deps current

## TypeScript / React (if present)

_Source: [languages/typescript.md](languages/typescript.md) · [frameworks/react.md](frameworks/react.md)._
- [ ] **pnpm** (pinned `packageManager`); `pnpm-lock.yaml` committed; `--frozen-lockfile`; lifecycle scripts allowlisted
- [ ] **Biome** (no ESLint/Prettier) with `react`/`test` domains + a11y; CI runs **`biome ci`**
- [ ] TS `strict` + `noUncheckedIndexedAccess`/`verbatimModuleSyntax`; `tsc` green in CI
- [ ] **Vitest** with enforced coverage thresholds; API boundaries validated with Zod
- [ ] Installable **PWA**; **no source maps** in prod; no secrets behind `VITE_`
- [ ] Bundle within a `size-limit` budget; latest LTS Node; `pnpm audit` clean

## Go (if present)

_Source: [languages/golang.md](languages/golang.md)._
- [ ] Pinned via `go`+`toolchain`; `GOTOOLCHAIN=local` in CI; `go.sum` committed; `-mod=readonly`
- [ ] **gofumpt + goimports** enforced; **golangci-lint v2** (standard + gosec/bodyclose/errorlint)
- [ ] Table-driven tests with **`go test -race`**; stdlib `testing` + go-cmp (not testify); coverage floor
- [ ] Errors wrapped `%w` (`errors.Is/As`); no panic in libs; no ignored errors; `context` first arg
- [ ] **`govulncheck`** in CI; `go mod tidy` produces no diff
- [ ] Release binary static (`CGO_ENABLED=0`) on distroless nonroot

## Rust (if present)

_Source: [languages/rust.md](languages/rust.md)._
- [ ] Toolchain pinned in `rust-toolchain.toml`; **cargo fmt --check** + **clippy** `-D warnings` clean in CI
- [ ] No `unwrap()`/`expect()` on library happy paths; errors typed (**thiserror**), **anyhow** only at the app boundary
- [ ] `unsafe_code = "forbid"`, or every block has a `// SAFETY:` note and **cargo miri test** passes
- [ ] Async (tokio): no blocking in `async fn` (offload via **spawn_blocking**); awaits timeout-bounded; spawned tasks owned
- [ ] **cargo test** (incl. doctests) + **nextest** green; `cargo build --locked`; `Cargo.lock` committed; MSRV tested in CI
- [ ] **cargo deny check** + **cargo audit** clean (or advisories triaged)

## Java / Kotlin (if present)

_Source: [languages/java-kotlin.md](languages/java-kotlin.md)._
- [ ] LTS Temurin JDK via Gradle toolchain; Wrapper committed + SHA-pinned; CI `--offline` build proves the graph is locked
- [ ] **spotlessCheck** clean (google-java-format / ktlint); Error Prone/NullAway + Detekt pass; warnings are errors
- [ ] Null-safety: JSpecify `@NullMarked` + NullAway (Java), no `!!` (Kotlin); `Optional` is a return type only
- [ ] Data via records/data classes + sealed types; `switch`/`when` exhaustive; concurrency structured + every blocking call timeout-bounded
- [ ] **gradlew test** green; integration tests on **Testcontainers**; dependency locking + verification on; **dependencyCheckAnalyze** clean

## C# / .NET (if present)

_Source: [languages/csharp.md](languages/csharp.md)._
- [ ] SDK pinned in `global.json`; **dotnet build -c Release** clean with `<TreatWarningsAsErrors>` + analyzers
- [ ] **dotnet format --verify-no-changes** clean; `<Nullable>enable</Nullable>` solution-wide; no unjustified `!`
- [ ] Versions via **Central Package Management** (`Directory.Packages.props`); no per-project `<Version>`
- [ ] No blocking on async (`.Result`/`.Wait()`); `CancellationToken` forwarded; libraries `ConfigureAwait(false)`
- [ ] **dotnet test** green (coverlet floor) + Testcontainers integration tests; `packages.lock.json` committed, CI `--locked-mode`; `dotnet list package --vulnerable` clean

## Containers (if present)

_Source: [platform/docker.md](platform/docker.md)._
- [ ] Base images small, current, and **digest-pinned** (distroless/Wolfi for runtime where possible)
- [ ] `# syntax=docker/dockerfile:1`; secrets via mounts (never build ARGs); BuildKit cache mounts
- [ ] Multi-stage; **non-root** + `init` + read-only rootfs + `cap_drop: [ALL]` + `no-new-privileges` + limits
- [ ] Frozen installs; one root `.dockerignore`; no secrets in layers; no `privileged`/docker.sock
- [ ] Tuned healthcheck; `depends_on: service_healthy`; only the entry point published
- [ ] **hadolint** + image scan in CI; published images carry **signed SBOM + provenance**

## CI/CD & supply chain

_Source: [platform/ci-cd.md](platform/ci-cd.md) · [practices/security.md](practices/security.md)._
- [ ] Every stack's gates run on PRs; install frozen; concurrency cancels stale runs
- [ ] **Actions pinned to commit SHA**; least-privilege `permissions:`; `persist-credentials: false`; Harden-Runner
- [ ] One stable required-status-check aggregator; branch ruleset + **CODEOWNERS**
- [ ] Cloud auth via **OIDC** (no long-lived keys)
- [ ] **CodeQL** (app) + **zizmor** (workflows) + **dependency-review** wired
- [ ] Releases automated from Conventional Commits (release-please) with a CHANGELOG

## Security

_Source: [practices/security.md](practices/security.md)._
- [ ] Secret scanning: **gitleaks** (pre-commit) + platform **push protection** + scheduled deep sweep
- [ ] Written **leak-response runbook** (rotate-first)
- [ ] Dependency scanning per ecosystem with an update **cooldown**
- [ ] Web: CSP + headers; `dangerouslySetInnerHTML` banned; built `dist/` scanned clean

## DevOps / infra (if deployed)

_Source: [platform/devops.md](platform/devops.md)._
- [ ] All infra is **IaC**; remote state locked + encrypted; secrets out of state; gated apply
- [ ] K8s: requests set (no CPU limit / memory limit = request); correct probes; hardened `securityContext`; digest-pinned images
- [ ] **GitOps** deploys; PR-based promotion; migrations N-1 safe; secrets via ESO/SOPS/Vault + rotation
- [ ] Metrics (RED/USE) + OTel + structured correlated logs; **SLO burn-rate** alerts
- [ ] _(scale-up)_ SLOs + error-budget policy + runbooks + tested backups/DR

## Infrastructure as Code (if present)

_Source: [platform/terraform.md](platform/terraform.md)._
- [ ] **OpenTofu** by default (any Terraform use is the documented escape hatch); directory-per-env root modules, each with **its own backend/state**
- [ ] Remote state with **native locking** (prefer `use_lockfile`; DynamoDB still valid), bucket KMS + versioning, **state encryption** on; secrets never in `.tf`/`.tfvars`/state
- [ ] Providers/modules version-pinned; **`.terraform.lock.hcl` committed** with multi-platform hashes
- [ ] CI gates: `fmt -check` → `validate` → **tflint** → **scan (Checkov/`trivy config`)** → **policy (Conftest/OPA)** → **plan-on-PR** → human-gated apply
- [ ] **No `apply` from a laptop**; prod apply behind a protected environment; **CI auth via OIDC**, no long-lived keys
- [ ] Modules covered by **`tofu test`**; _(scale-up)_ scheduled **drift-detection** on prod + **Terratest** E2E

## Kubernetes (if present)

_Source: [platform/kubernetes.md](platform/kubernetes.md)._
- [ ] **Requests always set**; no CPU limit on latency-sensitive svcs; **memory limit = request**; probes correct (liveness dependency-free, readiness gates traffic)
- [ ] `securityContext` hardened (runAsNonRoot, readOnlyRootFilesystem, drop ALL, seccomp RuntimeDefault); namespace **PSA `enforce: restricted`**
- [ ] Images **digest-pinned**, signatures **verified at admission** (**Kyverno**); no plaintext Secrets (ESO/SOPS/Vault); etcd encryption-at-rest
- [ ] **Default-deny NetworkPolicy** per namespace (DNS egress allowed); ClusterIP internal; Gateway API/Ingress with cert-manager TLS
- [ ] Manifests gated in CI: **kubeconform -strict + kube-linter + server dry-run**; admission policy (Kyverno/Gatekeeper) in Enforce
- [ ] RED/USE metrics scraped; JSON logs with `trace_id`; **SLO burn-rate alerts, not raw-CPU pages**; _(scale-up)_ PDB + topology spread + tenant quotas

## Caching (if present)

_Source: [platform/caching.md](platform/caching.md)._
- [ ] Each layer justified by freshness tolerance; pattern chosen per cache (**cache-aside** default — write the source of truth first, then *delete* the key)
- [ ] Every entry has a **TTL** + documented invalidation strategy; keys namespaced, versioned, and type-prefixed
- [ ] Hot keys have **stampede protection** (TTL jitter + single-flight); no `KEYS`/blocking ops in hot paths; big keys audited (`--bigkeys`) + chunked
- [ ] **Redis/Valkey** sets `maxmemory` + explicit `maxmemory-policy`; distributed locks use `SET NX PX`; rate limiters atomic (Lua/ZSET, deliberate fail-open/closed)
- [ ] HTTP/CDN sets correct `Cache-Control`/`ETag`/`Vary`; assets content-hashed + `immutable`; no PII/secrets in shared caches (authed = `private, no-store`)
- [ ] Hit rate, evictions, `maxmemory` headroom, and p99 latency emitted and alerted

## Data engineering (if present)

_Source: [platform/data-engineering.md](platform/data-engineering.md)._
- [ ] Batch vs streaming chosen by required latency; **ELT** into a warehouse/lakehouse, layered **Bronze→Silver→Gold** (Bronze append-only)
- [ ] Every pipeline **idempotent** (merge/partition-overwrite), partitioned by event time, incremental; transforms deterministic (no `now()`/`random()`) so backfills diff clean
- [ ] **dbt** / **Great Expectations** tests run in the DAG and fail on hard invariants; producer + dbt model **contracts** enforce schema; breaking changes versioned
- [ ] Gold modeled dimensionally (declared grain, SCD per attribute); each metric defined once
- [ ] **OpenLineage** emitted; datasets cataloged with owner + classification; freshness/volume/schema monitored + alerted on user impact
- [ ] No raw PII in Gold; minimized at ingest, masked in non-prod, erasure cascades to derived tables; _(scale-up)_ cost controlled (pruning, right-sized warehouses, spend alerts)

## Search & retrieval (if present)

_Source: [platform/search.md](platform/search.md)._
- [ ] Engine justified over `LIKE`/Postgres FTS (need is ranked relevance, faceting, or semantic); one engine chosen (**Elasticsearch/OpenSearch** default)
- [ ] Mappings explicit (`dynamic: strict`), `text` vs `keyword` correct, field-count capped; relevance clauses in query context, constraints in cached `filter`
- [ ] A **judgment list** scores relevance (nDCG/MRR) and gates changes in CI; pagination via `search_after`/PIT — no deep `from`/`size`
- [ ] _(vector)_ embedding model pinned; HNSW kNN tuned; **hybrid BM25+vector via RRF**
- [ ] Indexing **bulk + idempotent** (stable `_id`); reindex **zero-downtime via alias swap**; DB is source of truth, index synced via outbox/CDC + rebuildable
- [ ] p99 latency, relevance score, zero-results rate, and indexing lag emitted + alerted; no secrets/PII indexed; per-tenant `filter` enforced server-side

## Observability

_Source: [platform/observability.md](platform/observability.md)._
- [ ] App instrumented with **OpenTelemetry** exporting **OTLP** to a **Collector** (no vendor agents in app code)
- [ ] Logs are **JSON to stdout** with `trace_id`/`span_id` + correlation ID; no PII/secrets; errors never sampled away
- [ ] **RED** per service + **USE** per resource; latency is a histogram (p99); cardinality disciplined (no `user_id`/`request_id` labels)
- [ ] Traces propagate **W3C `traceparent`** end-to-end at 100%; sampling deliberate (tail sampling _(scale-up)_); exemplars link metrics→traces
- [ ] **SLOs** on user-journey SLIs with an error budget + written policy; alerts are multi-window **burn-rate**, page on symptoms, link a runbook
- [ ] Dashboards are **code** (provisioned); _(scale-up)_ cost controlled at the Collector (cardinality cap + tiered retention)

## Repo hygiene

_Source: [practices/collaboration.md](practices/collaboration.md) · [practices/dependencies.md](practices/dependencies.md)._
- [ ] Conventional Commits (+ commitlint); PRs gated on green CI; `--force-with-lease` only
- [ ] `.gitignore` covers secrets, generated artifacts, **and per-developer AI-assistant scratch** (shared reviewed rule files committed); no AI planning docs committed
- [ ] **pre-commit** config; **task runner** (`just`) with the `setup/lint/fmt/test/build/ci` contract
- [ ] `.editorconfig` + `.gitattributes`; CODEOWNERS; SECURITY.md; PR/issue templates; ADRs for big decisions
- [ ] Committed `AGENTS.md` + standards as the source of truth; README/docs in sync with code

## Branching & releases

_Source: [practices/git-workflow.md](practices/git-workflow.md)._
- [ ] **Trunk-based**: branches short-lived (< ~2 days) and merged behind flags; no GitFlow `develop` (release branches only for versioned/on-prem)
- [ ] **Squash-merge** default; branch rebased (not merged) onto `main`; linear history enforced in the ruleset
- [ ] Versioning is **SemVer** derived from Conventional Commits; releases are annotated, signed `vX.Y.Z` tags; `CHANGELOG.md` generated
- [ ] Hotfixes go forward on `main`; supported majors patched via `cherry-pick -x` onto `release/X.Y`
- [ ] Large binaries via **Git LFS** in `.gitattributes`; no secrets/artifacts in history; _(scale-up)_ merge queue wired on the `merge_group` event

## Documentation

_Source: [practices/documentation.md](practices/documentation.md)._
- [ ] Docs live in-repo (`docs/`, README the entry point), reviewed like code; nothing canonical lives only in a wiki
- [ ] README quickstart uses the task-runner targets and is **CI-executed** where practical
- [ ] Reference docs **generated** from source (OpenAPI/docstrings), built in CI warnings-as-errors; comments explain *why*, not *what*
- [ ] Diagrams are diagram-as-code (**Mermaid** default); no binary blob is the source of truth
- [ ] **markdownlint** + **link-check** (lychee) green in pre-commit + CI; docs updated/deleted in the same PR as the behaviour

## Application security (if it has an attack surface)

_Source: [practices/app-security.md](practices/app-security.md)._
- [ ] AuthZ **deny-by-default**, enforced server-side every request; object-level/IDOR checks
- [ ] Tokens/sessions hardened (PKCE, JWT verified + short TTL, HttpOnly+Secure+SameSite cookies)
- [ ] Input validated at the boundary; parameterized queries; SSRF egress allowlist; CSRF protection
- [ ] New trust boundaries threat-modeled (STRIDE) + recorded; work mapped against OWASP Top 10
- [ ] PII: classified, retention + right-to-erasure honored, **never logged**, encrypted at rest/in transit

## APIs & data (if present)

_Source: [design/api-design.md](design/api-design.md) · [platform/database.md](platform/database.md)._
- [ ] **Contract-first** (OpenAPI 3.1 / protobuf / SDL) committed + linted in CI (Spectral/buf)
- [ ] RFC 9457 error envelope; cursor pagination; idempotency keys; versioning + deprecation policy
- [ ] Migrations: one home, reviewed, **expand/contract** zero-downtime, N-1 compatible, destructive-change lint
- [ ] Indexes on FKs/predicates; EXPLAIN on hot queries; no `SELECT *`; bounded connection pool

## GraphQL & gRPC APIs (if present)

_Source: [design/graphql.md](design/graphql.md) · [design/grpc.md](design/grpc.md)._
- [ ] **GraphQL:** schema/SDL source of truth; **DataLoader** for N+1; cursor connections; depth/cost limits + persisted queries; introspection off in prod; field-level deny-by-default authz
- [ ] **gRPC:** **buf lint + buf breaking** in CI; field numbers never reused/renumbered; deadlines propagated; `google.rpc.Status` rich errors
- [ ] Evolution is additive-only (`@deprecated` / reserved); generated clients, not hand-written

## AI / LLM features (if present)

_Source: [practices/ai-engineering.md](practices/ai-engineering.md)._
- [ ] Prompts are **versioned in-repo** (not hardcoded); outputs schema-validated at the boundary
- [ ] An **eval set + CI regression gate** exists — no shipping a change you can't evaluate
- [ ] **Prompt-injection** defenses + input/output filtering; no PII in prompts/logs (link data-privacy)
- [ ] Token/cost/latency budgets; timeouts + fallback model; pinned model versions; traces capture prompt/completion/tokens/cost

## Design & resilience

_Source: [design/architecture.md](design/architecture.md) · [design/resilience.md](design/resilience.md)._
- [ ] Architecture decisions with multiple options recorded as **ADRs**; clear module boundaries
- [ ] Every outbound call has a **timeout**; retries bounded + jittered + budgeted; idempotent where retried
- [ ] Circuit breakers / backpressure where load can cascade; caches have TTL + stampede protection

## Event-driven & messaging (if present)

_Source: [design/event-driven.md](design/event-driven.md)._
- [ ] Async vs sync chosen per flow with a stated forcing reason; backbone fits the job (queue for work, log/stream for replayable facts)
- [ ] Delivery treated as **at-least-once**; write-and-publish atomic via the **transactional outbox** (no dual writes)
- [ ] Every consumer is **idempotent** (stable message id + dedup store with TTL); offsets commit after the effect
- [ ] Ordering per partition key where needed, never global; consumers tolerate cross-key reordering
- [ ] Retries bounded backoff + jitter; poison messages to a **DLQ** after N (alerted + replayable); schemas in a registry with compat enforced
- [ ] Events past-tense, versioned, **CloudEvents** envelope; `traceparent` propagated; consumer lag + DLQ depth alerted

## Testing strategy & review

_Source: [practices/testing-strategy.md](practices/testing-strategy.md) · [practices/code-review.md](practices/code-review.md)._
- [ ] Test pyramid (unit + integration + few e2e); mock at the boundary; contract tests on seams
- [ ] **Flaky-test policy**: quarantine + owner + ban on retry-to-green; coverage floor ratcheted
- [ ] Code review: small PRs, reviewer SLA, blocker/nit convention, heightened bar for AI-generated code

## Performance

_Source: [practices/performance.md](practices/performance.md)._
- [ ] Every optimized change carries a **before/after number** from a profile, not a guess
- [ ] Each surface has a written **budget**: backend p50/p95/p99 + RPS/memory ceiling; frontend CWV + bundle
- [ ] The right **profiler** is wired per stack (pprof / py-spy / clinic.js), sampling in prod
- [ ] **Load + stress** tests (**k6**) on critical paths with thresholds as pass/fail; soak test for long-running services _(scale-up)_
- [ ] Known bottlenecks checked (no **N+1**, no chatty I/O); caches emit hit-rate metrics with a target
- [ ] A CI **regression gate** fails the build on a significant latency/throughput/bundle regression, ratcheted

## Accessibility (if it has a UI)

_Source: [practices/accessibility.md](practices/accessibility.md)._
- [ ] Meets **WCAG 2.2 Level AA**; semantic HTML + landmarks, one `<h1>`, native controls over custom
- [ ] No invalid/over-applied ARIA; live regions for async updates; ARIA state stays in sync
- [ ] Full keyboard operability: logical focus order, visible `:focus-visible`, no traps, skip link
- [ ] Inputs labelled; errors are text + `aria-describedby` + announced; contrast meets AA (verified with a tool); no colour-only signals
- [ ] `alt` on every image; captions on video; `prefers-reduced-motion` honoured; zoom not blocked
- [ ] **eslint-plugin-jsx-a11y** + **jest-axe** + Playwright/Lighthouse a11y green in CI; manual keyboard + screen-reader pass for new patterns

## Shell scripts (if present)

_Source: [languages/shell.md](languages/shell.md)._
- [ ] `set -euo pipefail`; **shellcheck** + **shfmt** in CI/pre-commit; quoted expansions
- [ ] Scripts that outgrow ~100 lines / need real data structures are rewritten in Python or Go

## How to run the gates

```bash
uv run ruff check . && uv run ruff format --check . && uv run pytest -q && uvx pyright   # Python
pnpm biome ci . && pnpm typecheck && pnpm test && pnpm build                              # TS/React
gofumpt -l . && golangci-lint run && go test -race ./... && govulncheck ./...             # Go
hadolint Dockerfile && docker compose build                                               # Containers
```
