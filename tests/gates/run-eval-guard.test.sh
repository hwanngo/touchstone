#!/usr/bin/env bash
# Gate: scripts/run-eval.sh is the half of the eval system that needs a model call — not hermetic,
# not offline, not deterministic. It must never run without an explicit, deliberate opt-in, and
# tests/run.sh (the hermetic suite) must never call it at all.
#
# Two things are asserted:
#   1. BEHAVIOURAL — without --confirm-model-call the runner refuses (exit 3) and explains why,
#      rather than silently doing nothing or, worse, silently doing something model-shaped.
#   2. STRUCTURAL — no file under tests/ references run-eval.sh except this one. This is the
#      valuable half: it is what stops a future test from importing the model-dependent runner into
#      the blocking suite by accident. An assertion nobody has ever seen fail is worthless, so this
#      file's own history records having planted a reference in another test file and watched this
#      row go red before the fix — see the task-3 report for the before/after tallies.
#
# Every row here is guarded two ways, matching the sibling gate tests in this suite:
#   - assert_fixture states, as its own assertion, which files the row depends on.
#   - every exit-code assertion is paired with an assert_contains on the specific message, so a
#     "non-zero" or "zero" exit is never accepted on its own as proof of the right behaviour.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
RUNNER="$KIT/scripts/run-eval.sh"
TESTS_DIR="$KIT/tests"
CASE_DIR="$KIT/evals/cases/adopter-broken-toolchain"

assert_fixture() {
  local missing=""
  for f in "$@"; do [ -e "$f" ] || missing="$missing $f"; done
  assert_eq "fixture present:$*" "" "$missing"
}

run_runner() { # <args...> -> sets RUN_RC, RUN_OUT
  if [ ! -f "$RUNNER" ]; then
    RUN_RC=126
    RUN_OUT="FIXTURE MISSING: $RUNNER"
    return 0
  fi
  RUN_OUT="$(cd "$KIT" && bash "$RUNNER" "$@" 2>&1)"
  RUN_RC=$?
}

# --- behavioural: the guard itself ---------------------------------------------------------------
assert_fixture "$RUNNER" "$CASE_DIR/meta.txt" "$CASE_DIR/answer-key.txt"
run_runner --case adopter-broken-toolchain
assert_eq "the runner refuses without an explicit opt-in" "3" "$RUN_RC"
assert_contains "and explains why rather than failing silently" "needs a model call" "$RUN_OUT"

# Confirming the runner is not simply broken end-to-end: WITH the flag it does exactly what its
# docstring promises — prepares the case and prints the hand-off prompt, no scoring yet.
run_runner --case adopter-broken-toolchain --confirm-model-call
assert_eq "with the flag, it proceeds" "0" "$RUN_RC"
assert_contains "and names the target agent" "agent: adoption-doctor" "$RUN_OUT"
assert_contains "and hands off the exact scoring command" "score-eval.sh" "$RUN_OUT"

# And once a findings file exists, it scores it via score-eval.sh rather than re-implementing the
# scoring contract itself.
TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "run-eval scoring hand-off" "mktemp -d failed"
else
  trap 'rm -rf "$TMP"' EXIT
  # THE FINDINGS ARE THE CASE'S OWN COMMITTED reference-findings.txt, not a file built from the
  # answer key. This row used to synthesise them with
  # `awk -F'|' '$1 == "required" { print $2 ": " $3 }' answer-key.txt` — every required entry then
  # matched BY CONSTRUCTION, for any key, however broken, so the assertion below could never fail on
  # answer-key content. It is the only hermetic test that reads a real answer key; making it read a
  # real findings file too is what lets it notice an answer-key edit.
  # (The full replay across every case lives in tests/gates/reference-findings-replay.test.sh; this
  # row's job is only to prove run-eval.sh hands off to the scorer rather than re-implementing it.)
  assert_fixture "$CASE_DIR/reference-findings.txt"
  run_runner --case adopter-broken-toolchain \
    --findings "$CASE_DIR/reference-findings.txt" --confirm-model-call
  assert_eq "the case's committed reference findings score a pass through the runner" "0" "$RUN_RC"
  assert_contains "and the score-eval.sh verdict is echoed through" "verdict PASS" "$RUN_OUT"
  assert_contains "and it is the scorer's real recall line, not a synthesised one" \
    "matched 2 of 2 required" "$RUN_OUT"

  # ZERO WORK DONE MUST NEVER BE EXIT 0. A --findings path that does not exist used to fall through
  # the `[ -n "$FINDINGS" ] && [ -f "$FINDINGS" ]` test: the hand-off text had already been printed,
  # so `just eval <case> <typo-path>` exited 0 having scored nothing — and exit 0 reads as PASS to
  # anything checking status, in the one runner whose whole job is to produce a verdict. A directory
  # is included because `just eval <case> some/dir` is the same typo one character later.
  run_runner --case adopter-broken-toolchain --findings "$TMP/no-such-findings.txt" --confirm-model-call
  assert_eq "a --findings path that does not exist exits 2, not 0" "2" "$RUN_RC"
  assert_contains "and says nothing was scored" "Nothing was scored" "$RUN_OUT"
  run_runner --case adopter-broken-toolchain --findings "$TMP" --confirm-model-call
  assert_eq "a --findings path that is a directory exits 2, not 0" "2" "$RUN_RC"
  assert_contains "and names the unreadable path" "no readable file" "$RUN_OUT"
  # The empty default stays a pass: `just eval <case>` passes `--findings ""` and its only job is to
  # print the hand-off text, so this must NOT be swept up by the check above.
  run_runner --case adopter-broken-toolchain --findings "" --confirm-model-call
  assert_eq "an empty --findings is the hand-off-only path and still exits 0" "0" "$RUN_RC"
  assert_contains "and prints the hand-off command" "score-eval.sh" "$RUN_OUT"
