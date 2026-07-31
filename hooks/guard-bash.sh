#!/usr/bin/env bash
# PreToolUse(Bash) guard: deny narrow, unambiguous policy violations. Fail-open.
#
# Pipeline: normalize continuations -> one awk pass redacts quoted spans/comments AND splits
# into command segments (quote state must span the whole buffer, not per-line, so a multi-line
# quoted string doesn't leak its closing-quote line as a bare segment) -> evaluate rules per
# segment. Redaction is load-bearing: it stops a commit message that merely MENTIONS
# --no-verify from tripping the guard, and stops an unrelated command's -f/-n from being read
# as a git flag. Segmenting on ; && || | |& & and on grouping constructs ( ) { } is what keeps
# `rm -rf dist && git push` from looking like a force-push, while still exposing the git
# command inside `( git push --force )`, `{ git push --force; }`, a `case` arm, a backgrounded
# `cmd & git push --force`, or a control-flow body (`if`/`while`/`until`/`for` ... `git push
# --force` ...). Before testing for `git`, a fixed set of shell keywords/modifiers (if then
# else elif fi while until for do done case esac in ! time command builtin exec nohup eval sudo
# env) is consumed repeatedly, so `if ! git push --force` and `sudo git push --force` are still
# caught — but only that fixed set is skipped, so `echo git push --force` (which pushes nothing)
# is correctly left alone. The command word may also carry a path (`/usr/bin/git`,
# `./bin/git`): a token matching `git` or `*/git` is the git binary. Leading
# redirections (`2>&1 git …`, `>out.log git …`) are skipped by the same loop, for the same
# reason. `&` separates only when no redirection arrow is adjacent to it, so the operators
# 2>&1, >&2, <&3, &> and &>> survive segmentation intact instead of being cut in half.
#
# NOT analyzed: command substitution ($(...) / `...`). This is an advisory guard, not a
# sandbox; consuming eval/command as leading modifiers narrows that gap incidentally but does
# not close it.
#
# EVERY rule reads a SECOND, parallel view of the same buffer: the awk pass builds
# `raw` alongside the redacted `out`, from the same scan position and the same branch decisions
# (dual-view, single-scanner — never a second pass, which could disagree with the first on
# segment counts). Quoted spans, which `out` collapses to a single Q, are kept in `raw` as their
# whitelisted content instead (`[A-Za-z0-9._/-]`; everything else, including the quote
# characters and any shell metacharacter, becomes `_`), and an outside-quote backslash-escaped
# character is kept the same way — `out` still drops both characters, unchanged. The whitelist
# is what makes this safe: `raw` can never gain a segment separator or a redirect operator that
# `out` lacks, so a quoted or backslash-escaped write target (`cat > ".env"`, `cat > \.env`) is
# recoverable without giving the raw view any power to smuggle shell structure. Because `raw`
# CAN contain a real filename inside ordinary prose (`echo "update .env" > notes.txt`), the
# secret-write check reads it positionally — actual redirect targets and tee/cp/mv/sed -i
# arguments — never as a flat token scan. Each segment's `out` line is followed immediately by
# its `raw` line in the same heredoc (see the awk END block); if the two ever end up with a
# different number of lines (a construction bug), every `raw` line degrades to empty instead of
# raising an error, and the per-segment loop then falls back to the redacted `out` line — so a
# construction bug narrows the rules to their pre-raw behaviour rather than silently switching
# them off.
#
# The GIT rules read `raw` too, and must: `out` collapses `"--force"` and `"git"` to a `Q`, so
# quoting the flag or the command word walked past both git rules entirely. Reading raw is safe
# for the same whitelist reason — no whitespace on it means a quoted span is always exactly one
# token, so a commit message can never split into flag-shaped words. See the per-segment loop.
set -uo pipefail
# Pathname expansion OFF, once, for the whole script. Every `set -- $x` below relies on WORD
# SPLITTING, which is deliberate — but unquoted expansion also globs, which made the guard's
# decisions depend on the contents of whatever directory the agent happened to be in: `cp *
# backup/` DENIED in a directory containing `local.env` and ALLOWED in one that did not, a false
# positive on an ordinary command and a source of non-reproducible measurements. Splitting was
# always wanted here; globbing never was.
set -f

