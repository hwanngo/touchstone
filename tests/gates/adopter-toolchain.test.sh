#!/usr/bin/env bash
# Gate: the toolchain an adopter is handed must be able to run at all.
#
# Two defects, both found only from outside the kit:
#
# P1-7 templates/github/workflows/ci.yml checked out with no `submodules:` key, so `.touchstone/`
#   did not exist in an adopter's CI. The README tells adopters to wire check-sync.sh into CI and
#   the template had no such job — and worse, the stack gates walked a different tree in CI than on
#   a developer's machine, so CI went green on exactly the paths that failed locally. A green badge
#   that cannot see the code under test is the vacuous green this campaign exists to remove.
#
# P2-8 templates/pyproject-snippet.toml declared no dependency group, so `just setup`'s `uv sync`
#   installed nothing and the documented `just ci` died with `Failed to spawn: ruff`. The adopter
#   had to infer its own gate's toolchain from a spawn error.
#
# Everything here is structural and offline. The behavioural proof — a real adopter running
# `pre-commit run --all-files`, `just lint` and `just fmt` — lives in the sibling gates for the
# pieces that can be exercised locally; a GitHub Actions run cannot be.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"

CI="$KIT/templates/github/workflows/ci.yml"
SNIP="$KIT/templates/pyproject-snippet.toml"

exists() { if [ -f "$1" ]; then echo present; else echo absent; fi; }

# --- the CI template ------------------------------------------------------------------------------

assert_eq "templates/github/workflows/ci.yml is on disk" "present" "$(exists "$CI")"

# Count checkouts and how many of them ask for submodules. Equality is the assertion: one unscoped
# checkout is enough to reintroduce the CI-vs-local divergence for that job.
# `submodules:` lives on the step's `with:` line, which follows `uses:`, so this reads the pair.
counts="$(awk '
  want { if ($0 ~ /submodules:[ \t]*(true|recursive)/) s++; want = 0 }
  /uses:[ \t]*actions\/checkout@/ { n++; want = 1 }
  END { printf "%d %d\n", n + 0, s + 0 }' "$CI")"
checkouts="${counts% *}"
with_subs="${counts#* }"

assert_eq "ci.yml: the template really has checkout steps to inspect" "at least 4" \
  "$(if [ "$checkouts" -ge 4 ]; then echo "at least 4"; else echo "only $checkouts"; fi)"
assert_eq "ci.yml: every checkout fetches the vendored kit" "$checkouts" "$with_subs"

# The drift gate the README tells adopters to wire in.
assert_eq "ci.yml: there is a touchstone-sync job" "1" \
  "$(awk '/^[ \t]+touchstone-sync:[ \t]*$/ { n++ } END { print n + 0 }' "$CI")"
assert_eq "ci.yml: the sync job runs check-sync.sh" "at least 1" \
  "$(
    n="$(awk '/\.touchstone\/scripts\/check-sync\.sh/ { n++ } END { print n + 0 }' "$CI")"
    if [ "$n" -ge 1 ]; then echo "at least 1"; else echo "none"; fi
  )"

# A missing .touchstone/ must fail loudly. `check-sync.sh || true`, or a bare invocation that a
# shell would skip, would put the job back to reporting success on a tree it never saw.
assert_contains "ci.yml: a missing .touchstone/ fails the sync job rather than passing it" \
  "exit 1" "$(awk '/touchstone-sync:/,/^  python:/' "$CI")"

# The aggregator is the one required status check; a job outside its `needs:` gates nothing.
needs_line="$(awk '/^[ \t]+needs:[ \t]*\[/ { print }' "$CI" | tail -1)"
assert_contains "ci.yml: ci-required gates on the sync job too" "touchstone-sync" "$needs_line"

# The Python job must lint the same tree `just lint` does, or CI and local disagree again.
assert_eq "ci.yml: the python job scopes ruff the way the justfile does" "2" \
  "$(awk '/uv run ruff/ && /--extend-exclude .touchstone/ { n++ } END { print n + 0 }' "$CI")"

