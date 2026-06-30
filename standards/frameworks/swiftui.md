# SwiftUI Standards

Framework layer; language rules → [swift.md](../languages/swift.md). Everything in swift.md still
holds — Swift 6 complete concurrency, no force-unwraps on a fallible path, value-type models, typed
errors, Swift Testing. This doc owns only what's *SwiftUI*: view composition, the **Observation
framework** for state, data flow, navigation, in-view concurrency, identity/performance, previews,
the UIKit bridge, and the a11y/testing surface. Defers accessibility →
[accessibility.md](../practices/accessibility.md), test philosophy →
[testing-strategy.md](../practices/testing-strategy.md), and timeout/cancel contract →
[resilience.md](../design/resilience.md).

> **One law:** one source of truth per piece of state, observed at the leaf that reads it — a `body`
> that recomputes the world on every keystroke isn't done.

---

## 1. View composition

- **A `View` is a value, not a screen.** Build UIs by nesting many small `struct` views and passing
  data down; a 300-line `body` is a refactor, not a view. Extract a subview the moment a chunk has
  its own state, its own identity, or repeats — each extracted view is an independent rebuild scope.
- **Extract a subview over a `func someHeader() -> some View` helper.** A real `View` gets its own
  invalidation boundary and only re-runs when *its* inputs change; a helper method always recomputes
  with its parent. Reserve `@ViewBuilder` helpers for genuinely local, stateless fragments.
- **`@ViewBuilder` for conditional/multi-child content** — let the result builder assemble branches
  instead of `AnyView`. **`AnyView` erases identity and defeats diffing** (§7); reach for it only at
  a genuine type-boundary you can't express otherwise, never as a reflexive return type.
  ```swift
  struct ProfileScreen: View {
      let user: User
      var body: some View {
          VStack(spacing: 16) {
              AvatarBadge(user: user)        // extracted: own rebuild scope
              ContactList(items: user.contacts)
          }
      }
  }
  ```

## 2. State: the Observation framework

SwiftUI on **iOS 17+ uses Observation** (`@Observable`). It tracks reads at the *property* level, so
a view rebuilds only when a property it actually read changes — not on every mutation of the object.
This is the default; the `ObservableObject`/`@Published`/`@StateObject` stack is legacy.

| Wrapper | Use for | Owns lifetime? |
|---|---|---|
| **`@State`** | the single source of truth a view *owns* — a value, **or an `@Observable` reference model** | yes |
| **`@Bindable`** | getting `$`-bindings into an `@Observable` model passed in (controls, `TextField`) | no |
| **`@Environment`** | dependency-injected `@Observable` models / system values read down the tree | no |
| **`@Binding`** | a two-way handle to state a parent owns | no |
| **`let` property** | read-only data passed in — most subviews need nothing more | no |

- **Mark reference models `@Observable`** (the macro, `import Observation`); store the owned instance
  in **`@State`**, not `@StateObject`. SwiftUI keeps it alive across rebuilds and observes only the
  properties this view reads.
  ```swift
  @Observable final class CartModel {
      var items: [Item] = []
      var total: Decimal { items.reduce(0) { $0 + $1.price } }   // tracked read, no @Published
  }

  struct CartScreen: View {
      @State private var cart = CartModel()           // owns it
      var body: some View { CartTotals(cart: cart) }  // child rebuilds only when total changes
  }
  ```
- **Migration is mechanical:** drop `ObservableObject` conformance, delete every `@Published`, add
  `@Observable`; `@StateObject` → `@State`, `@ObservedObject` → a plain `let`/`@Bindable`,
  `@EnvironmentObject` → `@Environment(Model.self)`. Migrate model-by-model — old and new coexist.
- **`@Bindable` unlocks `$` on an injected model** for controls that need write access; without it
  you can still *read* its properties. **`@Environment` over `@EnvironmentObject`** for new code.
