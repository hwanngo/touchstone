# Changelog

All notable changes to touchstone are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org) applied to the *standards* — see [CONTRIBUTING.md](CONTRIBUTING.md#releases)
for what bumps major/minor/patch.

Consumers pin a version (`touchstone@vX.Y.Z`) and read this file when re-syncing to see what changed.

## [0.1.0] — 2026-06-30

Initial release — an opinionated, tool-agnostic engineering-standards kit for humans and AI agents.

### Standards (`standards/`)

- **66 docs**, one per stack/area, each opinionated and mapping every rule to an enforceable gate:
  - **Languages:** python · typescript · golang · rust · java-kotlin · csharp · swift · php · ruby ·
    elixir · zig · solidity · shell
  - **Frameworks:** react · next · nuxt · svelte · vue · angular · solid · astro · fastapi ·
    litestar · django · gin · node-backend · spring-boot · aspnet-core · rails · laravel · phoenix ·
    axum · react-native · flutter · swiftui · jetpack-compose
  - **Platform:** docker · devops · ci-cd · database · observability · terraform · kubernetes ·
    monorepo · caching · data-engineering · search
  - **Practices:** security · app-security · dependencies · testing-strategy · code-review ·
    code-quality · data-privacy · collaboration · git-workflow · performance · accessibility ·
    documentation · ai-engineering
  - **Design:** architecture · api-design · resilience · event-driven · graphql · grpc
  - **`self-audit.md`** — a scoring checklist + L1–L4 maturity model.
- **Versions are not hardcoded** — docs say "latest stable, verify" and keep only durable
  minimum-version floors, named features, and stable facts, so they don't rot.

### Skills (`skills/`)

- **61 Agent Skills** ([agentskills.io](https://agentskills.io) spec — `license` + `metadata`
  frontmatter), thin wrappers that surface the right standard on a matching edit/dependency/task,
  plus an `touchstone` router meta-skill. Every content skill follows the enforced
  `## Always`-first → domain sections → `## Done` spine. A generated `CATALOG.md` indexes them.

### Templates (`templates/`)

- Ready-to-copy configs (`biome.json`, `golangci.yml`, ruff/pytest snippet, `pre-commit-config.yaml`,
  `justfile`, `dependabot.yml`, `.dockerignore`, `.nvmrc`, `.python-version`), reusable SHA-pinned
  GitHub Actions workflows, `SECURITY.md`, ADR/issue/PR templates, and `CODEOWNERS`.

### Adoption & portability

- **`scripts/bootstrap.sh`** — one command vendors the kit as a pinned git submodule (`.touchstone`)
  and runs `init.sh` (no `curl | sh`). **`init.sh`** detects the stack, drops in templates + CI,
  writes a `.touchstone.toml` marker (idempotent — preserves your level/waivers), and **generates**
  single-source per-tool pointer files (`CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`,
  `.cursor/rules/touchstone.mdc`, `opencode.json`) that all defer to `AGENTS.md` — so Claude, Codex,
  Gemini, Cursor, Copilot, opencode, Pi, and Droid read the same rules with nothing duplicated and
  the kit root stays clean.

### Enforcement

- **Auditors:** `check-skills` (spec + spine), `check-standards` (doc template), `check-skill-quality`
  (advisory), `check-links`, `check-sync` (drift) — pure bash, zero install, wired into a hardened
  self-dogfooding CI (SHA-pinned Actions, least-privilege, shell + markdown lint, link + catalog
  checks). `bump-version.sh` sets the version everywhere at once.
- **Opt-in Claude Code agent hooks** (`hooks/`, installed into a repo via `init.sh --with-hooks`): inject the hard rules,
  guard against `--no-verify`/bare `--force`, block writing secrets, format on edit, audit touched
  instruction files, and nudge CI. All fail-open. `.claude-plugin/plugin.json` makes the kit
  installable as a Claude Code plugin.

[0.1.0]: https://github.com/hwanngo/touchstone/releases/tag/v0.1.0
