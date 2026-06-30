# Security & Supply-Chain Standards

Cross-cutting security controls every repo should adopt. Most run in CI — see
[ci-cd.md](../platform/ci-cd.md) for where they wire in. The theme: **shift left, fail the build, and
make tampering detectable.**

> **AuthN/authZ, OWASP Top 10, and threat modeling live in [app-security.md](app-security.md)** — this
> file is supply-chain, scanning, response, and crypto. Sensitive-data handling: [data-privacy.md](data-privacy.md).

---

## 1. Secret scanning (defense-in-depth, three layers)

Secrets in git history are the highest-frequency real incident. Use all three layers:

| Layer | Tool | When it fires |
|---|---|---|
| Local (pre-commit) | **gitleaks** hook | at `git commit` — fast, offline |
| Server-side | **platform push protection** (GitHub/GitLab) | at `git push` — **cannot** be bypassed with `--no-verify` |
| Deep / scheduled | **TruffleHog** (`--only-verified`) | weekly full-history sweep; API-verifies which secrets are *live* |

```yaml
# .pre-commit-config.yaml
- repo: https://github.com/gitleaks/gitleaks
  rev: v8.x
  hooks: [{ id: gitleaks }]
```

Run gitleaks as a **blocking CI job** too (local hooks can be skipped). Enable the platform's
native **push protection** — it's the only layer a developer can't bypass.

