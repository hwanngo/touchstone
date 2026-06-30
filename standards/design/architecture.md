# Architecture & System Design

The north star for design decisions. Optimise for change, not for cleverness. When in doubt, pick
the boring option and keep it reversible. Siblings: [api-design.md](api-design.md) (contracts),
[resilience.md](resilience.md) (failure patterns), [devops.md](../platform/devops.md) (deploy/observability).

---

## 1. Core principles

| Principle | What it means | Why |
|-----------|---------------|-----|
| **Boring tech by default** | Choose proven, well-understood tech; spend your innovation tokens on the actual problem | Most systems fail on operability, not feature gaps |
| **Reversibility** | Prefer two-way-door decisions; isolate one-way doors behind a seam | Cheap to be wrong when you can undo |
| **Clear module boundaries** | A boundary is a contract + an owner, not a folder | Coupling leaks through fuzzy seams |
| **Dependency direction** | Depend *inward*, toward stable abstractions; domain core knows nothing of IO | Stable things shouldn't change because volatile things did |
| **High cohesion, low coupling** | Things that change together live together; things that don't, don't share state | Localises blast radius of change |
| **Design for failure** | Assume every dependency is down, slow, or lying | Distributed systems are partial-failure machines |

> Rule of thumb: if a choice is reversible and cheap, **just decide and move** — don't ADR it. Reserve ceremony for one-way doors (§4).

## 2. Backend service design (12-factor, current)

The non-negotiables for any process that serves traffic:

| Concern | Standard |
|---------|----------|
| **Stateless processes** | Share-nothing; per-request state dies with the response. Durable state lives in backing services (DB/cache/queue), never local disk or memory |
| **Config from env** | No secrets or per-env values in code/image. Inject via env/secret store; fail fast on missing required config at boot |
| **Disposability** | Fast startup, graceful shutdown. On `SIGTERM`: stop accepting new work, drain in-flight requests within a deadline, close pools, then exit |
| **Dev/prod parity** | Same backing-service *types* and the same image across envs; differences are config only |
| **Bound every outbound call** | Every network/DB/cache call gets an explicit timeout — no unbounded waits. See [resilience.md](resilience.md) for retry/breaker/budget |
| **Validate at the boundary** | Reject malformed input at the edge before it touches domain logic; never trust callers |
| **Idempotency for mutations** | `POST`/`PUT`/`PATCH`/`DELETE` accept an idempotency key so retries are safe (§5) |

**Health-check semantics — keep these distinct:**

| Probe | Question | Action on failure |
|-------|----------|-------------------|
| **Liveness** | Is the process wedged/deadlocked? | Restart the instance |
| **Readiness** | Can it serve traffic *right now* (deps reachable, warmed)? | Pull from load balancer, don't restart |
| **Startup** _(scale-up)_ | Has slow boot finished? | Hold off liveness until done |

Liveness must **not** check downstream deps — a flaky dependency should drop you from readiness, not trigger a restart storm. Drain readiness *before* `SIGTERM` work on rolling deploys.

## 3. Modularity & boundaries

```text
Monolith-first  →  Modular monolith  →  Extract a service (only when forced)
(one deploy)       (hard internal       (independent deploy/scale/failure)
                    boundaries, events)
```

- **Default to a modular monolith.** One deployable, strong internal module boundaries (own data, talk via interfaces/events). You get most of the benefit of services with none of the distributed-systems tax.
- **Extract a service only when a real force demands it** — not for fashion:

