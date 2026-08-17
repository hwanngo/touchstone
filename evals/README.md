# Evals

An eval **case** is a fixture repo plus a catalogued answer key: a small, deliberately broken
repository, and a file naming exactly which defects a subagent should find in it. Cases are how
this kit proves a subagent (`agents/*.md`) actually finds the defects it claims to, instead of
trusting a description that sounds right.

## What a case is

```text
evals/cases/<case-id>/
  meta.txt          which agent this case targets, and a one-line summary
  answer-key.txt     the catalogued defects, one per line
  repo/**            the fixture repo itself — deliberately malformed
```

`meta.txt` is `key: value`, one per line:

```text
agent: adoption-doctor
summary: an adopter whose installed toolchain cannot run
min_recall: 100
max_unmatched: 0
```

`min_recall` and `max_unmatched` are the case's **score floors** — see "Score floors" below.
`scripts/check-evals.sh` requires both on every case, numeric, with no exception.

`answer-key.txt` is one defect per line, `<required|optional>|<path>|<substring>` — see
`scripts/score-eval.sh` for the exact scoring contract. `required` entries count toward an agent
run's recall; `optional` entries neither help nor hurt (defects an agent may reasonably surface or
reasonably skip). `<path>` and `<substring>` are matched against `repo/`-relative findings text: a
finding counts as a match when it contains both.

`<substring>` must **discriminate**, and `scripts/check-evals.sh` refuses a case where it does not.
Two spellings make the match test unconditional, so the entry contributes a guaranteed match and the
case's recall stops being a measurement:

- an **empty** `<substring>` — it is a substring of every line;
- a `<substring>` that is a substring of its own `<path>` (`standards/platform/caching.md|caching.md`)
  — any line containing the path necessarily contains it, so the entry says only "the agent mentioned
  this file".

Both shipped in this kit's own keys. Write a substring only a line describing the *defect* would
contain.

## What substring matching cannot tell apart

**Polarity.** A finding that *denies* a defect names the same file and uses the same vocabulary as
one that reports it, so substring matching alone scored a perfect PASS on a findings file asserting
every catalogued defect was absent:

```text
standards/frameworks/django.md: Django 4.2 LTS is correctly documented as current; no drift found
standards/platform/caching.md: confirmed there is no standalone caching.md; the claim is accurate
→ matched 2 of 2 required / unmatched 0 / recall 100 / verdict PASS
```

`scripts/score-eval.sh` now narrows this with one modest, explainable rule: a findings line
containing any of a fixed list of **conformance-assertion phrases** ("no action needed", "no drift",
"is correct", "looks correct", "is up to date", "correctly documented", "already present", …) cannot
satisfy an answer-key entry. It still counts as a findings line, so it lands in `unmatched` — the
honest place for it. The list lives at the top of `scripts/score-eval.sh`; every phrase is matched
case-insensitively, and each carries its verb so the negated form does not match it (`is up to date`
is a marker; "is **not** up to date" is not).

**This is a phrase list, not sentiment analysis, and it does not solve polarity.** It catches the
explicit "I checked and it is fine" register, which is what a lazy or over-confident run actually
produces. It does not catch a denial phrased any other way — `justfile: lints the vendored kit? no,
exclusion present` still matches the `justfile|vendored kit` entry, and a sufficiently creative
denial always will. **A nonzero recall is evidence, never proof, that the findings assert the defects
rather than deny them.** Reading the findings is still the human's job; this only removes the
cheapest way to fake a pass.

## Unmatched is not the same claim as false

`scripts/score-eval.sh` reports a line labelled `unmatched N`: the count of findings that matched no
answer-key entry, `required` or `optional`. That word is chosen deliberately, and an earlier version
of this scorer got it wrong — it printed `false-positives N`, which is a claim this instrument
cannot back up. **Unmatched means "matched no answer-key entry." It does not mean "untrue."**

An answer key only ever records what someone thought to catalogue in advance. Point a genuinely
thorough, entirely honest agent at a realistic fixture repo and it will routinely surface true
defects nobody wrote down — no answer key for a non-trivial fixture is ever complete. Scoring that
agent's honest thoroughness as `false-positives 18` and failing it on that basis punishes exactly
the behaviour this kit wants: an earlier blind run of `standards-auditor` against
`evals/cases/standards-gaps/` did exactly this — 18 unmatched findings, every one of them
independently verified true against the fixture by hand, on an agent that had matched 100% of the
catalogued required entries and produced zero hallucinations. That run is the reason
`answer-key.txt` for that case now catalogues those 18 as `optional` entries, and the reason score
floors exist at all.

