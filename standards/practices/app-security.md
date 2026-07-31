# Application Security Standards

Owns the **application attack surface**: authentication, authorization, the OWASP risks, input
handling, and threat modeling. The theme: **deny by default, never trust the client, and enforce
every decision on the server.**

Scope split — this doc is the app layer. Supply-chain, secret scanning, SBOM, runtime secrets,
CI gates, and **frontend XSS/CSP** live in [security.md](security.md). Data-at-rest encryption and
PII handling live in [data-privacy.md](data-privacy.md). Surface design (rate limits, versioning,
error shape) lives in [api-design.md](../design/api-design.md).

---

## 1. Authentication (who are you)

- **Delegated / SSO → OAuth 2.1 + OIDC.** Don't hand-roll. OAuth 2.1 folds the BCPs into the
  spec: **Authorization Code + PKCE for every client** (not just public/SPA), implicit and
  password grants are **gone**. Validate `state` (CSRF on the callback) and OIDC `nonce`
  (replay) on return; reject if either doesn't match what you stored.
- **First-party login → server-side sessions, not JWTs in the browser.** A session cookie you
  can revoke beats a stateless token you can't. Cookie flags are non-negotiable:

  | Flag | Value | Why |
  |---|---|---|
  | `HttpOnly` | on | JS can't read it → XSS can't exfiltrate the session |
  | `Secure` | on | never sent over plaintext HTTP |
  | `SameSite` | `Lax` (or `Strict`) | first line of CSRF defense |
  | server-side store | opaque ID → Redis/DB | revocable, rotatable, no PII in the token |

  **Rotate the session ID on every privilege change** (login, step-up, role change) to kill
  session fixation.

- **Tokens vs sessions:** use JWTs for **service-to-service** and short-lived access tokens, not
  as your browser session. Stateless = can't revoke = a stolen token is valid until `exp`.

### JWT pitfalls (the ones that actually get exploited)

- **Algorithm confusion / `alg:none`.** Pin the expected algorithm server-side; **never** trust
  the token header's `alg`. Reject `none`; don't let an RS256 verifier be tricked into HS256
  with the public key as the HMAC secret.
- **Always verify signature + claims**: `aud` (token meant for *you*), `iss` (issuer you trust),
  `exp`/`nbf` (time window). A decoded-but-unverified JWT is attacker-controlled JSON.
- **Short access TTL (5–15 min) + refresh-token rotation** (one-time-use; detect reuse →
  revoke the family). You can't revoke an access token, so keep it short and lean on refresh.

### Credentials & MFA

- Password hashing: **argon2id** (preferred) or **bcrypt** — memory-hard, per-user salt, tuned
  work factor. Never SHA-256/MD5/unsalted; never encryption (reversible).
- Offer **MFA** (TOTP/WebAuthn) and **require it for admin/privileged accounts**. Passkeys
  (WebAuthn) over SMS where you can. Rate-limit + lock out on credential stuffing.

## 2. Authorization (what may you do)

- **Deny by default.** Every route is forbidden until a check grants it. New endpoints inherit
  the deny, not an accidental allow.
- **Enforce on the server, on every request.** UI hiding a button is UX, not security. Token
  scope is a hint, not the decision. The server re-derives identity and re-checks permission for
  the *specific resource* every time.
