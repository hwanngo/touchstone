#!/usr/bin/env bash
# Gate: scripts/check-sync.sh — the drift gate — must stay meaningful once a repo is allowed to
# declare an intentional divergence from the kit.
#
# Background: the kit itself shipped no .touchstone.toml, so check-sync exited 2 ("run init.sh
# first") in its own repo and `just ci` was red. The kit cannot simply adopt itself, because three
# managed pairs differ ON PURPOSE (justfile, .github/dependabot.yml, .github/workflows/ci.yml):
# the kit's copies run the kit's own gates, the templates are the adopter starters. The fix is a
# first-class `diverge` list that pins the sha256 of BOTH sides plus a stated reason — available to
# every adopter, dogfooded by the kit.
#
# A declared-divergence mechanism is only worth having if it cannot rot into a waiver graveyard.
# The three properties that make it a gate rather than an off switch each get a row below:
#   * editing EITHER side of a declared pair breaks a pinned hash and fails until re-declared;
#   * a declaration that no longer describes a divergence (files now identical) fails as stale;
#   * undeclared drift fails exactly as it did before.
#
# FIXTURE MODEL. There is no committed fixture tree here: the fixture IS the kit's own tracked
# working-tree content, copied into $tmp/target/.touchstone and adopted with the REAL init.sh, so
# every row measures the INSTALLED artifact rather than a hand-written idea of it. That makes the
# "fixture deleted" failure mode different but not absent, so it is guarded the same two ways as
# tests/gates/check-links.test.sh:
#   1. assert_adopter states, as its own assertion, which files the build must have produced; if
#      the copy or init.sh silently produced nothing, that row fails before any verdict is read.
#   2. run_sync refuses to run against a tree with no check-sync.sh in it (rc 126, distinctive
#      output) instead of letting `bash: no such file` masquerade as a correct non-zero verdict,
#      and every non-zero row is paired with an assert_contains on the specific message.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # resolved relative to this file at runtime, same as every other test file
. "$DIR/../lib/assert.sh"
KIT="$(cd -P "$DIR/../.." && pwd)"

# Hard rule 4: self-skip only for genuine tool absence. Everything check-sync.sh itself does is
# under test and must never be skipped — tests/run.sh exits on failures only, so a skip reads green.
for tool in mktemp git tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    ts_skip "check-sync" "$tool not available"
    ts_report
    exit 0
  fi
done

TMP="$(mktemp -d 2>/dev/null || true)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  ts_skip "check-sync" "mktemp -d failed"
  ts_report
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

# vendor_kit <dir> — copy the kit's TRACKED files, at working-tree content, into <dir>. Working
# tree, not `git archive HEAD`: an implementation change that is staged-but-uncommitted (or merely
# unstaged) must be what these rows exercise, or the suite verifies yesterday's script.
vendor_kit() {
  local dst="$1"
  mkdir -p "$dst"
  (cd "$KIT" && git ls-files -z | tar -cf - --null -T -) | (cd "$dst" && tar -xf -)
}

# new_adopter <name> — a fresh repo with the kit vendored at .touchstone/, git-initialised, then
# adopted by the REAL init.sh. Echoes the target path.
new_adopter() {
  local t="$TMP/$1"
  mkdir -p "$t"
  vendor_kit "$t/.touchstone"
  git init -q "$t" >/dev/null 2>&1
  bash "$t/.touchstone/scripts/init.sh" --target "$t" >/dev/null 2>&1
  printf '%s\n' "$t"
}

# assert_adopter <label> <target> <file>... — precondition row. Names every file whose absence
# would change a verdict below, so a build that produced nothing fails loudly here instead of
# turning into a plausible-looking non-zero exit later.
assert_adopter() {
  local label="$1" t="$2" state="complete" missing="" f
  shift 2
  for f in "$@"; do
    [ -e "$t/$f" ] || missing="$missing $f"
  done
  [ -n "$missing" ] && state="missing:$missing"
  assert_eq "$label: built tree is complete on disk" "complete" "$state"
}

SYNC_RC=0
SYNC_OUT=""
# run_sync <target> — run the vendored check-sync against <target>, capturing rc WITHOUT a pipeline
# (a pipeline would hand back the last stage's status — the exact defect this campaign found in
# these gates).
run_sync() {
  local t="$1"
  if [ ! -f "$t/.touchstone/scripts/check-sync.sh" ]; then
    SYNC_RC=126
    SYNC_OUT="GATE MISSING: $t/.touchstone/scripts/check-sync.sh"
    return 0
  fi
  SYNC_RC=0
  SYNC_OUT="$(bash "$t/.touchstone/scripts/check-sync.sh" --target "$t" 2>&1)" || SYNC_RC=$?
}

