#!/usr/bin/env bash
# Gate: every item of the self-audit checklist must carry a maturity level the model declares.
#
# standards/self-audit.md is the kit's flagship document: ~150 checklist items plus an L1–L4
# maturity model. The model told a reader to "adopt in order" and the prose claimed "Each item
# below is tagged with the level it first becomes required" — but no item carried a tag. The
# checklist was a flat wall, the maturity model was decorative, and the sentence asserting
# otherwise was false. That is this repo's recurring failure mode: a rule stated in prose that
# nothing checks. The tags are now on every item, and this gate keeps them there — a newly added
# item that ships untagged fails the build instead of silently joining an untagged tail.
#
# THE VALID LEVEL SET IS NOT WRITTEN DOWN HERE. It is READ, at run time, from the maturity-model
# table in standards/self-audit.md — the single declared place. Nothing here hardcodes `L1|L2|L3|L4`
# and nothing here assumes a level is even spelled "L<n>": declared_levels() takes the first cell of
# every DATA row of the table under '## Maturity levels' (data rows being the ones after the
# |---|---| delimiter), so renaming the levels renames what this gate demands. The pin runs in BOTH
# directions:
#   - an item tagged with a level the table does not declare fails (the checklist invented a level);
#   - a level the table declares that NO item carries also fails (the model grew a tier the
#     checklist never uses — the model and the list drifting apart, in the other direction).
# So the checklist and its model cannot separate without going red, either way.
#
# The legend is pinned too. A doc full of `**L2**` markers that no longer explains what they mean is
# a checklist a reader cannot use, so the sentence introducing the markers is itself a requirement.
#
# The checker is a pure function of the root it is handed and MUST NOT reference $KIT: a checker
# that self-located would scan the real repo while appearing to scan a fixture, and every row here
# would be measuring the wrong tree. The self-audit-levels-empty rows exist to prove that has not
# happened.
#
# EVERY row is guarded two ways, matching tests/gates/repo-meta.test.sh:
#   1. assert_fixture states, as its own assertion, which files the row depends on. run_check copies
#      the fixture into an empty temp tree, so a DELETED fixture leaves the checker with no doc to
#      read at all — which exits non-zero, satisfying every "exits non-zero" assertion for entirely
#      the wrong reason. run_check additionally refuses to run on a missing fixture dir.
#   2. Every exit-code assertion is paired with an assert_contains on the specific message that
#      verdict should carry, so "non-zero" is never accepted on its own.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
FIXTURES="$KIT/tests/fixtures"

# Hard rule 4: self-skip only for genuine tool absence, never for anything the checker itself does —
# tests/run.sh exits on failures only, so a skip on the behaviour under test would read as green
# while leaving it unverified.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "self-audit-levels" "mktemp not available"
  ts_report
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# The declared sources of truth.
# ---------------------------------------------------------------------------------------------

CHECKLIST_DOC="standards/self-audit.md"
MODEL_HEADING="Maturity levels"
LEGEND_PREFIX="Each item below is tagged"

# ---------------------------------------------------------------------------------------------
# Parsers. Both are pure functions of a file path.
# ---------------------------------------------------------------------------------------------

