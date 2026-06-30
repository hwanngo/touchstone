# Spring Boot Standards

Framework layer; language rules → [java-kotlin.md](../languages/java-kotlin.md). Targets **current
Spring Boot** (verify the release — the line is mid 3.x→4.x transition) on a **Java 21+ / Kotlin** baseline. This doc owns only the Spring-shaped decisions;
cross-cutting concerns are **deferred, not repeated**: JDK/build/null-safety →
[java-kotlin.md](../languages/java-kotlin.md), schema/migrations/N+1 →
[database.md](../platform/database.md), authN/authZ/OWASP →
[app-security.md](../practices/app-security.md), metrics/traces/logs →
[observability.md](../platform/observability.md), the test pyramid →
[testing-strategy.md](../practices/testing-strategy.md), HTTP contracts →
[api-design.md](../design/api-design.md), timeouts/retries → [resilience.md](../design/resilience.md).

> **One law:** beans are wired by the constructor, config is typed, and every layer boundary is
> explicit — no field injection, no `@Value` confetti, no business logic in a controller.

---

## 1. Project structure

**Package-by-feature, never package-by-layer.** A `com.acme.orders` package holds that feature's
controller, service, repository, and DTOs together; a top-level `controllers/`/`services/`/
`repositories/` split forces every change to fan out across the tree and couples features.

```text
com.acme
  Application.java                 // @SpringBootApplication — the one entry point
  orders/  OrderController  OrderService  OrderRepository  OrderDtos  OrderConfig
  billing/ BillingController BillingService BillingRepository …
  shared/  error/ (ProblemDetail advice)  config/ (cross-cutting beans)
```

- **`controller → service → repository` is the only allowed call direction.** A controller never
  touches a repository; a repository never calls a service. The service is the transaction and
  business-rule boundary (§6).
- **Keep `@SpringBootApplication` at the root package** so component scanning covers every feature
  without an explicit `scanBasePackages` — one application class, no `@ComponentScan` sprawl.
- **DTOs at the edge, entities in the core.** Controllers speak `record`/`data class` DTOs; JPA
  entities never cross the web boundary (§4) — map in the service, not the controller.

## 2. Dependency injection

**Constructor injection only.** It makes dependencies final, visible, and testable without the
container — and a class whose constructor has eight args is *telling you* it does too much.

```java
@Service
public class OrderService {
    private final OrderRepository repo;
    private final PricingClient pricing;
    OrderService(OrderRepository repo, PricingClient pricing) {  // no @Autowired needed
        this.repo = repo; this.pricing = pricing;
    }
}
```

| Rule | Why |
|---|---|
| **No field/setter `@Autowired`** | Hides dependencies, defeats `final`, allows half-built objects, needs reflection to test. |
| **Single constructor → omit `@Autowired`** | Spring 4.3+ auto-wires the lone constructor; the annotation is noise. |
| **Inject interfaces, not implementations** | Swap a fake in tests; keep the seam where the layering demands it. |
| **No `ApplicationContext.getBean(...)`** | Service-locator anti-pattern — wire it in, don't pull it out. |
| **`@Configuration` `@Bean` methods for third-party types** | You can't annotate a library class; declare it in a config class instead. |
| **Kotlin** | A primary-constructor `class OrderService(private val repo: OrderRepository)` is the whole pattern — no annotation, no boilerplate. |

## 3. Typed configuration

**Typed `@ConfigurationProperties`, never scattered `@Value`.** Bind a whole prefix to an immutable
record/data class, validate it, and fail startup on a bad value.

```kotlin
@ConfigurationProperties("app.orders")
@Validated
data class OrderProps(@field:Positive val maxItems: Int, val holdTtl: Duration)
```

- **Secrets never live in `application.yml`.** Inject them from the environment or a secret manager
  (Vault, AWS/GCP secret stores) via `${ENV_VAR}` placeholders or Spring Cloud Config; commit only
  non-secret defaults. A leaked repo must not leak a credential — see
  [app-security.md](../practices/app-security.md).
