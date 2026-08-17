#!/usr/bin/env bash
# Gate: scripts/check-agents.sh must PARSE the subagent definitions under agents/, not grep at them.
#
# Why this file exists before the gate it tests: every capability this kit shipped without a gate
# has rotted (three standards docs went stale unnoticed; 12 SKILL.md descriptions shipped as
# unparseable YAML because check-skills.sh grepped at its inputs). agents/ is a new agent-facing
# surface with exactly the same failure modes, so it gets its executable spec first.
#
# The failure classes pinned here, one fixture each — each one already shipped somewhere in this
# repo, in skills/ or in standards/:
#   * an UNQUOTED plain scalar containing ': ' (or ending in ':') is not valid YAML at all: the
#     parser reads it as a nested mapping key and the description truncates or the document fails
#     to load. Claude Code then has no trigger text to route on, silently.
#   * the inverse ordering hazard: judging the trigger phrasing against the RAW value rejects the
#     correctly QUOTED form, i.e. rejects the only correct fix for the class above.
#   * `"… \"` opens a double-quoted scalar whose terminator is escaped, so it never closes.
#   * a `*.md` pointer in the system prompt that resolves nowhere — or, worse, resolves to a file
#     ABOVE the repo, letting a file the repo does not own decide the verdict.
#   * a definition with frontmatter and no system prompt: a stub that exists to satisfy a checker.
#   * zero agents examined reported as success.
#
# As in check-links.test.sh and check-skills.test.sh, we run the REAL gate against fixture trees
# rather than asserting it agrees with a hand-written expectation: each tests/fixtures/agents-* is a
# minimal tree with exactly one real defect (or, for the controls and the must-ignore trees, none).
#
# EVERY row below is guarded two ways, because rows in earlier versions of the sibling files passed
# with their fixtures deleted:
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
GATE="$KIT/scripts/check-agents.sh"
FIXTURES="$KIT/tests/fixtures"

# Hard rule 4: self-skip only for genuine tool absence, never for anything check-agents.sh itself
# does — tests/run.sh exits on failures only, so a skip on the behaviour under test would read as
# green while leaving it unverified.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "check-agents" "mktemp not available"
  ts_report
  exit 0
