# Jetpack Compose Standards

Framework layer; language rules → [java-kotlin.md](../languages/java-kotlin.md). Everything there
still holds — Kotlin null-safety (never `!!`), coroutines + structured concurrency, sealed types
with exhaustive `when`, and the Gradle + version-catalog toolchain. This doc owns only what's
*Compose*: the `@Composable` model, state and the snapshot system, unidirectional data flow,
recomposition and stability, `ViewModel` + `StateFlow` architecture, Navigation Compose, Material 3,
side effects, accessibility, testing, and previews. The cross-platform siblings that also ship to
Android are [flutter.md](flutter.md) and [react-native.md](react-native.md). Defers accessibility →
[accessibility.md](../practices/accessibility.md), test philosophy →
[testing-strategy.md](../practices/testing-strategy.md), the timeout/cancel contract →
[resilience.md](../design/resilience.md), and dependencies/supply-chain → [java-kotlin.md](../languages/java-kotlin.md) + [security.md](../practices/security.md).

> **One law:** state flows down, events flow up — a composable is a pure function of its state, and
> the only way to change the UI is to change the state it reads.

---

## 1. Toolchain & versions

| Concern | Tool | Notes |
|---|---|---|
| Dependency alignment | **Compose BOM (latest stable — verify the current release)** | `platform("androidx.compose:compose-bom:…")` pins every Compose artifact to one tested set; bump the BOM as a unit, never a single `androidx.compose.*` version. |
| Compiler | **Compose Compiler Gradle plugin** (`org.jetbrains.kotlin.plugin.compose`) | Kotlin 2.0+; the compiler version *is* the Kotlin version. Configure metrics/stability here, not in `kotlinOptions`. |
| Design system | **Material 3** (`androidx.compose.material3`) | Material 2 is legacy — don't start on it. |
| Lifecycle/state | **`lifecycle-viewmodel-compose` + `lifecycle-runtime-compose`** | Supplies `viewModel()` and `collectAsStateWithLifecycle` (§7). |
| Navigation | **Navigation Compose ≥ 2.8** + `kotlinx-serialization` | Type-safe routes are stable from 2.8 (§9). |
| DI | **Hilt** (`hilt-navigation-compose`) | Scopes `ViewModel`s to nav entries; the sanctioned DI default. |
| Test | **`createComposeRule` / `createAndroidComposeRule`** | Semantics-based UI tests (§12). |

- **Strong skipping is on** — default since Kotlin 2.0.20; don't disable it. It lets composables with
  unstable params skip and memoizes lambdas with unstable captures, so most over-recomposition (§6)
  disappears for free. Build config, locking, and reproducibility follow [java-kotlin.md](../languages/java-kotlin.md).

## 2. Everyday commands

```bash
./gradlew :app:assembleDebug                       # build
./gradlew :app:testDebugUnitTest                   # JVM unit + Robolectric Compose tests
./gradlew :app:connectedDebugAndroidTest           # on-device/emulator UI tests (§12)
./gradlew :app:lintDebug                            # Android Lint (Compose rules on)
# Compose compiler stability + recomposition metrics (§6) — diff the report on perf-sensitive PRs:
./gradlew assembleRelease \
  -Pandroidx.enableComposeCompilerMetrics=true \
  -Pandroidx.enableComposeCompilerReports=true
```

## 3. Composable functions

A `@Composable` is a description of UI for a given state, not an imperative draw call. The runtime may
call it **any number of times, in any order, on any thread, or skip it** — so it must be free of
side effects (§8) and cheap to re-run.

- **Make composables stateless and hoist state.** A reusable composable takes its `value` plus an
  `onValueChange: (T) -> Unit` and owns no state itself — state lives in the lowest common ancestor
  that needs it. Stateless composables are previewable (§13), testable, and reusable by construction.
  ```kotlin
  @Composable
  fun NameField(name: String, onNameChange: (String) -> Unit) {   // stateless: value in, event out
      OutlinedTextField(value = name, onValueChange = onNameChange)
  }
  ```
- **Name UI-emitting composables as nouns, `PascalCase`, returning `Unit`.** A composable that
  returns a value is a smell — extract it to a plain function or a `remember`ed calculation.
- **Pass data down, not the whole `ViewModel`.** A leaf takes the fields it renders, never the VM —
  it keeps leaves preview-friendly and stops them reaching for state they shouldn't read.
- **Keep composables small.** Extract a sub-tree into its own composable so the runtime gets a
  finer-grained recomposition scope — a 200-line `Column` recomposes as one unit.

