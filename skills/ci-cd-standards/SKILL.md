---
name: ci-cd-standards
description: Use when writing or editing CI/CD pipelines, GitHub Actions workflows (.github/workflows/**), dependabot/renovate config, release automation, or branch-protection/rulesets in a repo that follows touchstone. Invoke before changing how the project builds, gates, or releases.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# CI/CD & Pipeline Standards

Full standards: **`standards/platform/ci-cd.md`** and **`standards/practices/dependencies.md`** in the touchstone repo.
This skill inlines the load-bearing rules so it stays useful when installed standalone:

## Always
- **Pin every action to a full commit SHA** (`uses: org/action@<sha> # vX`) — never `@v4`/`@main`.
  The 2025 tj-actions compromise leaked secrets from 23k+ repos; SHA-pinned consumers were safe.
  Maintain with `pinact` (+ `pinact run --check` gate) and Dependabot `github-actions`.
- **Least-privilege `GITHUB_TOKEN`:** top-level `permissions: { contents: read }`, elevate per-job;
  `persist-credentials: false` on checkout; add **Harden-Runner** (`egress-policy: block` in prod).
- **One stable required-status-check aggregator** — branch protection matches by name, and a
  skipped required job reports "success". Gate on `result != failure && != cancelled`.
- **OIDC for cloud auth**, never long-lived keys (pin trust-policy `sub` to repo/ref).

## Gates & release
- Run every stack's gates frozen (`uv sync --locked`, `pnpm install --frozen-lockfile`); `concurrency` cancels stale runs.
- **CodeQL** (app) + **zizmor** (workflows) + **dependency-review** on PRs.
- Releases from Conventional Commits via **release-please** (+ commitlint); CHANGELOG generated.
- Dependency updates via Dependabot/Renovate **with a cooldown**; CVE fixes bypass it.
- Prefer `pull_request` over `pull_request_target`; distinct cache-key prefixes (PR vs release).

## Done
Actions SHA-pinned · least-privilege `permissions:` · aggregator required-check · OIDC · CodeQL+zizmor+dependency-review wired. See `standards/platform/ci-cd.md`.