# declare_diverge <target> <dest> — ask the gate itself for the ready-to-paste line and splice it
# into the marker, replacing any previous diverge block. Using --print-diverge rather than
# recomputing hashes here is deliberate: a row that hand-rolled the hashes would still pass if the
# flag emitted garbage.
declare_diverge() {
  local t="$1" dest="$2" line marker="$1/.touchstone.toml"
  line="$(bash "$t/.touchstone/scripts/check-sync.sh" --target "$t" --print-diverge "$dest" 2>/dev/null)"
  sed '/^diverge = \[/,/^\]/d' "$marker" >"$marker.new"
  mv "$marker.new" "$marker"
  {
    printf 'diverge = [\n'
    printf '  "%s",\n' "$line"
    printf ']\n'
  } >>"$marker"
  printf '%s\n' "$line"
}

# sync_out_has <needle> — echoes "present" or "absent" so a row can assert something is ABSENT with
# the same assert_eq every other row uses. A function rather than an inline `case` inside "$( ... )"
# because bash 3.2 mis-parses the pattern's ')' there (same note as check-links.test.sh).
sync_out_has() {
  case "$SYNC_OUT" in
  *"$1"*) echo present ;;
  *) echo absent ;;
  esac
}

count_lines() {
  local n
  n="$(printf '%s\n' "$SYNC_OUT" | grep -c "$1" || true)"
  printf '%s\n' "$n" | tr -d ' '
}

# --- 1. no marker -------------------------------------------------------------------------------
mkdir -p "$TMP/bare"
vendor_kit "$TMP/bare/.touchstone"
assert_adopter "no-marker" "$TMP/bare" ".touchstone/scripts/check-sync.sh"
run_sync "$TMP/bare"
assert_eq "no .touchstone.toml: exits 2" "2" "$SYNC_RC"
assert_contains "no .touchstone.toml: points at init.sh" "init.sh" "$SYNC_OUT"

# --- 2. fresh adoption is born green ------------------------------------------------------------
T="$(new_adopter target)"
assert_adopter "fresh adoption" "$T" \
  ".touchstone.toml" "justfile" ".editorconfig" ".gitattributes" \
  ".github/dependabot.yml" ".github/workflows/ci.yml" ".touchstone/templates/justfile"
run_sync "$T"
assert_eq "fresh adoption: exits 0" "0" "$SYNC_RC"
assert_contains "fresh adoption: reports no drift" "(none)" "$SYNC_OUT"
assert_contains "fresh adoption: says how many managed files it actually compared" "managed file(s)" "$SYNC_OUT"
assert_eq "fresh adoption: examined more than zero managed files" "absent" "$(sync_out_has "Checked 0 managed file(s)")"

# --- 3. undeclared drift still fails ------------------------------------------------------------
printf '\n# adopter customisation\n' >>"$T/justfile"
run_sync "$T"
assert_eq "undeclared drift: exits 1" "1" "$SYNC_RC"
assert_contains "undeclared drift: names the drifted file" "~ justfile" "$SYNC_OUT"

# --- 4. declaring it, with both hashes pinned, goes green and PRINTS the reason ------------------
LINE="$(declare_diverge "$T" justfile)"
assert_contains "--print-diverge: emits a four-field entry for the dest" "justfile :: " "$LINE"
run_sync "$T"
assert_eq "declared divergence: exits 0" "0" "$SYNC_RC"
assert_contains "declared divergence: is printed, never silent" "declared divergence" "$SYNC_OUT"
assert_contains "declared divergence: names the file" "= justfile" "$SYNC_OUT"

# --- 6/7 come before 5 so they run against the live declaration --------------------------------
# dest edited after the declaration → a pinned hash breaks.
printf '# later edit\n' >>"$T/justfile"
run_sync "$T"
assert_eq "declared, then dest edited: exits 1" "1" "$SYNC_RC"
assert_contains "declared, then dest edited: demands a re-declaration" "changed since declaration" "$SYNC_OUT"

