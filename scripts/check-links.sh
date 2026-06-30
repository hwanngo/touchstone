#!/usr/bin/env bash
# check-links — verify every relative Markdown link in the repo resolves to a real file.
#   usage: ./scripts/check-links.sh   (no args; scans all *.md outside node_modules)
# External (http/mailto) and pure-anchor links are skipped. Uses `set -uo pipefail` (no -e) so it
# reports ALL broken links, aggregating into one exit code. See standards/languages/shell.md.
set -uo pipefail
broken=0
while IFS= read -r -d '' f; do
  dir=$(dirname "$f")
  # strip fenced code blocks first so code (e.g. Go generics `](...)`) isn't parsed as a link
  links=$(awk 'BEGIN{fence=0} /^[[:space:]]*```/{fence=!fence; next} !fence{print}' "$f" |
    grep -oE '\]\([^)]+\)' | sed -E 's/^\]\(//; s/\)$//')
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    case "$link" in http* | mailto:* | "#"*) continue ;; esac
    case "$link" in *" "*) continue ;; esac # real file paths have no spaces (skips stray inline code)
    target="${link%%#*}"                    # strip #anchor
    [ -z "$target" ] && continue
    if [ ! -e "$dir/$target" ]; then
      echo "BROKEN: $f -> $link"
      broken=1
    fi
  done <<<"$links"
done < <(find . -name '*.md' -not -path './node_modules/*' -print0)

if [ "$broken" -eq 0 ]; then
  echo "All internal links resolve."
else
  echo "Broken internal links found."
  exit 1
fi
