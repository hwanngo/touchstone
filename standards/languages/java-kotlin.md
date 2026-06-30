# Java & Kotlin (JVM) Standards

Applies to any JVM project — modern **Java (21 LTS+)** and **Kotlin**, built with **Gradle
(Kotlin DSL)**, formatted by **Spotless**, and tested on **JUnit**. Cross-cutting concerns defer
to siblings: supply-chain and scanning to [security.md](../practices/security.md), update policy
to [dependencies.md](../practices/dependencies.md), the test pyramid to
[testing-strategy.md](../practices/testing-strategy.md), timeouts/retries to
[resilience.md](../design/resilience.md), and pipeline wiring to [ci-cd.md](../platform/ci-cd.md).

> **One law:** the build is reproducible and the version is pinned — same source, same JDK, same
> bytes, on every machine and in CI.

---

## 1. Toolchain

One JDK, one build tool, one of each linter — Maven is the documented escape hatch, not a parallel
default.

| Concern | Tool | Notes |
|---|---|---|
| JDK distribution | **Eclipse Temurin** via **SDKMAN!** | LTS only for prod: **21** or **25**. Never the OS JDK. |
| Version pin | **Gradle toolchains** | `java.toolchain.languageVersion` — Gradle *provisions* the JDK; build is independent of `JAVA_HOME`. |
| Build tool | **Gradle + Kotlin DSL** (`build.gradle.kts`) | `settings.gradle.kts`, `gradle/libs.versions.toml`. Groovy DSL is legacy. |
| Dependency declaration | **Version catalog** (`libs.versions.toml`) | One typed, central place for versions; `libs.foo` accessors. |
| Java format/lint | **Spotless** (google-java-format) + **Error Prone / NullAway** | Format is mechanical; Error Prone is compile-time bug-finding. |
| Kotlin format/lint | **Spotless** (ktlint) + **Detekt** | ktlint = official style; Detekt = static analysis. |
| Test stack | **JUnit + AssertJ + Testcontainers** | MockK (Kotlin) / Mockito (Java) only where a real collaborator is impractical. |
| Build escape hatch | **Maven** | Only for ecosystems that mandate it (some plugins, legacy orgs). Same gates apply. |

- **Commit the Gradle Wrapper** (`gradlew`, `gradle/wrapper/`) and pin its distribution with a
  **SHA-256** (`distributionSha256Sum`) so a tampered wrapper jar can't run on CI.
- **Enable the build cache and configuration cache** (default-preferred in Gradle 9) in
  `gradle.properties` — they cut rebuild time and *force* task inputs to be declared correctly:
  ```properties
  org.gradle.caching=true
  org.gradle.configuration-cache=true
  org.gradle.parallel=true
  ```

## 2. Everyday commands

```bash
sdk install java 21-tem && sdk use java 21-tem   # provision the 21 LTS JDK (or 25) — verify the current patch
./gradlew build                      # compile + test + lint (the CI default)
./gradlew test                       # JUnit only
./gradlew spotlessApply              # auto-format (Java + Kotlin)
./gradlew spotlessCheck              # verify formatting — what CI runs
./gradlew detekt                     # Kotlin static analysis
./gradlew dependencyCheckAnalyze     # OWASP dependency-check (CVE scan)
./gradlew dependencies --write-locks # refresh the dependency lockfile
./gradlew build --scan               # build with a shareable diagnostic scan
```

Run **`./gradlew --offline build` in CI after a warm cache** to prove the dependency graph is
fully locked (no surprise network fetch). Maven equivalents: `./mvnw verify`, `./mvnw spotless:check`.

## 3. Formatting & linting

- **Formatting is automated and non-negotiable** — Spotless owns it for both languages. Java uses
  **google-java-format** (AOSP/100-col, no config to bikeshed); Kotlin uses **ktlint**. CI runs
  `spotlessCheck`; a format diff fails the build. Style never appears in review.
  ```gradle
  spotless {
    java { googleJavaFormat() }   // optionally pin a version — check the current release
    kotlin { ktlint() }           // optionally pin a version — check the current release
  }
  ```
- **Error Prone + NullAway on every Java compile** — catches real bug classes (`@Nullable`
  violations, format-string mismatches, mutable-set leaks) at `javac` time, not in review. Wire it
  into the compiler with the `net.ltgt.errorprone` plugin and set `-Werror` once the baseline is clean.
- **Detekt for Kotlin** — complexity, exception-swallowing, coroutine misuse. Check in a
  `detekt.yml`; treat findings as build failures, not warnings. A suppressed rule needs a comment.
- **Fail the build on warnings deliberately.** `options.compilerArgs << "-Werror" << "-Xlint:all"`
  (Java) and `kotlinOptions { allWarningsAsErrors = true }` (Kotlin) — a warning that never fails is
  a warning nobody fixes.

## 4. Null-safety

The JVM's billion-dollar mistake is opt-out, not opt-in. Make absence a type, not a runtime surprise.