- **`@State` is `private` and minimal** — never seed it from a parent prop (it won't update); pass a
  `@Binding` or the value instead. State that outlives the view or is shared belongs in a model.

## 3. Data flow

- **Single source of truth, owned once, flowing down.** Each piece of state has exactly one owner;
  everyone else gets a `let`, a `@Binding`, or reads it from `@Environment`. Two copies of the same
  state is a sync bug waiting to happen.
- **Unidirectional: state down, events up.** Children render the state handed to them and call
  closures / mutate the bound model on user action — they don't fetch, derive global state, or reach
  sideways into a sibling's model.
- **Derive, don't duplicate.** A `total`, a filtered list, a validation flag is a *computed* property
  on the model or a `let` in `body` — never a second stored `@State` you hand-sync in `onChange`.
- **Validate external data at the boundary** (model/repository layer,
  [swift.md](../languages/swift.md) §5/§7), so `body` only renders already-valid domain types.

## 4. Architecture: plain SwiftUI (MV) by default

**Default to "plain SwiftUI" (MV): `@Observable` models + views, no per-view `ViewModel` layer.**
Observation already gives a view a precise, testable dependency on a reference model; wrapping every
screen in a `FooViewModel: ObservableObject` is UIKit muscle-memory that adds ceremony, indirection,
and a class to keep in sync for no rebuild-scoping benefit.

- **The model is a plain `@Observable` domain/store object**, often shared via `@Environment`, that
  owns state and the methods that mutate it. The view stays a thin projection of it.
- **Keep logic *out* of `body`.** Fetching, mutation, formatting, and business rules live on the
  model (or a repository it calls), so they're unit-testable without rendering a view (§11).
- **`@MainActor`-isolate the model** (§6) — UI state is main-actor state; background work is `async`
  and `Sendable` at the boundary, exactly as [swift.md](../languages/swift.md) §4 prescribes.
- _(scale-up)_ A genuinely complex, event-driven screen (a multi-step wizard, heavy local state
  machine) can warrant an explicit model object that looks like a view-model — that's a deliberate
  call for that screen, not a blanket pattern. **Pick the default per repo and state it.**

## 5. Navigation

- **`NavigationStack` with a type-safe, value-driven path** — never the deprecated
  `NavigationView`. Push *values*, not views; map each value to a destination with
  `.navigationDestination(for:)`. This makes navigation data, so it's testable and restorable.
  ```swift
  @State private var path = NavigationPath()
  NavigationStack(path: $path) {
      ItemList()
          .navigationDestination(for: Item.self) { ItemDetail(item: $0) }
  }
  // programmatic: path.append(item)  ·  path.removeLast()  ·  reset: path = NavigationPath()
  ```
- **Bind the path for programmatic navigation** — deep links, "pop to root", and post-action
  redirects mutate the `path` array/`NavigationPath`, not imperative push calls scattered in views.
- **A typed route `enum` is the scale-up.** For multiple destination types, model routes as a
  `Hashable enum` and switch in `navigationDestination` — one place owns the map, and an exhaustive
  switch makes a missing screen a compile error.
- **`NavigationSplitView` for multi-column** (iPad/Mac); **`.sheet`/`.fullScreenCover`/`.alert`
  driven by `@State` or an optional `item:`** for modal, non-addressable surfaces.

## 6. Concurrency in views

In-view async obeys the whole [swift.md](../languages/swift.md) §4 contract — structured tasks,
`Sendable` boundaries, bounded awaits.

- **`.task` for view-lifetime async work**, not `onAppear { Task { … } }`. `.task` inherits the
  view's lifetime and **cancels automatically when the view disappears**; use `.task(id:)` to restart
  when an input changes. A bare `Task {}` in `onAppear` leaks and double-fires.
  ```swift
  .task(id: query) { await model.search(query) }   // auto-cancelled, restarts on query change
  ```
- **The view and its model are `@MainActor`.** Read/write UI state on the main actor; hop to the
  background only for the actual work, and come back to publish results — no manual
  `DispatchQueue.main.async`.
- **Bound every external await** (network/IO) with a timeout/deadline and respect cancellation —
  there is no implicit timeout ([resilience.md](../design/resilience.md)). Don't `sleep`-and-hope.
- **Never block the main actor** waiting on async work; a synchronous wait in `body` freezes the
  frame. Model loading/empty/error as explicit state and render it (mirrors swift.md error rules).

## 7. Performance & identity

- **Identity drives diffing — get it right first.** In a `ForEach`, key on a **stable domain ID**
  (`Identifiable`/`id:`), never the array index when rows insert or reorder; a wrong key recycles
  state into the wrong row. This is the §1 composition rule's runtime payoff.
- **Lazy containers for long/unbounded content** — `LazyVStack`/`LazyVGrid` and `List` build cells on
  demand; a plain `VStack` in a `ScrollView` materialises every child up front. Use `List` for
  standard rows (it recycles); lazy stacks/grids for custom layouts.
- **Minimise `@State` and keep it local** — the smaller and lower a view's state, the smaller its
  rebuild blast radius. Observation already scopes rebuilds to the properties read; don't widen them
  by hoisting state or reading a whole model where one field would do.
- **Make expensive subviews `Equatable`** and apply `.equatable()` (or rely on synthesized
  conformance) so SwiftUI can skip a rebuild when inputs are unchanged — measure first, it isn't free.
- **Keep `body` pure and cheap.** No I/O, no controller allocation, no heavy compute — `body` can run
  every frame; move costly work to the model, `.task`, or a cached value. _(scale-up)_ Profile with
  **Instruments (SwiftUI template)** and the "Cause of view updates" signposts; never optimise by guess.

## 8. Previews

- **Every non-trivial view ships a `#Preview`** (the macro, iOS 17+) — previews are the fast inner
  loop and double as living documentation of a view's states.
- **Preview the states, not just the happy path** — empty, loading, error, long text, and inject
  fixture data through the initializer or a preview `@Environment` model. A view that's hard to
  preview is usually a view doing too much (§1).
- **Exercise the matrix in-preview**: `.preferredColorScheme(.dark)`, Dynamic Type
  (`.dynamicTypeSize(.accessibility3)`), and RTL (`.environment(\.layoutDirection, .rightToLeft)`)
  catch layout breaks before the simulator does (§10).

## 9. Platform integration (the UIKit bridge)

- **Stay in SwiftUI until you genuinely can't.** Reach for **`UIViewRepresentable` /
  `UIViewControllerRepresentable`** (or `NSView…` on macOS) only for a capability SwiftUI lacks — a
  `WKWebView`, a camera preview layer, a mature UIKit control. Check for a native SwiftUI API first
  (`PhotosPicker`, `Map`, `ShareLink` replaced their bridges).
- **Implement `Coordinator` for delegation/callbacks** and keep `updateUIView` a pure projection of
  SwiftUI state onto the UIKit object — no side effects. Treat the wrapper as an adapter: SwiftUI
  state in, user events out via bindings/closures.

## 10. Accessibility

Full bar in [accessibility.md](../practices/accessibility.md); the SwiftUI mapping:

- **SwiftUI gives you semantics for free — don't break them.** Standard controls (`Button`, `Toggle`,
  `Label`) are already accessible; preserve that by using them over tap-gesture'd `Text`. For custom
  controls, supply `.accessibilityLabel`, `.accessibilityValue`, `.accessibilityHint`, and the right
  `.accessibilityAddTraits(.isButton)`.
