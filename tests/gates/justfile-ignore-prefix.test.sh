#!/usr/bin/env bash
# Gate: no recipe line in templates/justfile — the task runner scripts/init.sh installs into EVERY
# adopting repo — or in the kit's own justfile may carry just's `-` prefix.
#
# `-` means "ignore this line's exit status". A recipe line prefixed with it prints its failure and
# the recipe still exits 0, so a gate behind one cannot fail. The kit's own justfile states the rule
# in capitals on line 2 ("NEVER prefix a gate line with `-`") and obeys it; templates/justfile shipped
# 14 violations, including every line of lint-skills, lint-shell and hooks-check. A comment is not
# enforcement — this file is.
#
# The rule enforced here is blanket, not "gate lines only": there is no reliable way to tell a gate
# line from a convenience line by inspection, and `-` is never *needed*, because the legitimate case
# (skip work whose stack or tool is absent) is served by an explicit `if ... fi` guard that still
# fails when the tool is present and the command fails.
#
# Shebang recipes are exempt, and that exemption is a fact about just rather than a loophole:
# verified against just 1.57.0, a `-exit 1` line inside a `#!/usr/bin/env bash` recipe is handed to
# the interpreter verbatim ("-exit: command not found", recipe fails 127) — just does not read it as
# a prefix there, so flagging it would be wrong.
#
# Structured after tests/gates/check-links.test.sh:
#   1. assert_fixture states, as its own assertion, which files each row depends on. scan() refuses
#      to read a missing justfile (SCAN_RC=126) instead of reporting a clean file, because "no
#      offending lines" is exactly what scanning nothing produces.
#   2. verdict() has a distinct "vacuous" outcome for a file with zero recipe body lines, so a scan
#      that examined nothing can never be mistaken for a pass.
#   3. The real-file rows assert a floor on the number of lines examined, not just the verdict.
#   4. The adopter rows run the INSTALLED justfile (scripts/init.sh --target into a temp repo), not
#      the template, and prove a failing gate script really fails the recipe — plus a control that
#      re-adds the `-` and shows the same failure being swallowed, so the row above cannot pass for
#      a reason unrelated to the prefix.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
FIXTURES="$KIT/tests/fixtures"

