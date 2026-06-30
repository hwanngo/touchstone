---
name: axum-standards
description: Use when building an Axum (or Actix-web) async Rust web service in a touchstone repo — routing, extractors, Tower middleware, IntoResponse errors, state/DI, graceful shutdown. Triggers on `axum`/`actix-web` in Cargo.toml, `Router`/`async fn` HTTP handlers, `State`/`Json`/`Path` extractors. Rust-language rules (toolchain, clippy, thiserror, tokio depth) live in the rust skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Axum (Rust Backend framework)

Full standard: **`standards/frameworks/axum.md`** (layers on `standards/languages/rust.md`). This
skill inlines the load-bearing rules so it stays useful when installed standalone in
`~/.claude/skills/`:

## Always
- **Axum 0.8 is the default** (on Tokio/Tower/Hyper); Actix-web is the measured escape hatch. Path
  syntax is **`/{id}`**, not 0.7's `/:id`.
- **handler → service → repository** layering; thin handlers delegate and return `Result<T, AppError>`
  via `?`. Split `lib` from `bin`.
- **`State<AppState>`** is the DI container — cheap-Clone behind `Arc`/pools, built once in `main`, no
  static singletons; sub-states via `FromRef`.
- **Typed extractors** (`Path`/`Query`/`Json`); at most one body extractor and it goes **last**;
  route rejections through `AppError`.
- **Validate every boundary** (`garde`/`validator`) in a shared extractor before the service runs.

## Don't get burned
- **Errors:** one `AppError` implementing `IntoResponse` (thiserror), maps source → status in one
  place → problem+json. **No `unwrap()`/`expect()` in handlers** (see rust skill §4); never leak a
  `sqlx::Error` or stack trace to the client.
- **Middleware:** compose with `ServiceBuilder` — **top-to-bottom = outermost-to-innermost**.
  `TraceLayer` outermost, then CORS (explicit allow-list, never `Any` in prod) + body-limit +
  `TimeoutLayer`, auth innermost.
- **Async:** all rust-skill tokio rules apply — never block the executor, bound awaits with
  `tokio::time::timeout`, make handler work cancel-safe (the client disconnecting drops the future).
- **Shutdown:** `axum::serve(...).with_graceful_shutdown(signal)` on `SIGTERM` **and** Ctrl-C; close
  the pool after drain; bound by the request timeout.
- **DB:** `sqlx` compile-checked queries in the repository (SeaORM only at scale); migrations at
  deploy, not on first request.

## Done
Handler → service → repo · typed extractors (body last) · one `AppError: IntoResponse`, no `unwrap` in handlers · `ServiceBuilder` ordering (Trace outer, auth inner) + explicit CORS · `with_graceful_shutdown` on SIGTERM+Ctrl-C · `oneshot` handler tests + Testcontainers for DB. See `standards/frameworks/axum.md`.
