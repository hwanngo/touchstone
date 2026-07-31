#!/usr/bin/env bash
# Multibyte-safety regression fixture for hooks/guard-bash.sh.
#
# METHODOLOGY WARNING, paid for twice by the humans reviewing this file: never build multibyte
# test bytes with backslash escapes inside a bash DOUBLE-QUOTED string — bash does not
# interpret \xNN/\NNN there, so "\xc3\xa9" is nine literal ASCII characters, not the two UTF-8
# bytes of é, and a probe built that way silently tests nothing and gives a false all-clear no
# matter what the hook does. Build real bytes with `printf '\xNN'` (hex) or `printf '\NNN'`
# (octal) into a variable, then interpolate that variable — never type or escape the bytes
# inline in a row below.
#
# Every row also carries a definite ASCII deny-trigger (--no-verify, -n, --force, or a chained
# secret write) alongside the multibyte payload. A bare "allow" with no control present proves
# nothing: it is also exactly what a crashed, fail-open guard returns. The awk multibyte
# conversion crash this fixture guards against (see hooks/guard-bash.sh's LC_ALL=C pin) makes
# `segments` come back empty and the per-segment loop never run — every rule OFF, git rules
# included — which reads as an innocuous "allow" unless something in the row was guaranteed to
# deny if the guard were actually running.
#
# Each row runs under BOTH `LC_ALL=C` and a UTF-8 locale, with IDENTICAL expectations — the
# crash this fixture targets is locale-dependent by construction, so a fixture that only tests
# one locale cannot see it. hook_decision (tests/lib/hookcase.sh) also asserts stderr is empty
# on every call, so a crash shows up as a `STDERR:...` mismatch rather than silently reading as
# "allow". That stderr assertion only works BECAUSE hooks/guard-bash.sh's awk invocation is
# unredirected — no `2>/dev/null` on that call. If a future edit ever adds one, this whole
# fixture's UTF-8 arm would start reading a crash as a clean "allow" again, silently.
#
# THE UTF-8 LOCALE ITSELF IS SELECTED AT RUNTIME (see select_utf8_locale below), never
# hardcoded to a specific name like en_US.UTF-8: a hardcoded locale that happens not to be
# installed on some machine/CI image would still be *accepted* by the shell (LANG=anything is
# always syntactically valid), silently running the process in the C locale instead — at which
# point both arms test the same locale and this fixture's entire purpose evaporates AS A PASS.
# `LC_CTYPE` is unset alongside `LC_ALL` for the same reason: an inherited LC_CTYPE outranks
# LANG and would otherwise silently win. If no UTF-8 locale is available at all, every row's
# UTF-8 arm FAILS (never ts_skip): this is the one place in the suite where the repo's
# self-skip-on-missing-fixture rule does not apply, because the missing thing is a capability
# the assertion itself depends on, not an absent test fixture — skipping would hide exactly the
# locale-dependent degradation this fixture exists to catch.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/hookcase.sh"
HOOK="$DIR/../../hooks/guard-bash.sh"

G="g""it"
C="c""ommit"

# Real UTF-8 bytes, built with printf hex escapes — see the methodology warning above.
E_ACUTE="$(printf '\xc3\xa9')"       # é, U+00E9, 2 bytes
PARTY="$(printf '\xf0\x9f\x8e\x89')" # 🎉, U+1F389, 4 bytes
caf_e="caf${E_ACUTE}"                # café, built from real bytes, not typed literally

# select_utf8_locale -> a UTF-8-codeset locale name installed on this machine, or "" if none.
# Prefers C.UTF-8 (ships on nearly every Linux distro's minimal image and keeps
# collation/messages boring, so only LC_CTYPE's multibyte behavior is under test), then any
# other locale `locale -a` reports whose name contains "utf8"/"UTF-8" case-insensitively.
select_utf8_locale() {
  local avail cand
  avail="$(locale -a 2>/dev/null)"
  [ -z "$avail" ] && return 0
  for cand in C.UTF-8 C.utf8; do
    if printf '%s\n' "$avail" | grep -qxF "$cand"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  printf '%s\n' "$avail" | grep -iE 'utf-?8' | head -1
}
UTF8_LOCALE="$(select_utf8_locale)"

