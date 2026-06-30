# Gin Framework Standards

Framework layer; language rules → [golang.md](../languages/golang.md). Dependencies and supply-chain defer to [golang.md](../languages/golang.md) + [security.md](../practices/security.md).

**Gin is a choice, not the default.** Go's stdlib `net/http` (1.22+ `ServeMux`) is the default per golang.md. Reach for Gin when you need richer routing ergonomics (groups, parametric paths, middleware chain) — not reflexively.

---

## 1. Project Layout

Flat-per-feature inside `internal/`; no giant `controllers/` dump.

```text
internal/
  order/
    handler.go      // HTTP; thin — no business logic
    service.go      // domain interface + implementation
    repository.go   // storage interface + implementation
    handler_test.go
  user/
    ...
cmd/api/main.go     // wires everything; calls constructors in order
```

One domain package per resource. Interfaces live in the consuming package (Go idiom). Avoid `pkg/` unless genuinely shared.

## 2. Layered Architecture & Dependency Injection

**Handler → Service → Repository.** Each layer owns an interface; the layer above depends on the interface, not the concrete type.

```go
// order/repository.go
type Repository interface {
    GetByID(ctx context.Context, id string) (*Order, error)
}

// order/service.go
type Service interface {
    GetOrder(ctx context.Context, id string) (*Order, error)
}
type service struct{ repo Repository }
func NewService(r Repository) Service { return &service{repo: r} }

// order/handler.go
type Handler struct{ svc Service }
func NewHandler(svc Service) *Handler { return &Handler{svc: svc} }
```

Wire in `main.go` — **no globals, no `init()` side-effects**:

```go
repo    := order.NewRepository(db)
svc     := order.NewService(repo)
handler := order.NewHandler(svc)
handler.Register(v1)
```

_(scale-up)_ Use `google/wire` or `uber-go/fx` to generate wiring when the graph grows beyond ~10 constructors.

## 3. Setup

Use `gin.New()`, never `gin.Default()` in prod — `gin.Default()` silently attaches Logger and Recovery; own your middleware stack.

```go
gin.SetMode(gin.ReleaseMode) // before router creation; read from env
r := gin.New()
r.Use(middleware.RequestID(), middleware.Logger(), middleware.Recovery())
```

**Wrap the router in `http.Server` with explicit timeouts** — Gin sets none; zero-timeout is a Slowloris risk. Follow golang.md HTTP-server-timeout rules.

```go
srv := &http.Server{
    Addr:         ":8080",
    Handler:      r,
    ReadTimeout:  5 * time.Second,
    WriteTimeout: 10 * time.Second,
    IdleTimeout:  120 * time.Second,
}
go func() { log.Fatal(srv.ListenAndServe()) }()

quit := make(chan os.Signal, 1)
signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
<-quit

ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()
if err := srv.Shutdown(ctx); err != nil {
    log.Fatalf("forced shutdown: %v", err)
}
```

## 4. Routing & Handlers

Group routes by resource and API version (`/api/v1/orders`). Handlers must be thin — delegate all business logic to the service layer. Return early on error.

```go
func (h *Handler) Register(rg *gin.RouterGroup) {
    g := rg.Group("/orders")
    g.Use(auth.Required())
    g.GET("/:id", h.GetOrder)
}

func (h *Handler) GetOrder(c *gin.Context) {
    order, err := h.svc.GetOrder(c.Request.Context(), c.Param("id"))
    if err != nil {
        _ = c.Error(err); return
    }
    c.JSON(http.StatusOK, order)
}
```

**Anti-patterns:** fat handlers that query the DB directly; `gin.Default()` in prod; storing `*gin.Context` in a struct or goroutine (context is request-scoped and not safe to outlive the handler).

## 5. Binding & Validation

Use `ShouldBindJSON` / `ShouldBindQuery` / `ShouldBindUri` — they return the error rather than writing a 400 implicitly. **Never `MustBind*`** — it calls `c.AbortWithStatus(400)` silently, bypassing error middleware.

```go
type CreateOrderReq struct {
    SKU      string `json:"sku"      binding:"required,max=64"`
    Quantity int    `json:"quantity" binding:"required,min=1"`
}
if err := c.ShouldBindJSON(&req); err != nil {
    _ = c.Error(&ValidationError{Cause: err}); return
}
```

