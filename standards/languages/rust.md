# Rust Standards

Applies to any Rust project. Toolchain pinned with **rustup** + `rust-toolchain.toml`, formatted
with **rustfmt**, linted with **clippy** (`-D warnings`), tested with **cargo test** + **nextest**,
async on **tokio**. Cross-cutting concerns defer to siblings: supply-chain to
[security.md](../practices/security.md), dependency policy to [dependencies.md](../practices/dependencies.md),
test philosophy to [testing-strategy.md](../practices/testing-strategy.md), timeouts/cancellation to
[resilience.md](../design/resilience.md), and pipelines to [ci-cd.md](../platform/ci-cd.md).

> **One law:** the build is reproducible and `clippy -D warnings` clean, or it isn't done.

---

## 1. Toolchain & versions

- **Pin the toolchain in `rust-toolchain.toml`** (committed) so every dev and CI uses the same
  compiler — no "works on my rustc". rustup auto-installs it on first `cargo` invocation.
  ```toml
  [toolchain]
  channel    = "1.85.0"              # an exact stable (e.g. — verify the current release), never "stable"
  components = ["rustfmt", "clippy"] # so CI never has to add them
  profile    = "minimal"
  ```
- **Edition 2024** (stable since Rust 1.85) for new crates; set `edition = "2024"` in `Cargo.toml`.
  It selects **resolver 3** (the MSRV-aware dependency resolver) by default.
- **Declare an MSRV** with `rust-version` in `Cargo.toml` and actually test it (§9). The pinned
  toolchain is what you *build* with; `rust-version` is the floor you *support*.
- One job per tool: **cargo** is the only entry point — never invoke `rustc` directly.

## 2. Everyday commands

```bash
cargo fmt --all                                   # auto-format
cargo fmt --all -- --check                        # verify formatting (what CI runs)
cargo clippy --all-targets --all-features -- -D warnings   # lint, warnings are errors (CI gate)
cargo test --all-features                          # unit + integration + doctests
cargo nextest run --all-features                   # faster test runner (no doctests — see §5)
cargo build --locked --release                     # release build, fail if Cargo.lock is stale
cargo deny check                                   # licenses, bans, advisories, sources
cargo audit                                        # RUSTSEC advisory scan of Cargo.lock
```

Add a dependency with `cargo add <crate>` (it edits `Cargo.toml` **and** resolves `Cargo.lock`) —
commit both. Use `cargo add --dev` for dev-deps and `-F <feat>` to enable features explicitly.

## 3. Formatting & linting

- **Formatting is automated and non-negotiable.** `cargo fmt`; never hand-align. Keep a minimal
  `rustfmt.toml` and let defaults rule — CI runs `cargo fmt --all -- --check`; a diff is a red build.
- **clippy with `-D warnings`** is the gate — a warning that isn't an error gets ignored forever.
  Configure lint levels in the `[lints]` table (stable since 1.74) so they apply to every
  invocation, not just the CI flag:
  ```toml
  # Cargo.toml
  [lints.rust]
  unsafe_code = "forbid"          # see §6; downgrade to "deny" only if you genuinely need unsafe
  missing_debug_implementations = "warn"

  [lints.clippy]
  all      = { level = "deny",  priority = -1 }   # correctness + suspicious + complexity + perf + style
  pedantic = { level = "warn",  priority = -1 }   # opt in, then allow the few that don't fit
  unwrap_used = "deny"            # libs: no unwrap/expect on the happy path (§4)
  expect_used = "warn"
  ```
  Highlights: clippy `all` catches real bug classes (`needless_collect`, `await_holding_lock`,
  redundant clones); `pedantic` is worth the noise once you allow the handful that don't fit. Fix
  findings — annotate a deliberate exception with `#[allow(clippy::lint, reason = "…")]`, never a
  blanket crate-level allow.

## 4. Error handling

- **`Result<T, E>` everywhere; no `unwrap()`/`expect()` in library code** — they panic, and a
  library has no business aborting the caller's process. Reserve `expect("invariant")` for a
  genuinely-unreachable state, with the message naming the invariant.
- **Libraries: `thiserror`** — a typed, `#[non_exhaustive]` enum so callers can `match` and you can
  add variants without a breaking change. Implement `std::error::Error` via the derive; wrap the
  source with `#[from]`/`#[source]` to preserve the chain.
  ```rust
  #[derive(thiserror::Error, Debug)]
  #[non_exhaustive]
  pub enum StoreError {
      #[error("user {0} not found")]
      NotFound(UserId),
      #[error("database")]
      Db(#[from] sqlx::Error),   // preserves the source chain
  }
  ```
