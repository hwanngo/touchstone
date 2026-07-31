#!/usr/bin/env bash
# Bash-guard decision table. Rows marked deny are policy violations that MUST be blocked;
# rows marked allow are ordinary commands that must NOT be blocked (a guard that cries wolf
# gets switched off, which is worse than no guard).
#
# G and C are assembled from fragments so this file does not itself contain the literal
# string the live guard denies writes on.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/../lib/assert.sh"
# shellcheck disable=SC1091
. "$DIR/../lib/hookcase.sh"
HOOK="$DIR/../../hooks/guard-bash.sh"

G="g""it"
C="c""ommit"

check() { # <expected> <command>
  assert_eq "$2" "$1" "$(hook_decision "$HOOK" "$2")"
}

# --- must deny: hook bypass ---
check deny "$G $C --no-verify -m x"
check deny "$G $C -n -m x"
check deny "$G $C --no-veri -m x"
check deny "$G -c core.hooksPath=/dev/null $C -m x"
check deny "HUSKY=0 $G $C -m x"
check deny "$G push --no-verify origin main"

# --- must deny: unleased force-push ---
check deny "$G push --force origin main"
check deny "$G push -f origin main"
check deny "$G push -ufqv origin main"
check deny "$G push origin +main:main"
check deny "$G push --force origin main # keep --force-with-lease semantics"
check deny "echo --force-with-lease; $G push --force origin main"
check deny "$G push --force-with-lease origin a; $G push --force origin b"
check deny "$G \\
 push --force origin main"

# --- must allow: legitimate compound commands ---
check allow "rm -rf dist && $G push origin main"
check allow "docker compose -f compose.yml up -d && $G push origin main"
check allow "make -f Makefile.ci && $G push origin main"
check allow "curl -sf https://example.test/health && $G push origin main"
check allow "head -n 5 CHANGELOG.md && $G $C -m x"
check allow "grep -rn TODO src/ ; $G $C -m x"
check allow "sort -n nums.txt | uniq -c && $G $C -m x"
check allow "$G log -n 5 && $G $C -m x"
check allow "ln -sf a b && $G push origin main"

# --- must allow: message content is data, not flags ---
check allow "$G $C -m \"fix: add -n flag support\""
check allow "$G $C -m \"docs: explain why --no-verify is banned\""
check allow "$G $C -m \"chore: touchstone-sync\""

# --- must allow: leased force-push ---
check allow "$G push --force-with-lease origin main"
check allow "$G push --force-with-lease=main origin main"

# --- must allow: ordinary reads ---
check allow "$G status"
check allow "$G push origin main"
check allow "ls -la"

# --- must deny: quoting/grouping tricks that hide a real bypass in the real argv ---
check deny "$G $C -m \"x\\\"\" --no-verify"
check deny "$G $C -m \$'it\'s' --no-verify"
check deny "$G $C -m \"line one
line two\" && $G push --force origin main"
check deny "( $G push --force origin main )"
check deny "{ $G push --force origin main; }"
check deny "case 1 in 1) $G push --force origin main;; esac"

# --- must allow: attached short-flag values and end-of-options are not bypass flags ---
check allow "$G $C -mnote"
check allow "$G $C -- --no-verify.txt"
check allow "$G $C -m note"
check allow "$G push -n origin main"

# --- must deny: padding a real flag with harmless repeated letters is not a length loophole ---
check deny "$G $C -nqqqqqq -m x"
check deny "$G push -fqqqqqq origin main"

# --- must allow: a long attached value stays allowed with no length cap ---
check allow "$G $C -mtestcase"

# --- must deny: a cluster mixing the force flag with another valid push letter. `d` (--delete)
#     and `o` (--push-option) were missing from the valid set, and because a cluster requires
#     EVERY letter to be valid, one unlisted letter made the whole token "not a cluster" and hid
#     the force flag next to it — a real force-delete allowed ---
check deny "$G push -fd origin topic"
check deny "$G push -df origin topic"
check deny "$G push -fdq origin topic"

# --- must allow: those same letters on their own are not force-pushes, and `-o` takes a value so
#     everything after it is a push-option string, not more flag letters ---
check allow "$G push -d origin topic"
check allow "$G push -o ci.skip origin main"
check allow "$G push -of origin main"

# --- must allow: the value-taking letter is honoured at EVERY position, not just the first.
#     `-amnote` is `-am note`; the `n` is inside the message, and denying it also misattributed
#     the reason to a flag that was never used ---
check allow "$G $C -amnote"
check allow "$G $C -amn"
check allow "$G $C -aqmnote"

# --- must deny: an `n` that really is a flag letter, before any value-taking letter ---
check deny "$G $C -an -m x"
check deny "$G $C -anq -m x"

