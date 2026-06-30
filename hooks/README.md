# Agent hooks

Optional **Claude Code hooks** that enforce touchstone standards at the *agent* layer — the gap a
pre-commit hook can't cover, because an agent can edit files and run commands long before a commit.
They mirror the pattern [superpowers](https://github.com/obra/superpowers) uses (a `SessionStart`
hook that injects the foundational rules), extended with a few narrow guards.

## What ships

| Hook | Event | Block / warn | Does |
|---|---|---|---|
| `touchstone-context.sh` | SessionStart · UserPromptSubmit | inject-only | Surfaces the touchstone **hard rules** (from `AGENTS.md`) into the agent's context so it obeys them from the first action. |
| `guard-bash.sh` | PreToolUse(Bash) | **deny** | Blocks `git … --no-verify` and bare `git push --force` (use `--force-with-lease`). |
| `block-secrets.sh` | PreToolUse(Write\|Edit) | **deny** | Blocks writing a real `.env` or a private key into the repo. |
| `format-touched.sh` | PostToolUse(Write\|Edit) | warn-only | Runs the standard formatter (ruff/Biome/gofumpt) on the file just edited. |
| `audit-touched.sh` | PostToolUse(Write\|Edit) | warn-only | When a `SKILL.md` or `standards/*.md` is edited, runs the matching auditor (`check-skills`/`check-standards`) and surfaces that file's violations immediately — catches a malformed instruction file long before commit. Skips silently if the repo doesn't ship the auditors. |
| `nudge-ci.sh` | Stop | warn-only | Reminds the agent to run `just ci` and show output before claiming done. |

**All hooks fail open**: a missing tool, bad input, or error lets the action proceed — hooks never
wedge your session. Only the two `PreToolUse` guards block, and only on unambiguous patterns. The
one dependency is **`jq`** (without it the hooks no-op).

## Install

```bash
./scripts/init.sh --with-hooks          # copies hooks/ -> .claude/hooks/ and the settings template
```

Or manually: copy `hooks/*.sh` to `.claude/hooks/` (`chmod +x`), then merge
[`templates/claude-settings.json`](../templates/claude-settings.json) into `.claude/settings.json`
(`init.sh` won't clobber an existing settings file — merge by hand).

## Opt out

Delete the relevant block from `.claude/settings.json`, or don't pass `--with-hooks`. The hooks are
opt-in precisely because they change agent behaviour and run shell on your machine — **review them
before adopting.**

## Composition

They **delegate**, they don't duplicate: `format-touched` runs the same formatters as the justfile /
pre-commit, and `nudge-ci` points at `just ci`. Pre-commit + CI remain the source of truth; these
just move enforcement earlier, to the agent.
