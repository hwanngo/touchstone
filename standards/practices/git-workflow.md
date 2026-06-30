# Git Workflow & Release Management Standards

How code flows from a branch to a tagged release: the branching model, merge strategy, versioning,
and repo topology. Commit conventions, the branch/PR hygiene basics, and repo meta live in
[collaboration.md](collaboration.md); review mechanics in [code-review.md](code-review.md); the CI
wiring for branch protection and release tooling in [ci-cd.md](../platform/ci-cd.md). This doc owns
the **strategy** those docs enforce.

> **One law:** keep `main` releasable at every commit — short-lived branches, linear history, and
> automation cut the releases.

---

## 1. Branching model — trunk-based by default

**Trunk-based development is the default.** Everyone integrates into one shared branch (`main`)
through short-lived branches; `main` is always releasable.

- **Short-lived branches:** a branch lives **< 1–2 days**, then merges or is abandoned. The longer
  it lives, the more it diverges and the more painful the merge — the whole point is to integrate
  before drift sets in.
- **Feature flags over long-lived branches:** merge incomplete work to `main` *behind a flag*
  rather than parking it on a branch for weeks. The flag — not the branch — is the unit of
  in-progress isolation, so integration happens continuously and the release stays decoupled from
  the rollout.
- **Why not GitFlow:** its standing `develop`/`release`/`feature` branches add long-lived
  divergence and a manual promotion ceremony that fights continuous delivery. Use it only for the
  escape hatch below — not as the day-to-day model.

### Escape hatch — release branches for versioned/on-prem products

If you ship **versioned artifacts customers pin to** (libraries, on-prem/self-hosted, firmware) and
must patch old majors, cut a `release/X.Y` branch *at the tag* and cherry-pick fixes back (see §5).
This is the only sanctioned long-lived branch — SaaS on continuous delivery does not need it.

| Model | Use when | Long-lived branches |
|---|---|---|
| **Trunk-based** (default) | SaaS / continuously deployed services | `main` only |
| **Release branches** _(escape hatch)_ | Versioned libraries, on-prem, multiple supported majors | `main` + `release/X.Y` |

## 2. Merge strategy & history

- **Squash-merge is the default.** One PR becomes one atomic commit on `main`, so history reads as
  one logical change per line and `git bisect`/`revert` operate on whole features. The squash
  subject must be a Conventional Commit (see [collaboration.md](collaboration.md)) — release
  automation parses it.
- **Rebase your branch, don't merge `main` into it.** Keep the branch a clean stack of commits on
  top of current `main`; this avoids "merge `main`" noise commits and keeps the eventual diff
  honest. Rebasing rewrites history, so push with `--force-with-lease`, **never** bare `--force`
  (rationale in [collaboration.md](collaboration.md)).
- **Linear history, enforced.** Require linear history in the branch ruleset so no merge commits
  reach `main`. A flat first-parent line makes `git log`, `bisect`, and revert deterministic.
- **No merge commits on `main`**, no "merge back from `main`" commits, no WIP/`fixup!` commits
  surviving to `main` — clean them with an interactive rebase before review.

## 3. Branch protection, required checks & merge queues

The *enforcement* (Repository Rulesets, the `ci-required` aggregator, CODEOWNERS) is specified in
[ci-cd.md](../platform/ci-cd.md) §4, §8. The **policy** it must encode:

- **`main` is protected:** no direct pushes, no force-push, no deletion; PR + ≥1 code-owner review;
  required status check = the single aggregator; linear history on.
