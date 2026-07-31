#!/usr/bin/env bash
# Gate: the kit's own prose must not make claims about the kit's own contents that the filesystem
# contradicts. A kit whose purpose is enforcing standards cannot ship false claims about itself, and
# unverified documentation is precisely the defect class this gate exists to stop recurring.
#
# Two claim shapes are mechanically checkable and are checked here:
#
#   A. COUNTS — "61 Agent Skills", "66 domain docs". A registry maps each countable noun phrase to a
#      filesystem measurement; every occurrence of "<number> <registered phrase>" anywhere in the
#      kit's markdown is compared against that measurement. The registry is the only hand-written
#      part: which files constitute "a domain doc" cannot be inferred from the prose. Claims are
#      DISCOVERED, not hand-listed, so a count added to a doc tomorrow is checked tomorrow.
#
#   B. NON-EXISTENCE — "no standalone `vue.md`". The filename is extracted and the tree is searched
#      for it; finding it is a failure. This is the exact defect that motivated the gate:
#      standards/frameworks/nuxt.md asserted there was no vue.md long after vue.md was added.
#
# WHAT IS DELIBERATELY NOT ENFORCED. A general "every claim matches reality" gate is not tractable
# in bash — most claims are about the world (tool behaviour, ecosystem state), not about this repo,
# and nothing mechanical can adjudicate them. Even within this repo the following stay unenforced:
#   - Prose lists asserted to be complete (README's per-domain standards index, AGENTS.md's routing
#     table, skills/README.md's skill table). Verifiable in principle, but matching a prose list to
#     a directory listing needs a naming convention the docs do not consistently carry.
#   - Counts written as words ("the five entries") rather than digits.
#   - Non-existence claims naming something other than a markdown file ("no separate dart skill").
#   - The second and later filenames on a line making several non-existence claims at once
#     ("no speculative `qwik.md` / `remix.md` / `quarkus.md`" checks only qwik.md).
# Those are stated here rather than silently omitted, so the gate's coverage is not mistaken for
# total coverage.
#
# The two checkers below are pure functions of the root they are handed. They MUST NOT reference
# $KIT: a checker that self-locates would scan the real repo while appearing to scan a fixture, and
# every row here would then be measuring the wrong tree. The claims-empty rows exist specifically to
# prove that has not happened — an empty tree must report finding nothing, not the real repo's
# numbers.
#
# EVERY row is guarded two ways, matching tests/gates/check-links.test.sh:
#   1. assert_fixture states, as its own assertion, which files the row depends on. run_check copies
#      the fixture into an empty temp tree, so a DELETED fixture leaves the checker scanning an empty
#      tree — which exits non-zero, satisfying every "exits non-zero" assertion for entirely the
#      wrong reason. run_check additionally refuses to run at all on a missing fixture directory.
#   2. Every exit-code assertion is paired with an assert_contains on the specific message that
#      verdict should carry, so "non-zero" is never accepted on its own.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
FIXTURES="$KIT/tests/fixtures"

# Hard rule 4: self-skip only for genuine tool absence, never for anything the checkers themselves
# do — tests/run.sh exits on failures only, so a skip on the behaviour under test would read as
# green while leaving it unverified.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "doc-claims" "mktemp not available"
  ts_report
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# The checkers. Pure functions of <root>.
# ---------------------------------------------------------------------------------------------

# docs_under <root> — every markdown file the kit authors, one per line.
# .git/ and node_modules/ are not ours. .superpowers/ is git-ignored agent scratch that
# .markdownlint-cli2.jsonc already excludes — and it holds the notes written ABOUT this gate, which
# quote the very claims the gate rejects, so scanning it would make writing about the gate break it.
# tests/ holds fixtures that assert deliberately-false claims for exactly this reason.
docs_under() {
  find "$1" \
    -name .git -prune -o \
    -name .superpowers -prune -o \
    -name node_modules -prune -o \
    -name tests -prune -o \
    -name '*.md' -print
}

