#!/usr/bin/env bash
# Gate: scripts/check-standards.sh. One file, one harness, two findings — they share a gate, a
# fixture root and a run_gate, and were only ever separate because the round that found the second
# one was scoped to adding files rather than editing them.
#
# FINDING 1 — the orphan mask. Line 26 was `files=(standards/*/*.md)`, a FIXED two-level glob, so
# anything sitting directly under standards/ was never validated in its life. Measured on this
# repo: `find standards -name '*.md'` = 69, the glob matched 67, and the gate reported
# "Validated 66" (it also skipped standards/frameworks/README.md as an index). The two files the
# glob could not reach were standards/README.md and standards/self-audit.md — the latter being the
# kit's flagship 149-item checklist, which had therefore never been checked by anything.
#
# The related failure mode is vacuity: a gate that enumerates nothing must not print a pass. The
# old code printed "no standards docs found" and exited 0.
#
# FINDING 2 — generation scaffolding that leaks into a committed standards doc: a bare '<tag>' /
# '</tag>' line sitting in prose, outside every code fence. standards/platform/terraform.md ended
# with a literal closing 'content' tag and a literal closing 'invoke' tag, outside any fence, on
# the last two lines of the file. Commit 9e700f1 added exactly this rule to check-skills.sh and
# fixed the skills/ side; the standards/ side had no such rule, so the same defect class sat in
# the flagship IaC doc unnoticed.
#
# That rule MUST be fence-aware, and that is the whole difficulty. A naive '^</?[a-z]+>$' also
# matches legitimate committed content: the closing 'script' tag in the Svelte, Vue and Nuxt
# single-file-component examples, and the landmark elements in practices/accessibility.md — all
# four inside fences, all four things a fence-blind rule would take the build red on. So two of
# the fixtures below are a matched pair: the same shape of line, once as a defect and once as
# content.
#
# The two fence markers must also be tracked INDEPENDENTLY. standards-scaffolding-fenced puts a
# '~~~' line inside a backtick block; with one shared toggle that line closes the block, and the
# closing script tag two lines later reads as prose — the gate then fires on a legitimate file.
#
# Each fixture under tests/fixtures/standards-* is a minimal tree with exactly one property under
# test. We exercise the real scripts/check-standards.sh by copying it into each fixture's own
# scripts/ dir and running it from there — the gate self-locates with
# `cd "$(dirname "${BASH_SOURCE[0]}")/.."`, so merely cd-ing this shell into a fixture would
# silently scan the REAL repo instead and every measurement would be wrong.
#
# EVERY row below is guarded two ways, for the reason spelled out in check-links.test.sh:
#   1. assert_fixture states, as its own assertion, which files the row depends on. run_gate copies
#      the fixture into an empty temp tree, so a DELETED fixture leaves the gate scanning nothing —
#      which now exits non-zero, satisfying every "exits non-zero" assertion for the wrong reason.
#      The empty-tree row is structurally incapable of telling the two apart on exit code alone.
#      run_gate therefore refuses to run at all on a missing fixture rather than scanning an empty
#      tree, and the precondition row names the miss.
#   2. Every exit-code assertion is paired with an assert_contains on the specific message that
#      verdict should carry, so "non-zero" is never accepted on its own.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
GATE="$KIT/scripts/check-standards.sh"
FIXTURES="$KIT/tests/fixtures"

# Hard rule 4: self-skip only for genuine tool absence, never for anything check-standards.sh does.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "check-standards" "mktemp not available"
  ts_report
  exit 0
fi

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# Every bare-tag literal this file needs — in the fixture it builds AND in the messages it asserts
# on — is assembled from these fragments at runtime. Writing one as a literal would put the exact
# defect under test into a tracked file, which this repo's own agent hooks refuse (correctly: that
# is how the terraform.md leak got committed in the first place).
LT='<'
GT='>'
CLOSE_CONTENT="${LT}/content${GT}"
CLOSE_INVOKE="${LT}/invoke${GT}"

# assert_fixture <fixture> <file>... — precondition row: every listed file must be on disk before the
# row that follows means anything.
assert_fixture() {
  local fixture="$1" state="complete" missing="" f
  shift
  for f in "$@"; do
    if [ ! -f "$FIXTURES/$fixture/$f" ]; then missing="$missing $f"; fi
  done
  if [ -n "$missing" ]; then state="missing:$missing"; fi
  assert_eq "fixture $fixture is complete on disk" "complete" "$state"
}

