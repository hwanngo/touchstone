---
name: gin-standards
description: Use when building a Gin (gin-gonic) HTTP service in a touchstone repo — routing, middleware, binding, handlers. Triggers on `gin-gonic/gin` import, `gin.New()`/`gin.Default()`, `*gin.Context`. Language rules live in the go skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Gin (framework)

Full standard: **`standards/frameworks/gin.md`** (layers on `languages/golang.md`). Note: Gin is a
choice — stdlib `net/http` (1.22+ ServeMux) is the default; reach for Gin for routing/middleware
ergonomics. Rules:

## Always
- **handler → service → repository** layering with interface contracts + constructor DI wired in `main.go`; no globals; `internal/<domain>/`.
- `gin.New()` (not `gin.Default()`) in prod; **wrap in an `http.Server` with timeouts** (Gin sets none — Slowloris) + **graceful shutdown** (`signal.NotifyContext` + `Shutdown`).
- **`ShouldBindJSON`** (+ `binding:` validators), never `MustBind`; bind errors → problem+json.
- Pass **`c.Request.Context()`** down to services/db — never store `*gin.Context`. Thin handlers.

## Defer
- API contract → `../design/api-design.md`; DB → `../platform/database.md`; authN/authZ → `../practices/app-security.md`; server/context basics → `../languages/golang.md`.

## Done
gofumpt/golangci-lint/`go test -race`/govulncheck green · layered DI · server timeouts + shutdown. See the doc.
