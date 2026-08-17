#!/usr/bin/env bash
# check-links — verify every internal Markdown link in the repo resolves, and (best-effort) that
# every `<file>.md §N` cross-reference names a section that exists.
#   usage: ./scripts/check-links.sh   (no args; always scans the repo this script lives in,
#           regardless of the caller's cwd — see the `cd` below)
#
# Link checks: a target must exist on disk (relative to the citing file's directory). A `#anchor`
# fragment (on a same-file `#foo` link or a `file.md#foo` link) must match a real heading in the
# target, using GitHub slug rules: lowercase, punctuation stripped, spaces to hyphens, duplicate
# headings get a `-1`, `-2`, ... counter suffix. `http(s)://` and `mailto:` targets are skipped by
# scheme match (not a `http*` glob, which used to also skip a *relative* link merely named
# "http...md"). A trailing `"title"` suffix is stripped rather than the whole link being skipped
# for containing a space, which used to hide genuinely broken links with an escaped/encoded space
# in the path. Reference-style definitions (`[label]: target "title"`) are parsed too.
#
# Code is stripped before parsing, so an example of link syntax is never treated as a real link:
# fenced blocks (both ``` and ~~~), indented (4-space) code blocks, and inline `code spans`. See
# BLOCK_AWK below for the two properties that stripping has to get right — independent fence
# markers, and container-relative fence indentation. A file that ends inside an unclosed fence is
# reported, not silently truncated.
#
# Destinations, by form:
#   - `../../elsewhere.md` — a link or §N token that climbs out of the scanned tree is REPORTED
#     (OUT-OF-REPO / could-not-resolve), never resolved: the gate's verdict must not depend on
#     files the repo does not own. Lexical containment only; see path_escapes_root.
#   - `/standards/x.md` — a root-absolute link destination is resolved against the SCAN ROOT, the
#     way GitHub renders root-relative links, so the verdict does not depend on which directory
#     the citing file happens to sit in. It previously resolved by accident from a file at the
#     repo root (`.//standards/x.md`) and was falsely BROKEN from anywhere else.
#   - `//example.com/x` — a protocol-relative URL is external and skipped, like `https://`.
#   - A bare `/etc/doc.md` in a prose §N token is a filesystem path, not a link destination, and is
#     still refused by path_escapes_root rather than resolved.
#
# `.git` and `.touchstone` are excluded so an adopted repo does not rescan its vendored kit
# submodule; `tests/fixtures/` is excluded because it deliberately contains broken-link fixtures
# for tests/gates/check-links.test.sh; `evals/cases/*/repo/` is excluded for the same reason —
# every case's fixture repo deliberately reproduces a real defect, and "fixing" it to satisfy this
# gate would mean it no longer reproduces the defect it exists to catch (see evals/README.md);
# `.superpowers/` is excluded to match `.markdownlint-cli2.jsonc` — it is git-ignored agent
# scratch, and prose written there *about* this gate (naming a fixture file, quoting link syntax)
# otherwise turns the gate red.
#
# LIMITATION, stated honestly: heading slugs are computed from prose that has already had its
# inline `code spans` removed — the same stripping the link parser needs so that example link
# syntax is not parsed as a real link. GitHub instead keeps the code span's text when it slugs a
# heading, so a heading whose text is *only* a code span, e.g. `## \`net/http\``, slugs differently
# here than on GitHub. No anchor in this repo currently targets such a heading; a link that started
# doing so could false-positive here, and fixing it properly means splitting the two stripping
# passes apart.
#
# Section-reference check: for each prose `<file>.md §N`, resolve file.md and require a `## N.`
# heading. LIMITATION, stated honestly: this is an IN-RANGE check only — it confirms the number
# exists as a heading, not that it is the section the author meant. A reference can be in-range
# and still point at the wrong topic. Closing that fully needs anchor-linked references instead of
# bare numbers; deferred to the content spec.
#
# A markdown tree with zero .md files is a failure, not a vacuous pass — see standards/languages/
# shell.md and the gate-hardening audit this script was rewritten under.
# Uses `set -uo pipefail` (no -e) so it reports ALL broken links/refs, aggregating into one exit
# code. See standards/languages/shell.md.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# --- scope guard: never certify a repo this gate has not opened ---------------------------------
# This gate scans the repo it LIVES in (the `cd` above), by design: it audits touchstone's own
# skills/standards/docs. Invoked the way an adopter would — `./.touchstone/scripts/check-links.sh` from a
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
      echo "check-links: refusing to run — it would report on the wrong repository."
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

