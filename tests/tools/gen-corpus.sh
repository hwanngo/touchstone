#!/usr/bin/env bash
# Prints one hooks/guard-bash.sh input command per NUL-terminated record to stdout: every
# Bash-command string used by the existing guard-bash test suites, plus a generated
# cross-product of shapes. Consumed by tests/tools/diff-decisions.sh; also runnable standalone
# to inspect or save a corpus (`tests/tools/gen-corpus.sh > corpus.bin`).
#
# NUL, not newline, is the record separator end to end (part 1 and part 2 both), because at
# least one existing row's command string contains a real embedded newline (the
# line-continuation case in tests/hooks/guard-bash.test.sh — `git \` + an actual newline +
# ` push --force origin main`, which exercises guard-bash.sh's own continuation-normalization
# step). A newline-terminated corpus would silently split that one record into two meaningless
# fragments and `sort -u` would separate them with no warning. To inspect this file's output as
# text, translate NULs to newlines: `tests/tools/gen-corpus.sh | tr '\0' '\n'`.
#
# Part 1 (existing rows) is extracted by actually RUNNING the test files with
# $HOOKCASE_LOG_FILE set — tests/lib/hookcase.sh's hook_decision appends every command string
# it is called with there, NUL-terminated, as a side channel, without changing its normal
# behavior at all (the variable is unset in ordinary test runs). This runs the real suite
# (harmlessly — these hooks never write anything, only inspect input and emit JSON) rather than
# trying to shadow/stub hook_decision by sourcing, which a test file's own `. hookcase.sh`
# would silently undo.
#
# Part 2 (generated cross-product) covers: {commit bypass long/short, push force/leased, secret
# writes via cat/tee/cp/sed} x {unquoted, single, double, ANSI-C, backslash-escaped} x {plain,
# append, and-redirect, single-digit fd, multi-digit fd, glued, spaced} x {ASCII, multibyte}.
# The multibyte variant appends a harmless real-UTF-8-byte trailing token to the ASCII form,
# built via printf hex escapes (never backslash escapes inside a bash double-quoted string —
# those are not interpreted by bash and would silently test nothing).
#
# Part 3 (the two axes nine review rounds never generated) applies the quote/escape dimension to
# the GUARDED FLAG itself and varies the COMMAND WORD. Every earlier corpus quoted the commit
# MESSAGE and the secret TARGET but always spelled the flag and the git binary literally — which
# is why 156 rows and 123 probe cases never noticed that `git push "--force" origin main` was a
# deny->allow regression against the pre-branch baseline. The cheapest possible bypass of a
# literal-token match is to quote the token, so it gets its own axis here:
#   flag styles:    bare, "double", 'single', embedded empty quote pair (`--f""orce`),
#                   backslash-escaped mid-word (`--f\orce`)
#   command words:  git, \git, 'git', "git", /usr/bin/git, sudo git, env git
# The in-word forms are placed EARLY in the flag (after 3 characters, or after 1 for a short
# flag) on purpose: the redacted view drops or collapses the escaped/quoted characters, so an
# in-word break near the END would leave a redacted prefix that still matches `--no-ver*` and the
# row would prove nothing. Negative controls travel with the axis (an `echo` prefix, a leased
# force-push, and a quoted commit message for every command-word variant) so an over-correction
# that starts denying ordinary commands shows up in the same differential run.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$DIR/../hooks"

CORPUS_LOG="$(mktemp 2>/dev/null)" || {
  echo "gen-corpus: mktemp failed" >&2
  exit 2
}
trap 'rm -f "$CORPUS_LOG"' EXIT

# --- part 1: every command string from the existing guard-bash suites ---
for f in "$TESTS_DIR"/guard-bash*.test.sh; do
  [ -f "$f" ] || continue
  HOOKCASE_LOG_FILE="$CORPUS_LOG" bash "$f" >/dev/null 2>&1
done
sort -u -z "$CORPUS_LOG"

# --- part 2: generated cross-product ---
G="git"
E_ACUTE="$(printf '\xc3\xa9')" # é, U+00E9, real bytes via printf hex escape
MB=" caf${E_ACUTE}"            # harmless trailing token — tests ASCII/multibyte PARITY, not a new trigger

# emit <record> -> writes it to stdout, NUL-terminated (see the NUL-delimiter note above)
emit() { printf '%s\0' "$1"; }

