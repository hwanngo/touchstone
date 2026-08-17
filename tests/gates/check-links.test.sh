#!/usr/bin/env bash
# Gate: scripts/check-links.sh must be non-vacuous. The audit's finding: run it from an empty
# directory and it prints "All internal links resolve." and exits 0 having examined nothing — the
# one gate missing the repo-root cd its siblings all have. It also stripped #anchor before testing
# (anchors never validated), skipped any link containing a space (hiding escaped/encoded-space
# breakage), only stripped ``` fences (not ~~~), parsed inline code spans as real links, ignored
# reference-style definitions, and matched `http*` as a glob (skipping a *relative* link merely
# named "http...md" as if it were external). It also never checked the ~123 prose `<file>.md §N`
# cross-references sprinkled through standards/ for being in range.
#
# Each fixture under tests/fixtures/links-* is a minimal tree with exactly one real defect (or, for
# the "ignored" fixtures, exactly one thing that must NOT be flagged). We exercise the real
# scripts/check-links.sh by copying it into each fixture's own scripts/ dir and running it from
# there — the same repo-root-relative-to-itself shape a real adopting repo has — rather than
# asserting the gate agrees with a hand-written expectation of what it should print.
#
# EVERY row below is guarded two ways, because two rows in the first version of this file passed
# with their fixtures deleted:
#   1. assert_fixture states, as its own assertion, which files the row depends on. run_gate copies
#      the fixture into an empty temp tree, so a DELETED fixture leaves the gate scanning nothing —
#      which exits non-zero, satisfying every "exits non-zero" assertion for entirely the wrong
#      reason. The empty-tree row is structurally incapable of telling the two apart on exit code
#      alone: a missing fixture reproduces the exact condition under test.
#   2. Every exit-code assertion is paired with an assert_contains on the specific message that
#      verdict should carry, so "non-zero" is never accepted on its own.
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
GATE="$KIT/scripts/check-links.sh"
FIXTURES="$KIT/tests/fixtures"

# Hard rule 4: self-skip only for genuine tool absence, never for anything check-links.sh itself
# does — tests/run.sh exits on failures only, so a skip on the behaviour under test would read as
# green while leaving it unverified.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "check-links" "mktemp not available"
  ts_report
  exit 0
fi

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# assert_fixture <fixture> <file>... — precondition row: every listed file must be on disk before
# the row that follows means anything. Name every file whose absence would change the verdict, not
# just one: with links-bad-anchor/target.md deleted, for instance, the gate reports a plain BROKEN
# whose text still contains the anchor name, so the row's assert_contains would pass too.
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
# (bulk generated content; paths the repo's .gitignore excludes), installs a copy of the real gate
# at <tree>/scripts/check-links.sh (mirroring how an adopting repo carries its own copy, per
# scripts/init.sh), runs it from <tree>, and leaves GATE_RC / GATE_OUT set.
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
  # else. Without that, an out-of-repo resolution cannot be exercised without leaving litter in
  # $TMPDIR.
  mkdir -p "$WORK/repo"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  if [ -n "$builder" ]; then "$builder" "$WORK/repo"; fi
  mkdir -p "$WORK/repo/scripts"
  cp "$GATE" "$WORK/repo/scripts/check-links.sh"
  GATE_RC=0
  GATE_OUT="$(cd "$WORK/repo" && bash scripts/check-links.sh 2>&1)" || GATE_RC=$?
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

# LARGE_HEADINGS — comfortably past the 500-to-1000-heading threshold at which the old
# `heading_slugs "$1" | grep -qxF "$2"` pipeline short-circuited: grep -q exited on its first match,
# the awk upstream took SIGPIPE and exited 141, and `set -o pipefail` promoted that 141 to the
# pipeline status, so a VALID anchor was reported BROKEN-ANCHOR. Generated here rather than
# committed: the file is ~35 KB of pure filler with no other test value.
LARGE_HEADINGS=1500
build_large_anchor_target() {
  local dst="$1/target.md" i=0
  {
    printf '# Target\n\n## First Heading\n\nBody.\n\n'
    while [ "$i" -lt "$LARGE_HEADINGS" ]; do
      printf '## Filler Heading %d\n\nBody.\n\n' "$i"
      i=$((i + 1))
    done
  } >"$dst"
}

# A REAL file placed above the scanned tree, so a gate with no containment check resolves the
# fixture's ../../ link and ../../ section reference against it and exits 0.
build_outside_repo_target() {
  printf '# Outside\n\n## 2. Second Section\n\nBody.\n' >"$1/../outside-doc.md"
}

# .superpowers/ is git-ignored (so it cannot be committed as fixture data) agent scratch that
# markdownlint already ignores. Scanning it makes writing about this gate break this gate.
build_superpowers_scratch() {
  mkdir -p "$1/.superpowers/sdd/notes"
  printf '# Note\n\nA planning draft naming [gone](really-missing.md).\n' >"$1/.superpowers/sdd/notes/draft.md"
}