fi

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# assert_fixture <fixture> <file>... — precondition row: every listed file must be on disk before
# the row that follows means anything. Name every file whose absence would change the verdict, not
# just one: with a fixture's standards/design/resilience.md deleted, for instance, the gate still
# exits non-zero and still names the agent, so the paired assert_contains passes too.
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
# <tree>/scripts/check-agents.sh (mirroring how an adopting repo carries its own copy, per
# scripts/init.sh), runs it from <tree>, and leaves GATE_RC / GATE_OUT set.
# The gate cd's to its own repo root, so the empty-tree case only means anything when the SCRIPT is
# relocated into an empty tree — cd'ing the shell alone would still scan touchstone itself.
GATE_RC=0
GATE_OUT=""
run_gate() {
  local fixture="$1" builder="${2:-}"
  if [ ! -f "$GATE" ]; then
    # The gate itself is absent: say so, rather than letting `cp` fail and every "exits non-zero"
    # row pass on a shell error. This is what this file reports while it is still red.
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
  # The scanned tree is <tmp>/repo, one level below the temp root, so a builder can legitimately
  # place a file OUTSIDE the scanned tree (at <tmp>/) and still have it removed with everything
  # else. Without that, out-of-repo resolution cannot be exercised without leaving litter in $TMPDIR.
  mkdir -p "$WORK/repo"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  if [ -n "$builder" ]; then "$builder" "$WORK/repo"; fi
  mkdir -p "$WORK/repo/scripts"
  cp "$GATE" "$WORK/repo/scripts/check-agents.sh"
  GATE_RC=0
  GATE_OUT="$(cd "$WORK/repo" && bash scripts/check-agents.sh 2>&1)" || GATE_RC=$?
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
# pointer climbs to. A gate with no containment check resolves the pointer against it and exits 0.
build_outside_repo_target() {
  mkdir -p "$1/../design"
  printf '# Outside\n\nA doc the repo does not own.\n' >"$1/../design/fixture-outside-doc.md"
}

# --- controls: must pass, proving the harness can tell good from bad ----------------------------

# The known-good tree carries agents/README.md as well, so the count below is also the assertion
# that the directory index was SKIPPED rather than validated as a broken definition: a gate that
# counted it would report 2, and one that validated it would report a frontmatter failure.
assert_fixture "agents-known-good" "agents/demo-auditor.md" "agents/README.md" "standards/design/resilience.md"
run_gate "agents-known-good"
assert_eq "known-good agent tree: exits 0" "0" "$GATE_RC"
assert_contains "known-good tree: the agent really was examined" "Validated 1 agents." "$GATE_OUT"
assert_eq "known-good tree: agents/README.md is not validated as a definition" "absent" "$(gate_out_has "README")"

# `tools:` written as a YAML block sequence is the same list as the comma-separated scalar. A gate
# that only understood the scalar form would fail a definition that loads correctly.
assert_fixture "agents-tools-sequence" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-tools-sequence"
assert_eq "'tools:' as a YAML block sequence: exits 0" "0" "$GATE_RC"
assert_contains "block-sequence tools: the agent really was examined" "Validated 1 agents." "$GATE_OUT"
assert_eq "block-sequence tools: not reported as an empty allowlist" "absent" "$(gate_out_has "'tools:' is present but empty")"

# THE ORDERING GUARD, inherited from check-skills.test.sh: quoting is the fix for a description
# containing ': '. If the gate judges the trigger phrasing before stripping quotes it rejects the
# fix, and the repair can never land.
assert_fixture "agents-desc-quoted" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-desc-quoted"
assert_eq "quoted description containing ': ': exits 0" "0" "$GATE_RC"
assert_contains "quoted description: the agent really was examined" "Validated 1 agents." "$GATE_OUT"
assert_eq "quoted description: not flagged for trigger phrasing" "absent" "$(gate_out_has "trigger phrasing")"

# --- frontmatter shape ---------------------------------------------------------------------------

assert_fixture "agents-no-frontmatter" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-no-frontmatter"
assert_eq "definition with no frontmatter: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no frontmatter: says the opening marker is missing" "missing opening '---' frontmatter" "$GATE_OUT"

assert_fixture "agents-frontmatter-unclosed" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-frontmatter-unclosed"
assert_eq "frontmatter opened and never closed: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "unclosed frontmatter: says so" "frontmatter not closed" "$GATE_OUT"

# Claude Code resolves a subagent by the `name` in its frontmatter, while humans and reviewers find
# it by filename. A mismatch means the file everyone edits is not the agent that runs.
assert_fixture "agents-name-mismatch" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-name-mismatch"
assert_eq "name that disagrees with the filename: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "name mismatch: names both sides" "name 'demo-renamed' != filename 'demo-auditor'" "$GATE_OUT"

# --- description: the routing trigger, and the YAML that carries it -------------------------------

assert_fixture "agents-desc-unquoted-colon" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-desc-unquoted-colon"
assert_eq "unquoted description containing ': ': exits non-zero" "nonzero" "$(nonzero)"
assert_contains "unquoted description: names the offending agent" "FAIL: demo-auditor:" "$GATE_OUT"
assert_contains "unquoted description: says it is an unquoted plain scalar" "unquoted 'description:'" "$GATE_OUT"

# A plain scalar ending in ':' is the same parse error as one containing ': ' — the trailing
# whitespace strip on extraction hides it from a colon-SPACE-only test.
assert_fixture "agents-desc-unquoted-trailing-colon" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-desc-unquoted-trailing-colon"
assert_eq "unquoted description ending in ':': exits non-zero" "nonzero" "$(nonzero)"
assert_contains "trailing-colon description: says it is an unquoted plain scalar" "unquoted 'description:'" "$GATE_OUT"

# `"… \"` opens a double-quoted scalar whose terminator is escaped, so it is never closed. Treating
# the escaped quote as a closing quote unwraps the value and skips the plain-scalar lint.
assert_fixture "agents-desc-escaped-quote" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-desc-escaped-quote"
assert_eq "description whose closing quote is escaped: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "escaped closing quote: reported as an invalid plain scalar, not silently unwrapped" \
  "invalid YAML plain scalar" "$GATE_OUT"

# `description: ""` is present and well-formed — just empty. Reporting it as absent sends the author
# looking for a key that is right in front of them.
assert_fixture "agents-desc-empty" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-desc-empty"
assert_eq "explicitly empty description: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty description: says empty, not missing" "'description:' is present but empty" "$GATE_OUT"
assert_eq "empty description: does not claim the key is absent" "absent" "$(gate_out_has "has no 'description:'")"

# --- the optional keys, checked for shape only ----------------------------------------------------

# `tools:` present with no value is not "inherit every tool" — it is an empty allowlist, i.e. an
# agent that can do nothing. Omitting the key is the way to inherit.
assert_fixture "agents-tools-empty" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-tools-empty"
assert_eq "'tools:' present but empty: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty tools: says the key is present and empty" "'tools:' is present but empty" "$GATE_OUT"

# `model:` takes one token. A prose value is a definition that will not load — and the gate
# deliberately does NOT pin the set of legal model aliases, which is exactly the kind of claim that
# went stale in standards/ unnoticed.
assert_fixture "agents-model-multiword" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-model-multiword"
assert_eq "'model:' holding a prose phrase: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "multiword model: says it must be a single token" "'model:' must be a single token" "$GATE_OUT"

# --- the body: a system prompt that routes somewhere real -----------------------------------------

assert_fixture "agents-body-empty" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-body-empty"
assert_eq "frontmatter with no system prompt: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty body: says there is no system prompt" "has no system prompt body" "$GATE_OUT"

# An agent that names no standards doc restates the standards instead of routing to them, which is
# the drift these agents exist to prevent. Same rule check-skills.sh applies to every SKILL.md.
assert_fixture "agents-no-standards-ref" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-no-standards-ref"
assert_eq "agent routing to no standards doc: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no standards reference: says the body routes nowhere" "references no standards/*.md doc" "$GATE_OUT"

assert_fixture "agents-drift-marker" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-drift-marker"
assert_eq "TODO left in a system prompt: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "drift marker: says which markers are banned" "TODO/FIXME/XXX" "$GATE_OUT"

# --- pointers: every *.md the prompt names must resolve, inside this repo -------------------------

assert_fixture "agents-pointer-dead" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-pointer-dead"
assert_eq "'../design/*.md' pointer resolving nowhere: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "dead relative pointer: names it" "../design/fixture-dead-pointer.md" "$GATE_OUT"

# The pointer's target EXISTS — one directory above the repo. Resolving it lets a file the repo does
# not own decide the verdict. Shared with check-skills.sh/check-links.sh via path_escapes_root.
assert_fixture "agents-pointer-outside-repo" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-pointer-outside-repo" build_outside_repo_target
assert_eq "pointer resolving above the repo root: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "out-of-repo pointer: names it" "../design/fixture-outside-doc.md" "$GATE_OUT"
assert_contains "out-of-repo pointer: says a path leaving the repo is refused" \
  "a path leaving the repo is refused, not resolved" "$GATE_OUT"

# --- tokeniser scope: what is and is not a pointer ------------------------------------------------

# A fenced example names files that do not and should not exist. The two fence markers are tracked
# independently, so a ~~~ line shown INSIDE a ``` block cannot close it: with a single shared toggle
# the tilde closes the block (exposing the line after it) and the real closing ``` re-opens one
# (swallowing the genuinely dead pointer that follows). Both halves are asserted.
assert_fixture "agents-fence-nested-detected" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-fence-nested-detected"
assert_eq "dead pointer after a fenced example: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "fence closes: the pointer after the fence is still checked" "fixture-after-fence.md" "$GATE_OUT"
assert_eq "fenced example: its filenames are not pointers" "absent" "$(gate_out_has "fixture-template.md")"
assert_eq "tilde inside a backtick fence does not close it" "absent" "$(gate_out_has "fixture-inside-after-tilde.md")"
assert_eq "a top-level ~~~ fence is a fence too" "absent" "$(gate_out_has "fixture-tilde-fenced.md")"

# An http(s) URL names a document on someone else's server. Matched by scheme, not by an `http*`
# glob, so a relative pointer merely NAMED like a scheme is still checked (see check-links.sh).
assert_fixture "agents-url-ignored" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-url-ignored"
assert_eq "https://…/x.md URL: exits 0 (not a repo pointer)" "0" "$GATE_RC"
assert_contains "URL fixture: the agent really was examined" "Validated 1 agents." "$GATE_OUT"
assert_eq "URL: no pointer extracted from it" "absent" "$(gate_out_has "fixture-remote-guide.md")"

# In `[label](dest)` only dest is a reference; the label is display text. Flagging it makes authors
# rewrite their prose to be resolvable instead of making their links correct.
assert_fixture "agents-link-label-ignored" "agents/demo-auditor.md" "standards/design/resilience.md"
run_gate "agents-link-label-ignored"
assert_eq "markdown link label spelled like a path: exits 0 (label is not a pointer)" "0" "$GATE_RC"
assert_contains "label fixture: the agent really was examined" "Validated 1 agents." "$GATE_OUT"
assert_eq "link label: not treated as a pointer" "absent" "$(gate_out_has "fixture-label-not-a-path.md")"

# --- non-vacuity: examining zero agents is a failure, never a pass --------------------------------

# This row cannot be defended by its exit code at all: deleting the fixture reproduces the exact
# condition under test. Only the precondition row above and the message below tell the two apart.
assert_fixture "agents-empty" ".gitkeep"
run_gate "agents-empty"
assert_eq "tree with no agents at all: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no agents: says nothing was checked" "nothing to check" "$GATE_OUT"
assert_eq "no agents: claims nothing about agents being valid" "absent" "$(gate_out_has "Validated")"

# The README skip must not open a hole in the non-vacuity rule: a directory holding only the index
# has zero definitions and fails exactly like an empty one. Without this row, "skip README.md"
# could be spelled as "skip everything that fails to parse" and nothing would notice.
assert_fixture "agents-readme-only" "agents/README.md" "standards/design/resilience.md"
run_gate "agents-readme-only"
assert_eq "directory holding only agents/README.md: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "README-only directory: says nothing was checked" "nothing to check" "$GATE_OUT"
assert_eq "README-only directory: claims nothing about agents being valid" "absent" "$(gate_out_has "Validated")"

# --- a broken awk must fail the gate, not silently disable it -------------------------------------

# The frontmatter/body split and the pointer tokeniser both run in awk, inside command substitutions
# whose failure the caller never sees. With awk broken the tokeniser returns empty and the pointer
# check certifies a prompt it never read. That is the silent-disable class this campaign treats as
# P0, so it is pinned here: remove the preflight from scripts/check-agents.sh and this row goes red.
#
# awk is shadowed by a stub earlier on PATH rather than removed, because an awk that RUNS and
# produces wrong output is the case a `command -v` check would miss.
awk_sabotage_rc() {
  local dir stub
  if [ ! -f "$GATE" ]; then
    printf 'NO GATE\n'
    return 0
  fi
  dir="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    printf 'NO TMPDIR\n'
    return 0
  fi
  mkdir -p "$dir/repo/scripts"
  cp "$GATE" "$dir/repo/scripts/check-agents.sh"
  cp -R "$FIXTURES/agents-known-good/." "$dir/repo/"
  mkdir -p "$dir/stub"
  stub="$dir/stub/awk"
  printf '#!/bin/sh\nexit 2\n' >"$stub"
  chmod +x "$stub"
  (cd "$dir/repo" && PATH="$dir/stub:$PATH" bash scripts/check-agents.sh >/dev/null 2>&1)
  printf '%s\n' "$?"
  rm -rf "$dir"
}

SABOTAGE_RC="$(awk_sabotage_rc)"
assert_eq "broken awk: the gate refuses to certify instead of passing vacuously" "2" "$SABOTAGE_RC"

ts_report