# The count registry. Each phrase is measured by measure_claim() below. Phrases are matched
# case-insensitively after backticks and asterisks are stripped, so `**61 Agent Skills**` and
# "61 agent skills" are the same claim.
COUNT_PHRASES='agent skills|content skills|domain docs|standards docs|agent hooks'

# measure_claim <root> <phrase> — the filesystem's answer, or -1 for an unregistered phrase.
measure_claim() {
  local root="$1" phrase="$2" n
  case "$phrase" in
  'agent skills')
    n="$(find "$root/skills" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')"
    ;;
  'content skills')
    # Every skill except the `touchstone` router meta-skill.
    n="$(find "$root/skills" -name 'SKILL.md' 2>/dev/null | grep -c '/touchstone/SKILL.md$')"
    n="$(($(find "$root/skills" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ') - n))"
    ;;
  'standards docs')
    n="$(find "$root/standards" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    ;;
  'domain docs')
    # One doc per stack/area: everything under standards/ that is neither a directory index nor the
    # cross-cutting self-audit checklist.
    n="$(find "$root/standards" -name '*.md' ! -name 'README.md' ! -name 'self-audit.md' 2>/dev/null | wc -l | tr -d ' ')"
    ;;
  'agent hooks')
    # The hook entrypoints only — hooks/lib/ holds sourced helpers, not hooks.
    n="$(find "$root/hooks" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')"
    ;;
  *)
    n=-1
    ;;
  esac
  printf '%s\n' "$n"
}

# awk program: emit "<file>:<line>|<phrase>|<number>" for each "<number> <registered phrase>".
# A number glued to a preceding word or hyphen is not a count ("ERC-721 agent hooks" is not a claim
# of 721). Fenced blocks are skipped: sample output is not a claim about this repo.
# shellcheck disable=SC2016 # awk program text: $0/RSTART are awk's, and must not expand in bash
AWK_COUNTS='
BEGIN { np = split(PHRASES, P, "|") }
/^[ \t]*(```|~~~)/ { fence = !fence; next }
fence { next }
{
  line = tolower($0)
  gsub(/[`*]/, "", line)
  for (k = 1; k <= np; k++) {
    s = line
    while ((i = index(s, P[k])) > 0) {
      pre = substr(s, 1, i - 1)
      if (match(pre, /[0-9]+[ ]+$/)) {
        b = (RSTART > 1) ? substr(pre, RSTART - 1, 1) : " "
        if (b !~ /[-a-z0-9.]/) {
          n = substr(pre, RSTART, RLENGTH)
          sub(/[ ]+$/, "", n)
          print FN ":" FNR "|" P[k] "|" n
        }
      }
      s = substr(s, i + length(P[k]))
    }
  }
}'

# check_counts <root> — every discovered count claim must equal its measurement.
check_counts() {
  local root="$1" list claims rc=0 nfiles nclaims f loc phrase claimed actual
  list="$(mktemp 2>/dev/null)" || return 3
  claims="$(mktemp 2>/dev/null)" || {
    rm -f "$list"
    return 3
  }
  docs_under "$root" >"$list"
  nfiles="$(wc -l <"$list" | tr -d ' ')"
  if [ "$nfiles" -eq 0 ]; then
    echo "FAIL: No markdown files found under $root — nothing was examined."
    rm -f "$list" "$claims"
    return 1
  fi
  : >"$claims"
  while IFS= read -r f; do
    awk -v FN="${f#"$root"/}" -v PHRASES="$COUNT_PHRASES" "$AWK_COUNTS" "$f" >>"$claims"
  done <"$list"
  nclaims="$(wc -l <"$claims" | tr -d ' ')"
  echo "Checked $nfiles markdown file(s); examined $nclaims count claim(s)."
  if [ "$nclaims" -eq 0 ]; then
    # A vacuous pass is the failure mode this whole campaign exists to remove. The kit's meta-docs
    # do state their inventory; a tree where none do is one where this gate cannot be shown to be
    # live, so it must be resolved deliberately rather than reported as green.
    echo "FAIL: no count claims found — this gate verified nothing."
    rc=1
  fi
  while IFS='|' read -r loc phrase claimed; do
    [ -n "$loc" ] || continue
    actual="$(measure_claim "$root" "$phrase")"
    if [ "$actual" -lt 0 ]; then
      echo "FAIL: $loc claims $claimed $phrase but '$phrase' has no registered measurement."
      rc=1
    elif [ "$actual" -eq 0 ]; then
      echo "FAIL: $loc claims $claimed $phrase but the filesystem yields 0 — nothing was measured."
      rc=1
    elif [ "$claimed" != "$actual" ]; then
      echo "FAIL: $loc claims $claimed $phrase; the filesystem has $actual."
      rc=1
    else
      echo "  ok  $loc: $claimed $phrase matches the filesystem."
    fi
  done <"$claims"
  rm -f "$list" "$claims"
  [ "$rc" -eq 0 ] && echo "All count claims match the filesystem."
  return "$rc"
}

