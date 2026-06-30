# Node.js Backend Standards

Framework layer; language rules → [typescript.md](../languages/typescript.md). How to build a
Node.js backend service in TypeScript. Cross-cutting concerns are **deferred, not repeated**: API
contracts → [api-design.md](../design/api-design.md), retries/timeouts/circuit-breakers →
[resilience.md](../design/resilience.md), authN/authZ/OWASP →
[app-security.md](../practices/app-security.md), test philosophy →
[testing-strategy.md](../practices/testing-strategy.md), logs/metrics/traces/SLOs →
[observability.md](../platform/observability.md), dependencies/supply-chain →
[typescript.md](../languages/typescript.md) + [security.md](../practices/security.md).

> **One law:** never block the event loop, and validate everything that crosses the boundary.

---

## 1. Framework choice

**Fastify is the default** for a new service: first-class TypeScript types, schema-based
validation **and** serialization, plugin encapsulation, and the lowest framework overhead. Reach
up or stay put deliberately — this is an upfront architecture call, not a retrofit.

| You have… | Use | Why |
|---|---|---|
| A lean HTTP/JSON service, high throughput | **Fastify** (this doc's default) | Schema-first, ~2× Express req/s, async-native. |
| A large app, many teams/domains, heavy DI | **NestJS** _(scale-up)_ | Batteries-included modules + DI container; structure pays off past ~10 domains. |
| An existing/legacy codebase | **Express 5** (baseline) | Maintain it; don't start new services on it. Express 5 finally awaits async handlers. |

- **Don't hand-roll `http.createServer` + a router** for anything past a toy — you reimplement
  body parsing, validation, and error handling the framework already hardened.
- NestJS still runs **on a Fastify adapter** (`@nestjs/platform-fastify`) — prefer it over the
  Express adapter so the perf and schema story below still apply.

## 2. Project layout & layering

**Module-by-domain, not by file-type.** Group everything a feature owns under one folder; reserve
the top level for the composition root and genuinely shared code. A flat
`controllers/ services/ repositories/` split stops scaling — every feature then touches every folder.

```text
src/
  orders/   route.ts  schema.ts  service.ts  repository.ts  errors.ts  orders.test.ts
  billing/  route.ts  schema.ts  service.ts  repository.ts  …
  config.ts  logger.ts  app.ts   server.ts          # global: env, logger, app factory, bootstrap
```

- **Strict layering: route/handler → service → repository.** The handler validates input and
  shapes the response; the **service** owns business logic; the **repository** owns persistence.
  Dependencies point inward — a handler never touches the DB driver directly.
- **An `app.ts` factory** (`buildApp(deps): FastifyInstance`) wires plugins/routes and returns the
  instance **without listening**; `server.ts` calls `.listen()`. Tests build a fresh app per suite.
- **Inject dependencies, don't import singletons.** Pass the repo into the service constructor (or
  a Fastify plugin/decorator); module-global mutable state is untestable and leaks across requests.

## 3. Runtime, ESM & execution

| Concern | Rule |
|---|---|
| Node version | **Current Active LTS** (e.g. Node 24 — verify the current Active LTS). Pin with `engines` + `.nvmrc`; only even majors in prod. |
| Modules | **ESM** (`"type": "module"`). No CommonJS in new code; use `node:` import prefixes for builtins. |
| Dev runtime | **`tsx`** to run `.ts` directly (`tsx watch src/server.ts`). `ts-node` is legacy — slower, ESM-awkward. |
| Build | Type-check with `tsc --noEmit`; transpile/bundle with **`tsup`/esbuild** for a fast `dist/`. Don't ship raw `ts-node` to prod. |
| Entry | Run the compiled JS (`node dist/server.js`) in the container; `tsx` is dev-only. |

```bash
pnpm dev      # tsx watch src/server.ts        — reload on change
pnpm build    # tsc --noEmit && tsup src/server.ts --format esm
pnpm start    # node dist/server.js            — what the container runs
```

## 4. Configuration

**Parse `process.env` once, at boot, through a schema** — a typed, frozen `config` object that the
rest of the app imports. Never read `process.env` scattered through the code.

- **Fail fast on misconfig:** a missing/invalid var crashes startup with a clear message, not a 500
  on first request. Secrets (`DATABASE_URL`, `JWT_SECRET`) are required fields, never defaulted.
- **No secrets in the image or repo** — inject at runtime (env/secret manager); `.env` is dev-only
  and git-ignored. See [app-security.md](../practices/app-security.md).

