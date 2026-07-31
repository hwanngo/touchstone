#!/usr/bin/env bash
# Gate: the `ci-required` aggregator in .github/workflows/ci.yml is the ONE check branch protection
# requires (ci-cd.md §4), so it decides whether every other gate can block a merge — and it was the
# only gate in the kit with no test of its own.
#
# The shell it runs is EXTRACTED FROM THE WORKFLOW AT TEST TIME, never copied here. A test holding
# its own copy of the logic passes forever after someone edits the workflow, which is the exact
# defect class this suite exists to kill. Everything below runs the workflow's real `run:` block
# under `bash -e` — the same way GitHub invokes it — against every `needs.*.result` shape the
# platform can produce.
#
# The two failure modes the aggregator exists to catch, and why each has rows here:
#   1. A bare `needs:` list does NOT fail on a skipped or cancelled dependency, and a skipped
#      REQUIRED check reports "success" to branch protection. So the job must reject any result
#      that is not literally `success` — not merely the ones GitHub calls failures.
#   2. A loop over an empty result list passes VACUOUSLY. So the job must also assert the COUNT of
#      results against a declared EXPECTED, or dropping a job from `needs:` silently shrinks the
#      gate to nothing while still reporting green.
#
# Every row is guarded the way tests/gates/check-links.test.sh guards its fixtures: preconditions
# assert, as their own rows, that the workflow and the job inside it are actually on disk and
# actually named `ci-required`, and every exit-code row is paired with an assert_contains on the
# specific message that verdict should carry. Without both, a renamed job yields an empty run block
# whose every invocation exits non-zero for entirely the wrong reason and satisfies eight of the
# nine exit-code assertions.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
WORKFLOW="$KIT/.github/workflows/ci.yml"
JOB="ci-required"

# Hard rule 4: self-skip only for genuine tool absence, never for anything the aggregator itself
# does — tests/run.sh exits on failures only, so a skip on the behaviour under test would read as
# green while leaving it unverified.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "ci-required" "mktemp not available"
  ts_report
  exit 0
