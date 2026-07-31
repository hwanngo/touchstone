#!/usr/bin/env bash
# PreToolUse(Write|Edit|MultiEdit|NotebookEdit) guard: block writing real secrets.
# Fail-open; gitleaks is the backstop.
set -uo pipefail

HOOK_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # lib/secret-paths.sh is resolved relative to HOOK_DIR at runtime
if ! . "$HOOK_DIR/lib/secret-paths.sh" 2>/dev/null; then
  printf '%s\n' '{"systemMessage":"touchstone: hooks/lib/secret-paths.sh missing — secret-path checks are unavailable, the Write guard is OFF"}'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"systemMessage":"touchstone: jq not installed — the Write guard is OFF"}'
  exit 0
fi

# STD — where the standards docs live, resolved at runtime. A deny message's job is to route the
# agent to the rule it just broke, and every one of them hard-coded `standards/…` — a path that
# exists only in the KIT. These hooks are byte-copied into adopting repos (scripts/check-sync.sh
# manages the pairs), and there the docs live in the vendored submodule with no root `standards/`,
# so every deny message pointed into thin air in the one environment the hooks are installed for.
# Resolved from the hook's own location, not $PWD, so running an agent from a subdirectory cannot
# flip it. Same runtime branch as hooks/touchstone-context.sh, for the same reason.
STD="standards"
_ts_repo="$(git -C "$HOOK_DIR" rev-parse --show-toplevel 2>/dev/null)" || _ts_repo=""
[ -n "$_ts_repo" ] || _ts_repo="$HOOK_DIR/../.."
if [ ! -d "$_ts_repo/standards" ] && [ -d "$_ts_repo/.touchstone/standards" ]; then
  STD=".touchstone/standards"
fi

input="$(cat)"
path="$(printf '%s' "$input" |
  jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
# Gather text from Write (.content), Edit (.new_string), MultiEdit (.edits[].new_string) and
# NotebookEdit (.new_source) — each is a shape the matcher claims to cover.
content="$(printf '%s' "$input" | jq -r '
  [.tool_input.content?, .tool_input.new_string?, .tool_input.new_source?,
   (.tool_input.edits[]?.new_string)]
  | map(select(. != null) | tostring) | join("\n")' 2>/dev/null)"

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

if [ -n "$path" ] && is_secret_path "$path"; then
  deny "touchstone: don't write a real .env/secret file — commit only *.example templates ($STD/practices/security.md)."
fi

if printf '%s' "$content" | grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----'; then
  deny "touchstone: that looks like a private key — never write secrets into the repo ($STD/practices/security.md)."
fi

exit 0
