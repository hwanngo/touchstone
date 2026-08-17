#!/usr/bin/env bash
# Gate: scripts/bootstrap.sh advertises a PINNED git submodule as its security rationale for
# preferring it over `curl | sh` (see the script's own header + standards/practices/security.md).
# That guarantee was void: `git submodule add` stages the gitlink at the default branch's HEAD,
# and the subsequent `checkout "$ref"` moved only the worktree — never re-staged — so committing
# recorded the WRONG commit and a later `git submodule update` silently reverted to unpinned HEAD.
# A missing ref was also non-fatal (silently proceeds unpinned), and a derived SSH remote URL
# landed in .gitmodules verbatim, breaking tokenless CI `submodule update`.
#
# Positive control: the scratch "kit" fixture below has TWO commits with a tag on the FIRST, so a
# gitlink correctly pinned to the tag is byte-distinguishable from one that silently reverted to
# the kit's HEAD. Without that distinction, an assertion here could pass vacuously against a
# broken script (see hard rule: "every comparison needs a control proving the comparison works").
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT_REPO="$(cd -P "$DIR/../.." && pwd)"
BOOTSTRAP="$KIT_REPO/scripts/bootstrap.sh"

# Hard rule 4: self-skip only for genuine tool absence, never for anything bootstrap.sh itself
# does — skipping on the mechanism under test is how a broken adoption path stays invisible, and
# tests/run.sh exits on failures only, so a skip here would read as green.
if ! command -v git >/dev/null 2>&1; then
  ts_skip "bootstrap-pin" "git not available"
  ts_report
  exit 0
fi
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "bootstrap-pin" "mktemp not available"
  ts_report
  exit 0
fi

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "bootstrap-pin" "mktemp -d failed"
  ts_report
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

# These rows vendor a local directory as a stand-in remote, and `git submodule add` refuses a
# local-path transport since git 2.38.1 (the CVE-2022-39253 mitigation) unless protocol.file.allow
# permits it. Scope that to an isolated config for this file only: never the real ~/.gitconfig, and
# never bootstrap.sh itself, which keeps the stricter default for real adopters. Without this the rows
# pass or fail according to whether the developer happens to have protocol.file.allow set globally.
# The SSH-shaped case below builds its own $GITCFG and passes GIT_CONFIG_GLOBAL explicitly, which
# overrides this for that one invocation — it sets protocol.file.allow itself.
GIT_CONFIG_GLOBAL="$TMP/gitconfig-base"
export GIT_CONFIG_GLOBAL
: >"$GIT_CONFIG_GLOBAL"
git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always

mkgitrepo() {
  # mkgitrepo <dir> — init a scratch repo with a local, throwaway identity (the test host may
  # have no global git user.name/user.email configured at all).
  git init -q "$1"
  git -C "$1" config user.email "touchstone-test@example.invalid"
  git -C "$1" config user.name "touchstone test"
}

# --- scratch "kit" fixture: two commits, tag on the FIRST (the positive control) -----------------
KIT_FIXTURE="$TMP/kit"
mkgitrepo "$KIT_FIXTURE"
mkdir -p "$KIT_FIXTURE/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' >"$KIT_FIXTURE/scripts/init.sh"
chmod +x "$KIT_FIXTURE/scripts/init.sh"
echo "1.2.3" >"$KIT_FIXTURE/VERSION"
git -C "$KIT_FIXTURE" add -A
git -C "$KIT_FIXTURE" commit -q -m "c1: tagged release"
TAG="v1.2.3-test"
git -C "$KIT_FIXTURE" tag "$TAG"
TAG_SHA="$(git -C "$KIT_FIXTURE" rev-parse "$TAG")"
echo "marker (kit HEAD advanced past the tag)" >"$KIT_FIXTURE/marker.txt"
git -C "$KIT_FIXTURE" add -A
git -C "$KIT_FIXTURE" commit -q -m "c2: HEAD moved past the tag"
KIT_HEAD_SHA="$(git -C "$KIT_FIXTURE" rev-parse HEAD)"

control="different"
[ "$TAG_SHA" = "$KIT_HEAD_SHA" ] && control="same"
assert_eq "positive control: kit fixture's tag SHA differs from its HEAD SHA" "different" "$control"