# Every `uses:` must name a ref that EXISTS. The kit ships these tag-pinned by design, so the
# adopter can run `pinact run` once and get SHAs resolved against their own repo — but pinact stops
# at the first unresolvable ref, so a single wrong major leaves the rest of the file unpinned, the
# zizmor pre-commit hook keeps failing, and the adopter cannot commit. `astral-sh/setup-uv@v8` was
# exactly that: v8 has never existed.
uses_refs="$(awk '
  { line = $0; sub(/[ \t]*#.*$/, "", line) }
  line ~ /uses:[ \t]*[A-Za-z0-9]/ {
    sub(/^.*uses:[ \t]*/, "", line); gsub(/[ \t]+$/, "", line)
    print line
  }' "$CI" | LC_ALL=C sort -u)"
uses_n="$(printf '%s\n' "$uses_refs" | awk 'NF { n++ } END { print n + 0 }')"
assert_eq "ci.yml: the template really has actions to resolve" "at least 6" \
  "$(if [ "$uses_n" -ge 6 ]; then echo "at least 6"; else echo "only $uses_n"; fi)"

assert_eq "ci.yml: every action is tag-pinned, not floating on a branch" "" \
  "$(printf '%s\n' "$uses_refs" | awk 'NF && $0 !~ /@v?[0-9]/ { print }')"

if command -v git >/dev/null 2>&1 &&
  git ls-remote --tags --refs "https://github.com/actions/checkout" >/dev/null 2>&1; then
  unresolvable=""
  resolved=0
  while read -r ref; do
    [ -n "$ref" ] || continue
    repo="${ref%@*}"
    tag="${ref##*@}"
    if git ls-remote --tags --refs "https://github.com/$repo" 2>/dev/null |
      awk -v t="refs/tags/$tag" '$2 == t { found = 1 } END { exit found ? 0 : 1 }'; then
      resolved=$((resolved + 1))
    else
      unresolvable="$unresolvable $ref"
    fi
  done <<EOF
$uses_refs
EOF
  assert_eq "ci.yml: every action ref resolves to a real tag" "" "$unresolvable"
  assert_eq "ci.yml: the ref check really reached the registry" "at least 6" \
    "$(if [ "$resolved" -ge 6 ]; then echo "at least 6"; else echo "only $resolved"; fi)"
else
  ts_skip "ci.yml action refs resolve" "no network (or git absent) — the tag-shape rows still ran"
fi

# --- the pyproject snippet -------------------------------------------------------------------------

assert_eq "templates/pyproject-snippet.toml is on disk" "present" "$(exists "$SNIP")"

assert_eq "pyproject-snippet.toml: declares a dependency group" "1" \
  "$(awk '/^\[dependency-groups\]/ { n++ } END { print n + 0 }' "$SNIP")"

# The tools the documented flow actually spawns. `just lint` runs ruff; `just test` and the CI
# template run pytest and pytest --cov.
for tool in ruff pytest pytest-cov; do
  assert_eq "pyproject-snippet.toml: the dev group installs $tool" "declared" \
    "$(awk -v t="$tool" '
      /^\[dependency-groups\]/ { in_g = 1; next }
      /^\[/ { in_g = 0 }
      in_g && index($0, "\"" t) == 1 { found = 1 }
      in_g && index($0, "\"" t) > 0 { found = 1 }
      END { print found ? "declared" : "missing" }' "$SNIP")"
done

# Every pinned floor must be a version, not a bare name — an unpinned floor is how a gate silently
# runs a tool old enough to lack the rule it is there to enforce.
assert_eq "pyproject-snippet.toml: every dev dependency carries a version floor" "" \
  "$(awk '
    /^\[dependency-groups\]/ { in_g = 1; next }
    /^\[/ { in_g = 0 }
    in_g && /^[ \t]*"/ && !/>=|==|~=/ { print }' "$SNIP")"

# ruff must not be able to walk the vendored kit even when invoked bare.
assert_eq "pyproject-snippet.toml: [tool.ruff] excludes the vendored kit" "1" \
  "$(awk '/^extend-exclude/ && /\.touchstone/ { n++ } END { print n + 0 }' "$SNIP")"

ts_report
