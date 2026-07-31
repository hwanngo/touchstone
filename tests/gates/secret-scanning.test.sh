#!/usr/bin/env bash
# Gate: the `secrets` job in .github/workflows/ci.yml — `gitleaks detect` over the repository and
# its history. Hard rule 9 is "never commit secrets", and until that job existed the kit's ONLY
# secret scanning was the gitleaks entry in .pre-commit-config.yaml: commit-time, local, and active
# only for a contributor who had run `pre-commit install`. Nothing in CI checked at all.
#
# WHY "RUN PRE-COMMIT IN CI" IS NOT THE FIX, and why this file pins the mode rather than the tool.
# The upstream gitleaks pre-commit hook is `gitleaks protect --verbose --redact --staged` with
# `pass_filenames: false`: it reads the STAGED DIFF and ignores the file list pre-commit hands it.
# Under `pre-commit run --all-files` nothing is staged, so it scans an empty diff and reports
# Passed. Measured against gitleaks v8.21.0 in a clone of this repo carrying a committed `ghp_…`
# token: `protect --staged` reported "no leaks found" and exited 0, while `detect` on the same
# clone found it and exited 1. A gate in the wrong mode is a gate that passes vacuously forever, so
# the rows below assert `detect` IS the mode and `protect`/`--staged` are NOT.
#
# As in tests/gates/ci-required-aggregator.test.sh and tests/gates/workflow-pinning.test.sh, the
# shell under test is EXTRACTED FROM THE WORKFLOW AT TEST TIME and executed under `bash -e`, the
# way GitHub invokes a `run:` block — never transcribed here, because a test carrying its own copy
# of the logic keeps passing after someone edits the workflow.
#
# gitleaks itself is not invoked. It is absent from the machines this suite runs on, and a row that
# shelled out to it would either skip (leaving the guard unverified) or need the network. What IS
# driven end-to-end is every line of the job's shell around the tool: the shallow/empty-history
# guards, the canary that must be DETECTED before a clean verdict is believed, and both scan
# invocations — through a stub `go` and a stub `gitleaks` whose exit statuses are set per case. The
# stub also records the canary file the block plants, so a canary neutered to an empty file fails
# here rather than making the guard a permanent pass.
#
# Fixtures are built under mktemp, never committed: a committed fixture holding a credential-shaped
# literal would be found by this very gate's own scan of the repository — the fixture for the gate
# would become a trap for the gate. Every credential-shaped string here is assembled from fragments
# at run time for the same reason, and because hooks/block-secrets.sh refuses to write one.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
WORKFLOW="$KIT/.github/workflows/ci.yml"
JOB="secrets"

# Hard rule 4: skip only for genuine tool absence. git is what the fixtures are made of; mktemp is
# where they live.
if ! command -v mktemp >/dev/null 2>&1; then
  ts_skip "secret-scanning" "mktemp not available"
  ts_report
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  ts_skip "secret-scanning" "git not available"
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
# test that silently skips on the machine that lacks it. The job is a parameter with a default
# rather than an environment override — a `JOB=other wf ...` prefix would leak past the call in
# bash and silently repoint every later invocation.
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

# has <haystack> <needle> — echoes yes/no. Also a function rather than an inline `case` inside
# "$( ... )", for the same bash 3.2 parse reason as in_list above.
has() {
  case "$1" in
  *"$2"*) echo yes ;;
  *) echo no ;;
  esac
}

file_state() { if [ -f "$1" ]; then echo present; else echo absent; fi; }
yesno() { if [ "$1" -eq 0 ]; then echo yes; else echo no; fi; }

# --- preconditions: nothing below means anything if these fail -----------------------------------

assert_eq "the kit's CI workflow is on disk" "present" "$(file_state "$WORKFLOW")"

JOB_NAMES=""
if [ -f "$WORKFLOW" ]; then JOB_NAMES="$(wf jobs)"; fi
assert_eq "a job named '$JOB' exists in it (deleting or renaming it must fail here)" \
  "present" "$(in_list "$JOB" "$JOB_NAMES")"

JOB_BLOCK=""
RUN_COUNT="0"
if [ -f "$WORKFLOW" ]; then
  JOB_BLOCK="$(wf job)"
  RUN_COUNT="$(wf count)"
fi
assert_eq "$JOB has exactly one run: block (the one this file drives)" "1" "$RUN_COUNT"

# The scan only gates if the aggregator requires it — ci-required is the single branch-protection
# check, so a job missing from its needs: cannot block a merge no matter what it finds.
AGG_NEEDS="$(wf job 0 ci-required | grep -m1 '^ *needs:' || true)"
assert_contains "ci-required requires the $JOB job (otherwise it cannot block a merge)" \
  "$JOB" "$AGG_NEEDS"

