---
name: devops-standards
description: Use when writing or editing infrastructure-as-code (Terraform/OpenTofu), Kubernetes manifests, GitOps/Argo/Flux config, Helm/Kustomize, deployment pipelines, or observability/SRE setup in a repo that follows touchstone. Invoke before changing how a service is deployed or run.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# DevOps / Platform / SRE Standards

Full standard: **`standards/platform/devops.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **One IaC tool** (OpenTofu/Terraform) with **remote state locked + encrypted** (S3 `use_lockfile`, not DynamoDB); pin providers/modules + commit the lock. **Secrets never in state/tfvars** (`sensitive` only redacts logs).
- **Kubernetes: set CPU+memory requests**; harden `securityContext` (runAsNonRoot, readOnlyRootFilesystem, drop ALL, seccomp) + namespace **PSA `restricted`**; pin images by digest.
- **GitOps** (Argo CD/Flux): promotion = a PR, prod gated; **DB migrations are N-1 / expand-contract**.
- **No plaintext secrets** (ESO/SOPS/Vault) + rotation; **OIDC, not static cloud keys**.

## Infra as Code
- CI: fmt → validate → tflint → **scan (Checkov/`trivy config`)** → plan-on-PR → **gated apply**.
- **Directory-per-env**, shared modules. Workspaces are for ephemeral previews only.

## Kubernetes
- **No CPU limit** on latency-sensitive svcs; **memory limit = request**.
- Probes: **never check external deps in liveness**; startup probe for slow boots. Lint with **kubeconform + kube-linter**.

## Deploy & observe
- Decouple deploy/release with feature flags.
- Observability: Prometheus + **OTel** + structured correlated logs; **alert on SLO burn-rate, not raw CPU**.

Items tagged _(scale-up)_ in the doc are for real production scale — adopt as you grow.

## Done
IaC fmt/validate/scan/plan green, apply gated · state encrypted, no secrets in state · k8s requests set + `securityContext` hardened + images digest-pinned · GitOps promotion via PR · OIDC + ESO/SOPS/Vault secrets · SLO burn-rate alerts. See `standards/platform/devops.md`.
