#!/usr/bin/env bash
# check-skill-quality — warn-only quality gate for SKILL.md descriptions (the agent's routing
# prompt). Beyond the structural checks in check-skills.sh, this flags descriptions that are
# technically valid but weak: a vague main verb, a generic boilerplate opening, or a first-few-words
# opening copy-pasted across skills (which makes the picker pick wrong). Always exits 0 — it prints
# "WARN:" lines + a count so the signal is visible without breaking the build.
#   usage: ./scripts/check-skill-quality.sh
# Pure bash + awk. `set -uo pipefail` (no -e); never fails. See standards/languages/shell.md.
# Inspired by the description-quality gate in the claudekit-engineer kit.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

shopt -s nullglob
files=(skills/*/SKILL.md)
[ ${#files[@]} -eq 0 ] && {
  echo "quality-gate: 0 warning(s)"
  exit 0
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

echo "quality-gate: $warn warning(s)"
exit 0
