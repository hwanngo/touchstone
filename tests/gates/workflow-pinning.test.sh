#!/usr/bin/env bash
# Gate: the `workflows` job in .github/workflows/ci.yml — `pinact run --check --verify` (ci-cd.md
# §4) and `zizmor` (ci-cd.md §1, §6) over the kit's OWN workflows. Hard rule 8 says CI is hardened
# by pinning every action to a SHA; until that job existed, nothing in the kit enforced it, so an
# unpinned `uses:` could land with every gate green.
#
# The scope is the whole difficulty. templates/github/workflows/** ships TAG-pinned (`@v7`) BY
# DESIGN — an adopter runs `pinact run` once against their own repo — so a repo-wide pin check
# fails on files that are correct, and the obvious fix (exclude enough to make it pass) ends in a
# check that examines nothing. Both halves are asserted below: the enumerated scope must contain
# the kit's own workflows and must NOT reach into templates/, and an empty scope must FAIL.
#
# That last row is not hypothetical. Measured against pinact v4.1.1: `pinact run -fix=false` over
# an empty .github/workflows exits 0, and over an ABSENT .github/workflows also exits 0. A scoped
# pin check whose scope silently stops matching therefore reports green while certifying nothing —
# strictly worse than having no check, because it also removes the reason to add one.
#
# As in tests/gates/ci-required-aggregator.test.sh, the shell under test is EXTRACTED FROM THE
# WORKFLOW AT TEST TIME and executed, never copied here: a test carrying its own transcription of
# the logic keeps passing after someone edits the workflow.
#
# The tools themselves are not invoked here. `pinact`/`zizmor` are absent from the runner that
# executes this suite, and a row that shells out to them would either skip (leaving the guard
# unverified) or need the network. What IS driven end-to-end is every line of the job's shell that
# runs BEFORE the tool — the enumeration and the two empty-scope guards — plus an independent,
# tool-free re-derivation of the pin property over the real workflow files, so the kit's own pins
# are verified by this suite even where pinact cannot run.
#
# Fixtures are built under mktemp rather than committed to tests/fixtures/. A committed
# tests/fixtures/*/.github/workflows/*.yml is collected by any repo-wide `zizmor .` (verified: its
# default collection globs **/.github/workflows/), so the fixture for this gate would become a trap
# for this gate.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
WORKFLOW="$KIT/.github/workflows/ci.yml"
JOB="workflows"

# Hard rule 4: skip only for genuine tool absence. mktemp is the one external dependency here.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "workflow-pinning" "mktemp not available"
  ts_report
  exit 0
fi

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# wf <mode> [n] [job] — run-block-aware reader for the workflow. Modes:
#   jobs   every job name under the top-level `jobs:` key, one per line
#   job    the named job's block, verbatim
#   count  how many `run: |` blocks the named job has
#   body   the n-th (1-based) `run: |` block of the named job, dedented to column 0
# Pure awk, for the reason check-skills.sh/check-standards.sh are: a test needing jq/yq/python is a
# test that silently skips on the machine that lacks it.
# The job defaults to $JOB and is overridable per call — a `JOB=other wf ...` prefix would leak
# past the call in bash and silently repoint every later invocation.
wf() {
  awk -v job="${3:-$JOB}" -v mode="$1" -v want="${2:-0}" '
    function indent_of(s,   n) { n = match(s, /[^ ]/); if (n == 0) return -1; return n - 1 }
    BEGIN { in_jobs = 0; in_job = 0; in_run = 0; runs = 0; body_indent = -1; pending = 0 }
    {
      line = $0
      ind = indent_of(line)
      blank = (line ~ /^[ \t]*$/)

      # Run-block bodies are arbitrary text, so they are consumed before any structural test.
      if (in_run) {
        if (blank) { pending++; next }
        if (body_indent < 0) {
          if (ind > run_indent) { body_indent = ind } else { in_run = 0 }
        }
        if (in_run && ind >= body_indent) {
          while (pending > 0) { if (mode == "job" || (mode == "body" && runs == want)) print ""; pending-- }
          if (mode == "body" && runs == want) print substr(line, body_indent + 1)
          if (mode == "job") print line
          next
        }
        pending = 0
        in_run = 0
      }

      if (blank) next

      # A non-comment line at column 0 opens a new top-level key: only `jobs:` holds job names, so
      # `on:`/`permissions:`/`concurrency:` children at indent 2 are never read as jobs.
      if (ind == 0) {
        if (line !~ /^#/) { in_jobs = (line ~ /^jobs:[ \t]*$/); in_job = 0 }
        next
      }

      if (in_jobs && ind == 2 && line ~ /^  [A-Za-z0-9_.-]+:[ \t]*$/) {
        name = line
        sub(/^  /, "", name)
        sub(/:[ \t]*$/, "", name)
        if (mode == "jobs") print name
        in_job = (name == job)
        next
      }

      if (in_job && line ~ /^ +run:[ \t]*\|[ \t]*$/) {
        run_indent = ind
        body_indent = -1
        in_run = 1
        runs++
        if (mode == "job") print line
        next
      }

      if (in_job && mode == "job") print line
    }
    END { if (mode == "count") print runs }
  ' "$WORKFLOW"
}

# in_list <needle> <space-separated haystack> — echoes present/absent. A function, not an inline
# `case` inside "$( ... )": the pattern's `)` terminates the substitution there and yields an
# assertion that can never fail. That mistake has been made twice in this repo.
in_list() {
  local needle="$1" list="$2" item
  for item in $list; do
    if [ "$item" = "$needle" ]; then
      echo present
      return 0
    fi
  done
  echo absent
}

file_state() { if [ -f "$1" ]; then echo present; else echo absent; fi; }

# has <haystack> <needle> — echoes yes/no. Also a function rather than an inline `case` inside
# "$( ... )", for the same bash 3.2 parse reason as in_list above.
has() {
  case "$1" in
  *"$2"*) echo yes ;;
  *) echo no ;;
  esac
}

