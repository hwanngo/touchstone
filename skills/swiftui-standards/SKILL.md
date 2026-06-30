---
name: swiftui-standards
description: Use when building or reviewing SwiftUI UI in a touchstone repo — declarative views, the Observation framework for state, navigation, in-view concurrency, identity/perf, and the a11y/test surface. Triggers on SwiftUI views, `.swift` files declaring `: View`/`some View`, `@Observable`, `@State`/`@Bindable`, `NavigationStack`, `#Preview`. Boundary: Swift-language rules (concurrency, optionals, value types, packages) → swift skill; this layers on top.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# SwiftUI (framework)

Full standard: **`standards/frameworks/swiftui.md`** (layers on `standards/languages/swift.md`).
This skill inlines the load-bearing rules so it stays useful when installed standalone in
`~/.claude/skills/`:

## Always
- **Observation framework, iOS 17+** — mark reference models `@Observable`; own them in `@State`,
  inject via `@Environment`, get `$`-bindings with `@Bindable`. No `ObservableObject`/`@Published`/
  `@StateObject` in new code.
- **One source of truth per state; data flows down, events up** — derive values, never duplicate
  state into a second `@State` you hand-sync.
- **Small composed views** — extract a subview (own rebuild scope) over a `-> some View` helper; no
  reflexive `AnyView`.
- **Plain SwiftUI (MV) by default** — logic on `@MainActor` `@Observable` models, not in `body`;
  reach for a per-screen view-model only for genuinely complex state _(scale-up)_.
- **`NavigationStack` + value-driven/type-safe path** (never `NavigationView`); program nav by
  mutating the path.
- **`.task`/`.task(id:)` for async** (auto-cancels) — never `onAppear { Task {} }`; bound every
  external await with a timeout.

## Don't get burned
- **`@State` seeded from a parent prop won't update** — pass a `@Binding` or the value instead.
- **Wrong `ForEach` identity recycles state into the wrong row** — key on a stable domain ID, never
  the array index when rows move.
- **`AnyView` and helper methods erase identity / always rebuild** — they quietly kill diffing and perf.
- **Bridge to UIKit (`UIViewRepresentable`) only when SwiftUI lacks the API** — check for a native
  one first (`PhotosPicker`, `Map`, `ShareLink`); keep `updateUIView` side-effect-free.
- **Migration is mechanical** — `@StateObject`→`@State`, `@ObservedObject`→`let`/`@Bindable`,
  `@EnvironmentObject`→`@Environment(Model.self)`, delete every `@Published`; do it model-by-model.

## Done
Observation state (no `ObservableObject`) · small composed views, stable identity · MV logic off
`body` · `NavigationStack` typed path · `.task` async, awaits bounded · lazy containers, pure `body` ·
`#Preview`s cover empty/loading/error + dark + Dynamic Type · a11y labels/traits + VoiceOver ·
Swift Testing for logic, XCUITest by accessibility id. See `standards/frameworks/swiftui.md`.