# quote_word <word> <style> -> the word wrapped per style
quote_word() {
  local word="$1" style="$2"
  case "$style" in
  unquoted) printf '%s' "$word" ;;
  single) printf "'%s'" "$word" ;;
  double) printf '"%s"' "$word" ;;
  ansic) printf "\$'%s'" "$word" ;;
  backslash) printf '\%s' "$word" ;;
  esac
}

# commit bypass, long and short form, x quote style x ASCII/multibyte
for form in --no-verify -n; do
  for style in unquoted single double ansic backslash; do
    msg="$(quote_word "bump" "$style")"
    emit "$G commit $form -m $msg"
    emit "$G commit $form -m $msg$MB"
  done
done

# push force / leased x ASCII/multibyte (no message argument, so no quote-style dimension)
for form in --force --force-with-lease; do
  emit "$G push $form origin main"
  emit "$G push $form origin main$MB"
done

# secret writes via cat, across the full redirect-shape dimension x quote style x ASCII/multibyte
for style in unquoted single double ansic backslash; do
  tgt="$(quote_word ".env" "$style")"
  emit "cat > $tgt"
  emit "cat > $tgt$MB"
  emit "cat >> $tgt"
  emit "cat >> $tgt$MB"
  emit "cat &> $tgt"
  emit "cat &> $tgt$MB"
  emit "cat 1> $tgt"
  emit "cat 1> $tgt$MB"
  emit "cat 10> $tgt"
  emit "cat 10> $tgt$MB"
  emit "cat >& $tgt"
  emit "cat >& $tgt$MB"
  emit "cat>$tgt"
  emit "cat>$tgt$MB"
done

# secret writes via tee/cp/sed x quote style x ASCII/multibyte
for style in unquoted single double ansic backslash; do
  tgt="$(quote_word ".env" "$style")"
  emit "tee $tgt"
  emit "tee $tgt$MB"
  emit "cp src $tgt"
  emit "cp src $tgt$MB"
  emit "sed -i '' s/a/b/ $tgt"
  emit "sed -i '' s/a/b/ $tgt$MB"
done

# --- part 3: the guarded flag itself, and the command word ---

# quote_flag <flag> <style> -> the flag rendered per style. All five forms expand, in a real
# shell, to exactly the same argv word — that is the point. `emptypair` and `midescape` break the
# word INTERNALLY (an embedded `""` and a backslash before a mid-word character), which no
# whole-token quoting axis can reach. The break point is early (after 3 characters, or after 1 on
# a two-character short flag) so the redacted view's remaining prefix cannot still match the
# guard's `--no-ver*` glob — see the header note.
quote_flag() {
  local flag="$1" style="$2" cut head tail
  cut=3
  [ "${#flag}" -le 3 ] && cut=1
  head="${flag:0:$cut}"
  tail="${flag:$cut}"
  case "$style" in
  bare) printf '%s' "$flag" ;;
  double) printf '"%s"' "$flag" ;;
  single) printf "'%s'" "$flag" ;;
  emptypair) printf '%s""%s' "$head" "$tail" ;;
  midescape) printf '%s\\%s' "$head" "$tail" ;;
  esac
}

# command_word <style> -> a spelling of the git binary that a real shell resolves to git
command_word() {
  case "$1" in
  bare) printf '%s' "$G" ;;
  backslash) printf '\\%s' "$G" ;;
  single) printf "'%s'" "$G" ;;
  double) printf '"%s"' "$G" ;;
  abspath) printf '/usr/bin/%s' "$G" ;;
  relpath) printf './bin/%s' "$G" ;;
  sudo) printf 'sudo %s' "$G" ;;
  env) printf 'env %s' "$G" ;;
  esac
}

for cw_style in bare backslash single double abspath relpath sudo env; do
  cw="$(command_word "$cw_style")"
  for fstyle in bare double single emptypair midescape; do
    emit "$cw commit $(quote_flag '--no-verify' "$fstyle") -m x"
    emit "$cw commit $(quote_flag '-n' "$fstyle") -m x"
    emit "$cw push $(quote_flag '--force' "$fstyle") origin main"
    emit "$cw push $(quote_flag '-f' "$fstyle") origin main"
  done
  # negative controls, one set per command-word variant: printing the text pushes nothing, a
  # leased force-push is policy-compliant, an ordinary commit message that merely NAMES the
  # guarded flag is data, and a plain push is a plain push.
  emit "echo $cw push --force origin main"
  emit "$cw push --force-with-lease origin main"
  emit "$cw commit -m \"docs: explain why --no-verify is banned\""
  emit "$cw push origin main"
done
