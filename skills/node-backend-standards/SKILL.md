---
name: node-backend-standards
description: Use when building or reviewing a Node.js backend service in TypeScript in a touchstone repo — Fastify/NestJS/Express APIs, layering, config, validation, errors, graceful shutdown, streams, security, testing. Triggers on `fastify`/`@nestjs/*`/`express` in package.json and server-side `.ts` (server.ts, app.ts, route/service/repository files). For React/Next/Nuxt UIs use those skills; TS-language rules live in the typescript skill.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Node.js Backend (framework)

Full standard: **`standards/frameworks/node-backend.md`** (layers on `standards/languages/typescript.md`).
Load-bearing rules, inlined so this stays useful installed standalone in `~/.claude/skills/`:

## Always
- **Fastify is the default** framework; NestJS _(scale-up)_ for large multi-team apps, Express only as a legacy baseline — choose deliberately.
- **Module-by-domain layout** with strict **handler → service → repository** layering; build the app in a no-listen factory so tests get a fresh instance; inject deps, never module-global state.
- **Parse `process.env` once at boot through a schema** into a frozen `config`; missing/invalid vars crash startup; no secrets in the image.
- **Schema-validate every boundary** (body/params/query) and serialize responses via schema — TypeBox with Fastify, Zod when shared with a TS frontend; never return raw ORM rows.
- **Current Active LTS Node** (24 in 2026), ESM, `tsx` for dev only, compiled JS in prod; **`pino`** structured logs with a request-id, never `console.log`.

## Don't get burned
- **Never block the event loop** — offload CPU work to `worker_threads`/a queue; stream large payloads with `pipeline()` and honour backpressure; bound fan-out.
- **Graceful shutdown:** on `SIGTERM` stop accepting, drain in-flight, close pools, bounded by a timeout < pod grace period.
- **Typed domain errors → one central handler → `application/problem+json`**; never leak stack traces or driver messages.
- **Security:** helmet, rate-limit, explicit CORS allow-list, body limits, deny-by-default auth → `standards/practices/app-security.md`.
- **Scale via replicas, not the `cluster` module**; keep-alive timeout > load-balancer idle timeout.

## Done
Domain modules + layering · env parsed to frozen config · boundaries schema-validated · problem+json errors · pino + request-id · SIGTERM drain · helmet/rate-limit/CORS · Vitest + `inject()`/supertest + Testcontainers. See `standards/frameworks/node-backend.md`.
