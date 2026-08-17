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
# doas env timeout nice) is consumed repeatedly, so `if ! git push --force` and `sudo git push
# --force` are still caught — and, for the WRAPPERS in that set only, their leading options are
# consumed too (`sudo -u deploy`, `env -i`, `timeout 60`), since one standard option used to end
# the search short of the git binary. Only that fixed set is skipped, so `echo git push --force`
# (which pushes nothing) is correctly left alone. The command word may also carry a path
# (`/usr/bin/git`, `./bin/git`): a token matching `git` or `*/git` is the git binary. Leading
# redirections (`2>&1 git …`, `>out.log git …`) are skipped by the same loop, for the same
# reason.
#
# THREE separators are conditional, because each of them is also an ordinary character INSIDE a
# token, and splitting there tore a write command away from its target:
#   * `&` separates only when no redirection arrow is adjacent, so 2>&1, >&2, <&3, &> and &>>
#     survive segmentation intact instead of being cut in half.
#   * `|` does not separate when a `>` precedes it: `>|` is the noclobber-override redirection
#     operator, not a pipe (`||` and `|&` are consumed whole earlier, so nothing else can reach
#     that branch with a `>` in front).
#   * `{` and `}` separate only where bash reads them as command GROUPING — `{` followed by
#     whitespace, `}` preceded by whitespace or another separator. Splitting unconditionally
#     turned `> ${HOME}/.env` into three segments with no redirect target left in any of them,
#     and did the same to `cp secrets.txt {.env,}`. Both are ordinary, non-adversarial shell.
#
# NOT analyzed: command substitution ($(...) / `...`), and ANSI-C quoting ($'\x2d\x2dforce'),
# which the shell decodes to a different string than the one written. This is an advisory guard,
# not a sandbox; consuming eval/command as leading modifiers narrows that gap incidentally but
# does not close it. See hooks/README.md for the full list of accepted limits and why decoding
# escape sequences here would mean interpreting the shell rather than matching its tokens.
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
# secret-write check reads it positionally — actual redirect targets, and the arguments of a
# writer recognized AT THE COMMAND WORD — never as a flat token scan. Each segment's `out` line
# is followed immediately by
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

# is_hookspath_key <token> — is this git's `core.hooksPath` config key, with or without an
# attached `=value`?
#
# GIT CONFIG KEY NAMES ARE CASE-INSENSITIVE (`git -c core.hookspath=X config --get core.hooksPath`
# returns X), and the guard's pattern was not — so a one-character change of case walked past the
# hook-bypass rule entirely. Spelled as bracket classes rather than by toggling `nocasematch`
# because this runs on the hot path of every segment and must not disturb shell state the rest of
# the guard reads; `[.]` is a literal dot, not the any-character wildcard a bare `.` would be.
is_hookspath_key() {
  case "$1" in
  [Cc][Oo][Rr][Ee][.][Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh] | \
    [Cc][Oo][Rr][Ee][.][Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]=*) return 0 ;;
  esac
  return 1
}

# takes_value <subcommand> <token> — does this git flag take its value as the NEXT word?
#
# Only the separate-word forms are listed. A flag whose value must be ATTACHED
# (`--force-with-lease=ref`, `-S<keyid>`) is deliberately absent: consuming the following word
# for one of those would swallow a real flag. `--force-with-lease` in particular must never be
# here — it is a bare flag as often as it is a valued one.
takes_value() {
  case "$2" in
  -m | --message | -F | --file | --author | --date | --cleanup | --trailer | --pathspec-from-file)
    return 0
    ;;
  esac
  case "$1" in
  commit)
    case "$2" in
    -C | --reuse-message | -c | --reedit-message | -t | --template | --fixup | --squash) return 0 ;;
    esac
    ;;
  push)
    case "$2" in
    -o | --push-option | --repo | --receive-pack | --exec) return 0 ;;
    esac
    ;;
  merge)
    case "$2" in
    -s | --strategy | -X | --strategy-option | --into-name) return 0 ;;
    esac
    ;;
  esac
  return 1
}

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

