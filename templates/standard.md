# Example Standards

<!-- Canonical standards/ doc template. Copy to standards/<domain>/<file>.md.
     Modeled on the deepest existing docs (python.md, fastapi.md, resilience.md).
     See CONTRIBUTING.md "Authoring conventions" for the rules this encodes. -->

<1–2 line scope sentence: what this doc owns, and which sibling docs it DEFERS to instead of
repeating — link them inline with a relative path such as `../design/resilience.md`.>

> **One law:** <single load-bearing principle for this domain>.

---

## 1. Toolchain

| Concern | Tool | Notes |
|---|---|---|
| <version · pkg mgr · formatter · linter · type-checker · test runner · runtime> | **<tool>** | <one-line rationale + where configured> |

## 2. Everyday commands

```bash
# the exact commands; mark which one CI runs
```

## 3. <Topic>

<!-- Numbered `## N.` WITH the period. Opinionated, imperative bullets with a bold lead-in and a
     one-clause rationale. Prefer a table or a fenced (language-tagged) snippet over prose.
     Tag production-only guidance _(scale-up)_. Cross-link siblings rather than restating them. -->

- **<Rule>:** <why, in one clause>. <Prod-only? add _(scale-up)_.>

## Definition of done

<!-- Bare, unnumbered heading. EVERY standard ends here. Each checkbox mirrors a rule above and
     maps to an enforceable gate — a CI command, a lint flag, a review check. No checkbox without
     a rule; no rule without a checkbox. -->

- [ ] <gate 1>
- [ ] <gate 2>

<!-- **Sources:** [ref](https://example.com) · [ref](https://example.com)   ← include if the doc leans on external references -->
