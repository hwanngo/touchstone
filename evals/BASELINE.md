# Baseline: shipped agents against their eval cases

Date: 2026-08-17. Model used for every run: **sonnet**. Every run was **blind** — each agent saw
only its own definition (`agents/*.md`) and the case's `repo/` fixture, never `answer-key.txt`.

**Scope: three cases, five runs.** `standards-auditor` vs `standards-gaps` (one run);
`adoption-doctor` vs `adopter-broken-toolchain` (three — "hinted", "nohint" and a later "fresh" run);
`currency-researcher` vs `stale-claims` (one). The header and the "Precision is not measured" section
were originally written when this document covered two cases and two runs, and said so; corrected
here rather than left to be read as a count.

This document records two things that must not be conflated: what those blind runs actually did, and
the fact that the scoring instrument itself was wrong for one of them. See "The instrument defect"
below before reading any verdict as a judgment on the agent.

## standards-auditor vs evals/cases/standards-gaps

**Raw scorer output** (original `answer-key.txt`, four catalogued entries, exact-match verdict):

```text
matched 3 of 3 required
false-positives 18
recall 100
verdict FAIL
```

**Adjudicated.** All 18 "false-positives" were checked by hand against the fixture, one at a time:
CHANGELOG.md, CodeQL, dependency-review-action, a release-automation workflow, any `schedule:`
trigger, `dependabot.yml`/`renovate.json`, `[tool.pyright]` config (`grep -c 'tool.pyright'
pyproject.toml` returns 0, no `pyrightconfig.json`), `.github/CODEOWNERS`'s six `@your-org`
placeholders, the `justfile`'s `ci` recipe (literally `lint test build`, omitting the pyright and
pip-audit steps CI runs), `tests/test_health.py` asserting only a hardcoded version constant, the
ADR's zero mentions of alternatives, and shellcheck/shfmt appearing zero times in
`.github/workflows/ci.yml`, plus the remaining commitlint/markdownlint/lychee/flaky-test-policy/
vendored-standards-docs findings. **All 18 are true statements about the fixture. Zero
hallucinations.**

**Assessment: genuinely good.** 100% recall against the catalogued required entries, 22 findings
total, 0 hallucinations on adjudication. This is a thorough, honest audit run.

**Rescored** after this task catalogued the 18 as `optional` entries in `answer-key.txt` and gave
the case score floors (`min_recall: 100`, `max_unmatched: 3`):

```text
matched 3 of 3 required
unmatched 0
recall 100
floors min_recall=100 max_unmatched=3
verdict PASS
```

Every one of the 18 now matches a catalogued `optional` entry, so `unmatched` drops from 18 to 0 —
under either the new floors or the untouched legacy exact-match rule (`--meta` omitted), this case
now scores PASS.

## adoption-doctor vs evals/cases/adopter-broken-toolchain

Two blind runs, scored independently: once against the fixture exactly as it was committed at the
time, and once against a copy of `repo/` with its provenance comments stripped ("hinted" and
"nohint" below). **Recall 100 on both runs** against each run's own catalogued required entries at
the time — but the two runs did not catalogue the same set of required entries, because the fixture
itself leaked one of them. See "The leak" below before reading either verdict as a clean result.

**The pre-commit defect was diagnosed genuinely, with hints stripped.** In the nohint run, the agent
read `.pre-commit-config.yaml`, resolved `astral-sh/ruff-pre-commit` at pinned `rev: v0.8.0`, and
correctly reported that `ruff-check` does not exist at that rev — naming the real ids (`ruff` and
`ruff-format`) that do. Nothing about this defect was hinted or leaked; the agent derived it from
the pinned rev and the hook id, exactly the method `agents/adoption-doctor.md`'s check 1 ("Can the
adopter commit?") prescribes.

**The justfile defect was found only with hints, and this was measured, not assumed.** At the time
of both runs, `repo/.pre-commit-config.yaml` and `repo/justfile` each opened with a `# DELIBERATELY
BROKEN — fixture for evals/cases/adopter-broken-toolchain, reproducing a real touchstone v0.2.0
defect...` comment block that named the exact defect in prose, and `repo/README.md` listed both
planted defects outright. With those comments present, the hinted run reported the justfile's
missing `.touchstone/` lint-scope exclusion. With them stripped, the nohint run did not — it
reported `.touchstone: absent` instead (the fixture had no `.touchstone/` directory at all at the
time, so the defect was *latent*: inferable only from the leaking comment, not diagnosable from
anything actually present in the fixture).

