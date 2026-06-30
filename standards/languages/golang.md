# Go Standards

Applies to any Go project. Formatted with **gofumpt + goimports**, linted with
**golangci-lint v2**, tested with stdlib **`testing` + go-cmp** under `-race`, and shipped as a
static binary on a **distroless** image.

---

## 1. Toolchain & versions

- **Pin the Go version with both directives** in `go.mod` (versions below are illustrative — pin
  your current toolchain): `go 1.24.0` (minimum language version you support) and
  `toolchain go1.24.4` (exact compiler everyone/CI builds with).
  ```bash
  go get go@1.24.0 toolchain@go1.24.4   # e.g. — verify the current release
  ```
- In CI set `GOTOOLCHAIN=local` (forbid surprise toolchain downloads) and use
  `actions/setup-go` with `go-version-file: go.mod`.
- Default to the **module cache** (`go.sum` + `-mod=readonly` gives reproducibility); reach for
  `go mod vendor` only for air-gapped/audited builds. `go work` is for local multi-module dev —
  **gitignore `go.work`**, never commit it.

## 2. Everyday commands

```bash
go build -mod=readonly ./...                       # build (don't auto-edit go.mod)
go test -race -covermode=atomic ./...              # test with the race detector
gofumpt -l -w . && goimports -local <module> -w .  # format
golangci-lint run                                  # lint
govulncheck ./...                                  # vuln scan
go mod tidy && git diff --exit-code go.mod go.sum  # deps match imports (CI gate)
```

## 3. Formatting

- **gofumpt** (stricter, deterministic superset of gofmt) + **goimports** (manages import
  grouping/add/remove). Mandate both; enforce in CI (`golangci-lint fmt --diff` fails on drift).
  Style never appears in code review.

## 4. Linting (golangci-lint v2)

One meta-linter, one config, one CI step. v2 requires `version: "2"` and a `linters.default`
key. Baseline `.golangci.yml`:
```yaml
version: "2"
run: { timeout: 5m }
linters:
  default: standard          # govet, staticcheck, errcheck, ineffassign, unused
  enable: [revive, gosec, gocritic, unparam, bodyclose, errorlint, errname,
           nilerr, unconvert, perfsprint, copyloopvar, nolintlint]
  settings:
    errcheck: { check-type-assertions: true }
    govet: { enable-all: true, disable: [fieldalignment] }   # fieldalignment is opt-in/noisy
  exclusions:
    presets: [comments, common-false-positives, std-error-handling]
    rules: [{ path: _test\.go, linters: [gosec, unparam, bodyclose] }]
formatters:
  enable: [gofumpt, goimports]
```
The `standard` set is non-negotiable; `gosec`/`bodyclose`/`errorlint` catch security,
resource-leak, and error-wrapping bugs `go vet` misses. CI: `golangci/golangci-lint-action`
pinned to a `v2.x`.

## 5. Testing

- **Table-driven tests + subtests** (`t.Run`) are the idiom — a new case is one struct literal;
  subtests give `-run` filtering and per-case reporting. Call `t.Parallel()` in independent
  subtests.
- **Stdlib `testing` + `google/go-cmp`** — not testify. `cmp.Diff(want, got)` gives clear
  diffs and avoids arg-order traps. (Tolerate `testify/require` only where a team already
  standardized on it.)
- **Always `go test -race`** in CI (`-covermode=atomic` with it). Data races are invisible to
  review and nondeterministic; treat any race report as a failing build.
- **Coverage as a floor**, not a target — compute `go tool cover` and fail under a threshold.
- `t.Helper()` (failures report the caller) and `t.Cleanup()` (LIFO teardown, correct under
  `t.Parallel()`) over manual `defer` plumbing. `testing.Short()` splits fast/slow suites.
- **Fuzz untrusted-input boundaries** (`go test -fuzz`) — parsers/decoders; the minimized
  corpus becomes permanent regression tests. Golden files for deterministic output.

## 6. Errors

- **Wrap with `%w`** to preserve the chain; match with `errors.Is` (sentinels) / `errors.As`
  (typed) / `errors.Join` (aggregate). Use `%v` to deliberately *hide* an internal error from
  your public API.
  ```go
  return fmt.Errorf("new store: %w", err)
  if errors.Is(err, ErrNotFound) { … }
  ```
- Error strings: lowercase, no trailing punctuation. Sentinels `ErrX`; typed `XError`.
- **No `panic` in libraries** — return `error` values; reserve panic for unrecoverable init.
  Never discard errors with `_`. Handle the error first, keep the happy path un-indented.

## 7. Context & concurrency

- **`context.Context` is the first parameter** (named `ctx`) of any request-scoped/cancellable
  function. **Never store a context in a struct.** Always `defer cancel()`, even on success.
