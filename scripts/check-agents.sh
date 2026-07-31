#!/usr/bin/env bash
# check-agents — audit every agents/*.md subagent definition against the Claude Code subagent
# format: well-formed frontmatter, `name` matching the filename, a `description` that is loadable
# YAML and trigger-phrased, well-formed optional `tools:`/`model:`, a system prompt body that
# actually exists and routes to a real standards/*.md doc, every *.md pointer resolving TO A FILE
# INSIDE THE REPO, and no drift markers. Pointers are read from prose only: fenced code blocks,
# http(s) URLs and markdown link labels are display text, not references.
#   usage: ./scripts/check-agents.sh   (no args; scans agents/*.md)
#
# agents/README.md is the one file here that is not a subagent definition (it is the directory's
# index, the same role hooks/README.md plays for hooks/), so it is skipped BY NAME and everything
# else in the directory must be a definition. The skip cannot hide an empty run: zero definitions
# examined exits 1, so a directory holding only a README fails exactly like an empty one.
#
# Exits 1 when there are no agents to scan: a gate that examined nothing has proved nothing. That
# is not hypothetical here — this kit shipped skills, standards and links gates that each certified
# an empty set as success before they were rewritten.
#
# Why this is a lint and not a YAML parse: a bash gate must not depend on python3/ruby/yq, which is
# the whole reason CI needs zero install. The one YAML failure class that actually shipped in this
# repo — an unquoted plain scalar containing ': ' — is therefore checked directly. See the
# description block below, and scripts/check-skills.sh, which learned it first.
#
# Pure bash + awk/grep (no jq/yq). `set -uo pipefail` (no -e) aggregates all failures into one exit
# code — mirrors scripts/check-skills.sh. See standards/languages/shell.md.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# --- scope guard: never certify a repo this gate has not opened ---------------------------------
# This gate scans the repo it LIVES in (the `cd` above), by design: it audits touchstone's own
# skills/standards/docs. Invoked the way an adopter would — `./.touchstone/scripts/check-agents.sh` from a
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
      echo "check-agents: refusing to run — it would report on the wrong repository."
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

# Preflight: the frontmatter/body split and the pointer tokeniser both run in awk, inside command
# substitutions whose failure is invisible to the caller. With awk broken the tokeniser returns
# empty and this gate certifies a prompt it never read — the silent-disable failure class
# scripts/check-links.sh was rewritten to close. Checked by behaviour, not by `command -v`: an awk
# on PATH that runs and produces wrong output is exactly the case a presence check misses.
if [ "$(printf 'x\n' | LC_ALL=C awk '{ print $0 "!" }' 2>/dev/null)" != "x!" ]; then
  echo "check-agents: awk is missing or not functional — refusing to certify definitions it cannot read." >&2
  exit 2
fi

fail=0
seen=""
err() {
  echo "FAIL: $1: $2"
  fail=1
}

