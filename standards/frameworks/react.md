# React Standards

How to build a good React app — the **framework layer**, meaningful once you've chosen React.
Built on the TypeScript standard; language rules → [typescript.md](../languages/typescript.md).

Applies to React single-page apps (Vite by default), tested with **React Testing Library**,
shipped as an installable **PWA** where it fits. Need SSR/SEO instead? → §3 and
[next.md](next.md).

**Baseline: React 19** (19.2 current stable). Every rule below assumes it. React 19 deleted a
long tail of APIs that had replacements for years and added first-class ones for things this doc
previously worked around; the version floor, the removals, and the adoption order are §14.

---

## 1. Project structure (feature-based)

**Organise by feature, not by file type** — a global `components/`-`hooks/`-`utils/` split by
kind doesn't scale. Colocate everything a feature owns under `src/features/<name>/`; reserve the
top level for genuinely shared code.

```text
src/
  app/          # routes, root providers, router — the composition layer
  components/    # shared design-system primitives    config/ — global config, env (§6)
  features/<feature>/{ api (fns + TanStack Query hooks §5), components, hooks, types, utils, stores }
  hooks/ lib/ stores/ testing/ types/ utils/   # shared, cross-feature
```

- **Unidirectional imports: `shared → features → app`.** Shared never imports a feature; one
  feature never imports another (compose in `app/`). Enforce with ESLint
  `import/no-restricted-paths` so violations fail CI, not review.
- **No barrel/`index.ts` re-export files** — they defeat tree-shaking, create import cycles, and
  bloat chunks; import the concrete path. _(scale-up: one barrel at a public package boundary.)_
- **Absolute imports** from `src` (`@/...` via tsconfig `paths` + Vite alias) — no `../../../`.

## 2. Components, hooks & app conventions

- Function components + hooks only — no legacy class components. **Type props with a plain
  `type`, destructured in the signature — not `React.FC`** ([typescript.md](../languages/typescript.md)).
- **Colocate** state, helpers, and sub-components next to where they're used; move them up only
  when a second caller appears. **Abstract on the *second* repetition, not the first** —
  premature shared abstractions cost more than the duplication they replace.
- **One component returns one tree.** Don't define nested render-functions (`renderHeader()`)
  inside a component — extract a real component. A ballooning prop list is the signal to split
  or switch to composition (`children`/slots), not to add a tenth prop.
- **`ref` is an ordinary prop — no `forwardRef` wrapper.** Destructure it like any other prop
  (`function Input({ ref, ...rest })`). A ref *callback* may now return a **cleanup function**, so
  teardown lives next to setup instead of in a paired effect — but that also means an implicit
  arrow return is a type error: `ref={el => (map[id] = el)}` must become a block body.
- **`<Context>` is its own provider**: `<ThemeContext value={theme}>`, not
  `<ThemeContext.Provider value={theme}>`. Same object, one less indirection.
- **Wrap third-party UI/libs** behind a thin local component so a swap is a one-file change.
- **Validate every external/API boundary with a schema (Zod).** Parse responses into typed
  data at the edge so the rest of the app works with trusted types; surface clear errors on
  parse failure. See [api-design.md](../design/api-design.md) for sharing schemas.
- Use relative API URLs (`/api/...`) and a dev-server proxy so dev, preview, and the
  production-served build all work unchanged.
- Streaming endpoints (SSE/websockets) must hit the network live — exclude them from any
  service-worker caching (§12).
- Follow the project's component library / design system consistently.
- **Route all logging through a thin `logger.ts`** (levels + structured context, one Sentry
  seam), not raw `console.*` — enforced by Biome `noConsole`.

## 3. SPA vs. meta-framework boundary

**A Vite SPA is the default** for app-shell / authenticated tools (dashboards, internal apps)
where there's no SEO surface and the user is already logged in. This doc assumes it.

Reach for a **meta-framework — Next.js (App Router) or Remix —** when you need **SSR/SSG for
SEO**, **streaming React Server Components**, or **edge rendering**. That's an architecture
choice made up front, not a retrofit: **don't bolt SSR onto a Vite SPA.** Adopting one
*supersedes* the Vite-specific rules here — the `build.sourcemap` guard, chunking, and the
hand-rolled service worker are all owned by the framework instead (see [next.md](next.md)).

| You need… | Use |
|---|---|
| App shell behind auth, no SEO | **Vite SPA** (this doc) |
| Public pages, SEO, social previews | **Next.js App Router / Remix** (SSR/SSG) |
| Streaming, RSC, edge | **Next.js App Router** |