**The leak, stated plainly:** the comment was doing the diagnosis instead of the agent. This is
exactly the defect class this kit exists to catch, applied to itself — an eval case's own fixture
handing the agent under test its answer key. It went uncaught because nothing scanned `repo/` for
its own provenance.

**Historical — measured against the pre-fix fixture.** Everything from here through the "Open
definition gap" paragraph below describes the **hinted** and **nohint** runs and the fixture as it
existed *before* Task 6b/6c's repairs: `.touchstone/` did not exist in `repo/` at all, and
`repo/README.md`/`.pre-commit-config.yaml`/`justfile` still carried the leaking provenance comments
described below. These two runs are preserved as *findings text*, rescored against the current
(fixed) answer key for illustration, but they are not comparable to the **fresh blind run against the
current, fixed fixture**, documented in its own section further down. Do not read the hinted/nohint
numbers as a baseline for `adoption-doctor` today.

**Original raw scorer output**, before this task's fixes (old answer key, `max_unmatched: 0`):

```text
# hinted
matched 2 of 2 required
unmatched 7
recall 100
floors min_recall=100 max_unmatched=0
verdict FAIL

# nohint
matched 2 of 2 required
unmatched 9
recall 100
floors min_recall=100 max_unmatched=0
verdict FAIL
```

Both FAILed on `max_unmatched: 0`, not on recall — and adjudicating the unmatched findings by hand
found a second instrument defect layered on top of the case-format one already known from
`standards-auditor`'s run: the nohint run's `.touchstone` required entry was satisfied by an
unrelated, coincidentally-matching finding — "justfile: no \`fmt\` recipe exists, so there is no
formatter step that could be scoped to exclude .touchstone/" — a true finding about a *different*
defect that happened to contain both "justfile" and ".touchstone". The old substring was too
generic to tell the two apart.

**This task fixed the case, not the agent** (no run proved `agents/adoption-doctor.md` broken, so it
was not edited):

- Moved the leaking provenance out of `repo/` into `evals/cases/adopter-broken-toolchain/NOTES.md`,
  where a maintainer (and `scripts/check-evals.sh`) can read it but an agent pointed at `repo/`
  cannot.
- Made the justfile defect **manifest**: `repo/.touchstone/` now carries real content (standards
  docs plus `scripts/bootstrap_helper.py`, which imports `os` and never uses it), so `ruff check .`
  from the repo root genuinely fails on a file inside `.touchstone/` — verified directly with a real
  `ruff` install (`ruff check .` → `F401 \`os\` imported but unused` at
  `.touchstone/scripts/bootstrap_helper.py:3:8`, exit 1).
- Replaced the coincidence-prone `required|justfile|.touchstone` entry with
  `required|justfile|vendored kit` — a substring specific to the lint-scope defect's actual
  mechanism, present in exactly one line of either preserved findings file (the genuine hinted
  finding) and absent from every other line in both files.
