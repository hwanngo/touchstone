# Swift Standards

Applies to any modern Swift (6.x) project. Toolchain pinned with **swiftly** + `.swift-version`,
built with **SwiftPM** (`Package.swift`), formatted and linted with **swift-format**, concurrency
checked under **Swift 6 complete checking**, and tested with the **Swift Testing** framework.
Cross-cutting concerns defer to siblings: supply-chain to
[security.md](../practices/security.md), dependency policy to [dependencies.md](../practices/dependencies.md),
test philosophy to [testing-strategy.md](../practices/testing-strategy.md), timeouts/cancellation to
[resilience.md](../design/resilience.md), and pipelines to [ci-cd.md](../platform/ci-cd.md).

> **One law:** compile clean under Swift 6 complete concurrency checking with no force-unwraps on a
> fallible path, or it isn't done.

---

## 1. Toolchain & versions

- **Pin the toolchain with swiftly** (the official Swift.org toolchain manager) and commit a
  **`.swift-version`** file so every dev and CI resolves the same compiler — no "works on my Xcode".
  ```bash
  swiftly install latest       # install the current toolchain — verify the release before pinning
  swiftly use latest           # writes/reads .swift-version in the project
  ```
- **Adopt the Swift 6 language mode** for new code — set `swiftLanguageModes: [.v6]` in the manifest
  so complete concurrency checking (§4) is a compile error, not a warning you'll never read.
- **Declare the platform floor** in `Package.swift` (`platforms: [.macOS(.v15), .iOS(.v18)]`); it is
  the minimum you support and what `availability` checks key off — set it deliberately, raise it
  knowingly (a SemVer-minor event for a library).
- One job per tool: **swift** / **xcodebuild** drive everything — never invoke `swiftc` directly.
  ```swift
  // swift-tools-version: 6.0
  let package = Package(
      name: "Acme",
      platforms: [.macOS(.v15), .iOS(.v18)],
      // ...
      swiftLanguageModes: [.v6])
  ```

## 2. Everyday commands

```bash
swift build                                        # build the package
swift test                                          # run the test suite (Swift Testing + XCTest)
swift format lint --strict --recursive Sources Tests  # lint, warnings are errors (CI gate)
swift format --in-place --recursive Sources Tests   # auto-format
swift package resolve                               # resolve deps, write Package.resolved
swift package show-dependencies                     # audit the dependency tree
swift package diagnose-api-breaking-changes <ref>   # SemVer guard for a library's public API
```

Add a dependency by editing `Package.swift` `dependencies:` and the target's `dependencies:`, then
`swift package resolve` — commit `Package.resolved` (§9). For app targets, the same runs through
Xcode's package UI, which writes the same resolved file.

## 3. Formatting & linting

- **Formatting is automated and non-negotiable.** Use **swift-format** (ships in the toolchain);
  never hand-align. Keep a checked-in `.swift-format` config and let the house style rule — CI runs
  `swift format lint --strict`; a diff is a red build.
- **`--strict` makes lint warnings errors** — a warning that isn't an error gets ignored forever.
  Wire it as a pre-build/CI step, not an editor nicety.
- **Reach for SwiftLint only for rules swift-format can't express** (custom regex rules, cyclomatic
  complexity, file length). Don't run both formatters — swift-format owns layout; if you add
  SwiftLint, scope it to analysis rules and disable its formatting rules so they can't fight.
- **Compile with warnings-as-errors** in CI (`-warnings-as-errors`) and turn on upcoming-feature
  flags early (`ExistentialAny`, `InternalImportsByDefault`) so a future language mode isn't a wall.

## 4. Strict concurrency

Swift 6 mode turns data races into **compile errors**. Don't suppress the checker — fix the
isolation. Timeouts and cancellation here are the async face of the resilience rules in
[resilience.md](../design/resilience.md).

- **`async`/`await` over completion handlers and raw `Task` chaining** — let the suspension points
  be visible. Never block a thread waiting on async work (`DispatchSemaphore.wait()`, `.sync` on the
  main queue); it defeats the cooperative pool and can deadlock.
- **Actors protect mutable shared state** — reach for an `actor` instead of a class plus a lock.
  Cross-actor calls are `await`ed; synchronous reentrancy bugs become a type error.
  ```swift
  actor Counter {
      private var value = 0
      func increment() { value += 1 }
      var current: Int { value }
  }
  ```
- **`@MainActor` for UI and main-thread state** — annotate the type, not every method. Swift 6.2's
  *default actor isolation* mode can make `@MainActor` the module default; opt a type out with
  `nonisolated` for genuinely background-safe work.
