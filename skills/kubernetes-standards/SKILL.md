---
name: kubernetes-standards
description: "Use when authoring or editing Kubernetes manifests, Helm charts, kustomization.yaml, or any *.yaml with a `kind:` (Deployment/StatefulSet/Job/Service/Ingress/NetworkPolicy) in a touchstone repo — covers workloads, resources, probes, securityContext, networking, scaling, rollouts, and policy/lint. Triggers on k8s manifests, Helm/Kustomize, HPA/PDB, and admission policy. Boundary: image build is docker-standards, IaC/GitOps/SRE is devops-standards, telemetry is observability-standards, supply-chain/signing is security-standards."
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Kubernetes (platform)

Full standard: **`standards/platform/kubernetes.md`** in the touchstone repo (the canonical k8s depth;
`standards/platform/devops.md` summarises and defers here). This skill inlines the load-bearing
rules so it stays useful when installed standalone in `~/.claude/skills/`:

## Always
- **Requests always set; NO CPU limit on latency-sensitive svcs; memory limit = request** — CPU is compressible (a limit throttles you below idle for no gain), memory is not (over-request → OOMKill).
- **Liveness probe is dependency-free** — never ping a DB/downstream, or one dep outage restarts every pod. Readiness gates traffic and *does* check deps; startup probe for slow boots (not a giant `initialDelaySeconds`).
- **Harden every pod**: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault` — and label the namespace **PSA `enforce: restricted`** (PodSecurityPolicy is gone since 1.25).
- **Images digest-pinned** (`@sha256:…`, never `:latest`), signatures **verified at admission** (Kyverno `verifyImages`).
- **No plaintext Secrets in git** — base64 is encoding, not encryption. Use ESO / SOPS+age / Sealed Secrets / Vault + rotation; ConfigMaps for non-secret config (roll pods on change).

## Don't get burned
- **Default-deny NetworkPolicy per namespace** — pods are flat-reachable by default; deny ingress+egress, then **always allow DNS egress** or everything breaks.
- **PDB sized against rollout surge**: `replicas − maxUnavailable ≥ minAvailable`; spread replicas across zones (`topologySpreadConstraints`). Never run HPA and VPA on the same metric — they oscillate (VPA recommender-only).
- **HPA on SLO/custom metrics, not raw CPU**; rollouts are `RollingUpdate` surge-bounded + readiness-gated; DB migrations N-1 / expand-contract (two versions run at once).
- **StatefulSet only for real stable-identity/ordered/per-PVC workloads** — Deployment is the default; prefer a managed datastore over self-hosting.
- Pick **Helm** (third-party / `helm rollback`) xor **Kustomize** (your own app, base+overlays) — don't blur them.

## Done
Correct workload kind · requests set (no CPU limit, mem limit = request) · liveness dependency-free, readiness/startup right · `securityContext` hardened + namespace PSA `restricted` · images digest-pinned + verified at admission · no plaintext Secrets (ESO/SOPS/Vault) · default-deny NetworkPolicy (+DNS) · HPA on SLO metrics + PDB + topology spread · rollouts surge-bounded/readiness-gated, migrations N-1 · CI gate **kubeconform -strict + kube-linter + server dry-run** + Kyverno/Gatekeeper Enforce · namespace-per-tenant RBAC/quota · metrics scraped, JSON logs, SLO burn-rate alerts. See `standards/platform/kubernetes.md`.