# awk program: emit "<file>:<line>|<name>.md" for each "no {standalone,separate,dedicated,
# speculative} <name>.md". Only the filename immediately following the adjective is taken — a line
# like nuxt.md's carries unrelated .md links that are not part of the claim.
# shellcheck disable=SC2016 # awk program text: $0/RSTART are awk's, and must not expand in bash
AWK_ABSENCE='
/^[ \t]*(```|~~~)/ { fence = !fence; next }
fence { next }
{
  s = tolower($0)
  gsub(/[`*]/, "", s)
  while (match(s, /(^|[^a-z])no (standalone|separate|dedicated|speculative) +[a-z0-9._+-]+\.md/)) {
    # Save the outer match position BEFORE the inner match() overwrites RSTART/RLENGTH. Without
    # this the loop rewinds instead of advancing and reports every claim twice.
    rs = RSTART
    rl = RLENGTH
    seg = substr(s, rs, rl)
    if (match(seg, /[a-z0-9._+-]+\.md$/)) {
      print FN ":" FNR "|" substr(seg, RSTART, RLENGTH)
    }
    s = substr(s, rs + rl)
  }
}'

# check_absence <root> — every "there is no <x>.md" claim must still be true.
check_absence() {
  local root="$1" list claims rc=0 nfiles nclaims f loc name hit
  list="$(mktemp 2>/dev/null)" || return 3
  claims="$(mktemp 2>/dev/null)" || {
    rm -f "$list"
    return 3
  }
  docs_under "$root" >"$list"
  nfiles="$(wc -l <"$list" | tr -d ' ')"
  if [ "$nfiles" -eq 0 ]; then
    echo "FAIL: No markdown files found under $root — nothing was examined."
    rm -f "$list" "$claims"
    return 1
  fi
  : >"$claims"
  while IFS= read -r f; do
    awk -v FN="${f#"$root"/}" "$AWK_ABSENCE" "$f" >>"$claims"
  done <"$list"
  nclaims="$(wc -l <"$claims" | tr -d ' ')"
  echo "Checked $nfiles markdown file(s); examined $nclaims absence claim(s)."
  # Unlike counts, zero absence claims is a legitimate state — a kit that never says "there is no X"
  # has nothing here to be wrong about. Non-vacuity is carried by the file count above.
  while IFS='|' read -r loc name; do
    [ -n "$loc" ] || continue
    hit="$(docs_under "$root" | grep -i "/$name\$" | head -1)"
    if [ -n "$hit" ]; then
      echo "STALE: $loc says there is no $name, but ${hit#"$root"/} exists."
      rc=1
    else
      echo "  ok  $loc: $name really does not exist."
    fi
  done <"$claims"
  rm -f "$list" "$claims"
  [ "$rc" -eq 0 ] && echo "All non-existence claims are still true."
  return "$rc"
}

