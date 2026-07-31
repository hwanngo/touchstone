#!/usr/bin/env bash
# PostToolUse(Write|Edit|MultiEdit|NotebookEdit): format the file the agent just touched with the
# SAME formatter the justfile runs. Never blocks; always exits 0.
#
# Why this was rewritten. The previous version resolved formatters with `command -v ruff` /
# `command -v biome`. Hard rule 1 mandates uv and pnpm, i.e. PROJECT-LOCAL tools: after
# `uv add --dev ruff` and `pnpm add -D @biomejs/biome` neither binary is on PATH, so in a
# standards-compliant repo — the only kind touchstone produces — the hook found nothing, formatted
# nothing, and said nothing. A hook that silently does nothing is the same defect class as a gate
# that silently passes, and hooks/README.md's claim that it "runs the same formatters as the
# justfile" was simply false.
#
# Resolution order per language, project-local FIRST, and every step reported:
#   1. the project's own environment (.venv/bin, node_modules/.bin) — the exact binary `uv run` /
#      `pnpm exec` would pick, without paying their startup cost or risking a network sync on every
#      keystroke-level edit;
#   2. `uv run` / `pnpm exec` — correct even when the environment lives somewhere non-default;
#   3. the PATH binary — a globally-installed tool is still better than no formatting;
#   4. nothing available → SAY SO (once per session per language), never fall silent.
#
# It also refuses to format anything under `.touchstone/`: rewriting files inside the pinned kit
# submodule dirties the pin the whole adoption model rests on.
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"systemMessage":"touchstone: jq not installed — format-touched is OFF (nothing was formatted)"}'
  exit 0
fi

input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
session="$(printf '%s' "$input" | jq -r '.session_id // "nosession"' 2>/dev/null)"
[ -n "$path" ] && [ -f "$path" ] || exit 0

sys="" # user-facing note (degraded toolchain)
ctx="" # agent-facing note (the file on disk changed under it)

emit() {
  if [ -n "$ctx" ] && [ -n "$sys" ]; then
    jq -n --arg c "$ctx" --arg s "$sys" \
      '{systemMessage: $s, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
  elif [ -n "$ctx" ]; then
    jq -n --arg c "$ctx" \
      '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
  elif [ -n "$sys" ]; then
    jq -n --arg s "$sys" '{systemMessage: $s}'
  fi
  exit 0
}

