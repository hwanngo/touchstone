# Shell / Bash Standards

Shell is **glue**, not software. Use it for CI steps, justfile recipes, entrypoints, and
one-off automation. When a script grows beyond its natural scope, rewrite it — see
[§8 When to stop](#8-when-to-stop-using-bash).

---

## 1. Safety preamble

Every executable script starts with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

| Flag | Effect |
|------|--------|
| `-e` | Exit on first unhandled error |
| `-u` | Unbound variable is a fatal error |
| `-o pipefail` | Pipeline fails if any stage fails, not just the last |

Do **not** rely on `-e` alone as implicit error handling — make exit codes explicit.
`IFS` is usually left at default; if you change it, restore it (`local IFS=$'\n'`).

---

## 2. Lint and format

| Tool | Role | Enforcement |
|------|------|-------------|
| [shellcheck](https://www.shellcheck.net/) | Static analysis | CI + pre-commit; **warnings = errors** (`--severity=warning`) |
| [shfmt](https://github.com/mvdan/sh) | Formatting | pre-commit (`shfmt -w -i 2`) |

Wire both into pre-commit and CI. See [ci-cd.md](../platform/ci-cd.md) and the shared
hook config in [collaboration.md](../practices/collaboration.md).

```bash
# CI enforcement
shellcheck --severity=warning scripts/**/*.sh
shfmt -d -i 2 scripts/          # diff-only; non-zero exit = unformatted
```

`shellcheck` is shebang-aware: a `#!/bin/sh` file is checked against POSIX; a
`#!/usr/bin/env bash` file is checked against bash. Do not suppress SC codes without a
comment explaining why.

---

## 3. Quoting and expansion

**Rule: when in doubt, quote it.**

```bash
# Good
echo "$var"
cp "$src" "$dest"
some_fn "$@"              # forward all args, preserving word boundaries

# Bad
echo $var                 # splits on IFS, globs
some_fn $@                # breaks on args with spaces
```

- Use `[[ ]]` for conditionals — no word-splitting surprises, supports `=~`, `&&`/`||`.
- Never `[ ]` in bash scripts (POSIX sh only).
- Use arrays for lists: `files=( a.txt "b c.txt" ); process "${files[@]}"`.
- **Never parse `ls`** — filenames can contain newlines and spaces.
- Use `find -print0` + `read -d ''` for robust filename iteration:

```bash
while IFS= read -r -d '' f; do
  process "$f"
done < <(find . -name "*.log" -print0)
```

---

## 4. Robustness

```bash
cleanup() { rm -f "$tmpfile"; }
trap 'cleanup' EXIT          # runs on exit, error, and signal

tmpfile=$(mktemp)            # never hardcode /tmp/foo

# Guard external commands
require_cmd() {
  command -v "$1" &>/dev/null || { echo "Missing: $1" >&2; exit 1; }
}
require_cmd jq
require_cmd curl
```

- Use **long flags** in scripts (`--recursive` not `-r`) — scripts are read later.
- Declare function-local vars with `local`: `local result=""`.
- Return meaningful exit codes; document non-zero meanings in a comment block.
- Prefer `printf` over `echo` for portability within scripts.

---

## 5. Security

| Risk | Rule |
|------|------|
| Injection | Always quote expansions; never interpolate untrusted input into commands |
| `eval` | **Never `eval` untrusted input.** If you must `eval`, document why and sanitize first |
| `curl \| sh` | Forbidden in CI without pinned URL + checksum verification. Prefer downloading, verifying, then executing |
| Secrets in args | **No secrets in `$@` or positional args** — visible in `ps aux`. Use env vars or files with tight permissions |

```bash
# Bad — secret visible in process list
./deploy.sh --token=s3cr3t

# Good
DEPLOY_TOKEN="$secret" ./deploy.sh
```

For secret files: `chmod 600`; clean up with `trap`.

---

## 6. Portability

Target **bash**, not POSIX sh, unless a `#!/bin/sh` constraint exists (Alpine
containers, minimal CI images). If you need POSIX sh, annotate the shebang and let
`shellcheck` enforce it:

```bash
#!/bin/sh
# Intentionally POSIX sh — runs in Alpine base image
```

Do not use bashisms (`[[ ]]`, `local`, arrays, `$((...))` extensions) in `#!/bin/sh` files.

---

## 7. Style conventions

- One logical operation per line; avoid `;`-chained one-liners beyond trivial guards.
- Functions over repeated blocks: name them as verbs (`setup_env`, `run_migrations`).
- Top-level `main()` + `main "$@"` pattern for non-trivial scripts.
- Keep scripts under **50 lines** of logic (excluding comments/blank lines) — if you
  are approaching 100, see §8.

---

## 8. When to stop using bash

> **Hard rule**: if a script exceeds ~100 lines, needs arrays-of-structs, parses JSON,
> or requires real error handling with recovery logic — **rewrite it**.

| Need | Reach for |
|------|-----------|
| JSON parsing / data transformation | [python.md](python.md) |
| CLI tool / daemon / typed config | [golang.md](golang.md) |
| Complex control flow with retries | [python.md](python.md) |
| Multi-step orchestration | [python.md](python.md) or a proper task runner |

`jq` is acceptable for one-liner JSON extraction in shell; anything beyond that belongs
in Python.

---

## Definition of done

- [ ] Every script has `#!/usr/bin/env bash` and `set -euo pipefail`
- [ ] `shellcheck --severity=warning` passes with zero findings
- [ ] `shfmt -d` produces no diff
- [ ] Both checks run in pre-commit and CI ([ci-cd.md](../platform/ci-cd.md))
- [ ] No unquoted expansions; arrays used for multi-word lists
- [ ] Temp files use `mktemp` and are cleaned up via `trap`
- [ ] No secrets passed as command-line arguments
- [ ] No `eval` of untrusted input
- [ ] Scripts over 100 lines of logic are flagged for rewrite in Python or Go
- [ ] External command dependencies are checked at script start
