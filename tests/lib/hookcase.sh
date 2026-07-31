#!/usr/bin/env bash
# Feed synthetic Claude Code hook payloads to a hook and report its decision.
# The hooks always exit 0 (fail-open), so the decision lives in stdout JSON, not $?.
#
# Every helper below asserts stderr is empty as part of the returned decision: if the hook
# process wrote ANYTHING to stderr, the "decision" comes back as a STDERR:<text> sentinel
# instead of allow/deny, which cannot match either expected value and so fails the row in the
# caller's assert_eq. This is deliberate — a hook that crashes mid-run (the awk
# multibyte-conversion abort a locale mismatch used to trigger is exactly this class) still
# exits 0 and produces no JSON, which silently reads as "allow" to a decision-only check.
# Surfacing stderr turns "the guard silently went quiet" into a visible, diagnosable test
# failure on every row, not just the ones where the crash also happens to flip a decision.

# _hook_run <script> <payload-json> -> stdout of the hook, or a "STDERR:<text>" sentinel if it
# wrote to stderr (checked before stdout is examined at all, so a hook that both errors AND
# prints stale JSON still fails the row).
_hook_run() {
  local script="$1" payload="$2" out err errfile
  errfile="$(mktemp 2>/dev/null)" || {
    printf 'STDERR:mktemp failed'
    return 0
  }
  out="$(printf '%s' "$payload" | bash "$script" 2>"$errfile")"
  err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
  if [ -n "$err" ]; then
    printf 'STDERR:%s' "$err"
    return 0
  fi
  printf '%s' "$out"
}

# _hook_decision_of <hook-output> -> "allow" | "deny" | the STDERR:... sentinel passed through
_hook_decision_of() {
  local out="$1"
  case "$out" in
  STDERR:*)
    printf '%s' "$out"
    return 0
    ;;
  esac
  if [ -z "$out" ]; then
    printf 'allow'
    return 0
  fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null ||
    printf 'allow'
}

# hook_decision <hook-script> <command-string> -> "allow" | "deny" | "STDERR:<text>"
#
# If $HOOKCASE_LOG_FILE is set, every command string this is called with is also appended
# there, NUL-terminated, in addition to computing the real decision. Unset in normal test runs
# (a no-op); tests/tools/gen-corpus.sh sets it to extract every Bash-command string the
# existing suites exercise, without needing to fork the hook process at all for that purpose.
# NUL, not newline, is the record separator: at least one existing row's command string
# contains a real embedded newline (the line-continuation case), and a newline-terminated log
# would silently split that single record into two meaningless fragments.
hook_decision() {
  local script="$1" cmd="$2" payload out
  [ -n "${HOOKCASE_LOG_FILE-}" ] && printf '%s\0' "$cmd" >>"$HOOKCASE_LOG_FILE"
  payload="$(jq -Rn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  out="$(_hook_run "$script" "$payload")"
  _hook_decision_of "$out"
}

# write_decision <hook-script> <file-path> [content] -> "allow" | "deny" | "STDERR:<text>"
write_decision() {
  local script="$1" path="$2" content="${3-}" payload out
  payload="$(jq -Rn --arg p "$path" --arg c "$content" \
    '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"
  out="$(_hook_run "$script" "$payload")"
  _hook_decision_of "$out"
}

# notebook_decision <hook-script> <notebook-path> [new-source] -> "allow" | "deny" | "STDERR:<text>"
notebook_decision() {
  local script="$1" path="$2" source="${3-}" payload out
  payload="$(jq -Rn --arg p "$path" --arg s "$source" \
    '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p,new_source:$s}}')"
  out="$(_hook_run "$script" "$payload")"
  _hook_decision_of "$out"
}
