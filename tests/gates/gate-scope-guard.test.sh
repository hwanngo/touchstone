#!/usr/bin/env bash
# Gate: the kit's own CI gates must refuse to run from a vendored checkout, instead of reporting a
# confident green about a repository they never opened.
#
# The defect, found only by adopting the kit into an outside repo: check-{agents,links,skill-quality,
# skills,standards}.sh each `cd "$(dirname "$0")/.."` and scan the repo they live in. Run the way an
# adopter naturally would — `./.touchstone/scripts/check-links.sh` from the consuming repo — they
# walked the vendored kit and printed "All internal links resolve." while the adopter's own
# deliberately-broken link sat unexamined a directory away. Every one of those gates was green, and
# every one of them was green about somebody else's files.
#
# WHY THE GUARD IS POSITIONAL, AND WHY THAT MATTERS HERE. The obvious implementation — "refuse
# unless I am the real touchstone repo" — would also refuse inside every temp fixture tree the rest
# of this suite builds by copying a gate into one, taking hundreds of rows red for a reason that has
# nothing to do with the defect. So the guard keys on POSITION: a root named `.touchstone`, or a root
# sitting inside another git work tree. Rows 3 and 4 below assert each of those two signals fires on
# its OWN, and rows 5-6 assert the fixture shape (neither signal) still runs — that last pair is the
# control which proves this gate cannot silently become "refuse always".
#
# Every refusal row asserts the exit code AND the specific refusal text AND the absence of the
# gate's success line, so "non-zero" is never accepted on its own — a gate that crashed for an
# unrelated reason would satisfy an exit-code assertion while leaving the defect wide open.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"

REFUSAL="refusing to run — it would report on the wrong repository"

if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "gate-scope-guard" "mktemp not available"
  ts_report
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  ts_skip "gate-scope-guard" "git not available"
  ts_report
  exit 0
fi

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "gate-scope-guard" "mktemp -d failed"
  ts_report
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

GATES="check-agents check-links check-skill-quality check-skills check-standards"

# plant <root> <gate> — copy the real gate into <root>/scripts/ and give <root> the shape of a kit
# checkout (a VERSION file plus the directories the gates scan), so that anything the gate does
# AFTER the guard has something to chew on. The trees are deliberately minimal: this file tests the
# guard, and the gates' own behaviour is covered by their own test files.
plant() {
  mkdir -p "$1/scripts" "$1/skills" "$1/standards" "$1/agents"
  echo "0.0.0" >"$1/VERSION"
  cp "$KIT/scripts/$2.sh" "$1/scripts/$2.sh"
}

# run_gate <root> <gate> [env-assignment] — run the planted gate from a cwd that is NOT its own root
# (the adopter's position), capture combined output and exit code into GATE_OUT / GATE_RC. Refuses
# to run at all if the plant is missing, so a broken fixture can never look like a passing row.
GATE_OUT=""
GATE_RC=0
run_gate() {
  local root="$1" gate="$2" allow="${3:-0}"
  if [ ! -f "$root/scripts/$gate.sh" ]; then
    GATE_OUT="fixture missing: $root/scripts/$gate.sh"
    GATE_RC=99
    return 0
  fi
  GATE_OUT="$(cd "$TMP" && TOUCHSTONE_ALLOW_NESTED="$allow" bash "$root/scripts/$gate.sh" 2>&1)"
  GATE_RC=$?
}

# assert_refuses <label> <root> <gate>
assert_refuses() {
  run_gate "$2" "$3"
  assert_eq "$1: exits 2" "2" "$GATE_RC"
  assert_contains "$1: says it is refusing, and why" "$REFUSAL" "$GATE_OUT"
  local leaked="no"
  case "$GATE_OUT" in
  *"All internal links resolve"* | *"Validated "* | *"quality-gate"* | *"Examined "*) leaked="yes" ;;
  esac
  assert_eq "$1: emits no success line" "no" "$leaked"
}

# --- rows 1-2: the real adopter shape — BOTH signals present -------------------------------------
# A git repo containing a `.touchstone` directory: exactly what bootstrap.sh produces.
HOST="$TMP/host"
mkdir -p "$HOST"
git init -q "$HOST"
for g in $GATES; do
  plant "$HOST/.touchstone" "$g"
