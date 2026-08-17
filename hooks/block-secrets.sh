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
# The SAME fields joined with nothing at all. A single MultiEdit whose edits are
# `-----BEGIN RSA` and ` PRIVATE KEY-----…` reconstructs a full header on disk while no one field
# contains it; joined with "\n" the two halves never share a line, so the matcher below could not
# see it. Joined with "" they do. This is a second view of the same bytes, never a replacement:
# the newline join is what keeps two unrelated edits from being read as one line.
glued="$(printf '%s' "$input" | jq -r '
  [.tool_input.content?, .tool_input.new_string?, .tool_input.new_source?,
   (.tool_input.edits[]?.new_string)]
  | map(select(. != null) | tostring) | join("")' 2>/dev/null)"

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

if [ -n "$path" ] && is_secret_path "$path"; then
  deny "touchstone: don't write a real .env/secret file — commit only *.example templates ($STD/practices/security.md)."
fi

# is_fixture_path <path> — a throwaway test key under a fixtures/testdata DIRECTORY. Crypto, TLS
# and SSH suites legitimately commit test keys, and denying those is the same class of defect as
# denying `.env.example`: it blocks the work the repo exists to do and teaches people to switch
# the guard off. Deliberately narrow — a full path COMPONENT, never a substring, so
# `src/fixtures_helper.go` is not exempt. This does NOT relax the .env-family PATH check above;
# a `tests/fixtures/.env` is still a real secret file.
is_fixture_path() {
  case "/$1/" in
  */fixtures/* | */testdata/* | */test-fixtures/* | */__fixtures__/*) return 0 ;;
  esac
  return 1
}

# The private-key matcher, widened in three directions and anchored in one. (Written as a built-up
# pattern rather than one literal so this file does not itself contain a key header — the same
# reason tests/hooks/block-secrets.test.sh assembles its fixtures from fragments.)
#
#   * Four OR five dashes, with or without a space around the label. The standard RFC 4716 /
#     ssh.com header spells it with four dashes and spaces, and matched nothing before.
#   * Digits in the label class, for the same reason (an `SSH2` label).
#   * END as well as BEGIN. Only the BEGIN header was ever examined, so a whole key with a
#     mangled BEGIN and an intact END footer walked straight through.
#
# And anchored to the start of a line (leading blanks allowed, because an embedded key inside
# YAML or JSON is indented): a real key's header BEGINS a line. Security DOCUMENTATION that
# quotes a header mid-sentence, inside backticks, used to deny — which blocked writing the very
# docs this kit ships.
PEM_LABEL='[A-Z0-9 ]*PRIVATE KEY( BLOCK)?'
PEM_RE="^[[:blank:]]*-{4,5} ?(BEGIN|END) ${PEM_LABEL} ?-{4,5}"
# A PuTTY .ppk private key carries no PEM header of any kind; this line is its file magic.
PPK_RE='^[[:blank:]]*PuTTY-User-Key-File-[0-9]+:'

# BOTH views are matched against BOTH patterns. The `glued` view was tested against PEM_RE only,
# so a PuTTY magic line split across two MultiEdit edits (`PuTTY-User-Key-File-` / `2: ssh-rsa`)
# reconstructed a real .ppk header on disk and was not caught — even though reassembly across edits
# is the entire reason `glued` exists. One missing alternative, in the one place the second view was
# supposed to cover.
if ! is_fixture_path "$path"; then
  if printf '%s' "$content" | grep -qE -- "$PEM_RE" ||
    printf '%s' "$glued" | grep -qE -- "$PEM_RE" ||
    printf '%s' "$content" | grep -qE -- "$PPK_RE" ||
    printf '%s' "$glued" | grep -qE -- "$PPK_RE"; then
    deny "touchstone: that looks like a private key — never write secrets into the repo ($STD/practices/security.md)."
  fi
fi

exit 0
