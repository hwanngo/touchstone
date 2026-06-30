#!/usr/bin/env bash
# PreToolUse(Bash) guard: deny only narrow, unambiguous policy violations. Fail-open.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(cat | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# is short flag letter $1 a bona-fide short cluster (-n, -f, -nf, -vn)? Tokenize on whitespace and
# only accept a token that is a single dash + 1-3 letters, so a hyphenated word inside a commit
# message (e.g. "-standards", "-sync") is never mistaken for a flag — that was a real false-positive.
has_short() { printf '%s' "$cmd" | tr -s ' \t' '\n' | grep -E "^-[A-Za-z]{1,3}$" | grep -q "$1"; }

# 1) Never bypass git hooks — long --no-verify, or commit's short -n.
if printf '%s' "$cmd" | grep -qE 'git\b.*\b(commit|push)\b' &&
  { printf '%s' "$cmd" | grep -q -- '--no-verify' ||
    { printf '%s' "$cmd" | grep -qE 'git\b.*\bcommit\b' && has_short n; }; }; then
  deny "touchstone: don't bypass git hooks with --no-verify/-n — fix the failing gate instead (standards/practices/collaboration.md)."
fi

# 2) Force-push only with a lease — long --force or short -f, never without a lease.
if printf '%s' "$cmd" | grep -qE 'git\b.*\bpush\b' &&
  { printf '%s' "$cmd" | grep -q -- '--force' || has_short f; } &&
  ! printf '%s' "$cmd" | grep -q -- '--force-with-lease'; then
  deny "touchstone: use 'git push --force-with-lease', never a bare --force/-f (standards/practices/collaboration.md)."
fi

exit 0
