#!/usr/bin/env bash
# check-standards — audit EVERY markdown doc under standards/, at any depth, against the touchstone
# doc template: an H1 title, a bare '## Definition of done' closer, numbered '## N.' sections (period
# after the number), language-tagged code fences, no trailing-period headings, and no leaked '<tag>'
# generation scaffolding in prose (fence-aware — see scaffolding_scan). Then report which docs have
# no dedicated skill (routed via the touchstone meta-skill) — informational, not a failure.
#
# Enumeration is `find standards -name '*.md'`, NOT a fixed-depth glob. It used to be
# `files=(standards/*/*.md)`, which could not reach anything sitting directly under standards/:
# standards/README.md and standards/self-audit.md — the kit's flagship 149-item checklist — were
# therefore never validated by anything. A fixed-depth glob makes coverage a silent function of
# directory layout; find plus the "Examined N" line below makes it a stated, checkable number.
#
# Index READMEs and self-audit.md are an index and a scoring checklist, so a '## Definition of done'
# closer is genuinely wrong for them. They are exempt from THAT ONE RULE ONLY (see is_index_doc) and
# are still counted and still checked against every other rule — an explicit, reported exemption
# rather than an accident of glob depth.
#   usage: ./scripts/check-standards.sh   (no args; scans standards/**.md at every depth)
# Pure bash + awk/grep (no jq/yq) so CI needs zero install. `set -uo pipefail` (no -e) aggregates
# every failure into one exit code — mirrors scripts/check-skills.sh. See standards/languages/shell.md.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# --- scope guard: never certify a repo this gate has not opened ---------------------------------
# This gate scans the repo it LIVES in (the `cd` above), by design: it audits touchstone's own
# skills/standards/docs. Invoked the way an adopter would — `./.touchstone/scripts/check-standards.sh` from a
# consuming repo — it therefore walks the vendored kit and prints a confident green about files that
# are not the caller's. That is worse than having no gate, so refuse instead of passing.
#
# The test is POSITIONAL, never identity. "Am I the real touchstone repo?" would also refuse inside
# every temp fixture tree that tests/gates/*.test.sh builds by copying this script into one, taking
# hundreds of rows red for the wrong reason. A vendored copy inside a host repo is recognised by its
# own root being named `.touchstone`, or by that root sitting inside ANOTHER git work tree; a plain
# clone and a fixture tree match neither. TOUCHSTONE_ALLOW_NESTED=1 overrides, for the one honest
# case the second test cannot distinguish: a kit clone that merely sits inside an unrelated repo.
if [ "${TOUCHSTONE_ALLOW_NESTED:-0}" != "1" ]; then
  _ts_root="$(pwd -P)"
  _ts_base="$(basename "$_ts_root")"
  _ts_up="$(dirname "$_ts_root")"
  _ts_host=""
  case "$_ts_base" in
  .touchstone) _ts_host="$_ts_up" ;;
  esac
  if [ -z "$_ts_host" ]; then
    _ts_host="$(git -C "$_ts_up" rev-parse --show-toplevel 2>/dev/null)" || _ts_host=""
  fi
  if [ -n "$_ts_host" ]; then
    {
      echo "check-standards: refusing to run — it would report on the wrong repository."
      echo "  This gate always scans the repo it lives in: $_ts_root"
      echo "  That is a vendored touchstone checkout inside: $_ts_host"
      echo "  So a verdict from here describes the KIT's files and never opens yours. A green would mean nothing."
      echo "  check-{agents,links,skill-quality,skills,standards}.sh are touchstone's OWN CI gates, not adopter gates."
      echo "  From a repo that adopted touchstone you want:"
      echo "    ./.touchstone/scripts/check-sync.sh   is my copy of the kit still in sync? (the adopter-facing gate)"
      echo "    just ci                               my own repo's gates"
      echo "  Kit developers: TOUCHSTONE_ALLOW_NESTED=1 if your kit clone merely sits inside another git repo."
    } >&2
    exit 2
  fi
fi

fail=0
err() {
  echo "FAIL: $1: $2"
  fail=1
}

# true (exit 0) if text on stdin contains an opening ``` fence with no language tag
untagged_fence() {
  awk '/^[[:space:]]*```/ { n++; if (n % 2 == 1 && $0 ~ /^[[:space:]]*```[[:space:]]*$/) found = 1 }
       END { exit found ? 0 : 1 }'
}

