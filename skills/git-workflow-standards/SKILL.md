---
name: git-workflow-standards
description: Use when choosing a branching model, setting up releases/versioning, deciding monorepo vs polyrepo, or configuring branch protection/merge queues in a touchstone repo — covers trunk-based development, SemVer + release-please, repo topology, and Git LFS. Commit/PR hygiene and review mechanics live in the collaboration and code-review skills.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Git Workflow & Release Management Standards

Full standard: **`standards/practices/git-workflow.md`** in the touchstone repo (defers commit
conventions to `standards/practices/collaboration.md`, CI/branch-protection wiring to `standards/platform/ci-cd.md`). This skill
inlines the load-bearing rules so it stays useful when installed standalone in `~/.claude/skills/`:

## Always
- **Trunk-based development by default** — integrate into `main` via branches that live < ~2 days; keep `main` releasable at every commit.
- **Feature flags, not long-lived branches** — merge incomplete work behind a flag; the flag is the unit of in-progress isolation, not the branch.
- **Squash-merge + linear history** — one PR = one Conventional-Commit on `main`; rebase the branch onto `main`, never merge `main` into it; `--force-with-lease` only.
- **SemVer from Conventional Commits** — releases are annotated signed `vX.Y.Z` tags; `CHANGELOG.md` is generated via release-please/changesets, never hand-edited.

## Choosing the model & topology
- **GitFlow is discouraged** for continuous delivery (standing `develop`/`release` branches = long-lived divergence). The only sanctioned long-lived branch is `release/X.Y`, and only for versioned/on-prem products that must patch old majors.
- **Hotfixes go forward** on `main`; for supported older majors, land on `main` then `git cherry-pick -x` onto `release/X.Y` and tag — never fix only on the release branch.
- **Monorepo by default** for one product/team (atomic refactors, one dependency graph); polyrepo when components need independent release cadence, ownership, or security boundaries. CODEOWNERS keyed to teams, validated in CI.
- **At scale** _(scale-up)_: merge queue (CI on the `merge_group` event); sparse + `--filter=blob:none` partial checkout for large trees; vendor+pin shared internal code over submodules.
- **Git LFS** for large non-diffable binaries (tracked in `.gitattributes`) — a committed binary bloats every clone forever. Never commit secrets/artifacts.

## Done
Trunk-based with short-lived branches behind flags · squash + linear history · SemVer tags + generated CHANGELOG · merge queue + sparse checkout where scale warrants · LFS for binaries. See `standards/practices/git-workflow.md`.
