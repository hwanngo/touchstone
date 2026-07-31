# Security Policy

touchstone is a repository of engineering standards, agent hooks, and quality gates that other
repositories adopt as a pinned submodule. It runs no service and holds no user data — but it does
ship code that executes on developer machines and in CI, and that code is what this policy covers.

## Reporting a vulnerability

**Do not open a public issue for a security report.**

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/hwanngo/touchstone/security/advisories/new)
(repository → *Security* → *Advisories* → *Report a vulnerability*).

No email address is published here on purpose. Private reporting keeps the report, the discussion,
the patch, and the eventual advisory in one place that is private until it is published — an inbox
gives none of that, and a published address is a permanent spam target that outlives whoever is
maintaining the repo.

A useful report says what an attacker can do, gives the smallest reproduction you have, and names
the tag or commit you tested.

Acknowledgement target is **2 business days**. Remediation targets by severity:

| Severity | Target fix |
|---|---|
| Critical | 48 hours |
| High | 7 days |
| Medium | 30 days |
| Low | 90 days |

Please allow a reasonable disclosure window before going public. Reporters are credited in the
advisory unless they ask not to be.

## Scope

The security-relevant surface is the code the kit executes on your machine or in your CI — not the
prose it ships.

| In scope | Why |
|---|---|
| `hooks/` | The Claude Code agent hooks. They run on a developer's machine with that developer's privileges and decide whether an agent-proposed command or file write is allowed. A bypass — an input that should be denied and is allowed — is a vulnerability here, not a feature request. So is anything that makes a hook silently stop guarding. |
| `scripts/` | Adoption and gate scripts. `bootstrap.sh` and `init.sh` write into an adopting repo; the `check-*.sh` gates run in CI. Arbitrary writes outside the target, or a gate that certifies a tree it never read, belong here. |
| `templates/` | Config the kit copies into adopting repos. A template that weakens a downstream repo — over-broad workflow `permissions:`, an unpinned or mutable action reference, a hook that silently no-ops — is in scope, because every adopter inherits it. |
| `tests/` | Only where a test conceals one of the above, e.g. a gate proven by a test that would pass with its fixtures deleted. |

**Out of scope**, and better sent as a normal issue or pull request:

- The advice in `standards/` and `skills/`. It is prose, not executable. Disagreeing with a
  recommendation is a standards discussion, not a vulnerability.
- Vulnerabilities in third-party tools the standards merely recommend — report those upstream, and
  open an issue here if the recommendation itself should change.
- Findings that presuppose an attacker who already controls the machine the hooks run on, or who
  can already push to this repository.

## Supported versions

The kit is versioned with SemVer (the `VERSION` file plus a `vX.Y.Z` tag) and adopters pin a
version. Fixes land on `main` and ship in the next release; there are no backport branches.

| Version | Supported |
|---|---|
| Latest release, and `main` | Yes |
| Any earlier release | No — re-pin to the latest release |