**Measuring genuine precision — whether an unmatched finding is actually WRONG, as opposed to
merely uncatalogued — needs decoys**: defects planted into a case's fixture that an agent might
plausibly but incorrectly report (a config value that looks stale but isn't, a dependency that looks
unpinned but is pinned one file over, and so on). A run against a case with decoys can distinguish
"this agent hallucinated a defect" from "this agent found something real that nobody catalogued." No
case in this kit currently plants decoys, so **precision is not measured here** — an `unmatched`
count is a prompt for a human to adjudicate the listed findings, not a verdict on their truth. This
is a known limitation, not an oversight: adding a decoy to a case is real design work (the decoy has
to be genuinely plausible, not a strawman), and no case has had it done yet.

## Score floors

Exact-match scoring (`matched == required` and `unmatched == 0`) is right for a small, fully
catalogued case, but wrong for a case like `standards-gaps` whose fixture has more true defects than
anyone catalogued — under exact matching, thoroughness alone guarantees FAIL forever, regardless of
agent quality. **Score floors** are how a case says how much of that it is willing to accept:

- `min_recall` — the minimum recall percentage (of `required` entries) a run must hit.
- `max_unmatched` — the maximum number of unmatched findings a run may have.

Pass `--meta <case>/meta.txt` to `scripts/score-eval.sh` to score against these floors instead of
the exact-match rule: `recall >= min_recall AND unmatched <= max_unmatched`. Without `--meta`, the
scorer's behaviour is unchanged from before floors existed — exact match only. `scripts/run-eval.sh`
always passes `--meta` for you.

A floor is not license to stop cataloguing. `standards-gaps`'s floor exists because the fixture
genuinely has more true, low-severity defects than the answer key's `required` entries name; the
floor bounds how many of those an honest run may leave unmatched before something is actually wrong,
rather than pretending the fixture has no more defects than the four anyone wrote down.

## Hermetic vs. model-dependent

The eval system splits cleanly into two halves:

