#!/usr/bin/env bash
# Gate: no gate or formatter that scripts/init.sh installs into an adopting repo may walk into
# `.touchstone/`, the vendored kit.
#
# WHY. templates/justfile ran `uv run ruff check .`, `ruff format .`, `pnpm biome ci .` and
# `gofumpt -w .` from the repo root with no scoping. Three consequences, all found only from an
# adopter:
#   * ruff formats Python inside Markdown fences, and 9 of the kit's own standards docs are not
#     ruff-format-clean, so a PRISTINE adopter was red on its first `just lint` — gated on code it
#     does not own and cannot fix.
#   * the obvious remedy, `just fmt`, then REWROTE those 9 tracked files inside the pinned
#     submodule, dirtying the pin the whole adoption model rests on.
#   * Biome refused to start at all ("Found a nested root configuration") on the kit's own
#     templates/biome.json.
# The same file's `lint-shell` and `hooks-check` already carried `-not -path './.touchstone/*'`:
# the failure mode was understood and simply not applied to the other stacks.
#
# Biome is asserted against templates/biome.json rather than the justfile because Biome has no CLI
# exclude flag — the exclusion has to live in `files.includes`, and it is also what stops Biome
# discovering the kit's nested config.
#
# Structure follows tests/gates/justfile-ignore-prefix.test.sh: the scanner is proved against a
# fixture that IS the defect and a fixture that is the fix, it has a distinct "vacuous" verdict so
# a scan that examined nothing cannot read as a pass, the real-file rows assert a floor on lines
# examined, and the last block proves the flag actually excludes by running the real tool.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
FIXTURES="$KIT/tests/fixtures"

