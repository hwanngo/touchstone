#!/usr/bin/env bash
# score-eval — turn an eval run's findings into a verdict against a catalogued answer key.
#
# Deterministic and offline BY DESIGN: this is the half of the eval system that can live in the
# hermetic suite. The half that invokes a model is scripts/run-eval.sh, which must never be called
# from tests/run.sh.
#
#   usage: ./scripts/score-eval.sh <answer-key> <findings> [--meta <meta.txt>]
#
# Answer key, one defect per line:  <required|optional>|<path>|<substring>
# A finding counts as matching an entry when it contains BOTH the path and the substring, AND does
# not read as a CONFORMANCE ASSERTION about that file (see DENIAL_MARKERS below). Entries marked
# `optional` neither help recall nor add to the unmatched tally — they are defects an agent may
# reasonably report or reasonably skip.
#
# A DEGENERATE ENTRY is a caller error and exits 2, never a silent 100%:
#   - an empty <substring> matched every findings line that named the path, so a key written as
#     `required|src/x.py|` (a trimmed field, or a draft) could not fail;
#   - a <substring> that is itself contained in <path> (`…/caching.md|caching.md`) carries zero
#     information beyond "the agent mentioned this file", because any line containing the path
#     necessarily contains the substring.
# scripts/check-evals.sh applies the same two rules as a blocking gate, so such an entry cannot
# reach a scoring run in the first place; this check is the backstop for a key passed in by hand.
#
# A findings line matching no answer-key entry at all — required OR optional — is UNMATCHED. That
# word is deliberate: unmatched means "matched no answer-key entry", which is NOT the same as
# untrue. An answer key only ever catalogues what someone thought to write down; a thorough, entirely
# honest agent auditing a realistic fixture will routinely surface true defects nobody catalogued,
# and no answer key can ever be complete. Measuring genuine PRECISION — whether an unmatched finding
# is actually wrong, as opposed to merely uncatalogued — would require planting decoys into a case's
# fixture: defects an agent might plausibly but wrongly report. No case currently does this, so
# precision is not measured here; see evals/README.md for that limitation stated in full, and treat a
# nonzero unmatched count as "needs a human to adjudicate", not as "proven false".
#
# An answer key with zero `required` entries exits 1: a scorer with nothing to require has proved
# nothing, and a 0-of-0 "100%" is the vacuous pass this repo exists to eliminate.
#
# Verdict:
#   - No --meta given: legacy exact-match verdict, UNCHANGED from every prior version of this
#     script — PASS requires matched == required AND unmatched == 0. This is deliberate: existing
#     callers that never pass --meta must see identical behaviour today and after this option was
#     added.
#   - --meta <file> given, naming a meta.txt with numeric `min_recall:` and `max_unmatched:` lines
#     (score floors — see evals/README.md): PASS requires recall >= min_recall AND
#     unmatched <= max_unmatched. A --meta file missing either line, or with a non-numeric value,
#     is a caller error and exits 2 rather than silently falling back to the legacy rule.
set -uo pipefail

KEY=""
FINDINGS=""
META=""
while [ $# -gt 0 ]; do
  case "$1" in
  --meta)
    [ $# -ge 2 ] || {
      echo "score-eval: --meta needs a value" >&2
      exit 2
    }
    META="$2"
    shift 2
    ;;
  *)
    if [ -z "$KEY" ]; then
      KEY="$1"
    elif [ -z "$FINDINGS" ]; then
      FINDINGS="$1"
    else
      echo "score-eval: unexpected argument: $1" >&2
      exit 2
    fi
    shift
    ;;
  esac
done

if [ -z "$KEY" ] || [ -z "$FINDINGS" ]; then
  echo "usage: score-eval.sh <answer-key> <findings> [--meta <meta.txt>]" >&2
  exit 2
fi
for f in "$KEY" "$FINDINGS"; do
  if [ ! -f "$f" ]; then
    echo "score-eval: no such file: $f" >&2
    exit 2
  fi
done