- Catalogued the 8–10 true, previously-uncatalogued findings from both runs (no `.git`, no
  `.touchstone/` at the time, no `AGENTS.md`, no `scripts/init.sh`, no `scripts/check-sync.sh`, no
  `.github/workflows/ci.yml`, no `setup` recipe, no `fmt` recipe, `ruff` undeclared so `just lint`
  exits 127, and the installed gate's inability to distinguish bad input from good) as `optional`
  entries, and set `max_unmatched: 2` — a deliberately nonzero but non-vacuous floor. What a *failing*
  run looks like under it, reproducible from the committed files: append three plausible-but-
  uncatalogued lines to `reference-findings.txt` and re-score, and the floor bites at full recall —
  `matched 2 of 2 required / unmatched 3 / recall 100 / floors min_recall=100 max_unmatched=2 /
  verdict FAIL`, exit 1.
- Extended `scripts/check-evals.sh` with a leak check so `repo/` can never again carry its own case
  provenance — this is the durable fix; the case fix alone would not stop it from recurring.

**Rescored** against the fixed fixture, the corrected answer key, and the new floors
(`min_recall: 100`, `max_unmatched: 2`):

```text
# hinted
matched 2 of 2 required
unmatched 0
recall 100
floors min_recall=100 max_unmatched=2
verdict PASS

# nohint
matched 1 of 2 required
unmatched 0
recall 50
floors min_recall=100 max_unmatched=2
verdict FAIL
```

**The nohint FAIL is the correct, honest result, not an artifact of scoring mechanics.** With the
leak closed and the justfile defect now manifest, the nohint run's preserved findings genuinely do
not contain the `.touchstone/`-lint-scope defect under any non-coincidental reading — it was missed,
not mis-scored. This case's floors were not loosened to make it pass; re-running `adoption-doctor`
blind against the now-fixed fixture (a NEW run, not a rescore of preserved text) is the way to learn
whether the agent finds this defect once the fixture actually shows it — see the fresh-run section
immediately below, which is exactly that new run.

**Open definition gap, found by both runs, not fixed by this task.**
`agents/adoption-doctor.md`'s five checks are all written to *diagnose* an adoption artifact that
exists but misbehaves — a pre-commit config with a bad hook id, a lint recipe with a scope bug, a
routing link that resolves to nothing. Both blind runs independently surfaced a different failure
mode the method is silent on: what to do when `.touchstone/`, `AGENTS.md`, `scripts/init.sh`,
`scripts/check-sync.sh`, or `.git` itself is **absent entirely**, rather than present-but-broken.
The agent handled this sensibly in practice in both runs (reporting the absence as a finding rather
than skipping it), but the *written method* has no step for it — check 4, for instance, opens "Read
every `standards/...` link in `AGENTS.md`", which presupposes `AGENTS.md` exists. Per this plan's
Step 5 rule, no run proved the agent broken (both runs produced correct, useful output), so
`agents/adoption-doctor.md` was not edited. This is recorded as an open definition gap for a future
task, the same way `currency-researcher`'s external-vs-repo-self-referential gap was recorded below
without being fixed.

### Fresh blind run (Task 6c), against the fixed fixture

A third, independent blind run of `adoption-doctor` — built from git-tracked files only, so no
`NOTES.md`, no leaking comments, no `.touchstone/`-absence special case — was made against the
fixture *after* Task 6b's repairs (provenance moved to `NOTES.md`, `.touchstone/` made real and
observable). This is the run that actually answers the question the hinted/nohint pair above could
not: what does the agent find when the fixture only shows its defects through their consequences?

**Both required defects were found genuinely.** Recall 100 against the two `required` entries. The
justfile finding — the one the nohint run above missed entirely — reads:

> `justfile`: `ruff check .` in the `lint` recipe is not scoped to exclude `.touchstone/`, so the gate
> lints the vendored kit itself and fails on an unused `os` import in
> `.touchstone/scripts/bootstrap_helper.py` before ever reaching the adopter's own code

That is a correct, mechanism-level diagnosis derived from reading the justfile and walking
`.touchstone/` — not a restatement of a comment, because no comment exists in this fixture anymore.
This is the leak's fix paying off: the same defect, diagnosed the same way the pre-commit defect was
diagnosed in the nohint run, now that it has an observable consequence.

**Adjudicated: all 5 originally-unmatched findings are true, zero false positives — but the scoring
key itself had a bug.** The raw score against the answer key as Task 6b left it:

```text
matched 2 of 2 required
unmatched 5
recall 100
floors min_recall=100 max_unmatched=2
verdict FAIL
```

Every one of the 5 unmatched lines was checked directly against the fixture (`git ls-files`,
file reads, and a real `ruff check .` run — `F401 \`os\` imported but unused` at
`.touchstone/scripts/bootstrap_helper.py:3:8`, exit 1): the agent correctly reported that
`pyproject.toml` is absent, `.github/workflows` has no CI wiring, the justfile has no `setup` recipe
and no `fmt` recipe, and the unused `os` import is a real lint violation. All five are genuinely true
of the fixture. **Zero hallucinations.**