# --- must deny: backgrounding and control-flow keywords don't shield a real bypass ---
check deny "echo hi & $G push --force origin main"
check deny "if true; then $G push --force origin main; fi"
check deny "while true; do $G push --force origin main; done"
check deny "until false; do $G push --force origin main; done"
check deny "if ! $G push --force origin main; then echo x; fi"
check deny "for f in a; do $G $C --no-verify -m x; done"

# --- must allow: over-eager keyword/separator handling would wrongly deny these ---
check allow "echo $G push --force origin main"
check allow "echo hi && $G push origin main"
check allow "$G push origin main & wait"

# --- must deny: an fd-redirection operator contains `&` but must not split the command, and a
#     leading redirection is plumbing, not the command word ---
check deny "$G push 2>&1 --force origin main"
check deny "$G $C 2>&1 --no-verify -m x"
check deny "$G push &>/dev/null --force origin main"
check deny "$G push >&2 --force origin main"
check deny "2>&1 $G push --force origin main"
check deny "$G 2>&1 push --force origin main"

# --- must allow: redirections on ordinary commands, and `&&`/`&` still read correctly. The last
#     three restate rows above on purpose: they are the exact guarantees the `&`-adjacency rule
#     must not regress, so they belong next to the rows that exercise it. ---
check allow "$G status 2>&1"
check allow "echo hi && $G push origin main"
check allow "$G push origin main & wait"
check allow "echo $G push --force origin main"

# --- must deny: bash ends a word at a redirect operator with no whitespace, so a redirect glued
#     to the git binary or to a subcommand/flag must not hide what follows it ---
check deny "$G>out push --force origin main"
check deny "$G>/dev/null push --force origin main"
check deny "$G<in push --force origin main"
check deny "${G}2>out push --force origin main"
check deny "$G push>out --force origin main"
check deny "$G push --force>out origin main"

# --- must allow: a glued redirect on an unguarded subcommand, and a plain push ---
check allow "$G status>out"
check allow "$G push origin main"

# --- must deny: `&>`/`&>>` glued to the git binary — the `&` opens the operator, so it belongs
#     with the redirect and not with the command word ---
check deny "$G&>out push --force origin main"
check deny "$G&>>out push --force origin main"
check deny "$G&>/dev/null push --force origin main"

# --- must allow: the word in front of `&>` is what runs. `cmd` is not the git binary and the
#     trailing words are its arguments; `${G}2` is a nonexistent command, because `&>` takes no
#     fd number and so the digit stays part of the word ---
check allow "cmd&>x $G push origin main"
check allow "cmd&>x $G push --force origin main"
check allow "${G}2&>out push --force origin main"

# --- must deny: a QUOTED or otherwise non-literal policy flag is not a bypass. The redacted view
#     collapses a quoted span to a single Q, so these all read as innocent there; the raw view is
#     what sees them. Every shape below was a deny->allow regression against the pre-branch
#     baseline, which caught them by accident because it grepped the whole command string. ---
check deny "$G push \"--force\" origin main"
check deny "$G push '--force' origin main"
check deny "$G $C \"--no-verify\" -m x"
check deny "$G $C '--no-verify' -m x"
check deny "$G push \"-f\" origin main"
check deny "$G $C \"-n\" -m x"
check deny "$G push --f\"\"orce origin main"
check deny "$G $C --n\"\"o-verify -m x"
check deny "$G push --f\\orce origin main"
check deny "$G $C --n\\o-verify -m x"

# --- must deny: a non-literal COMMAND WORD is not a bypass either — the shell resolves all of
#     these to the git binary ---
check deny "\\$G push --force origin main"
check deny "'$G' push --force origin main"
check deny "\"$G\" push --force origin main"
check deny "/usr/bin/$G push --force origin main"
check deny "./bin/$G push --force origin main"
check deny "sudo $G push --force origin main"
check deny "env $G push --force origin main"
check deny "\\$G $C --no-verify -m x"
check deny "sudo $G $C -n -m x"
check deny "env HUSKY=0 $G $C -m x"

# --- must allow: only `git` or `*/git` counts as the git binary, and only the fixed keyword set
#     is skipped — an arbitrary leading word is still never skipped ---
check allow "echo \\$G push --force origin main"
check allow "echo sudo $G push --force origin main"
check allow "echo /usr/bin/$G push --force origin main"
check allow "my$G push --force origin main"
check allow "$G-foo push --force origin main"

# --- documented limit of reading the raw view: a quoted message that is a SINGLE hyphen-led word
#     of letters is textually indistinguishable from a flag cluster and denies. A message with any
#     space, punctuation or digit in it does not — which is every row in the must-allow block
#     above. ---
check deny "$G $C -m \"-nope\""
check allow "$G $C -m \"-n is a flag\""

