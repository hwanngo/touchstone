# Zig Standards

Applies to any Zig project. Toolchain **pinned to an exact compiler** (Zig has no rustup/nvm —
the binary *is* the version), built with **`build.zig` + `build.zig.zon`**, formatted with
**`zig fmt`**, tested with the built-in **`zig test`** runner under a leak-checking allocator.
Cross-cutting concerns defer to siblings: supply-chain to
[security.md](../practices/security.md), dependency policy to
[dependencies.md](../practices/dependencies.md), test philosophy to
[testing-strategy.md](../practices/testing-strategy.md), and pipelines to
[ci-cd.md](../platform/ci-cd.md).

> **Zig is pre-1.0 and moving.** Every `0.x` release reshapes std and the build API — recent lines
> turned `std.Io` into an interface, reworked `Reader`/`Writer`, and renamed the allocators. **Pin
> one compiler version** (latest stable — verify the current release before adopting), read the
> release notes before bumping, and treat every upgrade as a real migration, not a patch. The rules
> below are stable; the exact symbols are dated — verify against the notes for *your* pinned version.
>
> **One law:** the build is reproducible on the pinned compiler and `zig build test` is green
> with **no leaks**, or it isn't done.

---

## 1. Toolchain & versions

- **Pin the exact compiler.** There is no official version manager, so the *only* source of truth
  is which `zig` binary is on `PATH`. Pin it everywhere it's consumed — a `.zigversion` file (read
  by [zigup](https://github.com/marler8997/zigup)/[zvm](https://github.com/tristanisham/zvm)),
  your CI step, and your container base — so "works on my Zig" can't happen.
- **Declare the floor in `build.zig.zon`** with `minimum_zig_version` so a too-old compiler fails
  fast with a clear message instead of a cryptic std error.
- **Prefer a tagged release over `master`.** Nightly moves daily and breaks without notice; only
  track `master` deliberately, and pin the *exact* nightly hash if you must.
- One entry point: **`zig`** drives build, test, fmt, cc, and cross-compilation — there is no
  separate package manager or test binary to install.

## 2. Everyday commands

```bash
zig version                          # the pinned compiler — print it in CI logs
zig fmt --check .                    # verify formatting, no rewrite (the CI gate)
zig fmt .                            # auto-format in place
zig build                            # compile per build.zig (Debug by default)
zig build test                      # run every test step wired into build.zig (CI gate)
zig build -Doptimize=ReleaseSafe     # release build, safety checks kept (§10)
zig build -Dtarget=aarch64-linux-musl   # cross-compile, zero extra toolchain (§12)
zig fetch --save git+https://github.com/owner/dep#<tag>   # add a dependency + pin its hash
```

`zig fetch --save` is the **only** correct way to add a dependency — it resolves the package, then
writes the URL **and** its content hash into `build.zig.zon`. Never hand-edit the hash.

## 3. Build system (`build.zig` + `build.zig.zon`)

- **`build.zig` is the build — a real Zig program**, not a declarative manifest. It replaces
  Make/CMake; the same file builds your code, your C deps (§11), and every cross-target (§12).
- **`build.zig.zon` is the lockfile-and-manifest in one.** It carries `.name`, `.version`,
  `.fingerprint` (identity — never regenerate it), `.minimum_zig_version`, and `.dependencies` with
  pinned `.hash` values. **Commit it.** A dependency without a hash is not reproducible.
  ```zig
  // build.zig — wire a test step so `zig build test` is the one command CI runs
  const lib_tests = b.addTest(.{ .root_source_file = b.path("src/root.zig"), .target = target });
  const run_tests = b.addRunArtifact(lib_tests);
  b.step("test", "Run unit tests").dependOn(&run_tests.step);
  ```
- **Expose options, not edits.** `b.option(...)` / `b.standardOptimizeOption(...)` /
  `b.standardTargetOptions(...)` so callers pick optimize mode and target on the CLI rather than
  forking the build file. Dependency versions live in `build.zig.zon`; see
  [dependencies.md](../practices/dependencies.md).

## 4. Formatting

- **`zig fmt` is the one formatter** — built in, zero config, no options to argue over. CI runs
  `zig fmt --check .`; a diff is a red build. Formatting never appears in code review.
- Don't hand-align or reach for a third-party formatter — there is exactly one canonical style and
  it ships with the compiler.

## 5. comptime — generics without macros

`comptime` is Zig's headline feature: ordinary Zig code that runs **at compile time**. It replaces
macros, templates, conditional compilation, and most reflection with one mechanism.

- **Generics are functions that take and return `type`.** A "generic" is just a `comptime`
  parameter — no separate template syntax, no macro DSL. The function body is plain Zig you can read.
  ```zig
  fn Stack(comptime T: type) type {
      return struct {
          items: []T,
          len: usize = 0,
          pub fn push(self: *@This(), v: T) void { self.items[self.len] = v; self.len += 1; }
      };
  }
  const IntStack = Stack(i32);   // instantiated at compile time
  ```
- **Reach for `comptime` to specialize, validate, and compute** — branch on `@typeInfo(T)`, reject
  bad types with `@compileError`, precompute tables. But **keep it shallow**: deep comptime is slow
  to compile and hard to read. If a value can be runtime, let it be runtime.
- **No preprocessor, no macros, no hidden codegen.** Configuration is `comptime` constants and
  build options (§3), not `#ifdef`. What you read is what runs.

## 6. Explicit by default — no hidden control flow

Zig's core promise: **no hidden control flow, no hidden allocations, no hidden anything.** Lean on
it and don't smuggle magic back in.

- **No hidden control flow** — no exceptions, no operator overloading, no destructors, no `goto`
  woven behind the scenes. If something runs, it's a call you can see. Cleanup is explicit `defer`
  (§7), not an invisible destructor.
- **No hidden allocations** — std functions that allocate **take an `Allocator` parameter** (§7);
  if a signature has no allocator, it doesn't heap-allocate. Preserve that property in your own
  APIs so callers stay in control of memory.
- **`try`/`catch` and `defer` are visible at the call site** — error propagation is spelled out
  with `try`, never thrown past you silently. A reader sees every exit.

## 7. Memory management & allocators

- **Pass an `Allocator`; never allocate globally.** Library code accepts `allocator: std.mem.Allocator`
  and uses it for every allocation — the caller chooses arena, page, GPA, or a fixed buffer. A
  function that hard-codes its allocator is unusable in someone else's memory regime.
- **`defer` to release, `errdefer` to unwind on error.** Pair every acquire with its release on the
  next line so it can't drift; `errdefer` frees only when the function returns an error (the success
  path keeps the resource).
  ```zig
  const buf = try allocator.alloc(u8, n);
  errdefer allocator.free(buf);     // freed only if a later `try` fails
  try fill(buf);
  return buf;                       // success: ownership passes to the caller
  ```
