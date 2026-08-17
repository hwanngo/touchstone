# Changelog

All notable changes to touchstone are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org) applied to the *standards* — see [CONTRIBUTING.md](CONTRIBUTING.md#releases)
for what bumps major/minor/patch.

Consumers pin a version (`touchstone@vX.Y.Z`) and read this file when re-syncing to see what changed.

## [Unreleased]

An eval-driven hardening pass: v0.2.0 gated whether a skill or agent *parses*; nothing checked
whether one *works*. This cycle built an eval harness that runs a subagent against a deliberately
broken fixture repo and scores its findings against a catalogued answer key, used it to find and fix
real defects in the two agents that shipped in v0.2.0, shipped four more agents evaluated the same
way, and ran a 177-attempt adversarial campaign against the Bash guard. The theme repeats from
v0.2.0: a check that examines nothing and reports success is worse than no check, and this cycle
found that failure mode **six times in its own eval system** before it found one in an agent.

### Added — the eval harness

- `scripts/score-eval.sh` — deterministic, offline scorer: turns a findings file plus an
  `answer-key.txt` into a `matched`/`unmatched`/`recall`/`verdict` report. **Score floors**
  (`min_recall:`/`max_unmatched:` in a case's `meta.txt`, via `--meta`) let a case accept honest,
  uncatalogued thoroughness instead of failing a run for finding more true defects than anyone wrote
  down — exact-match scoring made that impossible, and an early blind run against
  `standards-auditor` proved it: 100% recall, 18 additional findings, every one true on adjudication,
  scored FAIL anyway. See `evals/README.md`'s "Unmatched is not the same claim as false".
- `scripts/check-evals.sh` — validates every case under `evals/cases/`: well-formed `meta.txt` and
  `answer-key.txt`, numeric score floors required (not merely accepted), and the **phantom check** —
  every `required` answer-key entry must name a path that genuinely exists in the case's `repo/`
  fixture, so a case can't silently rot when its fixture drifts from its key. Also gates a **leak
  check**, added after a real leak was found (see below): `repo/` may never carry its own case id,
  "DELIBERATELY BROKEN", or similar provenance markers, because that content is the answer key,
  handed to the agent under test for free.
- `scripts/run-eval.sh` / `just eval <case> [findings]` — the model-dependent half. Requires
  `--confirm-model-call` (exits 3 without it) so pulling a live model call into the hermetic suite by
  accident is impossible, not just discouraged; `tests/gates/run-eval-guard.test.sh` asserts nothing
  in `tests/run.sh` calls it.
- Three eval cases (`evals/cases/{adopter-broken-toolchain,standards-gaps,stale-claims}/`) and
  `evals/BASELINE.md`, recording every blind run made against them, including the instrument defects
  those runs found in the scorer and the case format itself, not just in the agents.

### Added — four new agents

- `agents/adoption-doctor.md` — proves an adopting repo's installed toolchain actually works (can it
  commit, does `just lint` pass fresh, does `AGENTS.md` resolve), rather than merely being present.
- `agents/guardrail-redteam.md` — adversarially attacks a **scratch copy** of `hooks/` (never the
  live hooks) using their own source as the map, and reports every attempt with its verbatim input.
- `agents/drift-watcher.md` — scheduled counterpart to `currency-researcher`: sweeps every doc under
  `standards/` for staleness signals with no doc named in advance, verifies flagged candidates
  against a primary source, and reports a risk-ranked list.
- `agents/eval-runner.md` — drives the eval suite across every case and reports a regression verdict
  against `evals/BASELINE.md`.

All six agents in `agents/` are read-only reporters; `scripts/check-agents.sh` — which shipped in
v0.2.0, not this cycle — validates every definition and fails on zero agents examined.

### Changed — `level` is a conformance claim, not a target (read this if you already vendor touchstone)

`standards/self-audit.md`'s "Maturity levels" section said *"Declare your **target** in
`.touchstone.toml` (`level`)"*, while the rest of that file, and `agents/standards-auditor.md`, already
read the field as a statement of fact. One field, two meanings, and the permissive one is the one
adopters copied. It now has a single definition:

> `.touchstone.toml`'s `level` is a **conformance claim**, not a target: it declares the highest level
> at which every applicable item is already ✅, **and it is false the moment that stops being true.**

- **`0` is now a legal value**, meaning "conforms at no level". The maturity table defines L1–L4 only,
  so a repo with an open ❌ in L1 previously had nothing honest to write; the guidance is to say so
  plainly rather than rounding up to L1 because it is close.
- **The kit's own `level` went 4 → 0.** Re-derived item-by-item against the L1 checklist; four open,
  unwaived L1 fails, each now named inline in `.touchstone.toml`. The previous `4` was chosen under an
  `UNREVIEWED` marker and had never been derived from anything.
- **`scripts/init.sh` now scaffolds `level = 0` for new adopters, not `1`.** `init.sh` writes config;
  it verifies nothing, so `1` was a claim the tool had no basis to make on the adopter's behalf.
- `tests/gates/self-audit-levels.test.sh` gained `check_declared_level()` with ten fixtures (in range,
  out of range, negative, non-numeric, missing key, `UNREVIEWED`, the L4 ceiling, zero, …).

**Migration — what to do with your `level` value.** Nothing an adopter runs reads this field
(`check_declared_level()` lives in the kit's own test suite, not in `scripts/`), so nothing will break
and no gate will start failing. But your recorded `level` was correct as a *target* and is, unchanged
on disk, now a *false conformance claim*. **Re-derive it against `standards/self-audit.md`'s
checklist: if any applicable item up to your declared level is not ✅, lower it — and `0` is now
legal.** Under 0.x this is a MINOR bump, but by `CONTRIBUTING.md`'s own rule it is the MAJOR *class*
("a reversed rule that would make a previously-conforming repo non-conforming"), which is why it gets
a migration note rather than a line in a list.

### Fixed — real defects the eval harness found in shipped agents and cases

- `evals/cases/adopter-broken-toolchain/repo/` **leaked its own answer key**: its
  `.pre-commit-config.yaml` and `justfile` opened with comments naming the exact planted defect.
  Measured, not assumed: `adoption-doctor` found the justfile defect with the comments present and
  missed the same defect with them stripped. Provenance moved to each case's `NOTES.md`, outside
  `repo/`; `check-evals.sh`'s new leak check stops this from recurring silently, in this case or any
  other. No agent definition was edited — nothing proved `adoption-doctor` itself broken.
- The same case's answer key matched on coincidence twice: a `required` entry that any justfile
  finding mentioning both "justfile" and ".touchstone" could satisfy regardless of which defect it
  described, and later an `optional` entry that absorbed three unrelated absence-findings because
  they happened to cite the same file path mid-sentence. Both tightened to substrings specific to
  their intended finding's actual wording.
- `score-eval.sh` and `check-evals.sh` each dropped an answer key's or findings file's **last line**
  when it lacked a trailing newline, silently shrinking the required count — and, for a hand-written
  answer key, silently skipping the phantom check on exactly that entry. Fixed in both, with
  regression fixtures.
- `score-eval.sh` counted a findings file's **`#` provenance header as a finding**, so annotating a
  findings file with a date/model note inflated `unmatched` and flipped a genuine PASS to FAIL. That
  is why the three committed `reference-findings.txt` files originally shipped with no header at all
  — adding one would have silently broken their own score. Blank and `#` lines are now skipped, on
  the findings side only, and all three files now carry their provenance header.

### Fixed — the eval instrument: scoring that could not fail

The section above counts the "examined nothing, reported success" class six times in the eval system.
A subsequent whole-branch review found four more, all in the measurement path itself. Each is now
mutation-proven: the fix is removed, a named row goes red, the fix is restored.

- **The scorer was polarity-blind.** A findings file asserting every catalogued defect was *absent*
  scored `matched 2 of 2 / recall 100 / verdict PASS`, because a denial names the same file and uses
  the same vocabulary as a report. `score-eval.sh` now rejects a findings line containing any of a
  fixed list of **conformance-assertion phrases** ("no action needed", "no drift", "is correct",
  "looks correct", "is up to date", "correctly documented", …) as a match for any entry; the line
  still counts toward `unmatched`, which is the honest place for it. **This is a phrase list, not
  sentiment analysis, and it does not solve polarity** — a denial phrased another way still matches.
  `evals/README.md` now states that limit, with the residual example.
- **Two answer-key entry shapes made recall impossible to fail**, and no gate rejected either: an
  **empty** `<substring>` (matches every line), and a `<substring>` that is a substring of its own
  `<path>` — `required|standards/platform/caching.md|caching.md`, which shipped, and which reduced one
  of `stale-claims`' two required entries to "the agent mentioned this file". `check-evals.sh` now
  fails a case carrying either shape, `score-eval.sh` exits 2 on one rather than scoring it, and four
  shipped entries (one in `stale-claims`, three `optional` in `standards-gaps`) were given
  discriminating substrings.
- **The one check that catches answer-key drift ran only weekly.** The `reference-findings.txt`
  replay is deterministic, offline and takes milliseconds, but lived only in
  `.github/workflows/eval.yml`, so a one-character answer-key edit landed green and surfaced up to
  seven days later in a scheduled job nobody watches — while the branch had already shipped two
  coincidental-match answer-key bugs. It is now also
  `tests/gates/reference-findings-replay.test.sh`, in the blocking suite. Relatedly, the one hermetic
  test that read a real answer key built its findings *from that key* with
  `awk -F'|' '$1 == "required" { print $2 ": " $3 }'`, so every entry matched by construction and the
  assertion could never fail on answer-key content; it now reads the case's committed
  `reference-findings.txt`.
- **`run-eval.sh` exited 0 having scored nothing** when `--findings` named a missing path, a
  directory, or an unreadable file: the hand-off text had already printed, and the scoring branch
  simply fell through. `just eval <case> <typo-path>` therefore reported success having examined
  nothing — this repo's founding rule, broken in the eval runner. It now exits 2, while the empty
  `--findings ""` default (hand-off text only) stays exit 0.
- **The gate promising the hermetic suite never calls the model-dependent runner exempted the only
  file that calls it** — by filename, three times, twice with `--confirm-model-call`. The caller list
  is now compared for equality against the one expected path (so a second caller *and* the
  disappearance of the behavioural rows both go red), and the exemption's safety is itself asserted:
  `run-eval.sh` must contain no model or network command, so the first commit that gives it one turns
  that row red instead of shipping a silently non-hermetic suite.

### Fixed — the Bash guard, after a 177-attempt adversarial campaign

`guardrail-redteam` ran 177 attempts against a scratch copy of `hooks/` (never the live hooks; hard
rule 10) on opus, with no test files in the scratch tree so the attacker never saw the defender's
expectations: **55 confirmed bypasses, 6 false positives, 6 uncertain, 110 correctly handled.** Root
cause of the worst class: the command segmenter treated `{`, `}` and `|` as unconditional separators,
so a write command was split from its target and the `.env` guard never saw a target at all. 48
bypasses and all 6 false positives are now closed — every one promoted into `tests/hooks/*.test.sh`
as a regression probe first, then fixed at the matcher level, without regressing the guard's existing
no-false-positive coverage. Two bypasses stay open **by design**, documented in `hooks/README.md`:
`git push --mirror` (a policy call for the kit owner: it force-updates and deletes remote refs with
no lease, but is also the legitimate way to maintain a mirror) and ANSI-C quoting (the escaped
`$'\x2d\x2dforce'` / `$'\055\055force'` spellings — a verified live bypass under bash 3.2/`sh`/zsh,
deferred because closing it means interpreting the shell rather than matching its tokens, on the
piece of code where a mistake is most expensive; a bare `$'--force'` is *not* a bypass and denies).

**The arithmetic above does not close, and this release note will not pretend it does.**
55 − 48 closed − 2 open-by-design leaves **5 of the 55 confirmed bypasses with no stated
disposition here**, and the campaign record that would settle whether they are further spellings of
the two open classes or a third, undocumented class is an authoring-session artifact outside this
repository, so no reader of this file can check. Read "two remain open" as a **floor, not a total**.
The 6 `uncertain` attempts are the same: exactly one, `BS-024` (the four-dash spelling of the RSA
private-key header), has a recorded resolution — it denies, asserted in
`tests/hooks/block-secrets.test.sh` — and the other five have none. What *is* checkable from the repository: every closed attempt carries a regression row
named for its attempt id in `tests/hooks/*.test.sh`, so `grep -ho 'GB-[0-9]*\|BS-[0-9]*'
tests/hooks/*.test.sh | sort -u` is the auditable list of what was actually pinned down.

Two further guard defects were found by a whole-branch review after the campaign, and both were
introduced *by this cycle's own fixes*:

- **`GB-190` — an unquoted `<<` in arithmetic was mis-read as a heredoc operator and swallowed every
  following command line.** `n=$((1<<3))` followed by `git push --force origin main` **allowed**; the
  force-push alone denies. The heredoc delimiter scan stops at `)`, so `$((1<<3))` registered a
  heredoc with the delimiter `3`, no line ever equalled `3`, and the body-skip consumed the rest of
  the buffer — a two-line, ordinary-shell bypass of *every rule in the file*, silent, with no error
  and no exit status. This was the exact hazard the heredoc fix named as the reason detection lives
  inside the scanner, and it was live. Closed by two independent guards, one regression row each:
  arithmetic-context tracking (`<<` inside `$(( … ))`/`(( … ))` is left-shift), and "a delimiter with
  no terminator line ahead of it is not a heredoc at all" — which also closes the multi-line spelling
  the first guard cannot see. `hooks/README.md` documents both, and the one residual (an *unbalanced*
  unquoted `((`, which is a bash syntax error, suppresses a later heredoc's body-skip — a bounded
  false positive on input no shell will run).
- **`GB-191` — `git merge --no-verify-signatures` was denied, with a message saying `--no-verify` had
  been used.** A real option of `git merge` and `git pull`, unrelated to hooks, spelled with the
  `--no-verify` prefix — so the `--no-verbose` carve-out added earlier in this same cycle did not
  cover it, and `merge` had only just joined the subcommand set. A developer with
  `merge.verifySignatures=true` merging an unsigned topic branch was blocked *and* told the wrong
  reason. The matcher, not the message, was fixed: `--no-verify-*` joins `--no-verb*` as a carve-out,
  and `hooks/README.md`'s claim that `--no-verb…` was "the exact carve-out" is corrected — there are
  two. `--no-verify` and its unique abbreviations `--no-veri`/`--no-verif` stay denied.

Both flips were verified with `just diff-decisions 2ca7a18` over the 642-record corpus: 11 changed
decisions, 8 allow→deny (the `GB-190` bypass spellings) and 3 deny→allow (the `GB-191` false
positive), no other decision moved.

### Added — CI

- `.github/workflows/eval.yml` — a weekly (`schedule` + `workflow_dispatch`) workflow, **not** part
  of `ci-required`, that runs `check-evals.sh` and replays each case's committed
  `reference-findings.txt` through `score-eval.sh`. It never calls a model — see "Known limitations"
  below and `evals/README.md` for exactly what a green run there does and does not prove. Both of
  those checks are ALSO in the blocking suite (`check-evals.sh` in `just gates`, the replay in
  `tests/gates/reference-findings-replay.test.sh` under `just test`), so this workflow is a
  rot-detector rather than the only detector — see "Fixed — the eval instrument" below.

### Known limitations

- **Precision is not measured.** No eval case plants a **decoy** — a plausible defect that isn't
  actually present in the fixture — so every eval in this cycle shows these agents do not *miss*
  cataloged things; none establishes that they never *invent* things. On every run performed, the
  agents invented nothing (every unmatched finding was independently adjudicated true by hand). That
  is evidence, not proof, and it stays that way until a case is built with a genuinely plausible
  decoy in it.
- **`tests/run.sh` is not fully hermetic.** `tests/gates/pre-commit-hook-ids.test.sh` fetches hook
  metadata from `raw.githubusercontent.com` to verify pinned revs, so back-to-back runs — locally or
  in CI — can fail spuriously under rate-limiting. This contradicts the kit's own stated hermetic/
  offline constraint for the test suite and is a known source of CI flakiness, not yet fixed.
- **Two guard bypasses remain open by design** (see above and `hooks/README.md`): `git push --mirror`
  and ANSI-C quoting under zsh.
- **Nothing in this cycle has executed on a GitHub runner.** All verification, including
  `.github/workflows/eval.yml` itself, remains local, exactly as in v0.2.0.
- `currency-researcher`'s measured 100% recall (`evals/cases/stale-claims`) is against a **2-entry
  answer key** — thin evidence that the mechanism works, not a demonstrated ceiling. And it was
  thinner than that when the run was scored: one of the two entries had its substring inside its own
  path (`…/caching.md|caching.md`), so it could not distinguish the catalogued defect from any mention
  of the file. Both entries discriminate now, but the recorded 100% was **1 discriminating entry + 1
  file-mention entry**, not 2 of 2. The number was not re-measured against a model; only the key was
  fixed.
- **Polarity is only narrowed, not solved.** `score-eval.sh` rejects an explicit conformance
  assertion ("no drift", "is correct", …) as a match, which removes the cheapest way to score a
  perfect pass while denying every defect. A denial phrased any other way still matches. A nonzero
  recall is evidence, not proof, that a findings file asserts the defects rather than denies them —
  see `evals/README.md`'s "What substring matching cannot tell apart".
- Open agent-definition gaps recorded but not fixed this cycle (per the rule that a run which
  produces correct output does not get its agent edited on a hunch): `adoption-doctor`'s five checks
  assume adoption artifacts exist rather than being silent on total absence, and independently cited
  standards-doc sections it could not actually read in a partially-vendored fixture;
  `currency-researcher`'s evidence rules are written entirely around external primary sources and
  never mention the repo's own filesystem as a valid way to verify a repo-self-referential claim. See
  `evals/BASELINE.md` for both in full.

## [0.2.0] — 2026-07-31

A hardening pass over the gates, the agent hooks, and the adoption path. The theme throughout: rules
the kit stated but nothing enforced, and gates that could report success while examining nothing.

### Fixed — adoption (read this section first if you already vendor touchstone)

These were found by adopting the kit into a scratch project for the first time. Every one was
invisible from inside the kit, and the kit's own test suite was fully green while they shipped.

- **Adopters could not commit at all.** `templates/pre-commit-config.yaml` declared a hook id that
  does not exist at its pinned `rev`. pre-commit resolves ids at run time and aborts the whole run on
  the first unknown one, so every `git commit` failed, and the entire backstop — secret scanning,
  workflow linting, lockfile checks — never ran. All revs are now current and every id is verified
  against the upstream repo at its pinned rev by `tests/gates/pre-commit-hook-ids.test.sh`.
- **`just fmt` rewrote the pinned submodule** and `just lint` failed on the kit's own documents:
  the template's Python/Node/Go recipes ran over `.`, which includes `.touchstone/`. The shell
  recipes in the same file already excluded it; the exclusion is now applied consistently.
- **The Node gate could not run**, because the vendored `templates/biome.json` was discovered as a
  nested root config. It is now excluded, and `includes` no longer covers only `src/**` — the gate
  previously exited 0 having checked one file.
- **A workflow template pinned an action major that has never existed.** `pinact` stops at the first
  unresolvable ref, so one bad ref left every *other* action unpinned — a supply-chain gap disguised
  as a typo. Every `uses:` ref across the workflow templates is now verified to resolve.
- **The documented bootstrap command could not succeed**, since it defaults to a release tag that
  does not exist yet. It now diagnoses the cause, prints runnable alternatives, and the README says
  plainly that there is no release tag rather than documenting a command that fails.
- Adopters now receive the issue templates the kit's own checklist requires; `init.sh` shipped the
  PR template and CODEOWNERS but never the issue forms.

### Fixed — gates that could pass without checking anything

- `check-links.sh` **certified repositories it never read**: with `awk` unusable, every scan returned
  empty and the gate exited 0. It now refuses to run instead.
- `check-standards.sh` validated a fixed two-level glob, so `standards/self-audit.md` — the kit's
  flagship checklist — had never been validated in its life.
- `check-skills.sh` grepped at its inputs instead of parsing them, which let twelve unparseable
  frontmatter descriptions ship, and resolved pointers from only one location.
- `check-links.sh` and `check-skills.sh` could resolve paths outside the repository, and the four
  kit-only gates now refuse to certify a repo they were never pointed at, rather than reporting
  success about the kit while run from somewhere else.
- Secret scanning only ever examined the staged diff, so nothing scanned the repository or its
  history. CI now runs a full scan, proven against a planted credential.

### Fixed — the kit breaking its own rules

- CI installed a Node tool with `npx`, and the pre-commit template told adopters to install with
  `pipx` — both violating hard rule 1.
- Rule 9 banned committing generated artifacts while the kit committed a generated catalogue. The
  rule now carries one bounded exception, valid only while CI enforces the file's freshness.
- The adopter task-runner template disabled every gate with a leading `-`, which the kit's own
  runner forbids in capitals.

### Added

- `agents/` — `standards-auditor` and `currency-researcher`, with `scripts/check-agents.sh`.
- Self-adoption: the kit carries `.touchstone.toml`, and `check-sync.sh` gained a declared-divergence
  mechanism that pins both sides of each intentional kit-vs-template difference.
- Every checklist item in `standards/self-audit.md` now carries the maturity level at which it first
  becomes required, and bundled items spanning several levels have been split apart.
- Repo meta the kit requires of adopters and previously lacked itself: `SECURITY.md`, `CODEOWNERS`,
  PR and issue templates, `.pre-commit-config.yaml`.
- A `ci-required` aggregator job, `actionlint`, `pinact` and `zizmor` in CI.
- The test suite grew from 224 to 1113 assertions, with fixture-deletion and mutation drills so that
  a test which stops testing its subject fails loudly.

### Changed

- `next.md` rewritten for Next.js 16 — three of its code samples did not merely describe old
  behaviour, they fail to build on 16. `react.md` gained a React 19 baseline; `app-security.md`
  remapped to the OWASP Top 10:2025 revision.

### Known limitations

- Nothing here has executed on a GitHub runner; all verification was local.
- No `package.json` template exists, so a fresh adopter must install Biome before the Node gate runs.
- The Go toolchain was never exercised; its exclusions are inspection-only.
- The kit has no evaluation set for the skills and agents it ships. Every gate proves they parse;
  none evaluates what they produce.

## [0.1.0] — 2026-06-30

Initial release — an opinionated, tool-agnostic engineering-standards kit for humans and AI agents.

### Standards (`standards/`)

- **66 domain docs**, one per stack/area, each opinionated and mapping every rule to an enforceable
  gate — plus `self-audit.md` and two directory READMEs (`standards/README.md`,
  `standards/frameworks/README.md`), **69 standards docs** in total:
  - **Languages:** python · typescript · golang · rust · java-kotlin · csharp · swift · php · ruby ·
    elixir · zig · solidity · shell
  - **Frameworks:** react · next · nuxt · svelte · vue · angular · solid · astro · fastapi ·
    litestar · django · gin · node-backend · spring-boot · aspnet-core · rails · laravel · phoenix ·
    axum · react-native · flutter · swiftui · jetpack-compose
  - **Platform:** docker · devops · ci-cd · database · observability · terraform · kubernetes ·
    monorepo · caching · data-engineering · search
  - **Practices:** security · app-security · dependencies · testing-strategy · code-review ·
    code-quality · data-privacy · collaboration · git-workflow · performance · accessibility ·
    documentation · ai-engineering
  - **Design:** architecture · api-design · resilience · event-driven · graphql · grpc
  - **`self-audit.md`** — a scoring checklist + L1–L4 maturity model.
- **Versions are not hardcoded** — docs say "latest stable, verify" and keep only durable
  minimum-version floors, named features, and stable facts, so they don't rot.

### Skills (`skills/`)

- **61 Agent Skills** ([agentskills.io](https://agentskills.io) spec — `license` + `metadata`
  frontmatter): **60 content skills**, thin wrappers that surface the right standard on a matching
  edit/dependency/task, plus a `touchstone` router meta-skill. Every content skill follows the enforced
  `## Always`-first → domain sections → `## Done` spine. A generated `CATALOG.md` indexes them.

### Templates (`templates/`)

- Ready-to-copy configs (`biome.json`, `golangci.yml`, ruff/pytest snippet, `pre-commit-config.yaml`,
  `justfile`, `dependabot.yml`, `renovate.json`, `.dockerignore`, `.nvmrc`, `.python-version`),
  ready-to-copy GitHub Actions workflows (`ci`, `codeql`, `release-please`), `SECURITY.md`,
  ADR/issue/PR templates, and `CODEOWNERS`. The template workflows are **tag-pinned**; `pinact run`
  (see the README's setup steps) converts them to commit SHAs in the adopting repo. The kit's own
  `.github/workflows/` is SHA-pinned.

### Adoption & portability

- **`scripts/bootstrap.sh`** — one command vendors the kit as a pinned git submodule (`.touchstone`)
  and runs `init.sh` (no `curl | sh`). **`init.sh`** detects the stack, drops in templates + CI,
  writes a `.touchstone.toml` marker (idempotent — preserves your level/waivers), and **generates**
  single-source per-tool pointer files (`CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`,
  `.cursor/rules/touchstone.mdc`, `opencode.json`) that all defer to `AGENTS.md` — so Claude, Codex,
  Gemini, Cursor, Copilot, opencode, Pi, and Droid read the same rules with nothing duplicated and
  the kit root stays clean.

### Enforcement

- **Auditors:** `check-skills` (spec + spine), `check-standards` (doc template), `check-skill-quality`
  (advisory), `check-links`, `check-sync` (drift) — pure bash, zero install, wired into a hardened
  self-dogfooding CI (SHA-pinned Actions, least-privilege, shell + markdown lint, link + catalog
  checks). `bump-version.sh` sets the version everywhere at once.
- **Opt-in Claude Code agent hooks** (`hooks/`, installed into a repo via `init.sh --with-hooks`): inject the hard rules,
  guard against `--no-verify`/bare `--force`, block writing secrets, format on edit, audit touched
  instruction files, and nudge CI. All fail-open. `.claude-plugin/plugin.json` makes the kit
  installable as a Claude Code plugin.

[0.1.0]: https://github.com/hwanngo/touchstone/releases/tag/v0.1.0
