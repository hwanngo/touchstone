#!/usr/bin/env bash
# Gate: every recipe's `just --list` doc string must be a doc string, not the tail of a paragraph.
#
# WHY. `default: @just --list` is the first command an adopter runs, and just takes the LAST comment
# line before a recipe as that recipe's doc string. templates/justfile's multi-line explanatory
# comments sat directly above their recipes, so the adopter's first contact with the runner read:
#
#     fmt           # fails `fmt`. The skip is per-tool and conditional, never a blanket `-`.
#     lint          # purpose: a gate that could not run has not passed.
#     setup         # unresolvable constraint) fails `setup`.
#     lint-shell    # it here would fail this repo's gate on somebody else's code.
#
# Adopter-only, and so invisible from inside the kit: the kit's own justfile is clean.
#
# Two rules, both mechanical:
#   R1 CONTINUATION — the comment line above the doc line, if there is one, must end in sentence-
#      final punctuation (`.` `:` `!` `?`). A paragraph that runs on into the doc line means the doc
#      line is a fragment. This is what caught all four cases above.
#   R2 WIDTH — a doc line must be at most 78 characters. `--list` renders them in an aligned second
#      column; prose does not fit there and is prose, not documentation.
# The fix for either is the same: put the prose in a block above, separated by a BLANK line, and one
# short line directly above the recipe.
#
# Structure follows tests/gates/justfile-ignore-prefix.test.sh: fixtures that are the defect and the
# fix, a distinct "vacuous" verdict so scanning nothing cannot pass, a floor on recipes examined for
# the real files, and a behavioural block that runs `just --list` on the INSTALLED justfile.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
FIXTURES="$KIT/tests/fixtures"