# --- defect fixtures: the gate must exit non-zero and name the actual broken thing -------------

assert_fixture "links-broken-relative" "index.md"
run_gate "links-broken-relative"
assert_eq "broken relative link: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "broken relative link: names missing.md" "BROKEN: ./index.md -> missing.md" "$GATE_OUT"

assert_fixture "links-bad-anchor" "index.md" "target.md"
run_gate "links-bad-anchor"
assert_eq "bogus #anchor on a real file: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "bogus #anchor: reports it as an ANCHOR failure, not a missing file" "BROKEN-ANCHOR" "$GATE_OUT"
assert_contains "bogus #anchor: names the bad anchor" "not-a-real-heading" "$GATE_OUT"

# The empty-tree row cannot be defended by its exit code at all: deleting the fixture reproduces the
# exact condition under test. Only the precondition row above and the message below tell the two
# apart.
assert_fixture "links-empty" ".gitkeep"
run_gate "links-empty"
assert_eq "empty tree (no markdown at all): exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty tree: says it found no markdown, not that links resolve" "No markdown files found" "$GATE_OUT"
assert_eq "empty tree: claims nothing about links" "absent" "$(gate_out_has "All internal links resolve")"

assert_fixture "links-bad-refdef" "index.md"
run_gate "links-bad-refdef"
assert_eq "broken reference-style definition: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "broken reference-style definition: names missing-target.md" "BROKEN: ./index.md -> missing-target.md" "$GATE_OUT"

assert_fixture "links-http-name-detected" "index.md"
run_gate "links-http-name-detected"
assert_eq "relative link named like a scheme (http-notes.md): exits non-zero" "nonzero" "$(nonzero)"
assert_contains "http-named relative link: names http-notes.md" "BROKEN: ./index.md -> http-notes.md" "$GATE_OUT"

assert_fixture "links-title-suffix-detected" "index.md"
run_gate "links-title-suffix-detected"
assert_eq "link with title suffix at a missing file: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "title-suffixed link: names missing-with-title.md" "BROKEN: ./index.md -> missing-with-title.md" "$GATE_OUT"

# Stripping the title must not stop the destination being checked, in any title form.
assert_fixture "links-single-quoted-title-detected" "index.md"
run_gate "links-single-quoted-title-detected"
assert_eq "single-quoted title at a missing file: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "single-quoted title: names missing-single.md" "missing-single.md" "$GATE_OUT"
# ...and the reported target must be the destination alone. Without this row the assertion above
# also passes on the unfixed gate, which reported the whole unstripped `missing-single.md 'Some
# Title'` as the target — non-zero for the wrong reason.
assert_eq "single-quoted title: title is stripped, not treated as part of the path" "absent" "$(gate_out_has "Some Title")"

assert_fixture "links-section-ref-bad" "doc.md" "referencer.md"
run_gate "links-section-ref-bad"
assert_eq "out-of-range §N section reference: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "out-of-range §N: names the missing section, not just any failure" "BROKEN-SECTION: ./referencer.md -> doc.md" "$GATE_OUT"
assert_contains "out-of-range §N: says which heading is absent" "no '## 3.' heading" "$GATE_OUT"

# A tilde marker inside a backtick block must not close that block. With a single shared fence
# toggle it did, and every line after it was dropped: the gate examined half the file, found
# nothing broken in the half it read, and exited 0.
assert_fixture "links-nested-fence-detected" "index.md"
run_gate "links-nested-fence-detected"
assert_eq "tilde marker shown inside a backtick fence: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "nested fence marker: still sees the link after the fence" "BROKEN: ./index.md -> really-missing.md" "$GATE_OUT"

# A file that ends inside an unclosed fence has its tail dropped before parsing. Report it rather
# than silently declaring the unexamined half of the file link-clean.
assert_fixture "links-unclosed-fence-detected" "index.md"
run_gate "links-unclosed-fence-detected"
assert_eq "file ending inside an unclosed fence: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "unclosed fence: says so explicitly" "UNCLOSED-FENCE: ./index.md" "$GATE_OUT"

# The independent-fence-marker fix lives in three places. links-nested-fence-detected above pins
# only one of them (the link-stripping pass); reverting the other two to a shared toggle left the
# suite fully green. These two rows pin the remaining two.
#
# fence_unclosed: a ``` block that is never closed but contains a ~~~ line. A shared toggle sees
# ``` open / ~~~ close, calls the file balanced, and reports nothing whatsoever — the file has no
# links, so the gate exits 0 having examined a file whose tail it silently dropped.
assert_fixture "links-nested-marker-unclosed-detected" "index.md"
run_gate "links-nested-marker-unclosed-detected"
assert_eq "unclosed fence containing a nested marker: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "nested marker in an unclosed fence: still reported as unclosed" "UNCLOSED-FENCE: ./index.md" "$GATE_OUT"

