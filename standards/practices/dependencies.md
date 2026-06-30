# Package Managers & Dependency Policy

How dependencies are chosen, pinned, and kept current across ecosystems. This doc owns
package-manager choice and version policy; supply-chain *scanning*, SBOM, and signing live in
[security.md](security.md) — this doc links there rather than restating it.

---

## 1. One manager per ecosystem — no exceptions

| Ecosystem | Manager | Lockfile (committed) | CI install |
|---|---|---|---|
| Python | **uv** | `uv.lock` | `uv sync --locked` |
| Node | **pnpm** | `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| Go | **go modules** | `go.sum` | `go mod download` (build `-mod=readonly`) |

- **Never** use `pip`, `poetry`, `pipenv`, `conda`, `npm`, or `yarn`. Mixing managers
  corrupts the lockfile and breaks reproducibility.
- Add/remove deps through the manager so the manifest **and** lockfile update together, and
  commit both in the same change:

  ```bash
  uv add <pkg>          uv add --dev <pkg>          uv remove <pkg>
  pnpm add <pkg>        pnpm add -D <pkg>           pnpm remove <pkg>
  ```

- Lockfiles are the contract. CI installs frozen; if the lockfile is out of date the build
  fails — regenerate it locally and commit, don't loosen CI.

## 2. Use the latest stable versions — and stay current

**Outdated dependencies are a security liability.** The policy is to run **current, stable**
releases and to keep moving:

- New dependencies: add the **latest stable** version. Avoid pre-releases unless there's a
  concrete reason (write it down in the PR).
- Existing dependencies: bump regularly. Don't let majors fall years behind — small, frequent
  upgrades are far cheaper and safer than a big-bang migration later.
- Track the **current** language/runtime release (active LTS where applicable) rather than an
  old one for inertia's sake.
- Treat published advisories (CVEs / GHSAs) as **priority work**, not backlog.
- Before merging an upgrade, the gates must pass (lint, type-check, tests, build) and any
  container images must still build.

### Checking for outdated / vulnerable packages

```bash
# Python
uv lock --upgrade            # bump the lockfile to latest allowed
uv pip list --outdated       # see what's behind

# Node
pnpm outdated                # see what's behind
pnpm update --latest         # bump (review the diff!)
pnpm audit                   # known advisories in the dependency tree

# Go
go list -u -m all            # see what's behind
govulncheck ./...            # reachable vulnerabilities
```

## 3. Pinning vs. ranges

- **Application dependencies:** caret/compatible ranges in the manifest are fine **because
  the lockfile pins exact versions** — the lockfile is what gets installed.
- **Tools whose output gates CI** (formatters/linters — e.g. Biome) are **pinned to an exact
  version** so a background upgrade can't suddenly reformat the world and break CI. Bump them
  deliberately in their own PR.
- **Docker base images & GitHub Actions:** pin by **digest / commit SHA** as the default (tags
  are mutable). See [docker.md](../platform/docker.md) and [ci-cd.md](../platform/ci-cd.md).
- **Lockfile is law in CI:** fail on drift (`uv lock --check`, `pnpm install --frozen-lockfile`,
  `go mod tidy` diff-check). Keep dependency **lifecycle scripts** allowlisted (pnpm blocks them
  by default) so a compromised `postinstall` can't run.

## 4. Recommended automation

- A scheduled dependency updater — **Dependabot** is the default (template:
  `templates/dependabot.yml`); reach for **Renovate** (`templates/renovate.json`) when you need
  its richer grouping/scheduling — opening grouped upgrade PRs across the package managers,
  GitHub Actions, and Docker base images, configured with a **cooldown** (`minimumReleaseAge`)
  so freshly-published (possibly malicious) versions don't auto-merge; CVE patches bypass it.
- **Vulnerability scanning** per ecosystem and on built images — see [security.md](security.md)
  §2 for the full matrix (pip-audit / pnpm audit / govulncheck / Trivy) and SBOM/provenance.

These make "stay current" automatic rather than manual — adopt them per repo as capacity allows.

## 5. Shared quality-gate defaults

So gates stay auditable (a number, not a vibe), the kit's canonical defaults — referenced by
the per-stack docs and `self-audit.md`:

- **Test coverage floor:** **80% line / 60% branch**, enforced in CI and ratcheted upward; never
  target 100% (it rewards testing trivia). New code should not lower the floor.
- **Lint/format:** zero errors; CI runs the format-check, not just the linter.
- **Type-check:** zero new errors on the touched surface.

Projects may raise these; they may only lower them with a documented, reviewed waiver.

## Definition of done

- [ ] One manager per ecosystem; manifest **and** lockfile committed together; CI installs frozen and fails on drift
- [ ] New deps at latest stable; published advisories triaged as priority work
- [ ] CI-gating tools pinned to an exact version; base images / Actions pinned by digest/SHA; lifecycle scripts allowlisted
- [ ] Scheduled updater (Dependabot by default) with a release **cooldown** configured
