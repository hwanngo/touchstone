#!/usr/bin/env bash
# Gate: scripts/gen-skill-catalog.sh must never fail silently, and must never drop a skill from the
# body while still counting it in the header.
#
# The audit's finding, reproduced before this file was written: the generator exits 0 normally (80
# lines) and exits 1 on any skills/*/SKILL.md that has no frontmatter or is empty — printing NOTHING
# AT ALL, to stdout or stderr. Traced with `bash -x`, the abort is the assignment
#   domain="$(grep -oE 'standards/[a-z-]+/' "$f" | head -1 | sed -E ...)"
# under `set -euo pipefail`: grep matches nothing, exits 1, pipefail promotes that to the pipeline
# status, the command substitution carries it to the assignment, and `set -e` kills the script
# mid-loop. Non-zero is the RIGHT verdict for a malformed skill — a wrong catalog is worse than no
# catalog — but it has to say which file and what was wrong with it.
#
# The same trace shows the collateral damage: a perfectly VALID skill that happens to reference no
# standards/<domain>/ doc (a router) took the identical abort, because the mechanism cannot tell
# "no domain reference" from "malformed file".
#
# The second defect is the hardcoded body loop `for domain in meta languages frameworks platform
# practices design`: a skill in any other domain is counted in the header's "index of all N skills"
# and then silently omitted from the body.
#
# Fixtures are exercised by copying the real generator into each fixture's own scripts/ dir and
# running it from there — the generator self-locates with `cd "$(dirname "${BASH_SOURCE[0]}")/.."`,
# so cd-ing this shell into a fixture would silently read the REAL skills/ instead.
#
# EVERY row is guarded by an assert_fixture precondition AND an assert_contains on the specific
# message, because a deleted fixture leaves an empty tree, which now also exits non-zero — the same
# verdict for entirely the wrong reason.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
GATE="$KIT/scripts/gen-skill-catalog.sh"
FIXTURES="$KIT/tests/fixtures"

if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "gen-skill-catalog" "mktemp not available"
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

# run_gen <fixture> — GEN_RC / GEN_OUT (stdout only) / GEN_ERR (stderr only). Kept apart because the
# whole point of this gate is that a diagnostic goes to stderr while stdout stays clean: a partially
# generated catalog on stdout would be silently redirected over skills/CATALOG.md by CI.
GEN_RC=0
GEN_OUT=""
GEN_ERR=""
run_gen() {
  local fixture="$1"
  if [ ! -d "$FIXTURES/$fixture" ]; then
    GEN_RC=126
    GEN_OUT=""
    GEN_ERR="FIXTURE MISSING: $FIXTURES/$fixture"
    return 0
  fi
  WORK="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    GEN_RC=127
    GEN_OUT=""
    GEN_ERR="mktemp -d failed"
    return 0
  fi
  mkdir -p "$WORK/repo/scripts"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  cp "$GATE" "$WORK/repo/scripts/gen-skill-catalog.sh"
  GEN_RC=0
  GEN_OUT="$(cd "$WORK/repo" && bash scripts/gen-skill-catalog.sh 2>"$WORK/err" </dev/null)" || GEN_RC=$?
  GEN_ERR="$(cat "$WORK/err")"
  rm -rf "$WORK"
  WORK=""
}

# run_gen_twice <fixture> — leaves DET set to "identical" or "differs"; proves the generator is
# deterministic, which is the premise of CI's `diff -q` staleness check.
DET=""
run_gen_twice() {
  local fixture="$1" a b
  run_gen "$fixture"
  a="$GEN_OUT"
  run_gen "$fixture"
  b="$GEN_OUT"
  if [ "$a" = "$b" ]; then DET="identical"; else DET="differs"; fi
}

out_has() {
  case "$GEN_OUT" in
  *"$1"*) echo present ;;
  *) echo absent ;;
  esac
}
nonzero() { if [ "$GEN_RC" -ne 0 ]; then echo nonzero; else echo zero; fi; }

