#!/usr/bin/env bash
# bootstrap — adopt touchstone in the current repo in ONE command: vendor the kit as a pinned git
# submodule at .touchstone, then run init.sh (which generates the per-tool pointers + drops templates).
# Run it from a clone of the kit, inside your TARGET repo:
#   /path/to/touchstone/scripts/bootstrap.sh [--ref vX.Y.Z] [init.sh flags…]
# Any non-`--ref` flag (e.g. --with-hooks, --force, --dry-run) is passed through to init.sh.
# No `curl | sh` — uses a pinned git submodule, per standards/practices/security.md.
# See standards/languages/shell.md. `set -euo pipefail`: abort on first error.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF=""
URL=""
init_args=()
while [ $# -gt 0 ]; do
  case "$1" in
  --ref)
    REF="$2"
    shift 2
    ;;
  --url)
    URL="$2"
    shift 2
    ;;
  -h | --help)
    sed -n '2,8p' "$0"
    exit 0
    ;;
  *)
    init_args+=("$1") # unknown flag → pass through to init.sh
    shift
    ;;
  esac
done

# must run inside the target git work tree
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: run bootstrap.sh from inside the target git repo" >&2
  exit 2
}
TARGET="$(git rev-parse --show-toplevel)"

cd "$TARGET"
if [ -e .touchstone ]; then
  echo "touchstone: .touchstone already present — skipping submodule add"
else
  # only now do we need the kit's URL (override with --url for a remoteless clone)
  url="${URL:-$(git -C "$KIT" config --get remote.origin.url || true)}"
  [ -n "$url" ] || {
    echo "error: cannot determine the touchstone remote URL — pass it with --url <git-url>" >&2
    exit 2
  }
  ref="${REF:-v$(cat "$KIT/VERSION")}"
  echo "touchstone: vendoring $url @ $ref -> .touchstone"
  git submodule add "$url" .touchstone
  git -C .touchstone fetch --tags --quiet || true
  git -C .touchstone checkout --quiet "$ref" 2>/dev/null || echo "touchstone: ref '$ref' not found — staying on the default branch"
fi

echo "touchstone: running init.sh"
bash .touchstone/scripts/init.sh ${init_args[@]+"${init_args[@]}"}
