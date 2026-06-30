---
name: rust-standards
description: Use when writing, reviewing, testing, formatting, or configuring any Rust code (.rs files, Cargo.toml) in a touchstone repo — rustup-pinned toolchain, rustfmt, clippy -D warnings, cargo test/nextest, thiserror/anyhow, tokio. Invoke before adding deps, touching unsafe, editing tests, or changing release/build settings. Not for cross-cutting supply-chain (security-standards) or pipeline (ci-cd-standards) concerns.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Rust Standards

Full standard: **`standards/languages/rust.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **Pin the toolchain** in `rust-toolchain.toml` (exact stable channel + rustfmt/clippy); edition 2024; declare MSRV via `rust-version`.
- Format with **rustfmt** (`cargo fmt --all -- --check`); lint with **clippy** `-D warnings` — configure levels in the `[lints]` table, not just the CI flag.
- Test with **`cargo nextest run`** + **`cargo test --doc`** (nextest skips doctests); property tests via **proptest**, snapshots via **insta**.
- Commit **`Cargo.lock`** (libs too); CI builds `--locked`. Gate deps with **`cargo deny check`** + **`cargo audit`**.

## Don't get burned
- **Errors:** `thiserror` for libraries (typed, `#[non_exhaustive]`), `anyhow` only at the app/`main` boundary. **No `unwrap()`/`expect()` on library happy paths**; propagate with `?` + context.
- **Unsafe:** `unsafe_code = "forbid"` by default; downgrade to `"deny"` only in the crate that needs it, every block gets a `// SAFETY:` comment, and run **`cargo miri test`**.
- **Async (tokio):** never block the executor (offload CPU/blocking I/O via `spawn_blocking`, never `thread::sleep` or sync I/O in `async fn`); bound external awaits with `tokio::time::timeout`; own every `JoinHandle`; don't hold a `std::sync::Mutex` across `.await`.
- **Workspace:** share versions via `[workspace.dependencies]`; split `lib` from `bin`; `default-features = false` and add features back explicitly.
- **Release profile:** `strip`, `lto`, `codegen-units = 1`, `panic = "abort"` (binaries only) — never `panic=abort` on a published lib.
- **Perf:** never optimize without a **criterion** benchmark + a **samply**/flamegraph profile; kill needless `.clone()`.
- Changing deterministic output ⇒ re-accept the `insta` snapshot + explain.

## Done
`cargo fmt --all -- --check` clean · `cargo clippy --all-targets --all-features -- -D warnings` clean · `cargo test --all-features` + `cargo nextest run` green (incl. doctests) · `cargo build --locked` passes, `Cargo.lock` committed, MSRV tested · `cargo deny check` + `cargo audit` clean. See `standards/languages/rust.md`.
