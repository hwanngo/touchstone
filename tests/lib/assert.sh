#!/usr/bin/env bash
# Assertion primitives for the touchstone test suite.
# Sourced by tests/**/*.test.sh — never executed directly.
# Counters live in the sourcing shell so a test file's final ts_report is accurate.

TS_PASS=0
TS_FAIL=0
TS_SKIP=0

_ts_ok() {
  TS_PASS=$((TS_PASS + 1))
  printf '  ok   %s\n' "$1"
}

_ts_bad() {
  TS_FAIL=$((TS_FAIL + 1))
  printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"
}

# ts_skip <label> <reason> — for cases whose fixtures are absent (hard rule 4).
ts_skip() {
  TS_SKIP=$((TS_SKIP + 1))
  printf '  skip %s (%s)\n' "$1" "$2"
}

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then _ts_ok "$1"; else _ts_bad "$1" "$2" "$3"; fi
}

# assert_contains <label> <needle> <haystack>
assert_contains() {
  case "$3" in
  *"$2"*) _ts_ok "$1" ;;
  *) _ts_bad "$1" "contains '$2'" "$3" ;;
  esac
}

# ts_report — MUST be the last line of every test file. The runner parses this.
ts_report() {
  printf 'TS_TALLY %d %d %d\n' "$TS_PASS" "$TS_FAIL" "$TS_SKIP"
}
