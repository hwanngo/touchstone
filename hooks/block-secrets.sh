#!/usr/bin/env bash
# PreToolUse(Write|Edit|MultiEdit) guard: block writing real secrets. Fail-open; gitleaks is the backstop.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
# gather text from Write (.content), Edit (.new_string) AND MultiEdit (.edits[].new_string) — the
# last shape was previously ignored, letting a secret through on a matcher the hook claims to cover
content="$(printf '%s' "$input" | jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits[]?.new_string)] | map(select(. != null)) | join("\n")')"

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

base="$(basename "$path" 2>/dev/null || echo "")"
case "$base" in
.env.example | .env.sample | .env.template) : ;; # templates are fine
.env | .env.*)
  deny "touchstone: don't write a real .env — commit only *.example templates (standards/practices/security.md)."
  ;;
esac

if printf '%s' "$content" | grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
  deny "touchstone: that looks like a private key — never write secrets into the repo (standards/practices/security.md)."
fi

exit 0