# --- the silent failure: a malformed SKILL.md must be named ------------------------------------

assert_fixture "catalog-no-frontmatter" "skills/zz-broken/SKILL.md" "skills/alpha-standards/SKILL.md"
run_gen "catalog-no-frontmatter"
assert_eq "SKILL.md with no frontmatter: still exits non-zero (rejecting it is correct)" "nonzero" "$(nonzero)"
assert_contains "no-frontmatter skill: the offending file is named" "skills/zz-broken/SKILL.md" "$GEN_ERR"
assert_contains "no-frontmatter skill: says what was wrong with it" "no YAML frontmatter block" "$GEN_ERR"
assert_contains "no-frontmatter skill: says why it aborted at all" "refusing to generate" "$GEN_ERR"
assert_eq "no-frontmatter skill: emits no partial catalog on stdout" "" "$GEN_OUT"

assert_fixture "catalog-empty-skill" "skills/zz-empty/SKILL.md" "skills/alpha-standards/SKILL.md"
run_gen "catalog-empty-skill"
assert_eq "empty SKILL.md: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty skill: the offending file is named" "skills/zz-empty/SKILL.md" "$GEN_ERR"
assert_contains "empty skill: says what was wrong with it" "no YAML frontmatter block" "$GEN_ERR"

# --- the collateral damage: a valid skill with no standards/<domain>/ reference -----------------

# This is the case the old mechanism could not tell apart from a malformed file. It must succeed and
# land in the meta bucket, not abort.
assert_fixture "catalog-no-domain-ref" "skills/meta-router/SKILL.md"
run_gen "catalog-no-domain-ref"
assert_eq "valid skill referencing no standards/<domain>/ doc: exits 0" "0" "$GEN_RC"
assert_contains "no-domain skill: bucketed under meta" "## meta" "$GEN_OUT"
assert_contains "no-domain skill: really appears in the body" "**[meta-router](meta-router/SKILL.md)**" "$GEN_OUT"
assert_eq "no-domain skill: nothing written to stderr" "" "$GEN_ERR"

# --- vacuity: no skills at all is a failure, not an empty catalog -------------------------------

# Deleting this fixture reproduces the condition under test exactly, so the exit code proves nothing
# on its own; the precondition row and the message below are what separate them.
assert_fixture "catalog-empty" "skills/.gitkeep"
run_gen "catalog-empty"
assert_eq "no skills/*/SKILL.md at all: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no skills: says so rather than emitting an empty catalog" "no skills/*/SKILL.md found" "$GEN_ERR"
assert_eq "no skills: emits no catalog at all" "" "$GEN_OUT"

# --- the hardcoded whitelist: a new domain must not vanish from the body ------------------------

assert_fixture "catalog-new-domain" "skills/alpha-standards/SKILL.md" "skills/obs-standards/SKILL.md"
run_gen "catalog-new-domain"
assert_eq "skill in a domain outside the old whitelist: exits 0" "0" "$GEN_RC"
assert_contains "new domain: header counts both skills" "index of all 2 skills" "$GEN_OUT"
assert_contains "new domain: gets its own body section" "## observability" "$GEN_OUT"
assert_contains "new domain: its skill really appears in the body" "**[obs-standards](obs-standards/SKILL.md)**" "$GEN_OUT"
# The known domain must still be there — a data-derived order must not drop the whitelisted ones.
assert_contains "new domain: the known domain is still emitted too" "**[alpha-standards](alpha-standards/SKILL.md)**" "$GEN_OUT"
assert_eq "new domain: no skill is counted in the header but missing from the body" "absent" "$(out_has "counted but not emitted")"

# --- determinism: CI regenerates and diffs, so two runs must be byte-identical ------------------

assert_fixture "catalog-new-domain" "skills/alpha-standards/SKILL.md" "skills/obs-standards/SKILL.md"
run_gen_twice "catalog-new-domain"
assert_eq "two runs over the same tree produce identical output" "identical" "$DET"

ts_report
