# Accessibility (a11y) Standards

How to build web UIs everyone can use — the cross-cutting standard that owns **what** "accessible"
means and **how** the team gates it. Framework mechanics defer to
[../frameworks/react.md](../frameworks/react.md) and [../frameworks/next.md](../frameworks/next.md);
test placement and the pyramid to [testing-strategy.md](testing-strategy.md); the human review pass
to [code-review.md](code-review.md). This doc is the canonical home — those docs link here.

> **One law:** semantic HTML first; ARIA only to fill genuine gaps — a wrong `role` is worse than none.

---

## 1. Baseline & legal context

**Target [WCAG 2.2](https://www.w3.org/TR/WCAG22/) Level AA. It is the gate, not an aspiration.**
Every shipped surface meets all Level A + AA success criteria; AAA is opt-in for high-stakes flows.

- **WCAG 2.2 added AA criteria you must now meet** — bake these into review (§ in parens):
  Focus Not Obscured (2.4.11, §4), Target Size 24×24 CSS px (2.5.8, §4), Dragging Movements
  has a single-pointer alternative (2.5.7), Consistent Help (3.2.6), Redundant Entry (3.3.7, §5),
  Accessible Authentication — no cognitive-function test like solving a puzzle (3.3.8, §5).
- **Legal context (brief, not advice):** US **ADA** — the DOJ's 2024 Title II rule binds state/local
  government to WCAG 2.1 AA; courts read Title III (private business) against WCAG too. EU **EN 301 549**
  (the basis of the European Accessibility Act, enforceable **June 2025**) references WCAG AA.
  Targeting 2.2 AA satisfies the lot. _(scale-up: get a VPAT/accessibility conformance report for
  procurement and public-sector sales.)_

## 2. Semantic HTML first

**The right element ships keyboard behaviour, focus, roles, and states for free.** Reach for a native
control before anything custom; you cannot out-engineer the platform.

| Need | Use (native) | Don't |
|---|---|---|
| Action | `<button>` | `<div onClick>` (no focus, no Enter/Space, no role) |
| Navigation | `<a href>` | `<span>` + JS router push with no `href` |
| Form field | `<input>`/`<select>`/`<textarea>` + `<label>` | unlabeled `<div contenteditable>` |
| Disclosure | `<details>`/`<summary>` | hand-rolled show/hide |
| Page regions | `<header> <nav> <main> <aside> <footer>` | `<div class="header">` |

- **One `<main>`, landmarks for the rest.** Wrap regions in landmark elements so screen-reader users
  jump by region; give repeated landmarks (`<nav>`) an `aria-label` to tell them apart.
- **Headings describe structure, not size.** Exactly one `<h1>` per page; never skip a level
  (`<h2>`→`<h4>`) to get a font size — style with CSS. Headings are the #1 screen-reader navigation aid.
- **Name every control by its accessible name**, not just visual proximity — icon-only buttons get an
  `aria-label`; decorative SVGs get `aria-hidden="true"`.

```html
<header><nav aria-label="Primary"><!-- links --></nav></header>
<main>
  <h1>Invoices</h1>
  <button type="button" aria-label="Filter invoices"><svg aria-hidden="true">…</svg></button>
</main>
```

## 3. ARIA: no ARIA is better than bad ARIA

**ARIA changes what assistive tech announces but adds zero behaviour** — you still wire the keyboard,
focus, and state yourself. Most ARIA in the wild is wrong and actively misleads users.

- **First rule of ARIA: don't.** If a native element or attribute exists, use it. Only reach for ARIA
  to build a pattern HTML can't express (tabs, combobox, tree) — and then follow the
  [APG](https://www.w3.org/WAI/ARIA/apg/patterns/) pattern exactly, keyboard interactions included.
- **Never put a role that fights the element** (`<button role="link">`), and never `aria-hidden="true"`
  on a focusable element — it strands keyboard users on an invisible control.
- **Announce async changes with a live region** (`aria-live="polite"`, or `role="status"`/`role="alert"`)
  — toasts, validation results, and search counts are silent to screen readers otherwise. The region
  must exist in the DOM before you write to it.
- **State must be live**: keep `aria-expanded`, `aria-selected`, `aria-checked`, `aria-current` in sync
  with the actual UI on every change — a stale state attribute is a lie the user acts on.

## 4. Keyboard accessibility

**Everything operable by mouse is operable by keyboard alone, in a sane order, with a visible focus
indicator.** Test the whole flow with Tab/Shift-Tab/Enter/Space/Esc/arrows — no mouse.

- **Focus order follows DOM order; don't fight it with `tabindex`.** Only `tabindex="0"` (adopt) and
  `tabindex="-1"` (programmatic focus target) are allowed — **never a positive `tabindex`**, which
  desyncs tab order from reading order.
- **Visible focus, always.** Never `outline: none` without an equal-or-better replacement; a `:focus`
  ring must meet 3:1 contrast against its background, and `:focus-visible` is the modern selector. Per
  WCAG 2.2, the focused element must not be hidden behind sticky headers/footers (Focus Not Obscured).
- **No keyboard traps.** Focus can always leave a component via the keyboard. Modals are the exception
  by design: trap focus *inside* while open, restore focus to the trigger on close, and close on `Esc`.
- **Skip link first.** A "Skip to main content" link as the first focusable element lets keyboard and
  screen-reader users bypass the nav — visually hidden until focused.
- **Targets ≥ 24×24 CSS px** (WCAG 2.2 Target Size, AA) with adequate spacing; 44×44 for primary
  touch targets _(scale-up)_.

```html
<a href="#main" class="skip-link">Skip to main content</a>
<!-- .skip-link { position:absolute; left:-9999px } .skip-link:focus { left:0 } -->
```

## 5. Forms: labels, errors & instructions

**Every input has a programmatic label; every error is text, tied to its field, and announced.**
Pairs with the React Hook Form + Zod setup in [../frameworks/react.md](../frameworks/react.md) §8.

- **A real `<label for>` (or wrapping label)** — `placeholder` is not a label (it vanishes on input and
  fails contrast). Group related controls in `<fieldset>`/`<legend>` (radios, address blocks).
- **Errors don't rely on colour or icons alone:** show text, link it with `aria-describedby`, mark the
  field `aria-invalid="true"`, and move focus to (or summarise at) the first error on submit.
- **Instructions and required-ness before the input**, programmatically associated — not implied by a
  red asterisk only. Use `aria-describedby` for hints/format requirements.
- **WCAG 2.2:** don't force users to re-enter info they already gave in the same flow (Redundant Entry),
  and don't gate login behind a cognitive puzzle — allow paste, password managers, and email/OAuth
  (Accessible Authentication).

```html
<label for="email">Email</label>
<input id="email" type="email" required aria-describedby="email-err" aria-invalid="true" />
<p id="email-err" role="alert">Enter a valid email address.</p>
```

## 6. Colour & contrast

**Contrast is a measured gate, and colour is never the only signal.** Verify ratios with a tool
(browser DevTools contrast checker, axe) — don't eyeball them.

| Element | Minimum ratio (AA) |
|---|---|
| Body text (< 18.66px / < 24px) | **4.5:1** |
| Large text (≥ 24px, or ≥ 18.66px bold) | **3:1** |
| UI components & graphical objects (borders, icons, focus ring, chart bars) | **3:1** |

- **Never encode meaning in colour alone** (WCAG 1.4.1) — pair the red error state with text/an icon,
  the green/red status with a label or shape, the required field with a word. Test in greyscale.
- **Links in body text need a non-colour cue** (underline) or 3:1 contrast against the surrounding text
  *and* a hover/focus distinction.
- **Don't ship contrast as a token afterthought** — bake AA-passing pairs into the design-system palette
  so misuse is impossible, not policed per component.

## 7. Images, media & motion

- **Every `<img>` has `alt`.** Informative images describe content/function concisely; decorative ones
  get `alt=""` (empty, not missing) so AT skips them. Complex images (charts) need a longer text
  alternative nearby. Don't start alt with "image of".
- **Video/audio:** captions for all pre-recorded audio (WCAG 1.2.2, AA), and an audio description or
  transcript where visuals carry meaning (1.2.5). Captions are content, not a stretch goal.
- **Honour `prefers-reduced-motion`.** Gate non-essential animation, parallax, and auto-playing
  transitions behind the media query; provide a still alternative. Nothing flashes more than 3×/sec
  (seizure risk, WCAG 2.3.1). Auto-playing motion/audio > 5s needs a pause control.

```css
@media (prefers-reduced-motion: reduce) {
  *, ::before, ::after { animation-duration: .01ms !important; transition-duration: .01ms !important; }
}
```

## 8. Responsive, zoom & reflow

- **Reflow at 400% zoom / 320 CSS px wide without 2D scrolling** (WCAG 1.4.10, AA) — content reflows to
  a single column; no horizontal scroll for vertical text. This is the same discipline as mobile-first.
- **Never block zoom**: no `user-scalable=no` or `maximum-scale=1` in the viewport meta. Content must
  scale to 200% without loss of function (1.4.4).
- **Text-spacing override (1.4.12) survives:** the layout doesn't clip or overlap when users bump line
  height, letter/word spacing — don't pin heights on text containers.

## 9. Testing: automated, manual & AT

**Automation is necessary and nowhere near sufficient.** Axe-class tools catch only **~30–40%** of WCAG
issues — they verify machine-checkable rules (missing `alt`, low contrast, bad ARIA) but *cannot* judge
whether alt text is meaningful, focus order is logical, or a custom widget actually works. Manual +
assistive-tech testing is mandatory, not optional. Layer it ([testing-strategy.md](testing-strategy.md)):

| Layer | Tool | Catches |
|---|---|---|
| Static (lint) | **`eslint-plugin-jsx-a11y`** (or Biome's `a11y` domain) | bad JSX a11y at author time |
| Unit/component | **jest-axe / `axe-core`** in RTL tests | rule violations in rendered components |
| Page/CI | **Playwright + `@axe-core/playwright`**, or **Lighthouse-CI** a11y category | violations on real routes |
| Manual | **keyboard-only pass** + greyscale + 200%/400% zoom | focus order, traps, colour-only, reflow |
| AT | **NVDA + Firefox** (Windows), **VoiceOver + Safari** (macOS/iOS) | what a screen-reader user hears |

- **One axe engine, two homes:** jest-axe at the component layer for fast feedback, `@axe-core/playwright`
  at the page layer for real-DOM/route coverage — same ruleset, different blast radius.
- **Drive assertions through roles and accessible names** (`getByRole`, `getByLabelText`), not test IDs —
  a test that finds elements the way AT does *is* an accessibility test ([../frameworks/react.md](../frameworks/react.md) §13).
- **Run a real screen reader before shipping a new interactive pattern.** Smoke-test every release with
  one AT pass; an automated suite cannot tell you the combobox is unusable.

## 10. CI gating

- **Block the merge on automated a11y**, like any other test gate ([code-review.md](code-review.md) §3.2,
  [../platform/ci-cd.md](../platform/ci-cd.md)): lint rule, jest-axe, and a Playwright/Lighthouse a11y
  check all run in CI with a non-zero exit on violations — zero-violations as the floor, ratcheted.
- **Reviewers own what automation can't:** in PR review, do a keyboard pass and sanity-check labels,
  focus order, and alt text — flag with `blocking:` when AA is at risk.
- **Net-new interactive pattern ⇒ documented AT result** in the PR (which AT, what was heard). _(scale-up:
  schedule periodic audits and include disabled users in usability testing — automation never replaces them.)_

## Definition of done

- [ ] Meets **WCAG 2.2 Level AA** (incl. 2.2 additions: focus visible/not-obscured, target size, redundant entry)
- [ ] Semantic HTML + landmarks; one `<h1>`, no skipped heading levels; native controls over custom (§2)
- [ ] No invalid/over-applied ARIA; live regions for async updates; ARIA state stays in sync (§3)
- [ ] Full keyboard operability: logical focus order, visible `:focus-visible`, no traps, skip link (§4)
- [ ] Inputs labelled; errors are text + `aria-describedby` + announced; no colour-only signals (§5/§6)
- [ ] Contrast meets AA (4.5:1 text / 3:1 large & UI); verified with a tool (§6)
- [ ] `alt` on every image; captions on video; `prefers-reduced-motion` honoured; zoom not blocked (§7/§8)
- [ ] `eslint-plugin-jsx-a11y` + jest-axe + Playwright/Lighthouse a11y green in CI, zero violations (§9/§10)
- [ ] Manual keyboard pass + one screen-reader (NVDA/VoiceOver) pass done for new interactive patterns (§9)

**Sources:** [WCAG 2.2](https://www.w3.org/TR/WCAG22/) · [WAI-ARIA Authoring Practices (APG)](https://www.w3.org/WAI/ARIA/apg/) ·
[Using ARIA — "No ARIA is better than bad ARIA"](https://www.w3.org/TR/using-aria/) ·
[Deque axe-core](https://github.com/dequelabs/axe-core) · [eslint-plugin-jsx-a11y](https://github.com/jsx-eslint/eslint-plugin-jsx-a11y) ·
[EN 301 549 / European Accessibility Act](https://www.etsi.org/standards) · [ADA.gov Title II web rule (2024)](https://www.ada.gov/resources/2024-03-08-web-rule/)
