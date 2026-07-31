#!/usr/bin/env bash
# Gate: touchstone must satisfy its own repo-meta checklist item.
#
# standards/practices/collaboration.md closes with:
#
#   - [ ] Repo meta in place: `.editorconfig`, `.gitattributes`, CODEOWNERS, SECURITY.md, PR/issue templates
#
# The kit stated that rule, shipped templates for every item of it (templates/github/CODEOWNERS,
# templates/SECURITY.md, templates/github/pull_request_template.md, templates/github/ISSUE_TEMPLATE/)
# — and had none of them itself. templates/github/pull_request_template.md even carries the header
# comment "Place at .github/PULL_REQUEST_TEMPLATE.md", advice the kit never took. A standards kit
# that fails its own checklist cannot credibly enforce it, so the checklist is now mechanical.
#
# THE REQUIRED SET IS NOT WRITTEN DOWN HERE. It is READ, at run time, from the checklist line in
# standards/practices/collaboration.md — the single declared place. This file contributes only a
# resolver: which path on disk satisfies a checklist token ("CODEOWNERS" -> .github/CODEOWNERS, and
# the two other locations GitHub honours). The resolver is pinned to the prose in BOTH directions:
#   - a token in the prose that the resolver cannot resolve fails the gate (the checklist grew an
#     item nothing checks — the exact drift that produced this defect);
#   - a token the resolver knows that the prose no longer names also fails (the gate is demanding
#     something the standard stopped asking for).
# So the list cannot drift from the checklist prose without going red, in either direction.
#
# Two content assertions go beyond mere presence, taken from the two lines of the same doc that
# elaborate the checklist item: CODEOWNERS "keyed to teams with a catch-all fallback", and
# SECURITY.md "(private disclosure contact)". A CODEOWNERS whose rules match no path, and a
# SECURITY.md naming no way to report privately, are files that exist and guard nothing — presence
# alone would be a checkbox this gate could satisfy while the defect remained.
#
# The checker is a pure function of the root it is handed and MUST NOT reference $KIT: a checker
# that self-located would scan the real repo while appearing to scan a fixture, and every row here
# would be measuring the wrong tree. The repo-meta-empty rows exist to prove that has not happened.
#
# EVERY row is guarded two ways, matching tests/gates/check-links.test.sh and doc-claims.test.sh:
#   1. assert_fixture states, as its own assertion, which files the row depends on. run_check copies
#      the fixture into an empty temp tree, so a DELETED fixture leaves the checker unable to read
#      any checklist at all — which exits non-zero, satisfying every "exits non-zero" assertion for
#      entirely the wrong reason. run_check additionally refuses to run on a missing fixture dir.
#   2. Every exit-code assertion is paired with an assert_contains on the specific message that
#      verdict should carry, so "non-zero" is never accepted on its own.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
FIXTURES="$KIT/tests/fixtures"

# Hard rule 4: self-skip only for genuine tool absence, never for anything the checker itself does —
# tests/run.sh exits on failures only, so a skip on the behaviour under test would read as green
# while leaving it unverified.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "repo-meta" "mktemp not available"
  ts_report
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# The declared source of truth, and the resolver.
# ---------------------------------------------------------------------------------------------

CHECKLIST_DOC="standards/practices/collaboration.md"
CHECKLIST_PREFIX="- [ ] Repo meta in place:"

# META_TOKENS — every checklist token meta_requirements() below can resolve, one per line. This is
# the resolver's half of the two-way pin described in the header: it is compared against the tokens
# actually parsed out of the checklist line, and any difference either way fails the gate.
META_TOKENS='.editorconfig
.gitattributes
CODEOWNERS
SECURITY.md
PR/issue templates'