fi

# A dangling flag (no value) must fail fast, not hang. `shift 2` silently no-ops when only one
# positional argument remains, which — without an explicit guard — spins the parse loop on the same
# argument forever instead of exiting. Bounded by `timeout` so a regression fails this row instead
# of hanging the whole suite.
if command -v timeout >/dev/null 2>&1; then
  DANGLE_OUT="$(cd "$KIT" && timeout 5 bash "$RUNNER" --case 2>&1)"
  DANGLE_RC=$?
  assert_eq "a dangling --case with no value fails fast rather than hanging" "2" "$DANGLE_RC"
  assert_contains "and says which flag needed a value" "--case needs a value" "$DANGLE_OUT"
else
  ts_skip "dangling-flag hang guard" "timeout not available"
fi

# --- structural: the hermetic suite must never call the model-dependent runner -------------------
# Asserted structurally, not by convention. This is the row that must be provable to fail: plant a
# reference to run-eval.sh in some other test file, watch this go red, remove it, watch it go green
# again. See the task-3 report for the recorded before/after tallies from doing exactly that.
#
# THE EXEMPTION USED TO SWALLOW THE ASSERTION. The check was
# `grep -rl … | grep -v 'run-eval-guard.test.sh'` — i.e. it exempted, by filename, the one file that
# does call the runner, three times, twice with --confirm-model-call. So the guard protected every
# file except the file most likely to break it: the first commit that gives run-eval.sh a real model
# call makes tests/run.sh non-hermetic with this row still green, because its sole caller is its own
# exemption. Two changes fix that, and neither leaves an exemption that hides anything:
#
# 1. The caller list is compared for EQUALITY against the one expected path, not filtered and
#    compared to empty. A second caller appearing fails the row — and so does this file ceasing to
#    reference the runner at all, which would mean the behavioural rows above had been deleted. The
#    old form passed vacuously in that second case.
assert_fixture "$TESTS_DIR" "$RUNNER"
CALLERS="$(bash -c "grep -rl 'run-eval.sh' '$TESTS_DIR' 2>/dev/null | sort" || true)"
assert_eq "this file is the ONLY test that references the model-dependent runner" \
  "$TESTS_DIR/gates/run-eval-guard.test.sh" "$CALLERS"

# 2. The exemption is only safe while the runner it exempts cannot actually reach a model or the
#    network — which is true today (it prints a hand-off and delegates to the hermetic
#    scripts/score-eval.sh) but is exactly what run-eval.sh's stated purpose invites someone to
#    change. So that safety is now ASSERTED rather than assumed: the runner must contain none of the
#    commands that could reach outside this machine. A commit that gives the runner a model call
#    fails THIS row, in this file, and is forced to restructure the behavioural rows above (drive a
#    stub, or drop the --confirm-model-call rows) instead of shipping a silently non-hermetic suite.
#
#    Matched against command-shaped markers, not the word "model": run-eval.sh's own prose is full of
#    "model call" and "--confirm-model-call" and must not self-trip.
MODEL_REACH="$(bash -c "grep -nE 'claude |claude\\\$|anthropic|openai|curl |wget |nc |ssh |https?://|--prompt' '$RUNNER'" || true)"
assert_eq "the runner this file DOES invoke cannot reach a model or the network" "" "$MODEL_REACH"

ts_report
