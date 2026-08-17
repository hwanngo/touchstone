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

# Rows promoted from the guardrail-redteam campaign carry the attempt id that produced them
# (see the task-5b campaign record), so a reader can trace a row back to its attempt.
checkid() { # <attempt-id> <expected> <command>
  assert_eq "$1 $3" "$2" "$(hook_decision "$HOOK" "$3")"
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

# --- GB-158: a `-m` VALUE is data, not a flag. This used to deny with the message "don't bypass
#     git hooks with -n" — a block on an ordinary commit AND a false statement about which flag
#     caused it. The attached form (`-mnote`) was already handled inside cluster_has; this is the
#     separate-word form. Dropping the value cannot hide a bypass: the shell hands that word to
#     git as data. ---
checkid GB-158 allow "$G $C -m \"-nope\""
check allow "$G $C -m \"-n is a flag\""
check allow "$G $C -m -n"
check allow "$G $C --message \"-nope\""
check allow "$G $C -m \"--no-verify\""
check allow "$G push -o --force origin main"
check allow "$G merge -m \"-n\" feature"
# ...and the value consumes exactly ONE word, so a real flag after it is still seen
check deny "$G $C -m x --no-verify"
check deny "$G $C --no-verify -m \"-nope\""
check deny "$G $C -m note -n"
check deny "$G $C -m note --no-verify"
check deny "$G push -o ci.skip --force origin main"

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

# --- GB-150: `git mv` is a VCS rename of a file git already TRACKS, so no secret content enters
#     the repo that was not already in it. It used to deny with a message claiming a .env-family
#     file was being written from Bash. A multi-call SHELL-UTILITY dispatcher is different —
#     `busybox cp` really is cp — so that case stays. ---
checkid GB-150 allow "$G mv a.env b.env"
checkid GB-150b allow "$G mv old.env new.env"
check allow "$G mv notes.txt .env"
checkid GB-032 deny "busybox cp secrets.txt .env"
check deny "busybox mv secrets.txt .env"
check deny "toybox cp secrets.txt .env"
# the rule that motivated checking git-led segments at all is a REDIRECT rule and is untouched
check deny "$G status > .env"
check deny "$G config -l > .env"
check deny "$G show HEAD:secrets > .env"

# --- GB-157: a heredoc BODY is data the shell feeds a command on stdin, never command text.
#     Analyzing it line by line denied documentation prose that merely described a banned
#     command — the same defect as denying docs/security.md for quoting a PEM header. ---
checkid GB-157 allow "cat <<'EOF' > docs/policy.md
$G push --force is banned here
EOF"
check allow "cat <<EOF > docs/policy.md
$G $C --no-verify is banned here
EOF"
check allow "cat <<-'EOF' > docs/policy.md
	$G push --force is banned here
	EOF"
# the COMMAND LINE is still analyzed in full — only the body is dropped
check deny "cat <<'EOF' > .env
K=v
EOF"
# and the body ends at its terminator, so what follows is command text again
check deny "cat <<'EOF' > docs/p.md
doc line
EOF
$G push --force origin main"
# a `<<` inside a quoted string is not a heredoc, so it must not swallow the next line. This is
# the row that proves the detection is quote-aware rather than a text pre-pass.
check deny "echo \"a << b\"
$G push --force origin main"
check deny "echo 'x << EOF'
$G $C --no-verify -m x"
# a here-STRING has no body at all
check deny "$G push --force origin main <<< input"

# --- REGRESSION GB-190: an unquoted `<<` that is NOT a heredoc operator must not swallow the
#     rest of the command. `$((1<<3))` is left-shift; the delimiter scan stops at `)`, so the
#     operator parsed as a heredoc with delimiter `3`, no line ever equalled `3`, and the
#     body-skip consumed the whole remaining buffer — every rule below silently OFF for every
#     following line. Two independent guards close it (arithmetic-context tracking, plus
#     "no terminator line ahead means it was never a heredoc"), so each row below is asserted
#     both for the decision and, by the pairs, for the reason. ---
checkid GB-190 deny "n=\$((1<<3))
$G push --force origin main"
check deny "echo \$((1 << 3))
$G push --force origin main"
check deny "mask=\$((1<<8))
$G $C --no-verify -m x"
check deny "if (( 1<<2 )); then echo hi; fi
$G push --force origin main"
check deny "(( 1<<2 ))
$G $C --no-verify -m x"
check deny "x=\$(( 1 << (2+1) ))
$G push --force origin main"
check deny "while (( i<<1 < 100 )); do i=\$((i+1)); done
$G push --force origin main"
# arithmetic can span a newline, so the `<<` is still inside `$(( … ))` two lines later
check deny "n=\$((1
<<3))
$G push --force origin main"
# ONE ROW PER GUARD, so neither can be removed without a red row.
# This one supplies a line that IS equal to the mis-parsed delimiter, so the no-terminator net
# accepts it as a heredoc: only the arithmetic tracking denies it.
check deny "n=\$((1<<3))
$G push --force origin main
3"
# And this one keeps `<<` on a line the arithmetic tracker cannot reach as arithmetic-with-shift on
# one line — the delimiter has no terminator, so only the net denies it.
check deny "cat <<3
$G push --force origin main"
# a heredoc whose delimiter never appears on a line of its own could not run as written (the
# shell would block on stdin), so it is a mis-parse or a deliberate swallow — either way the
# lines after it are analyzed, never dropped.
check deny "cat <<EOF
$G push --force origin main"
# arithmetic on its own must still be allowed, and must not make the scanner crash
check allow "echo \$((1<<3))"
check allow "x=\$(( (1<<3) | (1<<4) ))"
check allow "echo \$(((1<<3)))"
# THE INVERSE ERROR: the arithmetic suppression must not stop a REAL heredoc from being
# detected, or its prose body gets scanned as command text again — the false positive the
# body-skip exists to prevent. A balanced arithmetic before it, and a `(` that is NOT
# arithmetic, both leave the following heredoc body skipped.
check allow "n=\$((1<<3))
cat <<EOF > docs/p.md
$G push --force is banned here
EOF"
check allow "a=(1 2)
cat <<EOF > docs/p.md
$G push --force is banned here
EOF"
# two heredocs on one command line: both bodies are data, and the command line is still checked
check allow "cat <<A <<B > docs/p.md
$G push --force
A
$G $C --no-verify
B"
check deny "cat <<A <<B > .env
one
A
two
B"