# meta_requirements <token> — print one requirement per line, or return 1 for an unknown token.
#
# Requirement syntax:
#   file:<a>|<b>|...   satisfied when ANY of those paths exists (alternatives are the several
#                      locations GitHub honours for the same file — none is more correct)
#   forms:<dir>        satisfied when <dir> exists and holds at least one issue form
#
# Written as a top-level function, never inline inside "$( … )": a `case` pattern's ')' terminates
# a command substitution in bash 3.2, yielding an assertion that compares literal shell text and
# can never fail. That mistake has been made twice in this repo.
meta_requirements() {
  case "$1" in
  '.editorconfig')
    printf 'file:.editorconfig\n'
    ;;
  '.gitattributes')
    printf 'file:.gitattributes\n'
    ;;
  'CODEOWNERS')
    printf 'file:.github/CODEOWNERS|CODEOWNERS|docs/CODEOWNERS\n'
    ;;
  'SECURITY.md')
    printf 'file:SECURITY.md|.github/SECURITY.md|docs/SECURITY.md\n'
    ;;
  'PR/issue templates')
    # "PR/issue templates" is one checklist token naming two independent artefacts, so it expands
    # to two requirements — a PR template alone must not tick the box.
    printf 'file:.github/PULL_REQUEST_TEMPLATE.md|.github/pull_request_template.md|PULL_REQUEST_TEMPLATE.md|docs/PULL_REQUEST_TEMPLATE.md\n'
    printf 'forms:.github/ISSUE_TEMPLATE\n'
    ;;
  *)
    return 1
    ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The checker. A pure function of <root>.
# ---------------------------------------------------------------------------------------------

# checklist_tokens <doc> — print the comma-separated items of the repo-meta checklist line, one per
# line, with backticks/bold markers and surrounding space stripped. Prints nothing if the line is
# absent, which the caller treats as a failure rather than as an empty requirement set.
checklist_tokens() {
  local line
  # -e, not a bare pattern: the checklist prefix starts with "- ", which grep would read as options.
  line="$(grep -F -e "$CHECKLIST_PREFIX" "$1" | head -1)"
  [ -n "$line" ] || return 0
  printf '%s\n' "${line#*"$CHECKLIST_PREFIX"}" |
    tr ',' '\n' |
    sed 's/[`*]//g; s/^[[:space:]]*//; s/[[:space:]]*$//' |
    sed '/^$/d'
}

# has_line <file> <extended-regex> — "yes"/"no". grep -c, not a `case` in a substitution, and the
# count is read from stdout so no exit status travels through a pipeline.
has_line() {
  local n
  n="$(grep -Ec "$2" "$1" 2>/dev/null)"
  [ -n "$n" ] || n=0
  if [ "$n" -gt 0 ]; then echo yes; else echo no; fi
}

