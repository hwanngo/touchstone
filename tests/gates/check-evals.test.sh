#!/usr/bin/env bash
# Gate: scripts/check-evals.sh must catch a phantom defect — an answer key that claims a defect its
# fixture repo no longer contains — and must never certify an empty case set.
#
# The gate is self-locating (`cd "$(dirname "${BASH_SOURCE[0]}")/.."`), same as check-agents.sh,
# check-skills.sh and check-links.sh: it always scans the repo it physically lives in. Running it
# FROM a fixture directory (rather than moving the script INTO that directory first) would still
# scan the KIT, not the fixture, and every row below would pass no matter what the fixture
# contained — the exact trap this campaign's own comments warn was made twice before. So, as with
# check-agents.test.sh and check-links.test.sh, run_gate installs a COPY of the real gate inside
# each fixture tree (at <tree>/scripts/check-evals.sh) and runs it from there.
#
# Each tests/fixtures/evals-* tree is a full repo shape: agents/<name>.md for the case's meta.txt
# to resolve, plus evals/cases/<id>/{meta.txt,answer-key.txt,repo/**}.
#
# EVERY row below is guarded two ways, matching the sibling gate tests:
#   1. assert_fixture states, as its own assertion, which files the row depends on. run_gate copies
#      the fixture into an empty temp tree, so a DELETED fixture leaves the gate scanning nothing —
#      which exits non-zero, satisfying every "exits non-zero" assertion for entirely the wrong
#      reason. The empty-tree row is structurally incapable of telling the two apart on exit code
#      alone: a missing fixture reproduces the exact condition under test.
#   2. Every exit-code assertion is paired with an assert_contains on the specific message that
#      verdict should carry, so neither "non-zero" nor "0" is ever accepted on its own.
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
GATE="$KIT/scripts/check-evals.sh"
FIXTURES="$KIT/tests/fixtures"

# Hard rule 4: self-skip only for genuine tool absence, never for anything check-evals.sh itself
# does — tests/run.sh exits on failures only, so a skip on the behaviour under test would read as
# green while leaving it unverified.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "check-evals" "mktemp not available"
  ts_report
  exit 0
fi

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# assert_fixture <file>... — every listed path is relative to $FIXTURES. A missing file fails this
# row by name, before the run_gate row that depends on it is asked to mean anything.
assert_fixture() {
  local missing="" f
  for f in "$@"; do [ -e "$FIXTURES/$f" ] || missing="$missing $f"; done
  assert_eq "fixture present:$*" "" "$missing"
}

# run_gate <fixture-name> — copies tests/fixtures/<fixture-name> into a fresh tmp tree, installs a
# copy of the real gate at <tree>/scripts/check-evals.sh (mirroring how an adopting repo carries its
# own copy, per scripts/init.sh), runs it from <tree>, and leaves GATE_RC / GATE_OUT set.
# The gate cd's to its own repo root, so the empty-tree case only means anything when the SCRIPT is
# relocated into an empty tree — cd'ing the shell alone would still scan touchstone itself.
GATE_RC=0
GATE_OUT=""
run_gate() {
  local fixture="$1"
  if [ ! -f "$GATE" ]; then
    # The gate itself is absent: say so, rather than letting `cp` fail and every "exits non-zero"
    # row pass on a shell error.
    GATE_RC=125
    GATE_OUT="GATE MISSING: $GATE"
    return 0
  fi
  if [ ! -d "$FIXTURES/$fixture" ]; then
    # Refuse to run rather than silently scan an empty tree. Paired with assert_fixture above and
    # the assert_contains on every row, a missing fixture now fails loudly instead of masquerading
    # as a correct non-zero verdict.
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
  mkdir -p "$WORK/repo"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  mkdir -p "$WORK/repo/scripts"
  cp "$GATE" "$WORK/repo/scripts/check-evals.sh"
  GATE_RC=0
  GATE_OUT="$(cd "$WORK/repo" && bash scripts/check-evals.sh 2>&1)" || GATE_RC=$?
  rm -rf "$WORK"
  WORK=""
}