# Preflight: this gate does ALL of its scanning in awk, and every awk call sits inside a pipeline or
# a command substitution whose failure is invisible to the caller. With awk broken or missing, every
# scan returned empty, the gate reported "nothing was verified" — and still exited 0. A gate that
# certifies a tree it never read is worse than no gate, so refuse to run instead.
#
# Checked by behaviour, not by `command -v`: an awk on PATH that produces wrong output is exactly the
# case that made this necessary. Uses the same LC_ALL=C pin as the real calls, so a locale that
# breaks awk is caught here too.
if [ "$(printf 'x\n' | LC_ALL=C awk '{ print $0 "!" }' 2>/dev/null)" != "x!" ]; then
  echo "check-links: awk is missing or not functional — refusing to certify a tree it cannot read." >&2
  exit 2
fi

broken=0
ALL_MD=()
# What was actually examined. The final report claims success only for the categories whose count
# is non-zero: a tree with no links and no §N references used to print both "All internal links
# resolve." and "All §N section references are in range.", each of which asserts a property of an
# empty set.
links_checked=0
anchors_checked=0
refs_checked=0

# LINK_TITLE_RE — a CommonMark link title in each of its three forms: "double-quoted",
# 'single-quoted' and (parenthesised). Used both to strip a title off a destination and to
# recognise a well-formed reference definition. The single quote is spliced in from a variable
# because the whole pattern is carried in a double-quoted shell string.
SQ="'"
LINK_TITLE_RE="(\"[^\"]*\"|${SQ}[^${SQ}]*${SQ}|\\([^)]*\\))"

# ---- shared parsing helpers -----------------------------------------------------------------

# path_escapes_root <path> — true when a scan-root-relative path leaves the scanned tree once its
# `.` and `..` components are resolved lexically (or when it is absolute). The gate's verdict must
# depend only on files the repo owns: a link or §N token of the form `../../elsewhere.md` used to
# resolve silently against a file above the scan root, so a reference could be declared good on the
# strength of a file that is not in the repo, and an out-of-tree path could appear in the gate's
# output. Lexical, not `realpath`: no symlink resolution, and none is available portably here.
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

