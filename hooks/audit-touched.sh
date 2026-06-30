#!/usr/bin/env bash
# PostToolUse(Write|Edit|MultiEdit): when an agent edits a skills/*/SKILL.md or a
# standards/<domain>/*.md, run the matching touchstone auditor and surface any violations right away —
# the gap a commit-time gate can't cover, since an agent can write a malformed instruction file long
# before a commit. Warn-only, fail-open: a missing auditor, jq, or any error lets the action proceed.
# See hooks/README.md and scripts/check-{skills,standards}.sh.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

path="$(cat | jq -r '.tool_input.file_path // empty')"
[ -n "$path" ] && [ -f "$path" ] || exit 0

# resolve the repo root from the edited file; skip silently if it doesn't ship the auditors
root="$(git -C "$(dirname "$path")" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$root" ] || exit 0

warn=""
case "$path" in
*/skills/*/SKILL.md)
  [ -f "$root/scripts/check-skills.sh" ] || exit 0
  dir="$(basename "$(dirname "$path")")"
  warn="$(bash "$root/scripts/check-skills.sh" 2>&1 | grep "^FAIL: $dir:")" || true
  ;;
*/standards/*/*.md)
  case "$(basename "$path")" in README.md) exit 0 ;; esac
  [ -f "$root/scripts/check-standards.sh" ] || exit 0
  rel="${path#*/standards/}"
  warn="$(bash "$root/scripts/check-standards.sh" 2>&1 | grep "^FAIL: $rel:")" || true
  ;;
*) exit 0 ;;
esac

[ -n "$warn" ] || exit 0
jq -n --arg w "$warn" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ("touchstone audit — the instruction file you just edited has template/spec violations:\n" + $w + "\nFix them so the skill/standard stays conformant (scripts/check-skills.sh · scripts/check-standards.sh).")}}'
exit 0