- **Every goroutine needs an owned exit path** (`ctx.Done()`, a closed channel, or a buffer so
  the send can't block) — a leaked goroutine never gets GC'd.
- Use **`errgroup`** for bounded parallel work (`SetLimit(n)`, first-error propagation, shared
  ctx cancel) instead of hand-rolled `WaitGroup` + error channel.
- "Share memory by communicating": channels for handoff/pipelines, `sync.Mutex` for simple
  shared state, `sync.OnceValue` for lazy init.

## 8. HTTP servers (`net/http`)

- **ALWAYS set `http.Server` timeouts.** The zero-value server has none — a single slow client
  holding a connection open (Slowloris) is an uncapped DoS. Minimum: `ReadHeaderTimeout`,
  `ReadTimeout`, `WriteTimeout`, `IdleTimeout`.
- **Stdlib `http.ServeMux` (1.22+) — no third-party router for most services.** It now does
  method + wildcard routing (`GET /users/{id}`, `{path...}`); `r.PathValue("id")` reads the
  segment. Reach for chi/gin only under real routing pressure, not by reflex.
- **Graceful shutdown** via `signal.NotifyContext` + `srv.Shutdown(ctx)` (drains in-flight
  requests, stops accepting new ones). **Middleware is `func(http.Handler) http.Handler`**;
  **propagate `r.Context()`** into every downstream call (DB, RPC) so client cancel/timeout
  flows through. See [resilience.md](../design/resilience.md), [api-design.md](../design/api-design.md).

  ```go
  srv := &http.Server{
      Addr:              ":8080",
      Handler:           mux,                    // your http.ServeMux, wrapped in middleware
      ReadHeaderTimeout: 5 * time.Second,        // the Slowloris guard — never omit
      ReadTimeout:       15 * time.Second,
      WriteTimeout:      15 * time.Second,
      IdleTimeout:       60 * time.Second,
  }
  ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
  defer stop()
  go func() {
      if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
          slog.Error("server", "err", err); os.Exit(1)
      }
  }()
  <-ctx.Done()                                   // signal received
  sdCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
  defer cancel()
  _ = srv.Shutdown(sdCtx)                         // drain in-flight, then exit
  ```

## 9. JSON (`encoding/json`)

- **Mandatory `json:"..."` tags** on every serialized struct — never ship default
  field-name-derived keys; the wire contract must be explicit and stable.
- **`omitempty` deliberately.** It can't express *present-but-zero* (a real `0`/`""`/`false`
  vanishes). For null-vs-absent use a **pointer** (`*int`) or **`omitzero` (1.24+)**, which keys
  off the Go zero value / an `IsZero()` method (and correctly omits a zero `time.Time`, which
  `omitempty` does not). Rule of thumb: `omitempty` for maps/slices, `omitzero` for everything else.
- **`json:"-"`** on secrets/internal fields so they can't leak through a generic encode.
- **At trust boundaries**, `dec := json.NewDecoder(r.Body); dec.DisallowUnknownFields()` to reject
  unexpected keys, then **validate after decode** — decoding success ≠ valid input.

  ```go
  type CreateUser struct {
      Email string  `json:"email"`
      Name  string  `json:"name,omitempty"`
      Age   *int    `json:"age,omitzero"`  // distinguishes "absent" from 0
      _     string  `json:"-"`             // never serialized
  }
  ```

## 10. `database/sql` & config

- **Always pass `ctx`:** `QueryContext`/`ExecContext`/`QueryRowContext` — never the
  context-free variants. **Parameterized queries only** (`$1`/`?`); never string-concat input.
- **Configure the pool** — the zero-value pool is *unbounded* and will exhaust the DB:
  `SetMaxOpenConns`, `SetMaxIdleConns`, `SetConnMaxLifetime` (rotate conns so the pool follows
  failovers/DNS). **`defer rows.Close()` AND check `rows.Err()`** after the iteration loop —
  a row-iteration error surfaces nowhere else.
- **Prefer [pgx](https://github.com/jackc/pgx) for Postgres** (native protocol, real types, far
  faster than the `lib/pq` `database/sql` path). See [database.md](../platform/database.md).
- **Config: one typed struct loaded from env at startup, fail-fast** on missing/invalid values.
  No `init()`-time `os.Getenv` (untestable, ordering-dependent, hidden failures).

  ```go
  db.SetMaxOpenConns(25); db.SetMaxIdleConns(25); db.SetConnMaxLifetime(5 * time.Minute)
  rows, err := db.QueryContext(ctx, `SELECT id, email FROM users WHERE org = $1`, orgID)
  if err != nil { return err }
  defer rows.Close()
  for rows.Next() { /* rows.Scan(...) */ }
  return rows.Err()   // don't skip this
  ```