fi

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# wf <mode> — reads the workflow with a run-block-aware state machine. Modes:
#   jobs   list every job name under the top-level `jobs:` key, one per line
#   job    the named job's block, verbatim (header line excluded)
#   body   the named job's `run: |` block(s), dedented to column 0 — the text bash actually runs
#   count  how many `run: |` blocks the named job has
# Pure awk on purpose: check-skills.sh/check-standards.sh already establish that the kit's gates
# parse their own YAML without a jq/yq/ruby/python dependency, and a test that needs an extra
# interpreter is a test that silently skips on the machine that lacks it.
wf() {
  awk -v job="$JOB" -v mode="$1" '
    function indent_of(s,   n) { n = match(s, /[^ ]/); if (n == 0) return -1; return n - 1 }
    BEGIN { in_jobs = 0; in_job = 0; in_run = 0; runs = 0; body_indent = -1; pending = 0 }
    {
      line = $0
      ind = indent_of(line)
      blank = (line ~ /^[ \t]*$/)

      # Run-block bodies are arbitrary text, so they are consumed before any structural test.
      if (in_run) {
        if (blank) { pending++; next }
        if (body_indent < 0) {
          if (ind > run_indent) { body_indent = ind } else { in_run = 0 }
        }
        if (in_run && ind >= body_indent) {
          while (pending > 0) { if (mode == "body" || mode == "job") print ""; pending-- }
          if (mode == "body") print substr(line, body_indent + 1)
          if (mode == "job") print line
          next
        }
        pending = 0
        in_run = 0
      }

      if (blank) next

      # A non-comment line at column 0 opens a new top-level key: only `jobs:` holds job names,
      # so `on:`/`permissions:`/`concurrency:` children at indent 2 are never read as jobs.
      if (ind == 0) {
        if (line !~ /^#/) { in_jobs = (line ~ /^jobs:[ \t]*$/); in_job = 0 }
        next
      }

      if (in_jobs && ind == 2 && line ~ /^  [A-Za-z0-9_.-]+:[ \t]*$/) {
        name = line
        sub(/^  /, "", name)
        sub(/:[ \t]*$/, "", name)
        if (mode == "jobs") print name
        in_job = (name == job)
        next
      }

      if (in_job && line ~ /^ +run:[ \t]*\|[ \t]*$/) {
        run_indent = ind
        body_indent = -1
        in_run = 1
        runs++
        if (mode == "job") print line
        next
      }

      if (in_job && mode == "job") print line
    }
    END { if (mode == "count") print runs }
  ' "$WORKFLOW"
}

# in_list <needle> <space-separated haystack> — echoes present/absent. A function rather than an
# inline `case` inside "$( ... )" because bash 3.2 mis-parses the pattern-terminating ')' there and
# produces an assertion that can never fail.
in_list() {
  local needle="$1" list="$2" item
  for item in $list; do
    if [ "$item" = "$needle" ]; then
      echo present
      return 0
    fi
  done
  echo absent
}

file_state() { if [ -f "$1" ]; then echo present; else echo absent; fi; }

# --- preconditions: nothing below means anything if these fail ----------------------------------

assert_eq "the kit's CI workflow is on disk" "present" "$(file_state "$WORKFLOW")"

JOB_NAMES=""
if [ -f "$WORKFLOW" ]; then JOB_NAMES="$(wf jobs)"; fi
assert_eq "a job named '$JOB' exists in it (a rename must fail here, not silently pass)" \
  "present" "$(in_list "$JOB" "$JOB_NAMES")"

JOB_BLOCK=""
if [ -f "$WORKFLOW" ]; then JOB_BLOCK="$(wf job)"; fi
RUN_COUNT="0"
if [ -f "$WORKFLOW" ]; then RUN_COUNT="$(wf count)"; fi
assert_eq "$JOB has exactly one run: block (the one this file drives)" "1" "$RUN_COUNT"

BODY=""
if [ -f "$WORKFLOW" ]; then BODY="$(wf body)"; fi
BODY_LINES="0"
if [ -n "$BODY" ]; then BODY_LINES="$(printf '%s\n' "$BODY" | grep -c '' || true)"; fi
assert_eq "the extracted run: block is non-empty" "yes" "$(if [ "$BODY_LINES" -gt 1 ]; then echo yes; else echo no; fi)"
assert_contains "the run: block reads RESULTS" "RESULTS" "$BODY"
assert_contains "the run: block reads EXPECTED" "EXPECTED" "$BODY"

# Materialise the extracted body exactly as GitHub would: a file invoked with `bash -e {0}`.
WORK="$(mktemp -d 2>/dev/null || true)"
BODY_FILE=""
if [ -n "$WORK" ] && [ -d "$WORK" ]; then
  BODY_FILE="$WORK/ci-required-run.sh"
  printf '%s\n' "$BODY" >"$BODY_FILE"
fi
assert_eq "the run: block was written out for execution" "yes" \
  "$(if [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] && [ "$BODY_LINES" -gt 1 ]; then echo yes; else echo no; fi)"

# --- the expression layer the shell body depends on ----------------------------------------------

# The body splits RESULTS on commas, so the join separator is load-bearing: change it and every
# result arrives as one unsplittable string that is never equal to "success".
assert_contains "RESULTS is the comma-join of every needs result" \
  "join(needs.*.result, ',')" "$JOB_BLOCK"
# `always()` is what makes the job run at all when a dependency failed, was cancelled or skipped —
# without it the aggregator is itself skipped, and a skipped required check reports success.
assert_contains "the job runs on always(), so a failed dependency cannot skip the gate" \
  "if: always()" "$JOB_BLOCK"

# --- the nine result shapes, driven through the workflow's own shell ------------------------------

CASE_OUT=""
CASE_RC=0
run_case() {
  local results="$1" expected="$2"
  CASE_RC=0
  CASE_OUT=""
  if [ -z "$BODY_FILE" ] || [ ! -s "$BODY_FILE" ]; then
    CASE_RC=126
    CASE_OUT="RUN BLOCK MISSING: $JOB in $WORKFLOW"
    return 0
  fi
  # Command substitution, not a pipeline: the status captured is the script's, not a downstream
  # tool's. GitHub runs `run:` blocks as `bash -e {0}`, so -e is part of the contract under test.
  CASE_OUT="$(RESULTS="$results" EXPECTED="$expected" bash -e "$BODY_FILE" 2>&1)" || CASE_RC=$?
}

rc() { printf 'rc=%s' "$CASE_RC"; }

run_case "success,success,success,success" 4
assert_eq "all four gates green: exits 0" "rc=0" "$(rc)"
assert_contains "all four green: says how many it actually counted" "all 4 required gates passed" "$CASE_OUT"

run_case "success,failure,success,success" 4
assert_eq "one gate failed: exits non-zero" "rc=1" "$(rc)"
assert_contains "one failure: names the offending result" "reported 'failure'" "$CASE_OUT"

# A bare `needs:` list does not fail the dependent job on a cancelled dependency.
run_case "success,success,cancelled,success" 4
assert_eq "one gate cancelled: exits non-zero" "rc=1" "$(rc)"
assert_contains "one cancelled: names the offending result" "reported 'cancelled'" "$CASE_OUT"

# Nor on a skipped one — and a skipped required check reports "success" to branch protection, so
# this row is the whole reason the job inspects results instead of relying on `needs:`.
run_case "success,skipped,success,success" 4
assert_eq "one gate skipped: exits non-zero" "rc=1" "$(rc)"
assert_contains "one skipped: names the offending result" "reported 'skipped'" "$CASE_OUT"

run_case "skipped,skipped,skipped,skipped" 4
assert_eq "every gate skipped (e.g. a bad path filter): exits non-zero" "rc=1" "$(rc)"
assert_contains "all skipped: names the offending result" "reported 'skipped'" "$CASE_OUT"

# The vacuous pass. An empty list makes the for-loop body run zero times, so only the count check
# can catch it — this row fails the moment that check is removed.
run_case "" 4
assert_eq "no results at all: exits non-zero rather than passing vacuously" "rc=1" "$(rc)"
assert_contains "empty results: reports the count, not a per-result verdict" "expected 4 gate results, got 0" "$CASE_OUT"

run_case "success,success,success" 4
assert_eq "a job dropped from needs: exits non-zero even though all results are success" "rc=1" "$(rc)"
assert_contains "dropped job: says the count is short" "expected 4 gate results, got 3" "$CASE_OUT"

run_case "success,success,success,success,success" 4
assert_eq "a job added but EXPECTED left stale: exits non-zero" "rc=1" "$(rc)"
assert_contains "stale EXPECTED: says the count is long" "expected 4 gate results, got 5" "$CASE_OUT"

# `set -f` in the run block. Without it the unquoted $RESULTS expansion globs against the runner's
# working directory, so the loop iterates over filenames and the message names a file rather than
# the result. Asserting the literal '*' survives is what pins the noglob.
run_case "success,*,success,success" 4
assert_eq "a glob-looking result value: exits non-zero" "rc=1" "$(rc)"
assert_contains "glob-looking value is not expanded against the working directory" "reported '*'" "$CASE_OUT"

# --- the declared EXPECTED must match the real needs list ------------------------------------------

# The count guard above is only as good as the number it compares against. These rows pin EXPECTED
# to the workflow's own `needs:` list, and that list to the workflow's own job list — so adding a
# job without wiring it into the aggregator fails here instead of quietly leaving it unrequired.
NEEDS_RAW="$(printf '%s\n' "$JOB_BLOCK" | grep -m1 '^ *needs:' || true)"
NEEDS_ITEMS="$(printf '%s\n' "$NEEDS_RAW" | sed -e 's/^ *needs: *\[//' -e 's/\] *$//' -e 's/,/ /g')"
EXPECTED_RAW="$(printf '%s\n' "$JOB_BLOCK" | grep -m1 'EXPECTED:' || true)"
EXPECTED_VAL="$(printf '%s\n' "$EXPECTED_RAW" | sed -e 's/.*EXPECTED:[ ]*//' -e 's/[^0-9].*$//')"

needs_count=0
for _n in $NEEDS_ITEMS; do needs_count=$((needs_count + 1)); done
assert_eq "the aggregator declares a non-empty needs: list" "yes" \
  "$(if [ "$needs_count" -gt 0 ]; then echo yes; else echo no; fi)"
assert_eq "EXPECTED equals the number of jobs in needs:" "$needs_count" "${EXPECTED_VAL:-<unset>}"

# Every job in the workflow except the aggregator itself must be in needs:, or it is not gated.
ungated=""
for _j in $JOB_NAMES; do
  if [ "$_j" != "$JOB" ] && [ "$(in_list "$_j" "$NEEDS_ITEMS")" = "absent" ]; then
    ungated="$ungated $_j"
  fi
done
assert_eq "every other job in the workflow is in the aggregator's needs:" "" "$ungated"

# ...and nothing in needs: is a job that does not exist (a typo there is accepted by YAML but makes
# the workflow invalid at dispatch time, long after review).
phantom=""
for _n in $NEEDS_ITEMS; do
  if [ "$(in_list "$_n" "$JOB_NAMES")" = "absent" ]; then phantom="$phantom $_n"; fi
done
assert_eq "every job named in needs: really exists in the workflow" "" "$phantom"

ts_report
