---
name: go-standards
description: Use when writing, reviewing, testing, formatting, or configuring any Go code in a repo that follows touchstone (gofumpt, golangci-lint v2, go test -race, slog, distroless). Invoke before adding deps, editing tests, or designing packages/APIs.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Go Standards

Full standard: **`standards/languages/golang.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- Pin Go via `go` + `toolchain` directives; `GOTOOLCHAIN=local` in CI. Commit `go.sum`; build `-mod=readonly`.
- Format with **gofumpt + goimports**; lint with **golangci-lint v2** (standard set + gosec/bodyclose/errorlint).
- **Table-driven tests + `go test -race`** always; stdlib `testing` + `go-cmp`, **not testify**. Coverage floor.
- **`govulncheck ./...`** in CI; `go mod tidy` must produce no diff.

## Don't get burned
- **Wrap errors with `%w`**; match via `errors.Is/As`. No `panic` in libraries; never ignore errors with `_`.
- **`context.Context` is the first arg**, never stored in a struct; always `defer cancel()`.
- Every goroutine needs an owned exit path; use `errgroup` for bounded parallel work.
- **Flat layout + `internal/`** — reject `golang-standards/project-layout`/`pkg/`. Accept interfaces, return structs.
- **HTTP servers:** set `http.Server` timeouts (the zero-value server is a Slowloris DoS); stdlib `http.ServeMux` (1.22+); graceful shutdown via `signal.NotifyContext` + `srv.Shutdown(ctx)`. JSON: tags mandatory, `DisallowUnknownFields` at boundaries. `database/sql`: bound the pool (zero-value is unbounded).
- Logging via stdlib **`log/slog`** (JSON). Ship static (`CGO_ENABLED=0`) on distroless nonroot.

## Done
`gofumpt -l .` empty · `golangci-lint run` clean · `go test -race ./...` green · `govulncheck` clean · `go mod tidy` no diff.