- **Profiles for environment shape, not secrets.** `application-prod.yml` overrides *structure*
  (pool sizes, log levels, flags); secrets still come from outside. Set the active profile with
  `SPRING_PROFILES_ACTIVE`, never hard-code a default of `prod`.
- **Validate config at startup.** `@Validated` + Bean Validation on the properties record turns a
  typo into a fast boot failure, not a 3am `NullPointerException`. Register types with
  `@ConfigurationPropertiesScan`, not `@Component`, so they stay plain bindable carriers.

## 4. Web layer

`@RestController` methods stay thin: validate input → call a service → return a DTO. No persistence,
no business branching in the controller.

- **Bean Validation at the boundary.** Annotate request records (`@NotBlank`, `@Email`, `@Positive`)
  and put `@Valid` on the parameter (`create(@Valid @RequestBody CreateOrder body)`); a
  `@RestControllerAdvice` turns the resulting `MethodArgumentNotValidException` into one error shape.
  Validate *business* invariants in the service, not with ever-more-clever annotations.
- **Errors are RFC 9457 `application/problem+json`.** Spring 6's `ProblemDetail` is the built-in
  carrier; centralize the mapping in a `@RestControllerAdvice` so every failure exits the same way.
  Never leak a stack trace, a JPA message, or an entity to the client.

  ```java
  @RestControllerAdvice
  class ApiErrors {
      @ExceptionHandler(OrderNotFound.class)
      ProblemDetail handle(OrderNotFound e) {       // serialized as application/problem+json
          return ProblemDetail.forStatusAndDetail(NOT_FOUND, e.getMessage());
      }
  }
  ```

- **Version and lint the API contract.** Set explicit paths and `operationId`s; export and diff the
  OpenAPI schema (springdoc) in CI ([api-design.md](../design/api-design.md)). Use `@RestController`,
  and never return entities directly — a response DTO is defense-in-depth against leaking a column.

## 5. Data access

Spring Data JPA is the default for CRUD; drop to a query builder (jOOQ/`JdbcClient`) for hot paths
and complex joins. **Schema and migration rules live in [database.md](../platform/database.md)** —
this section is only the Spring binding.

| Concern | Rule |
|---|---|
| **Migrations** | **Flyway** (default) or **Liquibase** run on startup/deploy; the schema is owned by `db/migration/`, **never** `ddl-auto`. |
| **`spring.jpa.hibernate.ddl-auto`** | `validate` in every shared environment; `none`/`validate` in prod. **Never `update`/`create`** — it silently mutates prod schema. |
| **`open-in-view`** | **`spring.jpa.open-in-view=false`** — the default `true` keeps a session open through view rendering, hiding lazy-load N+1s and holding connections. |
| **Reads** | Fetch interface/record projections; don't load a full entity graph to return three fields. |

- **N+1 is the JPA tax — pay it deliberately.** Default associations to `FetchType.LAZY`, then
  eager-load *per query* with a `JOIN FETCH` or an `@EntityGraph` (`@EntityGraph(attributePaths =
  "lines")` on the repository method) where you actually traverse the collection. Assert query counts
  on hot endpoints; background and tooling → [database.md](../platform/database.md).

- **Bound the pool.** Set HikariCP `maximum-pool-size` from `(cores × N) + headroom`, plus
  `connection-timeout` and a DB-side `statement_timeout`; an unbounded pool topples the database
  under a spike.

## 6. Transactions

**`@Transactional` lives on the service method, not the controller and not the repository.** The
service is the unit-of-work boundary — one business operation, one transaction.

- **`@Transactional(readOnly = true)` for queries** — it lets Hibernate skip dirty-checking and
  routes to a read replica when configured.
- **Keep transactions short.** Open late, commit early; **never** hold a transaction across a remote
  HTTP/RPC call or user think-time — it pins a connection and piles up locks
  ([database.md](../platform/database.md)).
- **Know the self-invocation trap.** A `this.otherMethod()` call inside the same bean bypasses the
  proxy, so its `@Transactional` is *ignored*. Split the method into another bean, or the boundary
  silently vanishes.
- **Default rollback is runtime-exceptions only.** Checked exceptions don't roll back unless you set
  `rollbackFor`; prefer unchecked domain exceptions so the default does the right thing.