# --- preconditions: nothing below means anything if these fail -----------------------------------

assert_eq "the kit's CI workflow is on disk" "present" "$(file_state "$WORKFLOW")"

JOB_NAMES=""
if [ -f "$WORKFLOW" ]; then JOB_NAMES="$(wf jobs)"; fi
assert_eq "a job named '$JOB' exists in it (a rename must fail here, not silently pass)" \
  "present" "$(in_list "$JOB" "$JOB_NAMES")"

JOB_BLOCK=""
RUN_COUNT="0"
if [ -f "$WORKFLOW" ]; then
  JOB_BLOCK="$(wf job)"
  RUN_COUNT="$(wf count)"
fi
# enumerate + the pinact guard + the zizmor guard. A dropped step changes this number, and every
# row below that drives block 2 or 3 would otherwise silently drive the wrong shell.
assert_eq "$JOB has exactly three run: blocks (enumerate, pinact, zizmor)" "3" "$RUN_COUNT"

# The gate only gates if the aggregator requires it — ci-required is the single branch-protection
# check, so a job missing from its needs: is a job that cannot block a merge.
AGG_NEEDS="$(wf job 0 ci-required | grep -m1 '^ *needs:' || true)"
assert_contains "ci-required requires the $JOB job (otherwise it cannot block a merge)" \
  "$JOB" "$AGG_NEEDS"

WORK="$(mktemp -d 2>/dev/null || true)"
assert_eq "a scratch directory was created for the fixtures" "yes" \
  "$(if [ -n "$WORK" ] && [ -d "$WORK" ]; then echo yes; else echo no; fi)"

# Materialise each run block exactly as GitHub does: a file invoked with `bash -e {0}`.
ENUM="" PINACT="" ZIZMOR=""
if [ -n "$WORK" ] && [ -d "$WORK" ] && [ "$RUN_COUNT" = "3" ]; then
  ENUM="$WORK/enumerate.sh"
  PINACT="$WORK/pinact.sh"
  ZIZMOR="$WORK/zizmor.sh"
  wf body 1 >"$ENUM"
  wf body 2 >"$PINACT"
  wf body 3 >"$ZIZMOR"
fi

nonempty() { if [ -n "$1" ] && [ -s "$1" ]; then echo yes; else echo no; fi; }
assert_eq "the enumerate run: block was extracted" "yes" "$(nonempty "$ENUM")"
assert_eq "the pinact run: block was extracted" "yes" "$(nonempty "$PINACT")"
assert_eq "the zizmor run: block was extracted" "yes" "$(nonempty "$ZIZMOR")"

# Extraction is by position, so pin what each position is. Without these, a reordering of the steps
# would have every row below asserting against the wrong block, and most would still pass.
assert_contains "block 1 is the enumerator (writes WORKFLOW_FILES)" \
  "WORKFLOW_FILES=" "$(cat "$ENUM" 2>/dev/null)"
