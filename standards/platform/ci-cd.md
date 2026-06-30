# CI/CD & Pipeline Standards

How we build, gate, and release. Examples use GitHub Actions; the principles port to any CI.
Security controls that *run* here are detailed in [security.md](../practices/security.md).

---

## 1. The pipeline gates (per stack)

Every PR must pass, before merge:

| Stack | Gates |
|---|---|
| Python | `ruff check` · `ruff format --check` · type-check · `pytest` (+ coverage floor) · `pip-audit` |
| TS/React | `biome ci` · `tsc --noEmit` · `vitest run --coverage` · `vite build` |
| Go | `gofumpt -l` (diff) · `golangci-lint run` · `go test -race -cover` · `govulncheck` |
| Containers | `hadolint` · image build · `trivy` scan |
| Workflows | `zizmor` (lint the CI itself) |

Install **frozen** (`uv sync --locked`, `pnpm install --frozen-lockfile`, `go mod download`);
cancel superseded runs with a `concurrency` group.

## 2. Caching correctness

A stale cache hit can **mask dependency drift** — the job reports green but isn't testing what's
actually installed. Cache semantics people get wrong:

- `actions/cache` is **not** shared from the base branch into PRs; each PR gets its own cache
  scope. A cold PR cache is normal and expected, not a performance bug.
- A partial `restore-keys` match may load a cache built with *different* dependencies. The job
  still runs, but the environment is wrong. Treat `restore-keys` hits as a warm-start, not a
  guarantee.

### Canonical key pattern
```yaml
- uses: actions/cache@<sha>
  with:
    path: ~/.cache/pip              # or node_modules, ~/.cargo, etc.
    key: ${{ runner.os }}-deps-${{ hashFiles('**/requirements.lock') }}
    restore-keys: |
      ${{ runner.os }}-deps-
```

Rules:
- **Always hash the exact lockfile** (`**/package-lock.json`, `**/uv.lock`, `**/go.sum`, etc.) —
  never hash loose manifest files (`package.json`, `pyproject.toml`).
- **Include `runner.os`** (and arch when cross-compiling, e.g. `${{ runner.arch }}`).
- **Use the toolchain's own cache input first** — `setup-node` `cache: npm`, `setup-go`
  `cache: true`, etc. Only reach for bare `actions/cache` when the setup action lacks native
  support.
- **Differentiate PR vs. release** with a key prefix (`pr-` / `release-`) to prevent untrusted
  PR caches from warming release jobs.

_These rules are a performance concern, but also a supply-chain hygiene concern: a poisoned cache
entry can substitute a dependency silently. See [security.md](../practices/security.md)._

## 3. Monorepo CI

Path-filtered triggers avoid running the full suite when unrelated directories change.

### Trigger filtering
```yaml
on:
  push:
    paths:
      - 'packages/api/**'
      - 'packages/shared/**'
  pull_request:
    paths:
      - 'packages/api/**'
```

Or use `dorny/paths-filter` for more expressive per-job conditions (generates output booleans
checked in `if:` expressions on downstream jobs).

### Selective builds

| Tool | Mechanism |
|---|---|
| **Nx** | `nx affected --base=origin/main` — graph-aware, caches task outputs |
| **Turborepo** | `turbo run build --filter=[HEAD^1]` — pipeline cache via remote cache |
| **Bazel** | `bazel build //... --build_tag_filters=changed` — hermetic, content-addressed |

Pick one and pin it. Mix only at the cost of two mental models.

### Why the `ci-required` aggregator is monorepo-safe

A *skipped* required job reports **neutral** (not "success" and not "failure"). GitHub's branch
protection evaluates neutral as passing — meaning a path-filtered job that was skipped would
silently un-gate the PR if required directly.

The `ci-required` aggregator (§4) gates on `contains(needs.*.result, 'failure') ||
contains(needs.*.result, 'cancelled')` — **skipped legs pass through cleanly** because "skipped"
is neither failure nor cancelled. Require only the single aggregator check in branch protection;
never require individual matrix legs or path-filtered jobs directly.

## 4. GitHub Actions hardening (non-negotiable)

The 2025 `tj-actions/changed-files` compromise (CVE-2025-30066) leaked secrets from 23,000+
repos by retroactively moving version tags to malicious commits. **Hash-pinned consumers were
unaffected.** Apply all of:

### Pin every action to a full commit SHA
```yaml
- uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
```
Maintain pins with `pinact run` (and `pinact run --check` as a gate); let Dependabot
(`package-ecosystem: github-actions`) bump them. Never `@v4`/`@main`.

### Least-privilege `GITHUB_TOKEN`
```yaml
permissions:
  contents: read          # top-level floor; everything else → none
jobs:
  release:
    permissions:          # elevate per-job, only what's needed
      contents: write
      id-token: write
```

### Harden checkout & runner
```yaml
- uses: step-security/harden-runner@<sha>   # v2
  with:
    egress-policy: block                    # production workflows: block + allowlist
    allowed-endpoints: >                    # enumerate what the job legitimately calls
      api.github.com:443
      objects.githubusercontent.com:443
      pypi.org:443
# During initial rollout only — switch to block once allowlist is known:
#   egress-policy: audit
- uses: actions/checkout@<sha>
  with: { persist-credentials: false }      # don't leave the token in .git/config
```

`egress-policy: audit` is **monitoring, not a control** — an exfiltration attempt still succeeds.
Use `block` with an explicit `allowed-endpoints` allowlist for all production-touching workflows.
`audit` is acceptable only during the rollout window while building the allowlist.

### One stable required-status check (not matrix legs)
Branch protection matches checks by exact name; require a single aggregator so renamed/added
matrix legs can't silently un-gate (a skipped required job reports "success"):
```yaml
ci-required:
  needs: [test, lint]
  if: ${{ always() }}
  runs-on: ubuntu-latest
  steps:
    - if: ${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}
      run: exit 1
```

### Cache-poisoning hygiene
Actions cache is global to a repo and not trust-segregated. Prefer `pull_request` over
`pull_request_target`; never checkout+execute untrusted fork code in a privileged job; use
distinct cache-key prefixes for PR vs release. `zizmor` flags these automatically.

## 5. Cloud auth: OIDC, not long-lived keys

Mint short-lived credentials per run instead of storing static cloud keys:
```yaml
permissions: { id-token: write, contents: read }
steps:
  - uses: aws-actions/configure-aws-credentials@<sha> # v4
    with: { role-to-assume: arn:aws:iam::…:role/gha-deploy, aws-region: us-east-1 }
```
Pin the IAM trust policy's `sub` to `repo:org/repo:ref:refs/heads/main` — never leave it
unconstrained. (GCP: Workload Identity Federation; Azure: federated credentials.)

## 6. SAST in the pipeline

- **CodeQL** on PRs (app code) — `github/codeql-action` init+analyze, `security-events: write`.
- **zizmor** on the workflows — `uvx zizmor --format sarif . > results.sarif` → upload SARIF.
- **dependency-review-action** on PRs — blocks newly-introduced vulnerable/bad-license deps.

See [security.md](../practices/security.md) for rationale; these are the CI wiring.

## 7. Pre-merge hooks: pre-commit (+ pre-commit.ci)

One `.pre-commit-config.yaml` runs the same hooks locally and in CI, so they never drift.
Hosted **pre-commit.ci** auto-fixes formatting on PRs and auto-updates hook versions:
```yaml
ci: { autofix_prs: true, autoupdate_schedule: weekly }
```
Run `pre-commit run --all-files` as a CI job regardless (hooks can be skipped with `--no-verify`).

### Runtime enforcement: agent hooks

Pre-commit catches problems at *commit* time — but an AI agent edits files and runs commands long
before that. Re-enforce the standards at the **agent** layer with opt-in Claude Code hooks
(`hooks/` → `.claude/settings.json`): inject the hard rules at session start, **deny**
`--no-verify` / bare `--force` and secret writes (PreToolUse), format on edit (PostToolUse), and
nudge `just ci` on stop. All **fail-open** so they never wedge a session; they *delegate* to the
same formatters/gates (no duplicate logic). See [`hooks/README.md`](../../hooks/README.md).

## 8. Branch protection (Repository Rulesets) + CODEOWNERS

Commit a ruleset for the default branch enforcing: required status check (the aggregator),
required PR review (≥1, code-owner), linear history, no force-push/deletion, optionally signed
commits. Route reviews with `CODEOWNERS` keyed to **teams, not individuals**, with a catch-all
fallback (`* @org/core-team`). Validate CODEOWNERS — invalid lines are silently ignored.

## 9. GitHub Environments + artifact promotion