- **Don't span aggregates in one transaction at scale** _(scale-up)_ — use an outbox + events, not a
  distributed transaction ([resilience.md](../design/resilience.md)).

## 7. Concurrency: virtual threads vs WebFlux

Pick **one** concurrency model per service — don't blend blocking JPA into a reactive pipeline.

| Workload | Choice | Why |
|---|---|---|
| Blocking I/O (JPA, JDBC, sync SDKs) — the common case | **MVC + virtual threads** | `spring.threads.virtual.enabled=true` (Boot 3.2+) gives high concurrency with plain blocking code; keep the readable imperative style. |
| Streaming, very high connection counts, fully non-blocking stack (R2DBC, reactive clients) | **WebFlux** | Reactor backpressure earns its complexity only when the *whole* path is non-blocking. |
| Kotlin, non-blocking | **Coroutines over WebFlux** | `suspend` controllers read like blocking code; see [java-kotlin.md](../languages/java-kotlin.md). |

- **Virtual threads are the new default for blocking apps** — they retire the "tune the Tomcat
  thread pool" problem. Don't pool them, and don't pin them under a `synchronized` block holding I/O
  (use a `ReentrantLock`) — same rule as [java-kotlin.md](../languages/java-kotlin.md). One blocking
  call on a WebFlux event loop stalls *every* request, so on JPA you want MVC, not `block()`.
- **Bound every outbound call with a timeout** (`RestClient`/`WebClient` connect+read timeouts) —
  an un-timed dependency call is the language face of [resilience.md](../design/resilience.md).

## 8. Security

Spring Security is **deny-by-default**: every request needs an authenticated, authorized match or it
is rejected. Mechanism here; policy and OWASP → [app-security.md](../practices/app-security.md).

```java
@Bean
SecurityFilterChain http(HttpSecurity http) throws Exception {
    return http
        .authorizeHttpRequests(a -> a
            .requestMatchers("/actuator/health", "/actuator/info").permitAll()
            .anyRequest().authenticated())          // deny-by-default
        .oauth2ResourceServer(o -> o.jwt(withDefaults()))
        .csrf(csrf -> csrf.disable())               // stateless API; keep CSRF on for browser sessions
        .build();
}
```

- **Lock down Actuator.** Expose only `health`/`info` publicly; everything else (`env`, `heapdump`,
  `loggers`) needs an authenticated role — these endpoints leak config and memory.
- **Method security for fine-grained checks:** `@PreAuthorize("hasAuthority('orders:write')")` on
  service methods, never an `if (user.isAdmin())` buried in a handler. Authn at the filter chain,
  authz close to the operation — never assume authenticated means authorized.

## 9. Observability

Actuator + Micrometer are wired in; the standard owns *what* and *where* —
[observability.md](../platform/observability.md).

- **Micrometer is the metrics facade**; register a `MeterRegistry` for your backend (Prometheus/OTLP)
  and rely on Boot's auto-instrumented HTTP/datasource/JVM metrics. Tag, but mind cardinality.
- **Tracing via Micrometer Tracing → OpenTelemetry** (OTLP export); propagate context across
  `RestClient`/`WebClient` and async hops so a request stitches into one trace.
- **Structured JSON logs with the trace/span id** (Boot 3.4 ships a structured-logging format) so a
  log line joins its trace; one line per request — method, path, status, latency.
- **Health probes for the orchestrator:** enable `livenessState`/`readinessState` and map them to
  Kubernetes probes; readiness must fail while dependencies warm up.

## 10. Testing

Match the test slice to the unit under test — a full context for everything is slow and proves
little. Pyramid → [testing-strategy.md](../practices/testing-strategy.md).

| Test | Annotation | Loads |
|---|---|---|
| Service / domain | none — plain JUnit 5 | nothing; construct with fakes/mocks. The bulk of the suite. |
| Web layer | **`@WebMvcTest`** | controllers + `MockMvc`, services mocked. Asserts status, JSON, validation, problem+json. |
| Persistence | **`@DataJpaTest`** + **Testcontainers** | JPA + a **real** Postgres, not H2 — H2 hides dialect bugs. |
| Wired path | **`@SpringBootTest`** _(scale-up)_ | the whole context; reserve for a few end-to-end flows. |