# nonzero — echoes "nonzero" or "zero" for the last gate run.
nonzero() { if [ "$GATE_RC" -ne 0 ]; then echo nonzero; else echo zero; fi; }

# --- a well-formed case passes --------------------------------------------------------------------

assert_fixture "evals-good/agents/demo-agent.md" "evals-good/evals/cases/demo/meta.txt" \
  "evals-good/evals/cases/demo/answer-key.txt" "evals-good/evals/cases/demo/repo/src/config.py"
run_gate "evals-good"
assert_eq "a well-formed case passes" "0" "$GATE_RC"
assert_contains "and says how many cases it examined" "Validated 1 eval case(s)." "$GATE_OUT"

# --- the phantom check is the point of this gate ---------------------------------------------------

# The answer key claims a required defect at src/config.py; the fixture's repo/ has no such file.
# An answer key is a CLAIM about a fixture repo, and a claim nothing verifies is the defect class
# this whole project exists to remove.
assert_fixture "evals-phantom-defect/agents/demo-agent.md" "evals-phantom-defect/evals/cases/demo/meta.txt" \
  "evals-phantom-defect/evals/cases/demo/answer-key.txt"
run_gate "evals-phantom-defect"
assert_eq "an answer key naming a defect the repo does not contain fails" "1" "$GATE_RC"
assert_contains "and names the phantom" "PHANTOM: demo -> src/config.py" "$GATE_OUT"

# --- zero cases is a failure, not a vacuous pass ----------------------------------------------------

assert_fixture "evals-empty/.gitkeep"
run_gate "evals-empty"
assert_eq "zero cases is a failure, not a vacuous pass" "1" "$GATE_RC"
assert_contains "and says so" "No eval cases found" "$GATE_OUT"

# --- an answer key with no trailing newline still has every entry checked --------------------------

# `read` returns non-zero on an answer key's final line when the file is not newline-terminated
# (ordinary for a hand-written file), even though it still populates the fields from that line.
# Without the `|| [ -n "$sev" ]` guard scripts/check-evals.sh carries, the last entry is silently
# dropped from the loop — so a phantom defect sitting on the file's last line would never be
# checked, and the gate would pass vacuously on exactly the case it exists to catch.
assert_fixture "evals-phantom-no-trailing-newline/agents/demo-agent.md" \
  "evals-phantom-no-trailing-newline/evals/cases/demo/meta.txt" \
  "evals-phantom-no-trailing-newline/evals/cases/demo/answer-key.txt" \
  "evals-phantom-no-trailing-newline/evals/cases/demo/repo/src/config.py"
run_gate "evals-phantom-no-trailing-newline"
assert_eq "a phantom on the unterminated last line still fails" "1" "$GATE_RC"
assert_contains "the last (no-newline) entry is checked, not silently dropped" \
  "PHANTOM: demo -> missing-file.txt" "$GATE_OUT"

# --- meta.txt must target a real agent --------------------------------------------------------------

# A case naming an agent this tree does not ship is exactly the drift a case-format gate exists to
# catch on the agent side, mirroring the repo-side phantom check above.
assert_fixture "evals-missing-agent/evals/cases/demo/meta.txt" \
  "evals-missing-agent/evals/cases/demo/answer-key.txt" \
  "evals-missing-agent/evals/cases/demo/repo/src/config.py"
run_gate "evals-missing-agent"
assert_eq "a case targeting a nonexistent agent fails" "1" "$GATE_RC"
assert_contains "and names the missing agent file" \
  "meta.txt targets agent 'ghost-agent', which has no agents/ghost-agent.md" "$GATE_OUT"

# --- meta.txt must carry numeric score floors --------------------------------------------------

# scripts/score-eval.sh reads min_recall/max_unmatched via its optional --meta argument; this gate
# requires them to be present and numeric so a case can never ship without them and silently fall
# back to score-eval.sh's legacy exact-match rule.
assert_fixture "evals-bad-floor/agents/demo-agent.md" "evals-bad-floor/evals/cases/demo/meta.txt" \
  "evals-bad-floor/evals/cases/demo/answer-key.txt" \
  "evals-bad-floor/evals/cases/demo/repo/src/config.py"
