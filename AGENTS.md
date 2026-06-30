# AGENTS.md — instructions for AI coding agents

Tool-agnostic guidance for any AI assistant (Claude Code, Codex, Cursor, Copilot, Gemini, …)
working in a repo that follows **touchstone**. Humans: see [`standards/`](standards/README.md).

> **The canonical standards live in [`standards/`](standards/README.md). Read the relevant one
> before changing code.** This file is a summary, not a replacement.

## Project

<!-- Fill in per repo: -->
- **Name:** _<project name>_
- **What it is:** _<one-line description>_
- **Stack:** _<e.g. Go service + React/TypeScript frontend, containerised, deployed on K8s>_

## Hard rules (do not violate)

1. **Python → `uv`. Node → `pnpm`. Go → modules.** Never `pip`/`npm`/`yarn`. Commit lockfiles.
2. **Format + lint with the standard tool and let CI enforce it:** ruff (Python), Biome (TS),
   gofumpt + golangci-lint (Go).
3. **Type-check** (Pyright/mypy · `tsc` · the Go compiler) and keep it green.
4. **Tests self-skip when fixtures are absent** — never hard-fail on missing seed/sample data
   (CI runs on a clean checkout). Run with the race detector for Go.
5. **Don't "clean up" intentional re-export/facade imports** — they're encoded as lint ignores;
   removing them breaks consumers.
6. **Containers:** small current base images (slim/alpine/distroless), multi-stage, non-root,
   digest-pinned. Keep any PWA (manifest + service worker) working.
7. **Use the latest stable dependency versions**; treat advisories as priority work.
8. **CI is hardened:** pin Actions to SHA, least-privilege `permissions:`, OIDC over static keys.
9. **Never commit** secrets, generated artifacts, per-developer AI-assistant scratch/settings, or
   AI-generated TDD/SDD planning docs. Shared, reviewed rule files (`AGENTS.md` + the per-tool
   pointers) ARE committed — see [standards/practices/collaboration.md](standards/practices/collaboration.md).
10. **Don't disable the guardrails.** If this repo ships touchstone agent hooks (`.claude/hooks/`),
    leave them on; never use `git --no-verify` or a bare `git push --force`.

## Before you say "done"

Run the gates for whatever you touched, and show the output — evidence before assertions.
**Prefer the task runner** (`just ci`, or `just lint test build`) — it's the kit's standard
entrypoint. The raw commands below are the fallback for repos without a `justfile`:

```bash
# Python:   uv run ruff check . && uv run ruff format --check . && uv run pytest -q  &&  uvx pyright
# TS/React: pnpm biome ci . && pnpm typecheck && pnpm test && pnpm build
# Go:       gofumpt -l . && golangci-lint run && go test -race ./... && govulncheck ./...
```

## Where things are

| Area | Standard |
|---|---|
| Python · TypeScript · Go · Rust · Java/Kotlin · C# · Swift · PHP · Ruby · Elixir · Zig · Solidity · Shell | `standards/languages/` |
| React · Next · Nuxt · Svelte · Vue · Angular · Solid · Astro · FastAPI · Litestar · Django · Gin · Node.js · Spring Boot · ASP.NET Core · Rails · Laravel · Phoenix · Axum · React Native · Flutter · SwiftUI · Jetpack Compose | `standards/frameworks/` |
| Docker · DevOps/SRE · CI/CD · Database · Observability · Terraform/IaC · Kubernetes · Monorepo · Caching · Data-engineering · Search | `standards/platform/` |
| Security · App-security · Deps · Testing · Code-review · Code-quality · Privacy · Collaboration · Git-workflow · Performance · Accessibility · Documentation · AI/LLM-engineering | `standards/practices/` |
| Architecture · API design · Resilience · Event-driven · GraphQL · gRPC | `standards/design/` |
| Self-audit checklist + maturity model | [standards/self-audit.md](standards/self-audit.md) |

Full index: [standards/README.md](standards/README.md).
