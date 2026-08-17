#!/usr/bin/env bash
# check-evals — every eval case under evals/cases/ is well-formed, and every defect its answer key
# claims is really present in its fixture repo.
#
# The phantom check is the reason this gate exists. An answer key is a CLAIM about a fixture repo.
# A claim nothing verifies is exactly the defect class this kit exists to remove: a case whose repo
# drifted away from its key scores every agent against a defect that is no longer there, and the
# resulting failures look like agent regressions rather than what they are — a stale fixture.
#
# This gate also requires every case's meta.txt to carry numeric `min_recall:` and `max_unmatched:`
# score floors — the ones scripts/score-eval.sh reads via its optional --meta argument. Requiring
# them here, not merely accepting them there, means a case can never ship without floors and quietly
# fall back to score-eval.sh's legacy exact-match rule.
#
#   usage: ./scripts/check-evals.sh   (no args; scans evals/cases/*)
#
# Zero cases exits 1: a gate that examined nothing has proved nothing.
#
# This gate is self-locating (the `cd` below), same as check-agents.sh, check-skills.sh and
# check-links.sh: it always scans the repo it lives in. Run it FROM a fixture directory and it
# still walks the repo the script physically sits inside — so tests/gates/check-evals.test.sh
# copies this script INTO each fixture tree before invoking it, exactly the way an adopting repo
# carries its own copy under .touchstone/scripts/. Running the gate against a fixture without
# relocating it first would silently re-certify this kit instead of the fixture under test.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# --- scope guard: never certify a repo this gate has not opened ---------------------------------
# This gate scans the repo it LIVES in (the `cd` above), by design: it audits touchstone's own
# eval cases. Invoked the way an adopter would — `./.touchstone/scripts/check-evals.sh` from a
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
      echo "check-evals: refusing to run — it would report on the wrong repository."
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
n=0

err() {
  echo "FAIL: $1" >&2
  fail=1
}