## 4. State boundaries (server vs. client)

**The #1 senior call: match state to its kind.** Most "state management" pain is server-cache
state crammed into a client store. Five kinds, five homes:

| Kind | Home | Don't |
|---|---|---|
| **Server cache** (API data) | **TanStack Query** | …copy into a global store / `useState` |
| **Local UI** (open, hovered) | `useState` / `useReducer` | …lift to global "just in case" |
| **App/global UI** (theme, auth, toasts) | Context, or **Zustand/Jotai** _(scale-up)_ | …reach for Redux by default |
| **Form** | React Hook Form (§8) | …`useState`-per-field |
| **URL** (filters, tabs, pagination) | the router (search params) | …mirror into React state |

- **Server data is a cache you don't own, not client state.** In Redux/Zustand you'd reimplement
  the caching, dedup, refetch, and invalidation TanStack Query already does. **Don't copy query
  results into `useState`** — that opts you out of background updates.
- **Global stores are for genuinely app-wide *client* state only.** Context covers most; add
  Zustand/Jotai only when context re-render scope or boilerplate actually bites.

## 5. Data fetching & the API layer

- **One pre-configured API client** (`lib/api-client.ts`) — shared everywhere; never scatter raw
  `fetch`/`axios` calls through components.
- **Colocate each request with its feature**: `features/<f>/api/<op>.ts` exports the **fetcher**,
  its **Zod schema/types**, and the **TanStack Query hook** that wraps it together. UI imports
  the hook, never a bare fetch.
- **One custom hook per query/mutation.** Keeps fetching out of components, colocates the query
  key, and makes config changes one-line.
- **Query keys are arrays, treated like effect deps** (`['todos', filters]`) — every input the
  query depends on goes in the key so changes refetch automatically. Use a per-feature **key
  factory** to avoid stringly-typed drift.
- **Don't use the query cache as a state manager.** `setQueryData` is for optimistic updates and
  mutation responses only — other writes get clobbered by background refetches. Tune **`staleTime`**
  (not `gcTime`) to control refetch frequency.

## 6. Error boundaries, Suspense & server state

