---
name: swift-standards
description: Use when writing, reviewing, testing, formatting, or configuring any modern Swift (6.x) code (.swift files, Package.swift) in a touchstone repo — swiftly-pinned toolchain, SwiftPM, swift-format, Swift 6 strict concurrency (actors/Sendable/structured tasks), typed throws, no force-unwrap, Swift Testing. Invoke before adding deps, touching concurrency, editing tests, or changing the public API. Not for cross-cutting supply-chain (security-standards) or pipeline (ci-cd-standards) concerns.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Swift Standards

Full standard: **`standards/languages/swift.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **Pin the toolchain** with **swiftly** + a committed `.swift-version`; build with **SwiftPM**; adopt **Swift 6 language mode** (`swiftLanguageModes: [.v6]`) so concurrency races are compile errors.
- Format and lint with **swift-format** (`swift format lint --strict`, ships in the toolchain); compile `-warnings-as-errors`. Add SwiftLint only for rules swift-format can't express — never run two formatters.
- **No force-unwrap (`!`) / `try!` on a fallible path** — `guard let`/`if let`/`??`; reserve `!` for a documented impossible-state invariant.
- Test with **Swift Testing** (`@Test`/`#expect`/`#require`) for new tests; keep **XCTest** only for UI automation + perf metrics. Commit **`Package.resolved`**; CI resolves locked.

## Don't get burned
- **Concurrency (Swift 6):** put shared mutable state behind an `actor`, not a class+lock; `@MainActor` on UI types; only `Sendable` values cross boundaries (`@unchecked Sendable` needs a comment naming the synchronization). Prefer structured `TaskGroup`/`async let` over `Task.detached`; **own every detached handle**; never block a thread on async work (`DispatchSemaphore.wait`); bound every external await with a timeout.
- **Errors:** model a typed `enum: Error`; use Swift 6 **typed throws** (`throws(E)`) for library domain errors, untyped `throws` at forwarding boundaries. `Result` only when storing/passing a failure as a value. Never swallow into `try?` on a must-succeed path; `precondition`/`assert` guard programmer errors, never user input.
- **Types:** struct-first (value semantics → `Sendable`, free `Equatable`/`Codable`); `final` classes by default; `let` over `var`; don't fake reference semantics with a struct wrapping a class.
- **API:** narrowest access control by default; `public`/`@frozen` are SemVer commitments — guard with `swift package diagnose-api-breaking-changes`; use `some P` over `any P` unless genuinely heterogeneous (enable `ExistentialAny`).
- **Platforms:** SwiftUI for apps; **Vapor** (or lighter **Hummingbird**) for server-side; build a static Linux binary (`--static-swift-stdlib`) for distroless containers.

## Done
`swift build` clean under Swift 6 complete concurrency checking · `swift format lint --strict` clean, `-warnings-as-errors` · no `!`/`try!` on fallible paths, errors typed · shared state behind actors, boundaries `Sendable`, tasks owned, awaits bounded · models are value types, classes `final` · public API deliberate + breaking-change check clean · `swift test` green (Swift Testing) · `Package.resolved` committed, deps locked + minimal · static Linux artifact builds. See `standards/languages/swift.md`.