Build the artifact **once**; promote the same digest through environments. Never rebuild per
environment — a different build is a different artifact, which voids any test that ran on the
prior build. This enforces [devops.md](devops.md)'s "same image everywhere" contract.

### Environment configuration (in repository Settings → Environments)

| Setting | Value |
|---|---|
| Required reviewers | ≥1 for `staging` / `production` |
| Wait timer | Optional delay (e.g., 5 min) for `production` to allow abort |
| Deployment branch policy | Tag pattern (`v*`) for `production`; `main` for `staging` |
| Environment secrets | Scope secrets here, not at repo level, so they're only accessible when a deployment targets that environment |

### Promotion pattern
```yaml
jobs:
  build:
    outputs:
      image-digest: ${{ steps.push.outputs.digest }}
    steps:
      - id: push
        run: echo "digest=$(docker inspect --format='{{index .RepoDigests 0}}' …)" >> $GITHUB_OUTPUT

  deploy-staging:
    needs: build
    environment: staging
    steps:
      - run: deploy ${{ needs.build.outputs.image-digest }}   # same digest

  deploy-production:
    needs: [build, deploy-staging]
    environment: production
    steps:
      - run: deploy ${{ needs.build.outputs.image-digest }}   # still the same digest
```

Environment secrets (e.g. `PROD_DEPLOY_KEY`) are injected only when the job targets that
environment — they never surface in the `build` or test jobs.

## 10. Self-hosted runner security _(scale-up)_

Self-hosted runners unlock larger machines and custom toolchains, but introduce supply-chain
risk: a compromised job runs code on your infrastructure.

**Non-negotiables for self-hosted runners:**

- **Ephemeral / just-in-time only.** Use [Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller)
  or `config.sh --ephemeral`. Each job gets a fresh VM/container; state never persists between
  jobs. Long-lived runners accumulate tampered state across jobs.
- **Never run fork PRs on self-hosted runners.** `pull_request` from a fork has limited
  `GITHUB_TOKEN` privileges, but still runs arbitrary code on your host. Restrict to
  `pull_request_target` + an `if: github.event.pull_request.head.repo.full_name == github.repository`
  guard, or route fork PRs exclusively to GitHub-hosted runners.
- **Isolated network.** Runners should not have access to production databases or internal APIs.
  Enforce via network segmentation; validate with Harden-Runner egress blocking (§4 hardening).
- **Least-privilege IAM.** The runner's cloud identity (instance profile / workload identity)
  should have only the permissions needed by the jobs it runs — not broad admin. Separate runner
  IAM roles per environment.
- **No long-lived secrets on the host.** All secrets via GitHub Environments or OIDC-minted
  credentials (§5). Secrets baked into an AMI or mounted volume survive host compromise.

## 11. Release automation

Derive releases from Conventional Commits — no manual version ceremony, but keep a human
merge-gate:
- **release-please** (default, language-agnostic via `release-type: simple`) maintains a
  standing release PR that bumps version, updates `CHANGELOG.md`, tags, and cuts a release on
  merge.
- **changesets** for JS monorepos (per-PR intent files, fine-grained bumps).
- Enforce commit format with **commitlint** (`commit-msg` hook + CI) so the release tool gets
  clean input.

## Definition of done

- [ ] All stack gates run on every PR; install is frozen; concurrency cancels stale runs
- [ ] Every action pinned to a SHA; `permissions:` is least-privilege
- [ ] `persist-credentials: false`; Harden-Runner present with `egress-policy: block` + `allowed-endpoints` on all production-touching workflows (`audit` only during rollout)
- [ ] Cache keys hash the exact lockfile; include `runner.os`; PR and release caches use distinct prefixes
- [ ] One stable required-check aggregator gates the branch (individual matrix/path-filtered legs not required directly)
- [ ] Monorepo: path-filtered triggers + affected-graph builds wired; aggregator is the sole branch-protection check
- [ ] Artifact built once; same digest promoted through Environments (never rebuilt per-env); Environments have required reviewers + deployment-branch policy
- [ ] Cloud auth via OIDC (no long-lived keys); IAM trust `sub` pinned to branch/tag
- [ ] CodeQL + zizmor + dependency-review wired
- [ ] Branch protection ruleset + CODEOWNERS in place
- [ ] Self-hosted runners (if used): ephemeral-only, fork PRs routed to GitHub-hosted, isolated network, least-privilege IAM, no host-resident secrets
- [ ] Releases automated from Conventional Commits (release-please) with a changelog
