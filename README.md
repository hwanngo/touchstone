# touchstone

[![CI](https://github.com/hwanngo/touchstone/actions/workflows/ci.yml/badge.svg)](https://github.com/hwanngo/touchstone/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

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
| [`skills/`](skills/README.md) | AI-agent skill wrappers ([Agent Skills](https://agentskills.io) spec) that surface the right standard at the right time |
| [`templates/`](templates/) | Config files `init.sh` copies in, each under its conventional destination name — the template is stored undotted: `templates/golangci.yml` → `.golangci.yml`, `templates/pre-commit-config.yaml` → `.pre-commit-config.yaml`, `templates/nvmrc` → `.nvmrc`; `biome.json` and `justfile` keep their name. ruff is configured by merging `templates/pyproject-snippet.toml`, not by a file of its own |
| [`hooks/`](hooks/README.md) | Opt-in Claude Code agent hooks that enforce the standards at runtime (`init.sh --with-hooks`) |
| [`scripts/`](scripts/README.md) | `bootstrap.sh`/`init.sh` (adopt) and `check-sync.sh` (the drift gate an adopter runs), plus `check-{agents,links,skill-quality,skills,standards}.sh` — **the kit's own CI gates, not adopter gates** ([why](#which-scripts-you-run-and-which-you-dont)) — `gen-skill-catalog.sh`, `bump-version.sh` |
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
  [code-quality](standards/practices/code-quality.md) · [data-privacy](standards/practices/data-privacy.md) · [collaboration](standards/practices/collaboration.md) ·
  [git-workflow](standards/practices/git-workflow.md) · [performance](standards/practices/performance.md) ·
  [accessibility](standards/practices/accessibility.md) · [documentation](standards/practices/documentation.md) ·
  [ai-engineering](standards/practices/ai-engineering.md)
- **[`design/`](standards/design/)** — [architecture](standards/design/architecture.md) ·
  [api-design](standards/design/api-design.md) · [resilience](standards/design/resilience.md) ·
  [event-driven](standards/design/event-driven.md) · [graphql](standards/design/graphql.md) ·
  [grpc](standards/design/grpc.md)
- **[self-audit](standards/self-audit.md)** — checklist + maturity model (L1–L4)

## Adopting it in a repo

> [!IMPORTANT]
> **touchstone has not published a release tag yet.** `bootstrap.sh` pins `.touchstone` to
> `v<VERSION>` by default, and until a `v0.1.0` tag exists on the remote that ref cannot resolve —
> so the bare `bootstrap.sh` form **fails**, deliberately and with a clean rollback, rather than
> vendoring something unpinned behind your back. Pass `--ref` (below) until the first tag ships.
> The failure message names the working options and prints them as runnable commands.

**One command** — clone the kit once, then from inside any target repo run `bootstrap.sh`: it
vendors the kit as a **pinned submodule** and runs `init.sh`, which detects your stack, generates
the per-tool pointer files (Claude/Gemini/Cursor/Copilot/opencode), drops the matching templates +
CI, and writes a `.touchstone.toml` marker. Nothing to copy by hand:

```bash
git clone https://github.com/hwanngo/touchstone ~/touchstone       # once, anywhere
cd my-repo
~/touchstone/scripts/bootstrap.sh --ref "$(git -C ~/touchstone rev-parse HEAD)"
#                                 ^ pins to the exact commit you just cloned — reproducible today.
#                                   Drop --ref once a vX.Y.Z tag exists; --with-hooks / --force /
#                                   --dry-run pass through to init.sh.
```

`--ref` takes any tag, branch or commit SHA. `--allow-unpinned` vendors the default branch instead,
without a pin — convenient, but it gives up the reproducibility the submodule model exists for, so
prefer a SHA.

Or do it explicitly (same result):

```bash
git submodule add https://github.com/hwanngo/touchstone .touchstone
git -C .touchstone checkout <sha-or-tag>   # pin it; a floating submodule is not a pin
./.touchstone/scripts/init.sh              # --dry-run to preview; --force to overwrite
```

Then finish the setup:

```bash
$EDITOR AGENTS.md                    # fill in the Project block
pinact run                           # pin GitHub Actions to commit SHA
pre-commit install && just ci        # install hooks + run the gates
```

Then score the repo against the [self-audit checklist](standards/self-audit.md), set `level` in
`.touchstone.toml` to the highest [maturity level](standards/self-audit.md#maturity-levels) every
applicable item actually passes at — a conformance claim, not an aspiration — and keep closing gaps
toward the next one. Stay in sync as the
kit evolves with `./.touchstone/scripts/check-sync.sh` (wire it into CI); read
[`CHANGELOG.md`](CHANGELOG.md) when bumping the pinned version.

### Which scripts you run, and which you don't

`.touchstone/scripts/` holds two different kinds of script, and running the wrong kind gives you a
confident green about a repo that was never scanned:

| From your repo | What it does |
|---|---|
| `./.touchstone/scripts/init.sh` | applies the kit to your repo (idempotent; re-run after bumping the pin) |
| `./.touchstone/scripts/check-sync.sh` | **the adopter-facing gate** — is your copy still in sync with the pinned kit? Wire this into CI |
| `just ci` | your repo's own gates, installed by `init.sh` |

`check-agents.sh`, `check-links.sh`, `check-skill-quality.sh`, `check-skills.sh` and
`check-standards.sh` are **touchstone's own CI gates**. They audit the kit's skills, standards and
docs, and by design they always scan the repository they live in. Run from your repo they would
therefore report on the *kit's* files and never open yours — so they now **refuse** with exit 2
instead of printing a pass. They are not gates you are missing; your equivalents are `just ci`.

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
| `hooks/` agent hooks (installed into your repo by `init.sh --with-hooks`) | Claude Code only (CI/pre-commit is the tool-agnostic backstop) |
| `.claude-plugin/plugin.json` — how **this kit** is installed as a Claude Code plugin; it is *not* copied into your repo, and must not be (it names touchstone, its version and its homepage — in your repo it would declare your repo to be the touchstone plugin) | Claude Code only |

So every tool finds the rules, **`scripts/init.sh` generates** thin **single-source pointer files**
into your repo (nothing to copy by hand) — each defers to `AGENTS.md`, so no rules are duplicated:
`CLAUDE.md` (`@AGENTS.md` import), `GEMINI.md`, `.github/copilot-instructions.md`,
`.cursor/rules/touchstone.mdc` (`alwaysApply`), and `opencode.json` (opencode also auto-loads
`AGENTS.md`). The touchstone repo itself stays clean — it ships only `AGENTS.md`; the per-tool files
are generated at adoption time. Per-tool *scratch/settings* stay gitignored — only the generated,
reviewed rule files are committed in your repo (see
[collaboration.md §4](standards/practices/collaboration.md)).

## Evals

`AGENTS.md` and `hooks/` state and enforce the rules; `agents/` (`standards-auditor`,
`currency-researcher`, `adoption-doctor`, `guardrail-redteam`, `drift-watcher`, `eval-runner`) are
subagents that *act* on them — auditing a repo, checking a claim, diagnosing a broken adoption. An
**eval** is how this kit proves one of those subagents actually finds what it claims to, instead of
trusting a description that sounds right: a small, deliberately broken fixture repo under
`evals/cases/<case-id>/repo/`, plus a catalogued `answer-key.txt` naming exactly which defects a
correct run must surface. See [`evals/README.md`](evals/README.md) for the full format, the score
floors that let a case tolerate honest, uncatalogued thoroughness, and the stated limits (most
importantly: **no case currently plants a decoy, so precision is not measured** — the evals show
these agents do not *miss* things, not that they never *invent* things).

Run one locally with `just eval <case-id>`: it prints the agent, the fixture path, and the scoring
command. Point that agent at `evals/cases/<case-id>/repo/`, save its findings to a file (one per
line), then `just eval <case-id> <findings-file>` to score them against the answer key.

**Evals are not in `just ci`, and never will be by design.** Running an agent against a fixture
means calling a model: not hermetic, not offline, not deterministic — and `tests/run.sh` (what
`just ci` runs) has to stay all three, the same way a unit-test suite can't depend on a live network
call. The deterministic half of the eval system *is* in `just ci`, precisely:
`scripts/check-evals.sh` runs in `just gates` (it checks each case's shape and phantom-checks its
answer key), and `scripts/score-eval.sh` runs in `just test` — through
`tests/gates/score-eval.test.sh` and through `tests/gates/reference-findings-replay.test.sh`, which
replays every case's committed `reference-findings.txt` (a frozen, dated, named-model run) against its
answer key. Neither ever touches a model. `.github/workflows/eval.yml` runs the same two things
weekly as a rot-detector — see that file and `evals/README.md` for exactly what a green run there
does and does not prove about the agent itself.

## Non-negotiables (the 60-second version)

- **uv** for Python · **pnpm** for Node · **go modules** for Go. Lockfiles committed; CI installs frozen.
- **ruff** (Python) · **Biome** (TS) · **gofumpt + golangci-lint** (Go) — format + lint, enforced in CI.
- **Latest stable deps**, kept current; outdated packages are a security liability.
- **Containers**: small current base images (slim/alpine/distroless), multi-stage, non-root, digest-pinned.
- **CI is hardened**: Actions pinned to SHA, least-privilege `permissions:`, secrets scanned, OIDC over static keys.
- **Never commit** secrets, per-developer AI-assistant scratch, or AI planning docs. Generated
  artifacts only when deterministic, marked generated, and CI-gated by regenerate-and-diff
  (e.g. `skills/CATALOG.md`); shared, reviewed rule files like `AGENTS.md` are fine.

## License

[MIT](LICENSE).
