#!/usr/bin/env bash
# Gate: scripts/check-skills.sh must parse its inputs, not grep at them.
#
# The audit's findings, one fixture each:
#   * it tested the '^use ' trigger requirement against the RAW frontmatter value, so a correctly
#     QUOTED description arrived as '"Use when …"' and was rejected — meaning the gate would have
#     blocked the very fix that makes 12 broken descriptions valid YAML. That ordering hazard is
#     why skills-desc-quoted is a must-pass fixture and not an afterthought.
#   * it never noticed the inverse: an UNQUOTED plain scalar containing ': ' (or ending in ':') is
#     not valid YAML at all, and 12 shipped skills were in exactly that state.
#   * it resolved only 'standards/*.md' tokens, and only from the repo root, so '../design/x.md'
#     and bare 'x.md' pointers — which resolve from neither the skill dir nor the root — sailed
#     through.
#   * it never looked for leaked generation scaffolding ('</content>' on its own line).
#   * with no skills at all it printed "no skills found" and exited 0 — a vacuous pass.
#
# The review round added:
#   * a '../design/x.md' pointer whose target was planted OUTSIDE the repo resolved, and the gate
#     exited 0 — a file the repo does not own decided the verdict (skills-pointer-outside-repo).
#   * every '.md' token was a pointer, including ones inside fenced code examples, inside http(s)
#     URLs, and inside markdown link LABELS — the last of which forced authors to make display text
#     resolvable instead of making their links correct.
#
# As in check-links.test.sh, we run the REAL gate against fixture trees rather than asserting it
# agrees with a hand-written expectation: each tests/fixtures/skills-* is a minimal adopting-repo
# tree with exactly one real defect (or, for the controls and the must-ignore trees, none).
#
# EVERY row below is guarded two ways, because deleting tests/fixtures/skills-empty used to leave
# this file at 14 passed / 0 failed:
#   1. assert_fixture states, as its own assertion, which files the row depends on. run_gate copies
#      the fixture into an empty temp tree, so a DELETED fixture leaves the gate scanning nothing —
#      which exits non-zero, satisfying every "exits non-zero" assertion for entirely the wrong
#      reason. The empty-tree row is structurally incapable of telling the two apart on exit code
#      alone: a missing fixture reproduces the exact condition under test.
#   2. Every exit-code assertion is paired with an assert_contains on the specific message that
#      verdict should carry, so neither "non-zero" nor "0" is ever accepted on its own.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
GATE="$KIT/scripts/check-skills.sh"
FIXTURES="$KIT/tests/fixtures"

# Hard rule 4: self-skip only for genuine tool absence, never for anything check-skills.sh itself
# does — tests/run.sh exits on failures only, so a skip on the behaviour under test would read as
# green while leaving it unverified.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "check-skills" "mktemp not available"
  ts_report
  exit 0
fi

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# assert_fixture <fixture> <file>... — precondition row: every listed file must be on disk before
# the row that follows means anything. Name every file whose absence would change the verdict, not
# just one: with a fixture's standards/design/resilience.md deleted, for instance, the gate still
# exits non-zero and still names the skill, so the paired assert_contains passes too.
assert_fixture() {
  local fixture="$1" state="complete" missing="" f
  shift
  for f in "$@"; do
    if [ ! -f "$FIXTURES/$fixture/$f" ]; then missing="$missing $f"; fi
  done
  if [ -n "$missing" ]; then state="missing:$missing"; fi
  assert_eq "fixture $fixture is complete on disk" "complete" "$state"
}

# run_gate <fixture-name> [builder-fn] — copies tests/fixtures/<fixture-name> into a fresh tmp tree,
# optionally calls <builder-fn> "<tree>" to materialise files that cannot sensibly be committed
# (here: a target placed OUTSIDE the scanned repo), installs a copy of the real gate at
# <tree>/scripts/check-skills.sh (mirroring how an adopting repo carries its own copy, per
# scripts/init.sh), runs it from <tree>, and leaves GATE_RC / GATE_OUT set.
# The gate cd's to its own repo root, so the empty-tree case only means anything when the SCRIPT is
# relocated into an empty tree — cd'ing the shell alone would still scan touchstone itself.
GATE_RC=0
GATE_OUT=""
run_gate() {
  local fixture="$1" builder="${2:-}"
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
  # The scanned tree is <tmp>/repo, one level below the temp root, so a builder can legitimately
  # place a file OUTSIDE the scanned tree (at <tmp>/) and still have it removed with everything
  # else. Without that, out-of-repo resolution cannot be exercised without leaving litter in $TMPDIR.
  mkdir -p "$WORK/repo"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  if [ -n "$builder" ]; then "$builder" "$WORK/repo"; fi
  mkdir -p "$WORK/repo/scripts"
  cp "$GATE" "$WORK/repo/scripts/check-skills.sh"
  GATE_RC=0
  GATE_OUT="$(cd "$WORK/repo" && bash scripts/check-skills.sh 2>&1)" || GATE_RC=$?
  rm -rf "$WORK"
  WORK=""
}