run_gate "evals-bad-floor"
assert_eq "a case with a non-numeric max_unmatched floor fails" "1" "$GATE_RC"
assert_contains "and names the malformed floor" \
  "meta.txt max_unmatched is not numeric: 'lots'" "$GATE_OUT"

# --- an answer-key entry whose recall could never fail must not ship -----------------------------

# scripts/score-eval.sh matches a finding against an entry by requiring BOTH <path> and <substring>
# in the line, so two spellings of <substring> make the test unconditional and turn the entry into a
# guaranteed match: an EMPTY substring, and a substring that is a substring of its own PATH. Both
# were live in this repo — `required|standards/platform/caching.md|caching.md` shipped in
# evals/cases/stale-claims, where it meant one of that case's two required entries could not
# distinguish the catalogued defect from any mention of the file, and the case still read
# `recall 100 / verdict PASS`. The clean sibling (evals-good, above) is the paired control: it uses
# the same fixture shape with discriminating substrings and passes.
assert_fixture "evals-degenerate-empty-needle/agents/demo-agent.md" \
  "evals-degenerate-empty-needle/evals/cases/demo/meta.txt" \
  "evals-degenerate-empty-needle/evals/cases/demo/answer-key.txt" \
  "evals-degenerate-empty-needle/evals/cases/demo/repo/src/config.py"
run_gate "evals-degenerate-empty-needle"
assert_eq "an answer-key entry with an empty substring fails the gate" "1" "$GATE_RC"
assert_contains "and names it as degenerate" \
  "DEGENERATE KEY: demo -> 'required|src/config.py|' has an empty substring" "$GATE_OUT"

assert_fixture "evals-degenerate-needle-in-path/agents/demo-agent.md" \
  "evals-degenerate-needle-in-path/evals/cases/demo/meta.txt" \
  "evals-degenerate-needle-in-path/evals/cases/demo/answer-key.txt" \
  "evals-degenerate-needle-in-path/evals/cases/demo/repo/src/config.py"
run_gate "evals-degenerate-needle-in-path"
assert_eq "an answer-key entry whose substring is inside its own path fails the gate" "1" "$GATE_RC"
assert_contains "and says it measures nothing" \
  "DEGENERATE KEY: demo -> 'required|src/config.py|config.py' has a substring contained in its own path" \
  "$GATE_OUT"

# --- repo/ must never leak the case's own provenance --------------------------------------------

# An answer key is a claim ABOUT a fixture; repo/ is what an agent under test actually sees. A
# comment inside repo/ naming the case, the defect class, or the fixture's own status is not
# realistic clutter — it is the answer key, handed to the agent for free. This is not a theoretical
# concern: a blind adoption-doctor run against evals/cases/adopter-broken-toolchain found its
# justfile defect with such a comment present in repo/, and MISSED the same defect once the comment
# was stripped — see that case's NOTES.md. A clean case must pass regardless.
assert_fixture "evals-leak-clean/agents/demo-agent.md" "evals-leak-clean/evals/cases/demo/meta.txt" \
  "evals-leak-clean/evals/cases/demo/answer-key.txt" \
  "evals-leak-clean/evals/cases/demo/repo/src/config.py"
run_gate "evals-leak-clean"
assert_eq "a case whose repo/ carries no provenance passes" "0" "$GATE_RC"
assert_contains "and says how many cases it examined" "Validated 1 eval case(s)." "$GATE_OUT"

# The leaking sibling: same shape, but repo/src/config.py opens with a "DELIBERATELY BROKEN —
# fixture for evals/cases/demo, reproducing a real defect" comment, exactly the pattern this gate
# exists to catch.
assert_fixture "evals-leaking-repo/agents/demo-agent.md" \
  "evals-leaking-repo/evals/cases/demo/meta.txt" \
  "evals-leaking-repo/evals/cases/demo/answer-key.txt" \
  "evals-leaking-repo/evals/cases/demo/repo/src/config.py"