```ts
import { z } from 'zod'
const Env = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']),
  PORT: z.coerce.number().default(3000),
  DATABASE_URL: z.string().url(),
})
export const config = Object.freeze(Env.parse(process.env)) // throws → process exits non-zero
```

## 5. Validation at the boundary (DTOs)

**Nothing untrusted enters a handler unparsed.** Validate body, params, query, and headers at the
edge; the service layer works only with parsed, typed data.

- **Fastify:** prefer **TypeBox** (`@fastify/type-provider-typebox`) — one schema drives runtime
  validation, response **serialization**, *and* the static type, with no codegen. Use **Zod**
  (`fastify-type-provider-zod`) when you already share Zod schemas with a TS frontend.
- **Express/Nest:** **Zod** per route (or `class-validator` DTOs in Nest); parse, don't cast.
- **Validate the response too** (Fastify `response` schema) — it filters fields and stops a new DB
  column from leaking into the public contract. DTOs in ≠ DTOs out; never return the ORM row raw.
- Share request/response schemas with consumers where possible → [api-design.md](../design/api-design.md).

```ts
const Body = Type.Object({ sku: Type.String({ maxLength: 64 }), qty: Type.Integer({ minimum: 1 }) })
app.post('/orders', { schema: { body: Body, response: { 201: OrderOut } } }, handler)
```

## 6. Error handling

- **Typed domain errors, not bare `throw new Error('...')`.** A small hierarchy
  (`AppError → NotFoundError, ValidationError, ConflictError`) carries an HTTP status and a stable
  `code`; the handler maps the type to a status, never the other way round.
- **One central error handler** (`app.setErrorHandler` / Nest exception filter / Express
  `(err,req,res,next)` last) is the only place that writes an error response.
- **Never leak internals:** emit `application/problem+json` (RFC 9457) with a safe message; log the
  stack + request-id server-side. Stack traces and driver messages never reach the client.
- **`async` handlers must surface rejections** — Fastify and Express 5 await them; in Express 4 wrap
  with an async-handler helper so a rejected promise can't hang the request.

```ts
app.setErrorHandler((err, req, reply) => {
  const e = toProblem(err)                    // maps AppError | ZodError | unknown → status + body
  req.log.error({ err, reqId: req.id }, e.title)
  reply.status(e.status).type('application/problem+json').send(e.body)
})
```

## 7. Logging & observability

- **`pino` is the logger** — structured JSON, low overhead. Fastify ships it built in; for Express
  use `pino-http`. Never `console.log` in app code (Biome `noConsole`, [typescript.md](../languages/typescript.md)).
- **One log line per request** with method, path, status, latency, and a **request-id** bound to a
  child logger; propagate the id downstream and echo it in the response.
- **Redact secrets** at the logger (`redact: ['req.headers.authorization', '*.password']`) — don't
  rely on remembering per-call. Metrics, traces, SLOs → [observability.md](../platform/observability.md).

## 8. Async, streams & backpressure

- **Stream large payloads; never buffer a whole file/result set in memory.** Pipe with
  **`stream/promises` `pipeline()`** so errors and cleanup propagate across every stage — a bare
  `.pipe()` leaks sockets and file descriptors on error.
- **Respect backpressure:** honour `write()`'s `false` return (or use `pipeline`); a fast producer
  into a slow consumer without backpressure grows the heap until the process OOMs.
- **`await` real concurrency with `Promise.all`**, but **bound fan-out** (e.g. `p-limit`) so you
  don't open 10k connections at once. Timeouts/retries on outbound calls → [resilience.md](../design/resilience.md).
- **Never `await` inside a hot loop** when the iterations are independent — gather promises and
  await once.

## 9. Graceful shutdown

A pod gets **`SIGTERM`, then a grace window, then `SIGKILL`.** Use the window to finish in-flight
work, not to drop it.

1. On `SIGTERM`/`SIGINT`, **stop accepting new connections** (`server.close()` / `app.close()`).
2. **Drain in-flight requests**, then close the DB pool, queue consumers, and other resources.
3. **Bound it with a timeout** shorter than the orchestrator's grace period; force-exit if drain
   stalls so a hung connection can't block the rollout.

```ts
for (const sig of ['SIGTERM', 'SIGINT'] as const)
  process.once(sig, async () => {
    const t = setTimeout(() => process.exit(1), 10_000).unref() // < pod grace period
    await app.close()          // stops listening, runs onClose hooks (drain, pool.end())
    clearTimeout(t)
  })
```

- **Idempotent and once-only** — guard against a second signal re-entering shutdown.
- Add `@fastify/under-pressure` to **shed load** (503) and fail readiness when the event-loop lag
  or RSS crosses a threshold _(scale-up)_.

