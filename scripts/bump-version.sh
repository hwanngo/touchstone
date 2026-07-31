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

# .touchstone.toml is the self-adoption marker check-sync.sh keys on, and its own comment promises
# this script keeps the version in lockstep. Until this line existed that promise was false, and the
# first bump after self-adoption would have left the marker on the old version.
[ -f .touchstone.toml ] && { sed -i.bak -E "s/^(version[[:space:]]*=[[:space:]]*\")[^\"]*(\")/\1$new\2/" .touchstone.toml && rm -f .touchstone.toml.bak; }

# skills/CATALOG.md is GENERATED and embeds the version once per skill, and
# .github/workflows/ci.yml regenerates it and `diff -q`s it against the committed copy. Bumping
# without this step left the catalog pinned to the old version, so every release landed CI red.
# Written via a temp file and mv: if the generator rejects a malformed SKILL.md (it exits non-zero
# and names the file), `set -e` aborts here with that diagnostic on stderr rather than truncating
# the committed catalog to nothing.
if [ -f skills/CATALOG.md ]; then
  catalog_tmp="$(mktemp)"
  trap 'rm -f "$catalog_tmp"' EXIT
  bash scripts/gen-skill-catalog.sh >"$catalog_tmp"
  mv "$catalog_tmp" skills/CATALOG.md
  trap - EXIT
  catalog_note=", skills/CATALOG.md"
else
  catalog_note=""
fi

echo "bumped $old -> $new (VERSION, $(find skills -name SKILL.md | wc -l | tr -d ' ') skills, template, plugin$catalog_note)"
echo "next: add a CHANGELOG [$new] section, run the gates, commit, tag v$new."
