---
name: spring-boot-standards
description: Use when building a Spring Boot 3.x service (Java or Kotlin) in a touchstone repo — structure, DI, typed config, web/validation, JPA, transactions, security, testing. Triggers on `org.springframework.boot` deps, `@SpringBootApplication`, `application.yml`/`application.properties`. JVM language rules live in the java-kotlin skill.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Spring Boot (framework)

Full standard: **`standards/frameworks/spring-boot.md`** (layers on `standards/languages/java-kotlin.md`). This
skill inlines the load-bearing rules so it stays useful standalone in `~/.claude/skills/`:

## Always
- **Package-by-feature**, not package-by-layer; `controller → service → repository` is the only call direction. DTOs at the edge, JPA entities in the core.
- **Constructor injection only** — no field/setter `@Autowired`, no `getBean` service-locator calls.
- **Typed `@ConfigurationProperties` (`@Validated`)**, not scattered `@Value`. Secrets come from env/secret-manager, **never** `application.yml`; profiles override structure only.
- **`@Valid` Bean Validation at the boundary**; errors as RFC 9457 `ProblemDetail` via `@RestControllerAdvice`; never return entities or leak stack traces.
- **`@Transactional` on services only** (`readOnly` for queries, short txns); migrations via Flyway/Liquibase; `ddl-auto=validate` (never `update`); `open-in-view=false`.

## Don't get burned
- **N+1** — default associations LAZY, then `JOIN FETCH`/`@EntityGraph` per query; assert query counts on hot endpoints.
- **Self-invocation** — a `this.method()` call skips the proxy, so its `@Transactional` is silently ignored.
- **Concurrency** — pick one model: MVC + virtual threads (`spring.threads.virtual.enabled=true`) for blocking JPA; WebFlux only for a fully non-blocking stack. One `block()` on the event loop stalls every request.
- **Security** — Spring Security deny-by-default (`anyRequest().authenticated()`); lock down Actuator except `health`/`info`.
- **Tests** — slice it (`@WebMvcTest`/`@DataJpaTest`/`@SpringBootTest`); Testcontainers with a real Postgres via `@ServiceConnection`, not H2.

## Defer (don't duplicate)
- JDK/build/null-safety → `../../standards/languages/java-kotlin.md`; schema/migrations/N+1 → `../../standards/platform/database.md`; authN/authZ → `../../standards/practices/app-security.md`; metrics/traces → `../../standards/platform/observability.md`; HTTP contracts → `../../standards/design/api-design.md`.

## Done
constructor DI · typed config, secrets external · `ProblemDetail` errors · `@Transactional` on services · N+1 guarded · deny-by-default security · sliced tests + Testcontainers. See `standards/frameworks/spring-boot.md`.