HOOK_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved at runtime relative to this file; not present at lint time via -x
if ! . "$HOOK_DIR/lib/secret-paths.sh" 2>/dev/null; then
  printf '%s\n' '{"systemMessage":"touchstone: hooks/lib/secret-paths.sh missing — secret-path checks are unavailable, the Bash guard is OFF"}'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"systemMessage":"touchstone: jq not installed — the Bash guard is OFF"}'
  exit 0
fi

# STD — where the standards docs live, resolved at runtime. A deny message's job is to route the
# agent to the rule it just broke, and every one of them hard-coded `standards/…` — a path that
# exists only in the KIT. These hooks are byte-copied into adopting repos (scripts/check-sync.sh
# manages the pairs), and there the docs live in the vendored submodule with no root `standards/`,
# so every deny message pointed into thin air in the one environment the hooks are installed for.
# Resolved from the hook's own location, not $PWD, so running an agent from a subdirectory cannot
# flip it. Same runtime branch as hooks/touchstone-context.sh, for the same reason.
STD="standards"
_ts_repo="$(git -C "$HOOK_DIR" rev-parse --show-toplevel 2>/dev/null)" || _ts_repo=""
[ -n "$_ts_repo" ] || _ts_repo="$HOOK_DIR/../.."
if [ ! -d "$_ts_repo/standards" ] && [ -d "$_ts_repo/.touchstone/standards" ]; then
  STD=".touchstone/standards"
fi

cmd="$(cat | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# Valid short-flag letters per subcommand. A token counts as a flag cluster only if EVERY
# letter is valid for that subcommand — so `-ufqv` is a cluster but `-standards` is a word.
SHORT_COMMIT='amneqvsFCcpuSoizt'
# `d` (--delete) and `o` (--push-option) belong here even though neither is a bypass: a cluster
# requires EVERY letter to be valid, so an omitted letter makes the whole token "not a cluster"
# and hides the dangerous letter sitting next to it. Leaving them out meant `git push -fd origin
# topic` — a real force-delete — was not recognized as containing `-f` at all.
SHORT_PUSH='fnqvu46do'

# Value-taking short flags per subcommand: the token's letters are scanned left to right and the
# scan STOPS at the first of these, because everything after it is that flag's attached value
# rather than more flag letters — so `-mnote` is `-m note` and `-amnote` is `-am note`, neither
# of them a cluster containing `-n`.
VALUE_COMMIT='mCcFtS'
# `o` (--push-option) takes a value, so `-of` is push-option `f`, not a force-push.
VALUE_PUSH='o'

# cluster_has <token> <valid-letters> <wanted-letter> <value-taking-letters>
cluster_has() {
  local tok="$1" ok="$2" want="$3" valtaking="$4" body ch i cluster
  case "$tok" in
  -[A-Za-z]*) body="${tok#-}" ;;
  *) return 1 ;;
  esac
  case "$body" in *[!A-Za-z]*) return 1 ;; esac
  # No length cap: any fixed ceiling is defeatable by padding a real flag with harmless
  # repeated valid letters (e.g. -nqqqqqqq). A token that is all letters and every letter valid
  # for this subcommand IS a cluster, no matter how long it is.
  #
  # The value-taking test is applied at EVERY position, not just the first. Checking only
  # position 0 meant `-amnote` was read as the cluster `amnote`, so `git commit -amnote` denied
  # with a message wrongly claiming `-n` had been used — the same defect as the earlier `-mnote`
  # fix, one position over. Letters after the value-taking one are the value and are neither
  # validated nor searched.
  cluster=""
  i=0
  while [ "$i" -lt "${#body}" ]; do
    ch="${body:$i:1}"
    case "$ok" in
    *"$ch"*) ;;
    *) return 1 ;;
    esac
    cluster="$cluster$ch"
    case "$valtaking" in *"$ch"*) break ;; esac
    i=$((i + 1))
  done
  case "$cluster" in *"$want"*) return 0 ;; esac
  return 1
}

