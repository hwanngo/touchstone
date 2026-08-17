#!/usr/bin/env bash
# Gate: scripts/score-eval.sh turns a findings file plus an answer key into a verdict.
# It is the only part of the eval system that runs in the hermetic suite — it takes text in and
# prints numbers out, with no model and no network.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
SCORER="$KIT/scripts/score-eval.sh"
FIXTURES="$KIT/tests/fixtures"

assert_fixture() {
  local missing=""
  for f in "$@"; do [ -e "$FIXTURES/$f" ] || missing="$missing $f"; done
  assert_eq "fixture present:$*" "" "$missing"
}

score() { # <fixture-dir> -> sets SCORE_RC, SCORE_OUT
  local d="$FIXTURES/$1"
  if [ ! -d "$d" ]; then
    SCORE_RC=126
    SCORE_OUT="FIXTURE MISSING: $d"
    return 0
  fi
  SCORE_OUT="$(bash "$SCORER" "$d/answer-key.txt" "$d/findings.txt" 2>&1)"
  SCORE_RC=$?
}

assert_fixture "score-eval-basic/answer-key.txt" "score-eval-basic/findings.txt"
score "score-eval-basic"
assert_eq "a run that finds both required defects passes" "0" "$SCORE_RC"
assert_contains "it reports how many it matched" "matched 2 of 2 required" "$SCORE_OUT"
assert_contains "and reports zero unmatched" "unmatched 0" "$SCORE_OUT"
assert_contains "and says so explicitly" "verdict PASS" "$SCORE_OUT"

assert_fixture "score-eval-empty/answer-key.txt" "score-eval-empty/findings.txt"
score "score-eval-empty"
assert_eq "a run that finds nothing fails" "1" "$SCORE_RC"
assert_contains "it names the shortfall" "matched 0 of 2 required" "$SCORE_OUT"
assert_contains "and says so explicitly" "verdict FAIL" "$SCORE_OUT"

# A scorer handed no required entries has proved nothing; that must fail rather than divide by zero
# into a vacuous PASS.
TMP="$(mktemp -d)"
: >"$TMP/empty-key.txt"
: >"$TMP/no-findings.txt"
VAC_OUT="$(bash "$SCORER" "$TMP/empty-key.txt" "$TMP/no-findings.txt" 2>&1)"
VAC_RC=$?
rm -rf "$TMP"
assert_eq "an answer key with zero required entries fails instead of passing vacuously" "1" "$VAC_RC"
assert_contains "and says why" "no required entries" "$VAC_OUT"

# Finding 1: `read` returns non-zero on a file's final line when it is not newline-terminated, even
# though it still populates the fields from that line. Without the `|| [ -n "$var" ]` guard, an
# answer key missing its trailing newline (ordinary for a hand-written file) silently loses its last
# required entry from the loop, shrinking the denominator into a vacuous 100%-recall PASS.
assert_fixture "score-eval-no-trailing-newline/answer-key.txt" "score-eval-no-trailing-newline/findings.txt"
score "score-eval-no-trailing-newline"
assert_eq "a key missing its trailing newline still counts every required entry: exits 1" "1" "$SCORE_RC"
assert_contains "both required entries are counted, not just the newline-terminated ones" \
  "matched 1 of 2 required" "$SCORE_OUT"
assert_contains "and the verdict reflects the real miss" "verdict FAIL" "$SCORE_OUT"

# Finding 2: a finding that is a strict substring of an already-matched line (e.g. "a.py: alph"
# inside "a.py: alpha") must NOT be absorbed by a substring test against the matched-lines blob — it
# is a spurious finding matching no answer-key entry, i.e. it is UNMATCHED (see below for why that
# is the name, not "false positive").
assert_fixture "score-eval-substring-fp/answer-key.txt" "score-eval-substring-fp/findings.txt"
score "score-eval-substring-fp"
assert_eq "a finding that is a substring of a real match still fails" "1" "$SCORE_RC"
assert_contains "the substring finding is counted as its own unmatched line" "unmatched 1" "$SCORE_OUT"
assert_contains "and the verdict reflects it, despite full recall" "verdict FAIL" "$SCORE_OUT"

