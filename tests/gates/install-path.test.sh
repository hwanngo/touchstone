#!/usr/bin/env bash
# Integration test: does the INSTALLED .claude/hooks/ tree — produced by the real
# scripts/init.sh --with-hooks, not the repo's hooks/ source tree — actually enforce the
# secret-path policy? Every other suite exercises hooks/ directly, so a packaging regression
# (e.g. init.sh's flat `hooks/*.sh` glob silently missing `hooks/lib/*.sh`) is invisible to
# them even though a real adopter gets a degraded install. This test would have caught it.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/hookcase.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
INIT="$KIT/scripts/init.sh"

# Hard rule 4: self-skip when a fixture this test needs is absent, rather than failing.
if ! command -v git >/dev/null 2>&1; then
  ts_skip "install-path" "git not available"
  ts_report
  exit 0
fi
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "install-path" "mktemp not available"
  ts_report
  exit 0
fi

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "install-path" "mktemp -d failed"
  ts_report
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

# NOT a skip. init.sh exiting non-zero is the audit's ORIGINAL finding, and tests/run.sh exits on
# failures only — a skip here would leave CI green with the whole adoption path broken, which is
# precisely the vacuous-pass class this suite exists to eliminate. The two guards above stay skips
# because they are genuine tool-absence conditions (a fixture this test needs is missing); this
# one is the behaviour under test.
init_rc=0
bash "$INIT" --target "$TMP" --with-hooks >/dev/null 2>&1 || init_rc=$?
assert_eq "scripts/init.sh --with-hooks exits 0" "0" "$init_rc"

HOOK_BLOCK="$TMP/.claude/hooks/block-secrets.sh"
HOOK_BASH="$TMP/.claude/hooks/guard-bash.sh"
LIB="$TMP/.claude/hooks/lib/secret-paths.sh"
SETTINGS="$TMP/.claude/settings.json"

# Also an assertion, not a skip, and for the same reason: a missing installed hook IS the
# packaging regression this file was written to catch.
hooks_present="missing"
[ -f "$HOOK_BLOCK" ] && [ -f "$HOOK_BASH" ] && hooks_present="present"
assert_eq "installed hooks present: block-secrets.sh and guard-bash.sh" "present" "$hooks_present"
if [ "$hooks_present" != "present" ]; then
  # Nothing below can run meaningfully without them; the failure is already recorded above.
  ts_report
  exit 0
fi

lib_present="missing"
[ -f "$LIB" ] && lib_present="present"
assert_eq "installed lib present: .claude/hooks/lib/secret-paths.sh" "present" "$lib_present"

assert_eq "installed Write .env denies" "deny" \
  "$(write_decision "$HOOK_BLOCK" "$TMP/.env")"
assert_eq "installed Write .envrc denies" "deny" \
  "$(write_decision "$HOOK_BLOCK" "$TMP/.envrc")"
assert_eq "installed Bash 'cat > .env' denies" "deny" \
  "$(hook_decision "$HOOK_BASH" "cat > .env")"
assert_eq "installed Write README.md allows" "allow" \
  "$(write_decision "$HOOK_BLOCK" "$TMP/README.md")"

# --- the installed settings file itself. Nothing in the repo verified templates/claude-settings.json
#     at all, and the pre-campaign failure mode was exactly a stale hook FILENAME in it: settings
#     that name a script the install does not contain, so the hook silently never runs and no gate
#     notices. ---
settings_valid="invalid-or-missing"
jq -e . "$SETTINGS" >/dev/null 2>&1 && settings_valid="valid"
assert_eq "installed .claude/settings.json parses as JSON" "valid" "$settings_valid"

if [ "$settings_valid" = "valid" ]; then
  # shellcheck disable=SC2016 # intentional: this is the LITERAL placeholder text Claude Code
  # expands at hook-run time, matched here as a string, never expanded by this shell
  PLACEHOLDER='${CLAUDE_PROJECT_DIR}'
  cmds="$(jq -r '.. | objects | select(has("command")) | .command' "$SETTINGS" 2>/dev/null)"
  missing=""
  named=0
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    # the template wraps each path in literal double quotes so a spaced project dir survives
    p="${c%\"}"
    p="${p#\"}"
    case "$p" in
    "$PLACEHOLDER"/*)
      named=$((named + 1))
      p="$TMP${p#"$PLACEHOLDER"}"
      [ -f "$p" ] || missing="$missing ${p#"$TMP/"}"
      [ -x "$p" ] || missing="$missing not-executable:${p#"$TMP/"}"
      ;;
    esac
  done <<EOF
$cmds
EOF
  assert_eq "every hook path settings.json names exists and is executable in the install" "" "$missing"
  # Without this, a settings file that named NO hook paths at all would satisfy the check above
  # vacuously — the empty-set pass this suite exists to eliminate.
  enough="no"
  [ "$named" -ge 6 ] && enough="yes"
  assert_eq "settings.json names at least 6 hook paths (guards the check above from passing vacuously)" "yes" "$enough"
fi

# --- the repo meta the kit requires of adopters must actually reach them -------------------------

# collaboration.md's repo-meta checklist requires PR *and* issue templates, and repo-meta.test.sh
# now enforces that on the kit itself. But init.sh placed CODEOWNERS, the PR template and
# SECURITY.md while never placing the three issue forms the kit ships, so every adopter silently
# got half the item. Asserted against the INSTALLED tree, not templates/ — testing the source
# instead of the installed artifact is the mistake that let the original install-path bug ship.
# The installed tree is $TMP (set at line 29 and used by every row above). An earlier draft of this
# block guarded on a $TARGET that does not exist in this file, so the whole loop silently skipped
# and the tally never moved — a vacuous test inside the suite built to abolish vacuous tests. The
# guard below fails loudly instead of skipping, which is what makes that undetectable case visible.
tmp_usable="no"
[ -n "${TMP:-}" ] && [ -d "${TMP:-}" ] && tmp_usable="yes"
assert_eq "installed tree is available for the repo-meta rows (guards them from skipping silently)" "yes" "$tmp_usable"
if [ "$tmp_usable" = "yes" ]; then
  for meta in .github/CODEOWNERS .github/PULL_REQUEST_TEMPLATE.md SECURITY.md \
    .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/feature_request.yml \
    .github/ISSUE_TEMPLATE/config.yml; do
    present="absent"
    [ -f "$TMP/$meta" ] && present="present"
    assert_eq "adopter receives $meta" "present" "$present"
  done
fi

ts_report