### Leak-response runbook (write this down before you need it)
A leaked secret is **compromised the moment it hits a remote** — deleting the commit is *not*
remediation. Order of operations:
1. **Rotate/revoke the credential at the provider first** (assume it's already scraped).
2. Invalidate sessions/tokens minted with it.
3. *Then* purge history (`git filter-repo`) if needed.
4. Record the incident; add a scanner rule so it can't recur.

> GitGuardian: ~80% of detected secrets are never rotated. Rotation is the fix, not deletion.

## 2. Dependency vulnerability scanning

Scan the **resolved dependency graph** against advisory DBs, per ecosystem, in CI:

| Ecosystem | Tool | CI command |
|---|---|---|
| Python | **pip-audit** | `uvx pip-audit` (or against the exported lockfile) |
| Node | **pnpm audit** | `pnpm audit --prod --audit-level high` |
| Go | **govulncheck** | `go run golang.org/x/vuln/cmd/govulncheck ./...` |
| Containers | **Trivy / Grype** | scan the built image (see [docker.md](../platform/docker.md)) |
| PRs (any) | **dependency-review-action** | blocks vulnerable/bad-license deps before merge |

Gate at a sensible severity (`high`+) so the check stays actionable, not noisy.

### Dependency-update cooldown (the senior move)
Auto-merging brand-new releases is how supply-chain malware spreads (a compromised version
rides an instantly-merged bot PR). Configure a **cooldown** so updates must "age" before
merge — **security/CVE patches bypass it**:

```jsonc
// renovate.json
{ "extends": ["config:recommended"], "minimumReleaseAge": "7 days" }
```
pnpm v11 ships a 24h install cooldown (`minimumReleaseAge`) on by default; keep it.

### Lockfiles are the contract
Commit lockfiles; CI installs `--frozen` / `--locked` and **fails on drift** (`uv lock --check`,
`pnpm install --frozen-lockfile`). pnpm v10+ blocks dependency **lifecycle scripts** by
default (`onlyBuiltDependencies`/`allowBuilds` allowlist) — keep it on; a compromised
transitive `postinstall` shouldn't execute on CI.

## 3. Static analysis (SAST) — your code *and* your CI

- **App code:** **CodeQL** (GitHub semantic analysis) on PRs — catches injection, path
  traversal, etc. Language-specific linters add cheap SAST too (Python ruff `S`/bandit rules,
  Go `gosec`, Biome security rules).
- **Your workflows:** **zizmor** — static analysis *of the GitHub Actions workflows
  themselves* (template injection, credential leakage, cache poisoning, unpinned actions).
  The CI config is a real attack surface; scan it. Both upload SARIF to code scanning.

(Both wire into CI — see [ci-cd.md](../platform/ci-cd.md) §SAST.)

## 4. Dynamic analysis (DAST) + runtime security

SAST sees source, never the running app. Add a black-box pass and watch the workload at runtime.

- **DAST:** **OWASP ZAP baseline** against **staging** (never prod) as a **scheduled** CI job —
  passive scan + spider, fails on new alerts, fast enough to run nightly. Catches misconfigured
  headers, exposed endpoints, and reflected XSS that static analysis can't reach.

  ```yaml
  # nightly DAST against staging
  - uses: zaproxy/action-baseline@v0.x
    with: { target: 'https://staging.example.com', fail_action: true }
  ```

- _(scale-up)_ **Runtime threat detection** — **Falco** or **Tetragon** (eBPF) to alert on
  anomalous syscalls/exec/network from running pods (reverse shells, crypto-miners, unexpected
  egress).
- _(scale-up)_ **Tighten the sandbox** beyond `seccompProfile: RuntimeDefault`: per-workload
  **seccomp**/**AppArmor** profiles, drop all capabilities, read-only rootfs, and an **admission
  policy** (Kyverno/Gatekeeper) that rejects privileged/`hostPath`/`latest`-tag pods (see
  [devops.md](../platform/devops.md)).

## 5. Build integrity: SBOM, provenance, signing

For anything you ship (images, binaries, packages):
- **SBOM** (CycloneDX/SPDX) — a machine-readable bill of materials so "are we affected by
  CVE-X?" is a query, not an audit. Generate from the lockfile / at build
  (`uv export --format cyclonedx1.5`, `anchore/sbom-action`, `docker buildx --sbom`).
- **Provenance attestation** (SLSA via `actions/attest-build-provenance`) — cryptographically
  binds an artifact digest to the workflow/commit that built it. Keyless (OIDC) — no key to leak.
- **Signing** (**cosign**) — sign container digests so admission control can verify them.
  Attestations are unsigned by default; **pair SBOM/provenance with signing or they convey no
  trust.** Increasingly a compliance requirement (US EO 14028, EU CRA).

### SLSA target (set a level, don't hand-wave)

[SLSA v1.0](https://slsa.dev) Build track. State the bar explicitly:

| Level | What it buys | How |
|---|---|---|
| **Build L2** (baseline) | hosted build + **signed provenance** | `actions/attest-build-provenance` on every build |
| **Build L3** (release artifacts) | **non-forgeable** provenance, isolated build | a **reusable trusted builder** (SLSA generators / hardened reusable workflow) — the workflow itself is the trust root, not the caller |

Generating provenance is half the job. **L3 is about the builder being isolated and the signing
key unreachable from build steps** — you only get that from a trusted reusable builder, not by
calling cosign inside your own job.

### Verify on consumption (a signature nobody checks is theater)

Producing attestations earns you nothing until the **consumer** verifies them. Pin the identity —
an unpinned verify accepts a signature from *any* workflow.

```bash
# Container image: verify keyless cosign attestation, pinned to the producing workflow
cosign verify-attestation \
  --type slsaprovenance \
  --certificate-identity-regexp '^https://github.com/acme/.+/.github/workflows/release.yml@refs/tags/v.+$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/acme/app@sha256:...

# Released binary/blob: verify SLSA provenance, pinned to source + builder
slsa-verifier verify-artifact app-linux-amd64 \
  --provenance-path app.intoto.jsonl \
  --source-uri github.com/acme/app \
  --builder-id https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@refs/tags/v2.0.0
```

**Enforce at K8s admission** so unverified images can't run: **Kyverno `verifyImages`** (or Sigstore
**policy-controller**) with the same pinned `certificate-identity` + `oidc-issuer` as above —
unsigned/mismatched images are rejected at the API server, not discovered in prod (see
[devops.md](../platform/devops.md)).

### Packages you publish

- **npm:** build with `--provenance` (`npm publish --provenance` from OIDC-trusted CI) — shows the
  verified-provenance badge and pins the source.
- **PyPI:** **Trusted Publishing** (OIDC, no long-lived token) + attestations — no API token to leak.

## 6. Web app security (frontends)

- **Content-Security-Policy + security headers** at the edge (see [docker.md](../platform/docker.md) nginx
  section). A static Vite SPA gets a clean `script-src 'self'` (external hashed JS, no inline);
  `style-src 'unsafe-inline'` is the honest, unavoidable compromise for a server-less SPA —
  **don't advertise a nonce policy you can't statically deliver.**
- **Ban the XSS sinks**: `dangerouslySetInnerHTML` (Biome `noDangerouslySetInnerHtml` = error);
  sanitize with DOMPurify behind one audited `<SafeHtml>` wrapper if truly needed.
- **`VITE_`/`NEXT_PUBLIC_` prefixes are a boundary, not a safeguard** — prefixed vars are
  inlined as plaintext into the bundle. Scan the **built `dist/`** (not just source) for
  secrets, and CI-grep-ban `VITE_*(SECRET|KEY|TOKEN|PASSWORD)`.
- **No source maps in production** (see [react.md](../frameworks/react.md)).

## 7. Secrets management (runtime)

- **Never plaintext in git.** `.env` is gitignored; only `*.example` is committed.
- **Cloud auth:** prefer short-lived **OIDC**-minted credentials over long-lived static keys
  (see [ci-cd.md](../platform/ci-cd.md) §OIDC).
- **In-cluster:** SOPS+age / Sealed Secrets / External Secrets Operator / Vault — never raw
  Secrets in manifests (see [devops.md](../platform/devops.md)).
- **Validate config at boot** and fail fast on missing/malformed secrets.

### Rotation: define it, don't just say it

"Rotate" is a verb with a number. The hierarchy, best to worst:

| Approach | Cadence | Mechanism |
|---|---|---|
| **Dynamic / short-lived** (preferred) | minutes–hours | Vault DB/cloud **leases**, cloud-managed rotation (RDS/Secrets Manager), **ESO** auto-refresh — app re-reads, no human |
| **Static secrets** (when unavoidable) | **≤ 90 days** | scheduled rotation job; tracked with an expiry/owner |
| **Any credential, on personnel change** | **immediate** | offboarding playbook revokes + rotates shared secrets the leaver could read |

**"Rotation in place" must be verifiable**, not assumed: emit a `last_rotated` timestamp/metric per
secret, **alert when it ages past policy**, and confirm the *old* value is **revoked at the provider**
(GitGuardian: ~80% of leaked secrets are never rotated — see §1). Rotating the store without
revoking the old credential isn't rotation.

## 8. Encryption (in transit + at rest)

Cross-cutting and non-optional. Defaults, with no exceptions list to maintain:

- **In transit:** **TLS 1.2 floor, 1.3 preferred**, everywhere — internal hops included; no plaintext
  on the wire. _(scale-up)_ **mTLS** for service-to-service (service mesh / SPIFFE) so identity is
  cryptographic, not network-position.
- **At rest:** **default-encrypt** every store — buckets, volumes, DBs, backups, queues. Use a
  **KMS customer-managed key (CMK)** with **envelope encryption** (KMS wraps per-resource data keys),
  not the provider's shared default key — CMK gives you rotation, revocation, and audit.
- **Key rotation:** enable **automatic CMK rotation** (annual minimum; cloud KMS does this
  transparently). TLS leaf certs short-lived + auto-renewed (cert-manager / ACME).
- **Field-level encryption** for the most sensitive fields (PII, tokens, secrets-in-DB) — encrypt
  the *value*, not just the disk, so a DB dump leaks ciphertext. Classification and which fields
  qualify live in [data-privacy.md](data-privacy.md).

## 9. Incident response & vulnerability management

The leak runbook (§1) covers *one* event class. This is the general security-IR process and the
**SLA that stops findings from rotting** — a scanner that gates with no remediation deadline just
generates a backlog.

### Security IR process

| Severity | Definition | Escalation | Comms |
|---|---|---|---|
| **SEV1** | active breach / data exfil / RCE in prod | page on-call + incident commander **now** | exec + legal; customer/regulator notice clock starts |
| **SEV2** | exploitable vuln, no confirmed exploitation | IC during business hours, fix this sprint | internal stakeholders |
| **SEV3** | contained / low-blast-radius | ticket, normal queue | team channel |

Flow: **detect → triage & assign severity → contain → eradicate → recover → blameless post-mortem**
with action items tracked to closure. Name the incident commander up front; keep a single comms
channel; preserve evidence before you clean up.

### Remediation SLA (clock starts at detection)

Prioritize by **CVSS + [EPSS](https://www.first.org/epss) (exploit *probability*) + [CISA KEV](https://www.cisa.gov/known-exploited-vulnerabilities-catalog) (known-exploited)** — **not CVSS alone**.
A CVSS 9.8 nobody is exploiting can wait behind a CVSS 7 that's KEV-listed.

| Class | Fix within | Trigger |
|---|---|---|
| **Critical / KEV-listed** | **48 h** | on CISA KEV, **or** Critical with high EPSS |
| **High** | **7 days** | CVSS High, exploit plausible |
| **Medium** | **30 days** | — |
| **Low** | **90 days** | — |

Wire the SLA into the scanner: findings carry a due date, **breaches alert**, and the gate
(§2/§3) is what enforces "no new findings past SLA." A finding with no deadline is a finding
that never gets fixed.

## Definition of done

- [ ] Secret scanning at commit (gitleaks) **and** push (platform) **and** scheduled (TruffleHog)
- [ ] Dependency scanning in CI per ecosystem; updates have a cooldown
- [ ] Lockfiles committed; CI fails on drift; lifecycle scripts allowlisted
- [ ] SAST on app code (CodeQL) **and** workflows (zizmor); **DAST (ZAP baseline)** scheduled vs. staging
- [ ] Shipped artifacts have SBOM + signed provenance; **SLSA target set** (L2 baseline / L3 release)
- [ ] Provenance/signatures **verified on consumption** (cosign/slsa-verifier, pinned identity) and at **K8s admission**
- [ ] Frontends: CSP + headers, XSS-sink ban, no leaked env/secrets/source-maps in `dist/`
- [ ] **Encryption** default-on: TLS ≥1.2 in transit, KMS-CMK at rest, field-level for sensitive data
- [ ] **Rotation defined**: dynamic-preferred, static ≤90 d, immediate on personnel change, age-alerted
- [ ] A written leak-response runbook (rotate-first) **and** a security-IR process with **remediation SLAs** (CVSS+EPSS+KEV)