# run_gate <fixture-name> [builder-fn] — copies tests/fixtures/<fixture-name> into a fresh tmp tree,
# optionally calls <builder-fn> "<tree>", installs a copy of the real gate at
# <tree>/scripts/check-standards.sh (mirroring how an adopting repo carries its own copy, per
# scripts/init.sh), runs it from <tree>, and leaves GATE_RC / GATE_OUT set.
GATE_RC=0
GATE_OUT=""
run_gate() {
  local fixture="$1" builder="${2:-}"
  if [ ! -d "$FIXTURES/$fixture" ]; then
    # Refuse to run rather than silently scan an empty tree.
    GATE_RC=126
    GATE_OUT="FIXTURE MISSING: $FIXTURES/$fixture"
    return 0
  fi
  WORK="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    GATE_RC=127
    GATE_OUT="mktemp -d failed"
    return 0
  fi
  mkdir -p "$WORK/repo"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  if [ -n "$builder" ]; then "$builder" "$WORK/repo"; fi
  mkdir -p "$WORK/repo/scripts"
  cp "$GATE" "$WORK/repo/scripts/check-standards.sh"
  GATE_RC=0
  GATE_OUT="$(cd "$WORK/repo" && bash scripts/check-standards.sh 2>&1 </dev/null)" || GATE_RC=$?
  rm -rf "$WORK"
  WORK=""
}

# gate_out_has <needle> — echoes "present" or "absent", so a row can assert absence with assert_eq.
gate_out_has() {
  case "$GATE_OUT" in
  *"$1"*) echo present ;;
  *) echo absent ;;
  esac
}

nonzero() { if [ "$GATE_RC" -ne 0 ]; then echo nonzero; else echo zero; fi; }

# Appends the exact two lines that were found at the end of standards/platform/terraform.md, in
# the same place: after the final checklist item, outside every fence, at end of file.
build_scaffolding_leak() {
  printf '%s\n%s\n' "$CLOSE_CONTENT" "$CLOSE_INVOKE" >>"$1/standards/platform/leaky.md"
}

# === FINDING 1: enumeration depth and vacuity =====================================================

# --- the orphan mask: a doc directly under standards/ must be validated -------------------------

# glossary.md sits at standards/glossary.md, exactly where `standards/*/*.md` cannot reach. It breaks
# three rules at once; the gate must see all of them.
assert_fixture "standards-toplevel-defect" "standards/glossary.md" "standards/languages/shell.md"
run_gate "standards-toplevel-defect"
assert_eq "doc directly under standards/: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "top-level doc: reported under its standards/-relative name" "FAIL: glossary.md:" "$GATE_OUT"
assert_contains "top-level doc: its missing H1 is caught" "first line is not an H1 title" "$GATE_OUT"
assert_contains "top-level doc: its unperiodised '## 3 ' heading is caught" "numbered heading without a period" "$GATE_OUT"
assert_contains "top-level doc: its untagged fence is caught" "untagged code fence" "$GATE_OUT"
# The count must be printed even on the failure path, so a future depth change cannot shrink coverage
# unnoticed behind a red build.
assert_contains "failing run still reports how many docs it examined" "Examined 2 markdown doc(s) under standards/" "$GATE_OUT"

# --- vacuity: enumerating nothing is a failure, not a pass --------------------------------------

# This row cannot be defended by its exit code at all: deleting the fixture reproduces the exact
# condition under test. Only the precondition row above and the message below tell the two apart.
assert_fixture "standards-empty" "standards/.gitkeep"
run_gate "standards-empty"
assert_eq "standards/ with no markdown at all: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty standards/: says it found nothing" "no markdown docs found under standards/" "$GATE_OUT"
assert_eq "empty standards/: claims nothing was validated" "absent" "$(gate_out_has "Validated")"

# --- the exemption is explicit, deliberate, and scoped to ONE rule ------------------------------

# README.md and self-audit.md are an index and a scoring checklist: neither has (or should have) a
# '## Definition of done' closer. They are exempt from that ONE rule — and counted, so the exemption
# is visible rather than an accident of glob depth.
assert_fixture "standards-index-exempt" "standards/README.md" "standards/self-audit.md" "standards/languages/shell.md"
run_gate "standards-index-exempt"
assert_eq "index README + self-audit without a Definition-of-done closer: exits 0" "0" "$GATE_RC"
assert_contains "index/checklist docs are counted as examined, not skipped" "Examined 3 markdown doc(s) under standards/" "$GATE_OUT"
assert_contains "the exemption is reported, not silent" "2 exempt from the 'Definition of done' rule" "$GATE_OUT"

# ...and every OTHER rule still applies to self-audit.md. Without this row the exemption above could
# be implemented as a blanket skip and nothing would notice.
assert_fixture "standards-selfaudit-checked" "standards/self-audit.md" "standards/languages/shell.md"
run_gate "standards-selfaudit-checked"
assert_eq "self-audit.md with an untagged fence: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "self-audit.md is exempt from the DoD rule only, not from validation" "FAIL: self-audit.md: has an untagged code fence" "$GATE_OUT"
assert_eq "self-audit.md is not asked for a Definition-of-done closer" "absent" "$(gate_out_has "FAIL: self-audit.md: missing a bare")"

# --- control: a well-formed tree passes, and says how much it looked at -------------------------