# is_secret_target <token> — is_secret_path, plus ONE brace-expansion group resolved.
#
# `cp .env{,.bak}` and `cp secrets.txt {.env,}` really do write a .env-family file, and
# `cp file{,.bak}` is everyday shell, not an exotic construct. A group is only expanded when it
# contains a COMMA: `${HOME}/.env` also has braces but is parameter expansion, and its basename
# already answers the question. A `$` immediately before the brace settles it either way.
#
# Deliberately one group, no nesting, no ranges — an over-approximation would be free to invent
# a secret-shaped name that the shell would never produce, and this predicate only ever ADDS
# denials.
is_secret_target() {
  local t="$1" pre post grp alt oldifs
  case "$t" in
  *'{'*','*'}'*) ;;
  *)
    is_secret_path "$t"
    return
    ;;
  esac
  pre="${t%%\{*}"
  case "$pre" in
  *'$')
    is_secret_path "$t" # ${...} — parameter expansion, not brace expansion
    return
    ;;
  esac
  # The unexpanded token is NOT tested here. `.env.example{,.bak}` matches `.env.*` with the
  # brace text still attached but misses the `*.example.*` allowlist, so testing it as written
  # would deny a template-to-backup copy — the exact false positive the allowlist exists to
  # prevent. Only what the shell would actually produce is judged.
  post="${t#*\}}"
  grp="${t#*\{}"
  grp="${grp%%\}*}"
  # An EMPTY alternative is the whole point of the `{,.bak}` idiom, and word splitting drops a
  # trailing empty field — so the `pre$post` candidate is tested explicitly rather than relying
  # on the split to produce it.
  is_secret_path "$pre$post" && return 0
  oldifs="$IFS"
  IFS=,
  # shellcheck disable=SC2086 # deliberate split on comma: these are the brace alternatives
  set -- $grp
  IFS="$oldifs"
  for alt in "$@"; do
    [ -n "$alt" ] || continue
    is_secret_path "$pre$alt$post" && return 0
  done
  return 1
}