# check_secret_write <already-glued-split raw segment> — deny a Bash write whose target is a
# `.env`-family FILENAME. Scope, stated precisely because the deny message used to overclaim
# parity with the Write guard: this checks NAMES ONLY, via is_secret_path (.env, .env.*, .envrc,
# *.env, minus the *.example.*/*.sample.*/*.template.* allowlist). It does NOT read content and
# has NO private-key detection of any kind, by name or by body — only block-secrets.sh, on the
# Write/Edit tools, inspects content for private-key material.
#
# Positional, not a flat token scan: `raw` can contain a real filename inside ordinary prose
# (`echo "update .env" > x`), so only actual write targets are checked — a redirect's target, or
# tee/cp/mv/sed -i's file arguments — never every token in the segment.
check_secret_write() {
  local arg="$1" tok target body awaiting=0 cmd="" in_place=0 checking=0
  # shellcheck disable=SC2086 # deliberate word-split: an already glued-split raw segment
  set -- $arg
  for tok in "$@"; do
    if [ "$awaiting" -ne 0 ]; then
      case "$awaiting" in
      1)
        case "$tok" in
        '&'*) : ;; # fd-dup target (`> &2`) — not a file
        *)
          is_secret_path "$tok" &&
            deny "touchstone: don't write a .env-family file from Bash — the Write guard blocks these names and switching tools doesn't change the policy ($STD/practices/security.md)."
          ;;
        esac
        ;;
      *) : ;; # awaiting==2: a read source — consume it, never check it
      esac
      awaiting=0
      continue
    fi

    # Bare-operator recognition uses the SAME normalization is_redirect already performs
    # (strip a leading &, then leading fd digits) but written self-contained here — is_redirect
    # itself is not touched, since it also feeds the git path. This is what catches a spaced
    # and-redirect (`cat &> .env`) and a multi-digit fd (`cat 10> .env`): the old hardcoded
    # pattern list (`'>' | '>>' | [0-9]'>' | [0-9]'>>'`) only recognized a SINGLE leading digit
    # and never recognized `&>`/`&>>` written apart from their target at all.
    body="${tok#&}"
    while :; do
      case "$body" in
      [0-9]*) body="${body#?}" ;;
      *) break ;;
      esac
    done
    case "$body" in
    '>' | '>>' | '>&')
      awaiting=1
      continue
      ;;
    '<')
      awaiting=2 # a bare read op — the next token is the source, not a target
      continue
      ;;
    esac

    case "$tok" in
    '<'*) continue ;; # an attached read source — not this guard's business
    *'>'*)
      # operator with the target attached: the text after the LAST `>` is the target (handles
      # both `>out` and the append form `>>out`, since `>>out` ends in a single `>` right before
      # the target). Attached forms already work via this catch-all, untouched.
      target="${tok##*>}"
      case "$target" in
      '' | '&'*) : ;; # nothing attached (a bare operator handled above), or a fd-dup target
      *)
        is_secret_path "$target" &&
          deny "touchstone: don't write a .env-family file from Bash — the Write guard blocks these names and switching tools doesn't change the policy ($STD/practices/security.md)."
        ;;
      esac
      continue
      ;;
    esac

    case "$tok" in
    tee | cp | mv)
      cmd="$tok"
      checking=1
      continue
      ;;
    sed)
      cmd="sed"
      continue
      ;;
    esac

    if [ "$cmd" = sed ]; then
      case "$tok" in
      -i | -i.* | --in-place | --in-place=*) in_place=1 ;;
      esac
      [ "$in_place" -eq 1 ] && checking=1
    fi

    [ "$checking" -eq 1 ] || continue
    case "$tok" in
    -*) continue ;; # a flag, not a target
    esac
    is_secret_path "$tok" &&
      deny "touchstone: don't write a .env-family file from Bash — the Write guard blocks these names and switching tools doesn't change the policy ($STD/practices/security.md)."
  done
}

