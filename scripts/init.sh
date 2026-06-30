#!/usr/bin/env bash
# touchstone bootstrap — apply the kit to a repo.
#   ./scripts/init.sh [--target DIR] [--force] [--dry-run] [--with-hooks]
# Detects the stack, drops in matching templates, copies AGENTS.md + editor configs,
# writes a .touchstone.toml marker, and prints the next steps. Idempotent: existing files are
# skipped unless --force. See standards/self-audit.md to verify afterwards.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$PWD"
FORCE=0
DRY=0
WITH_HOOKS=0
VERSION="$(cat "$KIT/VERSION")"

while [ $# -gt 0 ]; do
  case "$1" in
  --target)
    TARGET="$2"
    shift 2
    ;;
  --force)
    FORCE=1
    shift
    ;;
  --dry-run)
    DRY=1
    shift
    ;;
  --with-hooks)
    WITH_HOOKS=1
    shift
    ;; # also install opt-in Claude Code agent hooks
  -h | --help)
    sed -n '2,6p' "$0"
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 2
    ;;
  esac
done

say() { printf '  %s\n' "$*"; }
# copy SRC -> TARGET/DEST unless it exists (or --force); honors --dry-run
place() {
  local src="$1" dest="$2" abs="$TARGET/$2"
  if [ -e "$abs" ] && [ "$FORCE" -eq 0 ]; then
    say "skip   $dest (exists)"
    return
  fi
  if [ "$DRY" -eq 1 ]; then
    say "would  $dest"
    return
  fi
  mkdir -p "$(dirname "$abs")"
  cp "$KIT/$src" "$abs"
  say "place  $dest"
}

# write heredoc (stdin) -> TARGET/DEST unless it exists (or --force); honors --dry-run. Used for the
# generated per-tool pointer files so the kit itself ships no root clutter — only AGENTS.md.
gen() {
  local dest="$1" abs="$TARGET/$1"
  if [ -e "$abs" ] && [ "$FORCE" -eq 0 ]; then
    say "skip   $dest (exists)"
    cat >/dev/null
    return
  fi
  if [ "$DRY" -eq 1 ]; then
    say "would  $dest"
    cat >/dev/null
    return
  fi
  mkdir -p "$(dirname "$abs")"
  cat >"$abs"
  say "gen    $dest"
}

echo "touchstone v$VERSION → $TARGET"
[ "$DRY" -eq 1 ] && echo "(dry run — no files written)"