- **Wrap the app in error boundaries** (`react-error-boundary`): a top-level catch-all + per-
  route boundaries so a widget crash never white-screens the shell. Wire `onError` to the
  logger; show `error.message` only in dev. Pair routes with `React.lazy` + `Suspense` for
  code-splitting (let Vite/Rollup auto-chunk — don't hand-write `manualChunks`).
- **Server state via TanStack Query** (§5), never hand-rolled `useEffect`+`fetch` — that leaks
  race conditions, double-fires under StrictMode, and reimplements caching/cancellation per call.
  Pair queries with `<Suspense>` + an error boundary so loading/error are structural, not
  per-component `if (isLoading)` ladders.
- **`use()` is the one "hook" you may call conditionally.** It reads a promise (suspending until
  it settles) or a context, and unlike `useContext` it works after an early return or inside a
  branch. Use it to unwrap a promise handed down from a parent — **never for a promise created
  during render**, which mints a new one every pass and never settles. It complements TanStack
  Query, it doesn't replace it: `use()` has no cache, no dedup, no refetch.
- **Validate runtime env at boot.** Parse `import.meta.env` through a Zod schema in a side-
  effect-imported `env.ts` so misconfig fails loudly, not mid-session. **The `VITE_` prefix is
  a boundary, not a safeguard** — prefixed vars are inlined as plaintext into the bundle; never
  put secrets behind it, and scan the built `dist/` for leaks (see
  [app-security.md](../practices/app-security.md)).

## 7. Re-render & runtime performance

**Measure first.** Profile with the **React DevTools Profiler** (flame chart + "why did this
render") before optimising anything — most "slow" components aren't, and untargeted
memoisation adds dependency-array bugs for no win.

- **`useMemo`/`useCallback` are not reflexive.** Reach for them only when the value is a
  referentially-stable prop to a **memoised** child (`React.memo`), or guards a **genuinely
  expensive** compute. Memoising a primitive or a cheap object that nothing downstream depends
  on is pure overhead.
- **Shrink re-render scope structurally** before reaching for memo:
  - **Colocate state** with the component that uses it; **lift state down** so a high-frequency
    update doesn't re-render a whole page.
  - **Pass `children`** (or any element prop) so a stateful wrapper re-renders without
    re-rendering a static subtree it received as a prop.
  - **Stable keys** for dynamic lists — **never the array index** when items reorder/insert/
    delete; it corrupts state and defeats reconciliation.
- **React Compiler (v1.0, stable Oct 2025) is the default.** Adopt it (`babel-plugin-react-
  compiler`) — it memoises automatically and correctly, including values after early returns
  that `useMemo` literally cannot reach. **Once it's on, stop hand-writing `useMemo`/
  `useCallback`**; keep them only as escape hatches where an effect's deps need exact control.
  The compiler *requires* Rules-of-Hooks compliance to be safe.
- **Don't suppress `useExhaustiveDependencies`** (Biome's `react` domain). A silenced
  dependency array is a stale-closure bug waiting to happen — and the Compiler trusts it.
  When you genuinely need an Effect to read a value without re-firing on it, that's what
  **`useEffectEvent`** (React 19.2) is for: move the non-reactive part into an Effect Event and
  call it from the Effect. It reads the latest value at call time and is *not* a dependency — a
  supported escape hatch instead of a suppression comment.
- **`<Activity>`** (React 19.2) hides a subtree with `display: none` while **keeping its state**
  and unmounting its Effects, and de-prioritises its updates. Reach for it on tabs, wizard steps,
  and back-navigation targets where unmounting loses work but leaving it live costs renders.

## 8. Forms

- **React Hook Form + the Zod resolver** (`@hookform/resolvers/zod`) — **uncontrolled inputs**
  (minimal re-renders, §7) validated against a schema **reused from the API boundary** (§2/§5), so
  client and server agree on shape by construction.
- **Don't hand-roll `useState`-per-field** + manual `onChange` + ad-hoc validation; it
  re-renders on every keystroke and drifts from the API contract.

```tsx
const form = useForm<CreateUser>({ resolver: zodResolver(createUserSchema) })
// register fields uncontrolled; form.handleSubmit(onValid) parses+validates once
```

**React 19 Actions are the second legitimate shape** — pass an async function straight to
`<form action={fn}>` and React manages the submission for you: **`useActionState`** returns
`[state, action, isPending]` (pending, error, and result without a `useState` triplet),
**`useFormStatus`** lets a nested submit button read the parent form's pending state without prop
drilling, and **`useOptimistic`** shows the pending result and reverts automatically on failure.
Choose by where the mutation runs and how much client logic the form carries:

| Form | Use |
|---|---|
| Submits to a Server Function; wants progressive enhancement | **Action** on `<form>` + `useActionState` |
| Multi-step, dependent fields, per-keystroke validation | **React Hook Form** (above) |
| Both | RHF submitting *into* the action — they compose |

**What doesn't change either way: the server re-validates.** A Server Function is a public HTTP
endpoint ([next.md](next.md) §3); client-side parsing is UX, and the same Zod schema has to run
again on the other side. Stop writing bespoke `isSubmitting`/`error` state — one of the three
hooks above already owns it.

See [api-design.md](../design/api-design.md) for sharing the schema across the boundary.

## 9. Component API design

- **Props over context for reuse.** Context couples a component to a provider; a reusable
  component takes what it needs as props. Reserve context for genuinely app-wide ambient state.
- **Discriminated-union variant props, not boolean explosion.** A single `variant:
  'primary' | 'secondary' | 'danger'` beats `isPrimary`/`isDanger`/… (which permit nonsensical
  combinations the type system should forbid).
- **Forward `ref` and spread `...rest`** to the root element so the component composes with
  focus management, libraries, and `data-*`/`aria-*` attributes.
- **Support controlled *and* uncontrolled** via `value` (+ `onChange`) / `defaultValue`, mirroring
  native inputs — so callers pick the mode that fits.

```tsx
type Props = { variant: 'primary' | 'secondary' | 'danger' } & ComponentPropsWithRef<'button'>
function Button({ variant, ...rest }: Props) { return <button data-variant={variant} {...rest} /> }
```

`ComponentPropsWithRef` already carries `ref`, and in React 19 that is just a prop the spread
forwards — so this composes with focus management with no `forwardRef` in sight (§2).

## 10. Accessibility (first-class, not a pass at the end)

Target **WCAG 2.2 AA**. Accessibility is a build requirement, not a polish step.

- **Semantic HTML first** — `<button>`, `<nav>`, `<main>`, real headings. ARIA *supplements*
  semantics; it never replaces them. **Don't over-ARIA** — a wrong `role` is worse than none.
- **Keyboard + focus**: every interactive element reachable and operable by keyboard; manage
  focus on route change, dialog open/close, and async content; visible focus rings.
- **Labelled form fields** (`<label>`/`aria-label`) and **announced errors**
  (`aria-describedby` and a live region) — pairs with §8.
- **Colour contrast** meets AA; **honour `prefers-reduced-motion`** (gate non-essential
  animation/transitions behind the media query).
- **CI gate**: Biome's `a11y` rules are already on ([typescript.md](../languages/typescript.md)
  §3) — add an **axe / Lighthouse-a11y** check in CI so runtime violations (contrast, focus
  order, missing labels) also fail the build, not just static JSX lint. Drive these via
  behaviour tests (roles/labels, §13) — see
  [testing-strategy.md](../practices/testing-strategy.md).

