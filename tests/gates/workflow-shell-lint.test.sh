#!/usr/bin/env bash
# Gate: the actionlint step in the `shell` job of .github/workflows/ci.yml — the only thing that
# runs shellcheck over the shell embedded in this workflow's own `run:` blocks. Every other lint in
# the kit sweeps `*.sh` files, so roughly 60 lines of shell in that YAML were checked by nothing at
# all — including the `ci-required` aggregator, the job that decides whether any other gate can
# block a merge, and the SC2086 disable directives already sitting in those blocks, which were
# addressed to a shellcheck that never ran.
#
# (A comment line here must not begin with the word shellcheck followed by anything but a real
# directive — shellcheck parses `# shellcheck …` in this file as one, and errors out on prose.)
#
# WHY IT LIVES IN THE `shell` JOB, not the `workflows` job with pinact and zizmor:
# tests/gates/workflow-pinning.test.sh pins the `workflows` job to EXACTLY THREE `run:` blocks, and
# that pin is load-bearing — that file extracts its blocks by position, so a fourth block would have
# every row there driving the wrong shell. Linting shell is the `shell` job's remit anyway. This
# file pins the `shell` job's block count for the same reason, and asserts which block is which.
#
# The step was the one gate added in this round with no regression protection: pinact and zizmor are
# driven by workflow-pinning.test.sh, and actionlint by nothing. Removing it would have been silent.
#
# actionlint itself is not invoked here — it is absent from the machines this suite runs on, and a
# row that shelled out to it would either skip (leaving the guard unverified) or need the network.
# Two things are done instead:
#   1. The step's real `run:` block is EXTRACTED FROM THE WORKFLOW AT TEST TIME and executed under
#      `bash -e`, the way GitHub invokes it, against a stub toolchain — so the shellcheck-presence
#      guard, the pinned install, the invocation and the exit-status handling are all driven for
#      real. Never transcribed here: a test carrying its own copy of the logic keeps passing after
#      someone edits the workflow.
#   2. The PROPERTY actionlint enforces is re-derived independently, with shellcheck alone: every
#      `run: |` block in the workflow is extracted and shellchecked here. That is what keeps the
#      kit's own workflow shell verified on a machine where actionlint cannot run, and the
#      deliberately-broken fixture below proves that sweep can still fail.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
WORKFLOW="$KIT/.github/workflows/ci.yml"
JOB="shell"

# Hard rule 4: skip only for genuine tool absence.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "workflow-shell-lint" "mktemp not available"
  ts_report
  exit 0
fi

# The cases below run the extracted block with a PATH that holds only the stub directories, so the
# interpreter cannot be found through it.
BASH_BIN="$(command -v bash || true)"

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# wf <mode> [n] [job] — run-block-aware reader for the workflow. Modes:
#   jobs   every job name under the top-level `jobs:` key, one per line
#   job    the named job's block, verbatim
#   count  how many `run: |` blocks the named job has
#   body   the n-th (1-based) `run: |` block of the named job, dedented to column 0
#   all    every `run: |` block in the file, dedented, separated by a `#--- block N ---` marker
# Pure awk, for the reason check-skills.sh/check-standards.sh are: a test needing jq/yq/python is a
# test that silently skips on the machine that lacks it.
wf() {
  awk -v job="${3:-$JOB}" -v mode="$1" -v want="${2:-0}" '
    function indent_of(s,   n) { n = match(s, /[^ ]/); if (n == 0) return -1; return n - 1 }
    BEGIN { in_jobs = 0; in_job = 0; in_run = 0; runs = 0; all = 0; body_indent = -1; pending = 0 }
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
          while (pending > 0) {
            if (mode == "job" || mode == "all" || (mode == "body" && runs == want)) print ""
            pending--
          }
          if (mode == "all" || (mode == "body" && runs == want)) print substr(line, body_indent + 1)
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

      if (line ~ /^ +run:[ \t]*\|[ \t]*$/ && (in_job || mode == "all")) {
        run_indent = ind
        body_indent = -1
        in_run = 1
        if (in_job) runs++
        if (mode == "all") { all++; print "#--- block " all " ---" }
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

# has <haystack> <needle> — echoes yes/no. Also a function rather than an inline `case` inside
# "$( ... )", for the same bash 3.2 parse reason as in_list above.
has() {
  case "$1" in
  *"$2"*) echo yes ;;
  *) echo no ;;
  esac
}

file_state() { if [ -f "$1" ]; then echo present; else echo absent; fi; }
nonempty() { if [ -n "$1" ] && [ -s "$1" ]; then echo yes; else echo no; fi; }

