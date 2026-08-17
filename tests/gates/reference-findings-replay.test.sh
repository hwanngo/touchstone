#!/usr/bin/env bash
# Gate: every committed evals/cases/<id>/reference-findings.txt still scores a PASS against its
# case's answer-key.txt and meta.txt floors, through the CURRENT scripts/score-eval.sh.
#
# WHY THIS IS IN THE BLOCKING SUITE. This replay is deterministic, offline, hermetic and takes
# milliseconds — but it used to exist only in the weekly .github/workflows/eval.yml. `just ci` and PR
# CI ran only check-evals.sh, which reads a key's `sev` and `path` and never its substring. So a
# one-character answer-key edit landed green and surfaced up to seven days later, in a scheduled job
# nobody watches. Reproduced before this file existed: mutating
# `required|justfile|vendored kit` to `…|vendored kits` left check-evals.sh at rc=0,
# tests/gates/check-evals.test.sh at rc=0 and tests/gates/run-eval-guard.test.sh at
# `TS_TALLY 12 0 0`, while the replay scored `matched 1 of 2 / recall 50 / verdict FAIL`. This branch
# shipped TWO coincidental-match answer-key bugs (3c8669e, c1fa915) — precisely what this catches.
# The weekly job stays, and is now a rot-detector rather than the only detector.
#
# WHAT A PASS HERE PROVES, exactly: the scorer and the answer key still agree with each other on a
# frozen, previously-recorded findings text. NO MODEL RUNS. It proves nothing about whether the agent
# would still find those defects today — that is `just eval <case>`, run by a person. See
# evals/README.md's "Reference findings and what the scheduled workflow proves".
#
# NON-VACUITY. A case with no committed reference-findings.txt is skipped (not every case has one),
# but the file asserts a nonzero scored count as its own row: a run that scored nothing must fail,
# not report a confident green. The paired negative control at the end proves the replay can fail at
# all, by scoring a real answer key against a deliberately mismatched findings file.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
SCORER="$KIT/scripts/score-eval.sh"
CASES="$KIT/evals/cases"

assert_eq "the scorer exists" "yes" "$([ -f "$SCORER" ] && echo yes || echo no)"

scored=0
for case_dir in "$CASES"/*/; do
  [ -d "$case_dir" ] || continue
  id="$(basename "$case_dir")"
  findings="$case_dir/reference-findings.txt"
  [ -f "$findings" ] || continue
  key="$case_dir/answer-key.txt"
  meta="$case_dir/meta.txt"
  if [ ! -f "$key" ] || [ ! -f "$meta" ]; then
    assert_eq "$id: has both an answer key and a meta.txt beside its reference findings" \
      "both present" "key=$([ -f "$key" ] && echo yes || echo no) meta=$([ -f "$meta" ] && echo yes || echo no)"
    continue
  fi
  out="$(bash "$SCORER" "$key" "$findings" --meta "$meta" 2>&1)"
  rc=$?
  scored=$((scored + 1))
  assert_eq "$id: committed reference findings still score a PASS (rc)" "0" "$rc"
  assert_contains "$id: and the verdict says so" "verdict PASS" "$out"
  # Full recall, spelled out: the floors could in principle allow a partial match, but every shipped
  # case sets min_recall: 100, and asserting the matched/required line by value is what makes an
  # answer-key edit that breaks ONE entry a red row rather than a quieter one.
  req_n="$(awk -F'|' '$1 == "required" { c++ } END { print c + 0 }' "$key")"
  assert_contains "$id: and every required entry is matched, not merely enough of them" \
    "matched $req_n of $req_n required" "$out"
done

# The vacuity guard, as its own row: zero cases scored means this file proved nothing.
assert_eq "the replay scored at least one case" "yes" "$([ "$scored" -gt 0 ] && echo yes || echo no)"

# --- negative control: the replay must be able to FAIL ------------------------------------------
# Without this, a scorer that had started printing "verdict PASS" unconditionally would take every
# row above green. Scores a real, shipped answer key against a findings file that names none of its
# defects — the same key, the same scorer, only the findings changed.
CTRL="$(mktemp 2>/dev/null || true)"
if [ -z "$CTRL" ]; then
  ts_skip "replay negative control" "mktemp failed"
else
  printf 'unrelated/file.txt: something entirely uncatalogued\n' >"$CTRL"
  CTRL_KEY="$CASES/stale-claims/answer-key.txt"
  if [ ! -f "$CTRL_KEY" ]; then
    ts_skip "replay negative control" "evals/cases/stale-claims/answer-key.txt absent"
  else
    CTRL_OUT="$(bash "$SCORER" "$CTRL_KEY" "$CTRL" --meta "$CASES/stale-claims/meta.txt" 2>&1)"
    CTRL_RC=$?
    assert_eq "control: findings that match no entry fail the same replay" "1" "$CTRL_RC"
    assert_contains "control: and the verdict is FAIL" "verdict FAIL" "$CTRL_OUT"
  fi
  rm -f "$CTRL"
fi

ts_report
