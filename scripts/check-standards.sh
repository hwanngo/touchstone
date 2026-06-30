#!/usr/bin/env bash
# check-standards — audit every standards/<domain>/<doc>.md against the touchstone doc template: an H1
# title, a bare '## Definition of done' closer, numbered '## N.' sections (period after the number),
# language-tagged code fences, no trailing-period headings, and no drift markers. Then report which
# docs have no dedicated skill (routed via the touchstone meta-skill) — informational, not a failure.
# Index READMEs and self-audit.md use different shapes and are skipped.
#   usage: ./scripts/check-standards.sh   (no args; scans standards/*/*.md)
# Pure bash + awk/grep (no jq/yq) so CI needs zero install. `set -uo pipefail` (no -e) aggregates
# every failure into one exit code — mirrors scripts/check-skills.sh. See standards/languages/shell.md.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

fail=0
err() {
  echo "FAIL: $1: $2"
  fail=1
}

# true (exit 0) if text on stdin contains an opening ``` fence with no language tag
untagged_fence() {
  awk '/^[[:space:]]*```/ { n++; if (n % 2 == 1 && $0 ~ /^[[:space:]]*```[[:space:]]*$/) found = 1 }
       END { exit found ? 0 : 1 }'
}

shopt -s nullglob
files=(standards/*/*.md)
[ ${#files[@]} -eq 0 ] && {
  echo "no standards docs found"
  exit 0
}

# collect the standards docs every skill points at, so we can flag docs with no dedicated skill
skill_refs=$(grep -hoE 'standards/[A-Za-z0-9/_-]+\.md' skills/*/SKILL.md 2>/dev/null | sort -u)

n=0
orphans=""
for f in "${files[@]}"; do
  case "$(basename "$f")" in README.md) continue ;; esac
  rel="${f#standards/}"
  n=$((n + 1))

  # 1. H1 title on the first line
  head -1 "$f" | grep -qE '^# ' || err "$rel" "first line is not an H1 title"

  # 2. a bare '## Definition of done' closer (the doc's enforceable gate list)
  grep -qE '^## Definition of done[[:space:]]*$' "$f" || err "$rel" "missing a bare '## Definition of done' section"

  # 3. numbered section headings carry the period — no '## 3 Title'
  grep -qE '^## [0-9]+ ' "$f" && err "$rel" "numbered heading without a period (use '## N. Title')"

  # 4. no heading whose text ends in a period
  grep -qE '^#{1,6} .*[^.]\.$' "$f" && err "$rel" "a heading ends in a period (drop it)"

  # 5. every fenced code block carries a language tag
  untagged_fence <"$f" && err "$rel" "has an untagged code fence (add a language)"
  # (no drift-marker check here: standards docs legitimately discuss "TODO"/"FIXME" in prose —
  #  that gate lives in check-skills.sh, where bodies are terse AI instructions.)

  # coverage (informational): does any skill point at this doc?
  printf '%s\n' "$skill_refs" | grep -qxF "$f" || orphans="$orphans $rel"
done

if [ -n "$orphans" ]; then
  echo "note: docs with no dedicated skill (reachable via the touchstone router):"
  for o in $orphans; do echo "  - $o"; done
fi

if [ "$fail" -eq 0 ]; then
  echo "Validated $n standards docs."
else
  echo "Standards validation failed."
  exit 1
fi