## 4. State & the snapshot system

State that the UI reads must be **observable Compose state**, so a write schedules recomposition of
exactly the readers — a plain `var` is invisible to the runtime.

- **`remember { mutableStateOf(...) }` for transient UI state.** `remember` survives recomposition;
  the bare `mutableStateOf` does not. Use `by` delegation for ergonomic reads/writes.
  ```kotlin
  var query by remember { mutableStateOf("") }      // survives recomposition, lost on config change
  ```
- **`rememberSaveable` for state that must survive process death / rotation** (scroll-adjacent UI,
  expanded/collapsed flags, wizard step). Anything that belongs to the screen's *data* belongs in the
  `ViewModel` (§7), not in `rememberSaveable`.
- **`derivedStateOf` for state computed from other state** that changes less often than its inputs —
  it recomposes readers only when the *result* changes (e.g. `firstVisibleItemIndex > 0`). Don't wrap
  a cheap, always-changing derivation in it; that's pure overhead.
- **Use the right collection.** `mutableStateListOf` / `mutableStateMapOf` are observable; mutating a
  plain `ArrayList` held in state changes nothing on screen.
- **Snapshots give you atomic, thread-safe reads/writes** — never mutate Compose state from a
  background thread without going through the snapshot system; mutate from the main thread or a
  `withMutableSnapshot` block.

## 5. Unidirectional data flow

- **State down, events up.** A composable reads immutable state and emits events via lambdas; it never
  reaches back up to mutate a parent's field. The parent (or `ViewModel`) owns the state and is the
  only writer — this is the framework face of the "One law" above.
- **Model a screen as a single immutable `UiState`** (a `data class` / sealed hierarchy, §7), not a
  bag of independent `mutableStateOf` flags that can drift out of sync.
- **Events are explicit and named** (`onSubmit`, `onRetry`) — not a generic `onClick` that hides
  intent. The handler lives where the state lives, so cause and effect stay co-located.

## 6. Recomposition & performance

The **#1 Compose footgun is unstable parameters forcing over-recomposition** — a composable can only
skip if *all* its params are stable and `equals`-comparable. One unstable param and it re-runs every
time its parent does, cascading down the tree.

- **Prefer stable, immutable params.** Stable types: primitives, `String`, function types, and any
  class the compiler infers stable (all `val` properties of stable types). **Unstable by default:**
  `List`/`Map`/`Set` interfaces (the compiler can't prove the impl is immutable), `var` properties,
  and types from modules without the Compose compiler.
- **Make types stable explicitly.** Use **`kotlinx.collections.immutable`** (`ImmutableList`) for
  collection params, or annotate a value class `@Immutable` (deeply unchanging) / `@Stable` (mutations
  go through Compose state). A wrong annotation is a correctness bug — it silently drops needed
  recompositions.
  ```kotlin
  @Immutable data class Filters(val tags: ImmutableList<String>, val onlyFavourites: Boolean)
  ```
- **For types you don't own** (a DTO from another module), add a **stability-config file**
  (`stabilityConfigurationFile`) listing them as stable rather than wrapping every one.
- **Defer state reads to the lowest point.** Read scroll/animation state in a lambda or `Modifier`
  factory (`Modifier.offset { … }`, `graphicsLayer { … }`) so only layout/draw re-runs, not
  composition. Reading a fast-changing state high in the tree recomposes everything below it.
- **Key your lazy-list items** — `items(list, key = { it.id })` in `LazyColumn`/`LazyRow`. Without a
  stable key, an insert/reorder recomposes and loses item state, exactly like the list rules in the
  siblings. Never the index when items move.
- **Measure, don't guess.** Generate the **Compose compiler metrics** (§2) and read which composables
  are `restartable` but not `skippable` and which params are `unstable`; profile with the Layout
  Inspector's recomposition counts. Optimise what the report names. _(scale-up: ship a **Baseline
  Profile** for the critical user journey — it removes first-run jank by AOT-compiling the hot path.)_

## 7. Architecture (ViewModel + UiState)

- **`ViewModel` owns screen state and business logic; the composable renders it.** Expose **one
  `StateFlow<UiState>`** (a `data class` or sealed `Loading/Content/Error` hierarchy), built with
  `stateIn(viewModelScope, WhileSubscribed(5_000), …)` so upstream flows stop when the UI is
  backgrounded and resume without re-fetching on a quick rotation.