done
for g in $GATES; do
  assert_refuses "adopter layout: $g" "$HOST/.touchstone" "$g"
done

# --- row 3: the NAME signal alone — a `.touchstone` dir with no host repo above it ---------------
# Proves the basename test is load-bearing on its own, so a vendored copy is caught even where the
# host is not a git work tree (a tarball export, a worktree-less deployment).
NAMEONLY="$TMP/nogit/.touchstone"
plant "$NAMEONLY" check-links
assert_refuses "name signal alone (.touchstone, no host repo): check-links" "$NAMEONLY" check-links

# --- row 4: the NESTING signal alone — an ordinarily-named dir inside another git work tree ------
# Proves an adopter that vendors the kit under some other path (vendor/touchstone, tools/kit) is
# caught too, rather than the guard only recognising one hard-coded directory name.
NESTHOST="$TMP/nesthost"
mkdir -p "$NESTHOST"
git init -q "$NESTHOST"
plant "$NESTHOST/vendor/touchstone" check-links
assert_refuses "nesting signal alone (vendor/touchstone in a host repo): check-links" "$NESTHOST/vendor/touchstone" check-links

# --- rows 5-6: THE CONTROL — a plain fixture tree must still run ---------------------------------
# This is the row that keeps the guard honest. Every other gate test in this suite copies a gate
# into a bare mktemp tree; if the guard fired there, this file would be green while several hundred
# unrelated rows went red. A gate here is expected to FAIL (an empty tree verifies nothing) — the
# assertion is specifically that it fails on its own terms and never prints the refusal.
PLAIN="$TMP/plainfixture"
plant "$PLAIN" check-links
run_gate "$PLAIN" check-links
refused="no"
case "$GATE_OUT" in
*"$REFUSAL"*) refused="yes" ;;
esac
assert_eq "control: a bare fixture tree (no .touchstone name, no host repo) is NOT refused" "no" "$refused"
assert_eq "control: it fails on its own terms instead (no markdown to check)" "1" "$GATE_RC"

# A fixture tree that is ITSELF a git repo — the other shape tests build (check-sync's fixtures do
# `git init` at the fixture root). Its parent is a plain mktemp dir, so nesting must not fire.
PLAINGIT="$TMP/plaingit"
plant "$PLAINGIT" check-links
git init -q "$PLAINGIT"
run_gate "$PLAINGIT" check-links
refused="no"
case "$GATE_OUT" in
*"$REFUSAL"*) refused="yes" ;;
esac
assert_eq "control: a fixture tree that is its own git repo is NOT refused" "no" "$refused"

# --- row 7: the documented escape hatch ----------------------------------------------------------
# For the one honest case position cannot distinguish: a kit clone that merely happens to sit inside
# an unrelated git repo. Asserted so it cannot rot into a flag that does nothing.
run_gate "$NESTHOST/vendor/touchstone" check-links 1
escaped="no"
case "$GATE_OUT" in
*"$REFUSAL"*) escaped="no" ;;
*) escaped="yes" ;;
esac
assert_eq "TOUCHSTONE_ALLOW_NESTED=1 overrides the refusal" "yes" "$escaped"

# --- row 8: the adopter-facing gate is NOT caught by any of this ---------------------------------
# check-sync.sh takes a --target and is meant to be run from the adopter; if the guard had been
# pasted into it, the one gate adopters are told to run would have stopped working.
guarded="no"
if grep -q "scope guard: never certify" "$KIT/scripts/check-sync.sh" 2>/dev/null; then guarded="yes"; fi
assert_eq "check-sync.sh (the adopter-facing gate) carries no scope guard" "no" "$guarded"

# --- row 9: every kit-only gate actually carries the guard ---------------------------------------
# Discovery, not a hand-list: a sixth kit-only gate added tomorrow without the guard is a new false
# green, and this row is what notices. check-sync.sh is the sole documented exception (row 8).
missing=""
for f in "$KIT"/scripts/check-*.sh; do
  base="$(basename "$f")"
  [ "$base" = "check-sync.sh" ] && continue
  if ! grep -q "scope guard: never certify" "$f" 2>/dev/null; then
    missing="$missing $base"
  fi
done
assert_eq "every check-*.sh except check-sync.sh carries the scope guard" "" "$missing"

ts_report