check_secret_write() {
  local arg="$1" tok target body awaiting=0 wcmd="" in_place=0 checking=0
  local cmdword=1 kw=0 subwriter=0 msg
  msg="touchstone: don't write a .env-family file from Bash — the Write guard blocks these names and switching tools doesn't change the policy ($STD/practices/security.md)."
  # shellcheck disable=SC2086 # deliberate word-split: an already glued-split raw segment
  set -- $arg
  for tok in "$@"; do
    if [ "$awaiting" -ne 0 ]; then
      case "$awaiting" in
      1)
        case "$tok" in
        '&'*) : ;; # fd-dup target (`> &2`) — not a file
        *) is_secret_target "$tok" && deny "$msg" ;;
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
    # and never recognized `&>`/`&>>` written apart from their target at all. `>|` (noclobber
    # override) and `<>` (open read-write) are here for the same reason: both write, and both
    # were read as "not a redirect at all" when written apart from their target.
    body="${tok#&}"
    while :; do
      case "$body" in
      [0-9]*) body="${body#?}" ;;
      *) break ;;
      esac
    done
    case "$body" in
    '>' | '>>' | '>&' | '>|' | '<>')
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
      # the target). A leading `|` left over from `>|.env` belongs to the operator, not the name.
      target="${tok##*>}"
      target="${target#|}"
      case "$target" in
      '' | '&'*) : ;; # nothing attached (a bare operator handled above), or a fd-dup target
      *) is_secret_target "$target" && deny "$msg" ;;
      esac
      continue
      ;;
    esac

    # WRITER RECOGNITION IS POSITIONAL. A bare `cp`/`mv`/`tee` appearing as an ARGUMENT used to
    # arm the check for the rest of the segment, so `grep -l cp .env` — a read — denied. A writer
    # counts at the command word (after any leading assignments, keywords and wrapper options),
    # or as git's subcommand, and nowhere else. `git` is NOT one of the recognized subcommand
    # dispatchers — see the note on the `busybox`/`toybox` arm below for why `git mv a.env b.env`
    # is ALLOWED, and the `checkid GB-150 allow` row that asserts it.
    #
    # A trailing path component counts, exactly as it does for the git binary: `/bin/cp` is cp.
    if [ "$cmdword" -eq 1 ] || [ "$subwriter" -eq 1 ]; then
      if [ "$cmdword" -eq 1 ]; then
        case "$tok" in
        *=*) continue ;; # a leading assignment — the command word is still ahead
        if | then | else | elif | fi | while | until | for | do | done | case | "esac" | in | "!" | \
          time | command | builtin | exec | nohup | eval | sudo | doas | env | timeout | nice)
          kw=1
          continue
          ;;
        -*)
          # An option belonging to one of those wrappers (`sudo -u deploy cp …`). Only ever
          # skipped when a wrapper keyword actually preceded it, so an ordinary command's flags
          # cannot walk the search forward.
          [ "$kw" -eq 1 ] && continue
          ;;
        esac
      fi
      cmdword=0
      subwriter=0
      case "$tok" in
      tee | cp | mv | install | rsync | ln | */tee | */cp | */mv | */install | */rsync | */ln)
        wcmd="cp"
        checking=1
        continue
        ;;
      sed | */sed)
        wcmd="sed"
        continue
        ;;
      perl | */perl | ruby | */ruby)
        wcmd="perl"
        continue
        ;;
      dd | */dd)
        wcmd="dd"
        continue
        ;;
      curl | */curl | wget | */wget)
        wcmd="fetch"
        continue
        ;;
      busybox | */busybox | toybox | */toybox)
        # A multi-call SHELL-UTILITY dispatcher: the writer is the next word, and
        # "busybox cp secrets.txt .env" really is cp. It denied before only by accident — because
        # a writer name ANYWHERE in the segment used to arm the check, which is the same defect
        # that wrongly denied the read-only "grep -l cp .env".
        #
        # `git` is deliberately NOT in this list, though it was at first. "git mv" is not cp: it
        # renames a file git already TRACKS, so no secret content enters the repo that was not
        # already in it, and `git mv old.env new.env` was denied with a message claiming a
        # .env-family file was being written from Bash. It is not. The rule that motivated
        # checking git-led segments at all is untouched, because it never ran through this path:
        # `git status > .env` and `git config -l > .env` are REDIRECTS, handled above, and both
        # still deny.
        subwriter=1
        continue
        ;;
      esac
      continue # some other command — this segment has no writer
    fi

    case "$wcmd" in
    sed)
      # `-i`, `-i.bak` AND `-ie`: an attached backup suffix with no dot is still in-place, and
      # missing it let `sed -ie "s/a/b/" .env` through.
      case "$tok" in
      -i* | --in-place | --in-place=*) in_place=1 ;;
      esac
      [ "$in_place" -eq 1 ] && checking=1
      ;;
    perl)
      # perl/ruby cluster their switches (`-pi`, `-pi.bak`, `-w -i -e`), so any single-dash
      # cluster containing `i` is in-place. Over-approximating here only ARMS the check; a
      # secret-shaped filename still has to follow for anything to be denied.
      case "$tok" in
      --in-place | --in-place=*) in_place=1 ;;
      --*) : ;;
      -*i*) in_place=1 ;;
      esac
      [ "$in_place" -eq 1 ] && checking=1
      ;;
    dd)
      case "$tok" in
      of=*) is_secret_target "${tok#of=}" && deny "$msg" ;;
      esac
      continue
      ;;
    fetch)
      # curl and wget spell the same thing four ways each, and only curl's were handled: wget's
      # long form (`--output-document=.env`) and its attached short form (`-O.env`) both allowed
      # while the separate-word `wget -O .env` denied. Same operator, same target, same harm.
      # `-O*` must be tested BEFORE `-o*` would be reached — the two are distinct options and the
      # arms below keep them distinct — and both attached arms are listed after the bare-operator
      # arm so `-o`/`-O` alone still take the following word instead of being read as an attached
      # target of the empty string.
      case "$tok" in
      -o | -O | --output | --output-document) awaiting=1 ;;
      --output=*) is_secret_target "${tok#--output=}" && deny "$msg" ;;
      --output-document=*) is_secret_target "${tok#--output-document=}" && deny "$msg" ;;
      -o*) is_secret_target "${tok#-o}" && deny "$msg" ;;
      -O*) is_secret_target "${tok#-O}" && deny "$msg" ;;
      esac
      continue
      ;;
    esac

    [ "$checking" -eq 1 ] || continue
    case "$tok" in
    -*) continue ;; # a flag, not a target
    esac
    is_secret_target "$tok" && deny "$msg"
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
function wl(s,   r, k, ch) {
  r = ""
  for (k = 1; k <= length(s); k++) {
    ch = substr(s, k, 1)
    r = r (index(WL, ch) > 0 ? ch : "_")
  }
  return r
}
# skip_heredoc_body: from pos (the first character of the line AFTER the heredoc command line),
# consume whole lines until the terminator line, and return the position just past it. A heredoc
# with no terminator runs to the end of the buffer, which is exactly what the shell does with it.
# It can only be REACHED for a delimiter that has_delim_line() already proved terminates, so the
# run-to-end branch is now unreachable for a registered heredoc; it is kept because "consume to
# the end" is still the right answer if it ever is reached.
function skip_heredoc_body(b, pos, nn, d, strip,   line, e, s) {
  while (pos <= nn) {
    e = index(substr(b, pos), "\n")
    if (e == 0) { line = substr(b, pos); e = nn - pos + 2 } else { line = substr(b, pos, e - 1) }
    s = line
    if (strip) { while (substr(s, 1, 1) == "\t") s = substr(s, 2) }
    pos = pos + e
    if (s == d) { return pos }
  }
  return pos
}
# has_delim_line: is there a line at or after pos that is exactly the delimiter d (after the
# <<- tab strip)? This is the SAFETY NET for a mis-detected heredoc operator, and it is what
# turns the worst-case outcome from an UNBOUNDED FALSE NEGATIVE into no change at all.
#
# A heredoc whose terminator is nowhere in the buffer is, in a Claude Code Bash payload, never a
# real heredoc: the shell would sit waiting on stdin, so the command as written could not run.
# It is therefore either a mis-parse (`$((1<<3))` yielding the delimiter `3` — see the arithmetic
# note in the scanner) or a deliberate attempt to make the body-skip swallow the rest of the
# command. Registering it swallows every following line silently, with no error and no exit
# status to notice; declining to register it leaves those lines to be analyzed exactly as they
# were before heredoc handling existed. So: no terminator, no heredoc. The failure mode is
# pushed to the SAFE side — the guard can now only ever mis-analyze prose that is provably
# followed by its own terminator line, which is the bounded false positive the body-skip exists
# to prevent, never a silent hole.
#
# The scan starts at pos, i.e. from the heredoc OPERATOR, not from the body: a delimiter that
# only appears earlier in the buffer cannot terminate this body, and starting here keeps the
# check independent of how many other heredocs share the command line.
function has_delim_line(b, pos, nn, d, strip,   line, e, s) {
  while (pos <= nn) {
    e = index(substr(b, pos), "\n")
    if (e == 0) { line = substr(b, pos); e = nn - pos + 2 } else { line = substr(b, pos, e - 1) }
    s = line
    if (strip) { while (substr(s, 1, 1) == "\t") s = substr(s, 2) }
    pos = pos + e
    if (s == d) { return 1 }
  }
  return 0
}
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
    # ARITHMETIC CONTEXT. Inside `$(( … ))` / `(( … ))` a `<<` is the LEFT-SHIFT operator, not a
    # heredoc operator. Tracked here, in the scanner, for exactly the reason quote state is:
    # this is the only place that knows the `((` is not itself inside a quoted string, a comment,
    # or behind a backslash — each of those branches `continue`s above, so their characters never
    # reach this counter.
    #
    # `arith` counts the OPEN PARENS belonging to the arithmetic context, so nested parens
    # (`$(( (1<<3) | (1<<4) ))`) close it at the right place, and it is >0 for exactly the span
    # between the opening `((` and its matching `))`.
    #
    # Opening requires `((` in a position where bash actually reads arithmetic: after `$`, or at
    # the start of a command (start of buffer, whitespace, newline, or a separator). `foo((`,
    # `a=((` — arithmetic in no shell — do not open it. That restraint matters in the OTHER
    # direction from the bug this fixes: a spuriously-open arith would stop a REAL heredoc from
    # being detected and get its prose body scanned as command text, which is the bounded false
    # positive the body-skip exists to prevent.
    if (arith > 0) {
      if (c == "(") arith++
      else if (c == ")") arith--
    } else if (two == "((" && (p == "$" || p == "" || p == " " || p == "\t" || p == "\n" ||
                               p == ";" || p == "&" || p == "|")) {
      arith = 1
    }
    if (two == "<<" && substr(buf, i, 3) != "<<<" && arith == 0) {
      # HEREDOC OPERATOR. The body of a heredoc is DATA the shell feeds to a command on stdin —
      # it is never command text. Analyzing it line by line (a newline is a segment separator)
      # meant a line of documentation prose inside `<<EOF` was denied for describing a banned
      # command: `cat <<EOF > docs/policy.md` with a body explaining that force-pushing is banned
      # was blocked, which is writing the very docs this kit ships.
      #
      # Detected HERE, inside the scanner, and nowhere else: the scanner is the only place that
      # knows quote state, and a `<<` inside a quoted string (`echo "a << b"`) must not start a
      # heredoc. A pre-pass over the raw text could not tell those apart, and mis-detecting one
      # would swallow following lines of real command text — a silent hole in the guard.
      #
      # The COMMAND LINE is still analyzed in full, so `cat <<EOF > .env` still denies on its
      # redirect target; only the body lines are dropped. `<<<` is a here-STRING with no body.
      #
      # TWO GUARDS make the "mis-detecting one would swallow real command text" hazard above
      # unreachable rather than merely acknowledged, because it was NOT unreachable: `$((1<<3))`
      # parsed as a heredoc with delimiter `3` (the delimiter scan below stops at `)`), no line
      # ever equalled `3`, and the body-skip therefore consumed the whole rest of the buffer —
      # every following command line dropped before any rule saw it, silently.
      #   1. `arith == 0` in the condition above: inside `$(( … ))`/`(( … ))` this is left-shift.
      #   2. has_delim_line() below: a delimiter with no terminator line anywhere ahead is not a
      #      heredoc at all. Both are needed — (1) is the precise rule, (2) is the net that
      #      catches any other spelling that reaches here by mistake.
      hdj = i + 2
      hdstrip = 0
      if (substr(buf, hdj, 1) == "-") { hdstrip = 1; hdj++ }
      while (hdj <= n && (substr(buf, hdj, 1) == " " || substr(buf, hdj, 1) == "\t")) hdj++
      hdq = substr(buf, hdj, 1)
      hddelim = ""
      if (hdq == SQ || hdq == "\"") {
        hdj++
        while (hdj <= n && substr(buf, hdj, 1) != hdq) { hddelim = hddelim substr(buf, hdj, 1); hdj++ }
        hdj++
        hdout = "Q"
      } else {
        while (hdj <= n) {
          hdc = substr(buf, hdj, 1)
          if (hdc == " " || hdc == "\t" || hdc == "\n" || hdc == ";" || hdc == "&" ||
              hdc == "|" || hdc == ">" || hdc == "<" || hdc == "(" || hdc == ")") break
          if (hdc == "\\") { hdj++; if (hdj > n) break; hdc = substr(buf, hdj, 1) }
          hddelim = hddelim hdc
          hdj++
        }
        hdout = hddelim
      }
      if (hddelim != "" && has_delim_line(buf, i, n, hddelim, hdstrip)) {
        hd_n++
        hd_delim[hd_n] = hddelim
        hd_strip[hd_n] = hdstrip
        # Emit exactly what the previous scanner emitted for this operator, so the command line
        # tokenizes identically: `<<` verbatim, then the delimiter as Q when it was quoted.
        out = out "<<" hdout
        raw = raw "<<" wl(hddelim)
        i = hdj
        continue
      }
    }
    if (c == "\n" && hd_n > 0) {
      # End of the heredoc command line: every pending body, in the order the operators appeared.
      out = out "\n"; raw = raw "\n"
      i++
      for (hdk = 1; hdk <= hd_n; hdk++) i = skip_heredoc_body(buf, i, n, hd_delim[hdk], hd_strip[hdk])
      hd_n = 0
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
    if (c == "|") {
      # `>|` is the noclobber-override REDIRECTION OPERATOR, not a pipe. Splitting there put
      # `cat secrets.txt >` and `.env` in different segments, so the redirect lost its target and
      # nothing was checked. `||` and `|&` are already consumed whole above, so the only way to
      # reach here with a `>` in front is a real `>|`.
      prev = (i > 1) ? substr(buf, i - 1, 1) : ""
      if (prev == ">") { out = out c; raw = raw c; i++; continue }
      out = out "\n"; raw = raw "\n"; i++; continue
    }
    if (c == "{") {
      # `{` separates only where bash reads it as command GROUPING, which requires it to be its
      # own word: `{ cmd; }`. Splitting unconditionally meant `> ${HOME}/.env` became three
      # segments — the redirect lost its target — and `cp secrets.txt {.env,}` lost its. Both are
      # ordinary, non-adversarial shell. A `{` followed by anything other than whitespace opens a
      # parameter expansion or a brace expansion and belongs INSIDE the token.
      nxt = substr(buf, i + 1, 1)
      if (nxt != " " && nxt != "\t" && nxt != "\n" && nxt != "") { out = out c; raw = raw c; i++; continue }
      out = out "\n"; raw = raw "\n"; i++; continue
    }
    if (c == "}") {
      # The closing half of the same rule: `}` is a reserved word only at the start of a command,
      # so it separates only when what precedes it is whitespace or another separator. `${HOME}`
      # and `.en{v,v}` close a token instead.
      prev = (i > 1) ? substr(buf, i - 1, 1) : ""
      if (prev == "" || prev == " " || prev == "\t" || prev == "\n" || prev == ";" ||
          prev == "&" || prev == "|" || prev == "(" || prev == ")") {
        out = out "\n"; raw = raw "\n"; i++; continue
      }
      out = out c; raw = raw c; i++; continue
    }
    if (c == ";" || c == "\n" || c == "(" || c == ")") {
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
  # This is no longer an accepted limit for a FLAG VALUE. A quoted message that is a single
  # hyphen-led word of letters (`git commit -m "-nope"`) used to be indistinguishable from a flag
  # cluster and denied; the value of a value-taking flag is now consumed rather than scanned, so it
  # allows — see `takes_value` below and the `checkid GB-158 allow` row. What still denies is a
  # violation somewhere else in the same command (`git commit --no-verify -m "-nope"`), which is
  # correct: the message was never the reason.
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
  hookspath=0
  # wrapper/wrapper_val/wrapper_dur: a leading command WRAPPER (sudo, env, timeout, …) was in the
  # skip list, but the loop only skipped the bare keyword — so one standard option
  # (`sudo -u deploy`, `env -i`, `command -p`) left a `-u`/`-i`/`-p` where the git binary was
  # expected and the search stopped there. Options are now skipped, but ONLY while a wrapper
  # keyword actually precedes them: an arbitrary leading word still stops the search, which is
  # what keeps `echo git push --force` (which pushes nothing) allowed.
  wrapper=0
  wrapper_val=""
  wrapper_dur=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
    HUSKY=0 | HUSKY_SKIP_HOOKS=* | SKIP=* | PRE_COMMIT_ALLOW_NO_CONFIG=*)
      env_bypass=1
      shift
      ;;
    GIT_CONFIG_KEY_[0-9]*=*)
      # GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n set config from the environment,
      # and all three matched the generic assignment arm below without ever being read. Pointing
      # core.hooksPath somewhere from there is the same bypass as `-c core.hooksPath=`.
      is_hookspath_key "${1#*=}" && hookspath=1
      shift
      ;;
    sudo | doas | env | command | timeout | nice | nohup | */sudo | */doas | */env | */timeout | */nice | */nohup)
      wrapper=1
      wrapper_dur=0
      wrapper_val=""
      case "$1" in
      sudo | */sudo | doas | */doas) wrapper_val="ugpCUrth" ;;
      env | */env) wrapper_val="uCS" ;;
      timeout | */timeout)
        wrapper_val="sk"
        wrapper_dur=1
        ;;
      nice | */nice) wrapper_val="n" ;;
      esac
      shift
      ;;
    if | then | else | elif | fi | while | until | for | do | done | case | "esac" | in | "!" | time | builtin | exec | eval)
      wrapper=0
      shift
      ;;
    *=*) shift ;;
    -*)
      # An option belonging to the wrapper in front of it. A value-taking short flag consumes the
      # next token too — which flags those are depends on WHICH wrapper, because `sudo -p` takes
      # a prompt while `command -p` takes nothing, and getting that backwards would swallow the
      # git binary itself.
      [ "$wrapper" -eq 1 ] || break
      case "$1" in
      -[A-Za-z])
        case "$wrapper_val" in
        *"${1#-}"*)
          shift
          [ "$#" -gt 0 ] && shift
          ;;
        *) shift ;;
        esac
        ;;
      *) shift ;;
      esac
      ;;
    *)
      # A leading redirection is plumbing the shell strips before the command word, so the git
      # binary sits after it (`2>&1 git push …`, `>out.log git …`). Skip the operator, plus its
      # target when that was written as a separate token. `timeout`'s DURATION is the one bare
      # word any wrapper takes as an operand, and it is consumed once, only for `timeout`.
      if is_redirect "$1"; then
        shift
        [ "$REDIR_SPAN" -eq 2 ] && [ "$#" -gt 0 ] && shift
      elif [ "$wrapper_dur" -eq 1 ]; then
        case "$1" in
        [0-9]*)
          wrapper_dur=0
          shift
          ;;
        *) break ;;
        esac
      else
        break
      fi
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

  while [ "$#" -gt 0 ]; do
    case "$1" in
    -c)
      is_hookspath_key "${2-}" && hookspath=1
      shift
      [ "$#" -gt 0 ] && shift
      ;;
    -c*)
      is_hookspath_key "${1#-c}" && hookspath=1
      shift
      ;;
    --config-env=*)
      # `--config-env=<key>=<envvar>` (git >= 2.31) sets config from an env var and fell into the
      # generic `-*` arm, so the key was never looked at.
      is_hookspath_key "${1#--config-env=}" && hookspath=1
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
  #
  # A VALUE is not a flag either. `git commit -m "-nope"` denied with the message "don't bypass
  # git hooks with -n" — but `-nope` is the commit MESSAGE, so that was a block on an ordinary
  # commit plus a false statement about which flag caused it: the same defect class as the
  # `--no-verbose` false positive. The attached form (`-mnote`) was already handled by
  # VALUE_COMMIT inside cluster_has; this is the separate-word form, which nothing handled.
  # Dropping the value cannot hide a real bypass, because the shell hands that word to git as
  # data: `git push -o --force` sets a push-option string and force-pushes nothing, and
  # `git commit -m --no-verify` commits with that message and runs every hook.
  argv=""
  while [ "$#" -gt 0 ]; do
    [ "$1" = "--" ] && break
    argv="$argv${argv:+ }$1"
    if takes_value "$sub" "$1"; then
      shift
      [ "$#" -gt 0 ] && [ "$1" != "--" ] && shift
      continue
    fi
    shift
  done
  # shellcheck disable=SC2086 # deliberate re-split: argv is already word-split tokens
  set -- $argv

  case "$sub" in
  commit | push | merge)
    [ "$env_bypass" -eq 1 ] &&
      deny "touchstone: don't disable git hooks via the environment (HUSKY=0/SKIP=…) — fix the failing gate instead ($STD/practices/collaboration.md)."
    [ "$hookspath" -eq 1 ] &&
      deny "touchstone: don't bypass git hooks by pointing core.hooksPath elsewhere — fix the failing gate instead ($STD/practices/collaboration.md)."
    for t in "$@"; do
      case "$t" in
      # `--no-verbose` is parse-options AUTO-NEGATION of `-v/--verbose` and has nothing to do with
      # hooks — but `--no-ver*` denied it, and told the user it had used `--no-verify`: a block
      # AND a lie about why, on an ordinary command. `--no-verb` is the shortest prefix that
      # belongs to `--no-verbose` and not to `--no-verify`.
      --no-verb*) : ;;
      # `--no-verify-signatures` is the SAME defect, and it survived the fix above because it is
      # spelled with the `--no-verify` prefix. It is a real option of `git merge` and `git pull`
      # (the negation of `--verify-signatures`), it has nothing to do with hooks, and `merge`
      # joined the subcommand set in this cycle — so a developer with `merge.verifySignatures=true`
      # merging an unsigned topic branch was blocked and told they had used `--no-verify`.
      #
      # The carve-out is `--no-verify-` PLUS ANYTHING (including nothing): every such spelling is
      # either `--no-verify-signatures` or a unique prefix of it, and none of them can reach
      # git's `--no-verify`, which is a shorter string and therefore not prefixed by any of them.
      # `--no-verify` itself, and its ambiguous-but-unique-enough abbreviations `--no-veri` /
      # `--no-verif`, do NOT match this arm and stay denied — those are the spellings that really
      # do skip hooks. That is why this is a change to the MATCHER and not to the message.
      --no-verify-*) : ;;
      --no-ver*)
        deny "touchstone: don't bypass git hooks with --no-verify — fix the failing gate instead ($STD/practices/collaboration.md)."
        ;;
      esac
    done
    ;;
  config)
    # `git config core.hooksPath <path>` PERSISTS the bypass in the repo's config — strictly more
    # durable than the `-c` form that was already blocked, and never examined because only
    # commit/push were. Only a SET denies: `--get`/`--list` are reads, and `--unset` re-enables
    # hooks, so denying either would block the fix rather than the bypass.
    cfg_read=0
    cfg_key=0
    cfg_val=0
    for t in "$@"; do
      case "$t" in
      --get | --get-all | --get-regexp | --get-urlmatch | --get-color | --get-colorbool | \
        --list | -l | --unset | --unset-all | --name-only | --remove-section | --rename-section | \
        --edit | -e)
        cfg_read=1
        ;;
      esac
      if [ "$cfg_key" -eq 1 ]; then
        case "$t" in
        -*) : ;;
        *) cfg_val=1 ;;
        esac
      elif is_hookspath_key "$t"; then
        cfg_key=1
        case "$t" in *=*) cfg_val=1 ;; esac
      fi
    done
    [ "$cfg_read" -eq 0 ] && [ "$cfg_key" -eq 1 ] && [ "$cfg_val" -eq 1 ] &&
      deny "touchstone: don't bypass git hooks by pointing core.hooksPath elsewhere — fix the failing gate instead ($STD/practices/collaboration.md)."
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
      # ONLY --force-with-lease grants a lease. git-push(1) documents --force-if-includes as an
      # ancillary option to --force-with-lease, and --force explicitly disables the lease checks —
      # so `--force --force-if-includes` is a full unleased force push that the guard was reading
      # as leased. On its own --force-if-includes is a no-op and never sets `force`, so dropping
      # it here does not deny anything it used to allow.
      --force-with-lease | --force-with-lease=*) lease=1 ;;
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
