#!/usr/bin/env bash
# bootstrap — adopt touchstone in the current repo in ONE command: vendor the kit as a pinned git
# submodule at .touchstone, then run init.sh (which generates the per-tool pointers + drops templates).
# Run it from a clone of the kit, inside your TARGET repo:
#   /path/to/touchstone/scripts/bootstrap.sh [--ref vX.Y.Z] [--url <git-url>] [--allow-unpinned] [init.sh flags…]
# Any non-bootstrap flag (e.g. --with-hooks, --force, --dry-run) is passed through to init.sh.
# --ref            git ref to pin .touchstone to (default: v<VERSION> from the kit clone). A
#                  missing/unresolvable ref is FATAL — pass --allow-unpinned to proceed unpinned
#                  on the default branch instead. NOTE: until touchstone publishes its first
#                  vX.Y.Z tag the default ref cannot resolve, so --ref/--allow-unpinned is not an
#                  advanced option, it is the only way through; the failure message says so and
#                  prints the exact commands.
# --url            explicit submodule URL (default: the kit clone's `origin` remote, normalized
#                  from a `git@host:path` SSH form to `https://host/path` so tokenless CI can run
#                  `git submodule update`).
# --allow-unpinned proceed on the default branch when --ref cannot be resolved, instead of failing.
# No `curl | sh` — uses a pinned git submodule, per standards/practices/security.md.
# See standards/languages/shell.md. `set -euo pipefail`: abort on first error.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF=""
URL=""
ALLOW_UNPINNED=0
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
  --allow-unpinned)
    ALLOW_UNPINNED=1
    shift
    ;;
  -h | --help)
    sed -n '2,15p' "$0"
    exit 0
    ;;
  *)
    init_args+=("$1") # unknown flag → pass through to init.sh
    shift
    ;;
  esac
done

# git@host:path(.git) -> https://host/path(.git) — applied only to a URL we derive ourselves; an
# explicit --url is used verbatim (the caller chose it deliberately). An SSH-shaped URL landing in
# an adopter's .gitmodules breaks tokenless CI `git submodule update`.
normalize_url() {
  case "$1" in
  git@*:*)
    host_path="${1#git@}" # host:path
    host="${host_path%%:*}"
    path="${host_path#*:}"
    printf 'https://%s/%s\n' "$host" "$path"
    ;;
  *)
    printf '%s\n' "$1"
    ;;
  esac
}

# must run inside the target git work tree
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: run bootstrap.sh from inside the target git repo" >&2
  exit 2
}
TARGET="$(git rev-parse --show-toplevel)"

# refuse to vendor the kit into itself (e.g. running this from a checkout of touchstone itself)
if [ "$(cd "$TARGET" && pwd -P)" = "$(cd "$KIT" && pwd -P)" ]; then
  echo "error: target repo is the touchstone kit itself — refusing to bootstrap into itself" >&2
  exit 2
fi

cd "$TARGET"

# .touchstone only counts as "already vendored" if it's a REGISTERED submodule — a stray file or
# directory left at that path previously skipped vendoring silently and then handed init.sh a path
# that might not even exist.
if git submodule status -- .touchstone >/dev/null 2>&1; then
  echo "touchstone: .touchstone already a registered submodule — skipping vendoring"
elif [ -e .touchstone ]; then
  echo "error: .touchstone exists but is not a registered git submodule — remove or resolve it before bootstrapping" >&2
  exit 2
