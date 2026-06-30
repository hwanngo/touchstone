---
name: jetpack-compose-standards
description: Use when building native-Android UI with Jetpack Compose in a touchstone repo — composables, state & recomposition, unidirectional data flow, ViewModel + StateFlow, Navigation Compose, Material 3, side effects, and Compose testing. Triggers on `@Composable` functions, `androidx.compose`/compose-bom in build.gradle(.kts), `setContent`/`NavHost`, Material 3 UI. For Kotlin-language rules (null-safety, coroutines, Gradle, JUnit) use the java-kotlin skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Jetpack Compose (framework)

Full standard: **`standards/frameworks/jetpack-compose.md`** (layers on
`standards/languages/java-kotlin.md`). The Kotlin rules there still hold — null-safety (no `!!`),
coroutines + structured concurrency, sealed types, the Gradle/version-catalog toolchain. This skill
inlines the load-bearing Compose rules so it stays useful installed standalone in `~/.claude/skills/`:

## Always
- **Stateless composables + hoisted state.** A reusable composable takes `value` + an
  `onValueChange` lambda and owns no state; state lives in the lowest common ancestor. Pass data down,
  not the whole `ViewModel`. This is what makes previews and tests work.
- **State down, events up.** One immutable `UiState` per screen; the `ViewModel` is the only writer.
  UI state must be observable Compose state — `remember { mutableStateOf }` (transient),
  `rememberSaveable` (survives rotation/process death), `derivedStateOf` (computed). A plain `var` read
  by the UI is invisible to the runtime.
- **`ViewModel` exposes one `StateFlow<UiState>`**, collected with **`collectAsStateWithLifecycle()`**
  (never bare `collectAsState`). One-shot events (snackbar/nav) go through a `Channel`/`SharedFlow`,
  not `UiState`. No Android types in the `ViewModel`.
- **Compose BOM** aligns all `androidx.compose.*` versions; Compose Compiler Gradle plugin on;
  Material 3 (not M2). Strong skipping is the default — don't disable it.

## Don't get burned
- **Unstable params force over-recomposition** — the #1 footgun. A composable skips only if *all*
  params are stable. `List`/`Map`/`Set` and `var`-bearing types are unstable: use
  `kotlinx.collections.immutable` (`ImmutableList`) or `@Immutable`/`@Stable` (a wrong annotation is a
  correctness bug). Key lazy-list items (`items(list, key = { it.id })`); defer fast-changing state
  reads into `Modifier`/lambda. Check the Compose compiler metrics on perf PRs.
- **No side effects in a composable body** — it runs on every recomposition. Suspend work →
  `LaunchedEffect(key)`; callback-driven work → `rememberCoroutineScope()`; subscribe/cleanup →
  `DisposableEffect` with `onDispose`. Bound suspend work with timeouts ([resilience](../../standards/design/resilience.md)).
- **Navigation Compose with type-safe `@Serializable` routes** (≥ 2.8) — pass an ID, not a fat object;
  scope `ViewModel`s to the nav entry (`hiltViewModel()`).
- **Accessibility**: `contentDescription` on meaningful images (`null` on decorative), fix the
  `semantics { }` tree, AA contrast, `sp` text, ≥ 48 dp targets — verify with TalkBack.

## Done
BOM + compiler plugin · stateless/hoisted composables · observable state, UDF, one `UiState` ·
`collectAsStateWithLifecycle` · stability respected (immutable params, keyed lists, metrics checked) ·
effects use the right API, timeout-bounded · type-safe Navigation Compose · Material 3 tokens +
edge-to-edge · semantics/TalkBack a11y · `createComposeRule` tests query the semantics tree ·
`@Preview`s cover states. See `standards/frameworks/jetpack-compose.md`.
