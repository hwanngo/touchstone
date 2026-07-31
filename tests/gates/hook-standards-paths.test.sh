#!/usr/bin/env bash
# Gate: a hook's deny message must cite a standards path that resolves WHERE THE HOOK IS INSTALLED.
#
# The defect: every deny message in guard-bash.sh and block-secrets.sh ended with a literal
# `(standards/practices/…​.md)`. That path is real in the kit and nowhere else. These hooks are
# byte-copied into adopting repos (scripts/check-sync.sh manages the pairs), and an adopter has no
# root `standards/` — the docs live in the vendored `.touchstone/` submodule. So the one line whose
# entire job is to route the agent to the rule it just broke pointed into thin air, in the only
# environment the hooks are ever actually installed into.
#
# The fix resolves the prefix at runtime from the hook's OWN location, and this file asserts both
# layouts plus the difference between them. Asserting only the adopter layout would pass just as
# well against a hook that had hard-coded `.touchstone/standards/` and broken the kit instead.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  ts_skip "hook-standards-paths" "jq not available"
  ts_report
  exit 0
fi
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "hook-standards-paths" "mktemp not available"
  ts_report
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  ts_skip "hook-standards-paths" "git not available"
  ts_report
  exit 0
fi

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "hook-standards-paths" "mktemp -d failed"
  ts_report
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

# install_hooks <hookdir> — copy both PreToolUse guards plus the lib they source at runtime. The lib
# is not optional: without it each hook announces it is degraded and exits before any deny message,
# so every assertion below would be checking the wrong output entirely.
install_hooks() {
  mkdir -p "$1/lib"
  cp "$KIT/hooks/guard-bash.sh" "$KIT/hooks/block-secrets.sh" "$1/"
  cp "$KIT/hooks/lib/secret-paths.sh" "$1/lib/"
}

# --- layout A: the kit itself — standards/ at the repo root, hooks/ beside it --------------------
KITLIKE="$TMP/kitlike"
mkdir -p "$KITLIKE/standards/practices"
touch "$KITLIKE/standards/practices/security.md" "$KITLIKE/standards/practices/collaboration.md"
install_hooks "$KITLIKE/hooks"
git init -q "$KITLIKE"

# --- layout B: an adopter — no root standards/, kit vendored at .touchstone/, hooks at .claude/ ---
ADOPTER="$TMP/adopterlike"
mkdir -p "$ADOPTER/.touchstone/standards/practices"
touch "$ADOPTER/.touchstone/standards/practices/security.md" \
  "$ADOPTER/.touchstone/standards/practices/collaboration.md"
install_hooks "$ADOPTER/.claude/hooks"
git init -q "$ADOPTER"

# deny_reason <hookdir> <hook> <json> — run a guard and extract permissionDecisionReason.
deny_reason() {
  printf '%s' "$3" | bash "$1/$2" 2>/dev/null |
    jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null
}

BASH_JSON='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m x"}}'
WRITE_JSON='{"tool_name":"Write","tool_input":{"file_path":".env","content":"A=1"}}'

kit_bash="$(deny_reason "$KITLIKE/hooks" guard-bash.sh "$BASH_JSON")"
kit_write="$(deny_reason "$KITLIKE/hooks" block-secrets.sh "$WRITE_JSON")"
ado_bash="$(deny_reason "$ADOPTER/.claude/hooks" guard-bash.sh "$BASH_JSON")"
ado_write="$(deny_reason "$ADOPTER/.claude/hooks" block-secrets.sh "$WRITE_JSON")"

# Control: all four must actually be denials. A hook that failed to deny would yield an empty string,
# and every "does not contain X" assertion below would then pass on nothing.
assert_contains "control: kit layout guard-bash still denies --no-verify" "no-verify" "$kit_bash"
assert_contains "control: kit layout block-secrets still denies a .env write" ".env" "$kit_write"
assert_contains "control: adopter layout guard-bash still denies --no-verify" "no-verify" "$ado_bash"
assert_contains "control: adopter layout block-secrets still denies a .env write" ".env" "$ado_write"

# --- the assertions ------------------------------------------------------------------------------
assert_contains "kit layout: guard-bash cites standards/ at the repo root" \
  "(standards/practices/collaboration.md)" "$kit_bash"
assert_contains "kit layout: block-secrets cites standards/ at the repo root" \
  "(standards/practices/security.md)" "$kit_write"

assert_contains "adopter layout: guard-bash cites the vendored .touchstone/standards/" \
  "(.touchstone/standards/practices/collaboration.md)" "$ado_bash"
assert_contains "adopter layout: block-secrets cites the vendored .touchstone/standards/" \
  "(.touchstone/standards/practices/security.md)" "$ado_write"

# The cited path must RESOLVE from the repo root — the whole point of the exercise. Extracted from
# the message rather than reconstructed, so a message that cites something else fails here.
extract_path() {
  printf '%s\n' "$1" | LC_ALL=C awk 'match($0, /\([^()]*\.md\)/) { print substr($0, RSTART + 1, RLENGTH - 2) }'
}
ado_path="$(extract_path "$ado_bash")"
resolves="no"
[ -n "$ado_path" ] && [ -f "$ADOPTER/$ado_path" ] && resolves="yes"
assert_eq "the path an adopter is sent to actually exists in the adopter" "yes" "$resolves"

kit_path="$(extract_path "$kit_bash")"
kit_resolves="no"
[ -n "$kit_path" ] && [ -f "$KITLIKE/$kit_path" ] && kit_resolves="yes"
assert_eq "the path a kit developer is sent to actually exists in the kit" "yes" "$kit_resolves"

# The two layouts must differ. If they did not, the resolution would be a constant and both rows
# above would be satisfiable by a hard-coded prefix — the defect, merely relocated.
differ="no"
[ "$kit_path" != "$ado_path" ] && differ="yes"
assert_eq "positive control: the two layouts really do produce different paths" "yes" "$differ"

# --- no hard-coded root-relative citation survives in either hook --------------------------------
# Discovery rather than a hand-list: a deny message added tomorrow that hard-codes `standards/`
# reintroduces the defect for adopters, and this is what notices.
hardcoded=""
for h in guard-bash.sh block-secrets.sh; do
  if grep -n 'deny "' "$KIT/hooks/$h" | grep -q '(standards/'; then
    hardcoded="$hardcoded $h"
  fi
done
assert_eq "no deny message hard-codes a root-relative standards/ path" "" "$hardcoded"

ts_report