# path_escapes_root <path> — true when a repo-root-relative path leaves the repo once its `.` and
# `..` components are resolved lexically (or when it is absolute). The gate's verdict must depend
# only on files this repo owns: a pointer of the form `../design/x.md` tested against the repo's
# PARENT directory means a checkout whose sibling happens to contain `design/` silently green-lights
# exactly the dead-pointer class this gate exists to catch.
# Lexical, not `realpath`: no symlink resolution, and none is available portably here.
# Kept byte-identical to scripts/check-skills.sh's and scripts/check-links.sh's copies — the gates
# are standalone files that an adopting repo copies individually, so there is no shared lib to hoist
# it into. Keep them in sync.
path_escapes_root() {
  local rest="$1" comp depth=0
  case "$rest" in
  /*) return 0 ;;
  esac
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$comp" in
    "" | ".") continue ;;
    "..")
      depth=$((depth - 1))
      if [ "$depth" -lt 0 ]; then return 0; fi
      ;;
    *) depth=$((depth + 1)) ;;
    esac
  done
  return 1
}

# tools_is_sequence — true when the `tools:` key whose scalar is empty is followed by a YAML block
# sequence ("  - Read"). Both spellings are valid YAML for the same list, and rejecting the block
# form would fail a definition that loads correctly.
tools_is_sequence() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    /^tools:/ { f = 1; next }
    f { if ($0 ~ /^[[:space:]]+-[[:space:]]*[^[:space:]]/) found = 1; exit }
    END { exit found ? 0 : 1 }'
}

shopt -s nullglob
files=()
for f in agents/*.md; do
  if [ "$f" = "agents/README.md" ]; then continue; fi
  files+=("$f")
done

# A gate that examined nothing has proved nothing.
if [ ${#files[@]} -eq 0 ]; then
  echo "No agent definitions found under $(pwd)/agents — nothing to check."
  exit 1
fi

for f in "${files[@]}"; do
  id=$(basename "$f" .md)

  # frontmatter must open with --- and have a closing ---
  [ "$(head -1 "$f")" = "---" ] || {
    err "$id" "missing opening '---' frontmatter"
    continue
  }
  [ "$(grep -cE '^---[[:space:]]*$' "$f")" -ge 2 ] || {
    err "$id" "frontmatter not closed"
    continue
  }

  fm=$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$f")
  body=$(awk '/^---[[:space:]]*$/{c++; next} c>=2{print}' "$f")

  name=$(printf '%s\n' "$fm" | grep -E '^name:' | head -1 | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//')
  desc=$(printf '%s\n' "$fm" | grep -E '^description:' | head -1 | sed -E 's/^description:[[:space:]]*//; s/[[:space:]]*$//')

  # Unwrap a surrounding quote pair BEFORE anything reads the value. Order is load-bearing: the
  # trigger check below is a '^use ' match, so judging the raw text would reject '"Use when …"' —
  # i.e. reject the quoting that is the only correct fix for a description containing ': '.
  desc_raw=$desc
  case $desc in
  '"'*'"')
    # A backslash-escaped terminator is not a closing quote: `"… breaks.\"` is an UNTERMINATED
    # double-quoted scalar and YAML rejects it. Unwrapping it here would hide the value from the
    # plain-scalar lint below, so the one shape YAML is strictest about would pass silently.
    case $desc in
    *'\"') ;;
    *)
      desc=${desc#\"}
      desc=${desc%\"}
      ;;
    esac
    ;;
  "'"*"'")
    desc=${desc#\'}
    desc=${desc%\'}
    ;;
  esac

  # name: present, == filename, unique. Claude Code resolves a subagent by the frontmatter `name`
  # while humans find it by filename, so a mismatch means the file everyone edits is not the agent
  # that runs.
  if [ -z "$name" ]; then err "$id" "frontmatter has no 'name:'"; fi
  if [ -n "$name" ] && [ "$name" != "$id" ]; then err "$id" "name '$name' != filename '$id'"; fi
  if [ -n "$name" ]; then
    case " $seen " in *" $name "*) err "$id" "duplicate agent name '$name'" ;; esac
    seen="$seen $name"
    printf '%s' "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' || err "$id" "name '$name' not spec-valid (lowercase/digits/single-hyphen)"
    [ ${#name} -le 64 ] || err "$id" "name too long (${#name} chars; max 64)"
  fi

  # description: present, substantial. An explicitly empty value (`description: ""`) is reported as
  # empty rather than as missing — it IS present and well-formed, and telling an author to add a
  # key they can see in front of them sends them looking for the wrong bug.
  if [ -z "$desc_raw" ]; then
    err "$id" "frontmatter has no 'description:'"
  elif [ -z "$desc" ]; then
    err "$id" "'description:' is present but empty"
  elif [ ${#desc} -lt 40 ]; then err "$id" "description too short (${#desc} chars; need >=40)"; fi

  # A YAML plain (unquoted) scalar may contain neither ': ' nor a trailing ':' — the parser reads
  # either as a nested mapping key, and the description then truncates or the whole document fails
  # to load. Twelve of this repo's skills shipped in exactly that state. Quote the value to fix.
  # (`$desc_raw` = `$desc` means no quote pair was stripped above.)
  if [ "$desc_raw" = "$desc" ]; then
    case $desc_raw in
    *": "* | *:) err "$id" "unquoted 'description:' contains ': ' or ends with ':' (invalid YAML plain scalar) — wrap the value in double quotes" ;;
    esac
  fi

  # description: this is the ROUTING TEXT the calling agent matches on, not a summary for humans.
  # Trigger phrasing ('Use when …') is what makes delegation fire at the right moment.
  if [ -n "$desc" ]; then
    printf '%s' "$desc" | grep -qiE '^use ' || err "$id" "description should open with 'Use …' (trigger phrasing, not a summary)"
    [ ${#desc} -le 1024 ] || err "$id" "description too long (${#desc} chars; max 1024)"
  fi

  # tools: OPTIONAL — omitting it inherits every tool. Present-but-empty is not "inherit": it is an
  # empty allowlist, i.e. an agent that can do nothing, and it is a typo away from either intent.
  if printf '%s\n' "$fm" | grep -qE '^tools:'; then
    tools_val=$(printf '%s\n' "$fm" | grep -E '^tools:' | head -1 | sed -E 's/^tools:[[:space:]]*//; s/[[:space:]]*$//')
    if [ -z "$tools_val" ] && ! tools_is_sequence "$fm"; then
      err "$id" "'tools:' is present but empty (an agent with no tools can do nothing) — omit the key to inherit every tool"
    fi
  fi

  # model: OPTIONAL — omitting it inherits the caller's model. Checked for SHAPE only: one token.
  # The set of legal aliases is deliberately NOT pinned here. A hardcoded enum is precisely the kind
  # of claim that went stale in standards/ unnoticed, and a gate that rejects a model alias newer
  # than itself blocks the correct definition.
  if printf '%s\n' "$fm" | grep -qE '^model:'; then
    model_val=$(printf '%s\n' "$fm" | grep -E '^model:' | head -1 | sed -E 's/^model:[[:space:]]*//; s/[[:space:]]*$//')
    if [ -z "$model_val" ]; then
      err "$id" "'model:' is present but empty — omit the key to inherit the caller's model"
    else
      case $model_val in
      *[[:space:]]*) err "$id" "'model:' must be a single token (got '$model_val')" ;;
      esac
    fi
  fi

  # The body IS the system prompt. Frontmatter with nothing under it is a stub that exists to
  # satisfy a checker — the exact shape this gate must never certify.
  if [ -z "$(printf '%s\n' "$body" | tr -d '[:space:]')" ]; then
    err "$id" "has no system prompt body (frontmatter only)"
  fi

  # An agent that names no standards doc restates the standards instead of routing to them, and a
  # restatement is a second copy that drifts from the first. Same rule check-skills.sh applies to
  # every SKILL.md.
  printf '%s\n' "$body" | grep -qE 'standards/[A-Za-z0-9/_-]+\.md' ||
    err "$id" "body references no standards/*.md doc (an agent that routes nowhere restates instead)"

  # Every *.md pointer in the body must resolve — from the agent file's own directory or from the
  # repo root. Tokenised exactly as scripts/check-skills.sh does, and for the same reasons:
  #   * anything inside a fenced code block is an EXAMPLE, not a reference. Both fence markers are
  #     tracked independently, so a ~~~ line shown inside a ``` block cannot close it and swallow
  #     the rest of the body. Inline `code spans` are deliberately NOT stripped: a backticked path
  #     is this gate's primary pointer form.
  #   * an http(s) URL names a document on someone else's server. Matched by scheme, not by an
  #     `http*` glob, so a relative pointer merely named `http-notes.md` is still checked.
  #   * a markdown link LABEL is display text; only the destination is a reference.
  # Tokens carrying glob/brace metacharacters are documentation patterns ('standards/*.md'), not
  # pointers. A trailing sentence period or comma is punctuation, not part of the path.
  ptrs=$(printf '%s\n' "$body" | LC_ALL=C awk '
    BEGIN { fence = "" }
    /^[[:space:]]*```/ { if (fence == "") fence = "b"; else if (fence == "b") fence = ""; next }
    /^[[:space:]]*~~~/ { if (fence == "") fence = "t"; else if (fence == "t") fence = ""; next }
    fence != "" { next }
    { line = $0
      gsub(/https?:\/\/[^[:space:]]+/, " ", line)
      gsub(/\[[^]]*\]\(/, " (", line)
      n = split(line, t, /[^A-Za-z0-9_.,{}*?\/~-]+/)
      for (i = 1; i <= n; i++) { tok = t[i]; sub(/[.,]+$/, "", tok); if (tok ~ /\.md$/) print tok } }' | LC_ALL=C sort -u)
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case $p in
    *'*'* | *'?'* | *'{'* | *'}'* | *','*) continue ;;
    esac
    # Both candidates are repo-root-relative, and a candidate that leaves the repo is no candidate
    # at all: resolving it would let a file the repo does not own decide the verdict.
    resolved=""
    for cand in "$(dirname "$f")/$p" "$p"; do
      path_escapes_root "$cand" && continue
      if [ -f "$cand" ]; then
        resolved=$cand
        break
      fi
    done
    [ -n "$resolved" ] ||
      err "$id" "pointer '$p' resolves from neither the agent directory nor the repo root (a path leaving the repo is refused, not resolved)"
  done <<<"$ptrs"

  # no drift markers — an unresolved note in a system prompt is an instruction the agent will read
  printf '%s\n' "$body" | grep -qE '\b(TODO|FIXME|XXX)\b' && err "$id" "body contains TODO/FIXME/XXX"
done

if [ "$fail" -eq 0 ]; then
  echo "Validated ${#files[@]} agents."
else
  echo "Agent validation failed."
  exit 1
fi
