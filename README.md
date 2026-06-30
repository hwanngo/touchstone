# touchstone

**Opinionated, tool-agnostic engineering standards** for shipping production-grade software —
the conventions, tooling choices, and guardrails a senior engineer would set up on day one,
distilled into copy-pasteable docs, AI-agent skills, and ready-to-use config templates.

It is designed to be **dropped into any repository** as the shared source of truth for both
humans and AI coding agents.

---

## Why this exists

Every new project re-litigates the same decisions: which package manager, which formatter, how
to structure CI, how to keep secrets out of git, how to harden a container. touchstone answers them
once — decisively, with current (2024–2026) best practice and the rationale — so each repo starts
from a known-good baseline instead of drift.

### Principles

- **Opinionated, not a menu.** One recommended tool per job (uv, Biome, ruff, golangci-lint,
  OpenTofu…), with the escape hatch documented.
- **Enforced, not aspirational.** Every standard maps to a CI gate or a pre-commit hook.
- **Current and sourced.** Reflects 2025-era reality — SHA-pinned Actions, distroless runtimes,
  dependency cooldowns — not cargo-culted advice.
- **Scales down and up.** Items that only matter at production scale are tagged _(scale-up)_.

## What's inside

| Path | Contents |
|---|---|
| [`standards/`](standards/README.md) | The standards themselves — one doc per stack/area |
| [`skills/`](skills/README.md) | Claude Code skill wrappers that surface the right standard at the right time |
| [`templates/`](templates/) | Ready-to-copy config files (`biome.json`, `.golangci.yml`, `.pre-commit-config.yaml`, `ruff`, `justfile`, …) |
| [`hooks/`](hooks/README.md) | Opt-in Claude Code agent hooks that enforce the standards at runtime (`init.sh --with-hooks`) |
| [`scripts/`](scripts/README.md) | `bootstrap.sh`/`init.sh` (adopt), `check-{skills,standards,links,sync,skill-quality}.sh` (gates), `gen-skill-catalog.sh`, `bump-version.sh` |
| [`AGENTS.md`](AGENTS.md) | Tool-agnostic instructions any AI agent reads first |

### Standards index

Full index with one-line descriptions: **[standards/README.md](standards/README.md)**. By domain:

- **[`languages/`](standards/languages/)** — [python](standards/languages/python.md) ·
  [typescript](standards/languages/typescript.md) · [golang](standards/languages/golang.md) ·
  [rust](standards/languages/rust.md) · [java-kotlin](standards/languages/java-kotlin.md) ·
  [csharp](standards/languages/csharp.md) · [swift](standards/languages/swift.md) ·
  [php](standards/languages/php.md) · [ruby](standards/languages/ruby.md) ·
  [elixir](standards/languages/elixir.md) · [zig](standards/languages/zig.md) ·
  [solidity](standards/languages/solidity.md) · [shell](standards/languages/shell.md)
- **[`frameworks/`](standards/frameworks/)** — [react](standards/frameworks/react.md) ·
  [next](standards/frameworks/next.md) · [nuxt](standards/frameworks/nuxt.md) ·
  [svelte](standards/frameworks/svelte.md) · [vue](standards/frameworks/vue.md) ·
  [angular](standards/frameworks/angular.md) · [solid](standards/frameworks/solid.md) ·
  [astro](standards/frameworks/astro.md) · [fastapi](standards/frameworks/fastapi.md) ·
  [litestar](standards/frameworks/litestar.md) · [django](standards/frameworks/django.md) ·
  [gin](standards/frameworks/gin.md) · [node-backend](standards/frameworks/node-backend.md) ·
  [spring-boot](standards/frameworks/spring-boot.md) · [aspnet-core](standards/frameworks/aspnet-core.md) ·
  [rails](standards/frameworks/rails.md) · [laravel](standards/frameworks/laravel.md) ·
  [phoenix](standards/frameworks/phoenix.md) · [axum](standards/frameworks/axum.md) ·
  [react-native](standards/frameworks/react-native.md) · [flutter](standards/frameworks/flutter.md) ·
  [swiftui](standards/frameworks/swiftui.md) · [jetpack-compose](standards/frameworks/jetpack-compose.md)
- **[`platform/`](standards/platform/)** — [docker](standards/platform/docker.md) ·
  [devops](standards/platform/devops.md) · [ci-cd](standards/platform/ci-cd.md) ·
  [database](standards/platform/database.md) · [observability](standards/platform/observability.md) ·
  [terraform](standards/platform/terraform.md) · [kubernetes](standards/platform/kubernetes.md) ·
  [monorepo](standards/platform/monorepo.md) · [caching](standards/platform/caching.md) ·
  [data-engineering](standards/platform/data-engineering.md) · [search](standards/platform/search.md)