assert_fixture "standards-known-good" "standards/languages/shell.md" "standards/README.md" "skills/ok-standards/SKILL.md"
run_gate "standards-known-good"
assert_eq "well-formed standards tree: exits 0" "0" "$GATE_RC"
assert_contains "known-good tree: both docs were really examined" "Examined 2 markdown doc(s) under standards/" "$GATE_OUT"
assert_contains "known-good tree: reports the validated count" "Validated 2 standards docs." "$GATE_OUT"
# shell.md is referenced by the fixture's one skill, so the coverage report must stay quiet.
assert_eq "known-good tree: the covered doc is not reported as an orphan" "absent" "$(gate_out_has "languages/shell.md")"

# === FINDING 2: leaked generation scaffolding =====================================================

# --- the defect: a bare tag line in prose must fail the gate ------------------------------------

assert_fixture "standards-scaffolding-leak" "standards/platform/leaky.md" "standards/languages/shell.md"
run_gate "standards-scaffolding-leak" build_scaffolding_leak
assert_eq "leaked scaffolding in a standards doc: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "leaked scaffolding: reported under its standards/-relative name" \
  "FAIL: platform/leaky.md:" "$GATE_OUT"
assert_contains "leaked scaffolding: named as scaffolding, not as some generic shape complaint" \
  "leaked generation scaffolding at line" "$GATE_OUT"
assert_contains "leaked scaffolding: quotes the offending line so it can be found" \
  "$CLOSE_CONTENT" "$GATE_OUT"
assert_contains "leaked scaffolding: gives the line number" "line 15" "$GATE_OUT"
# The clean sibling must still have been enumerated: a rule that stopped at the first bad file
# would shrink coverage silently.
assert_contains "failing run still reports how many docs it examined" \
  "Examined 2 markdown doc(s) under standards/" "$GATE_OUT"

# --- the same shape, inside fences, is legitimate content and must NOT fire ---------------------

assert_fixture "standards-scaffolding-fenced" "standards/frameworks/component.md"
run_gate "standards-scaffolding-fenced"
assert_eq "closing script tag + landmarks inside fences: exits 0" "0" "$GATE_RC"
# The needle is the per-finding form, not the bare phrase: the run's summary line names the rule
# on every run, so matching on the phrase alone would report "present" for a clean tree too.
assert_eq "fenced tag lines: not reported as scaffolding" "absent" "$(gate_out_has "leaked generation scaffolding at line")"
# Proves the rule actually read this file rather than passing because it read nothing: the prose
# line count is the file's lines minus its four fence markers and its seven fenced lines.
assert_contains "fenced fixture: the rule really scanned the doc's prose" \
  "Scanned 19 prose line(s)" "$GATE_OUT"
assert_contains "fenced fixture: the doc was examined" "Examined 1 markdown doc(s) under standards/" "$GATE_OUT"

# --- vacuity: a run in which the rule read no prose at all is a failure, not a pass -------------

# There is no VALID tree in which this fires — an H1 on line 1 and a '## Definition of done'
# closer are both prose, and the gate demands them. That is exactly why the guard needs its own
# fixture: without one, the branch is unreachable from the suite and could rot into a no-op. The
# fixture is a doc that is one unclosed-then-closed fence and nothing else, so it also trips the
# H1 and closer rules; the row asserts the vacuity message specifically, not merely non-zero.
assert_fixture "standards-scaffolding-all-fenced" "standards/fenced.md"
run_gate "standards-scaffolding-all-fenced"
assert_eq "every line inside a fence: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "all-fenced tree: says the scaffolding rule read no prose" \
  "the leaked-scaffolding rule scanned no prose" "$GATE_OUT"
assert_contains "all-fenced tree: reports the zero it scanned rather than staying silent" \
  "Scanned 0 prose line(s)" "$GATE_OUT"

# --- regression: the four real docs a fence-blind rule would flag stay green --------------------

# Not a fixture — the real tree. These are the files the naive pattern hits, verified before the
# rule was written. If a future edit makes the rule fence-blind again, this row goes red on the
# repo's own content rather than waiting for someone to notice CI.
real_hits=0
for f in "$KIT/standards/frameworks/svelte.md" "$KIT/standards/frameworks/vue.md" \
  "$KIT/standards/frameworks/nuxt.md" "$KIT/standards/practices/accessibility.md"; do
  if [ ! -f "$f" ]; then
    real_hits="missing:$f"
    break
  fi
  n="$(grep -cE '^[[:space:]]*</?[A-Za-z][A-Za-z0-9_:-]*>[[:space:]]*$' "$f")" || true
  if [ "$n" -eq 0 ]; then
    real_hits="no-longer-representative:$f"
    break
  fi
done
assert_eq "the four real docs still contain the tag lines this rule must not flag" "0" "$real_hits"
assert_eq "real repo: check-standards.sh passes on the kit's own standards tree" "0" \
  "$(
    cd "$KIT" && bash scripts/check-standards.sh >/dev/null 2>&1
    echo $?
  )"

ts_report