# resolve_alt <root> <a|b|c> — echo the first alternative that exists under <root>, or nothing.
resolve_alt() {
  local root="$1" alts="$2" p
  # shellcheck disable=SC2086 # deliberate word splitting on the '|' separator via IFS
  local IFS='|'
  for p in $alts; do
    [ -n "$p" ] || continue
    if [ -e "$root/$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 0
}

# check_repo_meta <root> — the gate.
check_repo_meta() {
  # Two statements, not one: `local a="$1" b="$a/x"` expands $a in the CALLER's scope (the words are
  # expanded before the `local` builtin runs), which under `set -u` is an unbound-variable abort.
  local root="$1"
  local doc="$root/$CHECKLIST_DOC"
  local tokens="" tok reqs req kind spec hit dir forms
  local rc=0 examined=0 ntokens=0

  if [ ! -f "$doc" ]; then
    echo "FAIL: no $CHECKLIST_DOC under $root — the repo-meta checklist could not be read; nothing was verified."
    return 1
  fi

  tokens="$(checklist_tokens "$doc")"
  if [ -z "$tokens" ]; then
    echo "FAIL: $CHECKLIST_DOC has no '$CHECKLIST_PREFIX' line — the checklist this gate mirrors was reworded or removed; nothing was verified."
    return 1
  fi

  # --- forward pin: every token the checklist names must resolve, and be satisfied on disk -------
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    ntokens=$((ntokens + 1))
    reqs="$(meta_requirements "$tok")" || {
      echo "FAIL: the checklist names '$tok' but this gate has no requirement declared for it — add one to meta_requirements()."
      rc=1
      continue
    }
    while IFS= read -r req; do
      [ -n "$req" ] || continue
      kind="${req%%:*}"
      spec="${req#*:}"
      examined=$((examined + 1))
      if [ "$kind" = "forms" ]; then
        dir="$root/$spec"
        forms=0
        if [ -d "$dir" ]; then
          forms="$(find "$dir" -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.md' \) ! -name 'config.yml' ! -name 'config.yaml' | wc -l | tr -d ' ')"
        fi
        if [ "$forms" -gt 0 ]; then
          echo "  ok  $tok: $spec holds $forms issue form(s)."
        else
          echo "MISSING: checklist item '$tok' — $spec holds no issue form (a config.yml chooser alone is not a template)."
          rc=1
        fi
        continue
      fi
      hit="$(resolve_alt "$root" "$spec")"
      if [ -n "$hit" ]; then
        echo "  ok  $tok: $hit"
      else
        echo "MISSING: checklist item '$tok' — none of these paths exist: $(printf '%s' "$spec" | tr '|' ' ')"
        rc=1
      fi
    done <<EOF
$reqs
EOF
  done <<EOF
$tokens
EOF

  # --- reverse pin: the resolver must not require anything the checklist stopped naming ----------
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if [ "$(printf '%s\n' "$tokens" | grep -cxF -e "$tok")" -eq 0 ]; then
      echo "FAIL: this gate requires '$tok' but $CHECKLIST_DOC no longer names it — the gate and the checklist have drifted apart."
      rc=1
    fi
  done <<EOF
$META_TOKENS
EOF

  # --- content: the two lines of the same doc that elaborate the checklist item ------------------
  # "CODEOWNERS keyed to teams with a catch-all fallback" — a CODEOWNERS whose rules match no path
  # is silently a no-op, which is exactly how this class of defect hides.
  hit="$(resolve_alt "$root" "$(meta_requirements CODEOWNERS | sed 's/^file://')")"
  if [ -n "$hit" ]; then
    examined=$((examined + 1))
    if [ "$(has_line "$root/$hit" '^\*[[:space:]]+[^[:space:]]')" = "yes" ]; then
      echo "  ok  CODEOWNERS: has a catch-all '*' rule."
    else
      echo "WEAK: $hit has no catch-all '*' rule — $CHECKLIST_DOC requires a catch-all fallback."
      rc=1
    fi
  fi

  # "SECURITY.md (private disclosure contact)" — a policy with no way to report privately is prose.
  hit="$(resolve_alt "$root" "$(meta_requirements SECURITY.md | sed 's/^file://')")"
  if [ -n "$hit" ]; then
    examined=$((examined + 1))
    if [ "$(has_line "$root/$hit" 'security/advisories/new|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')" = "yes" ]; then
      echo "  ok  SECURITY.md: names a private disclosure channel."
    else
      echo "WEAK: $hit names no private disclosure contact — neither a private-advisory URL nor an email address."
      rc=1
    fi
  fi

  # Never pass on nothing. A run that examined zero requirements verified zero things.
  echo "Examined $examined requirement(s) from $ntokens checklist token(s) in $CHECKLIST_DOC."
  if [ "$examined" -eq 0 ]; then
    echo "FAIL: no repo-meta requirements were examined — this gate verified nothing."
    rc=1
  fi

  [ "$rc" -eq 0 ] && echo "All repo-meta checklist items are satisfied."
  return "$rc"
}

# ---------------------------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------------------------

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# assert_fixture <fixture> <file>... — precondition row: every listed file must be on disk before
# the row that follows means anything. Name every file whose absence would change the verdict: with
# repo-meta-no-catch-all/.github/CODEOWNERS deleted, for instance, the checker reports a MISSING
# instead of a WEAK and the row's "exits non-zero" assertion would still pass.
assert_fixture() {
  local fixture="$1" state="complete" missing="" f
  shift
  for f in "$@"; do
    if [ ! -f "$FIXTURES/$fixture/$f" ]; then missing="$missing $f"; fi
  done
  if [ -n "$missing" ]; then state="missing:$missing"; fi
  assert_eq "fixture $fixture is complete on disk" "complete" "$state"
}

# run_check <fixture-name> — copies tests/fixtures/<fixture-name> into a fresh tmp tree and runs
# check_repo_meta against that tree, leaving CHK_RC / CHK_OUT set.
CHK_RC=0
CHK_OUT=""
run_check() {
  local fixture="$1"
  if [ ! -d "$FIXTURES/$fixture" ]; then
    # Refuse to run rather than silently check an empty tree. Paired with assert_fixture above and
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
  CHK_OUT="$(check_repo_meta "$WORK/repo" 2>&1)" || CHK_RC=$?
  rm -rf "$WORK"
  WORK=""
}

# out_has <needle> — "present"/"absent", so a row can assert something is NOT in the output using
# the same assert_eq every other row uses.
out_has() {
  case "$CHK_OUT" in
  *"$1"*) echo present ;;
  *) echo absent ;;
  esac
}

