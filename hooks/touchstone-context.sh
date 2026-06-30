#!/usr/bin/env bash
# SessionStart + UserPromptSubmit hook: inject the touchstone hard rules into the agent's context
# (mirrors superpowers' SessionStart pattern). Fail-open: any problem → no output, exit 0.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // "SessionStart"')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -z "$cwd" ] && cwd="$PWD"

rules=""
# Prefer the "Hard rules" section of AGENTS.md; fall back to the touchstone meta-skill.
if [ -f "$cwd/AGENTS.md" ]; then
  rules="$(awk '/^## /{ if (inblk) exit } /^## Hard rules/{ inblk=1 } inblk{ print }' "$cwd/AGENTS.md")"
fi
[ -z "$rules" ] && [ -f "$cwd/skills/touchstone/SKILL.md" ] && rules="$(cat "$cwd/skills/touchstone/SKILL.md")"
[ -z "$rules" ] && exit 0

banner="This repo follows touchstone. Obey these hard rules from the first action; the full standards live in standards/.

$rules"

jq -n --arg ev "$event" --arg ctx "$banner" \
  '{hookSpecificOutput: {hookEventName: $ev, additionalContext: ("<touchstone-rules>\n" + $ctx + "\n</touchstone-rules>")}}'
exit 0
