#!/usr/bin/env bash
# touchstone drift check — does a consuming repo still match the kit it adopted?
#   ./scripts/check-sync.sh [--target DIR]
# Compares the repo's pinned version (.touchstone.toml) and its copied template files against this
# kit. Exits non-zero if behind or drifted — wire it into CI to catch silent rot.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$PWD"
[ "${1:-}" = "--target" ] && TARGET="${2:?--target needs a directory}"
KIT_VER="$(cat "$KIT/VERSION")"
rc=0

marker="$TARGET/.touchstone.toml"
if [ ! -f "$marker" ]; then
  echo "no .touchstone.toml in $TARGET — run scripts/init.sh first" >&2
  exit 2
fi
repo_ver="$(grep -E '^version' "$marker" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"

if [ "$repo_ver" != "$KIT_VER" ]; then
  echo "VERSION: repo pins $repo_ver, kit is $KIT_VER — review CHANGELOG.md and re-run init."
  rc=1
else
  echo "VERSION: up to date ($KIT_VER)."
fi

# Managed files: "kit/source::repo/dest"
managed="
templates/biome.json::biome.json
templates/golangci.yml::.golangci.yml
templates/dockerignore::.dockerignore
templates/pre-commit-config.yaml::.pre-commit-config.yaml
templates/justfile::justfile
templates/dependabot.yml::.github/dependabot.yml
templates/github/workflows/ci.yml::.github/workflows/ci.yml
templates/claude-settings.json::.claude/settings.json
.editorconfig::.editorconfig
.gitattributes::.gitattributes
"
echo "Drifted files (repo differs from kit):"
drift=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  src="${line%%::*}"
  dest="${line##*::}"
  [ -f "$TARGET/$dest" ] || continue
  if ! diff -q "$KIT/$src" "$TARGET/$dest" >/dev/null 2>&1; then
    echo "  ~ $dest"
    drift=1
    rc=1
  fi
done <<EOF
$(printf '%s\n' "$managed" | sed '/^$/d')
EOF
[ "$drift" -eq 0 ] && echo "  (none)"

exit $rc