# =====================================================================================
# Rows promoted from the guardrail-redteam campaign (task 5b). Every row below is named
# for the attempt it came from.
# =====================================================================================

# --- FALSE POSITIVE GB-180/181/182: `--no-verbose` is parse-options auto-negation of
#     `-v/--verbose` and has nothing to do with hooks. The `--no-ver*` prefix rule denied it AND
#     told the user it had used --no-verify — a block plus a lie about why. `--no-verb…` is the
#     only prefix of `--no-verbose` that is not also a prefix of `--no-verify`, so it is the
#     exact carve-out. ---
checkid GB-180 allow "$G $C --no-verbose -m \"wip\""
checkid GB-181 allow "$G push --no-verbose origin main"
checkid GB-182 allow "$G $C --no-verbose --allow-empty -m \"release notes\""
check allow "$G $C --no-verb -m x"
check allow "$G push --no-verbos origin main"

# --- FALSE POSITIVE GB-191: `--no-verify-signatures` is a real option of `git merge`/`git pull`
#     (the negation of `--verify-signatures`), unrelated to hooks — and it is spelled with the
#     `--no-verify` prefix, so the GB-180 carve-out above did not cover it. A developer with
#     merge.verifySignatures=true merging an unsigned topic branch was blocked and told they had
#     used --no-verify. `merge` only reached this rule from GB-047 in this same cycle, so this is
#     the same defect one subcommand later. ---
checkid GB-191 allow "$G merge --no-verify-signatures topic"
check allow "$G merge --verify-signatures topic"
# unique prefixes of --no-verify-signatures: none of them can reach git's shorter --no-verify
check allow "$G merge --no-verify-s topic"
check allow "$G merge --no-verify- topic"

