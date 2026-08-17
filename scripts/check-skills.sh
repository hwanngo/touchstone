#!/usr/bin/env bash
# check-skills — audit every skills/*/SKILL.md against the Agent Skills spec + the touchstone
# template: well-formed frontmatter, spec-valid name == dir, a description that is loadable YAML
# and trigger-phrased, license + metadata.version (tracking the repo VERSION), the 'Full standard:'
# / '## Done' spine, language-tagged code fences, a body pointing at a real standards/*.md, every
# *.md pointer resolving TO A FILE INSIDE THE REPO, no leaked '<tag>' scaffolding, and no drift
# markers. Pointers are read from prose only: fenced code blocks, http(s) URLs and markdown link
# labels are display text, not references, and are excluded before tokenising.
#   usage: ./scripts/check-skills.sh   (no args; scans skills/*/SKILL.md)
# Exits 1 when there are no skills to scan: a gate that examined nothing has proved nothing.
# Pure bash + awk/grep (no jq/yq) so CI needs zero install. `set -uo pipefail` (no -e) aggregates
# all failures into one exit code — mirrors scripts/check-links.sh. See standards/languages/shell.md.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# --- scope guard: never certify a repo this gate has not opened ---------------------------------
# This gate scans the repo it LIVES in (the `cd` above), by design: it audits touchstone's own
# skills/standards/docs. Invoked the way an adopter would — `./.touchstone/scripts/check-skills.sh` from a
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
      echo "check-skills: refusing to run — it would report on the wrong repository."
      echo "  This gate always scans the repo it lives in: $_ts_root"
      echo "  That is a vendored touchstone checkout inside: $_ts_host"
      echo "  So a verdict from here describes the KIT's files and never opens yours. A green would mean nothing."
      echo "  check-{agents,evals,links,skill-quality,skills,standards}.sh are touchstone's OWN CI gates, not adopter gates."
      echo "  From a repo that adopted touchstone you want:"
      echo "    ./.touchstone/scripts/check-sync.sh   is my copy of the kit still in sync? (the adopter-facing gate)"
      echo "    just ci                               my own repo's gates"
      echo "  Kit developers: TOUCHSTONE_ALLOW_NESTED=1 if your kit clone merely sits inside another git repo."
    } >&2
    exit 2
  fi
fi

fail=0
seen=""
err() {
  echo "FAIL: $1: $2"
  fail=1
}

# path_escapes_root <path> — true when a repo-root-relative path leaves the repo once its `.` and
# `..` components are resolved lexically (or when it is absolute). The gate's verdict must depend
# only on files this repo owns: a pointer of the form `../design/x.md` used to be tested against the
# repo's PARENT directory, so a checkout whose sibling happened to contain `design/`, `platform/` or
# `languages/` silently green-lit exactly the dead-pointer class this gate exists to catch.
# Lexical, not `realpath`: no symlink resolution, and none is available portably here.
# Kept byte-identical to scripts/check-links.sh's copy — the two gates are standalone files that an
# adopting repo copies individually, so there is no shared lib to hoist it into. Keep them in sync.
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

# true (exit 0) if text on stdin contains an opening ``` fence with no language tag
untagged_fence() {
  awk '/^[[:space:]]*```/ { n++; if (n % 2 == 1 && $0 ~ /^[[:space:]]*```[[:space:]]*$/) found = 1 }
       END { exit found ? 0 : 1 }'
}