- **Group and prune for the screen reader**: `.accessibilityElement(children: .combine)` to merge a
  composite into one announcement, `.accessibilityHidden(true)` for purely decorative content.
- **Honour system settings**: support **Dynamic Type** (scalable fonts, no hard-coded heights),
  meet WCAG **2.2 AA** contrast, and gate animation on `@Environment(\.accessibilityReduceMotion)`.
- **Verify with VoiceOver** and the **Accessibility Inspector**; audit Dynamic Type and dark mode in
  previews (§8) so a11y regressions surface in the inner loop.

## 11. Testing

Strategy and coverage floors live in [testing-strategy.md](../practices/testing-strategy.md) and
[swift.md](../languages/swift.md) §8. The SwiftUI split:

| Layer | Tool | Tests |
|---|---|---|
| **Model / logic** | **Swift Testing** (`@Test`, `#expect`) | `@Observable` models, derived state, navigation reducers — pure, no view rendered |
| **End-to-end UI** | **XCUITest** (`XCUIApplication`) | Real flows on a simulator: auth, navigation, deep links — query by accessibility id/label |
| **View unit** _(scale-up)_ | **ViewInspector** | Assert a `body`'s structure/state without a host app; a third-party dep — adopt deliberately |

- **Push logic into the model so most tests need no UI** (§4) — fast, deterministic Swift Testing
  cases over an `@Observable` store are the bulk of the suite. This is the payoff for keeping `body`
  thin.