# --- preconditions: nothing below means anything if these fail -----------------------------------

assert_eq "the kit's CI workflow is on disk" "present" "$(file_state "$WORKFLOW")"

JOB_NAMES=""
if [ -f "$WORKFLOW" ]; then JOB_NAMES="$(wf jobs)"; fi
assert_eq "a job named '$JOB' exists in it (a rename must fail here, not silently pass)" \
  "present" "$(in_list "$JOB" "$JOB_NAMES")"

RUN_COUNT="0"
if [ -f "$WORKFLOW" ]; then RUN_COUNT="$(wf count)"; fi
# shfmt + actionlint. The other two steps of this job are single-line `run:` and are not extracted.
# A dropped or added block changes this number, and the row below would otherwise drive the wrong
# shell. (The `workflows` job is pinned to three blocks by tests/gates/workflow-pinning.test.sh for
# the same reason — which is why actionlint was added here rather than there.)
assert_eq "$JOB has exactly two run: | blocks (shfmt, actionlint)" "2" "$RUN_COUNT"

AGG_NEEDS="$(wf job 0 ci-required | grep -m1 '^ *needs:' || true)"
assert_contains "ci-required requires the $JOB job (otherwise it cannot block a merge)" \
  "$JOB" "$AGG_NEEDS"

WORK="$(mktemp -d 2>/dev/null || true)"
assert_eq "a scratch directory was created for the fixtures" "yes" \
  "$(if [ -n "$WORK" ] && [ -d "$WORK" ]; then echo yes; else echo no; fi)"

SHFMT_BLOCK=""
LINT_BLOCK=""
if [ -n "$WORK" ] && [ -d "$WORK" ] && [ "$RUN_COUNT" = "2" ]; then
  SHFMT_BLOCK="$WORK/shfmt.sh"
  LINT_BLOCK="$WORK/actionlint.sh"
  wf body 1 >"$SHFMT_BLOCK"
  wf body 2 >"$LINT_BLOCK"
fi
assert_eq "the actionlint run: block was extracted" "yes" "$(nonempty "$LINT_BLOCK")"
# Extraction is by position, so pin what each position is: a reordering of the steps would have
# every row below asserting against the wrong block, and some would still pass.
assert_contains "block 1 is the shfmt step" "shfmt" "$(cat "$SHFMT_BLOCK" 2>/dev/null)"
assert_contains "block 2 is the actionlint step" "actionlint" "$(cat "$LINT_BLOCK" 2>/dev/null)"

LINT_SRC=""
if [ -n "$LINT_BLOCK" ] && [ -s "$LINT_BLOCK" ]; then LINT_SRC="$(cat "$LINT_BLOCK")"; fi

# --- the invocation ------------------------------------------------------------------------------

# Without `-shellcheck`, actionlint checks workflow SYNTAX and expressions only — it would still
# pass on a `run:` block full of unquoted expansions, which is the entire reason this step exists.
assert_contains "actionlint runs its shellcheck integration, not just the workflow schema" \
  "-shellcheck shellcheck" "$LINT_SRC"
assert_eq "actionlint is version-pinned, not floating at @latest" "no" \
  "$(has "$LINT_SRC" "actionlint@latest")"
# Given no file arguments, actionlint scans .github/workflows/ itself and exits 3 on an empty or
# absent directory, so the scope cannot silently shrink to nothing. Handing it the `workflows` job's
# $WORKFLOW_FILES list would couple this job to another job's environment and lose that property.
assert_eq "actionlint is not handed another job's file list" "no" \
  "$(has "$LINT_SRC" "WORKFLOW_FILES")"

# --- stubs: the block's shell, driven end-to-end without actionlint --------------------------------

STUB_BIN=""
SC_BIN=""
FAKE_GOPATH=""
LOG=""
if [ -n "$WORK" ] && [ -d "$WORK" ]; then
  STUB_BIN="$WORK/stubbin"
  SC_BIN="$WORK/scbin"
  FAKE_GOPATH="$WORK/gopath"
  LOG="$WORK/invocations.log"
  mkdir -p "$STUB_BIN" "$SC_BIN" "$FAKE_GOPATH/bin"

  # `go install` is a no-op that records its argument, so the pinned module path and version are
  # asserted from what the block ACTUALLY ran, not from a text match on the file.
  cat >"$STUB_BIN/go" <<'STUBGO'
#!/bin/sh
if [ "${1:-}" = "env" ] && [ "${2:-}" = "GOPATH" ]; then
  printf '%s\n' "$STUB_GOPATH"
  exit 0