assert_contains "block 2 is the pinact step" "pinact" "$(cat "$PINACT" 2>/dev/null)"
assert_contains "block 3 is the zizmor step" "zizmor" "$(cat "$ZIZMOR" 2>/dev/null)"

# --- fixtures ------------------------------------------------------------------------------------

# populated: two workflows the check must see, one non-workflow file it must not count, and a
# tag-pinned template it must not reach.
if [ -n "$WORK" ] && [ -d "$WORK" ]; then
  mkdir -p "$WORK/populated/.github/workflows" "$WORK/populated/templates/github/workflows"
  printf 'name: a\non: push\n' >"$WORK/populated/.github/workflows/alpha.yml"
  printf 'name: b\non: push\n' >"$WORK/populated/.github/workflows/beta.yaml"
  printf 'not a workflow\n' >"$WORK/populated/.github/workflows/notes.txt"
  printf 'name: t\non: push\njobs:\n  x:\n    steps:\n      - uses: actions/checkout@v7\n' \
    >"$WORK/populated/templates/github/workflows/tagged.yml"
  # emptydir: the directory survives but matches nothing — the shape pinact exits 0 on.
  mkdir -p "$WORK/emptydir/.github/workflows"
  # nodir: no .github at all — the other shape pinact exits 0 on.
  mkdir -p "$WORK/nodir"
fi

CASE_OUT=""
CASE_RC=0
ENV_FILE=""

# run_enum <fixture-dir> — drives the enumerate block with cwd set to the fixture, GITHUB_ENV
# pointed at a scratch file. Command substitution, never a pipeline: `cmd | tail` would capture
# tail's status.
run_enum() {
  CASE_RC=0
  CASE_OUT=""
  ENV_FILE="$WORK/github_env"
  : >"$ENV_FILE"
  if [ -z "$ENUM" ] || [ ! -s "$ENUM" ] || [ ! -d "$1" ]; then
    CASE_RC=126
    CASE_OUT="FIXTURE OR RUN BLOCK MISSING"
    return 0
  fi
  CASE_OUT="$(cd "$1" && GITHUB_ENV="$ENV_FILE" bash -e "$ENUM" 2>&1)" || CASE_RC=$?
}

# run_guard <block-file> <set|unset> [value] — drives a consumer block's empty-scope guard. Only
# the guard: the positive path shells out to pinact/zizmor, which are not present here.
run_guard() {
  CASE_RC=0
  CASE_OUT=""
  if [ -z "$1" ] || [ ! -s "$1" ]; then
    CASE_RC=126
    CASE_OUT="RUN BLOCK MISSING"
    return 0
  fi
  if [ "$2" = "unset" ]; then
    CASE_OUT="$(env -u WORKFLOW_FILES bash -e "$1" 2>&1)" || CASE_RC=$?
  else
    CASE_OUT="$(WORKFLOW_FILES="${3:-}" bash -e "$1" 2>&1)" || CASE_RC=$?
  fi
}

rc() { printf 'rc=%s' "$CASE_RC"; }
env_value() { sed -n 's/^WORKFLOW_FILES=//p' "$ENV_FILE" 2>/dev/null | tail -1; }

# --- the scope the two tools are pointed at -------------------------------------------------------

run_enum "$WORK/populated"
assert_eq "a repo with workflows: the enumerate step exits 0" "rc=0" "$(rc)"
assert_contains "it reports how many files it found, not just that it ran" \
  "2 workflow file(s) in scope" "$CASE_OUT"
SCOPE="$(env_value)"
assert_eq "the exported scope is exactly the two workflow files, in glob order" \
  ".github/workflows/alpha.yml .github/workflows/beta.yaml" "$SCOPE"

# The constraint that makes this gate hard: templates/** is tag-pinned on purpose, so a scope that
# reaches it fails on correct files and the check gets weakened or deleted.
assert_eq "the scope does not reach templates/ (tag-pinned by design)" "no" "$(has "$SCOPE" templates)"
assert_eq "a non-workflow file in .github/workflows/ is not handed to the tools" "no" \
  "$(has "$SCOPE" notes.txt)"

# --- the vacuous pass: the single most likely failure mode of a scoped check -----------------------

