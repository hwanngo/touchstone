---
name: app-security-standards
description: Use when writing or reviewing authentication, authorization, sessions/tokens (JWT/OAuth/OIDC), input validation, or anything touching the application attack surface in a touchstone repo. Invoke before adding a login/permission check, an API endpoint that handles user data, or when threat-modeling a new feature.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Application Security

Full standard: **`standards/practices/app-security.md`** in the touchstone repo. (Supply-chain/secrets/
CI live in `security.md`.) Load-bearing rules:

## Always
- **AuthZ deny-by-default**, enforced on the **server** every request — never trust the client; **check object-level ownership** (IDOR/BOLA — OWASP API #1) and isolate tenants.
- Validate/allowlist input at the boundary (schema); context-aware output encoding; parameterized queries (no injection); egress allowlist (SSRF); CSRF tokens for cookie auth.
- **Threat-model new trust boundaries** (lightweight STRIDE) and record an ADR; map the work against the OWASP Top 10 / API Top 10 before shipping.

## AuthN
- OAuth 2.1 / OIDC for delegated auth — Authorization Code + **PKCE**; validate `state`/`nonce`.
- **JWT pitfalls:** verify signature + `aud`/`iss`/`exp`; reject `alg:none`/alg-confusion; short TTL + refresh rotation (JWTs can't be revoked). Sessions: HttpOnly+Secure+SameSite, server-side, rotate on login.
- Passwords: **argon2id**; offer MFA.

## AuthZ
- **Deny-by-default**; enforce on the **server**, every request — never trust the client.
- **Check object-level ownership** (IDOR/BOLA — OWASP API #1); isolate tenants.

## Done
AuthZ deny-by-default + object-level checks · tokens/sessions hardened · inputs validated · OWASP risks reviewed · threat model for new boundaries.