# --- the scanner -------------------------------------------------------------------------------
# Emits `FRAGMENT <lineno>: <recipe> <- <doc>` / `WIDE <lineno>: <recipe> <- <doc>` per offender,
# then `EXAMINED <n>` (recipes seen) and `HITS <n>`.
# shellcheck disable=SC2016 # awk program text: $0/NR are awk's and must not expand in bash
SCANNER='
BEGIN { prev = ""; prev2 = ""; examined = 0; hits = 0 }
{
  line = $0
  if (line ~ /^[ \t]*$/) { prev2 = ""; prev = ""; next }
  if (line ~ /^[ \t]/) { next }                 # recipe body — never a doc position
  if (line ~ /^#/) { prev2 = prev; prev = line; next }
  if (line ~ /:=/) { prev2 = ""; prev = ""; next }
  if (line !~ /^[A-Za-z_][A-Za-z0-9_-]*([ \t]+[^:]*)?:/) { prev2 = ""; prev = ""; next }

  name = line; sub(/[ \t:].*$/, "", name)
  examined++
  if (prev != "") {
    doc = prev
    sub(/^#[ \t]*/, "", doc)
    gsub(/[ \t]+$/, "", doc)
    if (prev2 != "") {
      above = prev2
      gsub(/[ \t]+$/, "", above)
      if (above !~ /[.:!?]$/ && above != "#") {
        hits++; printf "FRAGMENT %d: %s <- %s\n", NR, name, doc
      }
    }
    if (length(doc) > 78) { hits++; printf "WIDE %d: %s <- %s\n", NR, name, doc }
  }
  prev2 = ""; prev = ""
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
    # Refuse rather than scan nothing: an absent file yields zero fragments, which is
    # indistinguishable from a well-documented one on the offender list alone.
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

offenders() { printf '%s\n' "$SCAN_OUT" | awk '$1 == "FRAGMENT" || $1 == "WIDE"'; }

verdict() {
  if [ "$SCAN_RC" -ne 0 ]; then
    echo error
  elif [ "$SCAN_EXAMINED" -eq 0 ]; then
    echo vacuous
  elif [ "$SCAN_HITS" -ne 0 ]; then
    echo fragments
  else
    echo clean
  fi
}

at_least() { if [ "$SCAN_EXAMINED" -ge "$1" ]; then echo "at least $1"; else echo "only $SCAN_EXAMINED"; fi; }
exists() { if [ -f "$1" ]; then echo present; else echo absent; fi; }

# --- the scanner can tell good from bad ---------------------------------------------------------

assert_eq "fixture justfile-doc-fragment is on disk" "present" "$(exists "$FIXTURES/justfile-doc-fragment/justfile")"
scan "$FIXTURES/justfile-doc-fragment/justfile"
assert_eq "fragment fixture: verdict is fragments" "fragments" "$(verdict)"
assert_contains "fragment fixture: catches the run-on paragraph" "FRAGMENT" "$SCAN_OUT"
assert_contains "fragment fixture: names the mangled doc string" "a gate that could not run has not passed." "$SCAN_OUT"
assert_contains "fragment fixture: catches the over-wide doc string" "WIDE" "$SCAN_OUT"

assert_eq "fixture justfile-doc-clean is on disk" "present" "$(exists "$FIXTURES/justfile-doc-clean/justfile")"
scan "$FIXTURES/justfile-doc-clean/justfile"
assert_eq "clean fixture: verdict is clean" "clean" "$(verdict)"
assert_eq "clean fixture: no false positive" "" "$(offenders)"
# Exact on purpose: a scanner that went clean by finding no recipes fails this row.
assert_eq "clean fixture: all four recipes were examined" "4" "$SCAN_EXAMINED"

scan "$FIXTURES/justfile-no-recipes/justfile"
assert_eq "justfile with no recipes: vacuous, not clean" "vacuous" "$(verdict)"

scan "$FIXTURES/justfile-does-not-exist/justfile"
assert_eq "absent justfile: refuses to scan rather than report it clean" "error" "$(verdict)"
assert_contains "absent justfile: says which path was missing" "JUSTFILE MISSING" "$SCAN_OUT"

# --- the real files ------------------------------------------------------------------------------

assert_eq "templates/justfile is on disk" "present" "$(exists "$KIT/templates/justfile")"
scan "$KIT/templates/justfile"
assert_eq "templates/justfile: no recipe's --list doc string is a paragraph fragment" "" "$(offenders)"
assert_eq "templates/justfile: verdict is clean" "clean" "$(verdict)"
assert_eq "templates/justfile: the scan really examined its recipes" "at least 10" "$(at_least 10)"

assert_eq "the kit's own justfile is on disk" "present" "$(exists "$KIT/justfile")"
scan "$KIT/justfile"
assert_eq "justfile: no recipe's --list doc string is a paragraph fragment" "" "$(offenders)"
assert_eq "justfile: verdict is clean" "clean" "$(verdict)"
assert_eq "justfile: the scan really examined its recipes" "at least 5" "$(at_least 5)"

# --- what an adopter actually sees ----------------------------------------------------------------
# Static cleanliness is not the claim; "`just --list` renders coherently in the file an adopter
# gets" is. That needs just, and scripts/init.sh to have placed the template.

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

if ! command -v just >/dev/null 2>&1; then
  ts_skip "adopter just --list" "just not available"
  ts_report
  exit 0
fi

WORK="$(mktemp -d 2>/dev/null || true)"
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  ts_skip "adopter just --list" "mktemp -d failed"
  ts_report
  exit 0
fi

mkdir -p "$WORK/repo"
init_rc=0
bash "$KIT/scripts/init.sh" --target "$WORK/repo" >/dev/null 2>&1 || init_rc=$?
assert_eq "scripts/init.sh placed the adopter justfile" "0" "$init_rc"
assert_eq "the installed justfile is on disk" "present" "$(exists "$WORK/repo/justfile")"

LIST="$(cd "$WORK/repo" && just --list 2>&1)"
list_rc=0
(cd "$WORK/repo" && just --list >/dev/null 2>&1) || list_rc=$?
assert_eq "the installed justfile: just --list succeeds" "0" "$list_rc"

# Every rendered doc string must fit the aligned column and start like a description, not like the
# middle of a sentence. `--list` lines look like "    name        # doc".
bad_docs="$(printf '%s\n' "$LIST" | awk -F'#' '
  /^[ \t]+[A-Za-z_][A-Za-z0-9_-]*[ \t]+#/ {
    doc = $0
    sub(/^[^#]*#[ \t]*/, "", doc)
    gsub(/[ \t]+$/, "", doc)
    if (length(doc) > 78) { print "WIDE: " doc; next }
    if (doc ~ /^(fails|purpose|it |Each |unresolvable)/) { print "FRAGMENT: " doc }
  }')"
assert_eq "the installed justfile: every --list doc string reads as a description" "" "$bad_docs"

listed="$(printf '%s\n' "$LIST" | awk '/^[ \t]+[A-Za-z_][A-Za-z0-9_-]*/ { n++ } END { print n + 0 }')"
assert_eq "the installed justfile: --list really listed the recipes" "at least 10" \
  "$(if [ "$listed" -ge 10 ]; then echo "at least 10"; else echo "only $listed"; fi)"

ts_report