else
  # only now do we need the kit's URL (override with --url for a remoteless clone)
  if [ -n "$URL" ]; then
    url="$URL"
  else
    derived_url="$(git -C "$KIT" config --get remote.origin.url || true)"
    [ -n "$derived_url" ] || {
      echo "error: cannot determine the touchstone remote URL — pass it with --url <git-url>" >&2
      exit 2
    }
    url="$(normalize_url "$derived_url")"
  fi
  ref_was_default=0
  if [ -z "$REF" ]; then ref_was_default=1; fi
  ref="${REF:-v$(cat "$KIT/VERSION")}"
  echo "touchstone: vendoring $url @ $ref -> .touchstone"
  git submodule add "$url" .touchstone
  git -C .touchstone fetch --tags --quiet || true
  if git -C .touchstone checkout --quiet "$ref" 2>/dev/null; then
    git add .touchstone
  elif [ "$ALLOW_UNPINNED" -eq 1 ]; then
    echo "touchstone: ref '$ref' not found — proceeding unpinned on the default branch (--allow-unpinned)"
    git add .touchstone
  else
    # An unresolvable ref used to print one line naming two flags and nothing else. The overwhelmingly
    # common case — the DEFAULT ref, `v<VERSION>`, against a kit that has never been tagged — read as
    # "you typed the wrong ref", when in fact no ref the adopter could have typed would have worked.
    # So diagnose before rolling back, while the clone is still on disk and can be interrogated:
    # whether the ref was defaulted, whether the remote publishes any tags at all, and what the
    # default branch's HEAD actually is. Every option named below is one the adopter can run verbatim.
    # No pipeline here: `git tag --list | grep -c .` would take its exit status through a pipe, and
    # `grep -c` exits 1 on an empty (untagged) remote — the very case being diagnosed.
    tags_raw="$(git -C .touchstone tag --list 2>/dev/null || true)"
    tag_count=0
    while IFS= read -r _t; do
      [ -n "$_t" ] && tag_count=$((tag_count + 1))
    done <<EOF
$tags_raw
EOF
    head_sha="$(git -C .touchstone rev-parse --short HEAD 2>/dev/null || true)"
    head_branch="$(git -C .touchstone rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    # detached HEAD reports "HEAD", which is not a branch name an adopter can pass to --ref
    case "$head_branch" in "" | HEAD) head_branch="" ;; esac
    # the pass-through flags the adopter already typed, so every suggested command is copy-pasteable
    # as-is. `${arr[@]+"${arr[@]}"}` is the bash 3.2-safe empty-array expansion used elsewhere here.
    extra=""
    if [ "${#init_args[@]}" -gt 0 ]; then extra=" ${init_args[*]}"; fi
    # leave no partial state behind: an adopter should be able to fix --ref and rerun cleanly
    git rm -f --ignore-unmatch .touchstone >/dev/null 2>&1 || true
    rm -rf "$TARGET/.git/modules/.touchstone" 2>/dev/null || true
    if [ -e .gitmodules ] && [ ! -s .gitmodules ]; then
      git rm -f --ignore-unmatch .gitmodules >/dev/null 2>&1 || true
      rm -f .gitmodules
    fi
    {
      echo "error: cannot pin .touchstone — ref '$ref' does not exist in $url"
      if [ "$ref_was_default" -eq 1 ]; then
        echo "  '$ref' is the DEFAULT ref: 'v' + the VERSION file of the kit clone at $KIT."
        echo "  You did not choose it, and no --ref you could have typed would have been used instead."
      fi
      if [ "$tag_count" -eq 0 ]; then
        echo "  The remote publishes NO tags at all — touchstone has not been released at a version tag yet,"
        echo "  so the bare 'bootstrap.sh' form cannot work until it is. This is a kit release gap, not your mistake."
      else
        echo "  The remote publishes $tag_count tag(s); '$ref' is not one of them. List them with:"
        echo "      git -C $KIT tag --list"
      fi
      echo "  Nothing was written — .touchstone, .gitmodules and .git/modules/.touchstone were all rolled back."
      echo "  Pick one and rerun:"
      if [ -n "$head_sha" ]; then
        echo "      $0 --ref $head_sha$extra"
        echo "          pin to an exact commit (RECOMMENDED — reproducible; $head_sha is the kit clone's HEAD today)"
      fi
      if [ -n "$head_branch" ]; then
        echo "      $0 --ref $head_branch$extra"
        echo "          pin to branch '$head_branch' (the recorded submodule commit is still exact, but a re-run moves it)"
      fi
      echo "      $0 --allow-unpinned$extra"
      echo "          vendor the kit's default branch without requiring any ref to resolve"
    } >&2
    exit 1
  fi
fi

echo "touchstone: running init.sh"
bash .touchstone/scripts/init.sh ${init_args[@]+"${init_args[@]}"}