shopt -s nullglob
files=(skills/*/SKILL.md)
# A gate that examined nothing has proved nothing. Exiting 0 here let an adopting repo whose
# skills/ never got populated (or got moved) show a green "skills validated" step forever.
[ ${#files[@]} -eq 0 ] && {
  echo "No skills found under $(pwd)/skills — nothing to check."
  exit 1
}

for f in "${files[@]}"; do
  dir=$(basename "$(dirname "$f")")

  # frontmatter must open with --- and have a closing ---
  [ "$(head -1 "$f")" = "---" ] || {
    err "$dir" "missing opening '---' frontmatter"
    continue
  }
  [ "$(grep -cE '^---[[:space:]]*$' "$f")" -ge 2 ] || {
    err "$dir" "frontmatter not closed"
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
    # double-quoted scalar and YAML rejects it. Unwrapping it here used to hide the value from the
    # plain-scalar lint below, so the one shape YAML is strictest about passed silently.
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

  # name: present, == dir, unique
  if [ -z "$name" ]; then err "$dir" "frontmatter has no 'name:'"; fi
  if [ -n "$name" ] && [ "$name" != "$dir" ]; then err "$dir" "name '$name' != directory '$dir'"; fi
  if [ -n "$name" ]; then
    case " $seen " in *" $name "*) err "$dir" "duplicate skill name '$name'" ;; esac
    seen="$seen $name"
  fi

  # description: present, substantial. An explicitly empty value (`description: ""`) is reported as
  # empty rather than as missing — it IS present and well-formed, and telling an author to add a
  # key they can see in front of them sends them looking for the wrong bug.
  if [ -z "$desc_raw" ]; then
    err "$dir" "frontmatter has no 'description:'"
  elif [ -z "$desc" ]; then
    err "$dir" "'description:' is present but empty"
  elif [ ${#desc} -lt 40 ]; then err "$dir" "description too short (${#desc} chars; need >=40)"; fi

  # A YAML plain (unquoted) scalar may contain neither ': ' nor a trailing ':' — the parser reads
  # either as a nested mapping key, and the description then truncates or the whole document fails
  # to load. This is a targeted lint, not a parser: a real YAML parse would mean depending on
  # python3/ruby/yq from a bash gate for one failure class, and this is that one failure class.
  # Quote the value to fix. (`$desc_raw` = `$desc` means no quote pair was stripped above.)
  if [ "$desc_raw" = "$desc" ]; then
    case $desc_raw in
    *": "* | *:) err "$dir" "unquoted 'description:' contains ': ' or ends with ':' (invalid YAML plain scalar) — wrap the value in double quotes" ;;
    esac
  fi

  # name: Agent Skills spec pattern (lowercase, digits, single hyphens) + length <= 64
  if [ -n "$name" ]; then
    printf '%s' "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' || err "$dir" "name '$name' not spec-valid (lowercase/digits/single-hyphen)"
    [ ${#name} -le 64 ] || err "$dir" "name too long (${#name} chars; spec max 64)"
  fi

  # description: trigger-phrased ('Use when …', not a process summary) and within the spec's 1024 cap
  if [ -n "$desc" ]; then
    printf '%s' "$desc" | grep -qiE '^use ' || err "$dir" "description should open with 'Use …' (trigger phrasing, not a summary)"
    [ ${#desc} -le 1024 ] || err "$dir" "description too long (${#desc} chars; spec max 1024)"
  fi

  # Agent Skills spec metadata: license + metadata.version (so a standalone-copied skill self-declares)
  printf '%s\n' "$fm" | grep -qE '^license:' || err "$dir" "frontmatter has no 'license:'"
  printf '%s\n' "$fm" | grep -qE '^[[:space:]]+version:' || err "$dir" "frontmatter has no 'metadata.version:'"

  # metadata.version must track the repo VERSION — stale standalone copies are the failure mode
  ver=$(printf '%s\n' "$fm" | grep -E '^[[:space:]]+version:' | head -1 | sed -E 's/.*version:[[:space:]]*//; s/[[:space:]]*$//')
  if [ -n "$ver" ] && [ -f VERSION ] && [ "$ver" != "$(cat VERSION)" ]; then
    err "$dir" "metadata.version '$ver' != repo VERSION '$(cat VERSION)'"
  fi

  # every fenced code block carries a language tag
  printf '%s\n' "$body" | untagged_fence && err "$dir" "has an untagged code fence (add a language)"

  # template spine — the 'touchstone' router meta-skill is exempt (it has no single canonical doc)
  if [ "$name" != "touchstone" ]; then
    printf '%s\n' "$body" | grep -qE 'Full standards?:' || err "$dir" "missing 'Full standard:' pointer to its standards/*.md doc"
    printf '%s\n' "$body" | grep -qE '^## Done' || err "$dir" "missing the '## Done' closer"
    # the first content section must be '## Always' (load-bearing non-negotiables, uniform across skills)
    first_h2=$(printf '%s\n' "$body" | grep -m1 -E '^## ' | sed -E 's/[[:space:]]*$//')
    [ "$first_h2" = "## Always" ] || err "$dir" "first section must be '## Always' (got '${first_h2:-none}')"
  fi

  # body must reference a real standards/*.md
  printf '%s\n' "$body" | grep -qE 'standards/[A-Za-z0-9/_-]+\.md' || err "$dir" "body references no standards/*.md doc"

  # Every *.md pointer in the body must resolve — from the skill's own directory (the form copied
  # out of standards/, e.g. '../../standards/design/api-design.md') or from the repo root
  # ('standards/x.md'). Failing from BOTH is the real defect: the old check looked only at
  # 'standards/*.md' tokens from the root, so relative and bare pointers were never resolved at all.
  #
  # What is NOT a pointer, and why (each of these used to be one):
  #   * anything inside a fenced code block — a shell example containing `cp template.md out.md`
  #     names files that do not and should not exist. Both markers are tracked independently, as in
  #     check-links.sh, so a ~~~ line shown inside a ``` block cannot close it and swallow the rest
  #     of the body. Inline `code spans` are deliberately NOT stripped: unlike check-links.sh, a
  #     backticked path is this gate's PRIMARY pointer form.
  #   * an http(s) URL — `https://…/GUIDE.md` names a document on someone else's server. Matched by
  #     scheme, not by an `http*` glob, so a relative pointer merely named `http-notes.md` is still
  #     checked.
  #   * a markdown link LABEL — in `[standards/x.md](../../standards/x.md)` only the destination is
  #     a reference; the label is display text that happens to be spelled like a path, and flagging
  #     it forced authors to make their prose resolvable instead of their links correct.
  # Tokens carrying glob/brace metacharacters are documentation patterns ('standards/*.md',
  # 'standards/design/{a,b}.md'), not pointers, so they are skipped. A trailing sentence period or
  # comma is punctuation, not part of the path.
  #
  # KNOWN LIMIT, stated honestly: a bare prose noun ('recorded in CHANGELOG.md by the release
  # process') is still read as a pointer. There is no syntactic difference between that and the bare
  # `resilience.md` pointers this check was extended to catch; the only available discriminator —
  # requiring a '/' — would reopen exactly that hole. Left as-is rather than weakened.
  ptrs=$(printf '%s\n' "$body" | awk '
    BEGIN { fence = "" }
    /^[[:space:]]*```/ { if (fence == "") fence = "b"; else if (fence == "b") fence = ""; next }
    /^[[:space:]]*~~~/ { if (fence == "") fence = "t"; else if (fence == "t") fence = ""; next }
    fence != "" { next }
    { line = $0
      gsub(/https?:\/\/[^[:space:]]+/, " ", line)
      gsub(/\[[^]]*\]\(/, " (", line)
      n = split(line, t, /[^A-Za-z0-9_.,{}*?\/~-]+/)
      for (i = 1; i <= n; i++) { tok = t[i]; sub(/[.,]+$/, "", tok); if (tok ~ /\.md$/) print tok } }' | sort -u)
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case $p in
    *'*'* | *'?'* | *'{'* | *'}'* | *','*) continue ;;
    esac
    # Both candidates are repo-root-relative, and a candidate that leaves the repo is no candidate
    # at all: resolving it would let a file the repo does not own decide the verdict. A checkout
    # whose PARENT happened to contain design/, platform/ or languages/ used to green-light the
    # whole '../<dir>/<file>.md' class — the class this check exists to catch.
    resolved=""
    for cand in "$(dirname "$f")/$p" "$p"; do
      path_escapes_root "$cand" && continue
      if [ -f "$cand" ]; then
        resolved=$cand
        break
      fi
    done
    [ -n "$resolved" ] ||
      err "$dir" "pointer '$p' resolves from neither the skill directory nor the repo root (a path leaving the repo is refused, not resolved)"
  done <<<"$ptrs"

  # leaked generation scaffolding — a bare '<tag>' / '</tag>' line is never skill prose
  stray=$(printf '%s\n' "$body" | grep -E '^</?[a-z_]+>$' | head -1)
  [ -n "$stray" ] && err "$dir" "body contains a stray tag line '$stray' (leaked scaffolding)"

  # no drift markers
  printf '%s\n' "$body" | grep -qE '\b(TODO|FIXME|XXX)\b' && err "$dir" "body contains TODO/FIXME/XXX"
done

if [ "$fail" -eq 0 ]; then
  echo "Validated ${#files[@]} skills."
else
  echo "Skill validation failed."
  exit 1
fi