## 10. Security

Mechanisms here; policy, authZ, and OWASP coverage → [app-security.md](../practices/app-security.md).

| Control | Fastify | Express |
|---|---|---|
| Secure headers | `@fastify/helmet` | `helmet` |
| Rate limiting | `@fastify/rate-limit` | `express-rate-limit` |
| CORS | `@fastify/cors` — explicit origin allow-list | `cors` — explicit allow-list |
| Body limits | `bodyLimit` (default 1 MB; set per route) | `express.json({ limit })` |

- **Input validation is the first line of defence** (§5) — schema-validate every boundary; reject
  unknown fields. Never interpolate untrusted input into SQL/shell.
- **Deny by default:** protected routes require the auth hook; public routes are the explicit
  exception. **Never `origin: '*'` with credentials.** TLS terminates at the proxy; trust
  `X-Forwarded-*` only behind it (`trustProxy`).

## 11. Testing

Mechanics (Vitest runner, coverage floors) → [typescript.md](../languages/typescript.md) §7;
strategy → [testing-strategy.md](../practices/testing-strategy.md).

- **`Vitest`** is the runner (Jest only in an existing Jest repo). Build the app via the §2 factory
  with **fakes injected** — fast, isolated, no real network.
- **HTTP tests run in-process:** Fastify **`app.inject()`** (no socket); **`supertest`** for
  Express. Assert on **status + response schema**, and cover the error path (a handler must return
  problem+json, not a 500).
- **Integration tests hit a real DB via `Testcontainers`** (`@testcontainers/postgresql`) — a
  throwaway container per run beats mocking the driver and catches migration/SQL drift _(scale-up)_.

## 12. Performance & scaling

- **Scale out with replicas (pods), not the `cluster` module.** In a container orchestrator, N
  single-process pods beat one process forking N workers — simpler, and the scheduler does the
  balancing. Reach for `cluster` only on a single bare host _(scale-up)_.
- **Offload CPU-bound work to `worker_threads`** (or a job queue). Hashing, image/PDF work, and big
  JSON parses block the loop and stall *every* concurrent request — measure event-loop lag.
- **Tune HTTP keep-alive:** set `server.keepAliveTimeout` **greater than** the upstream
  load-balancer's idle timeout, or you'll see sporadic 502s from races on connection close.
- **Reuse connection pools and `keepAlive` agents** for outbound HTTP/DB — never open a socket per
  request. **Profile before optimizing** (`node --prof`, clinic.js); most "slow" handlers are one
  blocking call or an unbounded query.

## Definition of done

- [ ] Framework chosen deliberately — Fastify default; NestJS/Express justified (§1).
- [ ] Code grouped **by domain module**; strict handler → service → repository layering; app built by a no-listen factory (§2).
- [ ] Node pinned to current Active LTS via `engines` + `.nvmrc`; ESM; `tsx` dev-only; compiled JS in prod (§3).
- [ ] `process.env` parsed once through a schema into a frozen `config`; missing/invalid vars crash at boot; no secrets in the image (§4).
- [ ] Every boundary (body/params/query) schema-validated; responses serialized via schema; no raw ORM rows returned (§5).
- [ ] Typed domain errors + one central handler → `application/problem+json`; no stack traces/internals leaked (§6).
- [ ] `pino` structured logs; one request-scoped line with request-id; secrets redacted (§7).
- [ ] Large payloads streamed with `pipeline()`; backpressure honoured; fan-out bounded (§8).
- [ ] `SIGTERM` drains in-flight, closes pools, and is bounded by a timeout < pod grace period (§9).
- [ ] helmet, rate-limit, explicit CORS allow-list, body limits; deny-by-default auth (§10).
- [ ] Tests via Vitest + `inject()`/`supertest`, fakes injected; Testcontainers for DB integration; error path covered (§11).
- [ ] Scales via replicas; CPU work off the loop; keep-alive > LB idle timeout; outbound pools reused (§12).

**Sources:** [Fastify docs](https://fastify.dev/) · [Fastify — Getting Started](https://fastify.dev/docs/latest/Guides/Getting-Started/) · [Node.js — Stream backpressure guide](https://nodejs.org/en/learn/modules/backpressuring-in-streams) · [Node.js release schedule (LTS)](https://github.com/nodejs/release#release-schedule) · [pino docs](https://getpino.io/) · [NestJS docs](https://docs.nestjs.com/) · [Express 5 guide](https://expressjs.com/en/guide/migrating-5.html) · [Testcontainers for Node.js](https://node.testcontainers.org/) · [OWASP NodeJS Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Nodejs_Security_Cheat_Sheet.html)
