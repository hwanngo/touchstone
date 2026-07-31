#!/usr/bin/env bash
# Gate: hooks/format-touched.sh must never be a silent no-op.
#
# The defect, invisible from inside the kit: the hook resolved formatters with `command -v ruff` /
# `command -v biome`. Hard rule 1 mandates uv and pnpm, which install those tools INTO THE PROJECT —
# after `uv add --dev ruff` neither binary is on PATH. So in a standards-compliant repo (the only
# kind touchstone produces) the hook found nothing, formatted nothing, and printed nothing, while
# hooks/README.md claimed it "runs the same formatters as the justfile". A hook that silently does
# nothing is the same defect class as a gate that silently passes.
#
# The four outcomes below are the contract: reformatted, formatter-failed, no-formatter-installed,
# inside-the-pinned-submodule. NONE of them may be silence, and the row asserting the hook produced
# non-empty output is therefore as load-bearing as the row asserting the file changed.
#
# Formatters are STUBBED, not installed. A row that depended on a real ruff being present would skip
# on a bare CI box and take the defect with it — and a stub is also the only way to test the
# formatter-failed branch deterministically. The stubs are placed at the exact project-local paths
# the hook is specified to look at, so a change to that resolution order fails here.
# shellcheck disable=SC2016 # file-wide: the single-quoted strings below are SOURCE for stub
# formatters written to disk, so `$1`/`$2` in them are the stub's own arguments at run time and
# must not expand while this file is being read.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
HOOK="$KIT/hooks/format-touched.sh"

if ! command -v jq >/dev/null 2>&1; then
  ts_skip "format-touched" "jq not available"
  ts_report
  exit 0
fi
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "format-touched" "mktemp not available"
  ts_report
  exit 0
fi

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "format-touched" "mktemp -d failed"
  ts_report
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

# A deliberately minimal PATH: jq (the hook's one hard dependency) plus the system utilities, and
# NOTHING ELSE. This is what makes the "no formatter installed" rows real — on a developer machine a
# global ruff or biome would otherwise satisfy tier 3 and those rows would assert the wrong branch.
STUBPATH="$TMP/bin"
mkdir -p "$STUBPATH"
JQ_BIN="$(command -v jq)"
ln -s "$JQ_BIN" "$STUBPATH/jq" 2>/dev/null || cp "$JQ_BIN" "$STUBPATH/jq"
if command -v git >/dev/null 2>&1; then
  ln -s "$(command -v git)" "$STUBPATH/git" 2>/dev/null || true
fi
CLEAN_PATH="$STUBPATH:/usr/bin:/bin:/usr/sbin:/sbin"

leaked=""
for t in ruff biome gofumpt uv pnpm; do
  if PATH="$CLEAN_PATH" command -v "$t" >/dev/null 2>&1; then leaked="$leaked $t"; fi
done
assert_eq "control: no real formatter or runner leaks into the scrubbed PATH" "" "$leaked"

# Flag files for the once-per-session notice live in TMPDIR; point it somewhere disposable so runs
# are deterministic and never collide with a previous one.
FLAGDIR="$TMP/flags"
mkdir -p "$FLAGDIR"

# run_hook <session> <file> — feed the hook a PostToolUse payload, capture stdout.
HOOK_OUT=""
run_hook() {
  HOOK_OUT="$(printf '%s' "{\"session_id\":\"$1\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$2\"}}" |
    PATH="$CLEAN_PATH" TMPDIR="$FLAGDIR" bash "$HOOK" 2>&1)"
}

# mkstub <path> <exit-code> <body-line...> — an executable stand-in for a formatter. The body
# lines are written verbatim into the stub, so `$1`/`$2` in them are the STUB's arguments at
# run time and must not expand here.
mkstub() {
  local dest="$1" rc="$2"
  shift 2
  mkdir -p "$(dirname "$dest")"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$@"
    printf 'exit %s\n' "$rc"
  } >"$dest"
  chmod +x "$dest"
}

