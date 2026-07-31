#!/usr/bin/env bash
# Gate: when bootstrap.sh cannot resolve the ref it was going to pin to, the failure must be USEFUL.
#
# The defect, found only by adopting the kit into an outside repo: the README's one documented
# command is `cd my-repo && ~/touchstone/scripts/bootstrap.sh`, which defaults to `--ref v<VERSION>`
# — and the touchstone remote has never been tagged. So the single documented adoption path exited 1
# for every user on first contact, with a one-line message that read like a typo on the adopter's
# part ("pass --ref <existing-ref>") when in fact no ref they could have typed would have been used.
#
# What is asserted here is that the message now (a) names the flags that DO work, (b) distinguishes
# a ref the adopter chose from the default it never chose, (c) distinguishes an untagged remote from
# a mistyped tag, and (d) leaves nothing behind. Row group 3 then runs the exact command the message
# printed, because guidance that has never been executed is just more prose.
#
# tests/gates/bootstrap-pin.test.sh covers the pinning mechanics; this file covers only the
# diagnostics on the failure path.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT_REPO="$(cd -P "$DIR/../.." && pwd)"
BOOTSTRAP="$KIT_REPO/scripts/bootstrap.sh"

# Hard rule 4: skip only for genuine tool absence, never for anything bootstrap.sh itself does.
if ! command -v git >/dev/null 2>&1; then
  ts_skip "bootstrap-ref-guidance" "git not available"
  ts_report
  exit 0
fi
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "bootstrap-ref-guidance" "mktemp not available"
  ts_report
  exit 0
fi

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "bootstrap-ref-guidance" "mktemp -d failed"
  ts_report
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

mkgitrepo() {
  git init -q "$1"
  git -C "$1" config user.email "touchstone-test@example.invalid"
  git -C "$1" config user.name "touchstone test"
}

# mkkit <dir> <version> — a scratch "kit" clone: a VERSION file and a stub init.sh, so bootstrap can
# get all the way to the checkout step and fail there rather than earlier for an unrelated reason.
mkkit() {
  mkgitrepo "$1"
  mkdir -p "$1/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$1/scripts/init.sh"
  chmod +x "$1/scripts/init.sh"
  echo "$2" >"$1/VERSION"
  git -C "$1" add -A
  git -C "$1" commit -q -m "c1"
}

# mktarget <dir> — a scratch adopter repo.
mktarget() {
  mkgitrepo "$1"
  echo readme >"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m init
}

# run_bootstrap <target> <kit-url> [extra args...] — capture combined output + rc.
BS_OUT=""
BS_RC=0
run_bootstrap() {
  local target="$1" url="$2"
  shift 2
  BS_OUT="$(cd "$target" && bash "$BOOTSTRAP" --url "$url" "$@" 2>&1)"
  BS_RC=$?
}

# --- group 1: the real-world case — DEFAULT ref against an UNTAGGED remote ------------------------
KIT_UNTAGGED="$TMP/kit-untagged"
mkkit "$KIT_UNTAGGED" "9.9.9"
tagcount="$(git -C "$KIT_UNTAGGED" tag --list | wc -l | tr -d ' ')"
assert_eq "positive control: the untagged kit fixture really has no tags" "0" "$tagcount"

T1="$TMP/target1"
mktarget "$T1"
run_bootstrap "$T1" "$KIT_UNTAGGED"

assert_eq "default ref against an untagged remote: exits 1" "1" "$BS_RC"
# The default ref is v<VERSION> of the kit clone the script was RUN FROM (this repo), not of the
# fixture it vendors — which is exactly the confusion the message now spells out, so assert against
# the same source the script reads rather than hard-coding a number that bump-version.sh will move.
DEFAULT_REF="v$(cat "$KIT_REPO/VERSION")"
assert_contains "names the ref it could not resolve" "$DEFAULT_REF" "$BS_OUT"
assert_contains "names where that default came from" "VERSION file of the kit clone at $KIT_REPO" "$BS_OUT"
assert_contains "says the ref was the DEFAULT, not the adopter's choice" "is the DEFAULT ref" "$BS_OUT"
assert_contains "says the remote publishes no tags at all" "publishes NO tags at all" "$BS_OUT"
assert_contains "names --ref as a way through" "--ref" "$BS_OUT"
assert_contains "names --allow-unpinned as a way through" "--allow-unpinned" "$BS_OUT"
assert_contains "states that nothing was written" "Nothing was written" "$BS_OUT"

# The rollback, asserted rather than assumed: a failed bootstrap that leaves a half-registered
# submodule behind cannot be retried, so the guidance would be useless even though it is correct.
left=""
[ -e "$T1/.touchstone" ] && left="$left .touchstone"
[ -e "$T1/.gitmodules" ] && left="$left .gitmodules"
[ -e "$T1/.git/modules/.touchstone" ] && left="$left .git/modules/.touchstone"
assert_eq "failed bootstrap leaves nothing behind" "" "$left"
dirty="$(cd "$T1" && git status --porcelain)"
assert_eq "failed bootstrap leaves the target's git status clean" "" "$dirty"