- **Hermetic, offline, part of `just ci`:** `scripts/score-eval.sh` turns a findings file plus an
  answer key into a verdict, and `scripts/check-evals.sh` (this directory's gate) checks that every
  case is well-formed and that every defect its answer key claims is really present in its fixture
  repo. Neither invokes a model or touches the network. They enter `just ci` by different doors, and
  the distinction matters when you are looking for which command exercises which:
  `check-evals.sh` is a `just gates` entry, run directly; `score-eval.sh` is not in `just gates` at
  all — it runs under `just test`, through `tests/gates/score-eval.test.sh` (its contract) and
  `tests/gates/reference-findings-replay.test.sh` (every case's committed reference findings).
- **Model-dependent, run by hand or in a scheduled job, never from `tests/run.sh`:** the runner that
  actually points an agent at `repo/` and captures its findings. That script needs a model to call
  and is therefore never part of the hermetic suite.

## The phantom check

`scripts/check-evals.sh` is the gate that stops a case from rotting. An answer key is a *claim*
about a fixture repo — "this file, at this path, contains this defect" — and a claim nothing
verifies is exactly the defect class this whole kit exists to remove. A case whose `repo/` drifts
away from its `answer-key.txt` (someone "cleans up" the fixture, or edits it without updating the
key) silently turns every future agent run into a false failure: the agent gets scored against a
defect that is no longer there, and the miss reads as an agent regression instead of what it
actually is — a stale fixture. The gate catches this by checking, for every `required` entry, that
the named path exists in `repo/` and is non-empty. It also refuses to certify zero cases: a gate
that examined nothing has proved nothing.

**The phantom check does not run against `optional` entries.** This is deliberate, not an oversight:
some real defects ARE the absence of a file — no `CHANGELOG.md`, no `SECURITY.md`, no
`dependabot.yml`. The `<required|optional>|<path>|<substring>` format has no way to assert "this
path is absent" without a phantom check reading that assertion as a claim the path exists, so an
absence-defect can only be catalogued as `optional`, never `required`, and its `<path>` names the
file that should exist but doesn't. Every `optional` absence-defect entry in this kit's answer keys
follows that convention (see `evals/cases/standards-gaps/answer-key.txt`).

## `evals/cases/*/repo/**` is deliberately malformed

Every fixture repo under a case's `repo/` exists to reproduce a real, previously-shipped defect —
a broken pre-commit hook id, a lint recipe that walks a vendored kit it should exclude, and so on.
Linting or link-checking that content would fail by construction, and "fixing" it to satisfy a
linter would mean the fixture no longer reproduces the defect it exists to catch. So
`evals/cases/*/repo/**` is excluded from `scripts/check-links.sh` and from `.markdownlint-cli2.jsonc`
— the two gates in this kit that otherwise walk the whole repo tree looking for markdown and
internal links. Gates scoped to their own directory (`scripts/check-standards.sh` over `standards/`,
`scripts/check-skills.sh` over `skills/`, `scripts/check-agents.sh` over `agents/`) never see this
content in the first place, so no exclusion is needed there.

## Reference findings and what the scheduled workflow proves

Running `agents/*.md` against a `repo/` fixture needs a model call — see "Hermetic vs.
model-dependent" above — so nothing that does that can live in `tests/run.sh`, `just ci`, or the
PR-blocking CI workflow. `.github/workflows/eval.yml` runs on a weekly schedule (and
`workflow_dispatch`) instead, and it **still does not invoke a model**. What it runs is:

1. `scripts/check-evals.sh` — fully deterministic, and real work: it validates every case's shape,
   runs the phantom check (an answer key claiming a defect the fixture doesn't have), and the leak
   check (a `repo/` that gives away its own provenance). This alone is worth a scheduled run,
   because it catches a case rotting between releases even if nobody touches `evals/` in the
   meantime.
2. `scripts/score-eval.sh`, replayed against a **committed** `reference-findings.txt` in each case
   directory (`evals/cases/<id>/reference-findings.txt`) — the frozen text output of one blind
   `agents/<name>.md` run, recorded in that case's `NOTES.md` with the date and model, and also
   documented in `evals/BASELINE.md`.

**Be precise about what step 2 proves.** `score-eval.sh` needs a findings file to score, and no
findings file is generated at CI time — nothing in this workflow calls a model. So step 2 replays
old, static text through the current `answer-key.txt` and the current `scripts/score-eval.sh`. A
PASS there proves the scorer and the answer key still agree with each other on a *fixed* input; a
regression in *either* the scoring logic or the answer key's substrings would flip it to FAIL. **State
this plainly: this workflow regresses the scorer and the answer key, not the agent.** It
proves nothing about the model — it does not mean `agents/adoption-doctor.md` (or any other agent)
would still find the same defects today, next week, or with a different model. Re-verifying the
agent itself requires an actual run: `just eval <case>` with fresh findings from a real agent
session, done by a person, on purpose, exactly as described above.

The workflow fails if it finds zero cases to check (`check-evals.sh`'s own zero-case guard) and
separately fails if it finds zero committed `reference-findings.txt` files to score — a scheduled
job that silently scored nothing would be exactly the vacuous-pass failure mode this kit exists to
eliminate.

**The replay is also in the blocking suite**, at
`tests/gates/reference-findings-replay.test.sh` (`just test`), and that is where it earns its keep.
Keeping it weekly-only meant a one-character `answer-key.txt` edit landed green and surfaced up to
seven days later, in a scheduled job nobody watches: `check-evals.sh` reads a key's `sev` and `path`
and never its `<substring>`, so nothing on the blocking path looked at the part that had changed.
Since the replay is deterministic, offline and takes milliseconds, there was never a hermeticity
reason to keep it out. The scheduled job stays, and is now a rot-detector — a clean runner, on a
schedule, against the default branch — rather than the only detector.

## Adding a case

1. Pick (or write) the `agents/<name>.md` subagent this case targets.
2. Build `repo/` reproducing one real defect class — ideally one that actually shipped, so the case
   is grounded in something that really happened rather than a defect nobody would write.
3. Write `answer-key.txt` naming every `required` defect a correct run must find, plus any
   `optional` ones it may reasonably surface or skip.
4. Write `meta.txt`, including numeric `min_recall:` and `max_unmatched:` score floors (see "Score
   floors" above). Start with `min_recall: 100` and `max_unmatched: 0` — exact-match strictness — and
   only widen `max_unmatched` if a real run against the case turns up true, uncatalogued defects that
   `answer-key.txt` isn't going to enumerate exhaustively.
5. Run `bash scripts/check-evals.sh` — it fails loudly on a phantom entry, a missing `agent:` line,
   an agent this repo does not ship, or a missing/non-numeric score floor.
6. Run the agent for real (`just eval <case>` after producing findings by hand) and, once it PASSes,
   commit that findings text as `evals/cases/<case-id>/reference-findings.txt`, with the date and
   model recorded in the case's `NOTES.md`. This is what lets `.github/workflows/eval.yml` include
   the new case — see "Reference findings and what the scheduled workflow proves" above for exactly
   what that scheduled replay does and does not prove. A case with no `reference-findings.txt` is
   still fully valid; it just isn't scored by the scheduled workflow, only by `check-evals.sh`.
