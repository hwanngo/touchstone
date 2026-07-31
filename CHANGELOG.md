# Changelog

All notable changes to touchstone are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org) applied to the *standards* — see [CONTRIBUTING.md](CONTRIBUTING.md#releases)
for what bumps major/minor/patch.

Consumers pin a version (`touchstone@vX.Y.Z`) and read this file when re-syncing to see what changed.

## [Unreleased]

## [0.2.0] — 2026-07-31

A hardening pass over the gates, the agent hooks, and the adoption path. The theme throughout: rules
the kit stated but nothing enforced, and gates that could report success while examining nothing.

### Fixed — adoption (read this section first if you already vendor touchstone)

These were found by adopting the kit into a scratch project for the first time. Every one was
invisible from inside the kit, and the kit's own test suite was fully green while they shipped.

- **Adopters could not commit at all.** `templates/pre-commit-config.yaml` declared a hook id that
  does not exist at its pinned `rev`. pre-commit resolves ids at run time and aborts the whole run on
  the first unknown one, so every `git commit` failed, and the entire backstop — secret scanning,
  workflow linting, lockfile checks — never ran. All revs are now current and every id is verified
  against the upstream repo at its pinned rev by `tests/gates/pre-commit-hook-ids.test.sh`.
- **`just fmt` rewrote the pinned submodule** and `just lint` failed on the kit's own documents:
  the template's Python/Node/Go recipes ran over `.`, which includes `.touchstone/`. The shell
  recipes in the same file already excluded it; the exclusion is now applied consistently.
- **The Node gate could not run**, because the vendored `templates/biome.json` was discovered as a
  nested root config. It is now excluded, and `includes` no longer covers only `src/**` — the gate
  previously exited 0 having checked one file.
- **A workflow template pinned an action major that has never existed.** `pinact` stops at the first
  unresolvable ref, so one bad ref left every *other* action unpinned — a supply-chain gap disguised
  as a typo. Every `uses:` ref across the workflow templates is now verified to resolve.
- **The documented bootstrap command could not succeed**, since it defaults to a release tag that
  does not exist yet. It now diagnoses the cause, prints runnable alternatives, and the README says
  plainly that there is no release tag rather than documenting a command that fails.
- Adopters now receive the issue templates the kit's own checklist requires; `init.sh` shipped the
  PR template and CODEOWNERS but never the issue forms.

### Fixed — gates that could pass without checking anything

- `check-links.sh` **certified repositories it never read**: with `awk` unusable, every scan returned
  empty and the gate exited 0. It now refuses to run instead.
- `check-standards.sh` validated a fixed two-level glob, so `standards/self-audit.md` — the kit's
  flagship checklist — had never been validated in its life.
- `check-skills.sh` grepped at its inputs instead of parsing them, which let twelve unparseable
  frontmatter descriptions ship, and resolved pointers from only one location.
- `check-links.sh` and `check-skills.sh` could resolve paths outside the repository, and the four
  kit-only gates now refuse to certify a repo they were never pointed at, rather than reporting
  success about the kit while run from somewhere else.
- Secret scanning only ever examined the staged diff, so nothing scanned the repository or its
  history. CI now runs a full scan, proven against a planted credential.

### Fixed — the kit breaking its own rules

- CI installed a Node tool with `npx`, and the pre-commit template told adopters to install with
  `pipx` — both violating hard rule 1.
- Rule 9 banned committing generated artifacts while the kit committed a generated catalogue. The
  rule now carries one bounded exception, valid only while CI enforces the file's freshness.
- The adopter task-runner template disabled every gate with a leading `-`, which the kit's own
  runner forbids in capitals.

### Added

- `agents/` — `standards-auditor` and `currency-researcher`, with `scripts/check-agents.sh`.
- Self-adoption: the kit carries `.touchstone.toml`, and `check-sync.sh` gained a declared-divergence
  mechanism that pins both sides of each intentional kit-vs-template difference.
- Every checklist item in `standards/self-audit.md` now carries the maturity level at which it first
  becomes required, and bundled items spanning several levels have been split apart.
- Repo meta the kit requires of adopters and previously lacked itself: `SECURITY.md`, `CODEOWNERS`,
  PR and issue templates, `.pre-commit-config.yaml`.
- A `ci-required` aggregator job, `actionlint`, `pinact` and `zizmor` in CI.
- The test suite grew from 224 to 1113 assertions, with fixture-deletion and mutation drills so that
  a test which stops testing its subject fails loudly.

### Changed

- `next.md` rewritten for Next.js 16 — three of its code samples did not merely describe old
  behaviour, they fail to build on 16. `react.md` gained a React 19 baseline; `app-security.md`
  remapped to the OWASP Top 10:2025 revision.

### Known limitations

- Nothing here has executed on a GitHub runner; all verification was local.
- No `package.json` template exists, so a fresh adopter must install Biome before the Node gate runs.
- The Go toolchain was never exercised; its exclusions are inspection-only.
- The kit has no evaluation set for the skills and agents it ships. Every gate proves they parse;
  none evaluates what they produce.

## [0.1.0] — 2026-06-30

Initial release — an opinionated, tool-agnostic engineering-standards kit for humans and AI agents.

### Standards (`standards/`)

- **66 domain docs**, one per stack/area, each opinionated and mapping every rule to an enforceable
  gate — plus `self-audit.md` and two directory READMEs (`standards/README.md`,
  `standards/frameworks/README.md`), **69 standards docs** in total:
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
  frontmatter): **60 content skills**, thin wrappers that surface the right standard on a matching
  edit/dependency/task, plus a `touchstone` router meta-skill. Every content skill follows the enforced
  `## Always`-first → domain sections → `## Done` spine. A generated `CATALOG.md` indexes them.

### Templates (`templates/`)

- Ready-to-copy configs (`biome.json`, `golangci.yml`, ruff/pytest snippet, `pre-commit-config.yaml`,
  `justfile`, `dependabot.yml`, `renovate.json`, `.dockerignore`, `.nvmrc`, `.python-version`),
  ready-to-copy GitHub Actions workflows (`ci`, `codeql`, `release-please`), `SECURITY.md`,
  ADR/issue/PR templates, and `CODEOWNERS`. The template workflows are **tag-pinned**; `pinact run`
  (see the README's setup steps) converts them to commit SHAs in the adopting repo. The kit's own
  `.github/workflows/` is SHA-pinned.

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
