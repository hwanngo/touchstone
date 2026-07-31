---
name: accessibility-standards
description: Use when building or reviewing web UI, components, forms, or markup in a touchstone repo — semantic HTML, ARIA, keyboard/focus, contrast, alt text, motion, and the a11y CI gate. Triggers on JSX/HTML/template edits, new interactive widgets, forms, and a11y review. Targets WCAG 2.2 AA. Framework wiring lives in the react/next skills; this is the cross-cutting source of truth they defer to.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Accessibility (practice)

Full standard: **`standards/practices/accessibility.md`** (framework wiring layers on
`standards/frameworks/react.md` and `standards/frameworks/next.md`). Load-bearing rules inlined so this stays useful
standalone in `~/.claude/skills/`:

## Always
- **Target WCAG 2.2 Level AA** — it's the merge gate, not a stretch goal.
- **Semantic HTML first** — native `<button>`/`<a>`/`<label>`/landmarks before any custom widget; they ship keyboard, focus, and roles for free. One `<h1>`, never skip heading levels.
- **No ARIA is better than bad ARIA** — only to fill a genuine gap, follow the APG pattern exactly, and keep `aria-expanded`/`-selected`/state in sync. Never `aria-hidden` a focusable element.
- **Full keyboard operability** — logical focus order (no positive `tabindex`), visible `:focus-visible` ring, no traps (modals restore focus + close on Esc), a skip link, targets ≥ 24×24px.
- **Labels + announced errors** — real `<label>` (not placeholder); errors are text + `aria-describedby` + `aria-invalid`, never colour alone.
- **Contrast** 4.5:1 text / 3:1 large & UI, measured with a tool; `alt` on every image; honour `prefers-reduced-motion`; don't block zoom/reflow.

## Don't get burned
- **Automation catches only ~30–40% of WCAG issues.** `eslint-plugin-jsx-a11y` + jest-axe + Playwright/Lighthouse a11y are the floor — they can't judge meaningful alt text, logical focus order, or whether a custom widget works.
- **A manual keyboard pass + one screen-reader pass (NVDA/Firefox or VoiceOver/Safari) is mandatory** for any new interactive pattern; document the AT result in the PR.
- **Drive tests through roles and accessible names** (`getByRole`/`getByLabelText`), not test IDs — finding elements the way AT does is the a11y test.

## Done
WCAG 2.2 AA met · semantic HTML + valid ARIA · keyboard/focus/skip-link · labelled fields + announced errors · contrast & alt & reduced-motion · jsx-a11y + axe + Playwright/Lighthouse green in CI, zero violations · manual keyboard + screen-reader pass for new patterns. See `standards/practices/accessibility.md`.
