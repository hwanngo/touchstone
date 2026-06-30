# Scripts

Kit tooling — pure `bash` + `awk`/`grep`/`diff` (no `jq`/`yq`/node), so CI needs zero install.
All follow the shell standard ([`standards/languages/shell.md`](../standards/languages/shell.md))
and the shared header format (`templates/script-header.sh`).

| Script | Purpose | Used by |
|---|---|---|
| [`bootstrap.sh`](bootstrap.sh) | One-command adoption: vendor the kit as a pinned submodule (`.touchstone`) then run `init.sh`. Run from a kit clone inside your target repo. `--ref`/`--url`; other flags pass through. No `curl\|sh`. | adopters |
| [`init.sh`](init.sh) | Apply the kit to a repo: detect stack, **generate** per-tool pointer files, drop in matching templates + CI, write `.touchstone.toml`. `--dry-run`/`--force`/`--with-hooks`. | adopters |
| [`check-sync.sh`](check-sync.sh) | Drift check: compare a consuming repo's pinned version + managed files against the kit. | adopters' CI |
| [`check-skills.sh`](check-skills.sh) | Audit every `SKILL.md` against the Agent Skills spec + the touchstone template: frontmatter, `name`==dir, trigger-phrased description, `license`+`metadata.version`(==VERSION), the `Full standard:`/`## Done` spine, language-tagged fences, real standards ref, no drift markers. | this repo's CI + `just lint-skills` |
| [`check-standards.sh`](check-standards.sh) | Audit every `standards/*/*.md` against the doc template: H1, bare `## Definition of done`, periodised `## N.` headings, language-tagged fences; reports docs with no dedicated skill. | this repo's CI + `just lint-skills` |
| [`check-skill-quality.sh`](check-skill-quality.sh) | **Warn-only** description-quality gate: vague verbs, boilerplate openings, openings duplicated across skills. | this repo's CI (advisory) |
| [`check-links.sh`](check-links.sh) | Verify every relative Markdown link resolves to a real file. | this repo's CI |
| [`gen-skill-catalog.sh`](gen-skill-catalog.sh) | Generate [`skills/CATALOG.md`](../skills/CATALOG.md) (a machine index of every skill, bucketed by domain) from frontmatter. Deterministic; CI regenerates + diffs to catch staleness. | `just skill-catalog` + CI |
| [`bump-version.sh`](bump-version.sh) | Set the kit version everywhere at once (VERSION, all skill `metadata.version`, template, plugin) so the version-consistency gate stays green. `usage: bump-version.sh X.Y.Z` | releases |

**Convention:** scripts that operate on a repo and need to surface *all* problems use
`set -uo pipefail` (no `-e`) and aggregate failures into one exit code (`check-skills`,
`check-standards`, `check-links`); scripts that should abort on first error use `set -euo pipefail`
(`init`, `check-sync`, `bump-version`). Each script's header comment states which and why.

```bash
bash scripts/check-skills.sh && bash scripts/check-standards.sh && bash scripts/check-links.sh   # core CI gates
```
