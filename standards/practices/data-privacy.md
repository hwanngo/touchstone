# Data Privacy & PII Compliance

> Not legal advice. Loop in counsel before launching in regulated industries, handling health/financial data, or reaching scale-up. This doc covers baseline engineering hygiene that applies to virtually every product.

---

## 1. Data Classification

| Class | Examples | Default handling |
|---|---|---|
| **Public** | Marketing copy, open API docs | No restrictions |
| **Internal** | Metrics, logs (scrubbed), internal IDs | Access-controlled, encrypted in transit |
| **Confidential** | Business logic, pricing, credentials | Encrypted at rest + in transit; [security.md](security.md) |
| **PII** | Name, email, IP, device ID, location | Minimized, retention-capped, erasable |
| **Sensitive / special-category** | Health, biometric, financial, political/religious | Field-level encryption, explicit consent, DPA required |

**Maintain a lightweight data inventory** — a living doc or spreadsheet listing what PII you collect, where it's stored (DB table/field, S3 bucket, third-party), who owns it, and its retention class. Update it at every new data-collection point.

---

## 2. Data Minimization

- Collect **only what you need** for the stated purpose. Challenge every new field in a schema PR.
- No optional "nice to have" PII collection without a clear retention and deletion plan.
- Prefer **pseudonymized** internal IDs (UUID → email mapping isolated to one service) over passing raw PII across services.
- Analytics/telemetry should receive **aggregate or anonymized** data only — never raw user events with identifiers.

---

## 3. Retention & Deletion

### 3.1 Default retention limits

| Class | Default max retention |
|---|---|
| PII (active accounts) | Duration of account + 30 days post-deletion |
| PII (inactive / churned) | 12 months from last activity, then delete |
| Sensitive/special-category | 90 days unless legally required longer |
| Logs (scrubbed) | 90 days hot, 1 year cold; see [devops.md](../platform/devops.md) |
| Backups containing PII | Follow backup rotation schedule; PII subject to same deletion SLA |

### 3.2 Right to erasure (GDPR Art. 17 / CCPA)

Design deletion to **actually cascade**:

```text
DELETE user → cascade to:
  ├── application DB (all foreign-keyed rows)
  ├── derived/aggregate tables (re-aggregate or null out)
  ├── search indexes
  ├── object storage (S3 prefix by user ID)
  ├── caches (Redis TTL or explicit evict)
  ├── audit logs → anonymize, do not delete (legal hold carve-out)
  └── backups → mark for purge on next rotation; document lag in SLA
```

- **Anonymization vs pseudonymization**: anonymized data is irreversibly stripped of all identifiers and no longer PII under GDPR. Pseudonymized data (e.g., hashed email) is still PII — re-identification is possible. Do not claim anonymization unless you can prove it withstands re-identification attacks.
- Honor erasure requests within **30 days** (GDPR) / **45 days** (CCPA). Automate where possible; manual steps must be tracked.
- Log the erasure event (without the PII) for compliance evidence.

---

## 4. PII in Logs, Telemetry & LLM Prompts — BANNED

**Zero-tolerance rule**: PII must never appear in:

- Application logs or structured log payloads
- Error messages returned to clients or stored in alerting systems
- Analytics events (Segment, Amplitude, Mixpanel, etc.)
- Distributed traces (Jaeger, Datadog APM spans)
- URLs / query strings (user IDs in paths are acceptable; emails, tokens, names are not)
- LLM prompts or completions sent to third-party model providers

**Scrub at the logging boundary**, not ad-hoc downstream:

```python
# BAD
logger.info(f"Password reset requested for {user.email}")

# GOOD
logger.info("Password reset requested", extra={"user_id": user.id})
```

Use a log-scrubbing middleware / structured-log wrapper that strips known PII fields before emission. See structured-logging conventions in [devops.md](../platform/devops.md) and input validation rules in [app-security.md](app-security.md).

---

## 5. Encryption

Encryption *mechanisms* — TLS floors, at-rest/KMS, envelope encryption, key rotation — are owned by
[security.md](security.md) §8. This section says only **what privacy classification requires be
encrypted**:

- **Special-category / sensitive PII** (health, financial, government IDs, precise location,
  credentials) gets **field-level (application-layer) encryption**, not just disk encryption — so a
  DB dump or stolen backup leaks ciphertext, not plaintext. Which fields qualify is set by the
  classification in §1.
- Everything classified **Confidential or above** is encrypted in transit and at rest by default,
  and **backups inherit the same standard** as the primary store.
- Pseudonymized data is still personal data — encrypt it per its re-identification risk.

---

## 6. Access Control

- **Least privilege**: production PII access requires explicit role grant, not default dev access.
- PII-containing tables should have column-level or row-level security where the DB supports it.
- Rotate access tokens; no long-lived personal credentials with PII read access.
- _(scale-up)_ Implement access audit logging: who queried PII data, when, and why (break-glass workflows). Alert on bulk exports or unusual access patterns.

### DSAR (Data Subject Access Requests)

1. Verify identity before returning data.
2. Respond within 30 days (GDPR) / 45 days (CCPA).
3. Include: all data held, processing purposes, third parties shared with.
4. Maintain a DSAR request log (without the response payload).

---

## 7. Vendors, Transfers & Breach Response

### Subprocessors & DPAs

- Every third-party that processes your users' PII requires a **Data Processing Agreement (DPA)**. This includes analytics, error tracking, email, CRM, LLM providers, and cloud infra.
- Know which country/region each subprocessor stores data in. EU-origin data transferred outside the EEA requires SCCs or adequacy decisions.
- Maintain a subprocessor list. Notify users when it materially changes (required under many DPAs).

### Data Residency

- Default: document where data is stored; don't let it drift to unexpected regions via replication or CDN edge caching.
- _(scale-up)_ Enterprise customers often require region-pinned deployments. Design storage with tenant-level region config early.

### Breach Response

A breach involving PII triggers notification obligations (72 hours under GDPR; "expedient" under CCPA). Your incident response runbook and the leak detection checklist live in [security.md](security.md). At minimum:

1. Contain and assess scope.
2. Notify counsel and DPO (if appointed) immediately.
3. File regulator notification within the jurisdiction SLA.
4. Notify affected users per legal guidance.

---

## Definition of done

- [ ] Data inventory exists and covers all PII fields and their storage locations
- [ ] Every new schema PR documents the data class of new fields
- [ ] Scrubbing middleware blocks PII from reaching logs, traces, and analytics
- [ ] Deletion cascade is tested: deleting a user record triggers verified cleanup across all stores
- [ ] Erasure SLA documented (≤30 days) and a manual or automated workflow exists to honor it
- [ ] Backup rotation policy explicitly accounts for PII deletion lag
- [ ] Field-level encryption applied to all sensitive/special-category fields
- [ ] KMS key rotation configured per [security.md](security.md)
- [ ] DPA on file for every active subprocessor that touches PII
- [ ] DSAR process documented and assigned to an owner
- [ ] Breach response runbook in [security.md](security.md) reviewed by at least one engineer and counsel
- [ ] _(scale-up)_ Access audit logging enabled on PII tables with alerting on anomalous queries
