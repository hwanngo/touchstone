#!/usr/bin/env bash
# touchstone test runner. Usage: tests/run.sh [one.test.sh ...]
# Reports "N passed, M failed, K skipped" — never a bare "ok", because a silent
# pass count is exactly how the existing gates got away with vacuous success.
# Omit -e: the runner must survive crashing tests and aggregate all results,
# then exit 1 only after counting. -e would abort mid-run and lose totals.
set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

command -v jq >/dev/null 2>&1 || {
  echo "tests: jq is required (the hooks depend on it too)" >&2
  exit 1
}

files=""
if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$(find tests -name '*.test.sh' | LC_ALL=C sort)"
fi

if [ -z "$files" ]; then
  echo "tests: no *.test.sh files found under tests/" >&2
  exit 1
fi

total_pass=0
total_fail=0
total_skip=0

for f in $files; do
  printf '%s\n' "$f"
  out="$(bash "$f" 2>&1)"
  printf '%s\n' "$out" | grep -v '^TS_TALLY ' || true
  tally="$(printf '%s\n' "$out" | grep '^TS_TALLY ' | tail -1)"
  if [ -z "$tally" ]; then
    printf '  FAIL %s emitted no tally (did it call ts_report?)\n' "$f"
    tally="TS_TALLY 0 1 0"
  fi
  # shellcheck disable=SC2086 # fixed 4-field tally line
  set -- $tally
  total_pass=$((total_pass + $2))
  total_fail=$((total_fail + $3))
  total_skip=$((total_skip + $4))
done

printf '\n%d passed, %d failed, %d skipped\n' "$total_pass" "$total_fail" "$total_skip"
[ "$total_fail" -eq 0 ]
