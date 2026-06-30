# Templates

Ready-to-copy config files that implement the [standards](../standards/README.md). Copy the ones
your stack needs into the target repo (paths noted in each file's header) and tune the
placeholders.

| File | Drop in as | Standard |
|---|---|---|
| `biome.json` | `biome.json` | [typescript.md](../standards/languages/typescript.md) |
| `golangci.yml` | `.golangci.yml` | [golang.md](../standards/languages/golang.md) |
| `pyproject-snippet.toml` | merge into `pyproject.toml` | [python.md](../standards/languages/python.md) |
| `pre-commit-config.yaml` | `.pre-commit-config.yaml` | [ci-cd.md](../standards/platform/ci-cd.md) · [security.md](../standards/practices/security.md) |
| `dockerignore` | `.dockerignore` (per context root) | [docker.md](../standards/platform/docker.md) |
| `justfile` | `justfile` | [collaboration.md](../standards/practices/collaboration.md) |
| `dependabot.yml` | `.github/dependabot.yml` | [security.md](../standards/practices/security.md) |
| `github/CODEOWNERS` | `.github/CODEOWNERS` | [ci-cd.md](../standards/platform/ci-cd.md) |
| `github/pull_request_template.md` | `.github/PULL_REQUEST_TEMPLATE.md` | [collaboration.md](../standards/practices/collaboration.md) |
| `github/ISSUE_TEMPLATE/*` | `.github/ISSUE_TEMPLATE/` | [collaboration.md](../standards/practices/collaboration.md) |
| `github/workflows/ci.yml` | `.github/workflows/ci.yml` | [ci-cd.md](../standards/platform/ci-cd.md) |
| `github/workflows/codeql.yml` | `.github/workflows/codeql.yml` | [security.md](../standards/practices/security.md) |
| `github/workflows/release-please.yml` | `.github/workflows/release-please.yml` | [ci-cd.md](../standards/platform/ci-cd.md) |
| `dependabot.yml` / `renovate.json` | `.github/` | [dependencies.md](../standards/practices/dependencies.md) |
| `SECURITY.md` | `SECURITY.md` | [security.md](../standards/practices/security.md) |
| `adr-0000-template.md` | `docs/adr/NNNN-*.md` | [collaboration.md](../standards/practices/collaboration.md) |
| `nvmrc` / `python-version` | `.nvmrc` / `.python-version` | [dependencies.md](../standards/practices/dependencies.md) |

Also copy the repo-root [`.editorconfig`](../.editorconfig) and [`.gitattributes`](../.gitattributes)
from this kit — they're universal.

## Authoring templates (for contributing to the kit itself)

Skeletons that keep every doc/skill/script in one format — see
[CONTRIBUTING.md](../CONTRIBUTING.md#authoring-conventions).

| File | Use for |
|---|---|
| `standard.md` | a new `standards/<domain>/<file>.md` |
| `SKILL.md` | a new `skills/<name>/SKILL.md` |
| `script-header.sh` | the header of a new `scripts/*.sh` |

> Pin tool versions (hook `rev`s, action SHAs) and keep them current with Dependabot/Renovate +
> `pre-commit autoupdate`. The versions here are starting points, not gospel.