run_enum "$WORK/emptydir"
assert_eq "an EMPTY .github/workflows fails instead of certifying nothing" "rc=1" "$(rc)"
assert_contains "empty scope: says why, in terms of the empty set" \
  "refusing to certify an empty set" "$CASE_OUT"
assert_eq "empty scope: nothing was exported for the tools to consume" "" "$(env_value)"

run_enum "$WORK/nodir"
assert_eq "an ABSENT .github/workflows fails too (pinact exits 0 on it)" "rc=1" "$(rc)"
assert_contains "absent scope: says why" "refusing to certify an empty set" "$CASE_OUT"

# Each consumer re-guards, so the gate does not depend on step ordering or on `set -e` propagating
# from a step that did not run.
run_guard "$PINACT" unset
assert_eq "pinact step with WORKFLOW_FILES unset: exits non-zero before invoking pinact" \
  "rc=1" "$(rc)"
assert_contains "pinact step names the empty scope" "WORKFLOW_FILES is empty" "$CASE_OUT"

run_guard "$PINACT" set ""
assert_eq "pinact step with WORKFLOW_FILES empty: exits non-zero" "rc=1" "$(rc)"

run_guard "$ZIZMOR" unset
assert_eq "zizmor step with WORKFLOW_FILES unset: exits non-zero before invoking zizmor" \
  "rc=1" "$(rc)"
assert_contains "zizmor step names the empty scope" "WORKFLOW_FILES is empty" "$CASE_OUT"

run_guard "$ZIZMOR" set ""
assert_eq "zizmor step with WORKFLOW_FILES empty: exits non-zero" "rc=1" "$(rc)"

# --- the invocations themselves --------------------------------------------------------------------

PINACT_SRC="$(cat "$PINACT" 2>/dev/null)"
ZIZMOR_SRC="$(cat "$ZIZMOR" 2>/dev/null)"

# ci-cd.md §4 names `pinact run --check` as the gate. --verify additionally asserts the `# vX.Y.Z`
# comment names the tag the SHA actually is — without it a pin whose comment lies passes review.
assert_contains "pinact runs in check mode (never fix mode, which would 'pass' by rewriting)" \
  "run --check" "$PINACT_SRC"
assert_contains "pinact also verifies the version comment matches the SHA" "--verify" "$PINACT_SRC"
# The enumerated list is passed as arguments — without it pinact falls back to its own default
# search, and the empty-set guard above stops guarding what pinact actually reads.
# shellcheck disable=SC2016 # the literal text of the invocation is the needle, not an expansion
assert_contains "pinact is pointed at the enumerated scope, not at its own default search" \
  'run --check --verify $WORKFLOW_FILES' "$PINACT_SRC"
assert_eq "pinact itself is installed at a pinned version, not @latest" "no" \
  "$(has "$PINACT_SRC" 'pinact@latest')"

# ci-cd.md §1 lists zizmor as a gate and §6 spells the invocation `uvx zizmor`.
assert_contains "zizmor is invoked the way ci-cd.md §6 spells it" "uvx zizmor@" "$ZIZMOR_SRC"
# shellcheck disable=SC2016 # the literal text of the invocation is the needle, not an expansion
assert_contains "zizmor is pointed at the enumerated scope" \
  '--strict-collection $WORKFLOW_FILES' "$ZIZMOR_SRC"
# Without it, a workflow zizmor cannot parse is a warning plus a silent skip — a parse error would
# remove a file from the audit while the job stays green.
assert_contains "an unparseable workflow fails the audit instead of being skipped" \
  "--strict-collection" "$ZIZMOR_SRC"
assert_eq "zizmor is version-pinned, not floating" "no" "$(has "$ZIZMOR_SRC" 'zizmor@latest')"
# The kit's dependabot config is in the audit set on purpose: zizmor's dependabot-cooldown audit is
# what keeps the `cooldown:` in .github/dependabot.yml from being dropped (verified: a config
# without it produces a dependabot-cooldown finding).
assert_contains "the kit's dependabot config is audited too" ".github/dependabot.yml" "$ZIZMOR_SRC"

# Offline, zizmor drops the audits that need the API (known-vulnerable-actions among them) and
# still prints "No findings to report" — a green run with a quietly smaller audit set.
assert_contains "zizmor gets a token, so its online audits are not silently skipped" \
  "GH_TOKEN" "$JOB_BLOCK"
assert_contains "pinact gets a token, so --verify can resolve tags" "GITHUB_TOKEN" "$JOB_BLOCK"

