# Maintainer notes — stale-claims

## `reference-findings.txt`

Committed verbatim from the blind run scored in `evals/BASELINE.md`'s "currency-researcher vs
evals/cases/stale-claims" section — `agent: currency-researcher`, model **sonnet**, run
**2026-08-17**. 100% recall was measured against this case's 2-entry answer key, which is thin
evidence on its own — see `evals/BASELINE.md` for that caveat stated in full, and
`evals/README.md`/`CHANGELOG.md` for why this and the other reference findings files are
"Known limitations", not a settled result.

`.github/workflows/eval.yml` replays this file through `scripts/score-eval.sh` on a schedule. That
replay only proves `answer-key.txt` and `scripts/score-eval.sh` still agree on this frozen text — it
re-runs no model and says nothing about whether `agents/currency-researcher.md` would still find
these defects today.
