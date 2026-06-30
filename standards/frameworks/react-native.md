# React Native Standards

Framework layer; component/state rules → [react.md](react.md), language → [typescript.md](../languages/typescript.md).
Everything in react.md still holds — function components, the server-vs-client state split, Zod at
boundaries, React Hook Form. This doc owns only what's *native*: Expo, the New Architecture,
navigation, lists, native modules, OTA updates, and the mobile-specific security/a11y surface.
Defers app security → [app-security.md](../practices/app-security.md), accessibility →
[accessibility.md](../practices/accessibility.md), test philosophy →
[testing-strategy.md](../practices/testing-strategy.md), timeout/cancel contract →
[resilience.md](../design/resilience.md).

> **One law:** ship through **Expo + EAS** on the **New Architecture**, and treat the JS bundle as
> public — anything you put in it leaves the device.

---

## 1. Expo is the default (managed workflow + EAS)

**Start every new app with Expo's managed workflow** (`npx create-expo-app`, TypeScript template).
You write JS/TS; Expo owns the native projects via **Continuous Native Generation** (`expo prebuild`
regenerates `ios/` and `android/` from `app.json` + config plugins). Don't commit `ios/`/`android/` —
they're build artifacts, not source.

| Concern | Tool | Notes |
|---|---|---|
| SDK | **Expo SDK — latest stable (verify the current release)** | Pins a tested RN/React pair (e.g. RN 0.85 / React 19.2 — check the SDK's matrix). Bump SDK as a unit, never RN alone. |
| Cloud build | **EAS Build** | Signed iOS/Android binaries off your machine; credentials managed by EAS. |
| OTA / channels | **EAS Update** (§11) | Ship JS-only fixes without a store review. |
| Submit | **EAS Submit** | Automated store upload from CI. |
| Native config | **config plugins** | Modify native projects declaratively in `app.json`; never hand-edit generated native code. |

- **Reach for native config through a config plugin, not a manual edit.** A hand-edited `ios/` dir is
  wiped by the next `prebuild`. If a library needs native setup, it ships a plugin — add it to
  `plugins` in `app.json`.
- **Bare workflow is the escape hatch, not the goal.** Drop to bare only when you need a native
  capability no SDK/plugin covers (a custom fork of a native SDK, exotic build steps). You keep EAS
  and most Expo modules; you take on owning the native projects. Prefer a **dev client**
  (`expo-dev-client`) over going fully bare — it gives you custom native code while keeping CNG.
- **`expo-doctor` runs in CI** to catch SDK/dependency mismatches before they reach a build.

```bash
npx create-expo-app@latest my-app -t          # typed template
npx expo start                                  # Metro dev server (--dev-client for custom natives)
npx expo prebuild --clean                       # regenerate native projects from config
eas build --profile production --platform all   # cloud-signed binaries
eas update --branch production                  # OTA JS bundle (§11)
npx expo-doctor                                 # CI: dependency/SDK sanity
```

## 2. The New Architecture + Hermes are non-negotiable

The **New Architecture is the only architecture** — SDK 55+ runs on it with no opt-out, and RN 0.85
made it the assumed-stable default. New apps inherit it; **don't ship the legacy bridge.**

- **Fabric** (the renderer) + **TurboModules** (lazy, typed native modules) + **JSI** (direct
  JS↔native calls, no JSON bridge serialization) — together they kill the async-bridge bottleneck
  that caused dropped frames and startup jank.
- **Hermes is the JS engine** (Hermes V1 is the default on current Expo SDKs): faster startup, lower memory, no
  JIT warm-up. Don't switch to JSC. Ship **source maps to Sentry/EAS only** — never in the app
  artifact (mirror the react.md prod-source-map rule).
- **Audit native dependencies for New-Arch support before adding them.** A library that only has a
  legacy native module will run under the interop layer at best, or break. Check
  [reactnative.directory](https://reactnative.directory) for the New-Arch badge.
- **Heavy synchronous work belongs on a worklet/native thread**, not the JS thread — use
  **Reanimated** (worklets) for gesture/animation work so the UI thread never waits on JS.

## 3. Navigation

**Use Expo Router** (file-based, built on React Navigation 7) for new apps — routes are files under
`app/`, deep links and typed routes come for free, and it mirrors the Next.js mental model the team
already has ([next.md](next.md)). Drop to **React Navigation directly** only for navigation patterns
the router doesn't express.

| File / API | Role |
|---|---|
| `app/_layout.tsx` | Stack/Tabs navigator + providers (the root shell) |
| `app/index.tsx`, `app/profile.tsx` | Screens; segment = file name |
| `app/[id].tsx`, `app/[...rest].tsx` | Dynamic / catch-all routes |
| `app/(tabs)/` | Route group — shared layout, no URL segment |
| `useLocalSearchParams()` | Typed route params (validate with Zod, §4) |

- **Type your routes.** Enable typed routes (`experiments.typedRoutes`) so `href` and params are
  checked — a broken link fails `tsc`, not QA.
- **Lazy-load heavy screens** and keep navigator config declarative; don't imperatively `navigate`
  from inside render.
- **Handle deep links and the Android hardware back button explicitly** — they're real entry points,
  not edge cases. Configure the URL scheme in `app.json`.

## 4. State & data (same split as the web)

The react.md state model is unchanged — **server cache ≠ client state.** Match state to its kind:

| Kind | Home | Don't |
|---|---|---|
| **Server cache** (API data) | **TanStack Query** (§react.md §4–5) | …hand-roll `useEffect`+`fetch` |
| **Local UI** | `useState`/`useReducer` | …lift to global "just in case" |
| **App/global UI** (auth, theme) | Context, or **Zustand** _(scale-up)_ | …reach for Redux by default |
| **Form** | React Hook Form + Zod resolver | …`useState`-per-field |
| **Persisted** (offline, §9) | MMKV / AsyncStorage | …keep server data only in memory |

- **TanStack Query for all server state**, with its persistence/offline plugins (§9) wired to MMKV so
  the app opens to cached data, not a spinner. **Validate every API response with Zod** at the
  boundary — a flaky mobile network surfaces malformed payloads the web rarely sees.
- **Bound every request with a timeout via `AbortSignal`** and respond to `NetInfo` connectivity —
  the [resilience.md](../design/resilience.md) contract matters more on a train than on fibre.
- **Zustand over Redux** for genuinely app-wide client state; context covers most of it.

## 5. Styling

- **`StyleSheet.create` is the baseline** — styles are validated and registered once, not rebuilt
  per render. **No inline `style={{…}}` objects in hot paths** (re-created every render, like the
  react.md inline-style ban).
- **Pick one styling system per repo and state it.** **NativeWind** (Tailwind classes compiled to
  `StyleSheet`) if the team thinks in Tailwind ([react.md](react.md) Tailwind option); **Tamagui**
  if you want an optimizing compiler + cross-platform design tokens. Don't mix both.
- **Theme via tokens, not scattered literals** — one source for colour/spacing/typography, switched
  for dark mode. Respect `useColorScheme()` and the OS reduce-motion setting (§14).

## 6. Lists & performance

**Measure on a low-end physical Android device, not a simulator** — that's where jank lives.

- **FlashList v2 over FlatList**, always, for any non-trivial list. It recycles views (5–10× the
  throughput on large datasets) and v2 needs **no size estimates**. It's New-Arch-only and JS-only,
  so it runs in Expo Go. Reserve `FlatList`/`ScrollView` for short, static lists.
- **Stable `keyExtractor`, never the array index** when items reorder/insert — same reconciliation
  rule as the web (react.md §7).
- **Kill re-renders structurally first**, then memo: extract and `React.memo` the row component,
  keep row props referentially stable, colocate state. **React Compiler** applies here too — adopt
  it and stop hand-writing `useMemo`/`useCallback`.
- **Cache and size remote images** with `expo-image` (disk + memory cache, `contentFit`, blurhash
  placeholders) — never a raw `<Image>` with an unbounded remote URL.
- **Guard startup time.** Keep the JS bundle lean (the New Arch helps, not the whole story): defer
  non-critical work off the first frame, control the splash with `expo-splash-screen`
  (`hideAsync()` only after the first screen is ready), and lazy-load heavy screens (§3).

## 7. Native modules & permissions

- **Stay in JS until you can't.** Reach for a native module only for a capability no Expo SDK module
  or community library covers. When you do, write it as a **TurboModule** (typed spec, §2) — not a
  legacy bridge module.
- **Prefer an Expo SDK module** (`expo-camera`, `expo-location`, `expo-notifications`, …) over a raw
  community native dep — it's maintained against the current SDK and ships its config plugin.
- **Request permissions just-in-time, with rationale, and handle denial.** Never request a
  permission at launch "to get it out of the way"; iOS will reject undeclared usage strings, and a
  blanket prompt tanks acceptance. Declare every usage string (`NSCameraUsageDescription`, etc.) via
  the module's config plugin.

## 8. Platform differences & safe areas

- **iOS and Android differ on purpose** — back navigation, ripple vs. opacity, date pickers, status
  bar. Use `Platform.select`/`.ios.tsx`/`.android.tsx` for genuine divergence; don't fork a whole
  screen when a prop differs.
- **Respect safe areas.** Wrap with `react-native-safe-area-context` (`useSafeAreaInsets`) — never
  hard-code a notch/home-indicator offset. Account for the keyboard (`KeyboardAvoidingView` /
  `react-native-keyboard-controller`).
- **Test both platforms before merge.** A layout that's pixel-perfect on iOS routinely breaks on
  Android (elevation, font scaling, hardware back).

## 9. Offline & storage

| Data | Store | Rule |
|---|---|---|
| Tokens, secrets | **`expo-secure-store`** (Keychain / Keystore) | Encrypted at rest; the *only* place for credentials (§12) |
| App state, cache, flags | **`react-native-mmkv`** | Synchronous, fast; back TanStack Query persistence with it |
| Legacy / simple KV | **AsyncStorage** | Async, slower — prefer MMKV for new code |

- **Never put secrets in AsyncStorage or MMKV** — they're plaintext on a rooted device. Secrets go in
  `expo-secure-store` (§12).
- **Persist the query cache** so the app is usable offline-first; reconcile on reconnect via TanStack
  Query's online-manager + `NetInfo`. _(scale-up: a sync engine — WatermelonDB / a local SQLite via
  `expo-sqlite` + replication — when you need true offline writes with conflict resolution.)_

## 10. Forms

**React Hook Form + the Zod resolver**, exactly as react.md §8 — uncontrolled where the platform
allows, one schema reused from the API boundary. RHF's `Controller` wraps RN's controlled
`TextInput`s; validation and the API contract stay in sync by construction. See
[react.md](react.md) for the pattern; nothing here overrides it.

## 11. OTA updates & release channels

**EAS Update ships JS/asset changes over-the-air** without a store review — but it is *not* a way
around the stores' native-code review.

- **OTA can only change the JS bundle and assets.** Anything native (a new permission, an SDK bump, a
  config-plugin change) needs a **new binary** through EAS Build. Pushing an update built against a
  different runtime to an old binary will crash it.
- **Pin `runtimeVersion` to the native runtime** (e.g. `policy: 'appVersion'`/`fingerprint`) so an
  update only lands on compatible binaries. This is the safety interlock — don't disable it.
- **Branch = channel.** Map an EAS Update **branch** to a build **channel** (`production`,
  `preview`, `staging`); promote a tested update from `preview` → `production` rather than pushing
  straight to users. Roll back by republishing a known-good update.

## 12. App security

The full model is [app-security.md](../practices/app-security.md); the mobile specifics:

- **The JS bundle is public.** Anyone can unzip an IPA/APK and read it — **no API keys, secrets, or
  private endpoints in the bundle** (same boundary as `VITE_*`/`NEXT_PUBLIC_*`). Secrets live
  server-side; the device gets short-lived tokens.
- **Credentials only in `expo-secure-store`** (Keychain/Keystore) — never AsyncStorage/MMKV, never a
  global JS variable (§9).
- **Pin certificates** _(scale-up)_ for high-value APIs (finance/health) to blunt MITM on hostile
  networks; budget for pin rotation so an expiring cert doesn't brick the app.
- **Don't log tokens/PII**, disable remote JS debugging in release builds, and gate deep-link params
  through Zod before acting on them (a deep link is attacker-controlled input).

## 13. Testing

Test philosophy and coverage floors live in [typescript.md](../languages/typescript.md) §11 and
[testing-strategy.md](../practices/testing-strategy.md). The RN stack:

| Layer | Tool | Tests |
|---|---|---|
| Component / unit | **Jest + React Native Testing Library** | Behaviour & a11y via roles/labels — not internals; mock the network with MSW |
| E2E | **Maestro** (default) or **Detox** _(scale-up)_ | Real flows on a device/emulator: auth, navigation, deep links, offline |

- **RNTL, query by role/label** (mirrors react.md §13) so tests double as accessibility checks.
- **Maestro for e2e** — declarative YAML flows, low setup; reserve Detox for teams that need its
  gray-box synchronization. Run the critical-path flow in CI on an emulator.
- **Mock native modules** (camera, location, notifications) at the boundary; don't reach for real
  hardware in unit tests.

## 14. Accessibility

Full bar in [accessibility.md](../practices/accessibility.md); the RN mapping:

- **`accessible` + `accessibilityRole` + `accessibilityLabel`** on every interactive element — RN
  doesn't get semantics free from HTML, so you supply them. Test with **VoiceOver (iOS)** and
  **TalkBack (Android)**.
- **Honour OS settings**: dynamic font scaling (don't cap `allowFontScaling` to force a layout),
  `prefers-reduced-motion` (gate Reanimated transitions), and sufficient contrast (WCAG 2.2 AA).
- **Minimum 44×44 pt touch targets**; ensure focus order and grouping make sense to a screen reader.

## Definition of done

- [ ] Language + React DoD met ([typescript.md](../languages/typescript.md) §10,
      [react.md](react.md)): `biome ci`, `tsc`, tests, supply chain, Zod boundaries
- [ ] Runs on the **New Architecture** (Fabric/TurboModules, Hermes); native deps are New-Arch-ready (§2)
- [ ] Built/shipped via **Expo + EAS**; native projects generated from config (no hand-edited
      `ios/`/`android/`); `expo-doctor` clean (§1)
- [ ] Server state in TanStack Query (persisted to MMKV, offline-tolerant); requests timeout-bounded (§4, §9)
- [ ] Lists use **FlashList**; profiled on a low-end Android device; images via `expo-image` (§6)
- [ ] Permissions requested just-in-time with usage strings declared via config plugins (§7)
- [ ] Safe areas respected; tested on **both** iOS and Android (§8)
- [ ] **No secrets in the JS bundle**; credentials only in `expo-secure-store` (§12)
- [ ] EAS Update `runtimeVersion` pinned; native changes go through a new build, not OTA (§11)
- [ ] RNTL + Maestro/Detox cover critical flows; a11y roles/labels verified with VoiceOver/TalkBack (§13–14)

**Sources:** [Expo docs — New Architecture](https://docs.expo.dev/guides/new-architecture/) &
[EAS Build](https://docs.expo.dev/build/introduction/) /
[EAS Update](https://docs.expo.dev/eas-update/introduction/) ·
[Expo SDK 56 changelog](https://expo.dev/changelog) ·
[Expo Router](https://docs.expo.dev/router/introduction/) &
[React Navigation](https://reactnavigation.org/) ·
[Shopify FlashList](https://shopify.github.io/flash-list/) ·
[react-native-mmkv](https://github.com/mrousavy/react-native-mmkv) ·
[reactnative.directory](https://reactnative.directory)
