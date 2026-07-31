---
name: terraform-standards
description: "Use when writing or editing Terraform/OpenTofu IaC (.tf, .tofu, terragrunt.hcl), backend/state config, modules, or the plan/apply pipeline in a touchstone repo — covers OpenTofu-default toolchain, directory-per-env state, version pinning, the fmt→validate→lint→scan→policy→plan→gated-apply workflow, secrets, drift, and testing. Boundary: Kubernetes/GitOps/observability runtime concerns are devops-standards; CI wiring/OIDC is ci-cd-standards."
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Terraform / OpenTofu (IaC)

Full standard: **`standards/platform/terraform.md`** in the touchstone repo ([standards/platform/devops.md](../../standards/platform/devops.md)
summarizes IaC and defers the depth here). This skill inlines the load-bearing rules so it stays
useful even when installed standalone in `~/.claude/skills/`:

## Always
- **OpenTofu by default** (≥ 1.8); Terraform only as the documented escape hatch (HCP/TFC features).
- **Directory-per-env root modules**, each with its **own backend/state**; shared logic is a
  versioned child module, never copy-paste. CLI workspaces are for ephemeral previews only.
- **Remote state, native locking** (`use_lockfile`, not DynamoDB), bucket KMS + versioning **and**
  OpenTofu state encryption. Segment state per env/component; never commit it.
- **Pin providers/modules; commit `.terraform.lock.hcl`** with multi-platform hashes.
- **CI is the only thing that mutates infra** — `fmt -check` → `validate` → `tflint` →
  **scan (Checkov/`trivy config`)** → **policy (Conftest/OPA)** → **plan-on-PR** → **gated apply**
  (applies the saved plan). **Never `apply` from a laptop**; CI auth via **OIDC**, not static keys.

## Don't get burned
- **`sensitive = true` redacts logs, it does NOT encrypt state** — secrets in `.tf`/`.tfvars`/state
  are leaked. Fetch via data sources (Secrets Manager/Vault) or `TF_VAR_*`; prefer not materializing.
- **State holds plaintext secrets** — least-privilege the backend bucket; treat state as a secret.
- **GitOps selfHeal doesn't cover Terraform** — run a scheduled `plan -detailed-exitcode` and alert
  on drift _(scale-up)_; reconcile via PR.
- **Don't over-abstract** — module on the second copy, not the first; **Terragrunt** only when
  env boilerplate is real duplication _(scale-up)_.

## Done
OpenTofu default · directory-per-env own-state, no copy-paste · remote state locked+encrypted, segmented, lockfile committed · CI fmt/validate/tflint/scan/policy/plan-on-PR + gated apply, OIDC, no laptop apply · secrets out of `.tf`/`.tfvars`/state · drift alerts + `tofu test`/Terratest _(scale-up)_. See `standards/platform/terraform.md`.
