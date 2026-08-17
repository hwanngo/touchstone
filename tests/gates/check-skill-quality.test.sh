#!/usr/bin/env bash
# Gate: scripts/check-skill-quality.sh is ADVISORY, and has to say so.
#
# Verified before this file was written, not assumed: on this repo it exits 0 while printing 28
# "WARN:" lines. Warn-only is INTENDED — the script's own header says "Always exits 0", scripts/
# README.md marks it "**Warn-only**" and "this repo's CI (advisory)", and .github/workflows/ci.yml
# runs it as a plain step. So the finding is not "it should fail"; making it blocking would turn CI
# red on 28 pre-existing warnings. The finding is that NOTHING at the point of use distinguishes it
# from the four blocking gates it sits beside in the justfile's `gates` recipe: it prints
# "quality-gate: 28 warning(s)" and exits 0, which reads exactly like a gate that passed.
#
# So the rows below pin two things:
#   1. warnings never change the exit status (the intended behaviour, now protected against a
#      well-meaning future "fix"), and
#   2. the output states, in words, that it is advisory and how many skills it examined — so a
#      reader of `just gates` output can tell an advisory pass from a real one.
#
# The one case that is NOT advisory is vacuity: zero skills examined means the run proved nothing,
# and no gate in this repo may report a pass on zero inputs. That is an error condition, not a
# warning, so it exits non-zero.
set -uo pipefail

# The kit-only gates carry a POSITIONAL scope guard: they refuse to run when their own root is named
# `.touchstone` or when its PARENT is a git work tree, because from there a green verdict would
# describe the kit instead of the caller's repo (see any check-*.sh header). This file relocates the
# gate into a temp tree by design, so if `TMPDIR` happens to sit inside a git repository — a
# perfectly ordinary setup — every relocated row would fail with "refusing to run" instead of
# exercising the behaviour under test. `TOUCHSTONE_ALLOW_NESTED=1` is the escape hatch the guard
# itself documents for exactly this case, and it is set here rather than left to the environment.
# The guard's own behaviour is NOT weakened by this: tests/gates/gate-scope-guard.test.sh sets the
# variable explicitly per row (defaulting to 0), so it still proves both the refusal and the hatch.
export TOUCHSTONE_ALLOW_NESTED=1

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
GATE="$KIT/scripts/check-skill-quality.sh"
FIXTURES="$KIT/tests/fixtures"

if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "check-skill-quality" "mktemp not available"
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

GATE_RC=0
GATE_OUT=""
run_gate() {
  local fixture="$1"
  if [ ! -d "$FIXTURES/$fixture" ]; then
    GATE_RC=126
    GATE_OUT="FIXTURE MISSING: $FIXTURES/$fixture"
    return 0
  fi
  WORK="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    GATE_RC=127
    GATE_OUT="mktemp -d failed"
    return 0
  fi
  mkdir -p "$WORK/repo/scripts"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  cp "$GATE" "$WORK/repo/scripts/check-skill-quality.sh"
  GATE_RC=0
  GATE_OUT="$(cd "$WORK/repo" && bash scripts/check-skill-quality.sh 2>&1 </dev/null)" || GATE_RC=$?
  rm -rf "$WORK"
  WORK=""
}

nonzero() { if [ "$GATE_RC" -ne 0 ]; then echo nonzero; else echo zero; fi; }

# --- warnings are advisory: they are reported, counted, and do NOT fail the run -----------------

assert_fixture "quality-warns" "skills/alpha-standards/SKILL.md" "skills/beta-standards/SKILL.md"
run_gate "quality-warns"
assert_eq "descriptions with a vague verb and a shared opening: still exits 0 (advisory)" "0" "$GATE_RC"
assert_contains "advisory run: the vague verb is reported" "vague main verb" "$GATE_OUT"
assert_contains "advisory run: the duplicated opening is reported" "first-5-word opening duplicated" "$GATE_OUT"
assert_contains "advisory run: names the offending skill" "WARN: alpha-standards:" "$GATE_OUT"
assert_contains "advisory run: counts the warnings" "4 warning(s)" "$GATE_OUT"
# The point of the whole exercise: the summary line says it is advisory, so a zero exit alongside
# warnings cannot be mistaken for a blocking gate that passed.
assert_contains "advisory run: the summary says warnings do not fail the build" "advisory" "$GATE_OUT"
assert_contains "advisory run: the summary says how many skills were examined" "examined 2 skill(s)" "$GATE_OUT"

# --- a clean tree: examined, zero warnings, still says how much it looked at --------------------

assert_fixture "quality-clean" "skills/alpha-standards/SKILL.md" "skills/beta-standards/SKILL.md"
run_gate "quality-clean"
assert_eq "well-written descriptions: exits 0" "0" "$GATE_RC"
assert_contains "clean run: reports zero warnings" "0 warning(s)" "$GATE_OUT"
assert_contains "clean run: still reports the examined count" "examined 2 skill(s)" "$GATE_OUT"

# --- vacuity is the one non-advisory failure ----------------------------------------------------

# Deleting the fixture reproduces the condition under test exactly, so the exit code proves nothing
# alone; the precondition row and the message below are what separate them.
assert_fixture "quality-empty" "skills/.gitkeep"
run_gate "quality-empty"
assert_eq "no skills to examine: exits non-zero (a run that proved nothing is not a pass)" "nonzero" "$(nonzero)"
assert_contains "no skills: says so explicitly" "no skills/*/SKILL.md found" "$GATE_OUT"

ts_report