# declared_levels <doc> — print the level id of every data row of the maturity-model table, one per
# line, in table order. A "data row" is a table row after the |---|---| delimiter, so the header
# row is excluded without this gate knowing the word "Level", and a level id is whatever sits in
# the first cell — no naming scheme is assumed. Prints nothing when the section, the table, or the
# doc is absent, which the caller treats as a failure rather than as an empty requirement set.
declared_levels() {
  awk -v h="$MODEL_HEADING" '
    /^##[[:space:]]/ {
      head = $0
      sub(/^##[[:space:]]+/, "", head)
      sub(/[[:space:]]+$/, "", head)
      insec = (head == h)
      indata = 0
      next
    }
    !insec { next }
    /^\|[[:space:]]*:?-+/ { indata = 1; next }
    indata && /^\|/ {
      cell = $0
      sub(/^\|[[:space:]]*/, "", cell)
      sub(/[[:space:]]*\|.*$/, "", cell)
      gsub(/[`*]/, "", cell)
      sub(/[[:space:]]+$/, "", cell)
      if (cell != "") print cell
    }
  ' "$1" 2>/dev/null
}

# checklist_items <doc> — print "<line> <marker> <text>" for every checklist item, where <marker> is
# the bold token opening the item or "-" when there is none. Fenced code is stripped first (the two
# fence markers tracked INDEPENDENTLY, as scripts/check-standards.sh does, so a '~~~' line shown
# inside a backtick block cannot close it): a '- [ ] …' line inside a fence is sample text, not a
# checklist item, and counting it would make this gate demand a marker on documentation.
#
# The marker is extracted without any arithmetic on byte offsets — the separator that follows it is
# multi-byte, and RLENGTH counts bytes under LC_ALL=C but characters elsewhere, so an offset-based
# extraction would silently differ between the two locales this suite runs in.
#
# The candidate must be `**<word>**` with no spaces, so an untagged item whose text merely opens in
# bold ("**Load + stress** tests…", "**pnpm** (pinned…)") yields a single-token marker or none, and
# <marker> can never contain the space this record format uses as its separator.
checklist_items() {
  awk '
    BEGIN { fence = "" }
    /^[[:space:]]*```/ { if (fence == "") fence = "`"; else if (fence == "`") fence = ""; next }
    /^[[:space:]]*~~~/ { if (fence == "") fence = "~"; else if (fence == "~") fence = ""; next }
    fence != "" { next }
    /^- \[[ xX]\] / {
      rest = $0
      sub(/^- \[[ xX]\][[:space:]]+/, "", rest)
      marker = "-"
      if (rest ~ /^\*\*[A-Za-z0-9]+\*\*[[:space:]]/) {
        id = rest
        sub(/^\*\*/, "", id)
        sub(/\*\*.*$/, "", id)
        marker = id
      }
      print NR " " marker " " rest
    }
  ' "$1" 2>/dev/null
}

# in_set <needle> <newline-separated-haystack> — "yes"/"no", so membership reads as an assertion
# rather than as a bare exit status.
in_set() {
  if printf '%s\n' "$2" | grep -qxF -e "$1"; then echo yes; else echo no; fi
}

# looks_like_level <token> — "yes"/"no". This chooses the WORDING of a failure, never the verdict:
# validity is decided solely by membership in the levels the table declares. Its only job is to tell
# "this item is tagged L9, which is not a level" apart from "this item is not tagged at all", two
# defects with two different fixes.
looks_like_level() {
  case "$1" in
  L[0-9] | L[0-9][0-9]) echo yes ;;
  *) echo no ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The checker. A pure function of <root>.
# ---------------------------------------------------------------------------------------------

check_self_audit_levels() {
  # Two statements, not one: `local a="$1" b="$a/x"` expands $a in the CALLER's scope (the words are
  # expanded before the `local` builtin runs), which under `set -u` is an unbound-variable abort.
  local root="$1"
  local doc="$root/$CHECKLIST_DOC"
  local levels="" levels_line="" items="" used="" lvl lineno marker text
  local rc=0 examined=0 nlevels=0

  if [ ! -f "$doc" ]; then
    echo "FAIL: no $CHECKLIST_DOC under $root — the checklist could not be read; nothing was verified."
    return 1
  fi

  levels="$(declared_levels "$doc")"
  if [ -z "$levels" ]; then
    echo "FAIL: $CHECKLIST_DOC declares no maturity levels in a table under '## $MODEL_HEADING' — the model this gate reads its valid set from is gone; nothing was verified."
    return 1
  fi
  levels_line="$(printf '%s\n' "$levels" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  nlevels="$(printf '%s\n' "$levels" | grep -c .)"

  # The legend: markers nobody explains are noise. Read with -F -e because the prefix is plain text
  # and must not be taken for a pattern.
  if ! grep -qF -e "$LEGEND_PREFIX" "$doc"; then
    echo "FAIL: $CHECKLIST_DOC has no '$LEGEND_PREFIX' line — the markers on every item are no longer explained to a reader."
    rc=1
  fi

  # --- forward pin: every item carries a marker, and the model declares it ----------------------
  items="$(checklist_items "$doc")"
  while read -r lineno marker text; do
    [ -n "$lineno" ] || continue
    examined=$((examined + 1))
    if [ "$(in_set "$marker" "$levels")" = "yes" ]; then
      used="$used
$marker"
      continue
    fi
    if [ "$marker" != "-" ] && [ "$(looks_like_level "$marker")" = "yes" ]; then
      echo "UNDECLARED: line $lineno is tagged '$marker', which the maturity model does not declare (declared: $levels_line): $text"
    else
      echo "UNTAGGED: line $lineno carries no level marker: $text"
    fi
    rc=1
  done <<EOF
$items
EOF

  # --- reverse pin: a level the model declares that no item carries -----------------------------
  while IFS= read -r lvl; do
    [ -n "$lvl" ] || continue
    if [ "$(in_set "$lvl" "$used")" = "no" ]; then
      echo "UNUSED: the maturity model declares '$lvl' but no checklist item carries it — the model and the checklist have drifted apart."
      rc=1
    fi
  done <<EOF
$levels
EOF

  # Never pass on nothing. A run that examined zero items verified zero things.
  echo "Examined $examined checklist item(s) against $nlevels declared level(s) ($levels_line) in $CHECKLIST_DOC."
  if [ "$examined" -eq 0 ]; then
    echo "FAIL: no checklist items were examined — this gate verified nothing."
    rc=1
  fi

  [ "$rc" -eq 0 ] && echo "All $examined checklist item(s) carry a level the maturity model declares."
  return "$rc"
}

# ---------------------------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------------------------

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# assert_fixture <fixture> <file>... — precondition row: every listed file must be on disk before
# the row that follows means anything. With the fixture's self-audit.md deleted the checker reports
# "no standards/self-audit.md" and every "exits non-zero" assertion below would still pass.
assert_fixture() {
  local fixture="$1" state="complete" missing="" f
  shift
  for f in "$@"; do
    if [ ! -f "$FIXTURES/$fixture/$f" ]; then missing="$missing $f"; fi
  done
  if [ -n "$missing" ]; then state="missing:$missing"; fi
  assert_eq "fixture $fixture is complete on disk" "complete" "$state"
}

# run_check <fixture-name> — copies tests/fixtures/<fixture-name> into a fresh tmp tree and runs
# check_self_audit_levels against that tree, leaving CHK_RC / CHK_OUT set.
CHK_RC=0
CHK_OUT=""
run_check() {
  local fixture="$1"
  if [ ! -d "$FIXTURES/$fixture" ]; then
    # Refuse to run rather than silently check an empty tree.
    CHK_RC=126
    CHK_OUT="FIXTURE MISSING: $FIXTURES/$fixture"
    return 0
  fi
  WORK="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    CHK_RC=127
    CHK_OUT="mktemp -d failed"
    return 0
  fi
  mkdir -p "$WORK/repo"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  CHK_RC=0
  CHK_OUT="$(check_self_audit_levels "$WORK/repo" 2>&1)" || CHK_RC=$?
  rm -rf "$WORK"
  WORK=""
}

# out_has <needle> — "present"/"absent", so a row can assert something is NOT in the output using
# the same assert_eq every other row uses.
out_has() {
  case "$CHK_OUT" in
  *"$1"*) echo present ;;
  *) echo absent ;;
  esac
}

