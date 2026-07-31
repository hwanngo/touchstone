# Scripts

Kit tooling — pure `bash` + `awk`/`grep`/`diff` (no `jq`/`yq`/node), so CI needs zero install.
All follow the shell standard ([`standards/languages/shell.md`](../standards/languages/shell.md))
and the shared header format (`templates/script-header.sh`).

| Script | Purpose | Used by |
|---|---|---|
| [`bootstrap.sh`](bootstrap.sh) | One-command adoption: vendor the kit as a pinned submodule (`.touchstone`) then run `init.sh`. Run from a kit clone inside your target repo. `--ref`/`--url`/`--allow-unpinned`; other flags pass through. No `curl\|sh`. | adopters |
| [`init.sh`](init.sh) | Apply the kit to a repo: detect stack, **generate** per-tool pointer files, drop in matching templates + CI, write `.touchstone.toml`. `--target`/`--dry-run`/`--force`/`--with-hooks`. | adopters |
| [`check-sync.sh`](check-sync.sh) | Drift check: compare a repo's pinned version + managed files against the kit, including declared divergences (`--print-diverge DEST` emits a ready-to-paste entry). The kit self-adopts, so it runs this on itself too. | adopters' CI + this repo's CI + `just gates` |
| [`check-skills.sh`](check-skills.sh) | Audit every `SKILL.md` against the Agent Skills spec + the touchstone template: frontmatter, `name`==dir, a description that is loadable YAML (an unquoted value containing a colon-then-space is rejected) and trigger-phrased once unquoted, `license`+`metadata.version`(==VERSION), the `Full standard:`/`## Done` spine, language-tagged fences, every `*.md` pointer resolving from the skill dir or the repo root, no leaked `<tag>` scaffolding, no drift markers. | this repo's CI + `just gates` |
| [`check-standards.sh`](check-standards.sh) | Audit every markdown doc under `standards/`, at any depth, against the doc template: H1, bare `## Definition of done` (index READMEs and `self-audit.md` are exempt from that one rule, and say so), periodised `## N.` headings, language-tagged fences, no leaked `<tag>` scaffolding; reports docs with no dedicated skill. | this repo's CI + `just gates` |
| [`check-agents.sh`](check-agents.sh) | Audit every `agents/*.md` subagent definition against the Claude Code subagent format: well-formed frontmatter, `name`==filename, a loadable, trigger-phrased `description`, well-formed optional `tools:`/`model:`, a body that routes to a real `standards/*.md`, every `*.md` pointer resolving to a file inside the repo, no drift markers. `agents/README.md` is skipped by name as the directory index. | this repo's CI + `just gates` |
| [`check-skill-quality.sh`](check-skill-quality.sh) | **Warn-only** description-quality gate: vague verbs, boilerplate openings, openings duplicated across skills. Warnings never fail the build; zero skills examined does. | this repo's CI (advisory) + `just gates` |
| [`check-links.sh`](check-links.sh) | Verify every internal Markdown link resolves — target on disk, `#anchor` matching a real heading under GitHub slug rules, reference-style definitions included — and, best-effort, that every `<file>.md §N` cross-reference names a section that exists. | this repo's CI + `just gates` |
| [`gen-skill-catalog.sh`](gen-skill-catalog.sh) | Generate [`skills/CATALOG.md`](../skills/CATALOG.md) (a machine index of every skill, bucketed by domain) from frontmatter. Deterministic; CI regenerates + diffs to catch staleness. Prints to stdout — in this repo, redirect it yourself; adopters get a `just skill-catalog` recipe that writes via a temp file. | this repo's CI (regenerate + diff) |
| [`bump-version.sh`](bump-version.sh) | Set the kit version everywhere at once (VERSION, all skill `metadata.version`, template, plugin) so the version-consistency gate stays green. `usage: bump-version.sh X.Y.Z` | releases |

**Which `just` recipes exist where.** In THIS repo the gate scripts run from `just gates` (and
`just ci`, which is `lint test gates`). `just lint-skills` and `just skill-catalog` are ADOPTER
recipes — they live in [`templates/justfile`](../templates/justfile), which is what `init.sh` drops
into a consuming repo, and each guards itself with `if [ -f scripts/… ]` so it no-ops in a repo that
did not vendor the script. Running either in the kit itself will tell you the recipe is unknown.

**Convention:** scripts that operate on a repo and need to surface *all* problems use
`set -uo pipefail` (no `-e`) and aggregate failures into one exit code (`check-skills`,
`check-standards`, `check-agents`, `check-links`, `check-skill-quality`); scripts that should abort
on first error use `set -euo pipefail` (`bootstrap`, `init`, `check-sync`, `gen-skill-catalog`,
`bump-version`). Each script's header comment states which and why.

**No gate passes on an empty set.** Every `check-*` script exits non-zero when it finds nothing to
examine, and reports how many inputs it read. A gate that certified zero files as green is how
several of these shipped broken before; the count in the output is the check on the check.

```bash
bash scripts/check-standards.sh && bash scripts/check-skills.sh \
  && bash scripts/check-agents.sh && bash scripts/check-links.sh   # core gates, as `just gates` runs them
```