# ---------------------------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------------------------

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# assert_fixture <fixture> <file>... — precondition row: every listed file must be on disk before
# the row that follows means anything. Name every file whose absence would change the verdict:
# with claims-absence-stale/standards/frameworks/vue.md deleted, for instance, the checker correctly
# reports nothing and the row's "exits non-zero" assertion would fail for the right reason — but
# with claims-counts-bad/skills/beta/SKILL.md deleted the count is merely wrong by a different
# amount and the row would still pass.
assert_fixture() {
  local fixture="$1" state="complete" missing="" f
  shift
  for f in "$@"; do
    if [ ! -f "$FIXTURES/$fixture/$f" ]; then missing="$missing $f"; fi
  done
  if [ -n "$missing" ]; then state="missing:$missing"; fi
  assert_eq "fixture $fixture is complete on disk" "complete" "$state"
}

# run_check <fixture-name> <checker-fn> — copies tests/fixtures/<fixture-name> into a fresh tmp tree
# and runs <checker-fn> against that tree, leaving CHK_RC / CHK_OUT set. The checkers take their
# root as an argument and never self-locate, so this really does examine the fixture and not the
# repo the test file happens to live in.
CHK_RC=0
CHK_OUT=""
run_check() {
  local fixture="$1" fn="$2"
  if [ ! -d "$FIXTURES/$fixture" ]; then
    # Refuse to run rather than silently scan an empty tree. Paired with assert_fixture above and
    # the assert_contains on every row, a missing fixture fails loudly instead of masquerading as a
    # correct non-zero verdict.
    CHK_RC=126
    CHK_OUT="FIXTURE MISSING: $FIXTURES/$fixture"
    return 0
  fi
  WORK="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    CHK_RC=127
    CHK_OUT="mktemp -d failed"
    return 0
  fi
  mkdir -p "$WORK/repo"
  cp -R "$FIXTURES/$fixture/." "$WORK/repo/"
  CHK_RC=0
  CHK_OUT="$("$fn" "$WORK/repo" 2>&1)" || CHK_RC=$?
  rm -rf "$WORK"
  WORK=""
}

# out_has <needle> — echoes "present" or "absent", so a row can assert something is NOT in the
# output using the same assert_eq every other row uses.
out_has() {
  case "$CHK_OUT" in
  *"$1"*) echo present ;;
  *) echo absent ;;
  esac
}

nonzero() { if [ "$CHK_RC" -ne 0 ]; then echo nonzero; else echo zero; fi; }

# ---------------------------------------------------------------------------------------------
# Rows: counts
# ---------------------------------------------------------------------------------------------

assert_fixture "claims-counts-bad" "README.md" "skills/alpha/SKILL.md" "skills/beta/SKILL.md"
run_check "claims-counts-bad" check_counts
assert_eq "count claim contradicted by the tree: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "wrong count: names the claim, the file, and both numbers" "README.md:3 claims 3 agent skills; the filesystem has 2" "$CHK_OUT"

assert_fixture "claims-counts-good" "README.md" "skills/alpha/SKILL.md" "skills/beta/SKILL.md" "standards/languages/x.md" "standards/languages/y.md"
run_check "claims-counts-good" check_counts
assert_eq "counts matching the tree: exits 0" "0" "$CHK_RC"
assert_contains "matching counts: both claims were really examined" "examined 2 count claim(s)" "$CHK_OUT"
assert_contains "matching counts: says so" "All count claims match the filesystem." "$CHK_OUT"

# The vacuity row. A tree of markdown that asserts no counts leaves this checker with nothing to
# verify, and "nothing to verify" must never be reported as green.
assert_fixture "claims-counts-none" "README.md"
run_check "claims-counts-none" check_counts
assert_eq "markdown but no count claims: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no count claims: refuses to report a vacuous pass" "no count claims found — this gate verified nothing" "$CHK_OUT"
assert_eq "no count claims: claims nothing about counts matching" "absent" "$(out_has "All count claims match")"

