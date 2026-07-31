---
name: shell-standards
description: Use when writing or editing a shell/bash script in a touchstone repo — CI steps, justfile recipes, entrypoints, agent hooks, or one-off automation (.sh files, a `#!/usr/bin/env bash` shebang). Covers the safety preamble, shellcheck + shfmt, quoting, robustness, and when to stop and rewrite in Python/Go. Not for application code — see the per-language skills.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Shell / Bash (language)

Full standard: **`standards/languages/shell.md`**. Shell is glue, not software — keep it small.
Load-bearing rules:

## Always
- **Safety preamble:** `#!/usr/bin/env bash` + `set -euo pipefail`; make exit codes explicit (don't lean on `-e` alone).
- **Lint + format:** **shellcheck** (`--severity=warning`, warnings = errors) + **shfmt** (`-i 2`), both in pre-commit and CI; never suppress an `SC` code without a comment saying why.
- **Quote every expansion** (`"$var"`, `"$@"`); use `[[ ]]` not `[ ]`; arrays for lists; never parse `ls` — use `find -print0` + `read -r -d ''`.

## Don't get burned
- **`mktemp` + `trap cleanup EXIT`** for temp files; check external commands up front (`command -v`).
- **Security:** never `eval` untrusted input; no secrets in argv (visible in `ps`) — pass via env/files (`chmod 600`); no unpinned `curl | sh`.
- `local` for function vars, long flags in scripts, `printf` over `echo`, a `main "$@"` entry for non-trivial scripts.

## Done
`shellcheck --severity=warning` clean · `shfmt -d` no diff · preamble present · expansions quoted · temp files `trap`-cleaned · no secrets in argv · scripts past ~100 lines of logic flagged for a Python/Go rewrite. See `standards/languages/shell.md`.