fi
if [ "${1:-}" = "install" ]; then
  printf 'go install %s\n' "${2:-}" >>"$STUB_LOG"
  exit 0
fi
printf 'go %s\n' "$*" >>"$STUB_LOG"
exit 1
STUBGO

  cat >"$FAKE_GOPATH/bin/actionlint" <<'STUBLINT'
#!/bin/sh
printf 'actionlint %s\n' "$*" >>"$STUB_LOG"
exit "${STUB_ACTIONLINT_RC:-0}"
STUBLINT

  # Present only on the PATH of the cases that are meant to have shellcheck. It is never executed:
  # the block only asks `command -v`.
  cat >"$SC_BIN/shellcheck" <<'STUBSC'
#!/bin/sh
printf 'shellcheck %s\n' "$*" >>"$STUB_LOG"
exit 0
STUBSC
  chmod +x "$STUB_BIN/go" "$FAKE_GOPATH/bin/actionlint" "$SC_BIN/shellcheck"
fi
assert_eq "bash was resolved by absolute path for the stubbed cases" "yes" \
  "$(if [ -n "$BASH_BIN" ] && [ -x "$BASH_BIN" ]; then echo yes; else echo no; fi)"
assert_eq "the stub toolchain was written" "yes" \
  "$(if [ -x "$STUB_BIN/go" ] && [ -x "$FAKE_GOPATH/bin/actionlint" ] && [ -x "$SC_BIN/shellcheck" ]; then echo yes; else echo no; fi)"

CASE_OUT=""
CASE_RC=0
run_case() { # <with|without shellcheck> [VAR=VALUE ...]
  local sc="$1"
  shift
  CASE_RC=0
  CASE_OUT=""
  if [ -z "$LINT_BLOCK" ] || [ ! -s "$LINT_BLOCK" ] || [ ! -x "$STUB_BIN/go" ] ||
    [ ! -x "$BASH_BIN" ]; then
    CASE_RC=126
    CASE_OUT="STUBS OR RUN BLOCK MISSING"
    return 0
  fi
  : >"$LOG"
  # The PATH is built from the stub dirs ALONE — no inherited entries — so "shellcheck is absent"
  # really is absent, rather than depending on where this suite happens to be run. The block needs
  # nothing else: `command` and `echo` are builtins, and `go` is stubbed. bash is invoked by
  # absolute path and the stubs are `#!/bin/sh`, so neither has to be findable on that PATH.
  local path="$STUB_BIN"
  if [ "$sc" = "with" ]; then path="$SC_BIN:$STUB_BIN"; fi
  # Command substitution, never a pipeline: `cmd | tail` would capture tail's status. GitHub runs
  # `run:` blocks as `bash -e {0}`, so -e is part of the contract under test.
  CASE_OUT="$(env PATH="$path" STUB_GOPATH="$FAKE_GOPATH" STUB_LOG="$LOG" "$@" \
    "$BASH_BIN" -e "$LINT_BLOCK" 2>&1)" || CASE_RC=$?
}

rc() { printf 'rc=%s' "$CASE_RC"; }
log_text() { cat "$LOG" 2>/dev/null; }

# 1. THE VACUITY GUARD. actionlint silently SKIPS its shellcheck integration when shellcheck is not
#    on PATH: it prints nothing and exits 0. ubuntu-latest ships shellcheck today, which is exactly
#    how this would become a permanent, meaningless pass.
run_case without
assert_eq "shellcheck absent: the step fails instead of silently linting nothing" "rc=1" "$(rc)"
assert_contains "shellcheck absent: says what is missing" "shellcheck is not on PATH" "$CASE_OUT"
assert_contains "shellcheck absent: says what that would have cost" "silently skip" "$CASE_OUT"
assert_eq "shellcheck absent: actionlint was never installed or run" "" "$(log_text)"

# 2. The green path.
run_case with
assert_eq "shellcheck present and no findings: exits 0" "rc=0" "$(rc)"
GREEN_LOG="$(log_text)"
assert_contains "actionlint is installed from the pinned module path and version" \
  "go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.7" "$GREEN_LOG"
assert_contains "actionlint really ran, with the shellcheck integration switched on" \
  "actionlint -shellcheck shellcheck" "$GREEN_LOG"

# 3. A finding fails the job.
run_case with STUB_ACTIONLINT_RC=1
assert_eq "actionlint reports a problem: the step fails" "rc=1" "$(rc)"

# 4. actionlint exits 3 with "no YAML file was found" on an empty or absent .github/workflows —
#    the shape where the scope has shrunk to nothing. The status must propagate, not be swallowed.
run_case with STUB_ACTIONLINT_RC=3
assert_eq "no workflow files to lint: the status propagates rather than passing" "rc=3" "$(rc)"