But adjudicating them surfaced something more interesting than a missing catalogue entry: the
existing `optional|.touchstone|absent` entry — left over from when the hinted/nohint runs correctly
reported `.touchstone` as absent — was **coincidentally satisfying three unrelated findings** in this
fresh run (`.editorconfig` absent, `.gitattributes` absent, `uv.lock` absent), because each of those
lines happens to cite `.touchstone/standards/self-audit.md` by path while describing a *different*
file's absence. That coincidence was silently absorbing three true-but-miscatalogued findings and
making the true unmatched count look smaller than it should — the same class of bug Task 6b fixed for
the `required|justfile|.touchstone` entry, now found a second time in an `optional` entry. Fixed by
tightening the path to `.touchstone:` (matches only a line that leads with that literal path, as the
hinted/nohint genuine findings do; no longer matches a mid-sentence citation). The `AGENTS.md`
absence finding had the same kind of gap for a different reason — this run's phrasing ("reference it
for routing rules") didn't contain the literal word "resolve" the existing entry required — fixed by
adding a second, paraphrase-tolerant `optional` entry rather than editing the first.

All 6 genuinely-true, previously-uncatalogued or mis-catalogued findings (`pyproject.toml`, `uv.lock`,
`.editorconfig`, `.gitattributes`, `.github/workflows` CI wiring, the `bootstrap_helper.py` unused
import, and the `AGENTS.md` routing-rules phrasing) are now `optional` entries in `answer-key.txt`,
each checked with `grep`/`python3` against all three preserved findings files before being written,
specifically to rule out a new coincidental match. **Rescored:**

```text
matched 2 of 2 required
unmatched 0
recall 100
floors min_recall=100 max_unmatched=2
verdict PASS
```

`max_unmatched: 2` was reviewed, not blindly kept: with the catalogue now materially more complete
(19 entries, up from 12), a small nonzero buffer stays appropriate for a genuinely thorough run that
surfaces something new and true, while still catching padding. The demonstration that the floor is
load-bearing rather than decoration, inlined so it can be re-run from the committed files alone:
append three plausible-but-uncatalogued lines to this case's `reference-findings.txt` and score it
twice, changing nothing but `max_unmatched`.

```text
# padded run, this case's real floor (max_unmatched: 2)
matched 2 of 2 required / unmatched 3 / recall 100
floors min_recall=100 max_unmatched=2
verdict FAIL                                            rc=1

# the SAME padded run, floor raised to 3
matched 2 of 2 required / unmatched 3 / recall 100
floors min_recall=100 max_unmatched=3
verdict PASS                                            rc=0
```

Full recall does not carry a padded run past this floor, and the only thing that flips it is the floor
itself — which is what makes the number a measurement rather than a formality.

**Open definition gap, hit again by the fresh run.** The gap recorded above — `adoption-doctor`
assumes adoption artifacts exist and is silent on what to do when they are absent entirely — was hit
a second, independent time: the fresh run had to clone the fixture into a scratch git repository
before it could proceed, because `pre-commit run --all-files` cannot run at all without a `.git`
directory, and the fixture (correctly, for a case about a broken toolchain) does not ship one.

**A second definition gap, found only by the fresh run.** The agent's report cited
`standards/practices/collaboration.md` §5 and `standards/platform/ci-cd.md` §7 as the routing targets
`AGENTS.md` should point to — but neither file exists in an adopter fixture that vendors only part of
the kit (`repo/.touchstone/standards/` here contains only `README.md` and `self-audit.md`). The agent
cited sections of standards docs it could not actually read in this repo, presumably from its own
general knowledge of the kit's standards layout rather than from anything present in `repo/`. Neither
gap was fixed here — per the Step 5 rule, no run proved the agent's checks *wrong*, only silent on
(and in this second case, over-confident about) paths the method never verifies exist before citing
them. Both are recorded for a later definition task; `agents/adoption-doctor.md` was not touched.

## currency-researcher vs evals/cases/stale-claims

**Raw scorer output** (unchanged answer key, two required entries):

```text
matched 2 of 2 required
false-positives 0
recall 100
verdict PASS
```

**Assessment: 100% recall — but on a 2-entry answer key, which is thin evidence.** Do not read a
2-of-2 as a strong result on its own; it establishes only that the agent can find two specific,
fairly conspicuous defects (a stale Django LTS claim, and a doc's false claim that a sibling doc
does not exist) in one small fixture. It says little about recall on a larger or noisier fixture,
and this case has no `optional` entries and no decoys, so it cannot distinguish "found everything
worth finding" from "found the two things the case happened to plant." Treat this case as a smoke
test that the agent's basic mechanism works, not as a demonstrated ceiling.