- **Collect with `collectAsStateWithLifecycle()`**, never bare `collectAsState()` — the lifecycle-aware
  collector stops gathering when the app is in the background, avoiding wasted work and hidden leaks.
  ```kotlin
  @Composable
  fun ProfileScreen(vm: ProfileViewModel = hiltViewModel()) {
      val state by vm.uiState.collectAsStateWithLifecycle()
      ProfileContent(state, onRefresh = vm::refresh)   // stateless child (§3)
  }
  ```
- **Scope `ViewModel`s to the nav entry** via `hiltViewModel()` (§9) so they live and die with the
  destination. **No Android framework types in the `ViewModel`** (no `Context`, `View`) — keep it
  plain so it unit-tests as ordinary Kotlin.
- **One-shot events** (snackbar, navigation) go through a `Channel`/`SharedFlow`, **not** the `UiState`
  — a state field re-fires the event on every recomposition and config change.

## 8. Side effects & coroutines

Effects bridge the declarative tree to the imperative world; each has a precise job. Coroutine and
`Flow` fundamentals stay in [java-kotlin.md](../languages/java-kotlin.md) §6.

| Need | API | Rule |
|---|---|---|
| Run suspend work tied to composition | **`LaunchedEffect(key)`** | Cancels + relaunches when `key` changes; keep keys honest. `Unit`/`true` = run once. |
| Launch a coroutine from a **callback** | **`rememberCoroutineScope()`** | For `onClick`-driven work — never call a `suspend` fun directly in a composable body. |
| Subscribe/cleanup non-Compose resources | **`DisposableEffect(key)`** | Must return `onDispose { }` — register a listener, unregister it there. |
| Expose a snapshot value to a non-Compose API | **`rememberUpdatedState`** | Capture the latest value inside a long-lived effect without restarting it. |
| Bridge Compose state out to a side effect | **`snapshotFlow { … }`** | Turn `State` reads into a `Flow` (e.g. analytics on scroll position). |

- **Never mutate state or do I/O directly in a composable body** — it runs on every recomposition.
  All of it belongs in an effect (or, better, the `ViewModel`).
- **Bound suspend work with timeouts/cancellation** per [resilience.md](../design/resilience.md); a
  `LaunchedEffect` is cancelled when it leaves composition, but the *call it makes* still needs a
  deadline.

## 9. Navigation

- **Navigation Compose with type-safe routes** (≥ 2.8). Routes are `@Serializable` objects (no args)
  or `data class`es (typed args) — a renamed field is a compile error, not a crashed deep link.
  ```kotlin
  @Serializable data object Home
  @Serializable data class Profile(val userId: String)

  NavHost(navController, startDestination = Home) {
      composable<Home> { HomeScreen(onOpen = { navController.navigate(Profile(it)) }) }
      composable<Profile> { ProfileScreen() }            // reads typed args via toRoute()
  }
  ```
- **A single `NavHost` owns the back stack**; pass typed objects to `navigate()`, read args with
  `backStackEntry.toRoute<Profile>()`. Don't smuggle complex objects through args — pass an ID and
  load from the `ViewModel`.
- **`hiltViewModel()` scopes each screen's `ViewModel` to its nav entry** (§7); handle deep links
  declaratively on the destination, not with imperative branching.

## 10. Material 3 & theming

- **One `MaterialTheme` at the root**, driven by tokens — color scheme, typography, shapes — never
  hard-coded `Color(0xFF…)` or `.dp` literals scattered through the tree. Read them via
  `MaterialTheme.colorScheme` / `.typography`.
- **Support dynamic color on Android 12+** (`dynamicLightColorScheme`/`dynamicDarkColorScheme`) with a
  brand fallback, and a real **dark theme** — switch the scheme, don't fork the UI.
- **Consume the system insets** with `Scaffold` + `WindowInsets` (`Modifier.safeDrawingPadding()`);
  the app is edge-to-edge by default on current Android, so never hard-code status/navigation-bar
  offsets — the safe-area rule shared with the siblings.

## 11. Accessibility

First-class, not a final pass — the full bar is [accessibility.md](../practices/accessibility.md);
the Compose specifics:

- **Set `contentDescription` on every meaningful `Icon`/`Image`**, and `null` on purely decorative
  ones so the screen reader skips them. Icon-only buttons must be labelled.
- **Fix semantics with the `Modifier.semantics { }` block** — merge a composite control with
  `mergeDescendants`, set `role = Role.Button` on custom tappables, `stateDescription` for toggles,
  and `heading()` for section titles. Use `clearAndSetSemantics` to collapse decorative noise.