# The job must not need write scopes to run a read-only audit; §4's floor is contents: read. Read
# from the non-comment lines only, so prose about permissions cannot satisfy or break the row.
JOB_KEYS="$(printf '%s\n' "$JOB_BLOCK" | grep -v '^[[:space:]]*#' || true)"
assert_eq "the job elevates no permissions beyond the workflow's contents:read floor" "no" \
  "$(has "$JOB_KEYS" 'permissions:')"

# --- an independent, tool-free check of the property pinact is there to enforce ---------------------

# pinact and zizmor are absent from the machine running this suite, so without this the kit's own
# pins would be verified only by a job nobody can run locally. This re-derives the property from
# the files: every `uses:` in .github/workflows/** resolves to a 40-hex SHA and carries a comment
# naming the version.
scan_pins() {
  awk '
    /^[ \t]*-?[ \t]*uses:[ \t]*[^ \t]/ {
      ref = $0
      sub(/^[ \t]*-?[ \t]*uses:[ \t]*/, "", ref)
      sp = index(ref, " ")
      if (sp > 0) { rest = substr(ref, sp); ref = substr(ref, 1, sp - 1) } else { rest = "" }
      if (substr(ref, 1, 2) == "./") next          # a local action has nothing to pin
      total++
      at = index(ref, "@")
      sha = (at > 0 ? substr(ref, at + 1) : "")
      if (length(sha) != 40 || sha ~ /[^0-9a-f]/) { print "UNPINNED " FILENAME " " ref }
      else if (index(rest, "#") == 0) { print "UNCOMMENTED " FILENAME " " ref }
    }
    END { print "TOTAL " total }
  ' "$@"
}

WF_FILES=""
WF_COUNT=0
for f in "$KIT"/.github/workflows/*.yml "$KIT"/.github/workflows/*.yaml; do
  [ -f "$f" ] || continue
  WF_FILES="${WF_FILES:+$WF_FILES }$f"
  WF_COUNT=$((WF_COUNT + 1))
done
assert_eq "this file's own scan found at least one workflow to scan" "yes" \
  "$(if [ "$WF_COUNT" -gt 0 ]; then echo yes; else echo no; fi)"

SCAN=""
# shellcheck disable=SC2086 # deliberate word-split of the file list built above
if [ "$WF_COUNT" -gt 0 ]; then SCAN="$(scan_pins $WF_FILES)"; fi
SCAN_TOTAL="$(printf '%s\n' "$SCAN" | sed -n 's/^TOTAL //p')"
# -E, not BRE alternation: `\|` is a GNU extension that BSD grep does not honour, and this suite
# runs on macOS as well as on the ubuntu runner.
SCAN_BAD="$(printf '%s\n' "$SCAN" | grep -Ec '^(UNPINNED|UNCOMMENTED) ' || true)"

assert_eq "the scan examined some uses: references (a zero count would pass vacuously)" "yes" \
  "$(if [ "${SCAN_TOTAL:-0}" -gt 0 ]; then echo yes; else echo no; fi)"
assert_eq "every action in the kit's own workflows is SHA-pinned with a version comment" "0" \
  "$SCAN_BAD"

# The scanner is itself pinned: a scanner that can no longer see an unpinned ref makes the row
# above a permanent, meaningless pass. Both defects it exists to catch are reintroduced here.
BADWF=""
if [ -n "$WORK" ] && [ -d "$WORK" ]; then
  BADWF="$WORK/bad-uses.yml"
  {
    printf 'jobs:\n  a:\n    steps:\n'
    printf '      - uses: actions/checkout@v7\n'
    printf '      - uses: actions/setup-go@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0\n'
    printf '      - uses: ./.github/actions/local\n'
    printf '      # a prose mention of uses: in a comment is not a step\n'
  } >"$BADWF"
fi
BAD_SCAN=""
if [ -n "$BADWF" ] && [ -s "$BADWF" ]; then BAD_SCAN="$(scan_pins "$BADWF")"; fi
assert_contains "the scanner flags a tag-pinned action" "UNPINNED" "$BAD_SCAN"
assert_contains "the scanner flags a SHA pin with no version comment" "UNCOMMENTED" "$BAD_SCAN"
assert_contains "the scanner counts the two remote refs and skips the local one" \
  "TOTAL 2" "$BAD_SCAN"

ts_report
