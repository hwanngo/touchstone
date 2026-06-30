# Git, Repo Hygiene & AI-Assistant Standards

How work moves through git: commits, branching, the task runner, repo metadata (incl. the ADR
process and `docs/adr/` home), and the rules for AI-assisted changes. PR review mechanics live in
[code-review.md](code-review.md); *when* a decision warrants an ADR is set by
[architecture.md](../design/architecture.md) §4.

---

## 1. Commit conventions

- **Conventional Commits**: `type(scope): summary`. Common types: `feat`, `fix`, `refactor`,
  `test`, `docs`, `chore`, `perf`, `build`, `ci`. Scope is the area touched.
- **Atomic commits** — one logical change each. Don't mix a refactor with a behaviour change.
- Imperative mood ("add", "fix", not "added"/"fixes"). Explain the *why* in the body.
- Don't commit commented-out code, debug prints, or secrets.
- **Enforce the format** with commitlint (`commit-msg` hook) + a CI check, so release automation
  (release-please/changesets) gets clean input. See [ci-cd.md](../platform/ci-cd.md) §7.

## 2. Branches & PRs

- Work on a branch; open a PR into the main branch. Don't push directly to it.
- A PR is mergeable only when **all CI gates are green** (lint, format check, type-check, tests,
  build for each stack). Enforce with a branch ruleset + CODEOWNERS — see [ci-cd.md](../platform/ci-cd.md) §6.
- Rebase/squash noisy WIP history before merge so the main branch stays readable.
- Force-pushing a shared branch: use `--force-with-lease`, never bare `--force`.

## 3. What never gets committed

The `.gitignore` enforces this; the policy behind it:

- **Secrets & env:** ignore every `.env*` variant; commit only `*.example` templates. Real
  credentials never enter git history. (Back this with secret scanning — [security.md](security.md).)
- **Generated artifacts:** build output (`dist/`, `build/`), caches (`.ruff_cache/`,
  `.pytest_cache/`, `.vite/`, `node_modules/`, `.venv/`), and any uploads/outputs/databases that
  regenerate from source or scripts.
- **AI assistant folders & their planning docs** — see §4.

## 4. AI-assistant hygiene

Building with AI coding assistants is encouraged. The line to hold is **scratch vs. shared rules**:
per-developer working state never gets committed, but the reviewed instruction files that *are*
the team's source of truth do.

- **Never commit per-developer scratch:** assistant working dirs and local settings —
  `.claude/settings.local.json`, chat/session history, caches, and the working folders of
  `.aider*`, `.continue/`, `.roo/`, `.cline/`, and anything matching `*superpowers*` / similar.
  Default-ignore the assistant dirs (`.claude/`, `.cursor/`, `.codex/`, `.gemini/`, `.windsurf/`)
  and **carve out only the specific reviewed rule files** you intend to share (see the `.gitignore`
  in this kit for the pattern).
- **Generated TDD/SDD planning docs stay out of the repo.** Spec/plan documents produced by
  agent workflows are scratch artifacts — useful locally, but gitignored. Distil anything durable
  into real docs and commit *that* instead.

**What *is* committed for AI agents** — the shared, reviewable source of truth every assistant and
human reads:

- A tool-agnostic [`AGENTS.md`](../../AGENTS.md) plus the canonical `standards/` docs.
- Thin, single-source **per-tool pointer files** that defer to `AGENTS.md` (no duplicated rules):
  `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`, `.cursor/rules/*.mdc`,
  `opencode.json`. These let Gemini / Cursor / Copilot / opencode pick up the same rules.
- **Agent Skills** (`skills/`) and any opt-in **agent hooks** a repo installs as its shared product
  (`.claude/hooks/` + `.claude/settings.json`, generated from the kit's `hooks/` via
  `init.sh --with-hooks`). Per-developer *installs* of a skill into `~/.claude/skills/` remain local.

## 5. Local enforcement: pre-commit + a task runner

- **pre-commit** is the universal local-hook framework — one version-pinned `.pre-commit-config.yaml`
  runs the same formatters/linters/secret-scanners locally and in CI, so they never drift. It's
  also the carrier for gitleaks, ruff, biome, zizmor, etc. Run `pre-commit run --all-files` as a
  CI job too. (Template: `templates/pre-commit-config.yaml`.)
- **A task runner gives one discoverable entrypoint** for every repeatable command. Prefer
  **`just`** (Make's ergonomics without the footguns). Every repo exposes the same target
  contract: `setup`, `lint`, `fmt`, `test`, `build`, `ci`. Onboarding becomes "install just, run
  `just setup`." (Template: `templates/justfile`.)

## 6. Repo meta files seniors expect

Encode review ownership, contribution rules, and consistency as repo state, not tribal knowledge:

- **`.editorconfig` + `.gitattributes`** — kill cross-OS indent/CRLF churn before it reaches a
  linter or a diff. (Templates at the kit root.)
- **`CODEOWNERS`** keyed to teams with a catch-all fallback; tie it to "require code-owner review."
- **`SECURITY.md`** (private disclosure contact), **`CONTRIBUTING.md`**, **PR/issue templates**,
  **`LICENSE`**.
- **ADRs** (Architecture Decision Records, MADR/Nygard) in `docs/adr/` for *significant* decisions
  with multiple viable options — context → decision → consequences. Immutable: supersede, never
  edit an accepted record. This is the decision-level home for "document everything reusable."

## 7. Documentation policy

- **Document everything reusable**: architecture, data/format specs, algorithms, and standards
  live in `docs/`. Keep them **verified against the code** — a doc that contradicts the codebase
  is a bug. Where practical, make the README quickstart a CI-executed contract and link-check docs.
- **Do not** commit throwaway AI planning/spec scratch (see §4).
- Keep `README.md` and `docs/` current when behaviour or interfaces change — in the same PR.
- Generate `CHANGELOG.md` (Keep a Changelog) from Conventional Commits via release automation
  rather than maintaining it by hand. See [ci-cd.md](../platform/ci-cd.md) §7.

## Definition of done

- [ ] Conventional Commits, atomic; branch + PR, never push to `main`; `--force-with-lease` only
- [ ] pre-commit installed and green; the task runner exposes `setup/lint/fmt/test/build/ci`
- [ ] Repo meta in place: `.editorconfig`, `.gitattributes`, CODEOWNERS, SECURITY.md, PR/issue templates
- [ ] `.gitignore` covers secrets, build artifacts, and AI-assistant folders; no AI planning docs committed
- [ ] Docs (README/`docs/`) updated in the same PR as the behaviour they describe