# --- must deny: writing secrets from Bash (the Write guard's rule, same policy) ---
check deny "cat > .env"
check deny "printf 'K=v' > .env"
check deny "cp /tmp/leak.env .env"
check deny "tee .env"
check deny "sed -i '' s/a/b/ .env"
check deny "cat > frontend/.env.production"
check deny "cat > .envrc"

# --- must allow: example/template files and unrelated redirects ---
check allow "cat > .env.example"
check allow "cat > README.md"
check allow "echo hi > /tmp/notes.txt"

# --- must deny: a quoted or backslash-escaped write target is not a bypass — the raw view sees
#     through the quote/escape that the redacted view (correctly) collapses to Q ---
check deny "cat > \".env\""
check deny "cat > '.env'"
check deny "printf 'K=v' > \"frontend/.env.production\""
check deny "cat > '.envrc'"
check deny "cat > \.env"
check deny "cat >> \".env\""
check deny "echo hi; cat > \".env\""
check deny "$G $C -m \"line one
line two\" && cat > \".env\""

# --- must allow: the raw view is positional, not a flat token scan — a secret-shaped filename
#     appearing as ordinary prose (not an actual write target) must not trigger a false deny ---
check allow "echo \"update .env\" > notes.txt"
check allow "grep TODO .env > /dev/null"
check allow "scp file.txt user@host:.env"
check allow "cat > \".env.example\""
check allow "$G $C -m \"mention .env in commit message\""

# --- must allow: copying a template-marked file to a backup keeps the component-anchored
#     allowlist match; must deny: copying a real secret to a backup does not ---
check allow "cp .env.example .env.example.bak"
check allow "cp .env.sample .env.sample.bak"
check deny "cp .env .env.bak"

# --- must deny: bare write-redirect forms the old hardcoded pattern list missed — a spaced
#     and-redirect (&>/&>>) and a multi-digit fd, both written apart from their target ---
check deny "cat &> .env"
check deny "cat &>> .env"
check deny "cat 10> .env"
check deny "cat 10>> .env"
check deny "cat >& .env"

# --- must allow: the same spaced and-redirect form on an ordinary or template target, and a
#     read redirect FROM a secret file into an ordinary write — a source is not a target ---
check allow "cat &> /tmp/notes.txt"
check allow "cat &> .env.example"
check allow "cp secretfile < .env"

# --- must deny: a git-led segment is not exempt from the secret-write rule. The check used to run
#     only in the non-git branch, so every one of these allowed — the second is a plausible
#     credential dump ---
check deny "$G status > .env"
check deny "$G config -l > .env"
check deny "$G config -l >> .env"
check deny "$G show HEAD:secrets > \".env\""
check deny "$G status > .env && $G push origin main"

# --- must allow: git-led segments with an ordinary or template target ---
check allow "$G status > /tmp/notes.txt"
check allow "$G status > .env.example"
check allow "$G diff > out.patch"

# --- must allow, and must give the SAME answer in every directory: the deliberate word-splits
#     also performed pathname expansion, so an ordinary `cp * backup/` DENIED in a directory that
#     happened to contain a secret-shaped file and ALLOWED in one that did not. Agreement between
#     the two arms is the property under test, which is why both are asserted — a single-directory
#     row cannot see this class at all. ---
check allow "cp * backup/"
cwd_tmp="$(mktemp -d 2>/dev/null || true)"
if [ -n "$cwd_tmp" ] && [ -d "$cwd_tmp" ]; then
  : >"$cwd_tmp/local.env"
  : >"$cwd_tmp/README.md"
  assert_eq "cp * backup/ (cwd contains local.env) still allows" "allow" \
    "$(cd "$cwd_tmp" && hook_decision "$HOOK" "cp * backup/")"
  # A glob that is itself secret-shaped stays denied, and correctly so: bash expands a redirect
  # target, so `cat > *.env` really does write a .env file. `set -f` only stops the GUARD from
  # expanding — it does not stop it from reading the literal pattern.
  assert_eq "cat > *.env (cwd contains local.env) denies on the literal pattern" "deny" \
    "$(cd "$cwd_tmp" && hook_decision "$HOOK" "cat > *.env")"
  assert_eq "cat > local.env (cwd contains local.env) still denies" "deny" \
    "$(cd "$cwd_tmp" && hook_decision "$HOOK" "cat > local.env")"
  rm -rf "$cwd_tmp"
else
  ts_skip "cwd-independence" "mktemp -d not available"
fi

# --- documented limit of checking every segment: `mv` is a write-command name wherever it
#     appears, so `git mv` onto a secret-shaped name denies. Accepted over exempting git-led
#     segments, which is what hid `git config -l > .env`. ---
check deny "$G mv a.env b.env"

ts_report