nonzero() { if [ "$CHK_RC" -ne 0 ]; then echo nonzero; else echo zero; fi; }

FIX_DOC="standards/self-audit.md"

# ---------------------------------------------------------------------------------------------
# Rows: the control. The harness must be able to tell a fully tagged checklist from a broken one.
# ---------------------------------------------------------------------------------------------

assert_fixture "self-audit-levels-good" "$FIX_DOC"
run_check "self-audit-levels-good"
assert_eq "every item tagged with a declared level: exits 0" "0" "$CHK_RC"
assert_contains "good tree: the level set was read out of the table, not hardcoded" \
  "against 4 declared level(s) (L1 L2 L3 L4)" "$CHK_OUT"
# 4, not 5: the fixture carries a '- [ ] …' line inside a fenced block. If fence stripping broke,
# that line would be counted AND reported untagged, so this number pins the fence handling.
assert_contains "good tree: counted the four real items and ignored the one inside a fence" \
  "Examined 4 checklist item(s)" "$CHK_OUT"
assert_contains "good tree: says so" "All 4 checklist item(s) carry a level" "$CHK_OUT"
assert_eq "good tree: the fenced sample line was not reported as an item" "absent" "$(out_has "inside a fence")"

# ---------------------------------------------------------------------------------------------
# Rows: an item with no marker — the defect this gate exists to prevent recurring.
# ---------------------------------------------------------------------------------------------