| Valid reason to extract | Not a reason |
|-------------------------|--------------|
| Independent deploy cadence between teams | "Microservices are modern" |
| Independent scaling profile (CPU-bound vs IO-bound) | One class got big |
| Failure isolation (blast-radius containment) | Wanting a new language for one feature |
| Org/team scaling (Conway's law — boundaries follow teams) | Résumé-driven design |

- **Sync vs async coupling** — a synchronous call couples *availability* (callee down ⇒ caller down); an event/queue decouples availability but adds eventual consistency and ordering/dedup work. Prefer **async between services, sync within a module**. Don't pay async complexity inside one process.
- **Anti-corruption layer (ACL):** wrap every third-party/legacy integration in a translation layer so its model never leaks into your domain. The ACL is the *only* code that knows the foreign vocabulary — swap the vendor by rewriting one adapter.

## 4. Decision records & diagrams

- **ADRs for significant or irreversible choices** — one-way doors, anything with multiple viable options and lasting consequences. Skip them for reversible trivia.
- Format: context → decision → consequences. **Immutable** — supersede, never edit an accepted record.
- Use the kit template `templates/adr-0000-template.md`; see [collaboration.md](../practices/collaboration.md) §6 for the process and `docs/adr/` home.
- **Diagrams: lightweight [C4](https://c4model.com).** Keep **Context** (system + actors + neighbours) and **Container** (deployable units + datastores + protocols) diagrams current; drop to **Component** only for hot spots. Skip the Code level — the IDE is your code diagram. Diagram-as-code (Mermaid/Structurizr) so they live in the repo and review like code.

## 5. Cross-cutting concerns

**Idempotency** — repeating a request must not repeat the effect. Implement with a client-supplied idempotency key + a dedup store (key → result, with TTL): first request executes and records, retries return the stored result. Mandatory on payment/order/provisioning paths.

**Consistency model — choose per use case, state it explicitly:**

| | Strong | Eventual |
|--|--------|----------|
| Use when | Money, inventory, auth, uniqueness | Feeds, counts, search, analytics, cross-service |
| Cost | Coordination, lower availability under partition | Must handle stale reads + reconciliation |

Default to **strong within a service's own datastore**, **eventual across services**. Never fake cross-service strong consistency with distributed locks — design for eventual + idempotent handlers instead.

**Failure-domain / blast-radius thinking** — for each dependency ask *"when this is down or slow, what's the degraded behaviour?"* Bound it (timeout, fallback, circuit breaker, bulkhead — [resilience.md](resilience.md)). A single slow dependency must never exhaust a shared pool and take the whole service down.

**Build vs buy** — buy/adopt anything that isn't your core differentiator (auth, billing, email, queues, observability). Build only where you have genuine, defensible domain advantage. Wrap bought things behind an ACL (§3) so the vendor stays replaceable.

**Data & privacy boundaries** — model data ownership and PII flow at design time; a module/service owns its data and exposes it via contract, never shared tables. See [data-privacy.md](../practices/data-privacy.md).

## 6. Smell checklist

- Two services that must always deploy together → they're one module; merge them.
- A shared database written by multiple services → hidden coupling; give each its own store + a contract.
- "We'll add retries later" on an unbounded call → it's already a latent outage.
- An ADR for a reversible choice, or a missing one for an irreversible choice → ceremony in the wrong place.
- Liveness probe that calls a downstream dependency → restart storms incoming.

## Definition of done

- [ ] Every service is stateless; all durable state lives in backing services
- [ ] Config comes from env/secret store; the process fails fast on missing required config
- [ ] Graceful shutdown drains in-flight work on `SIGTERM` within a deadline
- [ ] Distinct liveness / readiness (and startup if slow-booting) probes; liveness does **not** check downstream deps
- [ ] Every outbound call has an explicit timeout ([resilience.md](resilience.md))
- [ ] Mutating endpoints are idempotent (idempotency key + dedup) ([api-design.md](api-design.md))
- [ ] Input validated at the boundary before reaching domain logic
- [ ] Started as a (modular) monolith; any extracted service has a documented forcing reason
- [ ] Consistency model chosen and stated per data flow (strong vs eventual)
- [ ] Third-party/legacy integrations sit behind an anti-corruption layer
- [ ] Significant/irreversible decisions captured as immutable ADRs ([collaboration.md](../practices/collaboration.md) §6)
- [ ] C4 Context + Container diagrams exist as diagram-as-code and match reality