## 11. Web Vitals & performance budget

Hold a **Core Web Vitals** budget (field thresholds, 75th percentile):

| Metric | Good | Measures |
|---|---|---|
| **LCP** | ≤ 2.5 s | largest content paint |
| **INP** | ≤ 200 ms | interaction responsiveness (replaced FID, 2024) |
| **CLS** | ≤ 0.1 | layout stability |

- **Lazy-load routes** with `React.lazy` + `Suspense` (§6) so first load ships only the shell.
- **Image policy**: explicit `width`/`height` (or `aspect-ratio`) to kill CLS; modern formats
  (AVIF/WebP); `loading="lazy"` below the fold; never load oversized images.
- **Ban inline-style sprawl and runtime CSS-in-JS** (e.g. styled-components/emotion runtime):
  inline `style={{…}}` defeats theming/caching; runtime CSS-in-JS adds per-render style
  computation and hurts INP/LCP. Use build-time styles (**Tailwind** *or* **CSS Modules** —
  pick ONE and state it in the repo).
- **Lighthouse-CI gate** for the lab CWV proxies + the a11y/SEO categories; pair it with a
  `size-limit` bundle budget (§12) — they cover different failure modes (transfer size vs.
  rendered experience).

## 12. Build & tooling (Vite + PWA)

**Build tool / dev server: Vite** — the default for React/TS SPAs.

```bash
pnpm dev                      # dev server
pnpm build                    # tsc --noEmit && vite build
```

- **Never ship source maps to production.** Keep `build.sourcemap: false` (Vite's default —
  set it explicitly as a guard); the minified bundle should be the only client artifact.
  Verify after building: no `*.map` files and no `//# sourceMappingURL=` comments in `dist/`.
  Serve from a web server that also denies `.map` requests as defense-in-depth (see
  [docker.md](../platform/docker.md)).
- **Bundle hygiene:** inspect with `rollup-plugin-visualizer` (behind an `ANALYZE` flag) and
  fail CI on bloat with **`size-limit`** (a real non-zero exit, unlike Vite's
  `chunkSizeWarningLimit` which only warns). Set the budget at current size and ratchet down.

**PWA (installable web app).** For user-facing web apps, ship an installable PWA via
`vite-plugin-pwa` (Workbox):

- Generate a **web manifest** (name, icons, theme/background colour, `display: standalone`)
  and a **service worker** that precaches the app shell; use `registerType: 'autoUpdate'`.
- **Denylist dynamic/API routes from the service worker** (e.g.
  `navigateFallbackDenylist: [/^\/api\//]`) so API/SSE always hit the network — never let the
  SW cache dynamic responses.
- Provide the required icons (192/512 px incl. a maskable variant, apple-touch-icon, favicon)
  in `public/`. If branding changes, update all icons and the manifest together.
- When touching caching/SW config, verify installability (DevTools → Application, or a
  Lighthouse PWA audit) before merging.

## 13. Component testing (RTL + MSW)

Mechanics (runner, coverage thresholds) live in
[typescript.md](../languages/typescript.md) §7. The React strategy:

- **React Testing Library**, jsdom environment, global setup file. Test **behaviour and
  accessibility** (roles, labels, user events) — not implementation details. Use
  `@testing-library/user-event` for interactions. React 19 makes this the only supported path:
  `react-dom/test-utils` is **removed** (`act` now comes from `react` itself) and
  `react-test-renderer` is deprecated (§14).
- Co-locate tests (e.g. `src/**/__tests__/*.test.tsx`).
- **Mock the network, not `fetch`** — use **MSW** request handlers (shareable with dev/Storybook)
  and assert against the same Zod schemas the app uses. Hand-mocking `fetch` is brittle and
  doesn't compose with the TanStack Query layer (§5/§6). Prefer route/page-level integration tests
  (real provider tree + `QueryClient` + MSW) over shallow unit tests of presentational
  components. See [testing-strategy.md](../practices/testing-strategy.md).

