#!/usr/bin/env bash
# bump-version — set the kit version everywhere it's pinned, in one shot: the VERSION file, every
# skill's metadata.version, the SKILL template, and the plugin manifest. Keeps check-skills.sh's
# "metadata.version == repo VERSION" gate satisfied so a release is one command, not 60 edits.
#   usage: ./scripts/bump-version.sh X.Y.Z
# See standards/practices/collaboration.md (releases). `set -euo pipefail`: abort on any error.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

new="${1:-}"
printf '%s' "$new" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "usage: $0 X.Y.Z (semver)" >&2
  exit 2
}
old="$(cat VERSION 2>/dev/null || echo none)"

printf '%s\n' "$new" >VERSION

# every skill's metadata.version — scoped to the frontmatter block so a body `version:` (e.g. in a
# YAML example) can't be rewritten
for f in skills/*/SKILL.md; do
  [ -e "$f" ] || continue
  sed -i.bak -E "/^---[[:space:]]*\$/,/^---[[:space:]]*\$/ s/^([[:space:]]+version:[[:space:]]*).*/\1$new/" "$f" && rm -f "$f.bak"
done

# the template + the plugin manifest
[ -f templates/SKILL.md ] && { sed -i.bak -E "/^---[[:space:]]*\$/,/^---[[:space:]]*\$/ s/^([[:space:]]+version:[[:space:]]*).*/\1$new/" templates/SKILL.md && rm -f templates/SKILL.md.bak; }
[ -f .claude-plugin/plugin.json ] && { sed -i.bak -E "s/(\"version\":[[:space:]]*\")[^\"]*(\")/\1$new\2/" .claude-plugin/plugin.json && rm -f .claude-plugin/plugin.json.bak; }

echo "bumped $old -> $new (VERSION, $(find skills -name SKILL.md | wc -l | tr -d ' ') skills, template, plugin)"
echo "next: add a CHANGELOG [$new] section, run the gates, commit, tag v$new."