for case_dir in evals/cases/*/; do
  [ -d "$case_dir" ] || continue
  id="$(basename "$case_dir")"
  n=$((n + 1))

  [ -f "$case_dir/meta.txt" ] || err "$id: no meta.txt"
  [ -f "$case_dir/answer-key.txt" ] || err "$id: no answer-key.txt"
  [ -d "$case_dir/repo" ] || err "$id: no repo/ fixture tree"

  if [ -f "$case_dir/meta.txt" ]; then
    agent="$(awk -F': *' '/^agent:/ { print $2; exit }' "$case_dir/meta.txt")"
    if [ -z "$agent" ]; then
      err "$id: meta.txt has no 'agent:' line"
    elif [ ! -f "agents/$agent.md" ]; then
      err "$id: meta.txt targets agent '$agent', which has no agents/$agent.md"
    fi

    # Score floors: what scripts/score-eval.sh's --meta option reads. Required here, not just
    # accepted there, so a case can never ship without them — an agent run against a case with no
    # floors would silently fall back to score-eval.sh's legacy exact-match rule, which is exactly
    # the vacuous-on-thoroughness verdict this plan's Task 4c exists to fix.
    min_recall="$(awk -F': *' '/^min_recall:/ { print $2; exit }' "$case_dir/meta.txt")"
    max_unmatched="$(awk -F': *' '/^max_unmatched:/ { print $2; exit }' "$case_dir/meta.txt")"
    case "$min_recall" in
    '') err "$id: meta.txt has no 'min_recall:' line" ;;
    *[!0-9]*) err "$id: meta.txt min_recall is not numeric: '$min_recall'" ;;
    *)
      # BOUNDED, not merely numeric. `min_recall: 0` is satisfied by a run that matched nothing —
      # a floor that cannot fail is the same vacuous pass as no floor at all, and it passed this
      # gate. Above 100 is unreachable, which fails the case forever for a different reason.
      if [ "$min_recall" -lt 1 ] || [ "$min_recall" -gt 100 ]; then
        err "$id: meta.txt min_recall must be 1-100, got '$min_recall' (0 is a floor no run can fail; >100 is a floor no run can meet)"
      fi
      ;;
    esac
    case "$max_unmatched" in
    '') err "$id: meta.txt has no 'max_unmatched:' line" ;;
    *[!0-9]*) err "$id: meta.txt max_unmatched is not numeric: '$max_unmatched'" ;;
    *)
      # Bounded against something MEASURABLE rather than an arbitrary cap: a case that tolerates more
      # unmatched findings than its answer key has entries has given away more slack than it
      # catalogued, so no realistic run can breach it. `max_unmatched: 9999` passed this gate.
      # Zero is legal and is the right default (see evals/README.md's "Score floors").
      if [ -f "$case_dir/answer-key.txt" ]; then
        entries="$(awk -F'|' '$1 == "required" || $1 == "optional" { c++ } END { print c + 0 }' "$case_dir/answer-key.txt")"
        if [ "$max_unmatched" -gt "$entries" ]; then
          err "$id: meta.txt max_unmatched ($max_unmatched) exceeds the answer key's $entries catalogued entr(y|ies) — slack larger than the catalogue is a floor no run can breach"
        fi
      fi
      ;;
    esac
  fi

  if [ -f "$case_dir/answer-key.txt" ]; then
    req=0
    # `|| [ -n "$sev" ]`: `read` returns non-zero on an answer key's final line when the file is
    # not newline-terminated, even though it still populates the fields from that line. Without
    # the OR clause, a hand-written answer-key.txt missing its trailing newline (the ordinary case
    # for a file someone typed by hand) silently drops its last entry from the loop — shrinking
    # the required count and, worse, skipping the phantom check on exactly that entry. A phantom
    # defect on the last line of the file would then pass uncaught. See
    # scripts/score-eval.sh for the sibling bug this mirrors, and
    # tests/fixtures/evals-phantom-no-trailing-newline for the reproduction.
    while IFS='|' read -r sev path needle || [ -n "$sev" ]; do
      case "$sev" in
      required | optional) ;;
      *) continue ;;
      esac

      # --- DEGENERATE ENTRIES: an entry whose recall could never fail ---------------------------
      # scripts/score-eval.sh matches a finding against an entry by looking for BOTH <path> and
      # <substring> in the line. Two spellings of <substring> make that test unconditional, so the
      # entry contributes a guaranteed match and the case's recall figure stops being a measurement:
      #
      #   required|src/x.py|           an EMPTY substring is a substring of every line
      #   required|a/caching.md|caching.md   a substring of its own PATH: any line containing the
      #                                      path necessarily contains it
      #
      # Both were live: the second shipped in evals/cases/stale-claims, where it meant one of that
      # case's two required entries could not distinguish the catalogued defect from any mention of
      # the file. Checked for `optional` entries too — an optional entry does not move recall, but a
      # degenerate one silently absorbs findings lines out of the `unmatched` tally, which loosens
      # the other floor instead.
      #
      # This is a GATE, not a warning: a case carrying such an entry must not ship. score-eval.sh
      # rejects the same two shapes at scoring time as a backstop for a hand-passed key.
      if [ -z "$needle" ]; then
        err "DEGENERATE KEY: $id -> '$sev|$path|' has an empty substring, so it matches every findings line that names the path and its recall can never fail"
      else
        case "$path" in
        *"$needle"*)
          err "DEGENERATE KEY: $id -> '$sev|$path|$needle' has a substring contained in its own path, so any line naming the file satisfies it unconditionally — it measures nothing"
          ;;
        esac
      fi

      [ "$sev" = "required" ] || continue
      req=$((req + 1))
      if [ ! -s "$case_dir/repo/$path" ]; then
        err "PHANTOM: $id -> $path (answer key claims a defect here; the fixture has no such file)"
      fi
    done <"$case_dir/answer-key.txt"
    [ "$req" -gt 0 ] || err "$id: answer key has no required entries"
  fi

  # --- leak check: repo/ must never carry this case's own provenance -----------------------------
  # An answer key is a claim ABOUT a fixture; repo/ is what an agent under test actually sees. A
  # comment inside repo/ naming the case, the defect class, or the fixture's own status
  # ("DELIBERATELY BROKEN", "reproducing a real ... defect", a literal evals/cases/<id> path, or
  # the case id on its own) is not realistic clutter — it is the answer key, handed to the agent
  # for free. This is not hypothetical: a blind adoption-doctor run against
  # evals/cases/adopter-broken-toolchain found its justfile defect with such a comment present in
  # repo/, and missed the SAME defect once the comment was stripped — see that case's NOTES.md for
  # the measured before/after. Provenance a maintainer needs stays OUTSIDE repo/, in NOTES.md
  # beside the case (readable by a human and by this gate, never by an agent pointed at repo/).
  #
  # Markers deliberately EXCLUDE a bare "fixture": some cases vendor real standards content into
  # repo/.touchstone/ (e.g. self-audit.md's "tests self-skip when fixtures absent"), which uses
  # that word in its ordinary pytest-fixture sense — a bare-word marker would flag genuine content
  # as a leak it is not. "fixture repo" and "(fixture)" catch every leak this kit has actually
  # shipped without that false positive.
  #
  # THE CASE ID IS ANCHORED, for the same reason "fixture" is not a bare-word marker. `-e "$id"`
  # searched for the id as a free substring, which works only as long as no case is ever named
  # something that occurs in ordinary content. A case id of `ci`, `uv`, `lint` or `docs` — all
  # plausible names for a case about exactly those things — would flag every fixture mentioning the
  # word, and the gate's own message would insist that ordinary content was an answer key. The two
  # anchored spellings below are the ways a leak actually names its case: the `evals/cases/<id>`
  # path (already covered by the bare `evals/cases/` marker, kept here so the message names the
  # case), and the id set off by word boundaries. `grep -w` on the id is not enough on its own
  # either, but combined with the other markers it keeps the check while dropping the trap.
  if [ -d "$case_dir/repo" ]; then
    leak_hits="$(grep -rIn -F \
      -e "evals/cases/" -e "answer-key" -e "eval case" \
      -e "DELIBERATELY BROKEN" -e "reproducing a real" -e "fixture repo" -e "(fixture)" \
      "$case_dir/repo" 2>/dev/null)"
    id_hits="$(grep -rInw -F -e "$id" "$case_dir/repo" 2>/dev/null)"
    if [ -n "$id_hits" ]; then
      leak_hits="$leak_hits${leak_hits:+
}$id_hits"
    fi
    if [ -n "$leak_hits" ]; then
      # Input redirection (<<EOF), not a pipe: a `while read` fed by a pipe runs in a subshell, and
      # the `fail=1` err() sets inside the loop would be lost the moment the subshell exits.
      while IFS= read -r leak_line || [ -n "$leak_line" ]; do
        [ -n "$leak_line" ] || continue
        err "LEAK: $id -> repo/ carries its own case provenance, readable by an agent under test as the answer key ($leak_line)"
      done <<EOF
$leak_hits
EOF
    fi
  fi
done

if [ "$n" -eq 0 ]; then
  echo "No eval cases found under evals/cases — nothing to check." >&2
  exit 1
fi

[ "$fail" -eq 0 ] || exit 1
echo "Validated $n eval case(s)."