- **Model:** **RBAC** for coarse roles; **ABAC** when decisions depend on attributes (owner,
  tenant, status, time). Centralize the check (policy module / middleware), don't scatter `if
  role ==` across handlers.
- **IDOR / BOLA — OWASP API #1, ~40% of API attacks.** For *every* object reference in the
  request (`/orders/{id}`, `?account=`), verify **this caller owns/may-access this object**
  before responding. Don't rely on unguessable IDs (UUIDs hide, they don't authorize).

  ```python
  # WRONG: trusts the path param
  order = db.get(order_id)
  # RIGHT: scope the query to the caller — ownership is part of the lookup
  order = db.get(order_id, owner_id=current_user.id)  # 404 if not theirs
  ```

- **Object *property*-level too (API #3):** don't mass-assign or over-return fields. Allowlist
  inputs and outputs (DTOs/serializers) — never blind-bind the request body to your model.
- **Fail closed (OWASP A10, §3).** When the check itself goes wrong — the policy service is
  unreachable, the token parse throws, the claim is missing — **deny**. `except: pass` around an
  authorization call, a `try` that falls through to the permissive branch, or a default `allow`
  when the lookup returns `None` is the whole of *Mishandling of Exceptional Conditions*: the
  system is secure only while nothing breaks. Test the error path, not just the happy path.
- **Multi-tenant:** carry `tenant_id` in the auth context and **filter every query by it** at a
  choke point (repository layer / RLS). One missing `WHERE tenant_id` is a cross-tenant breach.
  See [database.md](../platform/database.md) for row-level security.

## 3. OWASP Top 10 (2025) → control mapping

Each risk maps to the standard that addresses it. This is the audit checklist. The current
revision is **OWASP Top 10:2025** (announced November 2025, final release January 2026) — it
supersedes the 2021 list.

| Risk (2025) | Control / where it lives |
|---|---|
| A01 Broken Access Control | Deny-by-default + per-object checks (§2); IDOR/BOLA; **SSRF** egress allowlist (§4) |
| A02 Security Misconfiguration | Hardened defaults; security headers → [security.md](security.md) |
| A03 Software Supply Chain Failures | Pinning, scanning, cooldown, SBOM → [security.md](security.md) + [dependencies.md](dependencies.md) |
| A04 Cryptographic Failures | TLS everywhere (§6); at-rest enc → [data-privacy.md](data-privacy.md) |
| A05 Injection | Parameterized queries / ORM bindings + input validation (§4) |
| A06 Insecure Design | Threat modeling per trust boundary (§5) |
| A07 Authentication Failures | OAuth 2.1/OIDC, argon2id, MFA, session rotation (§1) |
| A08 Software or Data Integrity Failures | Signing, provenance, attestation → [security.md](security.md) |
| A09 Security Logging and Alerting Failures | Audit authZ failures + logins; **alert** on them; no secrets in logs |
| A10 Mishandling of Exceptional Conditions | Fail closed (§2); typed error shape, no internals leaked → [api-design.md](../design/api-design.md), [resilience.md](../design/resilience.md) |

**What moved since 2021** — if you hold an older audit, re-map it:

- **SSRF is gone as its own entry.** 2021's A10 SSRF is now absorbed into **A01 Broken Access
  Control**. The control (§4) is unchanged; only the label moved.
- **A03 Software Supply Chain Failures is new**, expanding 2021's *Vulnerable and Outdated
  Components* past the dependency list to build systems, CI, and distribution infrastructure.
- **A10 Mishandling of Exceptional Conditions is new** — failing *open*, swallowed errors, and
  logic that takes the permissive branch when something goes wrong.
- **Renames**: *Identification and Authentication Failures* → **Authentication Failures**;
  *Security Logging and Monitoring Failures* → **Security Logging and Alerting Failures**
  (logging you never alert on is not a control).
- **Rank shifts**: Security Misconfiguration #5 → **#2**; Cryptographic Failures #2 → #4;
  Injection #3 → #5; Insecure Design #4 → #6. Broken Access Control stays **#1**.

**API Top 10 (2023 — still the current API revision)** highlights not covered above: **API2** Broken Auth (§1 JWT/session),
**API4** Unrestricted Resource Consumption → rate/size limits ([api-design.md](../design/api-design.md)),
**API5** Broken Function-Level AuthZ → deny-by-default on admin routes (§2), **API6** Sensitive
Business Flow abuse → bot/velocity controls _(scale-up)_, **API9** Inventory → no
undocumented/legacy endpoints in prod.

## 4. Input validation & output encoding

- **Validate at the boundary, allowlist not denylist.** Parse the request against a **schema**
  (Zod/Pydantic/JSON-Schema) at the edge; reject unknown fields. Validate type, range, length,
  format — then work with typed objects, not raw strings.
- **Injection → parameterize, always.** Bound parameters / ORM for SQL; never string-concat a
  query or shell command. Same for NoSQL operators, LDAP, and template engines.
- **Output encoding is context-aware.** Encode for the sink — HTML body vs attribute vs JS vs
  URL vs SQL are different escapes. (Browser XSS sink rules + CSP live in
  [security.md](security.md) / [react.md](../frameworks/react.md).)
- **SSRF (A01 in 2025 — was its own A10 in 2021 — / API7):** for any server-side fetch of a user-supplied URL, **allowlist egress**
  destinations and **block link-local/internal ranges** (`169.254.0.0/16`, RFC1918, metadata
  endpoints). Resolve-then-check to defeat DNS rebinding; disable redirects to internal hosts.
- **CSRF:** `SameSite` cookies are the baseline; add **per-request CSRF tokens** (double-submit
  or synchronizer) for any cookie-authenticated state-changing request. Token/Bearer-auth APIs
  that never use cookies are not CSRF-exposed.

## 5. Threat modeling (lightweight, per trust boundary)

Trigger a model **when you cross a new trust boundary** — a new internet-facing service, a new
data store of sensitive data, a new auth path, or a new third-party integration. Not every PR.

- Run **STRIDE** (Spoofing, Tampering, Repudiation, Info disclosure, DoS, Elevation) — or
  **evil-user-stories** ("as an attacker I can…") for a faster team-friendly pass.
- Draw a **data-flow diagram** marking trust boundaries (where data crosses a privilege level);
  threats cluster on the boundaries.
- **Record the outcome as an ADR** — assets, threats, accepted/mitigated, owner — so the
  reasoning survives. Cheap now, irreplaceable during an incident.

**Security-review trigger** (require a review before merge): new authN/authZ logic, crypto, a
new external surface, PII handling, deserialization, or a file/URL fetched from users.

## 6. Secrets & transport

- **TLS everywhere** — public *and* service-to-service (mTLS internally _(scale-up)_). HSTS on;
  redirect HTTP→HTTPS; modern ciphers only.
- **Secrets:** never in code/logs/errors; injected at runtime, rotatable, scoped — full handling
  in [security.md](security.md).
- **Sensitive data at rest:** encryption, key management, and PII classification →
  [data-privacy.md](data-privacy.md). Encrypt the data that would hurt if it leaked, not all of it.

---

## Definition of done

- [ ] Delegated auth via OAuth 2.1/OIDC with **PKCE**; `state`/`nonce` validated on callback
- [ ] First-party sessions: HttpOnly+Secure+SameSite cookies, server-side, rotated on priv change
- [ ] JWTs verify sig + `aud`/`iss`/`exp`, pinned `alg` (no `none`), short TTL + refresh rotation
- [ ] Passwords argon2id/bcrypt; MFA available and required for privileged accounts
- [ ] AuthZ deny-by-default, enforced server-side on every request, and **failing closed** on error
- [ ] Per-object ownership checks on every resource reference (no IDOR/BOLA); tenant-scoped queries
- [ ] Boundary schema validation (allowlist); parameterized queries; context-aware output encoding
- [ ] SSRF egress allowlist; CSRF tokens for cookie-auth mutations
- [ ] STRIDE/evil-user-story model + DFD recorded as an ADR for each new trust boundary
- [ ] Security-review trigger defined and enforced in the PR process
- [ ] OWASP Top 10 (**2025**) + API Top 10 (2023) mapped to controls and reviewed

---

**Sources:** [OWASP Top 10:2025](https://owasp.org/Top10/2025/) · [OWASP Top 10:2025 — Introduction (what changed since 2021)](https://owasp.org/Top10/2025/0x00_2025-Introduction/) · [OWASP API Security Top 10 (2023)](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)
