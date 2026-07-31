#!/usr/bin/env bash
# check-skill-quality — ADVISORY quality check for SKILL.md descriptions (the agent's routing
# prompt). Beyond the structural checks in check-skills.sh, this flags descriptions that are
# technically valid but weak: a vague main verb, a generic boilerplate opening, or a first-few-words
# opening copy-pasted across skills (which makes the picker pick wrong).
#
# WARNINGS NEVER FAIL THE BUILD, and that is deliberate — the signal is worth surfacing but is a
# judgement call, not a rule. It sits in the justfile's `gates` recipe beside four blocking gates,
# though, so the summary line below says "advisory" in words and reports how many skills it
# examined: a zero exit next to a warning count must not read like a blocking gate that passed.
#
# The one thing that is NOT advisory is vacuity. Zero skills examined means the run proved nothing,
# and no gate in this repo may report a pass on zero inputs, so that exits non-zero. This is an
# error condition, not a promotion of warnings to failures.
#   usage: ./scripts/check-skill-quality.sh
# Pure bash + awk. `set -uo pipefail` (no -e). See standards/languages/shell.md.
# Inspired by the description-quality gate in the claudekit-engineer kit.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# --- scope guard: never certify a repo this gate has not opened ---------------------------------
# This gate scans the repo it LIVES in (the `cd` above), by design: it audits touchstone's own
# skills/standards/docs. Invoked the way an adopter would — `./.touchstone/scripts/check-skill-quality.sh` from a
# consuming repo — it therefore walks the vendored kit and prints a confident green about files that
# are not the caller's. That is worse than having no gate, so refuse instead of passing.
#
# The test is POSITIONAL, never identity. "Am I the real touchstone repo?" would also refuse inside
# every temp fixture tree that tests/gates/*.test.sh builds by copying this script into one, taking
# hundreds of rows red for the wrong reason. A vendored copy inside a host repo is recognised by its
# own root being named `.touchstone`, or by that root sitting inside ANOTHER git work tree; a plain
# clone and a fixture tree match neither. TOUCHSTONE_ALLOW_NESTED=1 overrides, for the one honest
# case the second test cannot distinguish: a kit clone that merely sits inside an unrelated repo.
if [ "${TOUCHSTONE_ALLOW_NESTED:-0}" != "1" ]; then
  _ts_root="$(pwd -P)"
  _ts_base="$(basename "$_ts_root")"
  _ts_up="$(dirname "$_ts_root")"
  _ts_host=""
  case "$_ts_base" in
  .touchstone) _ts_host="$_ts_up" ;;
  esac
  if [ -z "$_ts_host" ]; then
    _ts_host="$(git -C "$_ts_up" rev-parse --show-toplevel 2>/dev/null)" || _ts_host=""
  fi
  if [ -n "$_ts_host" ]; then
    {
      echo "check-skill-quality: refusing to run — it would report on the wrong repository."
      echo "  This gate always scans the repo it lives in: $_ts_root"
      echo "  That is a vendored touchstone checkout inside: $_ts_host"
      echo "  So a verdict from here describes the KIT's files and never opens yours. A green would mean nothing."
      echo "  check-{agents,links,skill-quality,skills,standards}.sh are touchstone's OWN CI gates, not adopter gates."
      echo "  From a repo that adopted touchstone you want:"
      echo "    ./.touchstone/scripts/check-sync.sh   is my copy of the kit still in sync? (the adopter-facing gate)"
      echo "    just ci                               my own repo's gates"
      echo "  Kit developers: TOUCHSTONE_ALLOW_NESTED=1 if your kit clone merely sits inside another git repo."
    } >&2
    exit 2
  fi
fi

shopt -s nullglob
files=(skills/*/SKILL.md)
[ ${#files[@]} -eq 0 ] && {
  echo "quality-gate: no skills/*/SKILL.md found — nothing was examined, so this is not a pass" >&2
  exit 1
}

desc_of() {
  awk '/^---[[:space:]]*$/{d++; next} d==1 && /^description:[[:space:]]/{sub(/^description:[[:space:]]+/,""); print; exit}' "$1" |
    sed -E 's/^["'"'"']//; s/["'"'"']$//'
}
# the lowercased first 5 words of a description
opening_of() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | awk '{ for (i=1;i<=5&&i<=NF;i++) printf "%s%s",$i,(i<5&&i<NF?" ":""); print "" }'
}

warn=0
note() {
  echo "WARN: $1: $2" >&2
  warn=$((warn + 1))
}

# pass 1 — find first-5-word openings shared by >1 skill
openings=""
for f in "${files[@]}"; do
  d=$(desc_of "$f")
  [ -z "$d" ] && continue
  openings="$openings$(opening_of "$d")"$'\n'
done
dups=$(printf '%s' "$openings" | sed '/^$/d' | LC_ALL=C sort | LC_ALL=C uniq -d)

# pass 2 — emit warnings
for f in "${files[@]}"; do
  dir=$(basename "$(dirname "$f")")
  d=$(desc_of "$f")
  [ -z "$d" ] && continue
  low=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')

  case "$low" in
  "use when working with this skill"*) note "$dir" "generic boilerplate opening" ;;
  esac
  case "$low" in
  "use when working with"* | "use when handling"* | "use when handle"* | \
    "use when managing"* | "use when manage"* | "use when processing"* | "use when process"*)
    note "$dir" "vague main verb (work with / handle / manage / process) — name concrete triggers"
    ;;
  esac
  if [ -n "$dups" ]; then
    op=$(opening_of "$d")
    printf '%s\n' "$dups" | grep -qxF "$op" && note "$dir" "first-5-word opening duplicated across skills: \"$op\""
  fi
done

echo "quality-gate (advisory — warnings never fail the build): examined ${#files[@]} skill(s), $warn warning(s)"
exit 0
