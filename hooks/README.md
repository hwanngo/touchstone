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
| `git commit/push/merge --no-verify` (and any `--no-ver…` prefix except `--no-verb…` and `--no-verify-…`) | fix the failing gate |
| `git commit -n`, or a short cluster containing it (`-nq`) | fix the failing gate |
| `git -c core.hooksPath=… commit/push/merge`, `git -ccore.hooksPath=…`, `git --config-env=core.hooksPath=…` (the key is matched case-insensitively, as git itself matches it) | fix the failing gate |
| `git config [--local/--global/--system] core.hooksPath <path>` — a *persistent* hook disable | fix the failing gate |
| `HUSKY=0`, `HUSKY_SKIP_HOOKS=…`, `SKIP=…`, `PRE_COMMIT_ALLOW_NO_CONFIG=…`, `GIT_CONFIG_KEY_n=core.hooksPath` in front of `git commit/push/merge` | fix the failing gate |
| `git push --force` / `-f` / a short cluster containing `-f`, without a lease | `git push --force-with-lease` |
| `git push --force --force-if-includes` (`--force` disables the lease checks, so this is not a lease) | `git push --force-with-lease` |
| `git push origin +branch` (a force refspec) | `git push --force-with-lease` |
| Writing a `.env`-family file through a Bash redirect (`>`, `>>`, `>\|`, `&>`, `<>`), `tee`, `cp`, `mv`, `install`, `rsync`, `ln`, `dd of=`, curl/wget's output option in any of its spellings (`-o`/`-O`, attached `-o.env`/`-O.env`, `--output=`/`--output-document=`), or an in-place `sed -i`/`perl -pi` | keep secrets out of the repo |

All of those are recognized behind a **leading wrapper** (`sudo -u deploy`, `doas`, `env -i`,
`command -p`, `timeout 60`, `nice -n 10`) and behind a **path-qualified command word**
(`/usr/bin/git`, `/bin/cp`) — but only for that fixed wrapper set, so `echo git push --force`,
which pushes nothing, still allows.

Three of those are worth calling out because they are *not* pure bypasses:

- **`SKIP=<hook-id> git commit`** is a legitimate pre-commit idiom for skipping one named hook. The
  guard denies it anyway, because it cannot tell a targeted skip from `SKIP=` used to disable the
  hook that is failing. Run the commit without the prefix, or fix the hook.
- **`git push -o <push-option>`** is fine, but `-fd`/`-df` (force + delete) is denied like any
  other force-push.
- **`git config core.hooksPath`** denies only a *set*. `--get`, `--list` and `--unset` are allowed
  — unsetting the key is how you undo the bypass, so denying it would block the fix.

A writer is recognized **at the command word only** (after any leading assignments, wrapper
keywords and wrapper options), or in a multi-call *shell-utility* dispatcher's subcommand slot
(`busybox cp`, `toybox mv`). A writer *name* that is merely an argument is not a write:
`grep -l cp .env` reads a file and is allowed. `git mv old.env new.env` is allowed too — it
renames a file git already tracks, so no secret content enters the repo that was not already in
it. The redirect rule is what covers git (`git config -l > .env` still denies).

Flag **values** are not scanned as flags. `git commit -m "-nope"` commits with that message and
is allowed; `git push -o --force` sets a push-option string and force-pushes nothing. Exactly one
word is consumed, so `git commit -m x --no-verify` still denies.

`--no-verbose` is **allowed**. It is parse-options auto-negation of `-v/--verbose` and has nothing
to do with hooks; `--no-verb…` is the shortest prefix that belongs to it and not to `--no-verify`.

`--no-verify-signatures` is **allowed** too, and so is any prefix of it that is longer than
`--no-verify` itself (`--no-verify-s…`, `--no-verify-`). It is a real option of `git merge` and
`git pull` — the negation of `--verify-signatures` — and has nothing to do with hooks either; the
earlier fix missed it because it is spelled with the whole `--no-verify` prefix in front. None of
those spellings can reach git's `--no-verify`, which is a *shorter* string and so is not prefixed
by any of them.