# SOURCE edited after the declaration → the other pinned hash breaks. This is the row that proves
# the mechanism is not a one-sided waiver: an upstream template change under a declared
# customisation must force a human to re-look.
cp "$T/justfile" "$TMP/justfile.keep"
git -C "$T" checkout -- justfile 2>/dev/null || true
sed '/^diverge = \[/,/^\]/d' "$T/.touchstone.toml" >"$T/.touchstone.toml.new"
mv "$T/.touchstone.toml.new" "$T/.touchstone.toml"
cp "$TMP/justfile.keep" "$T/justfile"
declare_diverge "$T" justfile >/dev/null
printf '\n# upstream template change\n' >>"$T/.touchstone/templates/justfile"
run_sync "$T"
assert_eq "declared, then KIT SOURCE edited: exits 1" "1" "$SYNC_RC"
assert_contains "declared, then KIT SOURCE edited: demands a re-declaration" "changed since declaration" "$SYNC_OUT"

# --- 5. stale declaration (the two files are identical again) fails ------------------------------
cp "$T/.touchstone/templates/justfile" "$T/justfile"
declare_diverge "$T" justfile >/dev/null
cp "$T/.touchstone/templates/justfile" "$T/justfile"
run_sync "$T"
assert_eq "stale declaration (files identical): exits 1" "1" "$SYNC_RC"
assert_contains "stale declaration: says to remove the entry" "now matches the kit" "$SYNC_OUT"

# --- a diverge entry naming a file the kit does not manage is an error, not a no-op --------------
sed '/^diverge = \[/,/^\]/d' "$T/.touchstone.toml" >"$T/.touchstone.toml.new"
mv "$T/.touchstone.toml.new" "$T/.touchstone.toml"
{
  printf 'diverge = [\n'
  printf '  "src/not-managed.txt :: aaa :: bbb :: nonsense",\n'
  printf ']\n'
} >>"$T/.touchstone.toml"
run_sync "$T"
assert_eq "diverge entry for an unmanaged file: exits 1" "1" "$SYNC_RC"
assert_contains "diverge entry for an unmanaged file: says so" "not a managed file" "$SYNC_OUT"

# --- 8. version mismatch still fails ------------------------------------------------------------
V="$(new_adopter verbump)"
assert_adopter "version mismatch" "$V" ".touchstone.toml"
sed -E 's/^version = .*/version = "0.0.0"/' "$V/.touchstone.toml" >"$V/.touchstone.toml.new"
mv "$V/.touchstone.toml.new" "$V/.touchstone.toml"
run_sync "$V"
assert_eq "marker version behind the kit: exits 1" "1" "$SYNC_RC"
assert_contains "marker version behind the kit: names the pinned version" "repo pins 0.0.0" "$SYNC_OUT"

# --- 9. dogfood: the kit's own tracked tree must be green, with exactly its declared divergences --
K="$TMP/kitclone"
vendor_kit "$K"
assert_adopter "kit self-adoption" "$K" \
  ".touchstone.toml" "justfile" ".github/dependabot.yml" ".github/workflows/ci.yml" \
  ".pre-commit-config.yaml" \
  "templates/justfile" "templates/dependabot.yml" "templates/github/workflows/ci.yml" \
  "templates/pre-commit-config.yaml"
KIT_RC=0
KIT_OUT="$(cd "$K" && bash scripts/check-sync.sh 2>&1)" || KIT_RC=$?
assert_eq "kit self-adoption: check-sync exits 0 in the kit" "0" "$KIT_RC"
SYNC_OUT="$KIT_OUT"
assert_eq "kit self-adoption: exactly four declared divergences" "4" "$(count_lines '^  = ')"
assert_contains "kit self-adoption: justfile is one of them" "= justfile (declared divergence:" "$KIT_OUT"
assert_contains "kit self-adoption: dependabot.yml is one of them" "= .github/dependabot.yml (declared divergence:" "$KIT_OUT"
assert_contains "kit self-adoption: ci.yml is one of them" "= .github/workflows/ci.yml (declared divergence:" "$KIT_OUT"
assert_contains "kit self-adoption: .pre-commit-config.yaml is one of them" "= .pre-commit-config.yaml (declared divergence:" "$KIT_OUT"

# ...and it is not green by accident: remove one declaration and the kit goes red.
sed '/^  "justfile :: /d' "$K/.touchstone.toml" >"$K/.touchstone.toml.new"
mv "$K/.touchstone.toml.new" "$K/.touchstone.toml"
DROP_RC=0
DROP_OUT="$(cd "$K" && bash scripts/check-sync.sh 2>&1)" || DROP_RC=$?
assert_eq "kit self-adoption: dropping one diverge entry turns it red" "1" "$DROP_RC"
assert_contains "kit self-adoption: the dropped file is reported as plain drift" "~ justfile" "$DROP_OUT"

ts_report
