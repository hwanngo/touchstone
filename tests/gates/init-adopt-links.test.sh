#!/usr/bin/env bash
# Gate: AGENTS.md must survive adoption. The kit ships ONE AGENTS.md whose standards/ paths are
# root-relative — correct in the kit, where standards/ is at the root, and wrong in an adopter,
# where the kit is vendored at .touchstone/. scripts/init.sh rewrites those paths at install time.
#
# What the audit actually found (the earlier claim that "all the links are dead in adopters" was
# stale — the link TARGETS were already rewritten): the rewrite was INCOMPLETE and UNGATED.
#   * The domain routing table is written as code spans (`standards/languages/` …) and was not
#     rewritten at all. That table is how an agent decides which standard to open, so it is the
#     functional core of the file, and in every adopter it named paths that do not exist.
#   * Link TEXTS still read standards/… while their targets read .touchstone/standards/… .
#   * The session-hook banner told every adopter "the full standards live in standards/".
#   * Nothing anywhere exercised adoption, so the sed could silently narrow or vanish.
#
# This test runs the REAL init.sh into a temp adopter and asserts against WHAT IT PRODUCED, never
# against the template. Two rounds of this campaign were lost to measuring the source instead of
# the installed artifact.
#
# FIXTURE MODEL. The fixture is the kit's own tracked working-tree content, vendored into
# $tmp/target/.touchstone. There is nothing to delete under tests/fixtures/, but the same
# "fixture vanished → gate scanned nothing → non-zero for the wrong reason" hazard exists, so:
#   1. assert_present rows state, as their own assertions, that the build produced the files the
#      later verdicts read;
#   2. the rewrite-completeness row is paired with a row proving the SOURCE still contains work for
#      the rewrite to do — otherwise "0 unrewritten paths" would also pass on an empty AGENTS.md;
#   3. the link-existence row asserts a minimum link count, so losing the links cannot read as
#      "every link resolves".
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
ROOT="$(cd -P "$DIR/../.." && pwd)"

# Hard rule 4: self-skip only for genuine tool absence. jq is needed by the hook whose banner is
# asserted below; git/tar build the adopter. Nothing init.sh does is ever skipped.
for tool in mktemp git tar jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    ts_skip "init-adopt-links" "$tool not available"
    ts_report
    exit 0
  fi
done

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "init-adopt-links" "mktemp -d failed"
  ts_report
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

T="$TMP/target"
mkdir -p "$T/.touchstone"
# Working-tree content of the tracked files, not `git archive HEAD`: an uncommitted change to
# init.sh must be what these rows exercise, or the suite verifies yesterday's script.
(cd "$ROOT" && git ls-files -z | tar -cf - --null -T -) | (cd "$T/.touchstone" && tar -xf -)
git init -q "$T" >/dev/null 2>&1

# assert_present <label> <base> <file>... — precondition row naming every file a later verdict
# reads, so a build that produced nothing fails here rather than looking like a real verdict.
assert_present() {
  local label="$1" base="$2" state="complete" missing="" f
  shift 2
  for f in "$@"; do
    [ -e "$base/$f" ] || missing="$missing $f"
  done
  [ -n "$missing" ] && state="missing:$missing"
  assert_eq "$label" "complete" "$state"
}

assert_present "vendored kit is complete on disk" "$T/.touchstone" \
  "AGENTS.md" "scripts/init.sh" "scripts/check-sync.sh" "hooks/touchstone-context.sh" \
  "standards/README.md" "standards/self-audit.md" "standards/languages" "standards/frameworks" \
  "standards/platform" "standards/practices" "standards/design"

# --- the source must contain work for the rewrite to do ------------------------------------------
# Without this row, "0 unrewritten standards/ paths in the adopter copy" would also pass against an
# AGENTS.md that had lost its routing table entirely.
SRC_PAT='(\]\(|\[|`)standards/'
src_hits="$(grep -cE "$SRC_PAT" "$ROOT/AGENTS.md" || true)"
assert_eq "kit AGENTS.md still carries root-relative standards/ paths (the rewrite has work to do)" \
  "yes" "$(if [ "${src_hits:-0}" -ge 5 ]; then echo yes; else echo "no ($src_hits)"; fi)"
# Specifically the routing table's code spans — the context the old sed missed.
# shellcheck disable=SC2016 # the backticks ARE the literal markdown code-span delimiters under test
assert_contains "kit AGENTS.md routes domains via code spans" '`standards/languages/`' "$(cat "$ROOT/AGENTS.md")"

