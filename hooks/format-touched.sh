#!/usr/bin/env bash
# PostToolUse(Write|Edit|MultiEdit): format the touched file with the standard tool. Never blocks;
# silently skips if the formatter isn't installed. Fail-open (always exit 0).
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

path="$(cat | jq -r '.tool_input.file_path // empty')"
[ -n "$path" ] && [ -f "$path" ] || exit 0

case "$path" in
*.py)
  if command -v ruff >/dev/null 2>&1; then
    ruff format "$path" >/dev/null 2>&1
    ruff check --fix "$path" >/dev/null 2>&1
  fi
  ;;
*.ts | *.tsx | *.js | *.jsx | *.json | *.jsonc)
  command -v biome >/dev/null 2>&1 && biome check --write "$path" >/dev/null 2>&1
  ;;
*.go)
  command -v gofumpt >/dev/null 2>&1 && gofumpt -w "$path" >/dev/null 2>&1
  ;;
esac

exit 0