# Score floors (optional). Parsed with awk, not a `while read` loop, so the no-trailing-newline
# footgun documented below (and fixed three times elsewhere in this plan) does not apply here: awk
# processes a file's final unterminated line the same as every other line.
MIN_RECALL=""
MAX_UNMATCHED=""
if [ -n "$META" ]; then
  if [ ! -f "$META" ]; then
    echo "score-eval: no such file: $META" >&2
    exit 2
  fi
  MIN_RECALL="$(awk -F': *' '/^min_recall:/ { print $2; exit }' "$META")"
  MAX_UNMATCHED="$(awk -F': *' '/^max_unmatched:/ { print $2; exit }' "$META")"
  case "$MIN_RECALL" in
  '' | *[!0-9]*)
    echo "score-eval: $META has no numeric 'min_recall:' line" >&2
    exit 2
    ;;
  esac
  case "$MAX_UNMATCHED" in
  '' | *[!0-9]*)
    echo "score-eval: $META has no numeric 'max_unmatched:' line" >&2
    exit 2
    ;;
  esac
fi

# is_comment_or_blank <line> — true (exit 0) when a FINDINGS-file line is blank or a `#` comment
# (its first non-whitespace character is `#`). Applied only to $FINDINGS, never to $KEY: an answer
# key's lines are already routed by the required|optional case statement above, so a key that
# adopted the same `#` convention needs no separate handling here.
#
# Without this, a provenance header ("# produced 2026-08-17 with sonnet") on a findings file reads
# as a finding that matches no answer-key entry, inflating `unmatched` and flipping a genuine PASS
# to FAIL — which is exactly why the committed evals/cases/*/reference-findings.txt files shipped
# with no header at all: the header would have silently broken their own score. See
# tests/fixtures/score-eval-findings-header for the reproduction this guards.
is_comment_or_blank() {
  local trimmed="$1"
  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
  case "$trimmed" in
  '' | '#'*) return 0 ;;
  *) return 1 ;;
  esac
}

# --- POLARITY -----------------------------------------------------------------------------------
# Substring matching is polarity-blind: a findings line asserting a defect is ABSENT contains the
# same path and the same keywords as one asserting it is present. Measured, not hypothetical — this
# findings file used to score `matched 2 of 2 / recall 100 / verdict PASS` against
# evals/cases/stale-claims:
#
#   standards/frameworks/django.md: Django 4.2 LTS is correctly documented as current; no drift found
#   standards/platform/caching.md: confirmed there is no standalone caching.md; the claim is accurate
#
# A findings file that DENIES every catalogued defect is the most valuable thing an agent can get
# wrong, because it is what a lazy or over-confident run produces, and a perfect score on it means
# the metric cannot distinguish thoroughness from confident silence.
#
# THE RULE, deliberately modest: a findings line containing one of the fixed phrases below is a
# CONFORMANCE ASSERTION — a claim that there is nothing to fix — and cannot satisfy any answer-key
# entry. It still counts as a findings line, so it lands in `unmatched`, which is the honest place
# for it: "this line matched no catalogued defect, a human should read it".
#
# WHAT THIS IS NOT: sentiment analysis, negation parsing, or any attempt to understand the line.
# It is a phrase list, and its limits are stated in evals/README.md. It catches the explicit
# "I checked and it is fine" register; it does NOT catch a denial phrased in some other way
# (`justfile: lints the vendored kit? no, exclusion present` still matches). Polarity cannot be
# solved by substring matching; this narrows the easiest way to fake a pass, nothing more.
#
# Every phrase is matched case-insensitively against the whole line. Phrases are chosen so that the
# NEGATED form does not contain them — `is up to date` is a marker, and "is not up to date" does not
# contain it — which is why they carry their verb.
DENIAL_MARKERS='no action needed
no action required
no change needed
no change required
no changes needed
no changes required
nothing to fix
nothing to change
nothing to report
no drift
not stale
no issue found
no issues found
no defect found
no defects found
no problem found
no problems found
no violation
is correct
are correct
looks correct
look correct
seems correct
appears correct
already correct
verified correct
confirmed correct
is accurate
are accurate
claim is accurate
claim holds
correctly documented
correctly pinned
correctly configured
is up to date
are up to date
is up-to-date
are up-to-date
already present
already excluded
already handled
already pinned
false positive'

# denies_defect <findings-line> — true when the line reads as a conformance assertion.
denies_defect() {
  local lower marker
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r marker || [ -n "$marker" ]; do
    [ -n "$marker" ] || continue
    case "$lower" in
    *"$marker"*) return 0 ;;
    esac
  done <<EOF
