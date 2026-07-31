#!/usr/bin/env bash
# Gate: every `- id:` in a shipped pre-commit config must exist in that repo's
# .pre-commit-hooks.yaml AT THE PINNED `rev`.
#
# WHY. pre-commit resolves hook ids at run time and aborts the WHOLE run on the first unknown one —
# it does not skip the offending hook. templates/pre-commit-config.yaml shipped `ruff-check` against
# `astral-sh/ruff-pre-commit` at `rev: v0.8.0`, where the ids are `ruff` and `ruff-format`
# (`ruff-check` arrived in v0.9.x). Every `pre-commit run` and therefore every `git commit` in an
# adopting repo failed, with `--no-verify` — banned by hard rule 10 and denied by the kit's own
# guard-bash.sh — the only escape. The whole commit-time backstop (gitleaks, zizmor, uv-lock) never
# ran. Invisible from inside the kit: .pre-commit-config.yaml is a declared divergence that replaces
# the python/node/actions blocks, so the kit has never executed the block it ships to adopters.
#
# Structure, following tests/gates/check-links.test.sh:
#   1. The two parsers (`triples` over a config, `ids_of` over a hooks file) are proved OFFLINE
#      against fixtures first, including a fixture that IS the defect, so the live rows below cannot
#      pass because the parser reads nothing.
#   2. `missing_ids` has a distinct "vacuous" outcome for a config that yielded zero remote triples,
#      so a scan that resolved nothing can never be mistaken for a pass.
#   3. The live rows assert a floor on the number of triples checked, not just the verdict.
#   4. The live rows need the network. They self-skip as a group (hard rule 4) when it is absent —
#      never silently, and never by weakening the offline rows above.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"
FIXTURES="$KIT/tests/fixtures"

# --- the parsers -------------------------------------------------------------------------------