WORK="$(mktemp -d 2>/dev/null || true)"
assert_eq "a scratch directory was created for the fixtures" "yes" \
  "$(if [ -n "$WORK" ] && [ -d "$WORK" ]; then echo yes; else echo no; fi)"

BLOCK=""
if [ -n "$WORK" ] && [ -d "$WORK" ] && [ "$RUN_COUNT" = "1" ]; then
  BLOCK="$WORK/scan.sh"
  wf body 1 >"$BLOCK"
fi
assert_eq "the scan run: block was extracted" "yes" \
  "$(if [ -n "$BLOCK" ] && [ -s "$BLOCK" ]; then echo yes; else echo no; fi)"

BLOCK_SRC=""
if [ -n "$BLOCK" ] && [ -s "$BLOCK" ]; then BLOCK_SRC="$(cat "$BLOCK")"; fi

# --- the mode, which is the whole gap this job closes ---------------------------------------------

# `detect` scans the repository; `protect --staged` scans the staged diff and finds nothing in CI,
# where nothing is ever staged. Both halves are asserted: the right mode present, the wrong one
# absent — "contains detect" alone would still pass if someone added a protect call beside it.
assert_contains "the job scans with gitleaks' repository mode (detect)" "detect" "$BLOCK_SRC"
assert_eq "it does NOT use protect, the staged-diff mode that finds nothing in CI" "no" \
  "$(has "$BLOCK_SRC" "protect")"
assert_eq "...and does not read a staged diff by any other spelling" "no" \
  "$(has "$BLOCK_SRC" "--staged")"

# Both scan modes: history (a secret committed and later deleted is still in the repository) and
# the working tree (content reachable only through a merge commit is absent from `git log -p`).
assert_contains "history is scanned: detect over the checked-out repository" \
  "detect --source ." "$BLOCK_SRC"
assert_contains "the tree as checked out is scanned too" \
  "detect --no-git --source ." "$BLOCK_SRC"
# A depth-1 clone is what actions/checkout gives by default, and a one-commit history scan reports
# "no leaks found" as confidently as a full one.
#
# Matched as a YAML KEY LINE, not as a substring of the job block. `assert_contains "fetch-depth: 0"`
# was tried first and passed with the setting deleted: the run block's own error message names it,
# so prose about the setting satisfied an assertion about the setting. Caught by mutation.
job_key() { # <key: value> — present/absent, reading only real YAML lines of the job block
  if printf '%s\n' "$JOB_BLOCK" | grep -qE "^[[:space:]]*$1[[:space:]]*$"; then
    echo present
  else
    echo absent
  fi
}
assert_eq "the checkout fetches full history, or the history scan sees one commit" "present" \
  "$(job_key 'fetch-depth: 0')"
assert_eq "the checkout leaves no credentials in .git/config" "present" \
  "$(job_key 'persist-credentials: false')"
assert_eq "gitleaks is version-pinned, not floating at @latest" "no" \
  "$(has "$BLOCK_SRC" "gitleaks/v8@latest")"
# The job reads the repository and nothing else; ci-cd.md §4's floor is the workflow's contents:read.
JOB_KEYS="$(printf '%s\n' "$JOB_BLOCK" | grep -v '^[[:space:]]*#' || true)"
assert_eq "the job elevates no permissions beyond the workflow's contents:read floor" "no" \
  "$(has "$JOB_KEYS" 'permissions:')"

# --- stubs: the block's shell, driven end-to-end without gitleaks ---------------------------------

STUB_BIN=""
FAKE_GOPATH=""
LOG=""
CANARY_LOG=""
if [ -n "$WORK" ] && [ -d "$WORK" ]; then
  STUB_BIN="$WORK/stubbin"
  FAKE_GOPATH="$WORK/gopath"
  LOG="$WORK/invocations.log"
  CANARY_LOG="$WORK/canary-content"
  mkdir -p "$STUB_BIN" "$FAKE_GOPATH/bin"

  # `go install` is a no-op that records its argument, so the pinned module path and version are
  # asserted from what the block ACTUALLY ran, not from a text match on the file.
  cat >"$STUB_BIN/go" <<'STUBGO'
#!/usr/bin/env bash
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

  # The stub gitleaks: records how it was called, copies the canary it was pointed at, and takes
  # its exit status from the environment so each case below can choose a verdict. A scan of "." is
  # a real scan; anything else is the canary, which the block plants outside the repository.
  cat >"$FAKE_GOPATH/bin/gitleaks" <<'STUBLEAKS'
#!/usr/bin/env bash
mode=git
src=""
prev=""
for arg in "$@"; do
  if [ "$arg" = "--no-git" ]; then mode=tree; fi
  if [ "$prev" = "--source" ]; then src="$arg"; fi
  prev="$arg"