# section_refs: a ``` block containing a ~~~ line, followed by an out-of-range §N reference. Under
# a shared toggle the real closing marker re-opens a fence, so the paragraph holding the reference
# is never scanned and the bad reference is silently unchecked.
assert_fixture "links-nested-marker-section-ref-detected" "doc.md" "referencer.md"
run_gate "links-nested-marker-section-ref-detected"
assert_eq "§N reference after a fence containing a nested marker: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "nested marker: the §N reference past the fence is still scanned" "BROKEN-SECTION: ./referencer.md -> doc.md" "$GATE_OUT"
assert_contains "nested marker: and says which heading is absent" "no '## 9.' heading" "$GATE_OUT"

# A fence marker indented four spaces or more, outside any list, is the BODY of an indented code
# block — not a fence opener. Reading it as one produced a false UNCLOSED-FENCE and dropped the
# rest of the file, so the defect that was really there went unreported.
assert_fixture "links-indented-fence-marker-detected" "index.md"
run_gate "links-indented-fence-marker-detected"
assert_eq "fence marker inside an indented code block: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "indented fence marker: the link after it is still checked" "BROKEN: ./index.md -> really-missing.md" "$GATE_OUT"
assert_eq "indented fence marker: not mistaken for an unclosed fence" "absent" "$(gate_out_has "UNCLOSED-FENCE")"

# A link or §N token that climbs above the scanned tree must be reported, not resolved.
assert_fixture "links-outside-repo-detected" "sub/index.md"
run_gate "links-outside-repo-detected" build_outside_repo_target
assert_eq "link and §N ref resolving above the scan root: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "out-of-repo link: says so explicitly" "OUT-OF-REPO: ./sub/index.md" "$GATE_OUT"
assert_contains "out-of-repo §N token: refuses to resolve it" "could not resolve" "$GATE_OUT"

# --- must-ignore fixtures: the gate must exit 0, i.e. NOT flag the embedded broken link ---------

# These fixtures contain no link at all outside the construct under test, so asserting the reported
# link count is 0 proves the construct was stripped before parsing — a stronger claim than "exited
# 0", which a gate that resolved the link by luck would also satisfy.
#
# They are also the only trees in this file that contain markdown but no links at all, so they are
# where the "claim success only for categories that had inputs" fix is pinned: without the two
# `nothing was verified` / `absent` rows below, replacing that conditional report with an
# unconditional "All internal links resolve." left the whole suite green. A gate that asserts a
# property of the empty set is the defect this file exists to prevent.
assert_fixture "links-tilde-fence-ignored" "index.md"
run_gate "links-tilde-fence-ignored"
assert_eq "broken link inside a ~~~ fence: exits 0 (ignored)" "0" "$GATE_RC"
assert_contains "~~~ fence body: no link extracted from it" "0 internal link(s)" "$GATE_OUT"
assert_contains "~~~ fence body: says nothing was verified, having verified nothing" "No links, anchors or §N section references present — nothing was verified." "$GATE_OUT"
assert_eq "~~~ fence body: makes no success claim about the empty link set" "absent" "$(gate_out_has "All internal links resolve")"

assert_fixture "links-code-span-ignored" "index.md"
run_gate "links-code-span-ignored"
assert_eq "broken link inside an inline code span: exits 0 (ignored)" "0" "$GATE_RC"
assert_contains "inline code span: no link extracted from it" "0 internal link(s)" "$GATE_OUT"
assert_contains "inline code span: says nothing was verified, having verified nothing" "No links, anchors or §N section references present — nothing was verified." "$GATE_OUT"
assert_eq "inline code span: makes no success claim about the empty link set" "absent" "$(gate_out_has "All internal links resolve")"

# A fence indented to a list item's content column is a real fence. The indented-code-block fix
# above must not be spelled as "fence markers only at columns 0-3": that would leave this fixture's
# fence body unstripped and its sample link reported as a genuine broken link. The body line here
# sits at column 0, so an implementation that fell back to indented-code stripping would not save
# it either.
assert_fixture "links-list-nested-fence-ignored" "index.md"
run_gate "links-list-nested-fence-ignored"
assert_eq "fence indented to a list item's content column: exits 0 (ignored)" "0" "$GATE_RC"
assert_contains "list-nested fence body: no link extracted from it" "0 internal link(s)" "$GATE_OUT"

# Ordinary prose opening with `[Label]:` is not a link reference definition — its remainder is a
# sentence, not a single-token destination. Reading it as one invents a broken link.
assert_fixture "links-prose-refdef-ignored" "index.md"
run_gate "links-prose-refdef-ignored"
assert_eq "prose opening with [Label]: exits 0 (not a definition)" "0" "$GATE_RC"
assert_contains "prose [Label]: not read as a definition at all" "0 internal link(s)" "$GATE_OUT"