nonzero() { if [ "$CHK_RC" -ne 0 ]; then echo nonzero; else echo zero; fi; }

# ---------------------------------------------------------------------------------------------
# Rows: the control. The harness must be able to tell a satisfied checklist from a broken one.
# ---------------------------------------------------------------------------------------------

assert_fixture "repo-meta-complete" \
  "standards/practices/collaboration.md" ".editorconfig" ".gitattributes" \
  ".github/CODEOWNERS" "SECURITY.md" ".github/PULL_REQUEST_TEMPLATE.md" \
  ".github/ISSUE_TEMPLATE/bug_report.yml"
run_check "repo-meta-complete"
assert_eq "every checklist item present: exits 0" "0" "$CHK_RC"
assert_contains "complete tree: all five tokens and both PR/issue requirements were examined" "from 5 checklist token(s)" "$CHK_OUT"
assert_contains "complete tree: says so" "All repo-meta checklist items are satisfied." "$CHK_OUT"
assert_contains "complete tree: the issue forms really were counted" "holds 1 issue form(s)" "$CHK_OUT"

# ---------------------------------------------------------------------------------------------
# Rows: a checklist item that is not on disk.
# ---------------------------------------------------------------------------------------------

assert_fixture "repo-meta-missing-security" \
  "standards/practices/collaboration.md" ".editorconfig" ".gitattributes" \
  ".github/CODEOWNERS" ".github/PULL_REQUEST_TEMPLATE.md" ".github/ISSUE_TEMPLATE/bug_report.yml"
run_check "repo-meta-missing-security"
assert_eq "checklist names SECURITY.md and there is none: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "missing SECURITY.md: names the checklist item" "MISSING: checklist item 'SECURITY.md'" "$CHK_OUT"
assert_contains "missing SECURITY.md: lists every location it looked in" "SECURITY.md .github/SECURITY.md docs/SECURITY.md" "$CHK_OUT"
assert_eq "missing SECURITY.md: makes no success claim" "absent" "$(out_has "All repo-meta checklist items are satisfied")"
# The other items are still checked — one failure must not short-circuit the rest.
assert_contains "missing SECURITY.md: the PR template is still checked" "ok  PR/issue templates: .github/PULL_REQUEST_TEMPLATE.md" "$CHK_OUT"

# ---------------------------------------------------------------------------------------------
# Rows: a file that exists and guards nothing. Presence alone must not tick the box.
# ---------------------------------------------------------------------------------------------

assert_fixture "repo-meta-no-catch-all" \
  "standards/practices/collaboration.md" ".github/CODEOWNERS" "SECURITY.md" \
  ".github/PULL_REQUEST_TEMPLATE.md" ".github/ISSUE_TEMPLATE/bug_report.yml"
run_check "repo-meta-no-catch-all"
assert_eq "CODEOWNERS present but with no catch-all: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "no catch-all: says which file and what is missing" "WEAK: .github/CODEOWNERS has no catch-all" "$CHK_OUT"
# Without this row the assertion above also passes on a CODEOWNERS that is simply absent — a
# different defect with a different fix.
assert_eq "no catch-all: the file itself was found, so this is not a MISSING" "absent" "$(out_has "MISSING: checklist item 'CODEOWNERS'")"