done
printf 'scan mode=%s source=%s\n' "$mode" "$src" >>"$STUB_LOG"
if [ "$src" != "." ]; then
  cat "$src"/* >>"$STUB_CANARY_LOG" 2>/dev/null
  exit "${STUB_CANARY_RC:-1}"
fi
if [ "$mode" = "tree" ]; then exit "${STUB_TREE_RC:-0}"; fi
exit "${STUB_HISTORY_RC:-0}"
STUBLEAKS
  chmod +x "$STUB_BIN/go" "$FAKE_GOPATH/bin/gitleaks"
fi
assert_eq "the stub toolchain was written" "yes" \
  "$(if [ -x "$STUB_BIN/go" ] && [ -x "$FAKE_GOPATH/bin/gitleaks" ]; then echo yes; else echo no; fi)"

# --- fixtures ------------------------------------------------------------------------------------

git_commit() { # <dir> <message>
  git -C "$1" -c user.email=t@example.invalid -c user.name=touchstone commit -q -m "$2"
}

FULL="$WORK/full"
EMPTY="$WORK/empty"
NOGIT="$WORK/nogit"
SHALLOW="$WORK/shallow"
if [ -n "$WORK" ] && [ -d "$WORK" ]; then
  mkdir -p "$FULL" "$EMPTY" "$NOGIT"
  git -C "$FULL" init -q 2>/dev/null
  printf 'one\n' >"$FULL/a.txt"
  git -C "$FULL" add a.txt 2>/dev/null
  git_commit "$FULL" "first" 2>/dev/null
  printf 'two\n' >"$FULL/b.txt"
  git -C "$FULL" add b.txt 2>/dev/null
  git_commit "$FULL" "second" 2>/dev/null
  git -C "$EMPTY" init -q 2>/dev/null
  git clone --quiet --depth 1 "file://$FULL" "$SHALLOW" 2>/dev/null
fi

repo_state() { # <dir> — what the block's own first guard reads
  if [ ! -d "$1" ]; then
    echo missing
    return 0
  fi
  git -C "$1" rev-parse --is-shallow-repository 2>/dev/null || echo unknown
}

assert_eq "fixture: the full repo really is a non-shallow checkout" "false" "$(repo_state "$FULL")"
assert_eq "fixture: the full repo has the two commits the count guard will read" "2" \
  "$(git -C "$FULL" rev-list --count HEAD 2>/dev/null || echo 0)"
assert_eq "fixture: the empty repo is a repo with no commits" "false" "$(repo_state "$EMPTY")"
assert_eq "fixture: the shallow clone really is shallow" "true" "$(repo_state "$SHALLOW")"
assert_eq "fixture: the non-repo directory exists and is not a repo" "yes" \
  "$(if [ -d "$NOGIT" ] && [ ! -d "$NOGIT/.git" ]; then echo yes; else echo no; fi)"

# --- driving the block ----------------------------------------------------------------------------

CASE_OUT=""
CASE_RC=0
run_case() { # <fixture-dir> [VAR=VALUE ...]
  local dir="$1"
  shift
  CASE_RC=0
  CASE_OUT=""
  if [ -z "$BLOCK" ] || [ ! -s "$BLOCK" ] || [ ! -d "$dir" ] || [ ! -x "$STUB_BIN/go" ]; then
    CASE_RC=126
    CASE_OUT="FIXTURE OR RUN BLOCK MISSING"
    return 0
  fi
  : >"$LOG"
  : >"$CANARY_LOG"
  # Command substitution, never a pipeline: `cmd | tail` would capture tail's status. GitHub runs
  # `run:` blocks as `bash -e {0}`, so -e is part of the contract under test.
  CASE_OUT="$(cd "$dir" && env PATH="$STUB_BIN:$PATH" STUB_GOPATH="$FAKE_GOPATH" \
    STUB_LOG="$LOG" STUB_CANARY_LOG="$CANARY_LOG" "$@" bash -e "$BLOCK" 2>&1)" || CASE_RC=$?
}

rc() { printf 'rc=%s' "$CASE_RC"; }
log_text() { cat "$LOG" 2>/dev/null; }

# 1. The green path, and the only case where the scans are reached at all.
run_case "$FULL"
assert_eq "a full checkout with a live scanner and no findings: exits 0" "rc=0" "$(rc)"
assert_contains "it reports how much history it scanned, not just that it ran" \
  "2 commit(s) of history in scope" "$CASE_OUT"
assert_contains "it says the canary was detected before trusting the clean verdict" \
  "canary detected" "$CASE_OUT"
GREEN_LOG="$(log_text)"
assert_contains "gitleaks is installed from the pinned module path and version" \
  "go install github.com/zricethezav/gitleaks/v8@v8.30.1" "$GREEN_LOG"
assert_contains "the history scan really ran against the repository" \
  "scan mode=git source=." "$GREEN_LOG"
assert_contains "the tree scan really ran against the repository" \
  "scan mode=tree source=." "$GREEN_LOG"
SCAN_COUNT="$(printf '%s\n' "$GREEN_LOG" | grep -c '^scan ' || true)"
assert_eq "exactly three scans: the canary plus the two real ones" "3" "$SCAN_COUNT"

# The canary is only proof if it really carries a credential-shaped string. A canary neutered to an
# empty file, with a scanner that reports a leak anyway, would satisfy every row above. The pattern
# is assembled from fragments for the same reason the workflow assembles the token itself.
PAT_LEAD="gh"
PAT="^${PAT_LEAD}p_[0-9A-Za-z]{36}$"
CANARY_MATCH="$(grep -Ec "$PAT" "$CANARY_LOG" 2>/dev/null || true)"
assert_eq "the planted canary is a credential-shaped token, not an empty file" "1" "$CANARY_MATCH"

# ...and planted outside the tree the job then scans. A canary written into the working directory
# would be found by the repository scan itself, turning the proof into the finding.
CANARY_SRC="$(printf '%s\n' "$GREEN_LOG" | sed -n 's/^scan mode=tree source=//p' | grep -v '^\.$' | head -1)"
canary_placement() {
  case "$1" in
  "") echo missing ;;
  "$FULL" | "$FULL"/*) echo inside ;;
  /*) echo outside ;;
  *) echo relative ;;
  esac
}
assert_eq "the canary was planted outside the repository under scan" "outside" \
  "$(canary_placement "$CANARY_SRC")"

# 2. THE VACUITY GUARD. A scanner that reports the planted token clean must fail the job — this is
#    the row that fails if the canary is deleted from the block.
run_case "$FULL" STUB_CANARY_RC=0
assert_eq "a scanner blind to a planted token: exits non-zero instead of certifying the repo" \
  "rc=1" "$(rc)"
assert_contains "blind scanner: says the scans would have proved nothing" \
  "prove nothing" "$CASE_OUT"
assert_eq "blind scanner: no real scan was attempted after the canary failed" "no" \
  "$(has "$(log_text)" "source=.")"

# 3. A gitleaks that is not there at all exits 127. `if ! gitleaks ...` would read that as "the
#    canary was found" and wave the run through, so the guard tests for status 1 exactly.
run_case "$FULL" STUB_CANARY_RC=127
assert_eq "a scanner that never ran (127): exits non-zero" "rc=1" "$(rc)"
assert_contains "missing scanner: reports the status it actually saw" "exited 127" "$CASE_OUT"

run_case "$FULL" STUB_CANARY_RC=2
assert_eq "a scanner that errored (2, e.g. a bad config): exits non-zero" "rc=1" "$(rc)"
assert_contains "errored scanner: reports the status it actually saw" "exited 2" "$CASE_OUT"

# 4. The findings themselves — one row per scan mode, so deleting either scan fails here.
run_case "$FULL" STUB_HISTORY_RC=1
assert_eq "a secret in history: the job fails" "rc=1" "$(rc)"

run_case "$FULL" STUB_TREE_RC=1
assert_eq "a secret in the working tree: the job fails" "rc=1" "$(rc)"

# 5. The scope guards. A shallow checkout is the default actions/checkout gives, and it shrinks the
#    history scan to one commit while still printing "no leaks found".
run_case "$SHALLOW"
assert_eq "a shallow checkout: exits non-zero rather than scanning one commit" "rc=1" "$(rc)"
assert_contains "shallow: says what it read and how to fix it" \
  "not a full git checkout" "$CASE_OUT"
assert_contains "shallow: names the setting that restores the scope" "fetch-depth: 0" "$CASE_OUT"
assert_eq "shallow: nothing was scanned" "no" "$(has "$(log_text)" "scan ")"

run_case "$NOGIT"
assert_eq "not a git checkout at all (e.g. a source archive): exits non-zero" "rc=1" "$(rc)"
assert_contains "not a checkout: says so" "not a full git checkout" "$CASE_OUT"

run_case "$EMPTY"
assert_eq "a repository with no commits: exits non-zero rather than passing vacuously" \
  "rc=1" "$(rc)"
assert_contains "no commits: says why, in terms of the empty history" \
  "refusing to certify an empty history" "$CASE_OUT"
assert_eq "no commits: nothing was scanned" "no" "$(has "$(log_text)" "scan ")"

ts_report
