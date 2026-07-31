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

Both are **read-only reporters**. Neither edits the repo it audits: the auditor produces findings a
human turns into issues, and the researcher produces drift a human turns into a reviewed PR to
[`standards/`](../standards/README.md). That split is deliberate — the standards are the kit's
product, and they change through review.

## The gate

[`scripts/check-agents.sh`](../scripts/check-agents.sh) validates every definition here on each
`just gates` / CI run: frontmatter parses, `name` matches the filename, `description` is loadable
YAML and trigger-phrased, `tools`/`model` are well-formed, the body is a real system prompt that
routes to a `standards/*.md` doc, and every `*.md` pointer resolves inside the repo. Zero agents
examined is a failure, not a pass. `README.md` is the one file here that is not a subagent
definition, so the gate skips it by name — everything else in this directory must be one.