# the carve-outs must not reopen the rule they carve out of: these spellings really do skip hooks
check deny "$G $C --no-verify -m x"
check deny "$G $C --no-veri -m x"
check deny "$G $C --no-verif -m x"
check deny "$G push --no-verify origin main"
check deny "$G merge --no-verify topic"
check deny "$G merge --no-ver topic"

# --- FALSE POSITIVE GB-151: a bare writer NAME appearing as an ARGUMENT armed the write check
#     for the rest of the segment, so read-only commands denied. A writer is recognized at the
#     command word (after leading assignments/keywords) or as git's subcommand, nowhere else. ---
checkid GB-151 allow "grep -l cp .env"
check allow "grep -rn tee .env"
check allow "echo mv .env"
check allow "rg --files-with-matches cp .env"
check allow "awk /cp/ .env"
# and the writers themselves still deny at the command word
check deny "cp secrets.txt .env"
check deny "mv secrets.txt .env"
check deny "tee .env"
check deny "sudo cp secrets.txt .env"

# --- BYPASS GB-130..133: `${VAR}` in a redirect target or writer argument. `{`/`}` were
#     unconditional segment separators, so `> ${HOME}/.env` split into three segments and the
#     redirect lost its target. Braces now separate only where bash reads them as command
#     grouping: `{` followed by whitespace, `}` preceded by whitespace or a separator. ---
checkid GB-130 deny "cat secrets.txt > \${HOME}/.env"
checkid GB-131 deny "mv secrets.txt \${HOME}/.env"
checkid GB-132 deny "echo \"APP_KEY=abc\" | tee \${PWD}/.env"
checkid GB-133 deny "cp secrets.txt \${PWD}/.env"
check deny "cat secrets.txt > \${HOME}/.envrc"
check allow "cat secrets.txt > \${HOME}/notes.txt"
check allow "cp secrets.txt \${PWD}/backup/"
# command grouping must still segment, or `{ git push --force; }` stops being seen
check deny "{ $G push --force origin main; }"
check deny "{ $G push --force origin main;}"
check deny "echo hi; { $G $C --no-verify -m x; }"
check allow "{ echo hi; }"

# --- BYPASS GB-085/GB-101: brace EXPANSION in front of or inside the secret component. A brace
#     group containing a comma really does expand, and `cp .env{,.bak}` is everyday shell; a
#     group with no comma is `${VAR}` and is left alone. ---
checkid GB-085 deny "cp secrets.txt {.env,}"
checkid GB-101 deny "echo \"APP_KEY=abc\" | tee .en{v,v}"
check deny "cp .env{,.bak}"
check allow "cp notes.txt {out.txt,}"
check allow "cp README.md{,.bak}"
check allow "cp .env.example{,.bak}"

# --- BYPASS GB-010/011: `>|` (noclobber override) is ordinary POSIX redirection, but `|` was an
#     unconditional separator so the target landed in its own segment. ---
checkid GB-010 deny "cat secrets.txt >| .env"
checkid GB-011 deny "echo \"APP_KEY=abc\" >|.env"
check deny "cat secrets.txt 1>| .env"
# `>|` with the target GLUED: the `|` belongs to the operator, not to the filename. `>|.env`
# happened to deny anyway because `|.env` still ends in `.env`, so these two names — which do not
# — are what actually prove the operator is being parsed rather than pattern-matched.
check deny "cat secrets.txt >|.envrc"
check deny "cat secrets.txt >|.env.local"
check allow "cat secrets.txt >| notes.txt"
check allow "sort -n nums.txt | uniq -c"

