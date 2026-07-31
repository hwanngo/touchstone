#!/usr/bin/env bash
# gen-skill-catalog — generate a machine index of every skill from its SKILL.md frontmatter, bucketed
# by domain (derived from the standards/<domain>/ doc it points at). Deterministic: repeated runs
# produce byte-identical output, so CI can regenerate and diff to catch a stale catalog.
#   usage: ./scripts/gen-skill-catalog.sh           # prints to stdout
#          ./scripts/gen-skill-catalog.sh > skills/CATALOG.md
# Pure bash + awk/grep. `set -euo pipefail`: abort on error (a generator must not emit partial
# output). See standards/languages/shell.md.
#
# Two things this script has to get right, both of which it used to get wrong:
#
# 1. FAILING LOUDLY. The domain assignment below is a grep pipeline; when a SKILL.md referenced no
#    standards/<domain>/ doc, grep exited 1, pipefail promoted it to the pipeline status, the command
#    substitution carried it to the assignment, and `set -e` killed the script mid-loop — exit 1 with
#    NOTHING printed to stdout or stderr. That conflated a genuinely malformed skill with a perfectly
#    valid router skill that simply points at no single domain. The pipeline is now explicitly
#    tolerant (|| true, meta fallback) and malformed frontmatter is detected and REPORTED by name.
#    A malformed skill still exits non-zero — a wrong catalog is worse than no catalog.
#
# 2. NOT DROPPING A DOMAIN. The body loop iterated a hardcoded domain whitelist while the header
#    counted every row, so a skill in any other domain was counted and then silently omitted. The
#    section order below is derived from the data, with the known domains kept in their curated
#    order and anything new appended, and the emitted row count is checked against the header count.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# Curated display order. NOT a filter: any domain found in the data and not named here is appended
# after these, so a new standards/<domain>/ can never be counted in the header yet missing from the
# body.
KNOWN_DOMAINS="meta languages frameworks platform practices design"

field() { # $1=file $2=key  → frontmatter value (top-level or nested), surrounding quotes unwrapped
  local v
  v=$(awk -v k="$2" '/^---[[:space:]]*$/{d++; next} d==1 && $0 ~ ("^[[:space:]]*" k ":") {sub("^[[:space:]]*" k ":[[:space:]]*",""); print; exit}' "$1")
  # Unwrap a surrounding quote pair so the catalog renders the value, not the YAML syntax around it.
  # Quoting is the only valid way to write a description containing ': ' (a plain scalar may not),
  # so without this the fix for those descriptions leaks a literal '"' into every catalog entry.
  # Mirrors scripts/check-skills.sh. Only a MATCHED pair is unwrapped: a value with an internal or
  # unbalanced quote passes through untouched.
  case $v in
  '"'*'"') v=${v#\"} && v=${v%\"} ;;
  "'"*"'") v=${v#\'} && v=${v%\'} ;;
  esac
  printf '%s\n' "$v"
}

# has_frontmatter <file> — true when the file opens with a '---' line and closes the block with a
# second one. An empty file, or one that starts with prose, is not a skill this generator can index.
has_frontmatter() {
  awk 'NR==1 { if ($0 !~ /^---[[:space:]]*$/) { bad=1; exit } ; next }
       /^---[[:space:]]*$/ { found=1; exit }
       END { exit (bad || !found) ? 1 : 0 }' "$1"
}

tmp="$(mktemp)"
body="$(mktemp)"
trap 'rm -f "$tmp" "$body"' EXIT

bad=0
shopt -s nullglob
for f in skills/*/SKILL.md; do
  problem=""
  if ! has_frontmatter "$f"; then
    problem="no YAML frontmatter block (expected a '---' delimited header at the top of the file)"
  fi
  name=""
  desc=""
  ver=""
  if [ -z "$problem" ]; then
    name="$(field "$f" name)"
    desc="$(field "$f" description)"
    ver="$(field "$f" version)"
    [ -n "$name" ] || problem="frontmatter has no 'name:' field"
    [ -n "$problem" ] || [ -n "$ver" ] || problem="frontmatter has no 'version:' field"
    [ -n "$problem" ] || [ -n "$desc" ] || problem="frontmatter has no 'description:' field"
  fi
  if [ -n "$problem" ]; then
    echo "gen-skill-catalog: $f: $problem" >&2
    bad=$((bad + 1))
    continue
  fi
  # Primary domain = the domain of the first standards/<domain>/ doc the skill references; meta if
  # none. `|| true` because "references no domain doc" is a valid skill shape (a router), not an
  # error — and because a bare pipeline failure here is what used to abort the whole run in silence.
  domain="$(grep -oE 'standards/[a-z-]+/' "$f" | head -1 | sed -E 's|standards/||; s|/||' || true)"
  [ -n "$domain" ] || domain="meta"
  printf '%s\t%s\t%s\t%s\t%s\n' "$domain" "$name" "$ver" "$f" "$desc" >>"$tmp"
done

if [ "$bad" -gt 0 ]; then
  echo "gen-skill-catalog: refusing to generate a catalog from $bad malformed SKILL.md file(s) (listed above)" >&2
  exit 1
fi

count="$(wc -l <"$tmp" | tr -d ' ')"
# Vacuity guard: an "index of all 0 skills" is not a catalog, it is a silent deletion of one.
if [ "$count" -eq 0 ]; then
  echo "gen-skill-catalog: no skills/*/SKILL.md found — refusing to generate an empty catalog" >&2
  exit 1
fi

# Section order: the curated domains that actually occur, in their curated order, then every other
# domain present in the data, sorted. Derived from $tmp so nothing can be counted but not emitted.
present="$(cut -f1 "$tmp" | LC_ALL=C sort -u)"
order=""
for d in $KNOWN_DOMAINS; do
  printf '%s\n' "$present" | grep -qxF "$d" && order="$order $d"
done
for d in $present; do
  case " $KNOWN_DOMAINS " in
  *" $d "*) ;;
  *) order="$order $d" ;;
  esac
done

emitted=0
for domain in $order; do
  rows="$(LC_ALL=C sort -t'	' -k2,2 "$tmp" | awk -F'\t' -v d="$domain" '$1==d')"
  [ -n "$rows" ] || continue
  emitted=$((emitted + $(printf '%s\n' "$rows" | wc -l)))
  printf '\n## %s\n\n' "$domain" >>"$body"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r _ name ver path desc; do
    # shellcheck disable=SC2016  # backticks are literal Markdown code spans, not command substitution
    printf -- '- **[%s](%s)** `v%s` — %s\n' "$name" "${path#skills/}" "$ver" "$desc"
  done >>"$body"
done

if [ "$emitted" -ne "$count" ]; then
  echo "gen-skill-catalog: $((count - emitted)) skill(s) counted but not emitted — a domain was dropped from the body" >&2
  exit 1
fi

printf '<!-- generated by scripts/gen-skill-catalog.sh — do not edit by hand -->\n'
printf '# Skills Catalog\n\n'
# shellcheck disable=SC2016  # backticks are literal Markdown code spans; the format string must stay single-quoted
printf 'Auto-generated index of all %s skills. Refresh with `bash scripts/gen-skill-catalog.sh > skills/CATALOG.md`.\n' "$count"
cat "$body"
