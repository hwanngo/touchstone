# touchstone task runner — the entrypoint AGENTS.md promises.
# NEVER prefix a gate line with `-`. That turns a gate into a guaranteed pass.

set shell := ["bash", "-uc"]

default: ci

# run the bash test suite
test:
    bash tests/run.sh

# shell + markdown lint
lint:
    find hooks scripts templates tests -name '*.sh' -print0 | xargs -0 shfmt -d -i 2
    find hooks scripts templates tests -name '*.sh' -print0 | xargs -0 shellcheck
    pnpm dlx markdownlint-cli2@0.23.2 "**/*.md"

# the standards/skills/link gates
gates:
    bash scripts/check-standards.sh
    bash scripts/check-skills.sh
    bash scripts/check-agents.sh
    bash scripts/check-links.sh
    bash scripts/check-skill-quality.sh
    bash scripts/check-evals.sh
    bash scripts/check-sync.sh

ci: lint test gates

# NOT part of `just ci`: it needs a model call, so it is neither hermetic nor offline.
# Evaluate an agent against an eval case; see evals/README.md.
eval case findings="":
    bash scripts/run-eval.sh --case {{ case }} --findings {{ findings }} --confirm-model-call

# Decision-differential gate for hooks/guard-bash.sh — NOT part of `ci`, and deliberately so:
# this is machinery for a human to run explicitly before landing any change to that one file
# (see the GATE comment in tests/tools/diff-decisions.sh), not a default-path gate that would
# slow every `ci` run. Compares <baseline> (a git revision, e.g. a parent commit SHA) against
# the current working tree's hooks/guard-bash.sh and prints every input where their allow/deny
# decision differs; every printed line must be an intended flip already documented in that
# round's spec, or it's a regression.
#   usage: just diff-decisions <baseline-git-revision>
diff-decisions baseline:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    # A whole DIRECTORY, not a bare temp file. The guard sources hooks/lib/*.sh relative to its
    # own path, so materializing it as a lone file left that lib missing, the baseline hook took
    # its degraded fail-open branch, and it ALLOWED EVERY INPUT — a comparison against a guard
    # that was switched off, which shows up as a rich diff rather than an obvious failure.
    # diff-decisions.sh now also refuses to run when either revision allows a control input.
    git show {{ baseline }}:hooks/guard-bash.sh >"$tmp/guard-bash.sh"
    mkdir -p "$tmp/lib"
    libs="$(git ls-tree -r --name-only {{ baseline }} -- hooks/lib || true)"
    for p in $libs; do
      case "$p" in *.sh) git show "{{ baseline }}:$p" >"$tmp/lib/${p##*/}" ;; esac
    done
    bash tests/tools/diff-decisions.sh "$tmp/guard-bash.sh" hooks/guard-bash.sh
