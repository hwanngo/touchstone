#!/usr/bin/env bash
# Stop hook: gentle reminder to run the gates before declaring done. Guarded against the stop-loop —
# if `stop_hook_active` is already set (we're here *because* a previous Stop hook re-prompted), do
# nothing, so the turn can actually end and the user gets the floor back. Fires at most once.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
# already inside a stop-hook continuation → no-op, or we'd re-prompt forever
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0

jq -n '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: "If you changed code, run `just ci` (or the stack gates) and show the output before claiming done — evidence before claims."}}'
exit 0
