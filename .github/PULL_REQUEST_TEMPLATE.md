<!-- touchstone's own PR template. What adopters get is templates/github/pull_request_template.md,
     which is the generic starter; this one is checked against the kit's own gates. -->

## What & why

<!-- One paragraph: what this changes and the motivation. Link the issue. -->

Closes #

## How

<!-- Decisions a reviewer needs: which standard this follows, and why this shape rather than
     the obvious alternative. -->

## Checklist

- [ ] Conventional Commit title (`feat:` / `fix:` / `docs:` / `refactor:` / `chore:`), atomic
      commits, branch + PR — never a push straight to `main`
- [ ] `just ci` (lint + test + gates) is green locally and its output is pasted in this PR —
      evidence before assertions
- [ ] Shell stays bash 3.2-safe (no `mapfile`/`readarray`, no `declare -A`, no `${var,,}`, no `**`
      globstar) and passes `shfmt -d -i 2` and `shellcheck`
- [ ] New or changed behaviour has a case under `tests/`, and that case was shown to fail before
      the change — a test that never went red proves nothing
- [ ] No gate can pass vacuously: zero inputs examined is a failure, gate lines are never prefixed
      with `-` in the justfile, and no gate was weakened to make this PR green
- [ ] Changed a standard? The matching `skills/` wrapper and `templates/` file changed in the same
      PR so they cannot drift
- [ ] Changed a file the kit also ships as a template? `scripts/check-sync.sh` is green —
      re-declare intentional divergence with `scripts/check-sync.sh --print-diverge <path>` *after*
      committing the change, since it reads the working tree
- [ ] Docs/README updated in the same PR as the behaviour they describe, and prose claims about the
      kit's own contents still match the filesystem
- [ ] Nothing hard rule 9 forbids is committed: no secrets, no per-developer AI-assistant
      scratch/settings, no AI-generated TDD/SDD planning docs. Generated artifacts stay out of git
      too, with one sanctioned exception — a deterministic file, marked as generated, whose
      freshness CI enforces by regenerating it and failing on any diff (e.g. `skills/CATALOG.md`)
- [ ] Guardrails left on: no `git commit --no-verify`, no bare `git push --force`
      (`--force-with-lease` only), no agent hook disabled or routed around
- [ ] Version and CHANGELOG handled if this changes the standards themselves
      (`scripts/bump-version.sh`; see CONTRIBUTING for the SemVer bump rules)