- **XCUITest drives the critical path** end-to-end; query elements by **accessibility identifier**
  (a stable contract, set via `.accessibilityIdentifier`), never by visible string — that doubles as
  an a11y check (§10) and survives copy changes.
- **`ViewInspector` is the only way to unit-test a `body`'s tree** today (SwiftUI ships no view-test
  API); treat it as a _(scale-up)_ dependency for design-critical views, not a default. Keep tests
  deterministic — no `sleep`, await outcomes (swift.md §8).

## Definition of done

- [ ] Language DoD met ([swift.md](../languages/swift.md)): Swift 6 concurrency clean, no fallible force-unwraps, value-type models, `swift format lint --strict`, supply chain
- [ ] Views are small and composed; subviews extracted over helper methods; no reflexive `AnyView` (§1)
- [ ] State uses **Observation** (`@Observable` + `@State`/`@Bindable`/`@Environment`); no `ObservableObject`/`@Published`/`@StateObject` in new code (§2)
- [ ] One source of truth per state; data flows down, events up; derived values computed, not duplicated (§3)
- [ ] Plain-SwiftUI (MV) default — logic on `@MainActor` `@Observable` models, not in `body`; per-repo pattern stated (§4)
- [ ] Navigation via `NavigationStack` + value-driven/type-safe path; programmatic nav mutates the path (§5)
- [ ] Async via `.task`/`.task(id:)` (auto-cancelled); awaits timeout-bounded; main-actor isolation respected (§6)
- [ ] Stable identity in `ForEach`; lazy containers/`List` for long content; `body` pure; profiled in Instruments where needed (§7)
- [ ] Non-trivial views have `#Preview`s covering empty/loading/error + dark mode + Dynamic Type (§8)
- [ ] UIKit bridged only where SwiftUI lacks an API; `updateUIView` side-effect-free (§9)
- [ ] A11y labels/traits on custom controls; Dynamic Type + AA contrast; reduce-motion honoured; VoiceOver verified (§10)
- [ ] Logic tested with Swift Testing; critical flows with XCUITest by accessibility id; deterministic, no sleeps (§11)

**Sources:** [Apple — Migrating from the Observable Object protocol to the Observable macro](https://developer.apple.com/documentation/SwiftUI/Migrating-from-the-observable-object-protocol-to-the-observable-macro)
& [Managing model data in your app](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app) ·
[Observation framework](https://developer.apple.com/documentation/observation) ·
[NavigationStack](https://developer.apple.com/documentation/swiftui/navigationstack) ·
[SwiftUI accessibility](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals) ·
[Swift Testing](https://developer.apple.com/documentation/testing) ·
[ViewInspector](https://github.com/nalexn/ViewInspector)