# --- BYPASS GB-012: `1<>` (open read-write) written apart from its target. ---
checkid GB-012 deny "echo \"APP_KEY=abc\" 1<> .env"
check deny "echo \"APP_KEY=abc\" <> .env"
check allow "echo hi 1<> notes.txt"

# --- BYPASS GB-021/022/023: a path-qualified writer. The git rule already accepted `git` OR
#     `*/git`; the writer check required the bare name. ---
checkid GB-021 deny "/bin/cp secrets.txt .env"
checkid GB-022 deny "echo \"APP_KEY=abc\" | /usr/bin/tee .env"
checkid GB-023 deny "/bin/mv secrets.txt .env"
check deny "./bin/cp secrets.txt .env"
check allow "/bin/cp secrets.txt backup.txt"

# --- BYPASS GB-024..031: writers outside the recognized set. ---
checkid GB-024 deny "dd if=secrets.txt of=.env"
checkid GB-025 deny "install -m 600 secrets.txt .env"
checkid GB-026 deny "ln -sf /run/secrets/app.env .env"
checkid GB-027 deny "rsync -a secrets.txt .env"
checkid GB-028 deny "sed -ie \"s/a/b/\" .env"
checkid GB-030 deny "perl -pi -e \"s/a/b/\" .env"
checkid GB-031 deny "curl -o .env https://example.com/secrets"
check deny "curl --output .env https://example.com/secrets"
check deny "sed -i.bak s/a/b/ .env"
# and their ordinary, non-secret uses must not deny
check allow "dd if=/dev/zero of=disk.img"
check allow "install -d build/"
check allow "install -m 600 secrets.txt vault/creds"
check allow "ln -sf ../node_modules/.bin/eslint bin/eslint"
check allow "rsync -a src/ dist/"
check allow "sed -ie \"s/a/b/\" README.md"
check allow "perl -pi -e \"s/a/b/\" README.md"
check allow "curl -o out.json https://example.com/x"
check allow "curl -sSL https://example.com/x"

# --- BYPASS GB-040/041/042: git config keys are CASE-INSENSITIVE; the guard's pattern was not. ---
checkid GB-040 deny "$G -c core.hookspath=/dev/null $C -m x"
checkid GB-041 deny "$G -c CORE.HOOKSPATH=/dev/null $C -m x"
checkid GB-042 deny "$G -ccore.hookspath=/dev/null $C -m x"
check deny "$G -c Core.HooksPath=/dev/null push origin main"
check allow "$G -c core.pager=cat $C -m x"
check allow "$G -c user.name=x $C -m x"

# --- BYPASS GB-043/044: other ways to set the same config key. ---
checkid GB-043 deny "$G --config-env=core.hooksPath=HP $C -m x"
checkid GB-044 deny "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null $G $C -m x"
check allow "$G --config-env=user.name=UN $C -m x"
check allow "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=x $G $C -m x"

# --- BYPASS GB-045/046: `git config core.hooksPath <path>` is a PERSISTENT hook disable, more
#     durable than the `-c` form that was already blocked. Only a SET denies: reading, listing
#     and unsetting the key are harmless (unsetting it re-enables hooks). ---
checkid GB-045 deny "$G config core.hooksPath /dev/null"
checkid GB-046 deny "$G config --local core.hooksPath /dev/null"
check deny "$G config --global core.hookspath /dev/null"
check allow "$G config --get core.hooksPath"
check allow "$G config --unset core.hooksPath"
check allow "$G config core.hooksPath"
check allow "$G config -l"
check allow "$G config user.name \"Ada\""

# --- BYPASS GB-047: `git merge --no-verify` skips the pre-merge and commit-msg hooks; the rule
#     only ran for commit/push. `git merge -n` is --no-stat and must stay allowed. ---
checkid GB-047 deny "$G merge --no-verify feature"
check allow "$G merge feature"
check allow "$G merge -n feature"
check allow "$G merge --no-verbose feature"

