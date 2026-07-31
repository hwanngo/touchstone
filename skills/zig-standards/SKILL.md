---
name: zig-standards
description: Use when writing, reviewing, testing, formatting, or configuring any Zig code (.zig files, build.zig, build.zig.zon) in a touchstone repo — exact-version-pinned compiler (Zig is pre-1.0 and moving), zig fmt, zig build/test, comptime generics, explicit allocators, error unions, cross-compilation. Invoke before adding deps, touching memory/allocators, choosing a release mode, or wiring C interop. Not for cross-cutting supply-chain (security-standards) or pipeline (ci-cd-standards) concerns.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Zig Standards

Full standard: **`standards/languages/zig.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **Pin the exact compiler** — Zig is pre-1.0; there's no rustup/nvm, the binary *is* the version. Commit a `.zigversion`, pin it in CI, set `minimum_zig_version` in `build.zig.zon`, and treat every bump as a real migration (std + build API churn each release).
- Format with **`zig fmt --check .`** (one canonical style, no config); build and test with **`zig build`** + **`zig build test`** wired as steps in `build.zig`.
- Add dependencies only via **`zig fetch --save`** (writes URL + pinned content hash into `build.zig.zon`); commit `build.zig.zon`. Never hand-edit a hash.
- **Generics are `comptime` functions returning `type`** — no macros, no preprocessor, no hidden codegen.

## Don't get burned
- **Memory:** library functions take an `Allocator` param (no hidden/global allocation); pair every `alloc`/`create` with one `free`/`destroy`; `defer` to release, **`errdefer`** to unwind on the error path. An **arena** for request-scoped lifetimes.
- **Leaks are test failures:** use **`std.testing.allocator`** in every test that allocates; run binaries on the `DebugAllocator` (formerly `GeneralPurposeAllocator`) in Debug/ReleaseSafe to catch leaks/double-free/use-after-free.
- **Errors are values (`!T`):** propagate with `try`, handle with `catch` — never a blind `catch {}` or `catch unreachable`; no `@panic`/`unreachable` on bad input (that's for stating invariants).
- **No hidden control flow:** no exceptions, no destructors, no operator overloading — what you read is what runs; keep that property in your own APIs.
- **Release modes are a deliberate choice:** ship **ReleaseSafe** (checks on, near-Fast speed) unless a *profiled* hot path justifies **ReleaseFast/Small**, which disable safety checks and make overflow/OOB real UB.
- **C interop crosses the safety boundary:** `@cImport`/`zig cc` give zero-boilerplate C builds (Zig can replace Make/CMake and cross-compile C for free), but wrap C APIs in a validating Zig layer that owns lifetimes.
- **Cross-compilation is the default superpower:** `zig build -Dtarget=…` builds any target from any host with no cross-toolchain; target static `*-linux-musl` for distroless containers.

## Done
`zig fmt --check .` clean · `zig build` + `zig build test` green with **no leaks** (`std.testing.allocator`) · built on the pinned version with `minimum_zig_version` set · `build.zig.zon` committed, deps added via `zig fetch --save` · library funcs take an `Allocator`, errors propagated/handled (none dropped) · ships ReleaseSafe unless a profiled hot path says otherwise. See `standards/languages/zig.md`.
