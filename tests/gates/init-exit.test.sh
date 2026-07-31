#!/usr/bin/env bash
# Gate: scripts/init.sh must exit 0 on every combination of --dry-run / --with-hooks. The
# audit's original finding — the advertised adoption path reported failure on success — was a
# bare `[ "$WITH_HOOKS" -eq 1 ] && echo …` as the script's final statement: when the test was
# false, its failing status became init.sh's own exit code. bootstrap.sh runs init.sh last under
# set -e, so a plain adoption run failed even though every file it wrote was correct.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
INIT="$KIT/scripts/init.sh"

# Hard rule 4: self-skip when a fixture this test needs is absent, rather than failing.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "init-exit" "mktemp not available"
  ts_report
  exit 0
fi

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "init-exit" "mktemp -d failed"
  ts_report
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

# Each invocation gets its own pre-created, empty target dir: isolated (no cross-invocation
# state bleed) and pre-existing (matching every real caller — bootstrap.sh vendors the submodule
# into an existing checkout, and adopters run init.sh from inside their own repo root, never
# against a directory that doesn't exist yet). This keeps the assertions below focused on the
# one exit-code defect under test, not on whether --target's directory happens to pre-exist.
mkdir -p "$TMP/default" "$TMP/dry" "$TMP/hooks" "$TMP/hooks-dry"

# NOT skips. init.sh's exit code on each of these four invocations IS the behaviour under test —
# the audit's original finding. Skipping here would leave a broken adoption path invisible, since
# tests/run.sh exits on failures only (a skip reads as green).
default_rc=0
bash "$INIT" --target "$TMP/default" >/dev/null 2>&1 || default_rc=$?
assert_eq "init.sh --target <tmp> exits 0" "0" "$default_rc"

dry_rc=0
bash "$INIT" --target "$TMP/dry" --dry-run >/dev/null 2>&1 || dry_rc=$?
assert_eq "init.sh --target <tmp> --dry-run exits 0" "0" "$dry_rc"

hooks_rc=0
bash "$INIT" --target "$TMP/hooks" --with-hooks >/dev/null 2>&1 || hooks_rc=$?
assert_eq "init.sh --target <tmp> --with-hooks exits 0" "0" "$hooks_rc"

hooks_dry_rc=0
bash "$INIT" --target "$TMP/hooks-dry" --with-hooks --dry-run >/dev/null 2>&1 || hooks_dry_rc=$?
assert_eq "init.sh --target <tmp> --with-hooks --dry-run exits 0" "0" "$hooks_dry_rc"

dry_entries="$(find "$TMP/dry" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "--dry-run writes nothing under its target" "0" "$dry_entries"

ts_report