$DENIAL_MARKERS
EOF
  return 1
}

required=0
matched=0
# Sentinel newline at both ends so a match can be tested by looking for the WHOLE line delimited by
# '\n' on each side, never a bare substring test — otherwise a spurious finding that happens to be a
# substring of an already-matched line (e.g. "a.py: alph" inside "a.py: alpha") would read as matched
# instead of as the unmatched line it is.
matched_lines=$'\n'

# One pass over the findings BEFORE the key loop, so each line's polarity is decided exactly once
# rather than once per answer-key entry. Same sentinel-newline membership test as matched_lines.
denial_lines=$'\n'
while IFS= read -r line || [ -n "$line" ]; do
  is_comment_or_blank "$line" && continue
  denies_defect "$line" && denial_lines="$denial_lines$line"$'\n'
done <"$FINDINGS"

# `|| [ -n "$sev" ]` (and its twins below): `read` returns non-zero on the final line of a file that
# does not end in '\n', even though it still populates the fields from that line. Without the OR
# clause, a hand-written answer key (or findings file) missing its trailing newline silently drops
# its last entry from the loop — shrinking the required count and turning a real miss into a vacuous
# PASS. See tests/fixtures/score-eval-no-trailing-newline for the reproduction.
while IFS='|' read -r sev path needle || [ -n "$sev" ]; do
  case "$sev" in
  required | optional) ;;
  *) continue ;;
  esac
  [ -n "$path" ] || continue
  # Degenerate entries: see the header. Rejected loudly, because each of them yields a recall
  # figure that cannot fail, which is the one failure mode this scorer exists to prevent.
  if [ -z "$needle" ]; then
    echo "score-eval: $KEY entry for '$path' has an EMPTY substring, which matches every findings line naming the path — that entry's recall could never fail. Give it a discriminating substring." >&2
    exit 2
  fi
  case "$path" in
  *"$needle"*)
    echo "score-eval: $KEY entry '$sev|$path|$needle' has a substring that is contained in its own path, so any line naming the file satisfies it unconditionally — it measures nothing. Give it a substring that only a line describing the DEFECT would contain." >&2
    exit 2
    ;;
  esac
  hit=0
  while IFS= read -r line || [ -n "$line" ]; do
    is_comment_or_blank "$line" && continue
    # A conformance assertion about this file is not a report of the defect — see DENIAL_MARKERS.
    case "$denial_lines" in
    *$'\n'"$line"$'\n'*) continue ;;
    esac
    case "$line" in
    *"$path"*)
      case "$line" in
      *"$needle"*)
        hit=1
        matched_lines="$matched_lines$line"$'\n'
        ;;
      esac
      ;;
    esac
  done <"$FINDINGS"
  if [ "$sev" = "required" ]; then
    required=$((required + 1))
    [ "$hit" -eq 1 ] && matched=$((matched + 1))
  fi
done <"$KEY"

if [ "$required" -eq 0 ]; then
  echo "score-eval: no required entries in $KEY — a scorer with nothing to require proves nothing." >&2
  echo "verdict FAIL"
  exit 1
fi

unmatched=0
while IFS= read -r line || [ -n "$line" ]; do
  is_comment_or_blank "$line" && continue
  case "$matched_lines" in
  *$'\n'"$line"$'\n'*) ;;
  *) unmatched=$((unmatched + 1)) ;;
  esac
done <"$FINDINGS"

pct=$((matched * 100 / required))

echo "matched $matched of $required required"
echo "unmatched $unmatched"
echo "recall $pct"

if [ -n "$META" ]; then
  echo "floors min_recall=$MIN_RECALL max_unmatched=$MAX_UNMATCHED"
  if [ "$pct" -ge "$MIN_RECALL" ] && [ "$unmatched" -le "$MAX_UNMATCHED" ]; then
    echo "verdict PASS"
    exit 0
  fi
  echo "verdict FAIL"
  exit 1
fi

if [ "$matched" -eq "$required" ] && [ "$unmatched" -eq 0 ]; then
  echo "verdict PASS"
  exit 0
fi
echo "verdict FAIL"
exit 1