assert_fixture "self-audit-levels-untagged" "$FIX_DOC"
run_check "self-audit-levels-untagged"
assert_eq "an item carries no level marker: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "untagged item: names the line and the defect" "UNTAGGED: line" "$CHK_OUT"
assert_contains "untagged item: quotes the item so it can be found" "carries no level marker: Lockfile committed" "$CHK_OUT"
assert_eq "untagged item: makes no success claim" "absent" "$(out_has "carry a level the maturity model declares")"
# The other items are still checked — one untagged item must not short-circuit the rest, or a doc
# with two defects would report one and look half-fixed after the first is repaired.
assert_contains "untagged item: the run still reached every item" "Examined 4 checklist item(s)" "$CHK_OUT"

# ---------------------------------------------------------------------------------------------
# Rows: an item tagged with a level the model never declared.
# ---------------------------------------------------------------------------------------------

assert_fixture "self-audit-levels-undeclared" "$FIX_DOC"
run_check "self-audit-levels-undeclared"
assert_eq "an item invents a level: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "undeclared level: names the level and lists the declared set" \
  "is tagged 'L9', which the maturity model does not declare (declared: L1 L2 L3 L4)" "$CHK_OUT"
# Without this row the assertion above also passes on an item with no marker at all — a different
# defect with a different fix.
assert_eq "undeclared level: not reported as a missing marker" "absent" "$(out_has "UNTAGGED: line")"

# ---------------------------------------------------------------------------------------------
# Rows: the reverse pin. The model must not declare a tier the checklist never uses.
# ---------------------------------------------------------------------------------------------

assert_fixture "self-audit-levels-unused" "$FIX_DOC"
run_check "self-audit-levels-unused"
assert_eq "the model declares a level no item carries: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "unused level: says the model and the checklist drifted apart" \
  "the maturity model declares 'L4' but no checklist item carries it" "$CHK_OUT"
assert_eq "unused level: every item is properly tagged, so nothing is reported untagged" "absent" "$(out_has "UNTAGGED: line")"

# ---------------------------------------------------------------------------------------------
# Rows: nothing to read. Each must fail with its own message — a missing doc, a missing model, a
# missing legend and an empty checklist are four problems with four different fixes.
# ---------------------------------------------------------------------------------------------