# --- the scanner -------------------------------------------------------------------------------
# A "walker" is an invocation of a tool that traverses the working tree: ruff check / ruff format /
# gofumpt / pytest. Recipe body lines are split into shell segments on `;`, `&&` and `||` first, so
# a line running two tools is two assertions rather than one — the pre-fix `ruff check . && ruff
# format --check .` would otherwise pass on the strength of whichever half was scoped. Each walker
# segment must name `.touchstone`, via --extend-exclude, --ignore, or a find -not -path list.
# Segments that merely `echo` a tool's name, or probe for it with `command -v`, are not invocations
# and are not counted.
# Emits `UNSCOPED <lineno>: <text>` per offender, then `EXAMINED <n>` and `HITS <n>`.
# shellcheck disable=SC2016 # awk program text: $0/NR are awk's and must not expand in bash
SCANNER='
BEGIN { inrecipe = 0; examined = 0; hits = 0 }
/^[ \t]*$/ { next }
/^[ \t]/ {
  if (!inrecipe) next
  body = $0
  sub(/^[ \t]+/, "", body)
  if (body ~ /^#/) next
  work = body
  gsub(/&&|\|\||;/, "\001", work)
  n = split(work, seg, "\001")
  for (i = 1; i <= n; i++) {
    s = seg[i]
    if (s ~ /echo/) continue
    if (s ~ /command -v/) continue
    walker = 0
    if (s ~ /ruff[ \t]+(check|format)/) walker = 1
    if (s ~ /gofumpt/) walker = 1
    if (s ~ /pytest/) walker = 1
    if (!walker) continue
    examined++
    if (index(s, ".touchstone") == 0) { hits++; printf "UNSCOPED %d: %s\n", NR, s }
  }
  next
}
{
  inrecipe = 0
  if ($0 ~ /^#/) next
  if ($0 ~ /:=/) next
  if ($0 ~ /^[A-Za-z_][A-Za-z0-9_-]*([ \t]+[^:]*)?:/) inrecipe = 1
}
END { printf "EXAMINED %d\nHITS %d\n", examined, hits }
'

SCAN_RC=0
SCAN_OUT=""
SCAN_EXAMINED=0
SCAN_HITS=0

scan() {
  local f="$1" out=""
  SCAN_RC=0
  SCAN_OUT=""
  SCAN_EXAMINED=0
  SCAN_HITS=0
  if [ ! -f "$f" ]; then
    # Refuse rather than scan nothing: an absent file yields zero unscoped lines, which is
    # indistinguishable from a correctly scoped one on the offender list alone.
    SCAN_RC=126
    SCAN_OUT="JUSTFILE MISSING: $f"
    return 0
  fi
  out="$(awk "$SCANNER" "$f")" || {
    SCAN_RC=125
    SCAN_OUT="SCANNER FAILED: $f"
    return 0
  }
  SCAN_OUT="$out"
  SCAN_EXAMINED="$(printf '%s\n' "$out" | awk '$1 == "EXAMINED" { print $2 }')"
  SCAN_HITS="$(printf '%s\n' "$out" | awk '$1 == "HITS" { print $2 }')"
}

offenders() { printf '%s\n' "$SCAN_OUT" | awk '$1 == "UNSCOPED"'; }

verdict() {
  if [ "$SCAN_RC" -ne 0 ]; then
    echo error
  elif [ "$SCAN_EXAMINED" -eq 0 ]; then
    echo vacuous
  elif [ "$SCAN_HITS" -ne 0 ]; then
    echo unscoped
  else
    echo scoped
  fi
}

at_least() { if [ "$SCAN_EXAMINED" -ge "$1" ]; then echo "at least $1"; else echo "only $SCAN_EXAMINED"; fi; }
exists() { if [ -f "$1" ]; then echo present; else echo absent; fi; }

# --- the scanner can tell good from bad ---------------------------------------------------------

assert_eq "fixture justfile-scope-unscoped is on disk" "present" "$(exists "$FIXTURES/justfile-scope-unscoped/justfile")"
scan "$FIXTURES/justfile-scope-unscoped/justfile"
assert_eq "unscoped fixture: verdict is unscoped" "unscoped" "$(verdict)"
assert_eq "unscoped fixture: every walker line is flagged" "5" "$SCAN_HITS"
assert_contains "unscoped fixture: names the offending text" "uv run ruff format ." "$SCAN_OUT"

assert_eq "fixture justfile-scope-scoped is on disk" "present" "$(exists "$FIXTURES/justfile-scope-scoped/justfile")"
scan "$FIXTURES/justfile-scope-scoped/justfile"
assert_eq "scoped fixture: verdict is scoped" "scoped" "$(verdict)"
assert_eq "scoped fixture: no false positive" "" "$(offenders)"
# Exact on purpose: a scanner that went clean by matching nothing fails this row.
assert_eq "scoped fixture: the five walker lines were examined" "5" "$SCAN_EXAMINED"

# A justfile with no walker lines at all is vacuous, not scoped.
scan "$FIXTURES/justfile-no-recipes/justfile"
assert_eq "justfile with no tree-walking tool: vacuous, not scoped" "vacuous" "$(verdict)"

scan "$FIXTURES/justfile-does-not-exist/justfile"
assert_eq "absent justfile: refuses to scan rather than report it scoped" "error" "$(verdict)"
assert_contains "absent justfile: says which path was missing" "JUSTFILE MISSING" "$SCAN_OUT"

# --- the real file ------------------------------------------------------------------------------

assert_eq "templates/justfile is on disk" "present" "$(exists "$KIT/templates/justfile")"
scan "$KIT/templates/justfile"
assert_eq "templates/justfile: every tree-walking gate excludes .touchstone" "" "$(offenders)"
assert_eq "templates/justfile: verdict is scoped" "scoped" "$(verdict)"
assert_eq "templates/justfile: the scan really examined its walker lines" "at least 5" "$(at_least 5)"

# The shell recipes carried this exclusion before the other stacks did; keep it that way.
tsdash="$(awk '/-not -path/ && /\.touchstone/ { n++ } END { print n + 0 }' "$KIT/templates/justfile")"
assert_eq "templates/justfile: the shell recipes still exclude .touchstone" "at least 2" \
  "$(if [ "$tsdash" -ge 2 ]; then echo "at least 2"; else echo "only $tsdash"; fi)"

# --- Biome: the Node stack's exclusion lives in the config ----------------------------------------

BIOME="$KIT/templates/biome.json"
assert_eq "templates/biome.json is on disk" "present" "$(exists "$BIOME")"

biome_includes() {
  python3 - "$BIOME" <<'PY' 2>/dev/null
import json, sys
print(" ".join(json.load(open(sys.argv[1]))["files"]["includes"]))
PY
}

if command -v python3 >/dev/null 2>&1; then
  inc="$(biome_includes)"
  assert_contains "templates/biome.json: the vendored kit is excluded" "!**/.touchstone" "$inc"
  # P2-9: `src/**` alone let a repo whose TypeScript lives elsewhere pass a gate that checked
  # nothing. `**` minus the vendored and build directories is the floor.
  assert_contains "templates/biome.json: the include set is the whole tree, not just src/" "**" "$inc"
  assert_eq "templates/biome.json: src/** is no longer the only source of truth" "" \
    "$(printf '%s' "$inc" | awk '{ if ($1 == "src/**" && NF <= 4) print "still-src-only" }')"
else
  ts_skip "templates/biome.json includes" "python3 not available"
fi

# Biome exits 1 when it matched no files UNLESS this flag is passed — the one zero-files-checked
# floor any of these tools offers. It must appear nowhere in what an adopter is handed.
noerr="$(find "$KIT/templates" -type f -exec awk '
  { l = $0; sub(/^[ \t]+/, "", l) }
  l ~ /^#/ { next }
  index($0, "--no-errors-on-unmatched") { print FILENAME }
' {} + | LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "templates/: no command silences Biome's zero-files-matched failure" "" "$noerr"
# The scan is only meaningful if it read the template tree at all.
scanned="$(find "$KIT/templates" -type f | awk 'END { print NR + 0 }')"
assert_eq "templates/: the flag scan really read the template tree" "at least 15" \
  "$(if [ "$scanned" -ge 15 ]; then echo "at least 15"; else echo "only $scanned"; fi)"

# --- golangci-lint ---------------------------------------------------------------------------------

GOLANGCI="$KIT/templates/golangci.yml"
assert_eq "templates/golangci.yml is on disk" "present" "$(exists "$GOLANGCI")"
golangci_ts="$(awk '/touchstone/ { n++ } END { print n + 0 }' "$GOLANGCI")"
assert_eq "templates/golangci.yml: linters AND formatters exclude the vendored kit" "at least 2" \
  "$(if [ "$golangci_ts" -ge 2 ]; then echo "at least 2"; else echo "only $golangci_ts"; fi)"

# --- the flag actually excludes -------------------------------------------------------------------
# Textual presence is not the claim; "ruff really leaves .touchstone alone" is. Run the real tool
# against a tree that mimics the adopter: one clean file the adopter owns, one deliberately
# unformatted file inside the vendored kit, including the Markdown case that caused the defect.

RUFF=""
if command -v ruff >/dev/null 2>&1; then
  RUFF="ruff"
elif command -v uvx >/dev/null 2>&1; then
  RUFF="uvx ruff"
fi

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

if [ -z "$RUFF" ]; then
  ts_skip "ruff --extend-exclude behaviour" "neither ruff nor uvx available"
  ts_report
  exit 0
fi

WORK="$(mktemp -d 2>/dev/null || true)"
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  ts_skip "ruff --extend-exclude behaviour" "mktemp -d failed"
  ts_report
  exit 0
fi

mkdir -p "$WORK/repo/.touchstone/standards"
printf 'x = {"a": 1}\n' >"$WORK/repo/ok.py"
printf 'x   =   {   1:2 }\ndef  f( ):  pass\n' >"$WORK/repo/.touchstone/messy.py"
# shellcheck disable=SC2016 # literal Markdown + Python fixture text; nothing here may expand
printf '# Doc\n\n```python\n@pytest.mark.skipif(not Path("fixtures/load-data.csv").exists(), reason="load fixtures absent")\ndef test_bulk_import(): ...\n```\n' \
  >"$WORK/repo/.touchstone/standards/doc.md"

# Control: unscoped, ruff sees the vendored kit and fails. If this row ever goes green the row
# below proves nothing, because there would be nothing to exclude.
ctrl_rc=0
(cd "$WORK/repo" && $RUFF format --check --isolated . >/dev/null 2>&1) || ctrl_rc=$?
assert_eq "control: an unscoped ruff format --check fails on the vendored kit" "nonzero" \
  "$(if [ "$ctrl_rc" -ne 0 ]; then echo nonzero; else echo zero; fi)"

scoped_rc=0
(cd "$WORK/repo" && $RUFF format --check --isolated . --extend-exclude .touchstone >/dev/null 2>&1) || scoped_rc=$?
assert_eq "--extend-exclude .touchstone: the same tree passes" "0" "$scoped_rc"

# And `fmt` must leave the pin byte-identical.
before="$(cksum <"$WORK/repo/.touchstone/messy.py") $(cksum <"$WORK/repo/.touchstone/standards/doc.md")"
(cd "$WORK/repo" && $RUFF format --isolated . --extend-exclude .touchstone >/dev/null 2>&1) || true
after="$(cksum <"$WORK/repo/.touchstone/messy.py") $(cksum <"$WORK/repo/.touchstone/standards/doc.md")"
assert_eq "a scoped ruff format leaves every file in the vendored kit byte-identical" "$before" "$after"

# The adopter's own file was still formatted — the exclusion did not switch the formatter off.
assert_eq "the adopter's own files are still formatted" "0" \
  "$(
    cd "$WORK/repo" && $RUFF format --check --isolated ok.py >/dev/null 2>&1
    echo $?
  )"

ts_report