- **Detect leaks in tests with `std.testing.allocator`** — it fails any test that leaks, turning
  ownership bugs into red builds. For binaries, run on the **`DebugAllocator`** (formerly
  `GeneralPurposeAllocator`) in Debug/ReleaseSafe: it catches leaks, double-frees, and
  use-after-free. _(scale-up)_ Swap to a faster backing allocator only after profiling (§10).
- **Match every `alloc`/`create` with exactly one `free`/`destroy`**, and document who owns a
  returned pointer. An **arena** (`std.heap.ArenaAllocator`) is the clean answer for
  request-scoped/phase-scoped lifetimes — free the whole arena once instead of tracking each item.

## 8. Error handling

- **Errors are values in an error union (`!T`)** — a typed error set the compiler tracks, not
  exceptions. Define narrow error sets and let inference (`!T`) widen them; never paper over an
  error with `catch unreachable` unless it is *genuinely* impossible.
  ```zig
  const ParseError = error{ Empty, TooLong };
  fn parse(s: []const u8) ParseError!u32 { … }
  ```
- **Propagate with `try`, handle with `catch`.** `try expr` returns the error to the caller;
  `catch` provides a fallback or maps the error. Handle or propagate every error — the compiler
  won't let you silently drop one, so don't defeat it with a blind `catch {}`.
- **`errdefer` for cleanup on the error path** (§7) — the idiom that makes value-based errors as
  safe as RAII without hidden destructors.
- **Reserve panics for true invariant violations.** A library returns errors; it doesn't
  `@panic`/`unreachable` on bad input. `unreachable` is a *safety-checked* assertion in
  Debug/ReleaseSafe — use it to state an invariant, not to skip error handling.

## 9. Testing

- **Tests live in `test "name" { … }` blocks beside the code** — no separate framework, no
  annotations. The build runs them; co-locating them with the code keeps them honest.
  ```zig
  test "parse rejects empty input" {
      try std.testing.expectError(error.Empty, parse(""));
  }
  ```
- **Use `std.testing.allocator` in every test that allocates** (§7) so leaks fail the test.
  Assert with `std.testing.expect`, `expectEqual`, `expectError`, and `expectEqualStrings`.
- **Wire a `test` step in `build.zig`** so `zig build test` runs the whole suite — that single
  command is the CI gate. Keep tests deterministic (no wall-clock, no network). See
  [testing-strategy.md](../practices/testing-strategy.md) for the unit/integration split.
- _(scale-up)_ Run the built-in **fuzzer** (`zig build test --fuzz`) against parsers and decoders;
  a crashing input becomes a permanent regression case.

## 10. Release modes & safety

Zig makes the safety/speed trade-off an explicit build choice — pick it per build, never by luck.

| Mode | Safety checks | Optimization | Use it for |
|---|---|---|---|
| **Debug** (default) | all on | none | local dev, fast compiles |
| **ReleaseSafe** | all on | yes | **the default for shipping services** — UB caught, still fast |
| **ReleaseFast** | **off** | max speed | hot paths, *after* profiling proves the need |
| **ReleaseSmall** | **off** | min size | embedded / size-constrained targets |