# Two things that look like counts and are not: a number inside a fenced sample block, and a digit
# glued to a preceding word ("ERC-721 agent hooks"). Either one read as a claim would fail the run —
# 99 skills against 2, or 721 hooks against a tree with no hooks/ at all — so "exits 0 having
# examined exactly 1 claim" is a stronger statement than the exit code alone.
assert_fixture "claims-counts-noise-ignored" "README.md" "skills/alpha/SKILL.md" "skills/beta/SKILL.md"
run_check "claims-counts-noise-ignored" check_counts
assert_eq "fenced sample and hyphen-glued digit: exits 0" "0" "$CHK_RC"
assert_contains "noise: exactly one real claim was extracted" "examined 1 count claim(s)" "$CHK_OUT"
assert_eq "noise: the fenced 99 was never read as a claim" "absent" "$(out_has "claims 99")"
assert_eq "noise: ERC-721 was never read as a claim of 721" "absent" "$(out_has "721 agent hooks")"

# ---------------------------------------------------------------------------------------------
# Rows: non-existence
# ---------------------------------------------------------------------------------------------

assert_fixture "claims-absence-stale" "standards/frameworks/nuxt.md" "standards/frameworks/vue.md"
run_check "claims-absence-stale" check_absence
assert_eq "doc says no vue.md while vue.md exists: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "stale absence claim: names the claiming file and the file that exists" "STALE: standards/frameworks/nuxt.md:3 says there is no vue.md" "$CHK_OUT"
assert_contains "stale absence claim: points at the real file" "standards/frameworks/vue.md exists" "$CHK_OUT"

assert_fixture "claims-absence-true" "standards/frameworks/flutter.md"
run_check "claims-absence-true" check_absence
assert_eq "doc says no dart.md and there is none: exits 0" "0" "$CHK_RC"
assert_contains "true absence claim: it really was examined, not skipped" "examined 1 absence claim(s)" "$CHK_OUT"
assert_contains "true absence claim: says so" "All non-existence claims are still true." "$CHK_OUT"

# ---------------------------------------------------------------------------------------------
# Rows: an empty tree. These are the rows that prove the checkers examine the tree they are handed
# and not the repo this file lives in — against the real repo both report dozens of files.
# ---------------------------------------------------------------------------------------------

assert_fixture "claims-empty" ".gitkeep"
run_check "claims-empty" check_counts
assert_eq "empty tree (counts): exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty tree (counts): says it found no markdown" "No markdown files found" "$CHK_OUT"
assert_eq "empty tree (counts): did not scan the real repo instead" "absent" "$(out_has "agent skills matches")"

run_check "claims-empty" check_absence
assert_eq "empty tree (absence): exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty tree (absence): says it found no markdown" "No markdown files found" "$CHK_OUT"

# ---------------------------------------------------------------------------------------------
# Rows: the real repo. The fixtures prove the checkers work; these prove touchstone passes them.
# ---------------------------------------------------------------------------------------------

REAL_COUNTS_RC=0
REAL_COUNTS_OUT="$(check_counts "$KIT" 2>&1)" || REAL_COUNTS_RC=$?
assert_eq "touchstone's own count claims all match the filesystem" "0" "$REAL_COUNTS_RC"
CHK_OUT="$REAL_COUNTS_OUT"
assert_eq "touchstone: at least one count claim was examined" "absent" "$(out_has "examined 0 count claim(s)")"

REAL_ABSENCE_RC=0
REAL_ABSENCE_OUT="$(check_absence "$KIT" 2>&1)" || REAL_ABSENCE_RC=$?
assert_eq "touchstone's own non-existence claims are all still true" "0" "$REAL_ABSENCE_RC"
CHK_OUT="$REAL_ABSENCE_OUT"
assert_eq "touchstone: at least one absence claim was examined" "absent" "$(out_has "examined 0 absence claim(s)")"

ts_report