## 14. React 19 baseline

**Target React 19** (19.2 current stable; `react` and `react-dom` are versioned together). This is
a genuine breaking change, not a bump — most of it is the deletion of APIs that have had
replacements for years, so the migration is mechanical but not optional.

**Removed** — these fail, they don't warn:

| Gone | Use instead |
|---|---|
| `propTypes`, `defaultProps` on function components | TypeScript prop types; ES default parameters |
| Legacy context (`contextTypes` / `getChildContext`) | `createContext` (§2) |
| String refs (`ref="input"`) | ref callbacks / `useRef` |
| `ReactDOM.render`, `hydrate`, `unmountComponentAtNode`, `findDOMNode` | `createRoot`, `hydrateRoot`, `root.unmount()`, a ref |
| `react-dom/test-utils` | `act` from `react`; RTL for the rest (§13) |
| `React.createFactory`, UMD builds | JSX; an ESM CDN |

**Deprecated**: `element.ref` (read `element.props.ref`) and `react-test-renderer`. `forwardRef`
and `Context.Provider` still work but no longer have a job (§2) — React has said it intends to
deprecate both, so don't write new ones.

**Worth adopting, in rough order of payoff:**

| Feature | Replaces |
|---|---|
| Actions + `useActionState` / `useFormStatus` / `useOptimistic` (§8) | hand-rolled pending/error/optimistic state around a submit |
| `ref` as a prop; ref cleanup functions (§2) | `forwardRef`; teardown stranded in a paired effect |
| `use()` (§6) | `useContext` stuck above an early return; promise-unwrapping boilerplate |
| `useEffectEvent`, `<Activity>` (19.2, §7) | a suppressed dependency array; unmounting and losing state |
| Metadata in components — `<title>`/`<meta>`/`<link>` hoisted to `<head>` | react-helmet and friends |
| `preload` / `preinit` / `preconnect` / `prefetchDNS` from `react-dom` | hand-injected `<link rel="preload">` tags |
| `onCaughtError` / `onUncaughtError` on `createRoot` | ad-hoc error plumbing around the boundary (§6) |

**Not stable — do not standardise on it.** `<ViewTransition>` is **canary/experimental only**. A
meta-framework that pins React canary (the Next.js App Router does) exposes it; a Vite SPA on
stable React does not. Treat it as an experiment, not a pattern.

The **React Compiler** ships on its own 1.0 track and is *not* part of React 19 — see §7.

## Definition of done

- [ ] Language DoD met ([typescript.md](../languages/typescript.md) §10): `biome ci`, `tsc`,
      tests, supply chain
- [ ] On React 19; nothing left from the removed list (§14) — no `propTypes`/`defaultProps`,
      string refs, `ReactDOM.render`, or `react-dom/test-utils`
- [ ] Feature-based structure held: no cross-feature imports, unidirectional rule passes, no
      barrel files (§1)
- [ ] Server state lives in TanStack Query, not copied into `useState`/global stores (§4)
- [ ] `useExhaustiveDependencies` not suppressed
- [ ] `pnpm build` succeeds; bundle within `size-limit`
- [ ] Production build ships **no source maps** (`build.sourcemap: false`; no `*.map` in `dist/`)
- [ ] No secrets behind `VITE_`; built `dist/` scanned clean
- [ ] A11y gate passes (axe/Lighthouse-a11y) — labels, contrast, keyboard/focus (§10)
- [ ] Web Vitals budget met (Lighthouse-CI: LCP/INP/CLS, §11)
- [ ] PWA still installs (manifest + SW valid) if SW/caching/branding changed

**Sources:** [bulletproof-react](https://github.com/alan2207/bulletproof-react) (project
structure, state management, API layer, components) ·
[TanStack Query docs](https://tanstack.com/query/latest/docs/framework/react/overview) &
[TkDodo's Practical React Query](https://tkdodo.eu/blog/practical-react-query) ·
[React TypeScript Cheatsheet](https://github.com/typescript-cheatsheets/react) ·
[react.dev — You Might Not Need an Effect](https://react.dev/learn/you-might-not-need-an-effect) ·
[React 19 release notes](https://react.dev/blog/2024/12/05/react-19) &
[React 19 upgrade guide](https://react.dev/blog/2024/04/25/react-19-upgrade-guide) ·
[React 19.2 release notes](https://react.dev/blog/2025/10/01/react-19-2)