# gate_out_has <needle> — echoes "present" or "absent". Lets a row assert that something is NOT in
# the gate's output using the same assert_eq every other row uses. (Written as a function rather
# than an inline `case` inside "$( ... )" because bash 3.2 mis-parses the pattern's ')' there.)
gate_out_has() {
  case "$GATE_OUT" in
  *"$1"*) echo present ;;
  *) echo absent ;;
  esac
}

# nonzero — echoes "nonzero" or "zero" for the last gate run.
nonzero() { if [ "$GATE_RC" -ne 0 ]; then echo nonzero; else echo zero; fi; }

# --- builders for fixture content that cannot sensibly be committed ----------------------------

# A REAL file placed above the scanned tree, at exactly the path the fixture's '../design/…'
# pointer climbs to. A gate with no containment check resolves the pointer against it and exits 0 —
# which is what the reviewed version did.
build_outside_repo_target() {
  mkdir -p "$1/../design"
  printf '# Outside\n\nA doc the repo does not own.\n' >"$1/../design/fixture-outside-doc.md"
}

# --- controls: must pass, proving the harness can tell good from bad ----------------------------

assert_fixture "skills-known-good" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-known-good"
assert_eq "known-good skill tree: exits 0" "0" "$GATE_RC"
assert_contains "known-good tree: the skill really was examined" "Validated 1 skills." "$GATE_OUT"

# THE ORDERING GUARD. Quoting is the fix for the 12 unparseable descriptions; if the gate judges
# the trigger phrase before stripping quotes it rejects the fix, and the repair task can never land.
assert_fixture "skills-desc-quoted" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-desc-quoted"
assert_eq "quoted description containing ': ': exits 0" "0" "$GATE_RC"
assert_contains "quoted description: the skill really was examined" "Validated 1 skills." "$GATE_OUT"
assert_eq "quoted description: not flagged for trigger phrasing" "absent" "$(gate_out_has "trigger phrasing")"

# --- defect fixtures: the gate must exit non-zero and name the actual broken thing ---------------

assert_fixture "skills-desc-unquoted-colon" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-desc-unquoted-colon"
assert_eq "unquoted description containing ': ': exits non-zero" "nonzero" "$(nonzero)"
assert_contains "unquoted description: names the offending skill" "FAIL: demo-standards:" "$GATE_OUT"
assert_contains "unquoted description: says it is an unquoted plain scalar" "unquoted 'description:'" "$GATE_OUT"

# A plain scalar ending in ':' is the same Psych::SyntaxError as one containing ': ' — the trailing
# whitespace strip on extraction hid it from a colon-SPACE-only test.
assert_fixture "skills-desc-unquoted-trailing-colon" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-desc-unquoted-trailing-colon"
assert_eq "unquoted description ending in ':': exits non-zero" "nonzero" "$(nonzero)"
assert_contains "trailing-colon description: says it is an unquoted plain scalar" "unquoted 'description:'" "$GATE_OUT"

# `"… \"` opens a double-quoted scalar whose terminator is escaped, so it is never closed. Treating
# the escaped quote as a closing quote unwrapped the value and skipped the plain-scalar lint.
assert_fixture "skills-desc-escaped-quote" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-desc-escaped-quote"
assert_eq "description whose closing quote is escaped: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "escaped closing quote: reported as an invalid plain scalar, not silently unwrapped" \
  "invalid YAML plain scalar" "$GATE_OUT"

# `description: ""` is present and well-formed — just empty. Reporting it as absent sends the author
# looking for a key that is right in front of them.
assert_fixture "skills-desc-empty" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-desc-empty"
assert_eq "explicitly empty description: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty description: says empty, not missing" "'description:' is present but empty" "$GATE_OUT"
assert_eq "empty description: does not claim the key is absent" "absent" "$(gate_out_has "has no 'description:'")"