Bind errors → problem+json response. See [api-design.md](../design/api-design.md).

_(scale-up)_ Validate business invariants in the service layer, not struct tags alone.

## 6. Middleware

| Position | Middleware |
|---|---|
| 1 | Recovery — panic → 500, never crash |
| 2 | RequestID — inject before logging |
| 3 | Structured logger (slog) — include request-id |
| 4 | CORS — explicit origin allowlist, no wildcard in prod |
| 5 | Auth — before any protected route group |

Signature: `func(*gin.Context)`. Use `c.Next()` to continue, `c.Abort()` to short-circuit. Prefer `gin-contrib/*` for well-tested CORS/rate-limit implementations over hand-rolling.

## 7. Context Propagation

Pass `c.Request.Context()` to service and DB calls — **not `*gin.Context`** — so cancellation propagates correctly. Never store per-request state in package-level variables or on `*gin.Context` beyond the current request lifecycle.

```go
result, err := h.svc.Process(c.Request.Context(), payload) // correct
```

## 8. Centralized Error Handling

Accumulate errors with `c.Error(err)` in handlers; resolve them in a terminal middleware registered last. Map domain errors → HTTP status + problem+json in one place; never leak stack traces or DB messages to the client. Log originals server-side with request-id. See [api-design.md](../design/api-design.md) and [resilience.md](../design/resilience.md).

```go
func ErrorHandler() gin.HandlerFunc {
    return func(c *gin.Context) {
        c.Next()
        if len(c.Errors) == 0 { return }
        code, body := toHTTPError(c.Errors.Last().Err)
        c.JSON(code, body)
    }
}
```

## 9. Auth

AuthN in middleware; AuthZ deny-by-default in handlers/services — never assume authenticated == authorized. Full guidance → [app-security.md](../practices/app-security.md).

## 10. Testing

`httptest` + full router `ServeHTTP`; table-driven. No real server needed. Mock service interfaces with `mockery`-generated stubs to keep handler tests fast and isolated.

```go
w := httptest.NewRecorder()
req := httptest.NewRequest(http.MethodGet, "/api/v1/orders/"+tc.id, nil)
router.ServeHTTP(w, req)
assert.Equal(t, tc.want, w.Code)
```

See golang.md for table-driven patterns; [testing-strategy.md](../practices/testing-strategy.md) for integration test strategy.

_(scale-up)_ Wire a real DB via `testcontainers-go` for repository integration tests. See [database.md](../platform/database.md).

## Definition of done

- [ ] `gin.SetMode(gin.ReleaseMode)` set from env before router init
- [ ] `gin.New()` used; middleware stack explicitly declared
- [ ] `http.Server` wraps router with `ReadTimeout`, `WriteTimeout`, `IdleTimeout`
- [ ] Graceful shutdown wired to `SIGINT`/`SIGTERM` with `context.WithTimeout`
- [ ] Handler → Service → Repository layering; each layer depends on an interface
- [ ] All wiring via constructors in `main.go`; no package-level globals
- [ ] Routes grouped by resource/version; handlers contain no business logic
- [ ] `ShouldBind*` used everywhere; `MustBind*` absent
- [ ] Bind/validation errors routed through centralized error middleware
- [ ] `c.Request.Context()` propagated to all downstream calls; `*gin.Context` never stored
- [ ] CORS configured with explicit allowlist (no wildcard in prod)
- [ ] AuthN middleware + deny-by-default AuthZ in place
- [ ] Handler tests use mocked service interfaces + `httptest`; table-driven

**Sources:** [gin-gonic/gin](https://github.com/gin-gonic/gin) · [gin-gonic/examples](https://github.com/gin-gonic/examples) · [bxcodec/go-clean-arch](https://github.com/bxcodec/go-clean-arch) · [eddycjy/go-gin-example](https://github.com/eddycjy/go-gin-example) · [Caknoooo/go-gin-clean-starter](https://github.com/Caknoooo/go-gin-clean-starter) · [Graceful shutdown guide (Kittipat)](https://medium.com/@kittipat_1413/graceful-shutdown-in-golang-gin-a-complete-guide-130e3f075415)