- **Require branches be up to date** before merge so checks reflect the post-merge tree — but at
  volume this serialises merges (every merge invalidates the next PR's "up to date" status).

### Merge queue _(scale-up)_

Past a handful of PRs/day, a **merge queue** is the release train: GitHub batches PRs, tests each
against the *projected* post-merge `main`, and merges only green batches — keeping `main` green
without forcing every author to rebase-and-retest serially.

- Adopt it once "update branch → re-run CI → someone else merged first" becomes a routine tax
  (roughly **>10 active engineers** or **>20 PRs/day** on one branch).
- CI must trigger on the **`merge_group`** event, not just `pull_request`, or queued batches never
  get tested. Require the same aggregator check on the merge group.

```yaml
on:
  pull_request:
  merge_group:            # required: the queue tests batches via this event
```

## 4. Versioning & releases

- **SemVer `MAJOR.MINOR.PATCH`** for every published artifact. The bump is a **contract signal**,
  not a vibe: MAJOR = breaking change, MINOR = backward-compatible feature, PATCH = fix. Map the
  Conventional-Commit type to the bump (`feat:` → MINOR, `fix:` → PATCH, `!`/`BREAKING CHANGE` →
  MAJOR) so the version is *derived*, never hand-picked.
- **Tags are the source of truth.** A release is an **annotated, signed** tag `vX.Y.Z` on `main`;
  the artifact and changelog are built from it. Tags are immutable — never move or delete a
  published tag (the 2025 tj-actions incident moved tags onto malicious commits; see
  [ci-cd.md](../platform/ci-cd.md) §4).
- **Automate the cut.** **release-please** (or **changesets** for JS monorepos) maintains a
  standing release PR — version bump + `CHANGELOG.md` + tag on merge. Keep the human merge-gate;
  the tooling wiring lives in [ci-cd.md](../platform/ci-cd.md) §11. Do not bump versions by hand.
- **`CHANGELOG.md` is generated**, Keep-a-Changelog format, from Conventional Commits — never
  maintained manually. Reversed/removed behaviour ships with a migration note.

### Pre-release channels

Ship ahead of a stable cut with SemVer pre-release identifiers and matching dist-tags so early
adopters opt in and the `latest`/stable channel stays clean.

| Channel | Tag example | Audience |
|---|---|---|
| Stable | `v2.4.0` | Everyone; the default install |
| Release candidate | `v2.4.0-rc.1` | Pre-release verification |
| Next / canary | `v2.5.0-next.3` | Opt-in early adopters (npm `--tag next`) |

## 5. Hotfix & backport flow

- **Trunk default:** a production bug is fixed **forward** — patch on `main`, let automation cut the
  next PATCH. Don't open a side-branch when you control the only running version.
- **Supported older majors** _(escape hatch)_: land the fix on `main` first (so it never regresses),
  then **cherry-pick onto the affected `release/X.Y` branch** and tag a patch there. Never fix only
  on the release branch — the next major would silently reintroduce the bug.

```bash
git switch release/2.3
git cherry-pick -x <sha>     # -x records the source commit for traceability
git tag -s v2.3.4 -m "fix: …"
```

- Automate the backport where possible (e.g. a `backport release/2.3` PR label) so it isn't a
  manual scramble during an incident.

## 6. Repo topology — monorepo vs polyrepo

Pick deliberately; the choice drives CI, ownership, and release shape.

| | **Monorepo** | **Polyrepo** |
|---|---|---|
| Atomic cross-cutting change | One PR | Coordinated PRs across repos |
| Dependency/version skew | Eliminated (one tree) | Real risk; needs version discipline |
| CI cost | Needs affected-graph builds (Nx/Turbo/Bazel — [ci-cd.md](../platform/ci-cd.md) §3) | Naturally scoped per repo |
| Ownership boundary | CODEOWNERS by path | Repo = boundary |
| Release | Per-package (changesets) or tag-per-path | One artifact per repo |
| Tooling at scale | Sparse checkout, partial clone, VFS | Standard git |

- **Default to a monorepo** for one product/team — atomic refactors and a single dependency graph
  outweigh the tooling cost. Reach for polyrepo when components have **independent release cadences,
  ownership, or security boundaries**.
- **CODEOWNERS at scale:** key to **teams, not individuals**, with a catch-all fallback and the
  most-specific path winning. In a monorepo this *is* the ownership map. Validate it in CI — invalid
  lines are silently ignored (see [code-review.md](code-review.md), [ci-cd.md](../platform/ci-cd.md) §8).
- **Sparse checkout + partial clone** _(scale-up)_: don't make every dev check out a 30 GB tree.
  Clone blobless and sparse, then expand to the paths you touch:

  ```bash
  git clone --filter=blob:none --sparse git@github.com:org/monorepo.git
  cd monorepo && git sparse-checkout set packages/api packages/shared
  ```

- **Submodules vs vendoring:** prefer **vendoring** (copy the code in, pin the version, let
  Dependabot bump it — see [dependencies.md](dependencies.md)) for shared internal code; it keeps
  one checkout and one CI run. Reach for **submodules** only when a separate repo's history and
  access boundary must stay distinct — they add a second commit to track and a routine
  `--recurse-submodules` footgun.

## 7. Large files & repository hygiene

- **Git LFS for binaries.** Anything large and non-diffable — media, datasets, design assets,
  compiled fixtures — goes through **Git LFS**, tracked in `.gitattributes`. Git stores deltas
  badly for binaries; a committed binary bloats every clone **forever**, because history is
  immutable. Decide *before* the first commit.

  ```bash
  git lfs track "*.psd" "*.mp4" "fixtures/**/*.bin"   # writes .gitattributes — commit it
  ```

- **Never commit** secrets, build artifacts, or per-developer AI-assistant scratch — the `.gitignore` policy and
  rationale live in [collaboration.md](collaboration.md) §3. A secret in history is compromised even
  after deletion; rotate it and scrub with care (back it with secret scanning — [security.md](security.md)).
- **A bloated `.git` is a clone/CI tax on everyone, every day.** If a large blob or secret already
  landed, rewriting history (`git filter-repo`) is a coordinated, force-push-everyone event — treat
  it as an incident, not routine cleanup.

## Definition of done

- [ ] Trunk-based: branches short-lived (< ~2 days) and merged behind flags; no GitFlow `develop` branch (release branches only for versioned/on-prem products)
- [ ] Squash-merge default; branch rebased (not merged) onto `main`; linear history required in the ruleset
- [ ] `main` protected: no direct/force push, ≥1 code-owner review, aggregator required check ([ci-cd.md](../platform/ci-cd.md) §4)
- [ ] Merge queue wired with the `merge_group` event once PR volume warrants it _(scale-up)_
- [ ] Versioning is SemVer derived from Conventional Commits; releases are annotated signed `vX.Y.Z` tags; `CHANGELOG.md` generated, never hand-edited
- [ ] Hotfixes go forward on `main`; supported majors patched via `cherry-pick -x` onto `release/X.Y`
- [ ] Monorepo CODEOWNERS keyed to teams with a fallback and validated in CI; sparse/partial checkout documented for large trees _(scale-up)_
- [ ] Internal shared code vendored + pinned by default; submodules only where a separate access boundary requires it
- [ ] Large binaries tracked via Git LFS in `.gitattributes`; no secrets or build artifacts in history

**Sources:** [GitHub: merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue) · [trunkbaseddevelopment.com](https://trunkbaseddevelopment.com/) · [Git sparse-checkout](https://github.blog/open-source/git/bring-your-monorepo-down-to-size-with-sparse-checkout/) · [release-please](https://github.com/googleapis/release-please)