# --- assertion 1: bootstrapping with an explicit --ref pins to the TAG's commit, not kit HEAD ----
TARGET_GOOD="$TMP/target-good"
mkgitrepo "$TARGET_GOOD"
echo readme >"$TARGET_GOOD/README.md"
git -C "$TARGET_GOOD" add README.md
git -C "$TARGET_GOOD" commit -q -m init

good_rc=0
(cd "$TARGET_GOOD" && bash "$BOOTSTRAP" --url "$KIT_FIXTURE" --ref "$TAG") >/dev/null 2>&1 || good_rc=$?
assert_eq "bootstrap.sh --url <kit> --ref <tag> exits 0" "0" "$good_rc"

staged_sha="$(cd "$TARGET_GOOD" && git ls-files -s .touchstone 2>/dev/null | awk '{print $2}')"
assert_eq "git ls-files -s .touchstone reports the TAG's commit, not kit HEAD" "$TAG_SHA" "$staged_sha"

# --- assertion 2: a nonexistent --ref makes bootstrap.sh exit non-zero ---------------------------
TARGET_BAD="$TMP/target-bad"
mkgitrepo "$TARGET_BAD"
echo readme >"$TARGET_BAD/README.md"
git -C "$TARGET_BAD" add README.md
git -C "$TARGET_BAD" commit -q -m init

bad_rc=0
# Flags passed as explicit separate arguments below — never via an unquoted joined variable.
(cd "$TARGET_BAD" && bash "$BOOTSTRAP" --url "$KIT_FIXTURE" --ref "no-such-ref-xyz") >/dev/null 2>&1 || bad_rc=$?
nonzero="no"
[ "$bad_rc" -ne 0 ] && nonzero="yes"
assert_eq "bootstrap.sh --ref <nonexistent> exits non-zero" "yes" "$nonzero"

# --- assertion 3: a derived SSH-shaped remote lands in .gitmodules as https:// -------------------
# bootstrap.sh only normalizes a URL it DERIVES from the kit clone's own `origin` remote (an
# explicit --url is used verbatim), so this needs a kit clone whose own remote is SSH-shaped. We
# copy the fixed script into that clone (a byte-identical copy of the file under test) so its own
# `$KIT` resolves to a repo we control, without mutating this repo's real git config.
KIT_CLONE="$TMP/kit-clone"
mkdir -p "$KIT_CLONE/scripts"
cp "$BOOTSTRAP" "$KIT_CLONE/scripts/bootstrap.sh"
chmod +x "$KIT_CLONE/scripts/bootstrap.sh"
git init -q "$KIT_CLONE"
FAKE_SSH_URL="git@touchstone-fake-host.invalid:org/touchstone.git"
NORMALIZED_URL="https://touchstone-fake-host.invalid/org/touchstone.git"
git -C "$KIT_CLONE" remote add origin "$FAKE_SSH_URL"

# Redirect the NORMALIZED https URL back to the real local fixture, via a throwaway global config
# file (GIT_CONFIG_GLOBAL, scoped to this one invocation only — never touches the real ~/.gitconfig)
# so `git submodule add` can actually clone locally instead of hitting the network for a fake host.
GITCFG="$TMP/gitconfig-scratch"
git config --file "$GITCFG" protocol.file.allow always
git config --file "$GITCFG" url."file://$KIT_FIXTURE".insteadOf "$NORMALIZED_URL"

TARGET_SSH="$TMP/target-ssh"
mkgitrepo "$TARGET_SSH"
echo readme >"$TARGET_SSH/README.md"
git -C "$TARGET_SSH" add README.md
git -C "$TARGET_SSH" commit -q -m init

ssh_rc=0
(cd "$TARGET_SSH" && GIT_CONFIG_GLOBAL="$GITCFG" bash "$KIT_CLONE/scripts/bootstrap.sh" --ref "$TAG") >/dev/null 2>&1 || ssh_rc=$?
assert_eq "bootstrap.sh (SSH-shaped derived remote) exits 0" "0" "$ssh_rc"

gitmodules_content=""
[ -f "$TARGET_SSH/.gitmodules" ] && gitmodules_content="$(cat "$TARGET_SSH/.gitmodules")"
assert_contains "target .gitmodules records an https:// URL for a derived SSH remote" "https://" "$gitmodules_content"
has_ssh="no"
case "$gitmodules_content" in
*"git@"*) has_ssh="yes" ;;
esac
assert_eq "target .gitmodules does not record the raw git@ SSH URL" "no" "$has_ssh"

ts_report