assert_fixture "skills-pointer-relative-dead" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-pointer-relative-dead"
assert_eq "'../design/*.md' pointer resolving nowhere: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "dead relative pointer: names it" "../design/fixture-dead-pointer.md" "$GATE_OUT"

# A pointer written into prose ends with the sentence's period. Only a trailing COMMA was stripped,
# so the token failed the '\.md$' test and the dead pointer was invisible.
assert_fixture "skills-pointer-sentence-period" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-pointer-sentence-period"
assert_eq "dead pointer ending a sentence: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "sentence-final pointer: names it without the period" \
  "'standards/design/fixture-sentence-end.md'" "$GATE_OUT"

assert_fixture "skills-pointer-bare-dead" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-pointer-bare-dead"
assert_eq "bare 'file.md' pointer resolving nowhere: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "dead bare pointer: names it" "fixture-dangling-doc.md" "$GATE_OUT"

# The pointer's target EXISTS — one directory above the repo. Resolving it lets a file the repo does
# not own decide the verdict, and 65 of the dead pointers this gate was built to find were exactly
# this '../<dir>/<file>.md' shape.
assert_fixture "skills-pointer-outside-repo" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-pointer-outside-repo" build_outside_repo_target
assert_eq "pointer resolving above the repo root: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "out-of-repo pointer: names it" "../design/fixture-outside-doc.md" "$GATE_OUT"
assert_contains "out-of-repo pointer: says a path leaving the repo is refused" \
  "a path leaving the repo is refused, not resolved" "$GATE_OUT"

assert_fixture "skills-stray-xml" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-stray-xml"
assert_eq "leaked '</content>' scaffolding line: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "leaked scaffolding: names the tag" "</content>" "$GATE_OUT"

# --- tokeniser scope: what is and is not a pointer -----------------------------------------------

# A fenced example names files that do not and should not exist. The two fence markers are tracked
# independently, so a ~~~ line shown INSIDE a ``` block cannot close it: with a single shared toggle
# the tilde closed the block (exposing the line after it) and the real closing ``` re-opened one
# (swallowing the genuinely dead pointer that follows). Both halves are asserted.
assert_fixture "skills-fence-nested-detected" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-fence-nested-detected"
assert_eq "dead pointer after a fenced example: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "fence closes: the pointer after the fence is still checked" "fixture-after-fence.md" "$GATE_OUT"
assert_eq "fenced example: its filenames are not pointers" "absent" "$(gate_out_has "fixture-template.md")"
assert_eq "tilde inside a backtick fence does not close it" "absent" "$(gate_out_has "fixture-inside-after-tilde.md")"
assert_eq "a top-level ~~~ fence is a fence too" "absent" "$(gate_out_has "fixture-tilde-fenced.md")"

# An http(s) URL names a document on someone else's server. Matched by scheme, not by an `http*`
# glob, so a relative pointer merely NAMED like a scheme is still checked (see check-links.sh).
assert_fixture "skills-url-ignored" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-url-ignored"
assert_eq "https://…/x.md URL: exits 0 (not a repo pointer)" "0" "$GATE_RC"
assert_contains "URL fixture: the skill really was examined" "Validated 1 skills." "$GATE_OUT"
assert_eq "URL: no pointer extracted from it" "absent" "$(gate_out_has "fixture-remote-guide.md")"

# In `[label](dest)` only dest is a reference; the label is display text. Flagging it made authors
# rewrite their prose to be resolvable instead of making their links correct.
assert_fixture "skills-link-label-ignored" "VERSION" "skills/demo-standards/SKILL.md" "standards/design/resilience.md"
run_gate "skills-link-label-ignored"
assert_eq "markdown link label spelled like a path: exits 0 (label is not a pointer)" "0" "$GATE_RC"
assert_contains "label fixture: the skill really was examined" "Validated 1 skills." "$GATE_OUT"
assert_eq "link label: not treated as a pointer" "absent" "$(gate_out_has "fixture-label-not-a-path.md")"

# --- non-vacuity: examining zero skills is a failure, never a pass ------------------------------

# This row cannot be defended by its exit code at all: deleting the fixture reproduces the exact
# condition under test. Only the precondition row above and the message below tell the two apart.
assert_fixture "skills-empty" ".gitkeep"
run_gate "skills-empty"
assert_eq "tree with no skills at all: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no skills: says nothing was checked" "nothing to check" "$GATE_OUT"
assert_eq "no skills: claims nothing about skills being valid" "absent" "$(gate_out_has "Validated")"

ts_report
