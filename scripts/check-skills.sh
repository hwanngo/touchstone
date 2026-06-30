#!/usr/bin/env bash
# check-skills — audit every skills/*/SKILL.md against the Agent Skills spec + the touchstone
# template: well-formed frontmatter, spec-valid name == dir, trigger-phrased description, license +
# metadata.version (tracking the repo VERSION), the 'Full standard:' / '## Done' spine, language-
# tagged code fences, a body pointing at a real standards/*.md, and no drift markers.
#   usage: ./scripts/check-skills.sh   (no args; scans skills/*/SKILL.md)
# Pure bash + awk/grep (no jq/yq) so CI needs zero install. `set -uo pipefail` (no -e) aggregates
# all failures into one exit code — mirrors scripts/check-links.sh. See standards/languages/shell.md.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

fail=0
seen=""
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
files=(skills/*/SKILL.md)
[ ${#files[@]} -eq 0 ] && {
  echo "no skills found"
  exit 0
}

for f in "${files[@]}"; do
  dir=$(basename "$(dirname "$f")")

  # frontmatter must open with --- and have a closing ---
  [ "$(head -1 "$f")" = "---" ] || {
    err "$dir" "missing opening '---' frontmatter"
    continue
  }
  [ "$(grep -cE '^---[[:space:]]*$' "$f")" -ge 2 ] || {
    err "$dir" "frontmatter not closed"
    continue
  }

  fm=$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$f")
  body=$(awk '/^---[[:space:]]*$/{c++; next} c>=2{print}' "$f")

  name=$(printf '%s\n' "$fm" | grep -E '^name:' | head -1 | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//')
  desc=$(printf '%s\n' "$fm" | grep -E '^description:' | head -1 | sed -E 's/^description:[[:space:]]*//; s/[[:space:]]*$//')

  # name: present, == dir, unique
  if [ -z "$name" ]; then err "$dir" "frontmatter has no 'name:'"; fi
  if [ -n "$name" ] && [ "$name" != "$dir" ]; then err "$dir" "name '$name' != directory '$dir'"; fi
  if [ -n "$name" ]; then
    case " $seen " in *" $name "*) err "$dir" "duplicate skill name '$name'" ;; esac
    seen="$seen $name"
  fi

  # description: present, substantial
  if [ -z "$desc" ]; then
    err "$dir" "frontmatter has no 'description:'"
  elif [ ${#desc} -lt 40 ]; then err "$dir" "description too short (${#desc} chars; need >=40)"; fi

  # name: Agent Skills spec pattern (lowercase, digits, single hyphens) + length <= 64
  if [ -n "$name" ]; then
    printf '%s' "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' || err "$dir" "name '$name' not spec-valid (lowercase/digits/single-hyphen)"
    [ ${#name} -le 64 ] || err "$dir" "name too long (${#name} chars; spec max 64)"
  fi

  # description: trigger-phrased ('Use when …', not a process summary) and within the spec's 1024 cap
  if [ -n "$desc" ]; then
    printf '%s' "$desc" | grep -qiE '^use ' || err "$dir" "description should open with 'Use …' (trigger phrasing, not a summary)"
    [ ${#desc} -le 1024 ] || err "$dir" "description too long (${#desc} chars; spec max 1024)"
  fi

  # Agent Skills spec metadata: license + metadata.version (so a standalone-copied skill self-declares)
  printf '%s\n' "$fm" | grep -qE '^license:' || err "$dir" "frontmatter has no 'license:'"
  printf '%s\n' "$fm" | grep -qE '^[[:space:]]+version:' || err "$dir" "frontmatter has no 'metadata.version:'"

  # metadata.version must track the repo VERSION — stale standalone copies are the failure mode
  ver=$(printf '%s\n' "$fm" | grep -E '^[[:space:]]+version:' | head -1 | sed -E 's/.*version:[[:space:]]*//; s/[[:space:]]*$//')
  if [ -n "$ver" ] && [ -f VERSION ] && [ "$ver" != "$(cat VERSION)" ]; then
    err "$dir" "metadata.version '$ver' != repo VERSION '$(cat VERSION)'"
  fi

  # every fenced code block carries a language tag
  printf '%s\n' "$body" | untagged_fence && err "$dir" "has an untagged code fence (add a language)"

  # template spine — the 'touchstone' router meta-skill is exempt (it has no single canonical doc)
  if [ "$name" != "touchstone" ]; then
    printf '%s\n' "$body" | grep -qE 'Full standards?:' || err "$dir" "missing 'Full standard:' pointer to its standards/*.md doc"
    printf '%s\n' "$body" | grep -qE '^## Done' || err "$dir" "missing the '## Done' closer"
    # the first content section must be '## Always' (load-bearing non-negotiables, uniform across skills)
    first_h2=$(printf '%s\n' "$body" | grep -m1 -E '^## ' | sed -E 's/[[:space:]]*$//')
    [ "$first_h2" = "## Always" ] || err "$dir" "first section must be '## Always' (got '${first_h2:-none}')"
  fi

  # body must reference a real standards/*.md
  refs=$(printf '%s\n' "$body" | grep -oE 'standards/[A-Za-z0-9/_-]+\.md' | sort -u)
  if [ -z "$refs" ]; then
    err "$dir" "body references no standards/*.md doc"
  else
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      [ -f "$r" ] || err "$dir" "references missing doc '$r'"
    done <<<"$refs"
  fi

  # no drift markers
  printf '%s\n' "$body" | grep -qE '\b(TODO|FIXME|XXX)\b' && err "$dir" "body contains TODO/FIXME/XXX"
done

if [ "$fail" -eq 0 ]; then
  echo "Validated ${#files[@]} skills."
else
  echo "Skill validation failed."
  exit 1
fi