# split_glued <segment> -> echoes the segment with any glued redirect operator (`git>out`,
# `cat>.env`) split into its own token. Whitespace is not the only word terminator: bash also
# ends a word at a redirection operator, so `git>out push` really is `git` `>out` `push` and
# runs git all the same (verified: a glued redirect on the first word yields the same argv as
# the unglued form). Splitting on IFS alone leaves `git>out` as one opaque word that fails the
# `git` test, hiding every flag behind it. So break a token apart at its first `<`/`>` — but
# only when the part in front is a real word. A leading fd number or `&` belongs to the
# operator, not to a word (`2>&1`, `>&2`, `&>x`), and splitting those would strand a bare `2` or
# `&` where the command word is expected. Trailing digits on a real word are pushed onto the
# operator as its fd number: bash would read `git2>out` as the command `git2`, so this is a
# deliberate over-approximation, safe because it can only ever add a deny (or, on the raw path,
# a secret-write check) for a command word ending in a digit that is glued to a redirect.
#
# Extracted into its own function so both the git-detection path (fed `$seg`, output
# byte-identical to before) and the secret-write path (fed `$rawseg`) can reuse it. A
# command-substitution subshell for this helper is fine — nothing in it calls `deny`.
split_glued() {
  local seg="$1" tok pre split_seg=""
  # shellcheck disable=SC2086 # deliberate word-split: the segment is already redacted/whitelisted
  set -- $seg
  for tok in "$@"; do
    pre="${tok%%[<>]*}"
    case "$pre" in
    "$tok") ;;
    *[!0-9\&]*)
      case "$pre" in
      *"&")
        # A real word ending in `&`: that `&` opens an `&>`/`&>>` operator, so it belongs on the
        # operator side. It can never be mid-word, and `&>`/`&>>` take no fd number, so the
        # digit trim below must NOT run here: digits in front of this `&` are part of the real
        # word, which is what keeps `git2&>out` resolving to the nonexistent command `git2`.
        pre="${pre%?}"
        ;;
      *)
        while :; do
          case "$pre" in
          *[0-9]) pre="${pre%?}" ;;
          *) break ;;
          esac
        done
        ;;
      esac
      tok="$pre ${tok#"$pre"}"
      ;;
    esac
    split_seg="$split_seg${split_seg:+ }$tok"
  done
  printf '%s' "$split_seg"
}

# is_redirect <token>: true when the token is shell redirection plumbing rather than a command
# word — `2>&1`, `>&2`, `<&3`, `>>out.log`, `>/dev/null`, `&>x`, or a bare `>`/`>>`. On success
# REDIR_SPAN reports how many tokens the redirection occupies: 1 when the target is attached to
# the same token, 2 when the operator was written apart from its target (`> out.log`).
#
# Deliberately narrow: a token qualifies only when an optional leading `&` and an optional fd
# number are followed by `<` or `>`. Unknown words are NEVER skipped in the hunt for the git
# binary, so `echo git push …` — which prints text and pushes nothing — stays untouched.
REDIR_SPAN=1
is_redirect() {
  local tok="$1" body
  REDIR_SPAN=1
  body="${tok#&}"
  while :; do
    case "$body" in
    [0-9]*) body="${body#?}" ;;
    *) break ;;
    esac
  done
  case "$body" in
  '<'* | '>'*) ;;
  *) return 1 ;;
  esac
  case "$tok" in
  *'<' | *'>' | *'&') REDIR_SPAN=2 ;;
  esac
  return 0
}

# 1. normalize: fold backslash-newline continuations into a space
norm="${cmd//\\$'\n'/ }"

