#!/usr/bin/env bash
# <name> — <one-line purpose>.
#   usage: ./scripts/<name>.sh [--flag ARG]
# <2–3 lines: what it does and any non-obvious choice — e.g. why -e is omitted>.
# See standards/languages/shell.md.
set -euo pipefail
# Aggregating scripts that must report ALL problems use `set -uo pipefail` instead
# (no -e) and collect failures into one exit code — state which, and why, above.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2 # operate from the repo root (drop if not needed)

# --- helpers ---
# err() { echo "FAIL: $*" >&2; fail=1; }

# --- main ---