# triples <config> — emits "<repo> <rev> <id>" per REMOTE hook, in file order. `repo: local` blocks
# are skipped: their ids are defined inline and there is nothing upstream to resolve them against.
# shellcheck disable=SC2016 # awk program text: $0 is awk's and must not expand in bash
TRIPLES='
BEGIN { repo = ""; rev = "" }
{ line = $0; sub(/[ \t]*#.*$/, "", line) }
line ~ /^[ \t]*-[ \t]+repo:[ \t]*/ {
  v = line; sub(/^[ \t]*-[ \t]+repo:[ \t]*/, "", v); gsub(/[ \t]+$/, "", v)
  repo = v; rev = ""
  next
}
line ~ /^[ \t]*rev:[ \t]*/ {
  v = line; sub(/^[ \t]*rev:[ \t]*/, "", v); gsub(/[ \t]+$/, "", v)
  rev = v
  next
}
line ~ /^[ \t]*-[ \t]+id:[ \t]*/ {
  v = line; sub(/^[ \t]*-[ \t]+id:[ \t]*/, "", v); gsub(/[ \t]+$/, "", v)
  if (repo == "" || repo == "local" || rev == "") next
  printf "%s %s %s\n", repo, rev, v
  next
}
'

# ids_of <hooks-yaml> — the id of every hook the upstream repo defines, one per line.
# shellcheck disable=SC2016 # awk program text
IDS_OF='
{ line = $0; sub(/[ \t]*#.*$/, "", line) }
line ~ /^[ \t]*-[ \t]+id:[ \t]*/ {
  v = line; sub(/^[ \t]*-[ \t]+id:[ \t]*/, "", v); gsub(/[ \t]+$/, "", v)
  print v
}
'

triples() { awk "$TRIPLES" "$1"; }
ids_of() { awk "$IDS_OF" "$1"; }

# missing_ids <config> <hooks-yaml> — ids the config asks for that the hooks file does not define.
# Prints one per line; prints nothing when every id resolves.
missing_ids() {
  local cfg="$1" hooks="$2" known="" id=""
  known=" $(ids_of "$hooks" | tr '\n' ' ')"
  while read -r _repo _rev id; do
    [ -n "$id" ] || continue
    case "$known" in
    *" $id "*) ;;
    *) printf '%s\n' "$id" ;;
    esac
  done < <(triples "$cfg")
}

count_triples() { triples "$1" | awk 'END { print NR + 0 }'; }

exists() { if [ -f "$1" ]; then echo present; else echo absent; fi; }

# --- the parsers can tell good from bad (offline) -----------------------------------------------

assert_eq "fixture precommit-ids/hooks.yaml is on disk" "present" "$(exists "$FIXTURES/precommit-ids/hooks.yaml")"
assert_eq "fixture precommit-ids/bad.yaml is on disk" "present" "$(exists "$FIXTURES/precommit-ids/bad.yaml")"
assert_eq "fixture precommit-ids/good.yaml is on disk" "present" "$(exists "$FIXTURES/precommit-ids/good.yaml")"
assert_eq "fixture precommit-ids/local-only.yaml is on disk" "present" "$(exists "$FIXTURES/precommit-ids/local-only.yaml")"

assert_eq "ids_of reads every hook the upstream file defines" "ruff ruff-format" \
  "$(ids_of "$FIXTURES/precommit-ids/hooks.yaml" | tr '\n' ' ' | sed 's/ $//')"

assert_eq "triples pairs each id with its repo and rev" \
  "https://example.invalid/astral-sh/ruff-pre-commit v0.8.0 ruff-check|https://example.invalid/astral-sh/ruff-pre-commit v0.8.0 ruff-format" \
  "$(triples "$FIXTURES/precommit-ids/bad.yaml" | paste -sd '|' -)"

assert_eq "a config naming a non-existent id is flagged, and only that id" "ruff-check" \
  "$(missing_ids "$FIXTURES/precommit-ids/bad.yaml" "$FIXTURES/precommit-ids/hooks.yaml" | tr '\n' ' ' | sed 's/ $//')"

assert_eq "a config whose ids all exist is clean" "" \
  "$(missing_ids "$FIXTURES/precommit-ids/good.yaml" "$FIXTURES/precommit-ids/hooks.yaml")"

# The count is exact on purpose: a parser that went clean by reading nothing fails this row.
assert_eq "the clean fixture really had two ids resolved" "2" "$(count_triples "$FIXTURES/precommit-ids/good.yaml")"

# `repo: local` yields no remote triples — which is why the live rows below assert a floor rather
# than only a verdict. Zero ids checked is not a pass.
assert_eq "local hooks are not resolved against an upstream repo" "0" \
  "$(count_triples "$FIXTURES/precommit-ids/local-only.yaml")"

# --- the real files: structure (offline) ---------------------------------------------------------

TEMPLATE="$KIT/templates/pre-commit-config.yaml"
OWN="$KIT/.pre-commit-config.yaml"

assert_eq "templates/pre-commit-config.yaml is on disk" "present" "$(exists "$TEMPLATE")"
assert_eq "the kit's own .pre-commit-config.yaml is on disk" "present" "$(exists "$OWN")"

TEMPLATE_N="$(count_triples "$TEMPLATE")"
OWN_N="$(count_triples "$OWN")"
at_least() { if [ "$1" -ge "$2" ]; then echo "at least $2"; else echo "only $1"; fi; }
assert_eq "templates/pre-commit-config.yaml: every remote hook carries a repo and a rev" \
  "at least 14" "$(at_least "$TEMPLATE_N" 14)"
assert_eq "the kit's own config: every remote hook carries a repo and a rev" \
  "at least 10" "$(at_least "$OWN_N" 10)"

# The defect itself, as a literal: `ruff-check` at any v0.8.x rev is the combination that wedges
# every adopter. Offline, so this row holds even when the live rows below skip.
assert_eq "templates/pre-commit-config.yaml: no ruff hook is pinned to a rev predating its id" "" \
  "$(triples "$TEMPLATE" | awk '$3 ~ /^ruff-check$/ && $2 ~ /^v0\.[0-8]\./ { print }')"

# --- the real files: live resolution --------------------------------------------------------------
# Needs curl and network. Skipped as a group when either is absent — the offline rows above still ran.

CACHE=""
cleanup() { [ -n "$CACHE" ] && rm -rf "$CACHE"; }
trap cleanup EXIT

net_ok=0
if command -v curl >/dev/null 2>&1; then
  CACHE="$(mktemp -d 2>/dev/null || true)"
  if [ -n "$CACHE" ] && curl -fsSL --max-time 20 \
    "https://raw.githubusercontent.com/pre-commit/pre-commit-hooks/v5.0.0/.pre-commit-hooks.yaml" \
    >"$CACHE/probe.yaml" 2>/dev/null; then
    net_ok=1
  fi
fi

if [ "$net_ok" -eq 0 ]; then
  ts_skip "pre-commit hook ids resolve upstream" "no network (or curl absent) — offline rows still ran"
  ts_report
  exit 0
fi

# raw_url <repo-url> <rev> — the .pre-commit-hooks.yaml for a GitHub repo at a rev.
raw_url() {
  local repo="$1" rev="$2" slug=""
  slug="${repo#https://github.com/}"
  slug="${slug%.git}"
  printf 'https://raw.githubusercontent.com/%s/%s/.pre-commit-hooks.yaml' "$slug" "$rev"
}

# fetch_hooks <repo-url> <rev> — path to the cached hooks file, or empty on failure.
fetch_hooks() {
  local repo="$1" rev="$2" key="" out=""
  case "$repo" in
  https://github.com/*) ;;
  *)
    printf ''
    return 0
    ;;
  esac
  key="$(printf '%s@%s' "$repo" "$rev" | tr -c 'A-Za-z0-9' '_')"
  out="$CACHE/$key"
  if [ ! -f "$out" ]; then
    curl -fsSL --max-time 20 "$(raw_url "$repo" "$rev")" >"$out" 2>/dev/null || {
      rm -f "$out"
      printf ''
      return 0
    }
  fi
  printf '%s' "$out"
}

# check_live <label> <config> <floor> — one assertion row per (repo, rev) block, plus a floor row.
check_live() {
  local label="$1" cfg="$2" floor="$3"
  local checked=0 unresolvable="" repo="" rev="" id="" hooks="" known=""
  local bad=""
  while read -r repo rev id; do
    [ -n "$id" ] || continue
    hooks="$(fetch_hooks "$repo" "$rev")"
    if [ -z "$hooks" ]; then
      unresolvable="$unresolvable $repo@$rev"
      continue
    fi
    known=" $(ids_of "$hooks" | tr '\n' ' ')"
    checked=$((checked + 1))
    case "$known" in
    *" $id "*) ;;
    *) bad="$bad $repo@$rev:$id" ;;
    esac
  done < <(triples "$cfg")

  assert_eq "$label: every pinned rev has a fetchable .pre-commit-hooks.yaml" "" "$unresolvable"
  assert_eq "$label: every hook id exists at its pinned rev" "" "$bad"
  assert_eq "$label: the check really resolved ids upstream" "at least $floor" "$(at_least "$checked" "$floor")"
}

check_live "templates/pre-commit-config.yaml" "$TEMPLATE" 14
check_live "the kit's own .pre-commit-config.yaml" "$OWN" 10

ts_report
