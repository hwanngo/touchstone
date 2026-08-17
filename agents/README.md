# Agents

Claude Code **subagent** definitions the kit ships. Same shape as [`hooks/`](../hooks/README.md):
this directory is the source of truth, and a consuming repo installs a copy where its agent tool
looks for them — for Claude Code, `.claude/agents/<name>.md`.

Each file is a subagent in the Claude Code format: YAML frontmatter (`name`, `description`, and
optionally `tools` and `model`), then the system prompt as the body. `name` matches the filename,
and `description` is the trigger text the main agent routes on — write it as *when to use this*,
not as a summary of what it does.

| Agent | Use when |
|---|---|
| [`standards-auditor.md`](standards-auditor.md) | A repo needs scoring against the standards: adoption readiness, a pre-release conformance pass, or a maturity-level claim that needs proving. Reports gaps with the level at which each becomes required, and routes to the governing doc. |
| [`currency-researcher.md`](currency-researcher.md) | The technical claims in a standards doc need re-checking against upstream — versions, tool defaults, security guidance. Verifies against primary sources and reports what has drifted. |
| [`adoption-doctor.md`](adoption-doctor.md) | An adopting repo's installed toolchain needs to be proven to actually work, not just be present: can it commit, does `just lint` pass fresh, does `just fmt` leave `.touchstone/` alone, do `AGENTS.md` links resolve, can the installed gates fail. Reports which real, previously-shipped defect class it reproduces. |
| [`guardrail-redteam.md`](guardrail-redteam.md) | The `block-secrets.sh`/`guard-bash.sh` PreToolUse guards need adversarial testing — after a change to either hook, before a release that claims the guards still hold, or to check a specific bypass idea. Attacks a scratch copy using the hooks' own source as the map, and reports every attempt with its verbatim input and real decision. |
| [`drift-watcher.md`](drift-watcher.md) | A scheduled sweep for standards docs whose claims have gone stale, run with no doc named in advance. Triages every doc under `standards/` for staleness signals, verifies the candidates it flags against a primary source (or the repo itself, for a repo-internal claim), and reports a risk-ranked list — routing any heavily-flagged doc to `currency-researcher` for a full audit. |
| [`eval-runner.md`](eval-runner.md) | The eval suite needs to be run and checked for regressions — after an `agents/*.md` change, or on a schedule. Drives `check-evals.sh`/`run-eval.sh`/`score-eval.sh` across every case, states which cases produced evidence and which were skipped and why, and reports a regression verdict against `evals/BASELINE.md`. |

All six are **read-only reporters**. None edits the repo, case, or standard it examines: the
auditor, the doctor, the red-teamer, the watcher and the runner each produce findings a human turns
into issues, and the researcher produces drift a human turns into a reviewed PR to
[`standards/`](../standards/README.md). That split is deliberate — the standards are the kit's
product, and they change through review.

## The gate

[`scripts/check-agents.sh`](../scripts/check-agents.sh) validates every definition here on each
`just gates` / CI run: frontmatter parses, `name` matches the filename, `description` is loadable
YAML and trigger-phrased, `tools`/`model` are well-formed, the body is a real system prompt that
routes to a `standards/*.md` doc, and every `*.md` pointer resolves inside the repo. Zero agents
examined is a failure, not a pass. `README.md` is the one file here that is not a subagent
definition, so the gate skips it by name — everything else in this directory must be one.
