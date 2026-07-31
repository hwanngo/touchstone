---
name: java-kotlin-standards
description: Use when writing, reviewing, testing, formatting, or building any Java or Kotlin code in a touchstone repo — triggers on .java/.kt files, build.gradle(.kts)/settings.gradle.kts, gradle/libs.versions.toml, or pom.xml. Covers JDK/Gradle toolchain, Spotless, null-safety, records/sealed types, coroutines/virtual threads, JUnit/Testcontainers, and reproducible builds. Not for Android UI, JVM service frameworks, or cross-cutting supply-chain (see security/dependencies siblings).
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Java & Kotlin (JVM) Standards

Full standard: **`standards/languages/java-kotlin.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **One JDK, one build tool:** LTS **Temurin (21/25)** via SDKMAN!, pinned by **Gradle toolchain**; **Gradle Kotlin DSL** + version catalog (`libs.versions.toml`). Maven is the escape hatch. Commit + SHA-pin the Wrapper.
- **Format with Spotless** (google-java-format + ktlint); `spotlessCheck` is the CI gate. **Error Prone + NullAway** (Java) and **Detekt** (Kotlin) on every build; warnings are errors.
- **JUnit + AssertJ + Testcontainers**; mock only genuine external collaborators (MockK/Mockito). Coverage is a ratcheted floor.

## Don't get burned
- **Null-safety:** never `!!` in Kotlin; use `?.`/`?:`/`requireNotNull`. Java uses JSpecify `@NullMarked` + NullAway. `Optional` is a **return type only** — never a field or parameter. Assert nullability once at the Kotlin/Java seam.
- **Model data with `record`/`data class` and closed hierarchies with `sealed`** — exhaustive `switch`/`when` with **no `default`** so a new variant is a compile error.
- **Structured concurrency:** Kotlin coroutines in a `coroutineScope` (never `GlobalScope`); Java virtual threads + `StructuredTaskScope` (don't pool virtual threads, don't pin under `synchronized`). **Every blocking call is timeout-bounded.**
- **Lock the graph:** version catalog is the only version source; Gradle dependency **locking** + **verification** (checksums + signatures) on; commit the lockfile; CI builds `--offline`. `dependencyCheckAnalyze` clean.
- **Reproducible jars** (stable timestamps/order); ship via **jlink**, GraalVM `native-image` only where cold start is measured _(scale-up)_. Supply-chain details: `standards/practices/security.md` and `standards/practices/dependencies.md`.

## Done
`spotlessCheck` clean · Error Prone/NullAway + Detekt pass · warnings-as-errors · `./gradlew test` green (Testcontainers for integration) · dependency locking + verification on, lockfile committed · `dependencyCheckAnalyze` clean · reproducible jars with SBOM + signed provenance. See `standards/languages/java-kotlin.md`.