- **`Sendable` is the boundary contract** — only `Sendable` values cross actor/task boundaries.
  Prefer value types (which are `Sendable` when their members are); mark a reviewed reference type
  `@unchecked Sendable` **only** with a comment naming the synchronization that makes it safe.
- **Structured concurrency over detached tasks** — child tasks inherit cancellation and priority and
  can't outlive their scope. Use a `TaskGroup` (or `async let`) for fan-out; reserve `Task.detached`
  for genuinely independent work and **own its handle** so cancellation and errors don't vanish.
  ```swift
  let results = try await withThrowingTaskGroup(of: Row.self) { group in
      for id in ids { group.addTask { try await load(id) } }   // bounded, cancels on first throw
      return try await group.reduce(into: []) { $0.append($1) }
  }
  ```
- **Bound every external await** — there is no implicit network/IO timeout. Race the work against a
  sleep in a group, or use a deadline-aware client; an un-timed `await` hangs the task forever
  ([resilience.md](../design/resilience.md)).

## 5. Optionals & error handling

- **No force-unwrap (`!`) or `try!` on a fallible path** — they trap and abort the process. Bind with
  `guard let`/`if let`, default with `??`, or `map`/`flatMap`. Reserve `!` for a genuinely
  impossible state (a hard-coded `URL`, an IBOutlet), and treat each one as a documented invariant.
  ```swift
  guard let user = cache[id] else { throw StoreError.notFound(id) }   // not cache[id]!
  ```
- **Model errors as a typed `enum: Error`** so callers can `switch` exhaustively. Swift 6 **typed
  throws** (`throws(StoreError)`) put the error type in the signature — use it for a library's
  domain errors; keep untyped `throws` (which is `throws(any Error)`) at boundaries that genuinely
  forward arbitrary failures.
  ```swift
  enum StoreError: Error { case notFound(UserID), backend(any Error) }
  func fetch(_ id: UserID) throws(StoreError) -> User { /* ... */ }
  ```
- **`Result<Success, Failure>` only where you store or pass a failure as a value** (caching an
  outcome, a completion-handler bridge) — not as a substitute for `throws` on the happy path.
- **Propagate with `try`; add context, don't restringify.** Never swallow an error into `try?` on a
  path that must succeed — handle it, rethrow it, or log-and-continue *deliberately*. `try?` is for
  "absence is a valid result", not for hiding failures.
- **`precondition`/`assert` guard programmer errors** (invariants, API misuse), never user input or
  I/O failures — those return errors. `assert` is compiled out in release; `precondition` is not.

## 6. Value vs reference types

- **Struct-first.** Default to `struct` (and `enum`) for models, DTOs, and value objects — value
  semantics give you `Sendable`, no shared mutable aliasing, and free `Equatable`/`Hashable`/`Codable`
  via synthesis. Reach for `class` only when you need identity, inheritance, or deinit-based cleanup.
- **`final` by default on classes** — open inheritance is the exception, not the default; `final`
  enables devirtualization and states the design intent. Use `actor` over `class` the moment shared
  mutable state is involved (§4).
- **Prefer `let` over `var`**, and immutable value types over mutable ones — mutation through a copy
  is a local, race-free operation. Mark stored properties `private`/`private(set)` so invariants
  live behind methods, not bare fields.
- **Don't fake reference semantics with a struct** holding a class just to share mutation — that's a
  reference type wearing a value-type costume, and it breaks `Sendable` reasoning.

## 7. API design & access control

- **Protocol-oriented, but not protocol-everything.** Define a protocol when there are real multiple
  implementations or a seam to test/mock; don't add a single-conformer protocol "for flexibility".
  Prefer generic constraints (`some`/`any`) and small protocols composed over fat ones.
- **`any` is explicit existential cost.** Use `some P` (opaque, static dispatch) for returns and
  parameters with one underlying type; reserve `any P` for genuine heterogeneity, and enable the
  `ExistentialAny` upcoming feature so the cost is never silent.
- **Access control is the API contract** — default to the narrowest: `private` → `fileprivate` →
  `internal` → `package` → `public`. Mark a library's surface `public` deliberately; add `final` and
  document it. **`@frozen`/`public` are SemVer commitments** — guard them with
  `swift package diagnose-api-breaking-changes` in CI. See [api-design.md](../design/api-design.md).
- **`Codable` for serialization** with explicit `CodingKeys` when the wire contract differs from
  property names — never ship implicit name-derived keys for an external contract. Validate decoded
  input at the boundary; a successful decode is not a valid domain object.