- **[`practices/`](standards/practices/)** — [security](standards/practices/security.md) ·
  [app-security](standards/practices/app-security.md) · [dependencies](standards/practices/dependencies.md) ·
  [testing-strategy](standards/practices/testing-strategy.md) · [code-review](standards/practices/code-review.md) ·
  [data-privacy](standards/practices/data-privacy.md) · [collaboration](standards/practices/collaboration.md) ·
  [git-workflow](standards/practices/git-workflow.md) · [performance](standards/practices/performance.md) ·
  [accessibility](standards/practices/accessibility.md) · [documentation](standards/practices/documentation.md) ·
  [ai-engineering](standards/practices/ai-engineering.md)
- **[`design/`](standards/design/)** — [architecture](standards/design/architecture.md) ·
  [api-design](standards/design/api-design.md) · [resilience](standards/design/resilience.md) ·
  [event-driven](standards/design/event-driven.md) · [graphql](standards/design/graphql.md) ·
  [grpc](standards/design/grpc.md)
- **[self-audit](standards/self-audit.md)** — checklist + maturity model (L1–L4)

## Adopting it in a repo

**One command** — clone the kit once, then from inside any target repo run `bootstrap.sh`: it
vendors the kit as a **pinned submodule** and runs `init.sh`, which detects your stack, generates
the per-tool pointer files (Claude/Gemini/Cursor/Copilot/opencode), drops the matching templates +
CI, and writes a `.touchstone.toml` marker. Nothing to copy by hand:

```bash
git clone https://github.com/hwanngo/touchstone ~/touchstone     # once, anywhere
cd my-repo && ~/touchstone/scripts/bootstrap.sh             # per repo (--with-hooks / --force / --dry-run pass through)
```

Or do it explicitly (same result):

```bash
git submodule add https://github.com/hwanngo/touchstone .touchstone
./.touchstone/scripts/init.sh           # --dry-run to preview; --force to overwrite
```

Then finish the setup:

```bash
$EDITOR AGENTS.md                    # fill in the Project block
pinact run                           # pin GitHub Actions to commit SHA
pre-commit install && just ci        # install hooks + run the gates
```

Then score the repo against the [self-audit checklist](standards/self-audit.md) at your target
[maturity level](standards/self-audit.md#maturity-levels) and close the gaps. Stay in sync as the
kit evolves with `./.touchstone/scripts/check-sync.sh` (wire it into CI); read
[`CHANGELOG.md`](CHANGELOG.md) when bumping the pinned version.

For Claude Code users: copy [`skills/`](skills/) into `~/.claude/skills/` (global) or the repo's
`.claude/skills/` so the standards surface automatically while you work.

## Using touchstone with other AI tools

touchstone is built in layers that **degrade gracefully** across tools — the *content* is universal,
and the real enforcement (CI + pre-commit) is tool-agnostic, so whichever assistant writes the code
gets gated the same way.

| Layer | Portable to |
|---|---|
| `standards/*.md` (plain docs) | **any** tool or human |
| [`AGENTS.md`](AGENTS.md) — the entry point | Codex, opencode, Droid, Cursor, Jules, Pi, … |
| `skills/*/SKILL.md` ([Agent Skills](https://agentskills.io) open spec) | Claude, Codex, Cursor, Gemini, Windsurf, Antigravity, Pi (others ignore them) |
| `hooks/` agent hooks (installed via `init.sh --with-hooks`) + `.claude-plugin/` manifest | Claude Code only (CI/pre-commit is the tool-agnostic backstop) |

So every tool finds the rules, **`scripts/init.sh` generates** thin **single-source pointer files**
into your repo (nothing to copy by hand) — each defers to `AGENTS.md`, so no rules are duplicated:
`CLAUDE.md` (`@AGENTS.md` import), `GEMINI.md`, `.github/copilot-instructions.md`,
`.cursor/rules/touchstone.mdc` (`alwaysApply`), and `opencode.json` (opencode also auto-loads
`AGENTS.md`). The touchstone repo itself stays clean — it ships only `AGENTS.md`; the per-tool files
are generated at adoption time. Per-tool *scratch/settings* stay gitignored — only the generated,
reviewed rule files are committed in your repo (see
[collaboration.md §4](standards/practices/collaboration.md)).

## Non-negotiables (the 60-second version)

- **uv** for Python · **pnpm** for Node · **go modules** for Go. Lockfiles committed; CI installs frozen.
- **ruff** (Python) · **Biome** (TS) · **gofumpt + golangci-lint** (Go) — format + lint, enforced in CI.
- **Latest stable deps**, kept current; outdated packages are a security liability.
- **Containers**: small current base images (slim/alpine/distroless), multi-stage, non-root, digest-pinned.
- **CI is hardened**: Actions pinned to SHA, least-privilege `permissions:`, secrets scanned, OIDC over static keys.
- **Never commit** secrets, generated artifacts, per-developer AI-assistant scratch, or AI-generated planning docs (shared, reviewed rule files like `AGENTS.md` are fine).

## License

[MIT](LICENSE).