# --- BYPASS GB-048: husky v4's hook-disabling env var. ---
checkid GB-048 deny "HUSKY_SKIP_HOOKS=1 $G $C -m x"
check allow "HUSKY_SKIP_HOOKS=1 npm test"

# --- BYPASS GB-049..054: a wrapper keyword defeated by one standard option, and wrappers that
#     were not in the list at all. Only the fixed wrapper set gets its options skipped, so an
#     arbitrary leading word still stops the search. ---
checkid GB-049 deny "sudo -u deploy $G push --force origin main"
checkid GB-050 deny "command -p $G push --force origin main"
checkid GB-051 deny "doas $G push --force origin main"
checkid GB-052 deny "timeout 60 $G push --force origin main"
checkid GB-053 deny "nice -n 10 $G push --force origin main"
checkid GB-054 deny "env -i $G push --force origin main"
check deny "timeout 30s $G $C --no-verify -m x"
check deny "sudo -u deploy env HUSKY=0 $G $C -m x"
check allow "sudo -u deploy echo $G push --force origin main"
check allow "timeout 60 npm run build"
check allow "nice -n 10 make"
check allow "env -i printenv"
check allow "doas systemctl restart nginx"
check allow "timeout 60 bash -c \"$G push --force origin main\""

# --- BYPASS GB-055: `--force-if-includes` is ancillary to `--force-with-lease`, and `--force`
#     explicitly disables the lease checks — so it must not by itself suppress the deny. ---
checkid GB-055 deny "$G push --force --force-if-includes origin main"
check allow "$G push --force-with-lease --force-if-includes origin main"
check allow "$G push --force-if-includes origin main"

# --- BYPASS GB-070/071/073: `.env`-family name gaps. ---
checkid GB-070 deny "cat secrets.txt > .envrc.local"
checkid GB-071 deny "cat secrets.txt > .env~"
checkid GB-073 deny "cat secrets.txt > .flaskenv"
check deny "cat secrets.txt > .env-production"
check deny "cp secrets.txt config/env.production"
check allow "cat notes.txt > README.md~"
check allow "cat notes.txt > .env.example~"
# GB-193/BS-192: the `.env-*`/`.env_*` deny patterns were added without the matching template forms
# on the allowlist, so `> .env.example` allowed while `> .env-example` denied. Same file, one
# separator apart. Asserted here as well as through the Write guard, because both tools share
# hooks/lib/secret-paths.sh and a fix in one must not be a fix in only one.
checkid GB-193 allow "cat notes.txt > .env-example"
check allow "cat notes.txt > .env_sample"
check allow "cp a.txt config/.env-template"
# ...and the widening is anchored to `.env`, so these still deny
check deny "cat secrets.txt > prod-example.env"
check deny "cat secrets.txt > .env-templates"
check allow "cp a.ts src/env.ts"
check allow "cp a.ts src/env.d.ts"
check allow "cp a.js src/env.mjs"

# --- BYPASS GB-192: only curl's spellings of the output option were recognized. `wget -O .env url`
#     denied, but the long form and the attached short form — the same operator, the same target,
#     the same harm — allowed. ---
checkid GB-192 deny "wget --output-document=.env https://x/y"
check deny "wget --output-document .env https://x/y"
check deny "wget -O.env https://x/y"
check deny "wget -O .env https://x/y"
check deny "curl --output=.env https://x/y"
check deny "curl -o.env https://x/y"
# and the ordinary forms stay allowed, including wget's stdout spelling `-O-`
check allow "wget -O notes.txt https://x/y"
check allow "wget --output-document=README.md https://x/y"
check allow "wget -q -O- https://x/y"
check allow "curl -o notes.txt https://x/y"

ts_report