# BLOCK_AWK — the block-structure state machine, shared verbatim by all three awk passes below
# (strip_code, fence_unclosed, section_refs). It used to be copy-pasted into each of them under a
# "keep them in sync" comment; one string removes the drift hazard, and means one mutation of this
# logic is visible to every test that exercises any of the three.
#
# blk(<line>) advances the state and classifies the line:
#   "c" — code: a fence marker, a line inside a fenced block, or a line of an indented code block.
#   "b" — blank.
#   "t" — prose.
#
# Two properties it has to get right, both learned from real defects:
#
#  1. The two fence markers are tracked INDEPENDENTLY. `fence` holds the marker character that
#     OPENED the current block ("" when outside one) and only that same marker can close it. A
#     single shared boolean (the original shape) let a ~~~ line shown *inside* a ``` block flip the
#     state, after which the whole rest of the file was dropped — every link past that point
#     silently unchecked, gate still exit 0. That is the vacuity class this gate exists to
#     eliminate, at file granularity.
#
#  2. A fence marker is only a fence within 3 spaces of its CONTAINER's content column, per
#     CommonMark. Beyond that the line is an indented code block, not a fence: a doc showing a
#     literal ```bash inside a 4-space sample block used to be read as an opener, producing a false
#     UNCLOSED-FENCE and dropping the rest of the file from the scan. The container column is what
#     makes this safe — a fence nested in a list item is legitimately indented, so `listind` tracks
#     the innermost list item's content column and `    ``` ` under `1. ` stays a fence. Indented
#     code is classified "c" rather than merely "not a fence", so an over-indented sample block's
#     contents are still never parsed as real links.
#
# strip_spans(<line>) removes inline code spans by CommonMark's rule: a span opened by a run of N
# backticks is closed by the next run of EXACTLY N, which is how a span carries a backtick of its
# own. This was previously `sed -E 's/`[^`]*`//g'`, which pairs backticks left to right: given
# ``[x](missing.md)``, it deleted the two opening backticks as an empty span and the two closing
# ones as another, leaving the sample link behind as prose and inventing a broken link. The
# obvious sed repair needs a backreference, and BSD `sed -E` silently matches nothing rather than
# erroring on `\1` in a pattern, so a prior round rightly declined to ship it; with the awk pass
# now shared, run-length matching goes here instead. A run with no matching closer is literal text
# and is kept, as it was before. Spans are matched within a line, as the sed was.
#
# shellcheck disable=SC2016 # the backticks below are awk's fence marker, not a `cmd` substitution;
# nothing in this string is meant to expand — single quotes are the point
BLOCK_AWK='
function ind_of(s,   i, n, c, w) {
  w = 0
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == " ") w++
    else if (c == "\t") w += 4
    else break
  }
  return w
}
function blk(line,   ind, base) {
  ind = ind_of(line)
  if (fence != "") {
    if (line ~ /^[[:space:]]*```/ && fence == "`") fence = ""
    else if (line ~ /^[[:space:]]*~~~/ && fence == "~") fence = ""
    return "c"
  }
  if (line ~ /^[[:space:]]*$/) { pblank = 1; return "b" }
  base = listind
  if (ind >= base + 4 && (pblank || indcode)) { pblank = 0; indcode = 1; return "c" }
  pblank = 0
  indcode = 0
  if (listind > 0 && ind < listind) listind = 0
  if (match(line, /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/)) {
    listind = RLENGTH
    base = listind
  }
  if (ind <= base + 3) {
    if (line ~ /^[[:space:]]*```/) { fence = "`"; return "c" }
    if (line ~ /^[[:space:]]*~~~/) { fence = "~"; return "c" }
  }
  return "t"
}
function strip_spans(s,   out, i, n, c, run, j, run2, endpos) {
  out = ""
  i = 1
  n = length(s)
  while (i <= n) {
    c = substr(s, i, 1)
    if (c != "`") { out = out c; i++; continue }
    run = 0
    while (i + run <= n && substr(s, i + run, 1) == "`") run++
    j = i + run
    endpos = 0
    while (j <= n) {
      if (substr(s, j, 1) != "`") { j++; continue }
      run2 = 0
      while (j + run2 <= n && substr(s, j + run2, 1) == "`") run2++
      if (run2 == run) { endpos = j + run2; break }
      j += run2
    }
    if (endpos) i = endpos
    else { out = out substr(s, i, run); i += run }
  }
  return out
}
BEGIN { fence = ""; listind = 0; pblank = 1; indcode = 0 }
'

# strip_code — reads a file on stdin, drops code blocks (fenced and indented) and inline
# `code spans`, prints the remaining prose.
strip_code() {
  LC_ALL=C awk "$BLOCK_AWK"'
    { if (blk($0) != "c") print strip_spans($0) }
  '
}

# fence_unclosed <file> — true when <file> ends inside a fenced block that was never closed.
# strip_code drops everything after such a marker, so without this check the tail of the file is
# never parsed and the gate still passes. Independent marker tracking (BLOCK_AWK property 1)
# removes the most common cause of a stray toggle; this reports whatever causes remain instead of
# swallowing them.
fence_unclosed() {
  LC_ALL=C awk "$BLOCK_AWK"'
    { blk($0) }
    END { exit (fence == "" ? 1 : 0) }
  ' "$1"
}

# heading_slugs <file> — prints the GitHub slug of every heading in <file>, in document order,
# with duplicate-heading counter suffixes (-1, -2, ...).
heading_slugs() {
  strip_code <"$1" | LC_ALL=C awk '
    /^#{1,6}[[:space:]]/ {
      line = $0
      sub(/^#+[[:space:]]+/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      slug = tolower(line)
      gsub(/[^a-z0-9 _-]/, "", slug)
      gsub(/[[:space:]]+/, "-", slug)
      if (slug in seen) { seen[slug]++; print slug "-" (seen[slug] - 1) }
      else { seen[slug] = 1; print slug }
    }
  '
}

# anchor_exists <file> <anchor> — true when <anchor> matches one of <file>'s heading slugs.
# Deliberately NOT `heading_slugs "$1" | grep -qxF "$2"`: `grep -q` exits the instant it matches,
# the upstream awk then takes SIGPIPE and exits 141, and `set -o pipefail` promotes that 141 to the
# pipeline's status — so a genuinely VALID anchor in a file with enough headings (the threshold is
# between 500 and 1000 here) was reported BROKEN-ANCHOR. That is the "never take an exit status
# through a pipeline" rule in its pipefail variant. Materialise the slugs first, then feed grep a
# heredoc, so no pipe exists for grep to close early.
anchor_exists() {
  local slugs
  slugs="$(heading_slugs "$1")"
  grep -qxF -- "$2" <<EOF
$slugs
EOF
}

# check_one_link <citing-file> <citing-dir> <raw-link> — validates one extracted link target
# (existence, then #anchor if present) and records a BROKEN line + sets broken=1 on failure.
check_one_link() {
  local f="$1" dir="$2" link="$3" target anchor target_path
  [ -z "$link" ] && return 0
  # Strip a trailing title, e.g. `file.md "Some Title"`, instead of skipping any link that contains
  # a space (which used to hide a genuinely broken escaped/encoded-space path). All three
  # CommonMark title forms are handled: the previous pass stripped only the double-quoted one, so
  # `[x](url 'Title')` kept its title, failed the existence test and was reported falsely BROKEN —
  # a regression the old skip-anything-with-a-space behaviour had accidentally masked.
  link="$(printf '%s' "$link" | sed -E "s/[[:space:]]+${LINK_TITLE_RE}[[:space:]]*\$//")"
  [ -z "$link" ] && return 0
  # a destination may be wrapped in angle brackets: [x](<some file.md>)
  case "$link" in
  "<"*">")
    link="${link#<}"
    link="${link%>}"
    ;;
  esac
  [ -z "$link" ] && return 0
  case "$link" in
  # `//host/path` is a protocol-relative URL — external, and it must be matched before the
  # root-absolute `/path` handling below, which would otherwise try to resolve it on disk.
  //*) return 0 ;;
  http://* | https://* | mailto:* | tel:*) return 0 ;;
  esac

  links_checked=$((links_checked + 1))

  target="${link%%#*}"
  if [ "$target" = "$link" ]; then
    anchor=""
  else
    anchor="${link#*#}"
  fi

  if [ -z "$target" ]; then
    target_path="$f" # same-file "#anchor" link
  else
    case "$target" in
    # Root-absolute destination: GitHub renders `/standards/x.md` relative to the repository root,
    # so resolve it against the SCAN ROOT (which is the cwd — see the `cd` at the top). Prepending
    # "$dir/" instead made the verdict depend on where the citing file sits: it resolved by
    # accident from a file at the repo root (`.//standards/x.md`) and was falsely BROKEN from
    # every subdirectory. path_escapes_root still runs on the result, so `/../outside.md` is
    # reported rather than resolved.
    /*) target_path=".$target" ;;
    *) target_path="$dir/$target" ;;
    esac
    if path_escapes_root "$target_path"; then
      echo "OUT-OF-REPO: $f -> $link (resolves outside the repository being scanned)"
      broken=1
      return 0
    fi
    if [ ! -e "$target_path" ]; then
      echo "BROKEN: $f -> $link"
      broken=1
      return 0
    fi
  fi

  if [ -n "$anchor" ]; then
    case "$target_path" in
    *.md)
      anchors_checked=$((anchors_checked + 1))
      if ! anchor_exists "$target_path" "$anchor"; then
        echo "BROKEN-ANCHOR: $f -> $link (no heading matches #$anchor in $target_path)"
        broken=1
      fi
      ;;
    esac
  fi
}

# process_links <file> — extracts every inline `](target)` link and every reference-style
# `[label]: target` definition from <file>'s prose (fences/code spans already stripped) and checks
# each one.
process_links() {
  local f="$1" dir raw links refdefs link
  dir="$(dirname "$f")"
  if fence_unclosed "$f"; then
    echo "UNCLOSED-FENCE: $f (ends inside a code fence; everything after the opening marker would be silently unchecked)"
    broken=1
  fi
  raw="$(strip_code <"$f")"

  # One level of balanced parentheses is allowed inside the destination so that a parenthesised
  # title — [x](file.md (Title)) — and a URL containing brackets are both captured whole rather
  # than truncated at the first ')'.
  links="$(printf '%s\n' "$raw" | grep -oE '\]\(([^()]|\([^()]*\))+\)' | sed -E 's/^\]\(//; s/\)$//')"
  while IFS= read -r link; do
    check_one_link "$f" "$dir" "$link"
  done <<EOF
$links
EOF

  # A link reference definition is `[label]: destination` with an OPTIONAL title and nothing else on
  # the line; the destination is a single whitespace-free token, or any text inside <angle
  # brackets>. Requiring that shape stops ordinary prose such as
  # `[Note]: remember to update the changelog` — which CommonMark also refuses to treat as a
  # definition — being read as a link to a file called "remember to update the changelog".
  refdefs="$(printf '%s\n' "$raw" |
    grep -E "^[[:space:]]{0,3}\\[[^]]+\\]:[[:space:]]*(<[^<>]*>|[^[:space:]]+)([[:space:]]+${LINK_TITLE_RE})?[[:space:]]*\$" |
    sed -E 's/^[[:space:]]{0,3}\[[^]]+\]:[[:space:]]*//')"
  while IFS= read -r link; do
    check_one_link "$f" "$dir" "$link"
  done <<EOF
$refdefs
EOF
}

# ---- §N section-reference range check ---------------------------------------------------------

# section_refs <file> — emits "<token><TAB><N>" for every `<file>.md §N` reference found in
# <file>'s prose, including chained refs like `§7/§8` or `§3–§4`. Fences/code spans are stripped
# and wrapped paragraphs are joined first so a reference split across a line wrap is still found.
# Pinned to LC_ALL=C: this awk decomposes multi-byte literals (§, em/en dash) into raw bytes, and
# quantifying one directly (e.g. a bare `§?`) mis-compiles unless parenthesized — every optional
# multi-byte literal below is wrapped in `(...)?` for exactly that reason.
section_refs() {
  LC_ALL=C awk "$BLOCK_AWK"'
    function flush() {
      if (buf != "") scan(buf)
      buf = ""
    }
    function scan(s,    i, n, mstart, mlen, tok, rest, w, wlen, chain, num, rest2, clen, chunk) {
      i = 1
      n = length(s)
      while (i <= n) {
        rest = substr(s, i)
        if (!match(rest, /[A-Za-z0-9_.\/-]+\.md/)) break
        mstart = i + RSTART - 1
        mlen = RLENGTH
        tok = substr(s, mstart, mlen)
        w = substr(s, mstart + mlen, 60)
        if (match(w, /^[^§A-Za-z]{0,20}§[0-9]+/)) {
          wlen = RLENGTH
          chain = substr(w, 1, wlen)
          if (match(chain, /[0-9]+/)) {
            num = substr(chain, RSTART, RLENGTH)
            print tok "\t" num
          }
          rest2 = substr(w, wlen + 1)
          while (match(rest2, /^(–|—|[,;\/-])[[:space:]]{0,2}(§)?[0-9]+/)) {
            clen = RLENGTH
            chunk = substr(rest2, 1, clen)
            if (match(chunk, /[0-9]+/)) print tok "\t" substr(chunk, RSTART, RLENGTH)
            rest2 = substr(rest2, clen + 1)
          }
        }
        i = mstart + mlen
      }
    }
    BEGIN { buf = "" }
    {
      if (blk($0) != "t") { flush(); next }
      if (buf == "") buf = $0; else buf = buf " " $0
    }
    END { flush() }
  ' "$1"
}

# resolve_md <citing-dir> <token> — resolves a bare/relative/rooted §N token to a real file path:
# relative to the citing file's dir, then repo-root-relative, then standards/-relative, then (for
# a bare filename mentioned without any path, the common case) a unique repo-wide basename match.
resolve_md() {
  local citing_dir="$1" token="$2" c base m found="" count=0
  for c in "$citing_dir/$token" "$token" "standards/$token"; do
    # never resolve a reference against a file the repo does not own; the basename fallback below
    # is safe by construction because ALL_MD only ever holds in-tree paths
    if path_escapes_root "$c"; then continue; fi
    if [ -f "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  base="$(basename "$token")"
  for m in "${ALL_MD[@]}"; do
    if [ "$(basename "$m")" = "$base" ]; then
      found="$m"
      count=$((count + 1))
    fi
  done
  if [ "$count" -eq 1 ]; then
    printf '%s' "$found"
    return 0
  fi
  return 1
}

check_section_refs() {
  local f="$1" dir tok num target
  dir="$(dirname "$f")"
  while IFS="$(printf '\t')" read -r tok num; do
    [ -z "$tok" ] && continue
    refs_checked=$((refs_checked + 1))
    if ! target="$(resolve_md "$dir" "$tok")"; then
      echo "BROKEN-SECTION: $f -> $tok §$num (could not resolve '$tok' to a file)"
      broken=1
      continue
    fi
    if ! grep -qE "^## ${num}\. " "$target"; then
      echo "BROKEN-SECTION: $f -> $tok §$num (no '## $num.' heading in $target)"
      broken=1
    fi
  done < <(section_refs "$f")
}

# ---- main ---------------------------------------------------------------------------------------

while IFS= read -r -d '' f; do
  ALL_MD+=("$f")
done < <(find . -name '*.md' \
  -not -path './.git/*' \
  -not -path './.touchstone/*' \
  -not -path './node_modules/*' \
  -not -path './tests/fixtures/*' \
  -not -path './evals/cases/*/repo/*' \
  -not -path '*/.superpowers/*' \
  -print0)

n="${#ALL_MD[@]}"
if [ "$n" -eq 0 ]; then
  echo "No markdown files found under $(pwd) — nothing to check."
  exit 1
fi

for f in "${ALL_MD[@]}"; do
  process_links "$f"
done

for f in "${ALL_MD[@]}"; do
  check_section_refs "$f"
done

if [ "$broken" -ne 0 ]; then
  echo "Broken internal links or section references found."
  exit 1
fi

# Report the counts, then claim success only for the categories that actually had inputs. Printing
# "All internal links resolve." and "All §N section references are in range." unconditionally meant
# a tree of empty markdown files produced two success claims about empty sets.
echo "Checked $n markdown file(s): $links_checked internal link(s), $anchors_checked anchor(s), $refs_checked §N section reference(s)."
if [ "$links_checked" -gt 0 ]; then
  echo "All internal links resolve."
fi
if [ "$anchors_checked" -gt 0 ]; then
  echo "All #anchor fragments resolve."
fi
if [ "$refs_checked" -gt 0 ]; then
  echo "All §N section references are in range."
fi
if [ "$links_checked" -eq 0 ] && [ "$anchors_checked" -eq 0 ] && [ "$refs_checked" -eq 0 ]; then
  echo "No links, anchors or §N section references present — nothing was verified."
fi
exit 0