# scaffolding_scan <file> — prints exactly one line, "<prose-line-count>|<finding-or-empty>".
#
# The finding is the first bare '<tag>' / '</tag>' line that survives fence stripping. Generation
# scaffolding has leaked into a committed doc before — standards/platform/terraform.md ended with
# a stray closing 'content' and 'invoke' tag pair, outside any fence — and commit 9e700f1 added
# the same rule to check-skills.sh without covering standards/. A bare tag on its own line is
# never standards prose.
#
# It IS ordinary content inside a fence: the closing 'script' tag appears in the Svelte, Vue and
# Nuxt single-file-component examples and the landmark elements in practices/accessibility.md, so
# a fence-blind '^</?[a-z]+>$' takes the build red on four legitimate files. Fences are therefore
# stripped first, and the two markers are tracked INDEPENDENTLY — a fence closes only on the
# marker type that opened it, so a '~~~' line shown inside a backtick block cannot close it. The
# shared-toggle version of this is the bug check-links.sh already hit; see strip_code() there.
#
# The prose-line count is returned alongside so the caller can report it and refuse to pass a run
# in which this rule read nothing: a fence-stripping bug that swallowed every file would otherwise
# look identical to a clean tree.
scaffolding_scan() {
  awk '
    BEGIN { fence = ""; n = 0; hit = "" }
    /^[[:space:]]*```/ { if (fence == "") fence = "`"; else if (fence == "`") fence = ""; next }
    /^[[:space:]]*~~~/ { if (fence == "") fence = "~"; else if (fence == "~") fence = ""; next }
    fence != "" { next }
    { n++ }
    hit == "" && /^[[:space:]]*<\/?[A-Za-z][A-Za-z0-9_:-]*>[[:space:]]*$/ { hit = "line " NR ": " $0 }
    END { print n "|" hit }
  ' "$1"
}

# is_index_doc <standards-relative-path> — true for the docs whose shape is legitimately not the
# standards-doc template. Deliberately a closed list, not a pattern that could widen by accident:
# a directory index (README.md, at any depth) and the scoring checklist (self-audit.md).
is_index_doc() {
  case "$1" in
  README.md | */README.md | self-audit.md) return 0 ;;
  esac
  return 1
}

# Collect the standards docs every skill points at, so we can flag docs with no dedicated skill.
# Guarded by an explicit file list: with nullglob set and no skills/ present, `grep -hoE PAT
# skills/*/SKILL.md` would get zero file operands and block reading stdin.
shopt -s nullglob
skill_files=(skills/*/SKILL.md)
skill_refs=""
if [ ${#skill_files[@]} -gt 0 ]; then
  skill_refs=$(grep -hoE 'standards/[A-Za-z0-9/_-]+\.md' "${skill_files[@]}" 2>/dev/null | LC_ALL=C sort -u)
fi

examined=0
exempt=0
prose_lines=0
orphans=""
# Loop body must run in THIS shell (the counters above are read after it), hence the process
# substitution rather than `find ... | while read`.
while IFS= read -r f; do
  rel="${f#standards/}"
  examined=$((examined + 1))

  # 1. H1 title on the first line
  head -1 "$f" | grep -qE '^# ' || err "$rel" "first line is not an H1 title"

  # 2. a bare '## Definition of done' closer (the doc's enforceable gate list) — every doc except
  #    the indexes and the checklist, whose shape has no such closer by design
  if is_index_doc "$rel"; then
    exempt=$((exempt + 1))
  else
    grep -qE '^## Definition of done[[:space:]]*$' "$f" || err "$rel" "missing a bare '## Definition of done' section"
  fi

  # 3. numbered section headings carry the period — no '## 3 Title'
  grep -qE '^## [0-9]+ ' "$f" && err "$rel" "numbered heading without a period (use '## N. Title')"

  # 4. no heading whose text ends in a period
  grep -qE '^#{1,6} .*[^.]\.$' "$f" && err "$rel" "a heading ends in a period (drop it)"

  # 5. every fenced code block carries a language tag
  untagged_fence <"$f" && err "$rel" "has an untagged code fence (add a language)"
  # (no drift-marker check here: standards docs legitimately discuss "TODO"/"FIXME" in prose —
  #  that gate lives in check-skills.sh, where bodies are terse AI instructions.)

  # 6. no leaked generation scaffolding: a bare tag line in prose, outside every code fence
  scan=$(scaffolding_scan "$f")
  prose_lines=$((prose_lines + ${scan%%|*}))
  hit=${scan#*|}
  [ -n "$hit" ] && err "$rel" "leaked generation scaffolding at $hit (a bare tag line outside any code fence is never standards prose)"

  # coverage (informational): does any skill point at this doc? Directory indexes are not routed to
  # by a skill and never will be, so they are not candidates for the orphan report.
  case "$rel" in
  README.md | */README.md) ;;
  *) printf '%s\n' "$skill_refs" | grep -qxF "$f" || orphans="$orphans $rel" ;;
  esac
done < <(find standards -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

# Vacuity guard: a gate that enumerated nothing has proved nothing. This is the failure the old
# fixed-depth glob made invisible, so it must never be reported as a pass.
if [ "$examined" -eq 0 ]; then
  echo "FAIL: standards/: no markdown docs found under standards/ — a gate that examines nothing cannot pass" >&2
  exit 1
fi

# Printed on BOTH the pass and the fail path: a future change that shrinks coverage shows up as a
# smaller number rather than as silence.
echo "Examined $examined markdown doc(s) under standards/ ($exempt exempt from the 'Definition of done' rule)."
echo "Scanned $prose_lines prose line(s) (fenced code stripped) for leaked generation scaffolding."

# Second vacuity guard, for the one rule whose input is a SUBSET of the files: docs were examined,
# but if fence stripping left zero prose lines then the scaffolding rule read nothing and its
# silence means nothing. Unreachable from a valid standards tree — an H1 and a 'Definition of
# done' closer are both prose — which is precisely why it must be asserted rather than assumed.
if [ "$prose_lines" -eq 0 ]; then
  err "standards/" "every examined line was inside a code fence — the leaked-scaffolding rule scanned no prose"
fi

if [ -n "$orphans" ]; then
  echo "note: docs with no dedicated skill (reachable via the touchstone router):"
  for o in $orphans; do echo "  - $o"; done
fi

if [ "$fail" -eq 0 ]; then
  echo "Validated $examined standards docs."
else
  echo "Standards validation failed."
  exit 1
fi