# 2. one awk pass, two accumulators: `out` (redacted — byte-identical to before this dual-view
#    was added) redacts quoted spans to Q (backslash-escape aware in "..." and $'...', but not
#    in plain '...' where backslash is literal), strips # comments (only at a token boundary; a
#    comment ends at the next newline), and splits into segments on ; && || | |& & and on
#    grouping constructs ( ) { }. `raw` is built from the SAME scan position and the SAME branch
#    decisions: a quoted span contributes its whitelisted content (scan_quoted sets the global
#    QCONTENT) instead of Q, and an outside-quote backslash-escape contributes its whitelisted
#    escaped character instead of vanishing — every other branch (separators, redirect
#    characters, plain text) appends the identical text to both, so the two views can only ever
#    diverge inside quotes or across a backslash pair. State is accumulated over the WHOLE
#    buffer in END so a quoted span may safely contain an embedded newline.
#
#    LC_ALL=C is pinned on this ONE invocation only (not exported script-wide, so nocasematch
#    matching and basename downstream keep the ambient locale). Without the pin, awk's
#    multibyte-aware substr/regex machinery calls towc() on every byte and aborts with
#    "multibyte conversion failure" on invalid or incomplete UTF-8 — which happens whenever a
#    single-byte scan position lands mid-character, guaranteed for any quoted non-ASCII text.
#    awk exits before printing anything, `segments` comes back empty, the paired `read` below
#    fails, and the per-segment loop never runs — every rule silently OFF, git rules included.
#    The scan is byte-oriented and every pattern is pure ASCII, so for any ASCII-COMPATIBLE
#    encoding (UTF-8, Latin-1, the ISO-8859 family, KOI8, …) C-locale byte semantics are exactly
#    what this program already assumes: every byte the scanner compares against — quotes,
#    backslash, `#`, the separators, the redirect characters — is a single byte with the same
#    value it has in ASCII, and no multibyte sequence can contain that byte value. The claim is
#    NOT made for an ASCII-incompatible encoding (EBCDIC, UTF-16, Shift-JIS's double-byte
#    ranges): there the pin changes meaning rather than preserving it, and this scanner would be
#    wrong with or without it. Non-ASCII bytes then just fail the whitelist and become `_` in the
#    raw view, which is correct since is_secret_path only matches ASCII
#    names. The pin makes the crash unreachable; the awk program additionally uses ZERO regex
#    match operators (index()-lookups against a constant whitelist, plain string comparisons)
#    so correctness does not depend on the pin surviving a future edit — see WL below.
segments="$(printf '%s\n' "$norm" | LC_ALL=C awk -v SQ="'" '
function scan_quoted(buf, qpos, n, escaped,   i, c, q, ec) {
  q = substr(buf, qpos, 1)
  i = qpos + 1
  QCONTENT = ""
  while (i <= n) {
    c = substr(buf, i, 1)
    if (escaped && c == "\\") {
      if (i + 1 <= n) {
        ec = substr(buf, i + 1, 1)
        QCONTENT = QCONTENT (index(WL, ec) > 0 ? ec : "_")
      }
      i += 2
      continue
    }
    if (c == q) { return i + 1 }
    QCONTENT = QCONTENT (index(WL, c) > 0 ? c : "_")
    i++
  }
  return n + 1
}
BEGIN { WL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-" }
{ buf = buf (NR > 1 ? "\n" : "") $0 }
END {
  n = length(buf)
  out = ""
  raw = ""
  i = 1
  while (i <= n) {
    c = substr(buf, i, 1)
    two = substr(buf, i, 2)
    if (c == "\\") {
      if (i + 1 <= n) {
        ec = substr(buf, i + 1, 1)
        raw = raw (index(WL, ec) > 0 ? ec : "_")
      }
      i += 2
      continue
    }
    if (two == "$" SQ) { i = scan_quoted(buf, i + 1, n, 1); out = out "Q"; raw = raw QCONTENT; continue }
    if (c == SQ) { i = scan_quoted(buf, i, n, 0); out = out "Q"; raw = raw QCONTENT; continue }
    if (c == "\"") { i = scan_quoted(buf, i, n, 1); out = out "Q"; raw = raw QCONTENT; continue }
    p = (i > 1) ? substr(buf, i - 1, 1) : ""
    if (c == "#" && (i == 1 || p == " " || p == "\t")) {
      while (i <= n && substr(buf, i, 1) != "\n") i++
      continue
    }
    if (two == "&&" || two == "||" || two == "|&") { out = out "\n"; raw = raw "\n"; i += 2; continue }
    if (c == "&") {
      # A bare & backgrounds, and so separates, a command — but & is also a character inside
      # the redirection operators 2>&1, >&2, <&3, &> and &>>. Cutting a redirection in half
      # strands the rest of the command in a segment whose first token is a redirect fragment,
      # which then fails the "first token must be the git binary" gate. So & separates only
      # when no redirection arrow is adjacent to it: nothing before it and nothing after it may
      # be > or <. This runs AFTER the two-character check above, so && and |& are still
      # consumed whole instead of being re-examined one character at a time.
      prev = (i > 1) ? substr(buf, i - 1, 1) : ""
      nxt = substr(buf, i + 1, 1)
      if (prev == ">" || prev == "<" || nxt == ">" || nxt == "<") { out = out c; raw = raw c; i++; continue }
      out = out "\n"; raw = raw "\n"; i++; continue
    }
    if (c == "|" || c == ";" || c == "\n" || c == "(" || c == ")" || c == "{" || c == "}") {
      out = out "\n"; raw = raw "\n"; i++; continue
    }
    out = out c; raw = raw c; i++
  }
  # Emission: interleaved pairs (each redacted line immediately followed by its raw line), one
  # heredoc, no sentinel. If the two views ever end up with a different number of lines (a
  # construction bug), every raw line degrades to empty instead of raising an error — the git
  # rules read only `out` and stay structurally unaffected either way.
  outn = split(out, outarr, "\n")
  rawn = split(raw, rawarr, "\n")
  if (outn == rawn) {
    for (k = 1; k <= outn; k++) { print outarr[k]; print rawarr[k] }
  } else {
    for (k = 1; k <= outn; k++) { print outarr[k]; print "" }
  }
}')"

# 3. evaluate each segment independently — each redacted line is immediately followed by its
#    raw counterpart (see the awk END block above), so reading two lines per iteration keeps
#    them paired.
while IFS= read -r seg && IFS= read -r rawseg; do
  [ -z "${seg//[[:space:]]/}" ] && continue

  # BOTH rule families read the RAW view. The redacted view collapses every quoted span to a
  # single `Q`, so `git push "--force"`, `git commit '--no-verify'`, `"git" push --force` and
  # `\git push --force` look nothing like a policy violation in it — quoting the flag or the
  # command word was a total bypass of both git rules. (The crude whole-string grep this guard
  # replaced caught that class by accident, precisely because it grepped the whole string.)
  #
  # Reading raw is safe because raw is built through a character whitelist ([A-Za-z0-9._/-]):
  # whitespace is not on it, so a quoted span can never contribute a word boundary and always
  # collapses to exactly ONE token. `-m "docs: explain why --no-verify is banned"` becomes the
  # single word `docs__explain_why_--no-verify_is_banned`, which can match neither `-*` nor
  # `--no-ver*` — that collapse, not the redaction, is what keeps prose from tripping the rules.
  # The same whitelist is why raw can never gain a segment separator or a redirect operator.
  #
  # ACCEPTED LIMIT of reading raw: a quoted message that is a SINGLE hyphen-led word of letters
  # (`git commit -m "-nope"`) is textually indistinguishable from a flag cluster and denies. A
  # message with any space, punctuation or digit in it does not.
  #
  # DEGRADATION FALLBACK: the awk END block blanks every raw line if the two views ever come back
  # with different line counts (a construction bug). Falling back to the redacted view here is
  # what stops that from silently switching the git rules OFF; it narrows them to their previous
  # behaviour instead.
  view="$rawseg"
  [ -z "${view//[[:space:]]/}" ] && view="$seg"

  split_seg="$(split_glued "$view")"
  # shellcheck disable=SC2086 # deliberate re-split: the glued redirects are now separate tokens
  set -- $split_seg

  # The secret-write rule runs on EVERY segment, before the `git` test. It used to be called only
  # in the non-git branch, which then `continue`d — so any segment whose command word was `git`
  # skipped the rule outright: `git status > .env` allowed, and so did `git config -l > .env`, a
  # plausible credential dump. One accepted false positive follows and is asserted below:
  # `git mv a.env b.env` denies, because `mv` is a write-command name wherever it appears.
  check_secret_write "$split_seg"

  # Skip leading env-var assignments AND shell keywords/modifiers before testing for `git`,
  # repeatedly and in any mix — so `if ! git push --force` (two keywords) and
  # `for f in a; do git commit --no-verify; done` (keyword after a `;`-segment) are both
  # still recognized. Only this fixed keyword set is skipped; an arbitrary leading word
  # (e.g. `echo`) is NOT skipped, so `echo git push --force` — which pushes nothing — is
  # correctly left alone.
  env_bypass=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
    HUSKY=0 | SKIP=* | PRE_COMMIT_ALLOW_NO_CONFIG=*)
      env_bypass=1
      shift
      ;;
    if | then | else | elif | fi | while | until | for | do | done | case | "esac" | in | "!" | time | command | builtin | exec | nohup | eval | sudo | env)
      shift
      ;;
    *=*) shift ;;
    *)
      # A leading redirection is plumbing the shell strips before the command word, so the git
      # binary sits after it (`2>&1 git push …`, `>out.log git …`). Skip the operator, plus its
      # target when that was written as a separate token.
      is_redirect "$1" || break
      shift
      [ "$REDIR_SPAN" -eq 2 ] && [ "$#" -gt 0 ] && shift
      ;;
    esac
  done

  # A trailing path component counts: the shell resolves `/usr/bin/git` and `./bin/git` to the
  # same binary, so requiring the token to be exactly `git` was a two-character bypass. Still
  # deliberately narrow — an arbitrary unknown word is never accepted, so `echo git push --force`
  # (which pushes nothing) stays allowed, and `mygit`/`_git` do not match either.
  case "${1-}" in
  git | */git) ;;
  *) continue ;;
  esac
  shift

  hookspath=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
    -c)
      case "${2-}" in core.hooksPath=*) hookspath=1 ;; esac
      shift
      [ "$#" -gt 0 ] && shift
      ;;
    -c*)
      case "${1#-c}" in core.hooksPath=*) hookspath=1 ;; esac
      shift
      ;;
    -C)
      shift
      [ "$#" -gt 0 ] && shift
      ;;
    --git-dir=* | --work-tree=* | --namespace=* | --exec-path=*) shift ;;
    -*) shift ;;
    *)
      # Same for a redirection sitting between `git` and its subcommand (`git 2>&1 push …`).
      is_redirect "$1" || break
      shift
      [ "$REDIR_SPAN" -eq 2 ] && [ "$#" -gt 0 ] && shift
      ;;
    esac
  done

  sub="${1-}"
  [ -n "$sub" ] && shift

  # Stop examining tokens once a literal `--` end-of-options marker is seen — everything
  # after it is a pathspec, not a flag, no matter what it looks like.
  argv=""
  while [ "$#" -gt 0 ]; do
    [ "$1" = "--" ] && break
    argv="$argv${argv:+ }$1"
    shift
  done
  # shellcheck disable=SC2086 # deliberate re-split: argv is already word-split tokens
  set -- $argv

  case "$sub" in
  commit | push)
    [ "$env_bypass" -eq 1 ] &&
      deny "touchstone: don't disable git hooks via the environment (HUSKY=0/SKIP=…) — fix the failing gate instead ($STD/practices/collaboration.md)."
    [ "$hookspath" -eq 1 ] &&
      deny "touchstone: don't bypass git hooks via -c core.hooksPath — fix the failing gate instead ($STD/practices/collaboration.md)."
    for t in "$@"; do
      case "$t" in
      --no-ver*)
        deny "touchstone: don't bypass git hooks with --no-verify — fix the failing gate instead ($STD/practices/collaboration.md)."
        ;;
      esac
    done
    ;;
  esac

  if [ "$sub" = commit ]; then
    for t in "$@"; do
      cluster_has "$t" "$SHORT_COMMIT" n "$VALUE_COMMIT" &&
        deny "touchstone: don't bypass git hooks with -n — fix the failing gate instead ($STD/practices/collaboration.md)."
    done
  fi

  if [ "$sub" = push ]; then
    force=0
    lease=0
    for t in "$@"; do
      case "$t" in
      --force-with-lease | --force-with-lease=* | --force-if-includes) lease=1 ;;
      --force) force=1 ;;
      +*) force=1 ;;
      esac
      cluster_has "$t" "$SHORT_PUSH" f "$VALUE_PUSH" && force=1
    done
    [ "$force" -eq 1 ] && [ "$lease" -eq 0 ] &&
      deny "touchstone: use 'git push --force-with-lease', never a bare --force/-f or a +refspec ($STD/practices/collaboration.md)."
  fi
done <<EOF
$segments
EOF

exit 0