# Never rewrite the vendored kit — that is how an adopter's first green build silently dirties the
# submodule pin. Announced rather than skipped in silence.
case "$path" in
*/.touchstone/* | .touchstone/*)
  sys="touchstone: $path is inside the pinned .touchstone submodule — NOT formatted (formatting it would dirty the pin)."
  emit
  ;;
esac

# once <key> — true the first time this session asks about <key>. Keeps the "no formatter installed"
# notice honest without turning it into a per-edit nag: it is a one-off setup problem, not an event.
once() {
  local flag="${TMPDIR:-/tmp}/touchstone-fmt.$session.$1"
  [ -e "$flag" ] && return 1
  : >"$flag" 2>/dev/null || return 0
  return 0
}

# nearest_root <dir> <marker> — walk up from <dir> looking for <marker>, stopping at / (and at the
# git work-tree root when there is one, so the search never escapes the repo). Echoes the directory
# holding <marker>, or nothing. Handles monorepos: the nearest package.json wins, not the outermost.
nearest_root() {
  local dir="$1" marker="$2" stop=""
  stop="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || stop=""
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -e "$dir/$marker" ]; then
      printf '%s' "$dir"
      return 0
    fi
    [ -n "$stop" ] && [ "$dir" = "$stop" ] && return 1
    dir="$(dirname "$dir")"
  done
  return 1
}

filedir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P)" || filedir=""
[ -n "$filedir" ] || exit 0
before="$(cksum <"$path" 2>/dev/null)" || before=""

# ran_with records how the file was formatted, so the report can name the actual toolchain rather
# than a guess. Empty means no formatter ran. fmt_rc/fmt_out carry the FORMAT step's verdict.
ran_with=""
fmt_rc=0
fmt_out=""

# The two steps are deliberately separate invocations, because their exit statuses mean different
# things and only one of them is a defect:
#   fmt  — `ruff format` / `biome format --write` / `gofumpt -w`. Non-zero means the formatter could
#          not do its job: a broken install, or a config that excludes the file. THAT gets reported,
#          because a formatter which runs, fails and says nothing is the exact silent no-op this
#          hook was rewritten to eliminate. (Observed live: `biome format --write web/x.ts` exits 1
#          with "These paths were provided but ignored" when biome.json's files.includes omits the
#          directory — the file stays unformatted and the old hook reported success by saying
#          nothing at all.)
#   fix  — `ruff check --fix` / `biome check --write`. Non-zero here is ROUTINE: it means lint
#          diagnostics remain that no autofix can resolve. Reporting it would fire on ordinary code
#          every edit, so its status is dropped on purpose, not by oversight.
fmt() {
  fmt_out="$("$@" 2>&1)"
  fmt_rc=$?
}
fix() { "$@" >/dev/null 2>&1 || true; }

# Both runners are told where the project is by FLAG (`uv --project`, `pnpm --dir`) rather than by a
# surrounding `cd`: the file path handed to the formatter is absolute, and changing directory under
# it only creates ways for a relative path to be resolved against the wrong root.

case "$path" in
*.py)
  root="$(nearest_root "$filedir" pyproject.toml)" || root=""
  [ -n "$root" ] || root="$(nearest_root "$filedir" uv.lock)" || root=""
  if [ -n "$root" ] && [ -x "$root/.venv/bin/ruff" ]; then
    ran_with="$root/.venv/bin/ruff"
    fmt "$root/.venv/bin/ruff" format "$path"
    fix "$root/.venv/bin/ruff" check --fix "$path"
  elif [ -n "$root" ] && command -v uv >/dev/null 2>&1 &&
    uv run --quiet --project "$root" ruff --version >/dev/null 2>&1; then
    ran_with="uv run ruff"
    fmt uv run --quiet --project "$root" ruff format "$path"
    fix uv run --quiet --project "$root" ruff check --fix "$path"
  elif command -v ruff >/dev/null 2>&1; then
    ran_with="ruff (on PATH)"
    fmt ruff format "$path"
    fix ruff check --fix "$path"
  elif once py; then
    sys="touchstone: no ruff available, so $path was NOT formatted. Install it the standard way: uv add --dev ruff (hard rule 1 — ruff is the Python formatter/linter this repo's justfile and CI run)."
  fi
  ;;
*.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.json | *.jsonc)
  root="$(nearest_root "$filedir" package.json)" || root=""
  if [ -n "$root" ] && [ -x "$root/node_modules/.bin/biome" ]; then
    ran_with="$root/node_modules/.bin/biome"
    fmt "$root/node_modules/.bin/biome" format --write "$path"
    fix "$root/node_modules/.bin/biome" check --write "$path"
  elif [ -n "$root" ] && command -v pnpm >/dev/null 2>&1 &&
    pnpm --dir "$root" exec biome --version >/dev/null 2>&1; then
    ran_with="pnpm exec biome"
    fmt pnpm --dir "$root" exec biome format --write "$path"
    fix pnpm --dir "$root" exec biome check --write "$path"
  elif command -v biome >/dev/null 2>&1; then
    ran_with="biome (on PATH)"
    fmt biome format --write "$path"
    fix biome check --write "$path"
  elif [ -n "$root" ] && once node; then
    sys="touchstone: no Biome available, so $path was NOT formatted. Install it the standard way: pnpm add -D @biomejs/biome (hard rule 1 — Biome is the TS/JS formatter/linter this repo's justfile and CI run)."
  fi
  ;;
*.go)
  if command -v gofumpt >/dev/null 2>&1; then
    ran_with="gofumpt"
    fmt gofumpt -w "$path"
  elif once go; then
    sys="touchstone: gofumpt is not installed, so $path was NOT formatted. Install it with: go install mvdan.cc/gofumpt@latest (it is the Go formatter this repo's justfile and CI run)."
  fi
  ;;
*)
  exit 0
  ;;
esac

after="$(cksum <"$path" 2>/dev/null)" || after=""

if [ -n "$ran_with" ] && [ "$fmt_rc" -ne 0 ]; then
  # First 4 non-empty lines of the formatter's own diagnostics — enough to name the cause (a config
  # exclusion, a syntax error, a broken install) without pasting a full report into the transcript.
  detail="$(printf '%s\n' "$fmt_out" | LC_ALL=C awk 'NF { n++; if (n <= 4) print } n > 4 { exit }')"
  sys="touchstone: $ran_with FAILED on $path (exit $fmt_rc) — the file was NOT formatted. Run it yourself to see the full report.
$detail"
elif [ -n "$ran_with" ] && [ -n "$before" ] && [ "$before" != "$after" ]; then
  ctx="touchstone: $path was reformatted on disk by $ran_with after your edit. Re-read it before making further edits to it — your in-context copy is stale."
fi

emit