# kit location relative to the target — normally the vendored `.touchstone/` submodule. The canonical
# standards live there, NOT at the target root, so AGENTS.md's standards/ links must point at it.
KIT_REL="${KIT#"$TARGET"/}"
case "$KIT_REL" in /* | "$KIT") KIT_REL=".touchstone" ;; esac

# --- universal ---
# AGENTS.md is the one instruction file we copy to the target root; rewrite its standards/ links to
# the vendored kit so they resolve in the adopted repo (the docs live in $KIT_REL/standards/).
if [ -e "$TARGET/AGENTS.md" ] && [ "$FORCE" -eq 0 ]; then
  say "skip   AGENTS.md (exists)"
elif [ "$DRY" -eq 1 ]; then
  say "would  AGENTS.md"
else
  cp "$KIT/AGENTS.md" "$TARGET/AGENTS.md"
  sed -i.bak -E "s#\]\(standards/#](${KIT_REL}/standards/#g" "$TARGET/AGENTS.md" && rm -f "$TARGET/AGENTS.md.bak"
  say "place  AGENTS.md (standards links → ${KIT_REL}/standards/)"
fi

# per-tool pointer files — generated single-source, all defer to AGENTS.md (which routes to the
# standards) so Gemini / Cursor / Copilot / opencode pick up the same rules. Nothing to copy by hand.
gen CLAUDE.md <<'EOF'
# CLAUDE.md

This repository follows **touchstone**. The canonical instructions live in [`AGENTS.md`](AGENTS.md)
(it routes to the relevant `standards/` doc) — read it first.

@AGENTS.md
EOF
gen GEMINI.md <<'EOF'
# GEMINI.md

This repository follows **touchstone**. Before writing or reviewing code, **read
[`AGENTS.md`](AGENTS.md)** — the canonical instructions, which route to the relevant standard. Treat
them as mandatory; `AGENTS.md` is the single source of truth and this file only points at it.
EOF
gen .github/copilot-instructions.md <<'EOF'
# GitHub Copilot — touchstone instructions

This repository follows **touchstone**. Before suggesting or editing code, read and follow
[`AGENTS.md`](../AGENTS.md) — the canonical hard rules, which route to the relevant standard.
`AGENTS.md` is the single source of truth.
EOF
gen opencode.json <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "instructions": ["AGENTS.md"]
}
EOF
gen .cursor/rules/touchstone.mdc <<'EOF'
---
description: touchstone engineering standards — hard rules, tooling, and gates for this repo
alwaysApply: true
---

This repository follows **touchstone**. Read and follow [`AGENTS.md`](../../AGENTS.md) — the canonical
hard rules, which route to the relevant standard. It defines the package managers, formatters/
linters, type-checking, CI hardening, and commit hygiene this repo enforces. `AGENTS.md` is the
single source of truth.
EOF

place .editorconfig .editorconfig
place .gitattributes .gitattributes
place templates/pre-commit-config.yaml .pre-commit-config.yaml
place templates/justfile justfile
place templates/dependabot.yml .github/dependabot.yml
place templates/github/CODEOWNERS .github/CODEOWNERS
place templates/github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md
place templates/SECURITY.md SECURITY.md
place templates/github/workflows/ci.yml .github/workflows/ci.yml

STACKS=""
detect() { STACKS="$STACKS $1"; }

# --- per-stack ---
if [ -e "$TARGET/pyproject.toml" ] || [ -e "$TARGET/uv.lock" ]; then
  detect python
  place templates/python-version .python-version
  say "note   merge templates/pyproject-snippet.toml into pyproject.toml"
fi
if [ -e "$TARGET/package.json" ]; then
  detect node
  place templates/biome.json biome.json
  place templates/nvmrc .nvmrc
fi
if [ -e "$TARGET/go.mod" ]; then
  detect go
  place templates/golangci.yml .golangci.yml
fi
if ls "$TARGET"/Dockerfile* >/dev/null 2>&1 || [ -e "$TARGET/Dockerfile" ]; then
  detect docker
  place templates/dockerignore .dockerignore
fi

# keep the machine list (for the TOML marker) separate from the human banner — reusing one var
# word-split the prose "(none detected…)" into the stacks array.
STACKS="$(echo "$STACKS" | xargs || true)"
STACKS_DISPLAY="${STACKS:-(none detected — pass the templates you need manually)}"

# --- opt-in Claude Code agent hooks ---
if [ "$WITH_HOOKS" -eq 1 ]; then
  for h in "$KIT"/hooks/*.sh; do
    [ -e "$h" ] || continue
    dest=".claude/hooks/$(basename "$h")"
    place "hooks/$(basename "$h")" "$dest"
    [ "$DRY" -eq 0 ] && chmod +x "$TARGET/$dest" 2>/dev/null
  done
  # never clobber an existing settings file — place if absent, else tell the user to merge
  if [ -e "$TARGET/.claude/settings.json" ]; then
    say "note   merge templates/claude-settings.json into .claude/settings.json"
  else
    place templates/claude-settings.json .claude/settings.json
  fi
fi

# --- marker (idempotent: don't clobber a user's level/waivers on re-run) ---
if [ "$DRY" -eq 1 ]; then
  say "would  .touchstone.toml"
elif [ -e "$TARGET/.touchstone.toml" ] && [ "$FORCE" -eq 0 ]; then
  # refresh only the pinned version; preserve the user's level/waivers/stacks
  sed -i.bak -E "s/^version = .*/version = \"$VERSION\"/" "$TARGET/.touchstone.toml" && rm -f "$TARGET/.touchstone.toml.bak"
  say "update .touchstone.toml (version → $VERSION; level/waivers preserved)"
else
  cat >"$TARGET/.touchstone.toml" <<EOF
# Tracks which touchstone version/stacks/level this repo adopts. See touchstone/scripts/check-sync.sh.
version = "$VERSION"
stacks = [$(echo "$STACKS" | tr ' ' '\n' | grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)]
level = 1            # maturity level you target (see standards/self-audit.md): 1=Hygiene .. 4=Scale-up
waivers = []         # documented, reviewed exceptions
EOF
  say "place  .touchstone.toml"
fi

cat <<EOF

Detected stacks: $STACKS_DISPLAY

Next:
  1. Fill in the Project block of AGENTS.md (name, description, stack).
  2. Pin GitHub Actions to SHA:  pinact run
  3. Install hooks:  pre-commit install   (and run: pre-commit run --all-files)
  4. Score the repo against standards/self-audit.md and close gaps.
EOF
[ "$WITH_HOOKS" -eq 1 ] && echo "  5. Review .claude/settings.json + .claude/hooks/ (agent hooks run shell on your machine)."