# --- outcome 1: NO formatter installed — must say so, with the standards-compliant install command
PROJ="$TMP/proj"
mkdir -p "$PROJ"
printf '[project]\nname = "x"\n' >"$PROJ/pyproject.toml"
printf '{"name":"x"}\n' >"$PROJ/package.json"
printf 'x   =   1\n' >"$PROJ/a.py"
printf 'let   a=1\n' >"$PROJ/a.ts"

run_hook "s-none" "$PROJ/a.py"
assert_contains "no ruff: says the file was NOT formatted" "was NOT formatted" "$HOOK_OUT"
assert_contains "no ruff: names the uv install command, not a global one" "uv add --dev ruff" "$HOOK_OUT"
unchanged="$(cat "$PROJ/a.py")"
assert_eq "no ruff: the file is genuinely untouched" "x   =   1" "$unchanged"

run_hook "s-none" "$PROJ/a.ts"
assert_contains "no biome: says the file was NOT formatted" "was NOT formatted" "$HOOK_OUT"
assert_contains "no biome: names the pnpm install command" "pnpm add -D @biomejs/biome" "$HOOK_OUT"

# The notice is a setup problem, not a per-edit event: once per session per language.
run_hook "s-none" "$PROJ/a.py"
assert_eq "the no-formatter notice does not repeat within a session" "" "$HOOK_OUT"
run_hook "s-other" "$PROJ/a.py"
assert_contains "but a new session hears it again" "uv add --dev ruff" "$HOOK_OUT"

# --- outcome 2: project-local formatter FOUND and it changes the file ----------------------------
# The stub is placed at .venv/bin/ruff — tier 1 of the documented resolution order, and the exact
# path `uv add --dev ruff` produces. If the hook regressed to a bare `command -v ruff`, the scrubbed
# PATH has no ruff at all and this row fails rather than passing by luck.
mkstub "$PROJ/.venv/bin/ruff" 0 'if [ "$1" = "format" ]; then printf "y = 1\n" > "$2"; fi'
printf 'x   =   1\n' >"$PROJ/a.py"
run_hook "s-fmt" "$PROJ/a.py"
assert_eq "project-local ruff (.venv/bin) is used and rewrites the file" "y = 1" "$(cat "$PROJ/a.py")"
assert_contains "and the hook says the file changed under the agent" "was reformatted on disk" "$HOOK_OUT"
assert_contains "naming the binary that did it" ".venv/bin/ruff" "$HOOK_OUT"

# The Node half, same shape, at the path `pnpm add -D @biomejs/biome` produces.
mkstub "$PROJ/node_modules/.bin/biome" 0 'if [ "$1" = "format" ]; then printf "let a = 1;\n" > "$3"; fi'
printf 'let   a=1\n' >"$PROJ/a.ts"
run_hook "s-fmt" "$PROJ/a.ts"
assert_eq "project-local biome (node_modules/.bin) is used and rewrites the file" "let a = 1;" "$(cat "$PROJ/a.ts")"
assert_contains "and the hook says the TS file changed too" "was reformatted on disk" "$HOOK_OUT"

# A formatter that runs and finds nothing to change must stay quiet — the hook reports events, and
# "already formatted" is not one. Control for the two rows above: it proves the message is driven by
# an actual content change and is not printed unconditionally whenever a formatter exists.
run_hook "s-fmt" "$PROJ/a.py"
assert_eq "an already-formatted file produces no output" "" "$HOOK_OUT"