# --- the "false-positives" label is gone: matching no answer-key entry is UNMATCHED, not FALSE ----
# Uncatalogued is not the same claim as untrue — an answer key only records what someone thought to
# write down, and a thorough, honest agent will routinely surface true defects nobody catalogued.
# Measuring genuine precision would require planting decoys, which no case currently has (see
# evals/README.md). The scorer must never print the old, dishonest label again.
case "$SCORE_OUT" in
*false-positives*) FP_LABEL="present" ;;
*) FP_LABEL="absent" ;;
esac
assert_eq "the old 'false-positives' label is gone from the scorer's output" "absent" "$FP_LABEL"

# --- score floors: an optional --meta argument lets a case demand more than exact-match -----------
#
# Without --meta, behaviour is UNCHANGED from every prior version of this script: PASS requires
# matched == required AND unmatched == 0. With --meta naming a meta.txt carrying numeric
# `min_recall:`/`max_unmatched:` lines, PASS instead requires recall >= min_recall AND
# unmatched <= max_unmatched — the mechanism that lets a case like evals/cases/standards-gaps
# accept a bounded number of true-but-uncatalogued findings instead of failing on every one.
assert_fixture "score-eval-floors/answer-key.txt" "score-eval-floors/findings-extra.txt" \
  "score-eval-floors/findings-partial.txt" "score-eval-floors/meta-generous.txt" \
  "score-eval-floors/meta-strict.txt" "score-eval-floors/meta-malformed.txt"

score_meta() { # <answer-key> <findings> <meta> -> sets SCORE_RC, SCORE_OUT
  local key="$FIXTURES/score-eval-floors/$1" findings="$FIXTURES/score-eval-floors/$2" \
    meta="$FIXTURES/score-eval-floors/$3"
  SCORE_OUT="$(bash "$SCORER" "$key" "$findings" --meta "$meta" 2>&1)"
  SCORE_RC=$?
}

# Full recall, one uncatalogued (unmatched) finding, floors allow up to 1: PASS despite the nonzero
# unmatched count that would fail the legacy rule.
score_meta "answer-key.txt" "findings-extra.txt" "meta-generous.txt"
assert_eq "an uncatalogued finding within the floor still passes" "0" "$SCORE_RC"
assert_contains "the unmatched count is reported" "unmatched 1" "$SCORE_OUT"
assert_contains "the floors themselves are echoed" "floors min_recall=100 max_unmatched=1" "$SCORE_OUT"
assert_contains "and the verdict is PASS" "verdict PASS" "$SCORE_OUT"

# Same findings, but a floor of zero: the identical uncatalogued finding now fails, proving the
# floor is actually enforced rather than always passing once --meta is supplied.
score_meta "answer-key.txt" "findings-extra.txt" "meta-strict.txt"
assert_eq "the same uncatalogued finding fails a zero floor" "1" "$SCORE_RC"
assert_contains "and the verdict is FAIL" "verdict FAIL" "$SCORE_OUT"

# Zero unmatched findings but recall below min_recall: the recall floor is enforced independently
# of the unmatched floor.
score_meta "answer-key.txt" "findings-partial.txt" "meta-generous.txt"
assert_eq "recall below the floor fails even with zero unmatched" "1" "$SCORE_RC"
assert_contains "it names the shortfall" "matched 1 of 2 required" "$SCORE_OUT"
assert_contains "and the verdict is FAIL" "verdict FAIL" "$SCORE_OUT"

# A --meta file with a non-numeric floor is a caller error, not a silent fallback to the legacy
# rule: score-eval.sh must refuse loudly rather than guess what the case author meant.
score_meta "answer-key.txt" "findings-extra.txt" "meta-malformed.txt"
assert_eq "a non-numeric floor exits 2 rather than silently falling back" "2" "$SCORE_RC"
assert_contains "and names which floor is malformed" "max_unmatched" "$SCORE_OUT"
assert_contains "and says it must be numeric" "no numeric" "$SCORE_OUT"

# Finding 3: a `#` comment line (or a blank line) in a FINDINGS file must not be scored as a
# finding. Before this fixture existed, a provenance header on a findings file — "# produced
# 2026-08-17 with sonnet" — matched no answer-key entry, so it counted as `unmatched` and flipped a
# genuine PASS to FAIL. That is exactly why the committed evals/cases/*/reference-findings.txt
# files carried no header at all: adding one would have silently broken their score. This fixture
# is score-eval-basic's own key with a leading `#` header, a blank line, and an indented `#`
# comment prepended to the same two matching lines — same answer key, same real findings, so the
# verdict must be identical to score-eval-basic's: PASS, matched 2 of 2, unmatched 0.
assert_fixture "score-eval-findings-header/answer-key.txt" "score-eval-findings-header/findings.txt"
score "score-eval-findings-header"
assert_eq "a findings file with a comment header still passes" "0" "$SCORE_RC"
assert_contains "the header does not inflate unmatched" "unmatched 0" "$SCORE_OUT"
assert_contains "both real findings are still matched" "matched 2 of 2 required" "$SCORE_OUT"
assert_contains "and the verdict is PASS, not flipped by the header" "verdict PASS" "$SCORE_OUT"

