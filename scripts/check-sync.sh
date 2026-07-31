#!/usr/bin/env bash
# touchstone drift check — does a consuming repo still match the kit it adopted?
#   ./scripts/check-sync.sh [--target DIR] [--print-diverge DEST]
# Compares the repo's pinned version (.touchstone.toml) and its copied template files against this
# kit. Exits non-zero if behind or drifted — wire it into CI to catch silent rot.
#
# Declared divergences. A managed file whose copy intentionally differs from the kit's source can be
# declared in .touchstone.toml's optional `diverge` list, one entry per file, pinning the sha256 of
# BOTH sides plus a human reason. That keeps the gate meaningful rather than turning it off: editing
# either side breaks a pinned hash and fails until a human re-declares, a declaration whose two
# files have become identical fails as stale, and undeclared drift fails exactly as before. Use
# `--print-diverge DEST` to emit a ready-to-paste entry; the paste is deliberately manual.
#
# Exit codes: 0 = clean · 1 = drift / version / stale declaration · 2 = unusable (no marker, no
# such target, unknown flag).
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET="$PWD"
PRINT_DIVERGE=""

while [ $# -gt 0 ]; do
  case "$1" in
  --target)
    TARGET="${2:?--target needs a directory}"
    shift 2
    ;;
  --print-diverge)
    PRINT_DIVERGE="${2:?--print-diverge needs a managed dest path}"
    shift 2
    ;;
  -h | --help)
    sed -n '2,4p' "$0"
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 2
    ;;
  esac
done

if [ ! -d "$TARGET" ]; then
  echo "no such directory: $TARGET" >&2
  exit 2
fi
TARGET="$(cd "$TARGET" && pwd -P)"
KIT_VER="$(cat "$KIT/VERSION")"
rc=0

# Both roots are physical paths, so this is a real identity test (same comparison bootstrap.sh
# uses), not a string coincidence: IN_KIT means the kit is checking itself.
IN_KIT=0
[ "$KIT" = "$TARGET" ] && IN_KIT=1

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi | cut -d' ' -f1
}

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
hooks/guard-bash.sh::.claude/hooks/guard-bash.sh
hooks/block-secrets.sh::.claude/hooks/block-secrets.sh
hooks/format-touched.sh::.claude/hooks/format-touched.sh
hooks/audit-touched.sh::.claude/hooks/audit-touched.sh
hooks/nudge-ci.sh::.claude/hooks/nudge-ci.sh
hooks/touchstone-context.sh::.claude/hooks/touchstone-context.sh
hooks/lib/secret-paths.sh::.claude/hooks/lib/secret-paths.sh
"
managed_list="$(printf '%s\n' "$managed" | sed '/^$/d')"

# managed_src <dest> — echo the kit-side source for a managed dest, or nothing if unmanaged.
managed_src() {
  local want="$1" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "${line##*::}" = "$want" ]; then
      printf '%s\n' "${line%%::*}"
      return 0
    fi
  done <<EOF
$managed_list
EOF
  return 0
}

marker="$TARGET/.touchstone.toml"

# The diverge list, one raw "dest :: destsha :: srcsha :: reason" string per line. A marker without
# a `diverge` key yields the empty string, so adopters that never declare anything are untouched.
diverge=""
if [ -f "$marker" ]; then
  diverge="$(sed -n '/^diverge = \[/,/^\]/p' "$marker" | grep -oE '"[^"]*"' | sed 's/^"//; s/"$//' || true)"
fi

# diverge_entry <dest> — echo the first declaration for <dest>, or nothing.
diverge_entry() {
  local want="$1" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
    "$want :: "*)
      printf '%s\n' "$line"
      return 0
      ;;
    esac
  done <<EOF
$diverge
EOF
  return 0
}