# --- run the real init.sh ------------------------------------------------------------------------
INIT_RC=0
INIT_OUT="$(bash "$T/.touchstone/scripts/init.sh" --target "$T" --with-hooks 2>&1)" || INIT_RC=$?
assert_eq "init.sh --target <adopter> --with-hooks exits 0" "0" "$INIT_RC"
assert_contains "init.sh says it rewrote all three contexts, not just the link targets" \
  "standards link targets, texts and code spans" "$INIT_OUT"
assert_present "adoption produced the files under test" "$T" \
  "AGENTS.md" ".touchstone.toml" ".claude/hooks/touchstone-context.sh"

# --- 1. rewrite completeness: no root-relative standards/ survives in ANY of the three contexts ---
adopt_hits="$(grep -cE "$SRC_PAT" "$T/AGENTS.md" || true)"
assert_eq "adopted AGENTS.md has no unrewritten standards/ path (targets, texts or code spans)" \
  "0" "$(printf '%s' "${adopt_hits:-0}" | tr -d ' ')"
# shellcheck disable=SC2016 # the backticks ARE the literal markdown code-span delimiters under test
assert_contains "adopted AGENTS.md routes domains at the vendored kit" \
  '`.touchstone/standards/languages/`' "$(cat "$T/AGENTS.md")"
assert_contains "adopted AGENTS.md link TEXT matches its target" \
  '[.touchstone/standards/self-audit.md]' "$(cat "$T/AGENTS.md")"

# --- 2. every rewritten inline link target actually exists in the adopter ------------------------
missing_targets=""
link_count=0
while IFS= read -r target; do
  [ -z "$target" ] && continue
  case "$target" in
  http://* | https://* | mailto:*) continue ;;
  esac
  link_count=$((link_count + 1))
  [ -e "$T/$target" ] || missing_targets="$missing_targets $target"
done <<EOF
$(grep -oE '\]\([^)#]+' "$T/AGENTS.md" | sed 's/^](//' || true)
EOF
assert_eq "every adopted AGENTS.md link target resolves inside the adopter" "" "$missing_targets"
# A vacuity guard: an AGENTS.md that lost its links would satisfy the row above trivially.
assert_eq "…and there were really links to resolve" "yes" \
  "$(if [ "$link_count" -ge 5 ]; then echo yes; else echo "no ($link_count)"; fi)"

# --- 3. the SOURCE is untouched — the rewrite is install-time, not a pre-baked second template ----
assert_contains "kit AGENTS.md still links root-relative (single source, rewritten on install)" \
  '](standards/' "$(cat "$ROOT/AGENTS.md")"

# --- 4. a fresh adoption is born green under the drift gate ---------------------------------------
SYNC_RC=0
SYNC_OUT="$(bash "$T/.touchstone/scripts/check-sync.sh" --target "$T" 2>&1)" || SYNC_RC=$?
assert_eq "check-sync exits 0 immediately after a fresh adoption" "0" "$SYNC_RC"
assert_contains "check-sync really compared managed files in the adopter" "managed file(s)" "$SYNC_OUT"

# --- 5. an AGENTS.md hand-copied around init.sh is caught -----------------------------------------
cp "$T/AGENTS.md" "$TMP/adopted-AGENTS.md" # restored below; row 6 reads the ADOPTED copy
cp "$ROOT/AGENTS.md" "$T/AGENTS.md"
STALE_RC=0
STALE_OUT="$(bash "$T/.touchstone/scripts/check-sync.sh" --target "$T" 2>&1)" || STALE_RC=$?
assert_eq "un-rewritten AGENTS.md in an adopter: check-sync exits 1" "1" "$STALE_RC"
assert_contains "un-rewritten AGENTS.md: check-sync says what is wrong" \
  "AGENTS.md: links target standards/" "$STALE_OUT"

cp "$TMP/adopted-AGENTS.md" "$T/AGENTS.md"

# --- 6. the session-hook banner is layout-aware at runtime ----------------------------------------
# One byte-identical hook file serves both layouts (it is managed by check-sync, so a second
# adopter-flavoured copy would drift). Assert the BANNER sentence specifically: asserting only that
# ".touchstone/standards/" appears anywhere would pass on the rules text the hook quotes.
hook_out_adopter="$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$T" |
  bash "$T/.claude/hooks/touchstone-context.sh" 2>&1)"
assert_contains "hook banner in an adopter points at the vendored standards" \
  "the full standards live in .touchstone/standards/." "$hook_out_adopter"

hook_out_kit="$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$ROOT" |
  bash "$ROOT/hooks/touchstone-context.sh" 2>&1)"
assert_contains "hook banner in the kit still points at the root standards" \
  "the full standards live in standards/." "$hook_out_kit"

ts_report
