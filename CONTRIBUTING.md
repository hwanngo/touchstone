# Contributing

touchstone is a living set of standards. Changes are welcome — but the bar is "would a senior
engineer defend this in a design review?"

## Principles for changes

- **Decisive, not a survey.** Recommend one tool/approach with rationale; document the escape
  hatch rather than listing five equal options.
- **Current and sourced.** Tie claims to official docs or a concrete incident/rationale. Flag
  anything that's recently changed (deprecations, renames, reversed advice).
- **Enforceable.** A standard that can't map to a CI gate, a lint rule, or a checklist item is a
  suggestion, not a standard — mark it as such.
- **Scope-honest.** Tag production-scale-only guidance _(scale-up)_ so the kit stays usable on
  small projects.
- **Keep it tight.** Prefer a table or a snippet over a paragraph. Every doc should be scannable.

## Workflow

1. Branch, edit, open a PR. One logical change per PR.
2. CI lints the Markdown and checks links — keep it green.
3. Conventional Commit messages (`docs:`, `feat:`, `fix:`, `chore:`).
4. If you change a standard, update the matching [`skills/`](skills/) wrapper and
   [`templates/`](templates/) file in the same PR so they don't drift.

## Layout

- `standards/` — the canonical docs (one per stack/area).
- `skills/` — thin Claude Code wrappers pointing at the canonical docs, plus the generated
  `CATALOG.md` index.
- `templates/` — ready-to-copy config files referenced by the standards, including the
  `templates/github/` set (workflows, CODEOWNERS, PR/issue templates) an adopting repo receives.
- `hooks/` — the opt-in Claude Code agent hooks, installed by `init.sh --with-hooks`.
- `scripts/` — kit tooling (`bootstrap.sh`/`init.sh` to adopt, the `check-*` gates, `gen-skill-catalog.sh`, `bump-version.sh`).
- `tests/` — the bash suite `tests/run.sh` runs: `gates/` and `hooks/` cases, the `lib/assert.sh`
  primitives, `tools/`, and the `fixtures/` trees the gates are exercised against.
- `.github/` — the kit's **own** CI workflow and Dependabot config; what adopters get is
  `templates/github/`, not this.
- `.claude-plugin/` — `plugin.json`, the manifest that lets Claude Code install the kit as a plugin.
- `AGENTS.md` — the tool-agnostic entry point for AI agents.

## Authoring conventions

Every file follows one template so the kit reads as a single voice. Copy the matching template
and keep its shape; CI (`check-skills`, `check-links`, markdownlint, shellcheck/shfmt) enforces the
mechanical parts.

**Standards docs** (`templates/standard.md`): `# <Subject> Standards` → a 1–2 line intro that
states scope and links the siblings it *defers to* → `---` → numbered `## N.` sections **with the
period** → a bare, unnumbered `## Definition of done`. The DoD checkboxes **mirror the rules** and
each maps to an enforceable gate. Prefer tables/snippets over prose; **language-tag every fence**;
link siblings rather than restating them; tag prod-only items `_(scale-up)_`. Optional: a
`> **One law:**` opener and a `**Sources:**` footer.

**Don't hardcode "current" versions.** A pinned "X.Y is the latest" claim rots within months. Say
**"latest stable"** and tell the reader/agent to **verify the current release before recommending or
installing one** (e.g. `swiftly install latest`, "use the current LTS"). Keep only what's durable:
**minimum-version floors** that gate a feature ("requires Python 3.12+ for X", "Java 21+ for virtual
threads"), **stable facts** (LTS cadence, "Edition 2024", a tool's existence), and **named features**.
Where an example needs a concrete version, mark it illustrative (`# e.g. 1.x — check for current`).
This mirrors hard rule #7 (latest stable) and keeps the docs from going stale.

**Skills** (`templates/SKILL.md`): frontmatter (`name` == directory; `description` opens with
"Use when…" and names its triggers + boundary) → `Full standard:` pointer → `## Always` (the
load-bearing non-negotiables — **required, and first**) → one or more domain-specific sections →
`## Done`. `check-skills` enforces the `## Always`-first / `## Done`-last spine.

**Scripts** (`templates/script-header.sh`): the shared header (purpose · usage · why · link to
`shell.md`), then `set -euo pipefail` — or `set -uo pipefail` for fail-aggregating scripts, with a
comment saying why. See [`standards/languages/shell.md`](standards/languages/shell.md).

## Releases

The kit is versioned with **SemVer** (the `VERSION` file + a git tag `vX.Y.Z`); consumers pin a
version and read [`CHANGELOG.md`](CHANGELOG.md) when re-syncing. Bump rules — applied to the
_standards_, not the prose:

- **MAJOR** — a reversed or removed rule, or a tool swap, that would make a previously-conforming
  repo non-conforming (e.g. "we now require X", dropping a supported stack).
- **MINOR** — new standard/skill/template, or a new rule that only _adds_ a gate.
- **PATCH** — clarifications, fixes, version bumps in templates, typo/link fixes.

Every PR updates the `[Unreleased]` section of the CHANGELOG. Reversed advice must include a
short migration note. Cutting a release: move `[Unreleased]` → `[X.Y.Z]`, bump `VERSION`
(`scripts/bump-version.sh X.Y.Z` sets it everywhere), tag.

## Keeping the kit current

The "latest stable, verify" rule means the docs **don't** need a commit every time a tool ships a
release — currency is delegated to the reader/agent at use-time, and a consumer's own
Dependabot/Renovate keeps *their* lockfiles fresh. So you update the kit only for **durable** shifts:

- **Bump a floor** when a feature now needs a higher minimum (`Java 21+` → `Java 25+`) — MINOR if it
  only adds a gate, MAJOR if it makes a conforming repo non-conforming.
- **Add a named API boundary** when a new major changes the idioms (`Svelte 6 …`, `Edition 2027`) —
  describe the *feature*, never "the latest is X".
- **Drop an EOL'd version** once it's past security support (with a migration note); **swap a tool**
  when the ecosystem moves (a linter is archived, a CVE class emerges).
- **Add a doc + skill** when a new stack goes mainstream — coverage grows, version numbers don't.

What the kit *does* pin — Action SHAs and the `shfmt` version in CI — is reproducibility, not
currency; **Dependabot** (`.github/dependabot.yml`) bumps those. A light **quarterly sweep**
re-verifies the floors/named-features still asserted and runs `scripts/check-*` — that's the whole
maintenance loop.