## 11. Project layout & API design

- **Flat by default.** Start as one package in the module root; add structure only under real
  pressure (refactoring later is cheap). **Reject `golang-standards/project-layout` and
  `pkg/`** — they add import segments for no benefit (Russ Cox, issue #117).
- Multiple binaries → `cmd/<name>/main.go`. Private code → **`internal/`** (compiler-enforced).
  Never name a package `util`/`common`/`shared`/`helper`.
- **Accept interfaces, return structs.** Keep interfaces small and **defined in the consumer**
  (the `io.Reader` model) — trivial to mock, no premature abstraction. Design types so the
  **zero value is useful** (`bytes.Buffer`, `sync.Mutex`). Use **functional options** for
  constructors that will grow.

## 12. Generics

- **Default to concrete types + interfaces.** Reach for generics only for genuinely
  type-parametric **containers/algorithms** — the `slices`/`maps` helpers, `cmp.Ordered`
  comparisons, a real generic cache/set. Don't add a type parameter to avoid writing two methods.
- **Constrain tightly** — never `any` when a narrower constraint fits (`cmp.Ordered`,
  `constraints.Integer`, a small interface). A loose constraint discards the compiler's help.
- **No unused type parameters** (if `T` isn't load-bearing, it shouldn't exist). Prefer
  inference at call sites over explicit `[T]` instantiation.

  ```go
  func Map[T, U any](s []T, f func(T) U) []U { … }   // genuinely parametric → OK
  func MaxBy[T any, K cmp.Ordered](s []T, key func(T) K) T { … }  // tight constraint
  ```

## 13. Security, dependencies & build

- **`govulncheck ./...`** in CI — the official scanner uses call-graph reachability, so it only
  flags vulns you actually call (low noise, actionable). Add `gosec` (in golangci-lint) and
  keep `GOSUMDB` on; commit `go.sum`; `go mod verify`.
- **CI integrity gates:** `go mod tidy && git diff --exit-code go.mod go.sum`, `-mod=readonly`.
- **Static minimal containers:** `CGO_ENABLED=0`, `-trimpath`, `-ldflags "-s -w -X main.version=…"`,
  shipped on `gcr.io/distroless/static-debian13:nonroot` (no shell/pkg-mgr, UID 65532 satisfies
  K8s `runAsNonRoot`). See [docker.md](../platform/docker.md).
  ```dockerfile
  RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /app ./cmd/app
  FROM gcr.io/distroless/static-debian13:nonroot
  COPY --from=build /app /app
  USER nonroot:nonroot
  ENTRYPOINT ["/app"]
  ```
- Automated dependency updates via Dependabot/Renovate (`gomod`, `postUpdateOptions:
  [gomodTidy]`) paired with govulncheck. See [security.md](../practices/security.md).

## 14. Logging

- **`log/slog`** (stdlib, Go 1.21+) is the standard — no logrus/zap lock-in. JSON handler in
  prod, text in dev; install once with `slog.SetDefault`; bind request context with `slog.With`.
  ```go
  slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl})))
  ```

## 15. Profiling & build tags

- **Never optimize without a profile.** Measure with `go test -bench=. -benchmem` (allocs/op is
  where the wins hide), then drill with **pprof** (`-cpuprofile`/`-memprofile`, `go tool pprof`).
  Guesswork-driven micro-optimization is how readable code dies for no measured gain.
- **Expose `net/http/pprof` only on an internal/admin listener** — importing it for its
  `init()` side effect registers `/debug/pprof/*` on `http.DefaultServeMux`; never put that on
  your public server. Bind it to a separate, network-restricted `http.Server`.
- **Build tags gate non-default code:** `//go:build integration` to keep slow integration tests
  out of the default `go test` run (`go test -tags=integration`), and per-platform files
  (`//go:build linux`). The constraint is the **first line**, followed by a blank line.

  ```go
  //go:build integration

  package store_test   // only compiled with: go test -tags=integration ./...
  ```

## Definition of done

- [ ] `gofumpt -l .` empty; `goimports` clean
- [ ] `golangci-lint run` clean (with the curated set)
- [ ] `go test -race ./...` green; coverage ≥ floor
- [ ] `govulncheck ./...` clean; `go mod tidy` produces no diff
- [ ] Errors wrapped with `%w`; no panic in library code; no ignored errors
- [ ] `http.Server` has all four timeouts set; graceful shutdown wired
- [ ] Serialized structs have explicit `json:` tags; secrets `json:"-"`; input validated post-decode
- [ ] DB calls take `ctx` + params; pool limits set; `rows.Err()` checked
- [ ] New deps minimal; `go.sum` committed
- [ ] Release binary is static (`CGO_ENABLED=0`) on a distroless nonroot image