## 8. Testing

- **Swift Testing is the default for new tests** (`import Testing`, ships with the toolchain) — `@Test`
  functions, `#expect`/`#require` macros with rich failure capture, `@Suite` types, parameterized
  cases, and parallel-by-default execution. See [testing-strategy.md](../practices/testing-strategy.md)
  for the unit/integration split.
  ```swift
  @Test("decodes a known payload", arguments: samplePayloads)
  func decodes(_ p: Payload) throws {
      let user = try JSONDecoder().decode(User.self, from: p.data)
      #expect(user.id == p.expectedID)
  }
  ```
- **`#expect` for soft checks, `#require` to stop the test** when a precondition fails (it throws,
  unwrapping safely — the test-side replacement for `!`). `#expect(throws: StoreError.self)` asserts
  and **returns the matched error** so you can inspect it.
- **Keep XCTest for what Swift Testing doesn't cover** — UI automation (`XCUIApplication`) and
  performance metrics (`XCTMetric`/`measure`). The two frameworks coexist in one target; migrate unit
  tests incrementally, don't rewrite wholesale.
- **Write the test first** for new behaviour and bugfixes (TDD); keep tests deterministic — no
  wall-clock or network. Test concurrent code by awaiting outcomes, never `sleep`-and-hope.
- _(scale-up)_ Gate coverage with a floor that ratchets up (`swift test --enable-code-coverage` +
  `llvm-cov`), and run the suite under **Thread Sanitizer** in CI to catch residual races.

## 9. Packages & dependencies

- **Commit `Package.resolved`** — it pins the exact versions CI tests, for libraries *and* apps. CI
  resolves against it (don't let a fresh resolve silently pull a newer, untested graph).
- **Pin with version ranges in the manifest, exact commits in the resolved file.** Prefer
  `.upToNextMajor(from:)` for trusted deps; never a floating `branch:` dependency in a release build.
- **Keep the dependency tree lean** — audit with `swift package show-dependencies`; every transitive
  dependency is attack surface and build cost. Policy lives in
  [dependencies.md](../practices/dependencies.md); supply-chain (SBOM, provenance, advisory scanning)
  in [security.md](../practices/security.md).
- **Split a reusable library target from the app/executable** so logic is testable without booting the
  UI — and so it can be extracted later without surgery.
- _(scale-up)_ Mirror or vendor critical dependencies and verify checksums; automate updates via
  Dependabot/Renovate with a cooldown, paired with advisory scanning.

## 10. Platforms: apps vs server-side

- **Apps (Apple platforms):** prefer **SwiftUI** for new UI with value-type state; keep view bodies
  thin and push logic into `@MainActor` models. The whole concurrency contract (§4) applies — UI
  state is main-actor isolated, background work is `async` and `Sendable` at the boundary.
- **Server-side Swift:** **Vapor** is the default mature framework (mature ecosystem, ORM, middleware);
  **Hummingbird** is the lighter, more composable alternative when you want minimal surface. Either
  way, the server is an HTTP service — apply the resilience rules (timeouts, graceful shutdown,
  bounded concurrency) from [resilience.md](../design/resilience.md) and the container/runtime rules
  from [ci-cd.md](../platform/ci-cd.md).
- **Build a static Linux binary for containers** (`swift build -c release --static-swift-stdlib`) and
  ship it on a slim/distroless base — no Swift runtime to install, smaller attack surface. See
  [security.md](../practices/security.md) for the supply-chain side.

## Definition of done

- [ ] `swift build` clean under Swift 6 language mode with complete concurrency checking (no suppressed warnings)
- [ ] `swift format lint --strict` clean; `-warnings-as-errors` in CI
- [ ] No force-unwrap (`!`) / `try!` on a fallible path; errors typed (`enum: Error`, `throws(E)` where it fits)
- [ ] Concurrency: shared mutable state behind an `actor`; boundaries `Sendable`; structured tasks owned; awaits timeout-bounded
- [ ] Models are value types (`struct`/`enum`); classes are `final` unless inheritance is intended
- [ ] Public API marked deliberately + `final`; `swift package diagnose-api-breaking-changes` clean for a library
- [ ] `swift test` green (Swift Testing for new tests; XCTest only for UI/perf); deterministic, no sleeps
- [ ] `Package.resolved` committed; CI resolves locked; dependency tree audited and minimal
- [ ] Server/release artifact builds static for Linux; advisory scan clean (or triaged)
