#!/usr/bin/env bash
# Gate: scripts/bump-version.sh must leave the repo in a state CI accepts.
#
# The audit's finding: bump-version.sh rewrites VERSION, every skill's metadata.version, the SKILL
# template and the plugin manifest — but not skills/CATALOG.md, which embeds the version once per
# skill (61 times in this repo) and which .github/workflows/ci.yml regenerates and `diff -q`s. So
# every bump landed CI red, and the person bumping found out from a failed pipeline rather than from
# the tool that was supposed to make a release one command instead of sixty edits.
#
# The `bump-version.sh` with no args case is a control, not a defect: it already exits 2 with a
# usage message, and the row below exists so a future "fix" cannot quietly change that.
#
# Fixtures are exercised by copying the real bump-version.sh AND the real gen-skill-catalog.sh it
# now calls into the fixture's own scripts/ dir and running from there — both scripts self-locate
# with `cd "$(dirname "${BASH_SOURCE[0]}")/.."`, so running either against a cd-ed shell would
# rewrite the version of the REAL repo.
#
# Every row is guarded by an assert_fixture precondition and by an assertion on specific content,
# not just on an exit code.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
BUMP="$KIT/scripts/bump-version.sh"
GEN="$KIT/scripts/gen-skill-catalog.sh"
FIXTURES="$KIT/tests/fixtures"

if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "bump-version" "mktemp not available"
  ts_report
  exit 0
fi

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

assert_fixture() {
  local fixture="$1" state="complete" missing="" f
  shift
  for f in "$@"; do
    if [ ! -f "$FIXTURES/$fixture/$f" ]; then missing="$missing $f"; fi
  done
  if [ -n "$missing" ]; then state="missing:$missing"; fi
  assert_eq "fixture $fixture is complete on disk" "complete" "$state"
}

# setup_tree <fixture> — materialise the fixture plus both scripts into $TREE. Returns 1 (and leaves
# TREE empty) if the fixture is absent, so a deleted fixture cannot be mistaken for a passing run.
TREE=""
setup_tree() {
  local fixture="$1"
  TREE=""
  [ -d "$FIXTURES/$fixture" ] || return 1
  WORK="$(mktemp -d 2>/dev/null || true)"
  [ -n "$WORK" ] && [ -d "$WORK" ] || return 1
  mkdir -p "$WORK/repo/scripts"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  cp "$BUMP" "$WORK/repo/scripts/bump-version.sh"
  cp "$GEN" "$WORK/repo/scripts/gen-skill-catalog.sh"
  TREE="$WORK/repo"
}

teardown_tree() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  WORK=""
  TREE=""
}

# read_file <tree-relative-path> — content, or the literal "TREE MISSING"/"FILE MISSING" so a row
# reports the real reason instead of comparing two empty strings.
read_file() {
  if [ -z "$TREE" ]; then
    echo "TREE MISSING"
    return 0
  fi
  if [ ! -f "$TREE/$1" ]; then
    echo "FILE MISSING: $1"
    return 0
  fi
  cat "$TREE/$1"
}

BUMP_RC=0
BUMP_OUT=""
run_bump() { # $@ = args passed to bump-version.sh
  if [ -z "$TREE" ]; then
    BUMP_RC=126
    BUMP_OUT="FIXTURE MISSING"
    return 0
  fi
  BUMP_RC=0
  BUMP_OUT="$(cd "$TREE" && bash scripts/bump-version.sh "$@" 2>&1 </dev/null)" || BUMP_RC=$?
}

# catalog_is_fresh — regenerates the catalog in $TREE and compares it to the committed one, i.e.
# exactly what .github/workflows/ci.yml does. Echoes "fresh" or "stale".
catalog_is_fresh() {
  local regen
  if [ -z "$TREE" ]; then
    echo "TREE MISSING"
    return 0
  fi
  regen="$(cd "$TREE" && bash scripts/gen-skill-catalog.sh 2>/dev/null)" || {
    echo "generator failed"
    return 0
  }
  if [ "$regen" = "$(cat "$TREE/skills/CATALOG.md")" ]; then echo fresh; else echo stale; fi
}

has() { # $1=needle $2=haystack
  case "$2" in
  *"$1"*) echo present ;;
  *) echo absent ;;
  esac
}

# --- the defect: a bump must not leave skills/CATALOG.md pinned to the old version --------------

assert_fixture "bump-tree" "VERSION" "skills/CATALOG.md" "skills/alpha-standards/SKILL.md" \
  "skills/beta-standards/SKILL.md" "templates/SKILL.md" ".claude-plugin/plugin.json"