# --- an independent, tool-free check of the property actionlint is there to enforce ----------------

# actionlint is absent from the machine running this suite, so without this the kit's own workflow
# shell would be verified only by a job nobody can run locally. This extracts every `run: |` block
# in the workflow and shellchecks it directly — the same integration actionlint performs, minus the
# YAML layer.
SWEEP_DIR="$WORK/blocks"
BLOCK_TOTAL=0
if [ -n "$WORK" ] && [ -d "$WORK" ]; then
  mkdir -p "$SWEEP_DIR"
  # `all` emits every block separated by a marker line; split it into one file per block, each with
  # a shebang so shellcheck picks the right dialect.
  awk -v dir="$SWEEP_DIR" '
    /^#--- block [0-9]+ ---$/ { out = dir "/block" $3 ".sh"; print "#!/usr/bin/env bash" >out; next }
    out { print >out }
  ' <<EOF
$(wf all)
EOF
  for f in "$SWEEP_DIR"/block*.sh; do
    [ -f "$f" ] || continue
    BLOCK_TOTAL=$((BLOCK_TOTAL + 1))
  done
fi
assert_eq "every run: | block in the workflow was extracted for the sweep" "yes" \
  "$(if [ "$BLOCK_TOTAL" -gt 0 ]; then echo yes; else echo no; fi)"

# sweep <dir> — echoes "SWEPT <n> FINDINGS <m>[ <file>…]". Blocks containing a `${{ }}` expression
# are skipped and counted separately: actionlint substitutes a placeholder value for those before it
# lints them, and raw `${{` is not shell — so a standalone run would report a syntax error that
# actionlint would not. No block in the workflow uses one today; the counter is what makes that
# visible if one appears.
sweep() {
  local dir="$1" n=0 skipped=0 bad="" f
  for f in "$dir"/block*.sh; do
    [ -f "$f" ] || continue
    # shellcheck disable=SC2016 # the literal two-brace sequence is the needle, not an expansion
    if grep -q '\${{' "$f"; then
      skipped=$((skipped + 1))
      continue
    fi
    n=$((n + 1))
    if ! shellcheck -s bash "$f" >/dev/null 2>&1; then bad="$bad ${f##*/}"; fi
  done
  printf 'SWEPT %s SKIPPED %s FINDINGS%s' "$n" "$skipped" "${bad:-}"
}

if ! command -v shellcheck >/dev/null 2>&1; then
  ts_skip "workflow run: block sweep" "shellcheck not installed"
else
  SWEEP="$(sweep "$SWEEP_DIR")"
  SWEPT_N="$(printf '%s\n' "$SWEEP" | sed -n 's/^SWEPT \([0-9]*\) .*/\1/p')"
  assert_eq "the sweep examined some blocks (a zero count would pass vacuously)" "yes" \
    "$(if [ "${SWEPT_N:-0}" -gt 0 ]; then echo yes; else echo no; fi)"
  assert_eq "every block the sweep could read was extracted, none skipped for a \${{ }} expression" \
    "SKIPPED 0" "$(printf '%s\n' "$SWEEP" | sed -n 's/.*\(SKIPPED [0-9]*\).*/\1/p')"
  assert_eq "every run: | block in the kit's own workflow is shellcheck-clean" \
    "FINDINGS" "$(printf '%s\n' "$SWEEP" | sed -n 's/.*\(FINDINGS.*\)$/\1/p')"

  # The sweep is itself pinned: a sweep that can no longer see a defect makes the row above a
  # permanent, meaningless pass. Two blocks are planted — one with the unquoted expansion the
  # `# shellcheck disable=SC2086` directives in this workflow are about, one clean.
  BADDIR="$WORK/badblocks"
  mkdir -p "$BADDIR"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'files="a b"\n'
    # shellcheck disable=SC2016 # planted defect: the unquoted expansion is the point
    printf 'rm $files\n'
  } >"$BADDIR/block1.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "clean"\n'
  } >"$BADDIR/block2.sh"
  BAD_SWEEP="$(sweep "$BADDIR")"
  assert_eq "the sweep still reads two blocks when given two" "SWEPT 2" \
    "$(printf '%s\n' "$BAD_SWEEP" | sed -n 's/^\(SWEPT [0-9]*\).*/\1/p')"
  assert_contains "the sweep flags an unquoted expansion" "block1.sh" "$BAD_SWEEP"
  assert_eq "...and does not flag the clean block" "no" "$(has "$BAD_SWEEP" "block2.sh")"
fi

ts_report
