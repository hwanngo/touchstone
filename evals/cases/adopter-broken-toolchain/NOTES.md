# Maintainer notes — adopter-broken-toolchain

This file carries the provenance that used to live as comments inside `repo/`. It was moved out
because an agent under test is pointed at `repo/` only — comments there naming the case, the defect
class, or the fixture's own status are not "realistic clutter", they are the answer key, handed to
the agent for free. `scripts/check-evals.sh` now gates this (the "leak check" — see its comments)
so a case can never regress back to leaking its own provenance into `repo/`.

## Measured leak (2026-08-17, sonnet, blind runs of `adoption-doctor`)

Two blind runs were scored against this case: once with the fixture exactly as committed at the
time (its `.pre-commit-config.yaml` and `justfile` each opened with a `# DELIBERATELY BROKEN —
fixture for evals/cases/adopter-broken-toolchain, reproducing a real touchstone v0.2.0 defect...`
comment block naming the exact defect), and once against a copy of `repo/` with those comments
stripped. **With the comments present, the run found the justfile's `.touchstone/` lint-scope
defect. With them stripped, it did not.** That is a measured instrument leak, not a hunch: the
comment was doing the diagnosis instead of the agent.

Both runs found the `.pre-commit-config.yaml` defect on their own (correctly identifying that
`ruff-check` does not exist at `rev: v0.8.0`, and naming the real hook ids) — that defect was never
hint-dependent, which is part of why the leak on the *other* defect was detectable at all: it gave
a clean before/after comparison.

## The two real defects this case reproduces

Both are real touchstone v0.2.0 defects, found only from outside the kit during the v0.2.0
hardening round:

- **`git commit` aborts immediately.** `.pre-commit-config.yaml` names hook id `ruff-check` at
  `rev: v0.8.0`. `v0.8.0` is a real `astral-sh/ruff-pre-commit` tag, but at that rev the hook id was
  `ruff` (and `ruff-format`), not `ruff-check` — `ruff-check` did not exist until v0.9.x. pre-commit
  resolves every hook id at run time and aborts the **whole run** — not just this hook — on the
  first unresolvable one, so `git commit` fails for every change in this repo, not just changes
  touching Python.
- **`just lint` walks the vendored kit.** The `justfile`'s `lint` recipe runs `ruff check .` and
  `ruff format --check .` with no `.touchstone/` exclusion. Once touchstone is vendored as a
  submodule at `.touchstone/` (as `repo/.touchstone/` now demonstrates — see below), the recipe
  lints the vendored kit's own source as if it were this repo's code: failing the adopter's gate on
  files they do not own, and never finishing in reasonable time on a repo of any size.

## Why `repo/.touchstone/` now has real content

The defect above used to be *latent*: `repo/` had no `.touchstone/` directory at all, so the claim
that `lint` "walks the vendored kit" was inferable only from the (leaking) comment, not from
anything actually observable in the fixture — which is exactly why the hint-free run missed it. The
fixture now carries a small `.touchstone/` tree (`standards/README.md`, `standards/self-audit.md`,
and `scripts/bootstrap_helper.py` — the last one an intentionally-unused-import Python file, so
`ruff check .` genuinely flags something inside `.touchstone/` once the tool is available) so the
defect is diagnosable from evidence: read the justfile, see the unscoped `ruff check .`, see that
`.touchstone/` exists and carries real files. `evals/README.md`'s "`evals/cases/*/repo/**` is
deliberately malformed" section already excludes this tree from `check-links.sh` and markdownlint;
that exclusion also covers the new `.touchstone/` content, so it does not turn `just lint` red for
this kit itself.

## Answer-key substring choices (why they resist coincidental matches)

- `required|.pre-commit-config.yaml|hook id` — unchanged; both runs' genuine findings about the
  pre-commit defect contain the phrase "hook id", and no other line in either preserved findings
  file pairs `.pre-commit-config.yaml` with that phrase.
- `required|justfile|vendored kit` — replaces the old `required|justfile|.touchstone` entry, which
  the hint-free run satisfied on the finding "justfile: no \`fmt\` recipe exists, so there is no
  formatter step that could be scoped to exclude .touchstone/" — a *different*, true finding that
  merely happened to contain both "justfile" and ".touchstone". `.touchstone` is too generic a
  token: multiple true, unrelated justfile findings mention it (the fmt-recipe gap, the
  `.touchstone` absence). "vendored kit" is specific to the lint-scope defect's actual mechanism
  (linting the kit's own source once
  vendored) and appears in exactly one line of either preserved findings file — the genuine hinted
  finding. It does not appear anywhere in the hint-free file, which is the correct, honest result:
  the hint-free run genuinely missed this defect.

## Optional-entry catalogue (Defect 3)

Every uncatalogued finding in both preserved runs was checked by hand against the fixture as it
stood at run time and found true: no `.git`, no `.touchstone/` (before this task's fix), no
`AGENTS.md`, no `scripts/init.sh`, no `scripts/check-sync.sh`, no `.github/workflows/ci.yml`
(hint-free run only), no `setup` recipe, no `fmt` recipe, `ruff` undeclared so `just lint` exits 127,
and (hint-free run only) the installed gate cannot distinguish a bad probe from a clean tree. All are
now catalogued as `optional` entries in `answer-key.txt`, each with a substring chosen to match only
its intended line (verified against both preserved findings files with `scripts/score-eval.sh`).
`max_unmatched: 2` leaves a small, deliberately nonzero buffer for genuine thoroughness beyond this
catalogue, while still failing a run that hallucinates or pads with unrelated claims — see
`task-6b-report.md` for what a failing run looks like under these floors.

## `reference-findings.txt`

Committed verbatim from the **fresh blind run (Task 6c)** described above and in
`evals/BASELINE.md` — `agent: adoption-doctor`, model **sonnet**, run **2026-08-17**, against the
current (post-leak-fix) `repo/`. It is not the hinted or nohint run (those were measured against a
different, pre-fix fixture and are preserved only as historical text in `evals/BASELINE.md`).

`.github/workflows/eval.yml` replays this file through `scripts/score-eval.sh` on a schedule. That
replay only proves `answer-key.txt` and `scripts/score-eval.sh` still agree on this frozen text — it
re-runs no model and says nothing about whether `agents/adoption-doctor.md` would still find these
defects today. See `evals/README.md`'s "Reference findings and what the scheduled workflow proves"
section.