setup_tree "bump-tree"
# Precondition, asserted rather than assumed: the fixture starts stale-free at the OLD version, so
# a "fresh" verdict after the bump can only come from the bump itself.
assert_eq "fixture starts at 0.1.0 with a catalog matching it" "fresh" "$(catalog_is_fresh)"
assert_eq "fixture catalog really embeds the old version" "present" "$(has 'v0.1.0' "$(read_file skills/CATALOG.md)")"

run_bump 0.2.0
assert_eq "bump 0.1.0 -> 0.2.0: exits 0" "0" "$BUMP_RC"
assert_eq "bump rewrites VERSION" "0.2.0" "$(read_file VERSION)"
assert_eq "bump rewrites every skill's metadata.version" "present" "$(has 'version: 0.2.0' "$(read_file skills/alpha-standards/SKILL.md)")"
assert_eq "bump rewrites the SKILL template" "present" "$(has 'version: 0.2.0' "$(read_file templates/SKILL.md)")"
assert_eq "bump rewrites the plugin manifest" "present" "$(has '"version": "0.2.0"' "$(read_file .claude-plugin/plugin.json)")"
# The regression itself.
assert_eq "bump regenerates skills/CATALOG.md to the new version" "present" "$(has 'v0.2.0' "$(read_file skills/CATALOG.md)")"
assert_eq "bump leaves no old version behind in the catalog" "absent" "$(has 'v0.1.0' "$(read_file skills/CATALOG.md)")"
# The claim that actually matters: CI's regenerate-and-diff step would pass.
assert_eq "after the bump, CI's regenerate-and-diff would pass" "fresh" "$(catalog_is_fresh)"
assert_contains "bump says it refreshed the catalog" "CATALOG.md" "$BUMP_OUT"
teardown_tree

# --- control: no args is already correct and must stay correct ----------------------------------

setup_tree "bump-tree"
run_bump
assert_eq "no argument: exits 2" "2" "$BUMP_RC"
assert_contains "no argument: prints the usage line" "usage:" "$BUMP_OUT"
assert_eq "no argument: VERSION is untouched" "0.1.0" "$(read_file VERSION)"
teardown_tree

setup_tree "bump-tree"
run_bump "not-a-version"
assert_eq "non-semver argument: exits 2" "2" "$BUMP_RC"
assert_eq "non-semver argument: VERSION is untouched" "0.1.0" "$(read_file VERSION)"
teardown_tree

# --- a failing regeneration must fail the bump, not silently ship a stale catalog ---------------

# A SKILL.md the generator rejects makes the catalog unbuildable. The bump has to surface that; the
# one outcome that must never happen is a zero exit alongside a catalog still pinned to the old
# version, which is the pre-fix behaviour restored by accident.
setup_tree "bump-tree"
if [ -n "$TREE" ]; then
  mkdir -p "$TREE/skills/zz-broken"
  printf 'no frontmatter\n' >"$TREE/skills/zz-broken/SKILL.md"
fi
run_bump 0.3.0
assert_eq "unbuildable catalog: the bump exits non-zero instead of claiming success" "nonzero" \
  "$(if [ "$BUMP_RC" -ne 0 ]; then echo nonzero; else echo zero; fi)"
assert_contains "unbuildable catalog: the generator's diagnostic reaches the user" "zz-broken/SKILL.md" "$BUMP_OUT"
assert_eq "unbuildable catalog: CATALOG.md is not truncated to nothing" "present" "$(has 'Skills Catalog' "$(read_file skills/CATALOG.md)")"
teardown_tree

# --- the self-adoption marker must move with the version --------------------------------------

# .touchstone.toml is what check-sync.sh keys on, and the file's own comment promises this script
# keeps its version in lockstep. That promise was false until scripts/bump-version.sh learned to
# rewrite it: the first bump after self-adoption left the marker pinned to the old version, which
# fails check-sync on the very commit that ships a release. This row is what makes the promise
# testable — reverting the sed line in bump-version.sh must turn it red.
setup_tree "bump-tree"
assert_fixture "tests/fixtures/bump-tree/.touchstone.toml"
run_bump 0.4.0
assert_eq "marker: bump exits zero" "zero" \
  "$(if [ "$BUMP_RC" -eq 0 ]; then echo zero; else echo nonzero; fi)"
assert_contains "marker: .touchstone.toml carries the new version" 'version = "0.4.0"' \
  "$(read_file .touchstone.toml)"
# Deliberately not a `case` inside $(…): the pattern's own `)` terminates the command substitution,
# which yields a row that compares literal shell text and can never fail. That mistake has now been
# made twice in this repo, so this uses a plain grep -c instead.
marker_has_old="$(printf '%s' "$(read_file .touchstone.toml)" | grep -c '"0\.1\.0"')"
assert_eq "marker: the old version is gone, not merely joined by the new one" "0" "$marker_has_old"
teardown_tree

ts_report