So there are **two** carve-outs, not one: `--no-verb…` and `--no-verify-…`. Everything else under
`--no-ver…` stays denied — `--no-verify` itself, and the shorter abbreviations `--no-ver`,
`--no-veri`, `--no-verif`, which for `git commit`/`git push` really do resolve to `--no-verify`.

The guard checks **file names only** for the `.env` family (`.env`, `.env.*`, `.env-*`, `.env_*`,
`.envrc`, `.envrc.*`, `.flaskenv`, `*.env`, and the dotless `env.<deployment-stage>`, minus
`*.example.*`/`*.sample.*`/`*.template.*`; a trailing `~` is stripped first, so `.env~` denies and
`README.md~` does not). It does **not** inspect content and has **no private-key detection at
all** — neither by filename nor by body. Only `block-secrets.sh`, on the Write/Edit tools, checks
for private-key *content*.

The dotless family is matched against a fixed list of stage words (`env.production`, `env.staging`,
`env.local`, …) rather than a blanket `env.*`, and that narrowness is deliberate: `src/env.ts`,
`src/env.mjs` and `env.d.ts` are ordinary application source in every modern TypeScript project.
A blanket rule would deny writing them, and a guard that blocks legitimate work gets switched off.

**What the Bash guard does not see.** Commands are analyzed by redacting quoted spans and
comments, then splitting into segments on `;`, `&&`, `||`, `|`, `|&`, a bare `&`, a **newline**,
and grouping `(` `)` `{` `}`, evaluating each segment independently. Three of those separators are
*conditional*, because each is also an ordinary character inside a token: `&` does not separate
next to a redirection arrow (`2>&1`), `|` does not separate after a `>` (`>|` is the
noclobber-override redirect), and `{`/`}` separate only where bash reads them as command grouping
— `{` followed by whitespace, `}` preceded by whitespace. That last one is what keeps
`cat secrets.txt > ${HOME}/.env` in one piece; splitting it unconditionally left no segment
holding both the redirect and its target. A brace group containing a **comma** is expanded before
the name test, so `cp .env{,.bak}` is seen, while `cp .env.example{,.bak}` still allows.

Before testing for `git`, a fixed set of leading shell keywords
(`if`/`while`/`for`/`case`/`eval`/`sudo`/`doas`/`env`/`timeout`/`nice`/…) and leading redirections
are skipped — for the wrappers in that set, their own options are skipped too — and a word glued
to a redirect operator (`git>out`) is split apart first. The command word may carry a path
(`/usr/bin/git`, `/bin/cp`). A second, unredacted view of the same buffer — built from the same
scan, characters outside a safe whitelist replaced — is what the rules actually read, so a quoted
flag (`git push "--force"`) or a quoted `.env` target is still seen; only actual redirect targets
and the arguments of a writer *at the command word* are treated as write targets, never every
token in the segment.

A **heredoc body** is skipped. It is data the shell feeds a command on stdin, never command text,
so a line inside a `<<'EOF'` block that merely *describes* a banned command is not a violation —
writing `docs/policy.md` that explains why force-pushing is banned used to be denied for saying
so. The heredoc operator is detected inside the scanner rather than by a text pre-pass, because
only the scanner knows quote state: a `<<` inside a quoted string (`echo "a << b"`) must not start
a heredoc, and mis-detecting one would swallow following lines of real command text. The
**command line itself is still analyzed in full**, so `cat <<EOF > .env` still denies on its
redirect target, and command text after the terminator line is command text again.

That swallow hazard was **real, not hypothetical**: `n=$((1<<3))` on one line and a force-push on
the next used to allow, because the delimiter scan stops at `)` and so read a heredoc with the
delimiter `3`, whose terminator line never came — the body-skip then dropped every remaining line
before any rule saw it. Two guards now make it unreachable, and both are asserted:

- **`<<` inside `$(( … ))` / `(( … ))` is left-shift, not a heredoc operator.** The scanner tracks
  arithmetic nesting for the same reason it tracks quotes — it is the only place that knows the
  `((` is not itself quoted, commented out, or backslash-escaped.