# check_mb <expected> <label> <command> — runs under LC_ALL=C and then under the runtime-selected
# UTF-8 locale (LC_ALL and LC_CTYPE both unset, LANG set to it), asserting the SAME expected
# decision both times. If no UTF-8 locale was found, the UTF-8 arm FAILS rather than skipping —
# see the header note above.
check_mb() {
  local expected="$1" label="$2" cmd="$3" utf8_actual
  assert_eq "$label (LC_ALL=C)" "$expected" "$(LC_ALL=C hook_decision "$HOOK" "$cmd")"
  if [ -n "$UTF8_LOCALE" ]; then
    utf8_actual="$(
      unset LC_ALL LC_CTYPE
      LANG="$UTF8_LOCALE" hook_decision "$HOOK" "$cmd"
    )"
    assert_eq "$label (UTF-8: $UTF8_LOCALE)" "$expected" "$utf8_actual"
  else
    # No UTF-8 locale available on this machine at all: fail loudly rather than skip, per the
    # header note — a skip here would hide exactly the degradation this fixture guards against.
    assert_eq "$label (UTF-8: NONE AVAILABLE — \`locale -a\` reported no UTF-8 codeset, cannot exercise this arm)" \
      "$expected" "NO-UTF8-LOCALE-AVAILABLE"
  fi
}

# --- the three repros measured against the live hook before this round's locale-pin fix ---
check_mb deny "repro: quoted multibyte + --no-verify" \
  "$G $C --no-verify -m \"$caf_e\""
check_mb deny "repro: multibyte commit msg + push --force" \
  "$G $C -m \"emoji ${PARTY} msg\" && $G push --force origin main"
check_mb deny "repro: multibyte echo + chained secret write" \
  "echo \"$caf_e\" && cat > .env"

# --- unquoted multibyte immediately before a # (the PRE-EXISTING crash trigger — the
#     comment-boundary test crashed on this before the detection round ever touched the file) ---
check_mb deny "unquoted multibyte before #, chained force-push" \
  "echo ${E_ACUTE}#comment && $G push --force origin main"

# --- multibyte inside each of the three quote styles the awk scanner treats differently ---
check_mb deny "multibyte in single quotes" \
  "$G $C -m '$caf_e' --no-verify"
check_mb deny "multibyte in double quotes" \
  "$G $C -m \"$caf_e\" -n"
check_mb deny "multibyte in \$'...' (ANSI-C) quotes" \
  "$G $C -m \$'$caf_e' --no-verify"

# --- an outside-quote backslash-escaped multibyte character ---
check_mb deny "backslash-escaped multibyte, chained force-push" \
  "echo \\${E_ACUTE} && $G push --force origin main"

# --- a 4-byte emoji (spans more single-byte scan positions than any 2-byte case above)
#     followed by a chained secret write ---
check_mb deny "4-byte emoji + chained secret write" \
  "echo \"$PARTY\" && cat > .env"

# --- static invariants: the crash class cannot silently return ---
# (d1) the awk invocation itself must carry the locale pin — anchored on the actual `segments=`
#      invocation line (piped into LC_ALL=C awk), not a whole-file substring search: a future
#      edit that drops the pin from the real call while still discussing it in a comment must
#      fail this check, not pass it.
pin_matches="$(grep -cE '^segments=.*\| *LC_ALL=C awk' "$HOOK")"
assert_eq "awk invocation line carries LC_ALL=C pin (anchored, not a whole-file substring)" "1" "$pin_matches"
# (d2) zero regex-match operators anywhere in the awk program (whole-file grep is fine, indeed
#      strictly stronger, here: the awk program is embedded inline, so this also guards against
#      a `~` reappearing anywhere else in a future edit that touches this file)
tilde_count="$(grep -c '~' "$HOOK" | tr -d '[:space:]')"
assert_eq "zero '~' regex-match operators in guard-bash.sh" "0" "$tilde_count"

ts_report