# --- group 2: the contrasting case — an EXPLICIT bad ref against a TAGGED remote -----------------
# The control for group 1: if both branches produced the same text, "publishes NO tags at all" would
# be an unconditional string rather than a diagnosis, and every assertion above would be vacuous.
KIT_TAGGED="$TMP/kit-tagged"
mkkit "$KIT_TAGGED" "1.0.0"
git -C "$KIT_TAGGED" tag "v1.0.0"
git -C "$KIT_TAGGED" tag "v0.9.0"

T2="$TMP/target2"
mktarget "$T2"
run_bootstrap "$T2" "$KIT_TAGGED" --ref "no-such-ref-xyz"

assert_eq "explicit bad ref against a tagged remote: exits 1" "1" "$BS_RC"
assert_contains "reports how many tags the remote does publish" "publishes 2 tag(s)" "$BS_OUT"
saidnotags="no"
case "$BS_OUT" in
*"publishes NO tags at all"*) saidnotags="yes" ;;
esac
assert_eq "does NOT claim the tagged remote is untagged" "no" "$saidnotags"
saiddefault="no"
case "$BS_OUT" in
*"is the DEFAULT ref"*) saiddefault="yes" ;;
esac
assert_eq "does NOT blame the default when the adopter passed --ref" "no" "$saiddefault"

# --- group 3: the printed command must actually work ---------------------------------------------
# Extract the SHA from the message's own "--ref <sha>" suggestion and run it. This is the row that
# makes the guidance a promise rather than a hint: if the suggested form ever stopped working, or
# the message stopped printing one, this fails.
T3="$TMP/target3"
mktarget "$T3"
run_bootstrap "$T3" "$KIT_UNTAGGED"
suggested="$(printf '%s\n' "$BS_OUT" | LC_ALL=C awk '/--ref [0-9a-f]+$/ { print $NF; exit }')"
have="no"
[ -n "$suggested" ] && have="yes"
assert_eq "the failure message prints a concrete --ref <sha> to copy" "yes" "$have"

if [ -n "$suggested" ]; then
  run_bootstrap "$T3" "$KIT_UNTAGGED" --ref "$suggested"
  assert_eq "the suggested --ref <sha> command succeeds" "0" "$BS_RC"
  staged="$(cd "$T3" && git ls-files -s .touchstone 2>/dev/null | awk '{print $2}')"
  expected="$(git -C "$KIT_UNTAGGED" rev-parse HEAD)"
  assert_eq "and it pins .touchstone to that exact commit" "$expected" "$staged"
else
  ts_skip "suggested --ref command" "no --ref <sha> line was printed to run"
fi

# --- group 4: --allow-unpinned is the other advertised way through, and it works ------------------
T4="$TMP/target4"
mktarget "$T4"
run_bootstrap "$T4" "$KIT_UNTAGGED" --allow-unpinned
assert_eq "--allow-unpinned against an untagged remote succeeds" "0" "$BS_RC"
assert_contains "and says it proceeded unpinned" "proceeding unpinned" "$BS_OUT"

# --- group 5: the README must not document the form that cannot work -----------------------------
# The defect was half in the script and half in the prose: the README's quick-start showed the bare
# invocation, which is exactly the command group 1 proves fails. Every bootstrap.sh invocation shown
# in a README command position must therefore carry --ref or --allow-unpinned for as long as the kit
# is untagged. Discovered from the file, not hand-listed, so a new example is checked too.
README="$KIT_REPO/README.md"
bad_lines=""
seen_lines=0
if [ -f "$README" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    seen_lines=$((seen_lines + 1))
    # skip prose mentions and comment lines; only command positions matter
    case "$line" in
    \#*) continue ;;
    esac
    case "$line" in
    *"--ref"* | *"--allow-unpinned"*) continue ;;
    esac
    bad_lines="$bad_lines|$line"
  done <<EOF
$(LC_ALL=C awk '/^[[:space:]]*[^[:space:]#]*scripts\/bootstrap\.sh/ { sub(/^[[:space:]]+/, ""); print }' "$README")
EOF
fi
# The control for the row below: a scan that matched nothing would report "" and pass while
# verifying nothing at all — the vacuity class this whole campaign is about.
found="no"
[ "$seen_lines" -gt 0 ] && found="yes"
assert_eq "control: the README scan actually found a bootstrap.sh command line" "yes" "$found"
assert_eq "README shows no bootstrap.sh command without --ref/--allow-unpinned" "" "$bad_lines"

# --- group 6: the README must not tell adopters to run the kit's own CI gates --------------------
# Companion to tests/gates/gate-scope-guard.test.sh: the gates now refuse, and the prose must not
# send anyone at them. check-sync.sh is the adopter-facing one and is deliberately exempt.
kitonly_in_readme=""
for g in check-agents check-links check-skill-quality check-skills check-standards; do
  if grep -q "\.touchstone/scripts/$g" "$README" 2>/dev/null; then
    kitonly_in_readme="$kitonly_in_readme $g"
  fi
done
assert_eq "README shows no ./.touchstone/scripts/<kit-only gate> invocation" "" "$kitonly_in_readme"
assert_contains "README does point adopters at check-sync.sh" ".touchstone/scripts/check-sync.sh" "$(cat "$README")"

ts_report