assert_fixture "self-audit-levels-no-model" "$FIX_DOC"
run_check "self-audit-levels-no-model"
assert_eq "checklist with no maturity-model table: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no model: says the level set could not be read" "declares no maturity levels in a table under '## Maturity levels'" "$CHK_OUT"
assert_contains "no model: states that nothing was verified" "nothing was verified" "$CHK_OUT"
assert_eq "no model: does not fall back to a hardcoded L1-L4 and pass items anyway" "absent" "$(out_has "Examined")"

assert_fixture "self-audit-levels-no-items" "$FIX_DOC"
run_check "self-audit-levels-no-items"
assert_eq "a model but no checklist items at all: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no items: refuses to pass vacuously" "no checklist items were examined — this gate verified nothing" "$CHK_OUT"
assert_contains "no items: reports the zero rather than staying silent" "Examined 0 checklist item(s)" "$CHK_OUT"

assert_fixture "self-audit-levels-no-legend" "$FIX_DOC"
run_check "self-audit-levels-no-legend"
assert_eq "markers on every item but no legend explaining them: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no legend: says which sentence went missing" "has no '$LEGEND_PREFIX' line" "$CHK_OUT"
assert_eq "no legend: the items themselves are fine, so none is reported untagged" "absent" "$(out_has "UNTAGGED: line")"

# The row that proves the checker reads the tree it is handed and not the repo this file lives in:
# against the real kit it examines the whole checklist.
assert_fixture "self-audit-levels-empty" ".gitkeep"
run_check "self-audit-levels-empty"
assert_eq "empty tree: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty tree: says the checklist could not be read at all" "no $CHECKLIST_DOC under" "$CHK_OUT"
assert_eq "empty tree: did not check the real repo instead" "absent" "$(out_has "Examined")"

# ---------------------------------------------------------------------------------------------
# Rows: the real repo. The fixtures prove the checker works; these prove touchstone passes it.
# ---------------------------------------------------------------------------------------------

REAL_RC=0
REAL_OUT="$(check_self_audit_levels "$KIT" 2>&1)" || REAL_RC=$?
assert_eq "every item of touchstone's own self-audit checklist carries a declared level" "0" "$REAL_RC"
CHK_OUT="$REAL_OUT"
assert_contains "touchstone: its four levels were read out of its own table" \
  "against 4 declared level(s) (L1 L2 L3 L4)" "$CHK_OUT"
assert_eq "touchstone: the checklist really was read and had items" "absent" "$(out_has "Examined 0 checklist item(s)")"
# These three name the defect rather than resting on the exit code above. Stripping a marker off one
# item otherwise fails only the rc row, whose output is the bare "expected 0, actual 1" — true, but
# it does not say WHICH of the ~150 items broke, and the point of a gate is to be actionable.
assert_eq "touchstone: no item of its own checklist is missing a marker" "absent" "$(out_has "UNTAGGED: line")"
assert_eq "touchstone: no item of its own checklist invents a level" "absent" "$(out_has "UNDECLARED: line")"
assert_eq "touchstone: every level its model declares is carried by at least one item" "absent" "$(out_has "UNUSED: the maturity model declares")"
# An EXACT count, tightened from the original `>= 100` floor. The floor was a deliberate choice so
# that adding an item would not fail the test, and it does catch a parser that stops matching most
# of the list. But it cannot catch the regression this file exists to prevent: 14 bundled items were
# just split into 168, and a floor of 100 would sit green through a re-bundling that collapsed them
# back, or through 68 items being deleted outright.
#
# The maintenance cost is the point, not a side effect. Adding a checklist item is exactly the moment
# to confirm the new item is tagged, so a test that must be updated then is doing its job. Update the
# number deliberately; do not widen it back into a floor to avoid the edit.
REAL_ITEMS="$(printf '%s\n' "$REAL_OUT" | sed -n 's/^Examined \([0-9][0-9]*\) checklist item(s).*/\1/p')"
[ -n "$REAL_ITEMS" ] || REAL_ITEMS=0
assert_eq "touchstone: every checklist item was matched, exactly" "168" "$REAL_ITEMS"

ts_report