- **Applications: `anyhow`** — `anyhow::Result<()>` at the binary boundary, `.context("…")` to add a
  human trail. `anyhow` belongs in `main`/handlers, **never in a library's public API**.
- **Propagate with `?`**; add context at each layer rather than re-stringifying. Never swallow an
  error into `let _ =` on a fallible path — handle it, return it, or log-and-continue *deliberately*.

## 5. Testing

- **Unit tests** live in a `#[cfg(test)] mod tests` beside the code (they can reach private items);
  **integration tests** in `tests/` exercise only the public API. See
  [testing-strategy.md](../practices/testing-strategy.md) for the unit/integration split.
- **Run tests with `cargo nextest`** — faster, per-test isolation, clearer output. Keep
  **`cargo test --doc`** in CI too: nextest does **not** run doctests, and doctests are how your
  public examples stay compilable.
- **Doctests are documentation that can't rot** — every public API example in `///` docs compiles
  and runs under `cargo test`. Use `#![doc = include_str!("../README.md")]` so the README is tested.
- **Property tests with `proptest`** for parsers, encoders, and invariants — generate inputs instead
  of hand-picking them; a failing case auto-shrinks to a minimal reproducer that becomes a regression.
  ```rust
  proptest! {
      #[test]
      fn roundtrip(s in ".*") { prop_assert_eq!(decode(&encode(&s)), s); }
  }
  ```
- **Snapshot tests with `insta`** for deterministic structured output; review with `cargo insta
  review`, commit the `.snap`. Changing output on purpose ⇒ re-accept the snapshot *in the same PR*.
- Write the test first for new behaviour and bugfixes (TDD); keep tests deterministic — no
  wall-clock or network. _(scale-up)_ Wire **`cargo llvm-cov`** with a coverage floor that ratchets up.

## 6. Unsafe code

- **`unsafe_code = "forbid"` at the crate root by default** (§3) — most crates never need `unsafe`,
  and forbidding it is a one-line guarantee reviewers can trust. Downgrade to `"deny"` only in the
  specific crate that genuinely needs it (FFI, a vetted data-structure), never workspace-wide.
- **Every `unsafe` block carries a `// SAFETY:` comment** stating the invariant that makes it sound;
  clippy `undocumented_unsafe_blocks` enforces it. An `unsafe` block without a SAFETY note fails review.
- **Run `cargo miri test`** on any crate with `unsafe`/FFI — Miri catches UB (use-after-free,
  out-of-bounds, data races, invalid aliasing) that normal tests sail past. _(scale-up)_ Run Miri
  in CI for the unsafe crates; pair with **`-Z sanitizer=address`** under nightly for FFI boundaries.

## 7. Async (tokio)

The default async runtime is **tokio** (multi-threaded). Pick one runtime per binary and commit to
it; don't mix tokio and async-std in one process. Timeouts and cancellation here are the async face
of the resilience rules in [resilience.md](../design/resilience.md).

- **Never block the executor** — no `std::thread::sleep`, sync `std::fs`, or CPU-bound loops inside
  an `async fn`. The worker thread can't poll other tasks while you block it. Offload to a blocking
  pool; clippy `await_holding_lock` flags a `std::sync::Mutex` held across `.await`.
  ```rust
  let out = tokio::task::spawn_blocking(move || expensive_cpu(input)).await?;   // CPU/blocking I/O
  tokio::time::sleep(Duration::from_secs(1)).await;                              // not thread::sleep
  ```
- **Bound every external await with `tokio::time::timeout`** — an un-timed `await` on a network/DB
  op hangs a task forever:
  ```rust
  let resp = tokio::time::timeout(Duration::from_secs(5), client.get(url).send()).await??;
  ```
- **Own every spawned task.** `tokio::spawn` returns a `JoinHandle` — keep it, or supervise tasks
  with a `JoinSet`. A dropped handle detaches the task: it leaks and its panic vanishes.
- **Cancellation is cooperative** — propagate a `CancellationToken` (or `select!` on a shutdown
  signal) and check it at await points so tasks unwind on shutdown instead of being killed mid-write.