- **Kotlin: lean on the type system.** A `String` is non-null; `String?` is nullable. **Never use
  `!!`** to silence the compiler — it's a deliberate NPE. Prefer `?.`, `?:`, and `requireNotNull(x)
  { "msg" }` (which documents *why* at the boundary).
- **Java: annotate with JSpecify `@Nullable` / `@NonNull`** (the cross-tool standard, adopted by
  Guava, JUnit, Spring) and enforce with **NullAway** — it reads JSpecify and fails the build on a
  dereference of a possibly-null value. Mark a package non-null by default with
  `@NullMarked` so only the exceptions need annotating.
  ```java
  @NullMarked package com.acme.orders;   // everything non-null unless marked @Nullable
  ```
- **`Optional<T>` is a return type, never a field or parameter.** Use it to express "this lookup may
  find nothing" (`Optional<User> findById(...)`); don't store it, don't accept it as an argument,
  don't call `.get()` without an `orElseThrow`. For collections return an empty collection, not
  `Optional<List<>>`.
- **At the Kotlin/Java seam**, treat un-annotated Java types as *platform types* — wrap the call and
  assert nullability once, at the boundary, so a Java `null` can't leak untyped into Kotlin.

## 5. Modern idioms

Reach for the language's data-modelling primitives before hand-writing boilerplate.

| Need | Java (21+) | Kotlin |
|---|---|---|
| Immutable value object | **`record`** | **`data class`** |
| Closed type hierarchy | **`sealed interface` + records** | **`sealed class` / `sealed interface`** |
| Exhaustive dispatch | **pattern-matching `switch`** | **`when` (exhaustive, no `else`)** |
| Null/absence | `Optional<T>` (returns only) | `T?` |

- **Records and data classes for data; classes for behaviour.** A record/data class with logic
  hanging off it is a smell — keep them as transparent carriers and put behaviour in services.
- **Sealed hierarchies + exhaustive matching** make illegal states unrepresentable and turn a new
  variant into a *compile error* at every match site — no silent `default` fall-through:
  ```java
  sealed interface Shape permits Circle, Square {}
  record Circle(double r) implements Shape {}
  record Square(double s) implements Shape {}

  double area(Shape sh) {
      return switch (sh) {                 // no default: adding a variant won't compile until handled
          case Circle c -> Math.PI * c.r() * c.r();
          case Square s -> s.s() * s.s();
      };
  }
  ```
  ```kotlin
  sealed interface Result<out T>
  data class Ok<T>(val value: T) : Result<T>
  data class Err(val cause: Throwable) : Result<Nothing>

  fun <T> Result<T>.orThrow(): T = when (this) {   // exhaustive — compiler enforces both arms
      is Ok -> value
      is Err -> throw cause
  }
  ```
- **Kotlin: prefer `val` over `var`, expression bodies, and extension functions** over utility
  classes. **Java: `var` for local inference** where the type is obvious from the RHS, never to hide it.
- **Don't model errors you can recover from as exceptions** on hot paths — a sealed `Result` makes
  the failure part of the type and forces the caller to handle it.

## 6. Concurrency

- **Kotlin: coroutines + structured concurrency.** Launch concurrent work inside a `coroutineScope`
  so a child failure cancels its siblings and propagates — never `GlobalScope` (leaks, unowned
  lifetime). Confine work to a dispatcher (`Dispatchers.IO` for blocking I/O) and **make suspend
  functions main-safe** (they never block the caller's thread).
  ```kotlin
  suspend fun load(ids: List<Id>): List<Row> = coroutineScope {
      ids.map { async(Dispatchers.IO) { fetch(it) } }.awaitAll()  // one failure cancels the rest
  }
  ```
- **Java: virtual threads (21+) for I/O-bound concurrency** — one carrier-cheap thread per task; no
  thread-pool sizing. Pair with **structured concurrency** (`StructuredTaskScope`, preview through
  25) so subtasks share a deadline and fail as a unit. **Don't pool virtual threads** and don't pin
  them under a `synchronized` block holding I/O — use a `ReentrantLock`.
- **Bound every blocking call with a timeout** (`withTimeout` in Kotlin; a deadline on the
  `StructuredTaskScope`/HTTP client in Java). An un-timed remote call hangs a worker forever — this
  is the language face of [resilience.md](../design/resilience.md).
- **Immutability is the default concurrency strategy** — share `record`/`data class` values, not
  mutable state. When you must share mutable state, reach for `java.util.concurrent` (`Atomic*`,
  `ConcurrentHashMap`) over `synchronized`, and never a non-thread-safe collection across threads.

## 7. Testing

- **JUnit 5 (Jupiter) is the floor; move to JUnit 6 once your baseline is Java 17+** (unified
  versioning, native Kotlin `suspend` test support, JSpecify-annotated API). Tests live under
  `src/test/java` / `src/test/kotlin`.
- **AssertJ for assertions** (`assertThat(x).isEqualTo(...)`) — fluent, readable failure messages,
  far better than bare JUnit asserts. **Kotlin may use kotlin.test / Kotest** where the team has
  standardized; don't mix three assertion libraries in one module.
- **Mock only what you must.** Prefer real objects and in-memory fakes; use **MockK** (Kotlin —
  understands coroutines/final classes) or **Mockito** (Java) for genuine external collaborators,
  not for code you own. A test that mocks the thing under test asserts nothing.
- **Integration tests use Testcontainers**, not mocks-of-a-database — a real Postgres/Kafka in a
  throwaway container catches the bugs a mock hides. Gate the slow suite behind a JUnit `@Tag`:
  ```kotlin
  @Tag("integration")
  @Testcontainers
  class OrderRepoTest {
      companion object { @Container val db = PostgreSQLContainer("postgres:17-alpine") }
  }
  ```
  Run fast tests by default; `./gradlew test -PincludeTags=integration` in the slow CI lane.
- **Property-based tests for parsers/encoders** (jqwik for Java, Kotest property module) at
  untrusted-input boundaries — the shrunk counterexample becomes a permanent regression. Coverage
  (JaCoCo) is a **floor, ratcheted up**, never a target. The pyramid lives in
  [testing-strategy.md](../practices/testing-strategy.md).

## 8. Dependencies & supply chain

- **Version catalog is the single source of versions.** Declare libraries and plugin versions in
  `gradle/libs.versions.toml`; modules reference `libs.*`. No version literals scattered in build
  files, no two modules on different minor versions of the same lib by accident.
- **Lock the graph.** Enable Gradle **dependency locking** (`dependencyLocking { lockAllConfigurations() }`)
  and commit `gradle.lockfile`; CI builds with `--offline` against it so a transitive version can't
  drift silently. Maven escape hatch: pin every version in `<dependencyManagement>` + the
  reproducible-build plugin.
- **Verify integrity, not just versions.** Turn on Gradle **dependency verification**
  (`gradle/verification-metadata.xml` with SHA-256 **and** PGP signatures) so a swapped artifact
  fails the build — this is the JVM half of [security.md](../practices/security.md).
- **Scan in CI.** **OWASP dependency-check** (`dependencyCheckAnalyze`) against the resolved graph,
  gated at `high`+; updates flow through Renovate/Dependabot with a **cooldown** (CVE patches
  bypass it). Policy lives in [dependencies.md](../practices/dependencies.md).
- **Keep the graph lean** — a BOM (`platform(...)`) aligns related libraries to one tested set;
  prefer the JDK/stdlib over a dependency for one helper function.

## 9. Build & release

- **Reproducible builds are the contract.** Set stable archive metadata so the same source yields
  byte-identical jars — auditable, cacheable, and the precondition for trustworthy provenance:
  ```gradle
  tasks.withType<AbstractArchiveTask> {
      isPreserveFileTimestamps = false
      isReproducibleFileOrder = true
  }
  ```
- **Pin the bytecode target to your LTS floor** via the Gradle toolchain (`release = 21`), so the
  build can't silently emit class files newer than your deploy JDK.
- **Ship a runtime, not a JDK.** _(scale-up)_ Use **jlink** to assemble a minimal custom runtime
  image (only the modules you use) on a distroless/`jlink` base — smaller surface, faster start than
  a full JRE. Containerize per [docker.md](../platform/docker.md) (nonroot, distroless).
- **GraalVM `native-image` for cold-start-sensitive workloads** _(scale-up)_ — CLIs, serverless,
  scale-to-zero. It trades reflection-config maintenance and longer builds for sub-100ms startup;
  adopt it only where startup/footprint is a measured constraint, not by reflex.
- **Emit an SBOM and signed provenance** for every published artifact (CycloneDX Gradle plugin +
  SLSA attestation) and publish via OIDC, not a long-lived token — see
  [security.md](../practices/security.md) and [ci-cd.md](../platform/ci-cd.md).

## Definition of done

- [ ] JDK is an LTS Temurin (21/25), provisioned via Gradle toolchain; Wrapper committed + SHA-pinned
- [ ] `./gradlew spotlessCheck` clean (google-java-format + ktlint); Error Prone/NullAway + Detekt pass
- [ ] Warnings are errors (`-Werror` / `allWarningsAsErrors`); no `!!` in Kotlin, no untyped platform leaks
- [ ] Null-safety enforced: JSpecify `@NullMarked` + NullAway (Java); `Optional` only as a return type
- [ ] Data modelled with records/data classes + sealed types; `switch`/`when` exhaustive (no stray `default`)
- [ ] Concurrency is structured (coroutine scope / `StructuredTaskScope`); every blocking call is timeout-bounded
- [ ] `./gradlew test` green; integration tests use Testcontainers; coverage ≥ ratcheted floor
- [ ] Version catalog is the only version source; dependency locking on; lockfile committed; CI builds `--offline`
- [ ] Dependency verification (checksums + signatures) on; `dependencyCheckAnalyze` clean (or triaged)
- [ ] Release jars are reproducible; published artifacts carry an SBOM + signed provenance