run_gate "evals-leaking-repo"
assert_eq "a case whose repo/ leaks its own provenance fails" "1" "$GATE_RC"
assert_contains "and names the leak" "LEAK: demo -> repo/ carries its own case provenance" "$GATE_OUT"
assert_contains "quoting the offending line" "DELIBERATELY BROKEN" "$GATE_OUT"

# The case id marker is matched at WORD BOUNDARIES, not as a free substring. Searching for the bare
# id works only while no case is named something that occurs in ordinary prose — a case id of `ci`,
# `uv`, `lint` or `docs` (all plausible names for a case about exactly those things) would otherwise
# flag every fixture line containing the word as a fragment, and the gate would insist that ordinary
# content was a leaked answer key. This fixture is a case named `ci` whose repo/ says "specific",
# "efficient" and "CIPHER" and nothing else: no leak.
assert_fixture "evals-leak-id-substring/agents/demo-agent.md" \
  "evals-leak-id-substring/evals/cases/ci/meta.txt" \
  "evals-leak-id-substring/evals/cases/ci/answer-key.txt" \
  "evals-leak-id-substring/evals/cases/ci/repo/src/config.py"
run_gate "evals-leak-id-substring"
assert_eq "a common-word case id does not flag the word as a fragment of longer words" "0" "$GATE_RC"
assert_contains "and the case is still examined, not skipped" "Validated 1 eval case(s)." "$GATE_OUT"

# --- score floors must be BOUNDED, not merely numeric -------------------------------------------
# `min_recall: 0` is met by a run that matched nothing, and `max_unmatched: 9999` by a run of pure
# noise: a floor that cannot fail is the same vacuous pass as no floor at all, and both passed this
# gate while it checked only that the values were digits.
FLOORCHK="$(mktemp -d 2>/dev/null || true)"
if [ -z "$FLOORCHK" ]; then
  ts_skip "floor bounds" "mktemp -d failed"
else
  floor_case() { # <min_recall> <max_unmatched> -> sets GATE_RC/GATE_OUT
    rm -rf "$FLOORCHK/tree"
    mkdir -p "$FLOORCHK/tree"
    cp -R "$FIXTURES/evals-good/." "$FLOORCHK/tree/"
    mkdir -p "$FLOORCHK/tree/scripts"
    cp "$GATE" "$FLOORCHK/tree/scripts/check-evals.sh"
    {
      echo "agent: demo-agent"
      echo "summary: floor-bounds probe"
      echo "min_recall: $1"
      echo "max_unmatched: $2"
    } >"$FLOORCHK/tree/evals/cases/demo/meta.txt"
    GATE_RC=0
    GATE_OUT="$(cd "$FLOORCHK/tree" && bash scripts/check-evals.sh 2>&1)" || GATE_RC=$?
  }

  # Control first: an in-bounds pair on the same tree passes, so the two failures below cannot be
  # the tree's fault. evals-good's key has 2 entries, so max_unmatched 2 is the largest legal value.
  floor_case 100 0
  assert_eq "control: an in-bounds floor pair passes" "0" "$GATE_RC"
  assert_contains "control: and the case is examined" "Validated 1 eval case(s)." "$GATE_OUT"

  floor_case 0 0
  assert_eq "min_recall 0 fails: a recall floor no run can miss" "1" "$GATE_RC"
  assert_contains "and says what the legal range is" "min_recall must be 1-100" "$GATE_OUT"

  floor_case 101 0
  assert_eq "min_recall above 100 fails: a floor no run can meet" "1" "$GATE_RC"
  assert_contains "and names the offending value" "got '101'" "$GATE_OUT"

  floor_case 100 9999
  assert_eq "max_unmatched larger than the whole answer key fails" "1" "$GATE_RC"
  assert_contains "and compares it to what the key actually catalogues" \
    "max_unmatched (9999) exceeds the answer key's 2 catalogued" "$GATE_OUT"

  rm -rf "$FLOORCHK"
fi

ts_report