# --- outcome 3: the formatter RAN and FAILED — the case the old hook hid entirely -----------------
# Observed live in the dogfood adopter: `biome format --write web/x.ts` exits 1 with "These paths
# were provided but ignored" when biome.json's files.includes omits the directory. The file is left
# unformatted and the pre-fix hook reported that by saying nothing whatsoever.
mkstub "$PROJ/node_modules/.bin/biome" 1 'echo "x No files were processed in the specified paths." >&2'
printf 'let   b=2\n' >"$PROJ/b.ts"
run_hook "s-fail" "$PROJ/b.ts"
assert_contains "a failing formatter is reported, not swallowed" "FAILED on" "$HOOK_OUT"
assert_contains "with its exit code" "(exit 1)" "$HOOK_OUT"
assert_contains "and its own diagnostics, so the cause is actionable" "No files were processed" "$HOOK_OUT"
assert_eq "and the file is correctly left alone" "let   b=2" "$(cat "$PROJ/b.ts")"

# The autofix step's status is deliberately NOT reported: `ruff check --fix` exits non-zero whenever
# un-autofixable lint findings remain, which is ordinary code. Only the FORMAT step is a defect
# signal. Format stub succeeds, check stub fails — the hook must stay quiet about the latter.
mkstub "$PROJ/.venv/bin/ruff" 0 'if [ "$1" = "check" ]; then exit 1; fi' 'if [ "$1" = "format" ]; then exit 0; fi'
printf 'z = 1\n' >"$PROJ/c.py"
run_hook "s-lint" "$PROJ/c.py"
assert_eq "remaining lint findings (non-zero autofix) are not reported as a failure" "" "$HOOK_OUT"

# --- outcome 4: a file inside the pinned submodule is refused, and says so ------------------------
# Formatting the vendored kit is how an adopter's first green build silently dirties the pin the
# whole adoption model rests on. Skipping it is right; skipping it in silence is not.
mkdir -p "$PROJ/.touchstone/standards"
printf 'q   =   1\n' >"$PROJ/.touchstone/standards/x.py"
mkstub "$PROJ/.venv/bin/ruff" 0 'if [ "$1" = "format" ]; then printf "q = 1\n" > "$2"; fi'
run_hook "s-sub" "$PROJ/.touchstone/standards/x.py"
assert_contains "a file inside .touchstone/ is refused" "NOT formatted" "$HOOK_OUT"
assert_contains "and the reason names the pin" "dirty the pin" "$HOOK_OUT"
assert_eq "the vendored file is genuinely untouched" "q   =   1" "$(cat "$PROJ/.touchstone/standards/x.py")"

# --- outcome 5: jq missing — announced, like every other hook's degraded mode ---------------------
# An EMPTY PATH directory, not a trimmed system one: this host has jq in /usr/bin, so "PATH without
# the package manager's bin" is not the same as "PATH without jq". The hook reaches its jq check
# before it needs any external command, and printf is a builtin, so an empty PATH is survivable.
NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
assert_eq "control: jq really is absent from the empty PATH" "" "$(PATH="$NOJQ" command -v jq || true)"
BASH_BIN="$(command -v bash)"
nojq_out="$(printf '%s' '{"tool_input":{"file_path":"/tmp/x.py"}}' | PATH="$NOJQ" "$BASH_BIN" "$HOOK" 2>&1)"
assert_contains "without jq the hook announces it is OFF rather than exiting quietly" "format-touched is OFF" "$nojq_out"

# --- documentation: hooks/README.md must describe the behaviour that exists -----------------------
# The prose was false for as long as the hook was broken, and nothing checked it. These rows are
# deliberately about the two claims that were wrong.
HREADME="$KIT/hooks/README.md"
readme_txt=""
[ -f "$HREADME" ] && readme_txt="$(cat "$HREADME")"
assert_contains "hooks/README.md documents the uv resolution path" "uv run" "$readme_txt"
assert_contains "hooks/README.md documents the pnpm resolution path" "pnpm" "$readme_txt"
assert_contains "hooks/README.md documents the project-local venv path" ".venv/bin/ruff" "$readme_txt"
assert_contains "hooks/README.md documents the project-local node path" "node_modules/.bin/biome" "$readme_txt"

ts_report