# ---------------------------------------------------------------------------------------------
# Rows: the two-way pin between the checklist prose and this gate's resolver.
# ---------------------------------------------------------------------------------------------

# The checklist grows an item. Every file on disk is fine; the gate must still go red, because a
# checklist item nothing checks is how the original defect survived.
assert_fixture "repo-meta-prose-drift" "standards/practices/collaboration.md" "SECURITY.md" ".github/CODEOWNERS"
run_check "repo-meta-prose-drift"
assert_eq "checklist names an item the resolver does not know: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "prose drift: names the unresolvable token" "the checklist names 'FUNDING.yml' but this gate has no requirement declared for it" "$CHK_OUT"
assert_eq "prose drift: the tree is otherwise complete, so no item is reported missing" "absent" "$(out_has "MISSING: checklist item")"

# The checklist loses an item. The gate must not keep silently demanding it.
assert_fixture "repo-meta-prose-shrunk" "standards/practices/collaboration.md" "SECURITY.md"
run_check "repo-meta-prose-shrunk"
assert_eq "checklist stops naming SECURITY.md: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "prose shrunk: says the gate and the checklist drifted apart" "this gate requires 'SECURITY.md' but $CHECKLIST_DOC no longer names it" "$CHK_OUT"

# ---------------------------------------------------------------------------------------------
# Rows: nothing to read. Both must fail, and with distinguishable messages — an empty tree and a
# reworded checklist are different problems with different fixes.
# ---------------------------------------------------------------------------------------------

assert_fixture "repo-meta-no-checklist" "standards/practices/collaboration.md" "SECURITY.md"
run_check "repo-meta-no-checklist"
assert_eq "collaboration.md without the repo-meta line: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "reworded checklist: says the line is gone, not that the doc is gone" "has no '$CHECKLIST_PREFIX' line" "$CHK_OUT"
assert_contains "reworded checklist: states that nothing was verified" "nothing was verified" "$CHK_OUT"
assert_eq "reworded checklist: makes no success claim" "absent" "$(out_has "All repo-meta checklist items are satisfied")"

# The row that proves the checker reads the tree it is handed and not the repo this file lives in:
# against the real kit it reports five satisfied tokens.
assert_fixture "repo-meta-empty" ".gitkeep"
run_check "repo-meta-empty"
assert_eq "empty tree: exits non-zero" "nonzero" "$(nonzero)"
assert_contains "empty tree: says the checklist could not be read at all" "no $CHECKLIST_DOC under" "$CHK_OUT"
assert_eq "empty tree: did not check the real repo instead" "absent" "$(out_has "ok  SECURITY.md")"

# ---------------------------------------------------------------------------------------------
# Rows: the real repo. The fixtures prove the checker works; these prove touchstone passes it.
# ---------------------------------------------------------------------------------------------

REAL_RC=0
REAL_OUT="$(check_repo_meta "$KIT" 2>&1)" || REAL_RC=$?
assert_eq "touchstone satisfies its own repo-meta checklist" "0" "$REAL_RC"
CHK_OUT="$REAL_OUT"
assert_eq "touchstone: the checklist really was read and had tokens" "absent" "$(out_has "from 0 checklist token(s)")"
assert_contains "touchstone: its own CODEOWNERS has a catch-all" "ok  CODEOWNERS: has a catch-all" "$CHK_OUT"
assert_contains "touchstone: its own SECURITY.md names a private channel" "ok  SECURITY.md: names a private disclosure channel" "$CHK_OUT"
# These two name the exact resolved paths rather than resting on the exit code above. Deleting the
# PR template or emptying .github/ISSUE_TEMPLATE otherwise fails only the rc row, whose output is
# the bare "expected 0, actual 1" — true, but it does not say which of the five items broke.
assert_contains "touchstone: its PR template sits where its own template says to put it" "ok  PR/issue templates: .github/PULL_REQUEST_TEMPLATE.md" "$CHK_OUT"
assert_contains "touchstone: its issue forms were really counted" "ok  PR/issue templates: .github/ISSUE_TEMPLATE holds" "$CHK_OUT"

ts_report