```java
@DataJpaTest
@Testcontainers
class OrderRepoTest {
    @Container @ServiceConnection
    static PostgreSQLContainer<?> db = new PostgreSQLContainer<>("postgres:17-alpine");
    // @ServiceConnection (Boot 3.1+) auto-wires the datasource — no @DynamicPropertySource
}
```

- **`@ServiceConnection` over `@DynamicPropertySource`** for Testcontainers (Boot 3.1+). **Don't
  mock the framework** — mock collaborators you own; a test that mocks the repository *and* the
  service asserts nothing.

## 11. Build & packaging

- **Gradle (Kotlin DSL) is the default**, Maven the documented escape hatch — same gates either way.
  Use the Spring dependency-management BOM so starter versions align to one tested set.
- **Build an OCI image with the buildpack:** `./gradlew bootBuildImage` (Cloud Native Buildpacks)
  produces a layered, reproducible image without a hand-written Dockerfile; layered jars keep
  dependency layers cacheable.
- **GraalVM native image for cold-start-sensitive workloads** _(scale-up)_ — the AOT/native profile
  trades longer builds and reflection hints for sub-100ms startup; adopt it only where
  startup/footprint is a *measured* constraint.
- **Emit a CycloneDX SBOM and signed provenance** for every published artifact (Boot 3.3+ builds the
  SBOM). Toolchain, container hardening, and supply-chain rules → [java-kotlin.md](../languages/java-kotlin.md).

## Definition of done

- [ ] Package-by-feature; `controller → service → repository` direction only; DTOs at the edge, entities in the core
- [ ] Constructor injection everywhere; no field/setter `@Autowired`; no `getBean` service-locator calls
- [ ] Config is typed `@ConfigurationProperties` (`@Validated`); secrets come from env/secret-manager, never `application.yml`
- [ ] Profiles override structure only; active profile from `SPRING_PROFILES_ACTIVE`
- [ ] Controllers thin; `@Valid` + Bean Validation at the edge; business invariants checked in the service
- [ ] Errors are RFC 9457 `ProblemDetail` via `@RestControllerAdvice`; no stack traces/entities leaked; OpenAPI versioned in CI
- [ ] Migrations via Flyway/Liquibase; `ddl-auto=validate` (never `update`); `open-in-view=false`; pool bounded
- [ ] N+1 guarded with `JOIN FETCH`/`@EntityGraph` + query-count assertions on hot endpoints
- [ ] `@Transactional` on services only; `readOnly` for queries; short txns; self-invocation trap avoided
- [ ] One concurrency model: MVC + virtual threads for blocking, WebFlux only for a fully non-blocking stack; outbound calls timeout-bounded
- [ ] Spring Security deny-by-default; Actuator locked down except health/info; method security for fine-grained authz
- [ ] Actuator + Micrometer metrics, Micrometer Tracing → OTel, structured JSON logs with trace id; liveness/readiness probes
- [ ] Tests sliced (`@WebMvcTest`/`@DataJpaTest`/`@SpringBootTest`); Testcontainers (real Postgres) via `@ServiceConnection`
- [ ] Image built with `bootBuildImage` (layered jars); SBOM + signed provenance on published artifacts

**Sources:** [spring-projects/spring-boot](https://github.com/spring-projects/spring-boot) · [Spring Boot reference docs](https://docs.spring.io/spring-boot/index.html) · [Spring Framework — `@Transactional`](https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html) · [Spring Boot — virtual threads](https://docs.spring.io/spring-boot/reference/features/task-execution-and-scheduling.html) · [Spring Security — authorization architecture](https://docs.spring.io/spring-security/reference/servlet/authorization/architecture.html) · [Spring — RFC 9457 `ProblemDetail`](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-ann-rest-exceptions.html) · [Testcontainers + Spring Boot](https://java.testcontainers.org/test_framework_integration/spring_boot/)