# .superpowers/ is excluded from the scan, matching .markdownlint-cli2.jsonc.
assert_fixture "links-superpowers-ignored" "index.md"
run_gate "links-superpowers-ignored" build_superpowers_scratch
assert_eq "broken link under .superpowers/: exits 0 (excluded)" "0" "$GATE_RC"
assert_contains ".superpowers/ file is not even counted" "Checked 1 markdown file(s)" "$GATE_OUT"

# Every CommonMark title form, and the angle-bracket destination, at the same real file.
assert_fixture "links-title-forms-good" "index.md" "other.md"
run_gate "links-title-forms-good"
assert_eq "single/double/parenthesised titles and <dest>: exits 0" "0" "$GATE_RC"
assert_contains "all seven title/destination forms are extracted and checked" "7 internal link(s)" "$GATE_OUT"

assert_fixture "links-large-anchor-target" "index.md"
run_gate "links-large-anchor-target" build_large_anchor_target
assert_eq "valid anchor in a $LARGE_HEADINGS-heading target: exits 0" "0" "$GATE_RC"
assert_contains "large target: the anchor really was checked" "1 anchor(s)" "$GATE_OUT"
assert_contains "large target: valid anchor is not reported broken" "All #anchor fragments resolve" "$GATE_OUT"

# --- controls: must pass, proving the harness can tell good from bad ----------------------------

assert_fixture "links-known-good" "index.md" "other.md" "my file.md"
run_gate "links-known-good"
assert_eq "known-good tree: exits 0" "0" "$GATE_RC"
assert_contains "known-good tree: all three files were scanned" "Checked 3 markdown file(s)" "$GATE_OUT"
assert_contains "known-good tree: its six links were really checked" "6 internal link(s)" "$GATE_OUT"
assert_contains "known-good tree: its two anchors were really checked" "2 anchor(s)" "$GATE_OUT"

# A root-absolute destination resolves against the SCAN ROOT, not the citing file's directory, so
# the same link is judged identically from `./index.md` and from `./sub/index.md`. It used to
# resolve by accident only from the root (`.//standards/x.md`) and be reported BROKEN from every
# subdirectory. The link count also pins the protocol-relative URL as external: were it resolved on
# disk it would be a third counted link, and a broken one.
assert_fixture "links-root-absolute-good" "index.md" "sub/index.md" "standards/x.md"
run_gate "links-root-absolute-good"
assert_eq "root-absolute link from both the root and a subdirectory: exits 0" "0" "$GATE_RC"
assert_contains "root-absolute link: both citing files' links were really checked" "2 internal link(s)" "$GATE_OUT"
assert_eq "root-absolute link: not reported broken from the subdirectory" "absent" "$(gate_out_has "BROKEN")"

assert_fixture "links-section-ref-good" "doc.md" "referencer.md"
run_gate "links-section-ref-good"
assert_eq "in-range §N section reference: exits 0" "0" "$GATE_RC"
assert_contains "in-range §N: the reference was really examined" "1 §N section reference(s)" "$GATE_OUT"
assert_contains "in-range §N: and reported in range" "All §N section references are in range." "$GATE_OUT"

# --- a broken awk must fail the gate, not silently disable it -----------------------------------

# Every scan this gate performs runs in awk, inside a pipeline or command substitution whose failure
# the caller never sees. With awk broken, all four scans returned empty, the gate printed "nothing
# was verified" and exited 0 — certifying a tree it had never read. That is the silent-disable class
# this campaign treats as P0 wherever it appears, so it is pinned here: remove the preflight from
# scripts/check-links.sh and this row goes red.
#
# awk is shadowed by a stub earlier on PATH rather than removed, because an awk that RUNS and
# produces wrong output is the case a `command -v` check would miss.
awk_sabotage_rc() {
  local dir stub
  dir="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    printf 'NO TMPDIR\n'
    return 0
  fi
  mkdir -p "$dir/repo/scripts" "$dir/stub"
  cp "$GATE" "$dir/repo/scripts/check-links.sh"
  printf '# T\n\nA link: [x](nope.md)\n' >"$dir/repo/a.md"
  stub="$dir/stub/awk"
  printf '#!/bin/sh\nexit 2\n' >"$stub"
  chmod +x "$stub"
  (cd "$dir/repo" && PATH="$dir/stub:$PATH" bash scripts/check-links.sh >/dev/null 2>&1)
  printf '%s\n' "$?"
  rm -rf "$dir"
}

SABOTAGE_RC="$(awk_sabotage_rc)"
assert_eq "broken awk: the gate refuses to certify instead of passing vacuously" "2" "$SABOTAGE_RC"

ts_report
