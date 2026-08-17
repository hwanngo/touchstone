#!/usr/bin/env bash
# run-eval — prepare an eval case, then score a findings file against its answer key.
#
# THIS SCRIPT IS NOT PART OF THE BLOCKING SUITE. Evaluating an agent means running a prompt through a
# model: not hermetic, not offline, not deterministic. tests/run.sh must stay all three, so the
# --confirm-model-call flag exists to make importing this into the suite a deliberate act rather than
# an accident. tests/gates/run-eval-guard.test.sh asserts that run-eval-guard.test.sh is the ONLY
# test that references this script, and — because that one exemption is only safe while this script
# cannot reach outside the machine — asserts that this file invokes no model or network command. Give
# this script a real model call and that row goes red, on purpose: restructure the guard's
# behavioural rows first.
#
#   usage: ./scripts/run-eval.sh --case <id> [--findings <file>] --confirm-model-call
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

CASE=""
FINDINGS=""
CONFIRMED=0
while [ $# -gt 0 ]; do
  case "$1" in
  --case)
    # `shift 2` when only one positional argument remains (a dangling `--case` at the end of the
    # argument list) fails silently under `set -uo pipefail` (no `-e`): the shift does not happen,
    # $1 is still `--case`, and the loop spins on the same argument forever instead of failing
    # loudly. Requiring a second argument up front turns that hang into an ordinary exit 2.
    [ $# -ge 2 ] || {
      echo "run-eval: --case needs a value" >&2
      exit 2
    }
    CASE="$2"
    shift 2
    ;;
  --findings)
    [ $# -ge 2 ] || {
      echo "run-eval: --findings needs a value" >&2
      exit 2
    }
    FINDINGS="$2"
    shift 2
    ;;
  --confirm-model-call)
    CONFIRMED=1
    shift
    ;;
  *)
    echo "run-eval: unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

if [ "$CONFIRMED" -eq 0 ]; then
  echo "run-eval: scoring an agent needs a model call, which is neither hermetic nor offline." >&2
  echo "          Re-run with --confirm-model-call if that is what you want." >&2
  exit 3
fi

[ -n "$CASE" ] || {
  echo "run-eval: --case is required" >&2
  exit 2
}
DIR="evals/cases/$CASE"
[ -d "$DIR" ] || {
  echo "run-eval: no such case: $CASE" >&2
  exit 2
}

AGENT="$(awk -F': *' '/^agent:/ { print $2; exit }' "$DIR/meta.txt")"
echo "case:  $CASE"
echo "agent: $AGENT"
echo "repo:  $DIR/repo"
echo
echo "Run the $AGENT agent against $DIR/repo, write one finding per line to a file, then:"
echo "  bash scripts/score-eval.sh $DIR/answer-key.txt <that-file> --meta $DIR/meta.txt"

# A findings path that was GIVEN but cannot be read is a failure, never a silent skip.
#
# `[ -n "$FINDINGS" ] && [ -f "$FINDINGS" ]` fell through on a typo'd path, a directory, or an
# unreadable file: the hand-off text above had already been printed, so `just eval <case>
# <typo-path>` exited 0 having scored nothing. Exit 0 reads as PASS to anything checking status, and
# agents/eval-runner.md tells the agent this command "scores it" and to quote the
# matched/unmatched/recall/verdict lines — of which there would be none. Zero work done must never
# be exit 0; that is the rule this whole repo is built on, and it was broken in the eval runner.
#
# An EMPTY $FINDINGS is different and stays exit 0: `just eval <case>` passes `--findings ""` by
# design (the justfile's default), and that invocation's job is only to print the hand-off text.
if [ -n "$FINDINGS" ]; then
  if [ ! -f "$FINDINGS" ]; then
    echo "run-eval: --findings names no readable file: $FINDINGS" >&2
    echo "          Nothing was scored, so this is a failure and not a pass. Check the path." >&2
    exit 2
  fi
  if [ ! -r "$FINDINGS" ]; then
    echo "run-eval: --findings is not readable: $FINDINGS" >&2
    exit 2
  fi
  echo
  bash scripts/score-eval.sh "$DIR/answer-key.txt" "$FINDINGS" --meta "$DIR/meta.txt"
  exit $?
fi