# --print-diverge: emit one ready-to-paste entry and stop. Nothing is written to the TOML on
# purpose — re-declaring an intentional divergence is a review step, not an automated refresh.
if [ -n "$PRINT_DIVERGE" ]; then
  src="$(managed_src "$PRINT_DIVERGE")"
  if [ -z "$src" ]; then
    echo "$PRINT_DIVERGE is not a managed file — nothing to declare" >&2
    exit 2
  fi
  if [ ! -f "$TARGET/$PRINT_DIVERGE" ] || [ ! -f "$KIT/$src" ]; then
    echo "cannot hash $PRINT_DIVERGE: missing $TARGET/$PRINT_DIVERGE or $KIT/$src" >&2
    exit 2
  fi
  existing="$(diverge_entry "$PRINT_DIVERGE")"
  reason="TODO: state why this repo's copy intentionally differs from $src"
  if [ -n "$existing" ]; then
    rest="${existing#* :: }"
    rest="${rest#* :: }"
    reason="${rest#* :: }"
  fi
  printf '%s :: %s :: %s :: %s\n' \
    "$PRINT_DIVERGE" "$(sha256 "$TARGET/$PRINT_DIVERGE")" "$(sha256 "$KIT/$src")" "$reason"
  exit 0
fi

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

# AGENTS.md routing sanity. init.sh rewrites the standards/ paths in an adopter's copy to point at
# the vendored kit; a copy that still targets a root standards/ which does not exist here was
# hand-copied around init.sh and routes every agent into thin air. In the kit, standards/ exists, so
# this is a no-op.
if [ -f "$TARGET/AGENTS.md" ] && [ ! -d "$TARGET/standards" ] &&
  grep -qE '\]\(standards/' "$TARGET/AGENTS.md"; then
  echo "AGENTS.md: links target standards/ but no standards/ exists here — re-run init.sh --force so they target the vendored kit"
  rc=1
fi

# In the kit only, and only when git can answer, ignore dest files that exist but are not tracked:
# a developer's local, git-ignored .claude/ hook copies must not make `just ci` disagree with CI.
skip_untracked=0
if [ "$IN_KIT" -eq 1 ] && command -v git >/dev/null 2>&1 &&
  git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  skip_untracked=1
fi

echo "Drifted files (repo differs from kit):"
drift=0
checked=0
declared=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  src="${line%%::*}"
  dest="${line##*::}"
  [ -f "$TARGET/$dest" ] || continue
  if [ "$skip_untracked" -eq 1 ] && ! git -C "$TARGET" ls-files --error-unmatch "$dest" >/dev/null 2>&1; then
    continue
  fi
  checked=$((checked + 1))
  entry="$(diverge_entry "$dest")"
  if diff -q "$KIT/$src" "$TARGET/$dest" >/dev/null 2>&1; then
    # Identical. Only interesting if something still claims they diverge.
    if [ -n "$entry" ]; then
      echo "  ! $dest declared divergent but now matches the kit — remove its diverge entry"
      drift=1
      rc=1
    fi
  elif [ -z "$entry" ]; then
    echo "  ~ $dest"
    drift=1
    rc=1
  else
    rest="${entry#* :: }"
    want_dest="${rest%% :: *}"
    rest="${rest#* :: }"
    want_src="${rest%% :: *}"
    reason="${rest#* :: }"
    if [ "$(sha256 "$TARGET/$dest")" = "$want_dest" ] && [ "$(sha256 "$KIT/$src")" = "$want_src" ]; then
      echo "  = $dest (declared divergence: $reason)"
      declared=$((declared + 1))
    else
      echo "  ! $dest declared divergence but content changed since declaration — review and re-run: scripts/check-sync.sh --print-diverge $dest"
      drift=1
      rc=1
    fi
  fi
done <<EOF
$managed_list
EOF
if [ "$drift" -eq 0 ]; then
  if [ "$declared" -eq 0 ]; then echo "  (none)"; else echo "  (none undeclared)"; fi
fi

# A declaration that names something the kit does not manage cannot be verified by anything above —
# it would sit in the marker forever looking like a reviewed exception.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  dest="${line%% :: *}"
  if [ -z "$(managed_src "$dest")" ]; then
    echo "  ! $dest declared divergent but is not a managed file — remove the entry"
    rc=1
  fi
done <<EOF
$diverge
EOF

# Never pass on nothing. A run that compared zero managed files has verified zero things; saying
# "no drift" there is the vacuous-green failure this kit exists to prevent.
echo "Checked $checked managed file(s)."
if [ "$checked" -eq 0 ]; then
  echo "check-sync: no managed files found in $TARGET — nothing was verified. Run scripts/init.sh." >&2
  rc=1
fi

exit $rc
