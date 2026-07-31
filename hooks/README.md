# Agent hooks

Optional **Claude Code hooks** that enforce touchstone standards at the *agent* layer — the gap a
pre-commit hook can't cover, because an agent can edit files and run commands long before a commit.
They mirror the pattern [superpowers](https://github.com/obra/superpowers) uses (a `SessionStart`
hook that injects the foundational rules), extended with a few narrow guards.

## What ships

| Hook | Event | Block / warn | Does |
|---|---|---|---|
| `touchstone-context.sh` | SessionStart · UserPromptSubmit | inject-only | Surfaces the touchstone **hard rules** (from `AGENTS.md`) into the agent's context so it obeys them from the first action. |
| `guard-bash.sh` | PreToolUse(Bash) | **deny** | Blocks git-hook bypasses, unleased force-pushes, and `.env`-family writes — see [the full deny set](#what-the-bash-guard-denies). |
| `block-secrets.sh` | PreToolUse(Write\|Edit\|MultiEdit\|NotebookEdit) | **deny** | Blocks writing a real `.env` or a private key into the repo. |
| `format-touched.sh` | PostToolUse(Write\|Edit\|MultiEdit\|NotebookEdit) | warn-only | Runs the standard formatter on the file just edited, resolved **project-locally first** — see [how it finds a formatter](#how-format-touched-finds-a-formatter). Never silent: it says so when it reformats the file, when the formatter fails, and when none is installed. |
| `audit-touched.sh` | PostToolUse(Write\|Edit\|MultiEdit\|NotebookEdit) | warn-only | When a `SKILL.md` or `standards/*.md` is edited, runs the matching auditor (`check-skills`/`check-standards`) and surfaces that file's violations immediately — catches a malformed instruction file long before commit. Skips silently if the repo doesn't ship the auditors. |
| `nudge-ci.sh` | Stop | warn-only | Reminds the agent to run `just ci` and show output before claiming done. |

**All hooks fail open**: a missing tool, bad input, or error lets the action proceed — hooks never
wedge your session. Only the two `PreToolUse` guards block, and only on unambiguous patterns. The
one dependency is **`jq`** (without it the hooks no-op, and every hook that can says so).

**Fail open is not the same as fall silent.** A hook that cannot act must announce it, exactly as a
gate that cannot scan must refuse rather than pass — otherwise "nothing happened" and "everything
was fine" are indistinguishable. `guard-bash.sh` and `block-secrets.sh` already emitted a
`"the guard is OFF"` `systemMessage`; `format-touched.sh` did not, and was a silent no-op in every
standards-compliant repo for exactly as long as nobody checked. It now reports all four outcomes.

### How format-touched finds a formatter

Hard rule 1 mandates `uv` and `pnpm`, which install formatters **into the project**, not onto
`PATH`. A `command -v ruff` check therefore finds nothing in a compliant repo — which is what the
first version of this hook did, so it formatted nothing and said nothing. Resolution is now
project-local first, and every outcome is reported:

| Language | 1. project env | 2. project runner | 3. `PATH` | 4. none |
|---|---|---|---|---|
| `.py` | `.venv/bin/ruff` | `uv run --project <root> ruff` | `ruff` | says `uv add --dev ruff` |
| `.ts .tsx .js .jsx .mjs .cjs .json .jsonc` | `node_modules/.bin/biome` | `pnpm --dir <root> exec biome` | `biome` | says `pnpm add -D @biomejs/biome` |
| `.go` | — | — | `gofumpt` | says `go install mvdan.cc/gofumpt@latest` |

`<root>` is the nearest ancestor of the edited file holding `pyproject.toml`/`uv.lock` (Python) or
`package.json` (Node), never above the git work tree — so in a monorepo the nearest package wins.

Tier 1 exists because tiers 2 and 3 resolve to the same binary while paying a process-launch (and
possibly an environment-sync) cost on every single file write. Tier 2 still matters: it is what
finds the toolchain when the environment is not at the default `.venv`/`node_modules` path.

Four outcomes, all of them spoken:

- **Reformatted** — an `additionalContext` note telling the agent its in-context copy is now stale.
- **Formatter failed** — a `systemMessage` naming the tool, the exit code and the first lines of
  its own diagnostics. The status of the *format* step is what is reported; the status of the
  autofix step (`ruff check --fix`, `biome check --write`) is deliberately dropped, because
  non-zero there just means ordinary un-autofixable lint findings remain.
- **No formatter installed** — a `systemMessage` with the exact `uv`/`pnpm` command to install it,
  emitted **once per session per language** rather than on every edit: it is a setup problem, not
  an event.
- **File is inside `.touchstone/`** — skipped and said so. Formatting the vendored kit would dirty
  the submodule pin the whole adoption model rests on.

### What the Bash guard denies

The full deny set, so nothing blocks you without warning:

| Denied | Do this instead |
|---|---|
| `git commit/push --no-verify` (and any `--no-ver…` prefix) | fix the failing gate |
| `git commit -n`, or a short cluster containing it (`-nq`) | fix the failing gate |
| `git -c core.hooksPath=… commit/push` | fix the failing gate |
| `HUSKY=0`, `SKIP=…`, `PRE_COMMIT_ALLOW_NO_CONFIG=…` in front of `git commit/push` | fix the failing gate |
| `git push --force` / `-f` / a short cluster containing `-f`, without a lease | `git push --force-with-lease` |
| `git push origin +branch` (a force refspec) | `git push --force-with-lease` |
| Writing a `.env`-family file through a Bash redirect, `tee`, `cp`, `mv` or `sed -i` | keep secrets out of the repo |

Two of those are worth calling out because they are *not* pure bypasses:

- **`SKIP=<hook-id> git commit`** is a legitimate pre-commit idiom for skipping one named hook. The
  guard denies it anyway, because it cannot tell a targeted skip from `SKIP=` used to disable the
  hook that is failing. Run the commit without the prefix, or fix the hook.
- **`git push -o <push-option>`** is fine, but `-fd`/`-df` (force + delete) is denied like any
  other force-push, and `git mv onto-a.env-name` is denied because `mv` is a write command
  wherever it appears.

The guard checks **file names only** for the `.env` family (`.env`, `.env.*`, `.envrc`, `*.env`,
minus `*.example.*`/`*.sample.*`/`*.template.*`). It does **not** inspect content and has **no
private-key detection at all** — neither by filename nor by body. Only `block-secrets.sh`, on the
Write/Edit tools, checks for private-key *content*.

**What the Bash guard does not see.** Commands are analyzed by redacting quoted spans and
comments, then splitting into segments on `;`, `&&`, `||`, `|`, `|&`, a bare `&`, a **newline**,
and grouping characters (`(` `)` `{` `}`), evaluating each segment independently. Before testing
for `git`, a fixed set of leading shell keywords (`if`/`while`/`for`/`case`/`eval`/`sudo`/`env`/…)
and leading redirections are skipped, and a word glued to a redirect operator (`git>out`) is split
apart first. The command word may carry a path (`/usr/bin/git`). A second, unredacted view of the
same buffer — built from the same scan, characters outside a safe whitelist replaced — is what the
rules actually read, so a quoted flag (`git push "--force"`) or a quoted `.env` target is still
seen; only actual redirect targets and `tee`/`cp`/`mv`/`sed -i` arguments are treated as write
targets, never every token in the segment.

Because a newline is a segment separator, a **heredoc body** is analyzed line by line like any
other input: a line inside a `<<'EOF'` block that reads like a policy violation is denied even
though the shell would never execute it.

The guard matches literal argv tokens in the command string it is handed — it does not interpret
the shell. That is what makes the following accepted limits (not an exhaustive list) inherent
rather than incidental bugs, each verified against the live hook:

- **Command substitution** (`git push $(echo --force)`) and the contents of an **`eval`** string
  are not analyzed.
- **A value arriving through variable expansion**: `X=--force; git push $X origin main` allows —
  the literal token the guard sees is `$X`, not `--force`.
- **A nested interpreter**: `bash -c "git push --force origin main"` allows — the guarded flag is
  inside a string literal passed to another shell, not a token in the outer command.
- **A quoted `-c core.hooksPath=` value or a quoted force refspec**: `git -c "core.hooksPath=/dev/null"
  commit` and `git push origin "+main:main"` allow, while their unquoted forms deny. The unredacted
  view maps `=` and `+` to `_`, so those two patterns no longer match. The *flag* rules
  (`--no-verify`, `--force`, `-n`, `-f`) are **not** affected — quoting those is caught.
- **A quoted commit message that is a single hyphen-led word of letters** (`-m "-nope"`) denies:
  with the quotes stripped it is textually identical to a flag cluster. Any space, digit or
  punctuation in the message avoids this — which is every ordinary message.

Closing any of these would require actually interpreting the shell (tracking variable
assignments, expanding substitutions, recursing into nested interpreters) rather than matching
tokens, which is a different, much larger guard than this one. These are fail-open advisory
guards, not a sandbox — `pre-commit` and branch protection are the enforcing layers.

## Install

```bash
./scripts/init.sh --with-hooks          # copies hooks/ -> .claude/hooks/ and the settings template
```

Or manually: copy `hooks/*.sh` to `.claude/hooks/` **and `hooks/lib/*.sh` to
`.claude/hooks/lib/`** (`chmod +x`), then merge
[`templates/claude-settings.json`](../templates/claude-settings.json) into `.claude/settings.json`
(`init.sh` won't clobber an existing settings file — merge by hand). The `lib/` copy is not
optional: both `PreToolUse` guards source `lib/secret-paths.sh` at runtime, and a flat `hooks/*.sh`
glob silently misses it — the hooks then announce they are degraded and every `.env`-name check is
off.

## Opt out

Delete the relevant block from `.claude/settings.json`, or don't pass `--with-hooks`. The hooks are
opt-in precisely because they change agent behaviour and run shell on your machine — **review them
before adopting.**

## Composition

They **delegate**, they don't duplicate: `format-touched` invokes the same formatters, out of the
same project environment, that `just fmt` and pre-commit do (`uv run ruff`, `pnpm exec biome`,
`gofumpt`) — see [the resolution table](#how-format-touched-finds-a-formatter) — and `nudge-ci`
points at `just ci`. Pre-commit + CI remain the source of truth; these just move enforcement
earlier, to the agent.

The deny messages cite a standard by path, and that path is resolved **at runtime**: `standards/…`
inside the kit, `.touchstone/standards/…` in a repo that vendored the kit. A hard-coded `standards/`
routed the agent to a directory that does not exist in an adopter — which is every repo these hooks
are actually installed into.
