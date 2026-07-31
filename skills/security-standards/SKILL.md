---
name: security-standards
description: Use when handling secrets, dependencies, CI/supply-chain, SBOM/signing, or web-app security in a repo that follows touchstone. Invoke before adding a dependency, wiring CI, handling credentials, or shipping a build artifact.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Security & Supply-Chain Standards

Full standard: **`standards/practices/security.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **Secret scanning, 3 layers**: gitleaks (pre-commit) + platform push protection (can't be bypassed) + TruffleHog (scheduled, `--only-verified`). **Leak runbook: rotate/revoke at the provider FIRST** — deleting the commit is not remediation.
- **Scan deps per ecosystem in CI** (pip-audit, pnpm audit, govulncheck, Trivy for images), gate at high+; **update cooldown** (`minimumReleaseAge`) so fresh malware can't auto-merge (CVE patches bypass); lockfiles committed, CI fails on drift.
- **Pin Actions to SHA**, least-privilege `permissions:`, `persist-credentials: false`, Harden-Runner; **OIDC** over static keys.
- Shipped artifacts get **SBOM + signed provenance** (cosign) and **verify at consumption** (`cosign verify-attestation`/Kyverno admission) — a signature nobody verifies is theater.

## Secrets & dependencies
- `.env` gitignored; only `*.example` committed. Validate config at boot.
- **Lifecycle scripts allowlisted** (pnpm blocks by default).

## CI & build integrity
- SAST: **CodeQL** (app) + **zizmor** (the workflows themselves). Attestations are unsigned by default; target SLSA Build L2/L3.
- **Vuln-management SLA** (Critical/KEV 48h · High 7d · Med 30d), prioritized by CVSS+EPSS+KEV; DAST (ZAP) against staging. AuthN/authZ/OWASP/threat-modeling live in `standards/practices/app-security.md`.

## Web
- **CSP + security headers**; ban `dangerouslySetInnerHTML`; no secrets behind `VITE_`; no source maps in prod.

## Done
Secret scanning clean (gitleaks + push protection) · deps scanned with cooldown, lockfiles drift-free · Actions SHA-pinned + least-privilege + OIDC · CodeQL + zizmor green · artifacts carry signed SBOM/provenance, verified at consumption. See `standards/practices/security.md`.