- **A delimiter with no terminator line ahead of it is not a heredoc at all.** Such a command could
  not run as written (the shell would block on stdin), so it is either a mis-parse or a deliberate
  swallow; either way its following lines are analyzed rather than dropped. This is what closes the
  multi-line spelling (`$((1` / `<<3))`) that arithmetic tracking alone cannot see.

The residual: an *unbalanced* unquoted `((` — `echo ((`, which is a bash syntax error — leaves the
scanner in arithmetic state, so a heredoc later in the same command string is not recognized and
its body is analyzed as command text. That is the bounded false positive this section is about,
on input no shell will run, and never a silent hole.

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
- **ANSI-C quoting**: `git push $'\x2d\x2dforce' origin main` allows, as do the octal
  (`$'\055\055force'`) and `--` spellings, and the same trick on
  `--no-verify`, `-n`, `-f` and on a redirect target (`> $'\x2eenv'`). This is a **verified live
  bypass, not a theoretical one** — the `\x` and octal forms expand in bash 3.2, `sh` and zsh, and
  `\u` expands in zsh (bash 3.2 passes it through literally). It stays open on a triage judgment,
  not because it is hard: nobody writes a hex-escaped `--force` by accident, so it fires only
  under deliberate obfuscation, and decoding escape sequences inside the guard's single
  load-bearing scanner would mean interpreting the shell rather than matching its tokens — the
  same line every other limit here sits behind, on the piece of code where a mistake is most
  expensive.
- **`git push --mirror`** allows. It force-updates *and deletes* remote refs with no lease, so it
  is squarely the harm the force-push rule exists to prevent — but it is also the documented way
  to maintain a mirror, a distinct workflow rather than a spelling of `--force`. Adding it would
  change what the deny table *means*, which is a policy decision for this kit's owner and not a
  matcher fix; it is listed here so the gap is known rather than silent.

Closing the first four of these would require actually interpreting the shell (tracking variable
assignments, expanding substitutions, recursing into nested interpreters) rather than matching
tokens, which is a different, much larger guard than this one. These are fail-open advisory
guards, not a sandbox — `pre-commit` and branch protection are the enforcing layers.

### What the Write guard denies, and what it deliberately does not

`block-secrets.sh` denies a write whose **path** is in the `.env` family above, and a write whose
**content** contains a private key: a PEM `BEGIN` **or** `END` line with four or five dashes and a
label that may contain digits (so the RFC 4716 / ssh.com `---- BEGIN SSH2 ENCRYPTED PRIVATE KEY
----` spelling is covered, and a key whose header is mangled but whose footer is intact no longer
walks through), or a PuTTY `.ppk` header line. A single `MultiEdit` is checked both with its edits
joined by newlines and joined by nothing, so one call cannot reassemble a header on disk out of
two fragments that never share a line.

Its stated limits:

- **The header must begin a line** (indentation allowed, for keys embedded in YAML or JSON).
  Security documentation that quotes a header mid-sentence is allowed — writing the docs that
  explain what a private key looks like is work this kit exists to do, and denying it was a false
  positive that trained people to switch the guard off.
- **A `fixtures`/`testdata`/`test-fixtures`/`__fixtures__` path component exempts the *content*
  check.** Crypto, TLS and SSH suites legitimately commit throwaway test keys. The exemption is a
  full path component, never a substring, and it does **not** relax the path check: a
  `tests/fixtures/.env` is still denied — asserted, not merely claimed, by the `path_case deny
  "tests/fixtures/.env"` rows in `tests/hooks/block-secrets.test.sh`.
- **Private keys only.** AWS access keys, database passwords and other non-PEM credential material
  are out of scope by design; `gitleaks` in pre-commit and CI is the backstop for those.
- **No cross-call state.** Two Write/Edit calls that are innocuous individually and assemble a key
  between them are not detected. Each hook invocation sees one tool call and nothing else. Two edits
  in ONE `MultiEdit` call are a different case and *are* detected, for both the PEM header and the
  PuTTY magic line: the guard matches a second view of the same fields joined with no separator.
- **Templating suffixes are not stripped**, so `secrets/db.env.j2` allows. A `.j2`/`.tpl`/`.tmpl`
  file is a template meant to be committed — the same reason `*.example.*` is allowlisted — and
  stripping the suffix would deny ordinary template work.

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