**And it was thinner than that when it was scored.** At the time of this run the second required
entry was `required|standards/platform/caching.md|caching.md` — its substring sitting inside its own
path, so any findings line that merely *named* the file satisfied it, whatever it said about it. The
honest description of the 2-of-2 above is therefore **1 discriminating entry + 1 file-mention
entry**, not 2 of 2. The entry now reads `required|standards/platform/caching.md|exists`, and
`scripts/check-evals.sh` fails any case carrying an entry of that shape — but the number above was
not re-measured against a model, only the key was fixed, so read the recall figure with that in
mind.

**Rescored** with the case's new score floors (`min_recall: 100`, `max_unmatched: 0` — unchanged in
substance from the legacy exact-match rule, since this case has no catalogued slack to give):

```text
matched 2 of 2 required
unmatched 0
recall 100
floors min_recall=100 max_unmatched=0
verdict PASS
```

**Open definition gap, found by this run, not fixed by this task.** `agents/currency-researcher.md`
writes its evidence rules entirely around *external* primary sources: "Verify each against a
primary source... Fetch it," and "Your training data is not a source... If you did not fetch it, it
is `UNVERIFIED`." But the second required finding in this case — the doc's claim that
`standards/platform/caching.md` does not exist — is a claim about the repo itself. No external
fetch can settle it; it can only be checked by reading the repo's own filesystem, which the agent's
`Read`/`Grep`/`Glob` tools support but the *written rules* never mention as a verification method.
The agent got this right in practice (it matched the required entry), but the rules as written could
just as easily lead a future run to mark a repo-self-referential claim `UNVERIFIED` for "not being
fetched," which would be wrong — the claim was fully checkable, just not via WebFetch. Per this
plan's Step 5, no run proved the agent broken (it produced the right answer), so
`agents/currency-researcher.md` was not edited. This gap should be handled as a definition fix in
its own right, not folded into this task's scorer-hardening work.

## The instrument defect

`scripts/score-eval.sh` counted every finding matching no answer-key entry as a "false positive" and
required zero of them to PASS. Against `standards-gaps`, a fixture built from a real, previously
adjudicated adopter repo, an open-ended audit agent will always surface true defects nobody
catalogued in advance — no answer key for a non-trivial fixture is ever complete. That makes
`false-positives == 0` an unmeetable bar for a thorough, honest agent, independent of agent quality.
**The FAIL verdict on `standards-auditor`'s raw run was an instrument defect, not an agent defect.**
This task fixed the instrument: renamed the misleading `false-positives` label to `unmatched`
(matched no answer-key entry — not the same claim as untrue), catalogued the 18 as `optional`
entries, and added score floors (`min_recall`/`max_unmatched` in `meta.txt`, read via
`scripts/score-eval.sh --meta`) so a case can state how much true-but-uncatalogued thoroughness it
is willing to accept. See `evals/README.md` for the full rationale.

## Precision is not measured

**No case** currently plants a **decoy** — a defect an agent might plausibly but wrongly report.
Without decoys, there is no way to distinguish "this finding is real but uncatalogued" from "this
finding is actually wrong": every `unmatched` finding across all three cases above was independently
adjudicated true by hand, but the scorer itself cannot tell the two apart, and won't be able to
until a case is built with decoys in it. That is a stated limitation of all three cases as they
exist today, not something this task's scorer changes address. See "Unmatched is not the same claim
as false" in `evals/README.md`.

**Nor does recall measure polarity.** `scripts/score-eval.sh` now refuses to match a findings line
that is an explicit conformance assertion ("no drift", "is correct", "looks correct", …), which
closes the cheapest way for a run to score full recall while denying every defect it was asked
about. It is a phrase list, not comprehension: a denial phrased another way still matches. So a
recall figure in this document is evidence, not proof, that the run asserted the defects rather than
denied them — the adjudication-by-hand above is what actually establishes that, for these five runs.
See "What substring matching cannot tell apart" in `evals/README.md`.