# --- the scanner -------------------------------------------------------------------------------
# Emits one `PREFIX <lineno>: <text>` per offending line, then `EXAMINED <n>` and `HITS <n>`.
# just grammar, only as much as this needs: a recipe header is an unindented, uncommented line
# containing `:` but not `:=`; its body is the indented lines that follow, up to the next unindented
# non-blank line. Body lines that are comments, interpreter-script bodies (first body line starts
# `#!`), or continuations of a line ending `\` are not prefix positions and are not counted.
# shellcheck disable=SC2016 # awk program text: $0/RLENGTH are awk's, and must not expand in bash
SCANNER='
BEGIN { inrecipe = 0; shebang = 0; firstbody = 0; cont = 0; examined = 0; hits = 0 }
/^[ \t]*$/ { cont = 0; next }
/^[ \t]/ {
  if (!inrecipe) next
  body = $0
  sub(/^[ \t]+/, "", body)
  if (firstbody) { firstbody = 0; if (body ~ /^#!/) shebang = 1 }
  wascont = cont
  cont = ($0 ~ /\\$/) ? 1 : 0
  if (shebang) next
  if (wascont) next
  if (body ~ /^#/) next
  examined++
  if (match(body, /^[@-]+/)) {
    pfx = substr(body, 1, RLENGTH)
    if (index(pfx, "-") > 0) { hits++; printf "PREFIX %d: %s\n", NR, $0 }
  }
  next
}
{
  inrecipe = 0; shebang = 0; cont = 0
  if ($0 ~ /^#/) next
  if ($0 ~ /:=/) next
  if ($0 ~ /^[A-Za-z_][A-Za-z0-9_-]*([ \t]+[^:]*)?:/) { inrecipe = 1; firstbody = 1 }
}
END { printf "EXAMINED %d\nHITS %d\n", examined, hits }
'

SCAN_RC=0
SCAN_OUT=""
SCAN_EXAMINED=0
SCAN_HITS=0

# scan <justfile-path> — leaves SCAN_RC / SCAN_OUT / SCAN_EXAMINED / SCAN_HITS set.
scan() {
  local f="$1" out=""
  SCAN_RC=0
  SCAN_OUT=""
  SCAN_EXAMINED=0
  SCAN_HITS=0
  if [ ! -f "$f" ]; then
    # Refuse rather than scan nothing: an absent file yields zero offending lines, which is
    # indistinguishable from a clean file on the offender list alone.
    SCAN_RC=126
    SCAN_OUT="JUSTFILE MISSING: $f"
    return 0
  fi
  out="$(awk "$SCANNER" "$f")" || {
    SCAN_RC=125
    SCAN_OUT="SCANNER FAILED: $f"
    return 0
  }
  SCAN_OUT="$out"
  SCAN_EXAMINED="$(printf '%s\n' "$out" | awk '$1 == "EXAMINED" { print $2 }')"
  SCAN_HITS="$(printf '%s\n' "$out" | awk '$1 == "HITS" { print $2 }')"
}

# offenders — the offending lines alone, so a failing row prints the actual justfile text.
offenders() { printf '%s\n' "$SCAN_OUT" | awk '$1 == "PREFIX"'; }

# verdict — clean | offenders | vacuous | error, for the last scan.
verdict() {
  if [ "$SCAN_RC" -ne 0 ]; then
    echo error
  elif [ "$SCAN_EXAMINED" -eq 0 ]; then
    echo vacuous
  elif [ "$SCAN_HITS" -ne 0 ]; then
    echo offenders
  else
    echo clean
  fi
}

# at_least <n> — echoes "at least <n>" or "only <examined>", so the failure names the real count.
at_least() {
  if [ "$SCAN_EXAMINED" -ge "$1" ]; then echo "at least $1"; else echo "only $SCAN_EXAMINED"; fi
}

# assert_fixture <fixture> <file>... — precondition row: every listed file must be on disk before
# the row that follows means anything.
assert_fixture() {
  local fixture="$1" state="complete" missing="" f
  shift
  for f in "$@"; do
    if [ ! -f "$FIXTURES/$fixture/$f" ]; then missing="$missing $f"; fi
  done
  if [ -n "$missing" ]; then state="missing:$missing"; fi
  assert_eq "fixture $fixture is complete on disk" "complete" "$state"
}

exists() { if [ -f "$1" ]; then echo present; else echo absent; fi; }
nonzero() { if [ "$1" -ne 0 ]; then echo nonzero; else echo zero; fi; }

# --- the scanner can tell good from bad ---------------------------------------------------------

assert_fixture "justfile-dash-gate" "justfile"
scan "$FIXTURES/justfile-dash-gate/justfile"
assert_eq "dash-prefixed gate line: verdict is offenders" "offenders" "$(verdict)"
assert_eq "dash-prefixed gate line: exactly one hit" "1" "$SCAN_HITS"
assert_contains "dash-prefixed gate line: names the offending text" "-bash scripts/check-b.sh" "$SCAN_OUT"
assert_eq "dash-prefixed gate line: the un-prefixed sibling is not flagged" "" \
  "$(printf '%s\n' "$SCAN_OUT" | awk '$1 == "PREFIX" && /check-a/')"

assert_fixture "justfile-dash-clean" "justfile"
scan "$FIXTURES/justfile-dash-clean/justfile"
assert_eq "settings, continuations, shebang bodies and comments: verdict is clean" "clean" "$(verdict)"
assert_eq "clean fixture: no false positive" "" "$(offenders)"
# The count is exact on purpose: it pins which four lines are prefix positions, so a scanner that
# went clean by skipping everything (the way the defect under test goes green) fails this row.
assert_eq "clean fixture: the four real recipe lines were examined" "4" "$SCAN_EXAMINED"

assert_fixture "justfile-no-recipes" "justfile"
scan "$FIXTURES/justfile-no-recipes/justfile"
assert_eq "justfile with no recipe body lines: vacuous, not clean" "vacuous" "$(verdict)"
assert_eq "vacuous justfile: zero lines examined" "0" "$SCAN_EXAMINED"

# The harness's own missing-input guard. Without it, deleting a fixture above turns every "no
# offenders" assertion green for the wrong reason.
scan "$FIXTURES/justfile-does-not-exist/justfile"
assert_eq "absent justfile: refuses to scan rather than report it clean" "error" "$(verdict)"
assert_contains "absent justfile: says which path was missing" "JUSTFILE MISSING" "$SCAN_OUT"

# --- the real files -----------------------------------------------------------------------------

assert_eq "templates/justfile is on disk" "present" "$(exists "$KIT/templates/justfile")"
scan "$KIT/templates/justfile"
assert_eq "templates/justfile: no recipe line carries the ignore-exit-status prefix" "" "$(offenders)"
assert_eq "templates/justfile: verdict is clean" "clean" "$(verdict)"
assert_eq "templates/justfile: the scan really examined its recipe lines" "at least 15" "$(at_least 15)"

assert_eq "the kit's own justfile is on disk" "present" "$(exists "$KIT/justfile")"
scan "$KIT/justfile"
assert_eq "justfile: no recipe line carries the ignore-exit-status prefix" "" "$(offenders)"
assert_eq "justfile: verdict is clean" "clean" "$(verdict)"
assert_eq "justfile: the scan really examined its recipe lines" "at least 8" "$(at_least 8)"

# --- the adopter path: the INSTALLED justfile, executed --------------------------------------------
# Textual cleanliness is not the claim under test; "a failing gate fails the recipe in the file an
# adopter actually gets" is. That needs init.sh to have run and just to be present.

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

missing_tool=""
for tool in just mktemp; do
  command -v "$tool" >/dev/null 2>&1 || missing_tool="$tool"
done

if [ -n "$missing_tool" ]; then
  # Hard rule 4: self-skip for genuine tool absence only. Every assertion above still ran.
  ts_skip "adopter-justfile" "$missing_tool not available"
  ts_report
  exit 0
fi

WORK="$(mktemp -d 2>/dev/null || true)"
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  ts_skip "adopter-justfile" "mktemp -d failed"
  ts_report
  exit 0
fi

REPO="$WORK/adopter"
mkdir -p "$REPO"
INIT_OUT="$(bash "$KIT/scripts/init.sh" --target "$REPO" 2>&1)"
INIT_RC=$?
assert_eq "adopter: scripts/init.sh --target succeeds" "0" "$INIT_RC"
assert_contains "adopter: init.sh reports placing the justfile" "justfile" "$INIT_OUT"
assert_eq "adopter: a justfile is installed at the target root" "present" "$(exists "$REPO/justfile")"

scan "$REPO/justfile"
assert_eq "installed justfile: no recipe line carries the ignore-exit-status prefix" "" "$(offenders)"
assert_eq "installed justfile: verdict is clean" "clean" "$(verdict)"
assert_eq "installed justfile: the scan really examined its recipe lines" "at least 15" "$(at_least 15)"

# just_in <recipe> — runs the INSTALLED justfile from the adopter root. --justfile/--working-directory
# pin both, so a justfile anywhere above $TMPDIR cannot be picked up instead.
JUST_OUT=""
JUST_RC=0
just_in() {
  JUST_RC=0
  JUST_OUT="$(just --justfile "$REPO/justfile" --working-directory "$REPO" "$1" 2>&1)" || JUST_RC=$?
}

# A failing gate script must fail the recipe — and the lines before it must have run, proving the
# recipe did not abort early for an unrelated reason.
mkdir -p "$REPO/scripts"
printf '#!/usr/bin/env bash\necho RAN-SKILLS\n' >"$REPO/scripts/check-skills.sh"
printf '#!/usr/bin/env bash\necho RAN-STANDARDS\n' >"$REPO/scripts/check-standards.sh"
printf '#!/usr/bin/env bash\necho RAN-QUALITY\nexit 1\n' >"$REPO/scripts/check-skill-quality.sh"
just_in lint-skills
assert_eq "installed lint-skills: a failing gate script fails the recipe" "nonzero" "$(nonzero "$JUST_RC")"
assert_contains "installed lint-skills: the first gate line really ran" "RAN-SKILLS" "$JUST_OUT"
assert_contains "installed lint-skills: the second gate line really ran" "RAN-STANDARDS" "$JUST_OUT"
assert_contains "installed lint-skills: the failing gate line really ran" "RAN-QUALITY" "$JUST_OUT"

# Control for the row above: the same failing script behind a `-` prefix. If this exits 0 while the
# row above exits non-zero, the difference is the prefix and nothing else.
printf 'demo:\n    -bash scripts/check-skill-quality.sh\n    @echo REACHED\n' >"$WORK/dash.justfile"
DASH_RC=0
DASH_OUT="$(just --justfile "$WORK/dash.justfile" --working-directory "$REPO" demo 2>&1)" || DASH_RC=$?
assert_eq "control: behind a '-' prefix the identical failure is swallowed" "0" "$DASH_RC"
assert_contains "control: ...and the recipe carries on past it" "REACHED" "$DASH_OUT"

# Control: all gates pass -> recipe passes. Without this the row above is satisfied by a recipe that
# always fails.
printf '#!/usr/bin/env bash\necho RAN-QUALITY\n' >"$REPO/scripts/check-skill-quality.sh"
just_in lint-skills
assert_eq "installed lint-skills: all gates passing exits 0" "0" "$JUST_RC"
assert_contains "installed lint-skills: ...having really run them" "RAN-QUALITY" "$JUST_OUT"

# The promise the `-` was standing in for: in a repo that carries none of these scripts the recipe
# is a no-op, and says so rather than failing on a missing file.
rm -rf "$REPO/scripts"
just_in lint-skills
assert_eq "installed lint-skills: no scripts/ dir at all exits 0" "0" "$JUST_RC"
assert_contains "installed lint-skills: ...and names what it skipped" "skip: scripts/check-skills.sh not present" "$JUST_OUT"

# Same shape for the shell recipes, which globbed hooks/*.sh scripts/*.sh unguarded.
just_in lint-shell
assert_eq "installed lint-shell: no shell dirs exits 0" "0" "$JUST_RC"
assert_contains "installed lint-shell: ...and says it skipped" "skip:" "$JUST_OUT"

just_in hooks-check
assert_eq "installed hooks-check: no shell dirs exits 0" "0" "$JUST_RC"
assert_contains "installed hooks-check: ...and says it skipped" "skip:" "$JUST_OUT"

# hooks-check used to run `bash -n hooks/*.sh scripts/*.sh templates/*.sh`, which syntax-checks the
# FIRST file only and passes the rest as positional arguments — a broken second file exited 0. Put
# the broken file second and require a failure.
mkdir -p "$REPO/scripts"
printf '#!/usr/bin/env bash\necho fine\n' >"$REPO/scripts/aaa-ok.sh"
printf '#!/usr/bin/env bash\nif [ 1 ; then\n' >"$REPO/scripts/zzz-broken.sh"
just_in hooks-check
assert_eq "installed hooks-check: a syntax error in a NON-first file fails the recipe" "nonzero" "$(nonzero "$JUST_RC")"
assert_contains "installed hooks-check: names the broken file" "zzz-broken.sh" "$JUST_OUT"

rm -f "$REPO/scripts/zzz-broken.sh"
just_in hooks-check
assert_eq "installed hooks-check: syntactically valid scripts exit 0" "0" "$JUST_RC"

ts_report