- **Ship `ReleaseSafe` unless you've measured otherwise.** It keeps bounds/overflow/null checks
  (illegal behavior traps instead of corrupting memory) at near-`ReleaseFast` speed — dropping
  safety must be a deliberate, profiled decision, not the default reflex.
- **`ReleaseFast`/`ReleaseSmall` disable safety checks**, so integer overflow, out-of-bounds, and
  `unreachable` become real UB. Confine them to the specific binary/hot path that needs them, and
  keep that code covered by tests run under ReleaseSafe.
- **Never optimize without a profile** — build `ReleaseFast`, measure the real hot path, change one
  thing, re-measure. Guesswork-driven micro-optimization is how readable code dies for no gain.

## 11. C interop

- **`@cImport` pulls C headers straight into Zig** — no bindings generator, no FFI boilerplate.
  Declare the include in `build.zig` (`addIncludePath`, `linkLibC`) and call C functions directly.
  ```zig
  const c = @cImport(@cInclude("sqlite3.h"));   // C symbols available as c.sqlite3_open(...)
  ```
- **Zig builds C and C++ too** — `addCSourceFiles`/`linkLibrary` in `build.zig` compiles C deps
  with the same cross-compiling toolchain (§12), so **`zig build` can replace** a project's
  Make/CMake/autotools entirely and cross-compile the C with it for free.
- **C interop crosses the safety boundary** — C pointers are unchecked and C allocations escape
  Zig's allocator model (§7). Wrap C APIs in a thin Zig layer that validates inputs, owns the
  lifetimes, and surfaces failures as Zig errors (§8). FFI hardening defers to
  [security.md](../practices/security.md).

## 12. Cross-compilation

- **Cross-compilation is Zig's superpower — it's the default, not a plugin.** The compiler ships
  with the std/libc sources for every supported target, so any host builds any target with no
  cross-toolchain, no sysroot, no `apt install gcc-aarch64`:
  ```bash
  zig build -Dtarget=aarch64-macos          # from x86 Linux, no extra tooling
  zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe   # static musl binary
  ```
- **`zig cc` is a drop-in cross-compiling C compiler** — point `CC="zig cc -target …"` at another
  project's build to cross-compile *its* C without a toolchain. This is half of why Zig shows up in
  non-Zig pipelines.
- **Target a static musl triple for containers** (`x86_64-linux-musl`) to get a dependency-free
  binary for a `FROM scratch`/distroless image; see [docker.md](../platform/docker.md) for the
  container side. Make `-Dtarget`/`-Doptimize` build options (§3) so CI builds every artifact from
  one `build.zig`.

## 13. Dependencies & supply chain

- **`build.zig.zon` is the lockfile — commit it, and every dependency carries a pinned `.hash`**
  (§3). `zig fetch --save` writes the URL *and* the content hash; that hash *is* the supply-chain
  guarantee — `zig build` verifies it, so a swapped or tampered artifact fails the fetch. Never
  hand-edit a hash.
- **There is no mature vulnerability-audit tool yet** — Zig has no `cargo audit`/`pip-audit`
  equivalent (an advisory DB and scanner are only emerging). Compensate: keep the dependency set
  **small and reviewed**, pin exact tags/hashes, and read the diff on every bump.
- **Stay current** — track each dependency's upstream releases and bump deliberately (every `0.x`
  bump can be a real migration; §1) rather than letting a pinned hash quietly rot.
- **The cross-cutting policy** — update cadence/cooldown, SBOM, signing/provenance — lives in
  [dependencies.md](../practices/dependencies.md) and [security.md](../practices/security.md); this
  doc doesn't restate it.

## Definition of done

- [ ] Built on the **pinned** Zig version (`.zigversion` + CI), `minimum_zig_version` set in `build.zig.zon`
- [ ] `zig fmt --check .` clean
- [ ] `zig build` and `zig build test` green; tests use `std.testing.allocator` and report **no leaks**
- [ ] `build.zig.zon` committed; every dependency added via `zig fetch --save` with a pinned hash; deps kept minimal + reviewed (no mature vuln-audit tool yet)
- [ ] Generics/specialization via `comptime`; no preprocessor, no hidden codegen
- [ ] Library functions take an `Allocator`; every `alloc`/`create` paired with `free`/`destroy`; `errdefer` on error paths
- [ ] Errors are values (`!T`); propagated with `try` or handled with `catch` — none silently dropped; no `@panic`/`unreachable` on bad input
- [ ] Ships **ReleaseSafe** unless a profiled hot path justifies ReleaseFast/Small; that code stays test-covered
- [ ] C boundaries (`@cImport`/`zig cc`) wrapped in a validating Zig layer that owns lifetimes
- [ ] Cross-compiled artifact builds from one `build.zig` via `-Dtarget`/`-Doptimize`

**Sources:** [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html) · [Zig Language Reference](https://ziglang.org/documentation/master/) · [Zig Build System](https://ziglang.org/learn/build-system/)