# --- POLARITY: a finding that DENIES the defect must not satisfy the entry ------------------------
# Substring matching is polarity-blind, so a findings file asserting every catalogued defect is
# ABSENT used to score a perfect 2-of-2 PASS: the denial contains the same path and the same
# keywords as a real report. That is the most valuable thing an agent can get wrong, because it is
# what a lazy or over-confident run produces.
#
# The two fixture findings files are the SAME two paths and the SAME two needles, differing only in
# polarity. findings-real.txt is the KNOWN-POSITIVE CONTROL: without it, a scorer that had simply
# stopped matching anything at all would pass the denial row below for the wrong reason.
assert_fixture "score-eval-polarity/answer-key.txt" "score-eval-polarity/findings-real.txt" \
  "score-eval-polarity/findings-denial.txt"

pol() { # <findings-file> -> sets SCORE_RC, SCORE_OUT
  local d="$FIXTURES/score-eval-polarity"
  SCORE_OUT="$(bash "$SCORER" "$d/answer-key.txt" "$d/$1" 2>&1)"
  SCORE_RC=$?
}

pol "findings-real.txt"
assert_eq "control: findings that REPORT both defects still pass" "0" "$SCORE_RC"
assert_contains "control: both required entries matched" "matched 2 of 2 required" "$SCORE_OUT"
assert_contains "control: verdict PASS" "verdict PASS" "$SCORE_OUT"

pol "findings-denial.txt"
assert_eq "findings that DENY both defects fail" "1" "$SCORE_RC"
assert_contains "a conformance assertion satisfies no entry" "matched 0 of 2 required" "$SCORE_OUT"
assert_contains "and lands in unmatched, where a human can adjudicate it" "unmatched 2" "$SCORE_OUT"
assert_contains "and the verdict is FAIL" "verdict FAIL" "$SCORE_OUT"

# --- DEGENERATE ENTRIES: a key whose recall could never fail is a caller error, not a 100% --------
# Both shapes shipped in this repo's own answer keys (see scripts/check-evals.sh, which gates them),
# and both produced `recall 100 / verdict PASS` on findings that said nothing about the defect.
assert_fixture "score-eval-degenerate/answer-key-empty-needle.txt" \
  "score-eval-degenerate/answer-key-needle-in-path.txt" "score-eval-degenerate/findings.txt"

deg() { # <answer-key-file> -> sets SCORE_RC, SCORE_OUT
  local d="$FIXTURES/score-eval-degenerate"
  SCORE_OUT="$(bash "$SCORER" "$d/$1" "$d/findings.txt" 2>&1)"
  SCORE_RC=$?
}

deg "answer-key-empty-needle.txt"
assert_eq "an empty substring exits 2 instead of scoring 100%" "2" "$SCORE_RC"
assert_contains "and says what is wrong with it" "EMPTY substring" "$SCORE_OUT"
case "$SCORE_OUT" in
*"verdict PASS"*) DEG_VERDICT="PASS printed" ;;
*) DEG_VERDICT="no PASS printed" ;;
esac
assert_eq "and prints no verdict at all, so nothing reads it as a pass" "no PASS printed" "$DEG_VERDICT"

deg "answer-key-needle-in-path.txt"
assert_eq "a substring contained in its own path exits 2" "2" "$SCORE_RC"
assert_contains "and says why it measures nothing" "contained in its own path" "$SCORE_OUT"

# A --meta flag naming a file that does not exist on disk is likewise a loud, specific failure.
NOMETA_OUT="$(bash "$SCORER" "$FIXTURES/score-eval-floors/answer-key.txt" \
  "$FIXTURES/score-eval-floors/findings-extra.txt" --meta "$FIXTURES/score-eval-floors/does-not-exist.txt" 2>&1)"
NOMETA_RC=$?
assert_eq "a --meta file that does not exist exits 2" "2" "$NOMETA_RC"
assert_contains "and says no such file" "no such file" "$NOMETA_OUT"

ts_report