- **Respect system settings**: don't cap font scaling (size in `sp`, not `dp`), meet WCAG **AA**
  contrast, gate animations on the reduce-motion setting, and keep touch targets ≥ 48 dp
  (`minimumInteractiveComponentSize`). Verify with TalkBack and the Accessibility Scanner.

## 12. Testing

- **`createComposeRule()` for pure-Compose tests** (run under Robolectric on the JVM where possible);
  `createAndroidComposeRule<Activity>()` only when you need a real Activity. UI tests live in
  `androidTest`; `ViewModel`/logic tests are plain JVM unit tests (§7).
- **Query and assert through the semantics tree**, never widget internals: `onNodeWithText`,
  `onNodeWithContentDescription`, `onNodeWithTag` (`Modifier.testTag`), then `performClick()` /
  `assertIsDisplayed()`. Semantics-based tests double as accessibility checks (§11) and survive
  refactors.
  ```kotlin
  composeTestRule.setContent { NameField(name = "Ada", onNameChange = {}) }
  composeTestRule.onNodeWithText("Ada").assertIsDisplayed()
  ```
- **Control the clock for animations/async** with `mainClock.autoAdvance = false` + `advanceTimeBy`,
  and `waitUntil` for state to settle — don't sleep. Test philosophy and the coverage ratchet stay in
  [testing-strategy.md](../practices/testing-strategy.md); mock only genuine external collaborators
  per [java-kotlin.md](../languages/java-kotlin.md) §7.
- **Screenshot-test design-critical composables** _(scale-up)_ — render to a reference PNG (Paparazzi
  on the JVM, or Roborazzi) and fail on pixel drift; regenerate goldens in the same PR with rationale.

## 13. Previews

- **`@Preview` every reusable composable in its stateless form** — pass sample state directly so the
  preview needs no `ViewModel` or network. This is the payoff for hoisting state (§3).
- **Cover the states that matter** with a `@PreviewParameter` provider or multiple annotated functions:
  loading / content / error, **light and dark** (`uiMode`), and a large-font / RTL variant to catch
  layout and a11y breaks early.
- **Previews are not tests** — they verify appearance, not behaviour. Keep them building (a broken
  preview rots fast) but don't let them substitute for §12.

## Definition of done

- [ ] Compose dependencies aligned via the **BOM**; Compose Compiler Gradle plugin on; Material 3, not M2
- [ ] Reusable composables are **stateless with hoisted state**; leaves take data + event lambdas, not the `ViewModel`
- [ ] UI state is observable Compose state (`remember`/`rememberSaveable`/`derivedStateOf`); no plain `var` read by the UI
- [ ] Unidirectional flow held — one immutable `UiState` per screen; state down, named events up
- [ ] Stability respected: collection params are immutable/`@Immutable`; lazy lists keyed; reads deferred; metrics checked on perf PRs
- [ ] `ViewModel` exposes one `StateFlow<UiState>`, collected with **`collectAsStateWithLifecycle`**; no Android types in the VM; one-shot events off `UiState`
- [ ] Side effects use the right API (`LaunchedEffect`/`rememberCoroutineScope`/`DisposableEffect`); no I/O or state mutation in a composable body; suspend work timeout-bounded
- [ ] Navigation Compose with **type-safe `@Serializable` routes**; one `NavHost`; `ViewModel`s scoped to nav entries
- [ ] Themed from `MaterialTheme` tokens (dynamic color + dark theme); edge-to-edge with system insets; no hard-coded colors/offsets
- [ ] `contentDescription` + `semantics` correct; AA contrast, `sp` text, ≥ 48 dp targets; verified with TalkBack
- [ ] UI tests via `createComposeRule` query the **semantics tree**; clock controlled for async; coverage ≥ ratcheted floor
- [ ] Reusable composables have `@Preview`s covering loading/content/error and light/dark

**Sources:** [Compose BOM](https://developer.android.com/develop/ui/compose/bom) &
[Compose Compiler plugin](https://developer.android.com/develop/ui/compose/setup-compose-dependencies-and-compiler) ·
[State & state hoisting](https://developer.android.com/develop/ui/compose/state) ·
[Stability & strong skipping](https://developer.android.com/develop/ui/compose/performance/stability/strongskipping) ·
[Side effects](https://developer.android.com/develop/ui/compose/side-effects) ·
[Type-safe navigation](https://developer.android.com/guide/navigation/design/type-safety) ·
[Architecture (UI layer)](https://developer.android.com/topic/architecture/ui-layer) ·
[Testing Compose](https://developer.android.com/develop/ui/compose/testing) ·
[Compose accessibility](https://developer.android.com/develop/ui/compose/accessibility)