- **Hold a `Mutex` across `.await`?** Use `tokio::sync::Mutex`; otherwise prefer `std::sync::Mutex`
  for short, non-async critical sections (it's faster). Don't reach for the async mutex by reflex.

## 8. Project layout & dependencies

- **Cargo workspace for multi-crate repos**: a root `[workspace]` with **`[workspace.dependencies]`**
  so versions and features are declared once and inherited (`foo = { workspace = true }`). A virtual
  manifest (no root `[package]`) keeps the root a pure aggregator. Split a `lib` crate from its `bin`
  so the logic is testable and reusable.
- **Commit `Cargo.lock`** — for binaries *and* libraries (the modern guidance): it pins what CI
  tests. CI builds with `--locked` so a stale lockfile fails instead of silently re-resolving.
- **`cargo deny` is the dependency gate** (`advisories` + `bans` + `licenses` + `sources`) — it
  catches duplicate versions, banned/yanked crates, and disallowed licenses in one pass. Pair with
  **`cargo audit`** for the RUSTSEC feed. Both run in CI. Policy lives in
  [dependencies.md](../practices/dependencies.md); supply-chain (SBOM, provenance) in
  [security.md](../practices/security.md).
  ```toml
  # deny.toml
  [advisories]   # default: deny known vulns
  [bans]
  multiple-versions = "warn"
  [licenses]
  allow = ["MIT", "Apache-2.0", "BSD-3-Clause", "Unicode-3.0"]
  ```
- **Keep the dependency tree lean** — audit with `cargo tree -d` (duplicate versions bloat builds)
  and enable only the features you use (`default-features = false`, add back explicitly).
- _(scale-up)_ **`cargo vet`** to record audits of third-party crates and gate unaudited additions.

## 9. Build, release & CI

- **CI runs `--locked`** on every cargo command so a drifted lockfile fails fast. Cache `~/.cargo`
  and `target/` (e.g. `Swatinem/rust-cache`) to keep the pipeline quick. See
  [ci-cd.md](../platform/ci-cd.md).
- **Test the MSRV** — a job pinned to `rust-version` (via `cargo +<msrv>` or a matrix entry) so the
  floor you advertise actually builds. Bumping MSRV is a SemVer-minor event; do it deliberately.
- **Release builds are optimized and stripped** — set it in the profile, not ad-hoc flags:
  ```toml
  [profile.release]
  strip = "symbols"   # smaller binary; drop debug symbols
  lto = "thin"        # cross-crate inlining; "fat" if you can afford the link time
  codegen-units = 1   # better optimization, slower compile — release only
  panic = "abort"     # binaries only: smaller + faster; never for a published lib
  ```
- **Cross-compile with `cross`** (zero host toolchain fuss) for release artifacts; produce a static
  binary against **musl** (`x86_64-unknown-linux-musl`) for a `FROM scratch`/distroless image. See
  [docker.md](../platform/docker.md) for the container side.
- _(scale-up)_ **`cargo-dist`** to build, package, sign, and publish multi-platform release artifacts
  from CI in one config.

## 10. Performance

- **Never optimize without a profile.** Benchmark with **criterion** (statistical, regression-aware)
  — it warns when a change regresses a benchmark, turning perf into a CI signal:
  ```rust
  fn bench(c: &mut Criterion) { c.bench_function("parse", |b| b.iter(|| parse(black_box(INPUT)))); }
  ```
  Wrap inputs in `std::hint::black_box` so the optimizer can't fold the benchmark away.
- **Profile the real hot path** — **`samply`** (cross-platform, Firefox Profiler UI) or
  `cargo flamegraph`; optimize the function the profiler names, then re-measure. Guesswork-driven
  micro-optimization is how readable code dies for no measured gain.
- **Reach for the right type before `unsafe`** — avoid needless `.clone()` (clippy flags many),
  prefer borrows and `&str`/`&[T]` over owned copies, and pick the data structure that fits. A
  `Vec` with `with_capacity` beats a clever pointer trick almost every time.

## Definition of done

- [ ] `cargo fmt --all -- --check` clean
- [ ] `cargo clippy --all-targets --all-features -- -D warnings` clean
- [ ] `cargo test --all-features` green (incl. doctests); `cargo nextest run` green
- [ ] No `unwrap()`/`expect()` on library happy paths; errors typed (`thiserror`) / `anyhow` only at the app boundary
- [ ] `unsafe` forbidden, or every block has a `// SAFETY:` comment and `cargo miri test` passes
- [ ] Async: no blocking in `async fn` (offload via `spawn_blocking`); awaits timeout-bounded; tasks owned
- [ ] `cargo build --locked` passes; `Cargo.lock` committed; MSRV (`rust-version`) tested in CI
- [ ] `cargo deny check` and `cargo audit` clean (or advisories triaged)
- [ ] Release profile stripped + optimized; cross-compiled artifact builds
- [ ] Any deterministic-output change ships with a re-accepted `insta` snapshot + rationale
