# Flutter & Dart Standards

How to build a good Flutter app — the framework layer **and** the Dart language layer, which
live here together: there is no separate `dart.md`, so the language essentials (§3) are inline.
Applies to cross-platform Flutter apps (latest stable Flutter / Dart 3.x — verify the current release) built feature-first, state
managed with **Riverpod**, navigated with **go_router**, and tested with the SDK's own
`flutter_test` + `integration_test`. The native-iOS sibling is [swift.md](../languages/swift.md);
shared concerns defer to the practice docs linked below rather than being restated here —
dependency and supply-chain policy (pub / `pubspec.lock`, advisory scanning) lives in
[dependencies.md](../practices/dependencies.md) + [security.md](../practices/security.md).

> **One law:** a `const` widget that never rebuilds beats any amount of `setState` cleverness —
> push state to the leaves, keep the tree cheap.

---

## 1. Toolchain & versions

| Concern | Tool | Notes |
|---|---|---|
| SDK version | **FVM** (Flutter Version Management) | Pin per-repo in `.fvmrc`; CI and every dev use the same channel + build. Never rely on a globally-installed `flutter`. |
| Dart | Ships with Flutter | Don't install Dart separately — the bundled SDK is the source of truth. |
| Formatter | **`dart format`** | Non-negotiable, zero-config, enforced in CI. |
| Analyzer / linter | **`dart analyze`** + **`very_good_analysis`** | Strict lint set on top of the analyzer; config in `analysis_options.yaml`. |
| Test runner | **`flutter test`** / **`integration_test`** | Unit + widget + on-device E2E (§14). |
| Packages | **pub** | `flutter pub get`; **commit `pubspec.lock`** for apps. |

- **Pin the SDK with FVM and commit `.fvmrc`.** A floating SDK is how "works on my machine" starts;
  CI runs `fvm install && fvm flutter ...` and the version is reviewed like any other dep.
- **Commit `pubspec.lock` for application repos** (reproducible builds); **gitignore it for
  published packages** so consumers resolve against their own constraints — opposite call, opposite
  reason. Constrain deps with caret ranges (`^1.4.0`), not `any`; run `flutter pub outdated` on a
  schedule and update deliberately.

## 2. Everyday commands

```bash
fvm flutter pub get                       # resolve deps from pubspec.lock
fvm dart format .                          # auto-format
fvm dart format --output=none --set-exit-if-changed .   # verify (what CI runs)
fvm dart analyze                           # lint + static analysis (fatal-infos in CI)
fvm flutter test                           # unit + widget tests
fvm flutter test --coverage                # with lcov coverage
fvm dart run build_runner build --delete-conflicting-outputs   # codegen (§9)
fvm flutter build apk --flavor prod -t lib/main_prod.dart      # release artifact (§15)
```

## 3. Dart language essentials

- **Sound null safety is mandatory** — no `// @dart=2.x` opt-outs, and `dynamic` is a code smell.
  Avoid the bang operator `!`; prefer `?.`, `??`, pattern-matching, or an explicit guard that
  narrows the type. Each `!` is an unchecked assertion you're promising the compiler.
- **Records** for lightweight, structural multi-value returns instead of one-off classes:
  `(int code, String body)`. **Patterns + exhaustive `switch`** for destructuring and control flow.
- **Sealed class hierarchies** model closed sets (UI state, domain results) so a `switch`
  expression is checked-exhaustive — add a variant and every unhandled `switch` becomes a compile
  error, not a runtime surprise.
  ```dart
  sealed class Result<T> {}
  final class Ok<T>  extends Result<T> { const Ok(this.value);  final T value; }
  final class Err<T> extends Result<T> { const Err(this.error); final Object error; }

  String render(Result<int> r) => switch (r) {
    Ok(:final value) => 'got $value',
    Err(:final error) => 'failed: $error',   // omit a case → compile error
  };
  ```
- **`final` by default, `const` for compile-time constants.** Immutability is the default posture.
- **Strict analyzer.** Turn infos into build failures and enable the strict language modes — they
  catch real bugs (implicit `dynamic`, unsound casts) the defaults wave through:
  ```yaml
  # analysis_options.yaml
  include: package:very_good_analysis/analysis_options.yaml
  analyzer:
    language:
      strict-casts: true
      strict-raw-types: true
    errors:
      invalid_annotation_target: ignore   # noisy with freezed/json_serializable
  ```

## 4. Project structure (feature-first)

**Organise by feature, not by layer** — a global `models/`–`widgets/`–`services/` split doesn't
scale, exactly as in [react.md](react.md). Colocate everything a feature owns under
`lib/features/<name>/`; reserve `lib/core/` (or `lib/shared/`) for genuinely cross-feature code.

```text
lib/
  core/        # theme, router, DI, shared widgets, env config
  features/<feature>/
    data/        # repositories, dio clients, DTOs (json_serializable §9)
    domain/      # entities, value objects, repository interfaces
    application/ # Riverpod providers / notifiers (§5)
    presentation/# screens + widgets (§6)
  main_dev.dart  main_prod.dart   # flavor entrypoints (§15)
```

- **Dependencies point inward**: `presentation → application → domain ← data`. The domain layer
  knows nothing about Flutter, dio, or JSON — keep `package:flutter` out of it so it stays
  testable as plain Dart. _(scale-up: enforce with `dart_code_metrics` import rules.)_
- **One feature never reaches into another's internals** — compose features at the router / `core`
  layer, not by importing a sibling's `presentation/`.

## 5. State management

**Riverpod is the default.** It is compile-safe, testable without a `BuildContext`, and its
code-generated providers give you the right rebuild scope for free.

- **Annotate providers with `@riverpod` (riverpod_generator)** — the generated providers are
  type-safe, auto-dispose by default, and refactor cleanly. Use `Notifier`/`AsyncNotifier` for
  state that holds logic; a plain function provider for derived/read-only values.
  ```dart
  @riverpod
  class TodoList extends _$TodoList {
    @override
    Future<List<Todo>> build() => ref.watch(todoRepositoryProvider).fetchAll();

    Future<void> add(Todo t) async {
      state = const AsyncLoading();
      state = await AsyncValue.guard(() => ref.read(todoRepositoryProvider).create(t));
    }
  }
  ```
- **Model async state with `AsyncValue`** and render it with `.when(data/loading/error)` — loading
  and error become structural, not a scatter of `if (isLoading)` flags. Wrap mutations in
  `AsyncValue.guard` so thrown errors land in the error state instead of crashing.
- **`ref.watch` to react, `ref.read` to act.** `ref.read`-ing a value you should rebuild on is the
  Riverpod equivalent of a stale closure.
- **`setState` is for genuinely local, ephemeral widget state only** (animation toggles, a text
  controller). The moment state is shared, derived, or fetched, it belongs in a provider — lifting
  business state into `setState` and prop-drilling it is the anti-pattern this section exists to kill.
- **Bloc is the sanctioned escape hatch**, not a parallel default — reach for it when a feature has
  genuinely complex, event-driven state machines that want the explicit event→state ceremony.
  **Pick one per repo and state it** — don't run Riverpod and Bloc side by side.

## 6. Widgets

- **Composition over inheritance.** Build UIs by nesting small widgets and passing
  `child`/`children`; never subclass a concrete widget to tweak it. Extract a `class` widget over a
  `_buildHeader()` helper — a real widget gets its own rebuild boundary and a `const` constructor;
  a helper method always rebuilds with its parent.
- **`const` constructors everywhere they're legal.** A `const` widget is canonicalised and skipped
  during rebuilds — the single highest-leverage perf habit in Flutter. The
  `prefer_const_constructors` lint (very_good_analysis) enforces it; treat its findings as bugs.
- **Keep `build` methods pure and cheap** — no I/O, no controller allocation, no expensive compute.
  `build` can run every frame; costly work belongs in `initState`, a provider, or a memoised value.
- **Keys only when identity matters** — reordering/inserting/removing in a list, or preserving state
  across a widget-type swap. Use `ValueKey`/`ObjectKey` on stable domain IDs; **never** the list
  index when items move. Most static widgets need no key.

## 7. Navigation

- **`go_router` is the standard router** — declarative, URL-based routes that behave identically on
  mobile and web, with deep-link and redirect support built in. Don't hand-roll `Navigator.push`
  stacks for app-level navigation.
- **Centralise routes in one typed router** (`core/router.dart`); guard authenticated areas with
  `redirect` reading auth state from a Riverpod provider, so a logout reactively bounces the user
  out. Prefer **type-safe routes** (`go_router_builder`) so a renamed param is a compile error.
- Reserve raw `Navigator` for **local, ephemeral** surfaces (a dialog, a bottom sheet) outside the
  addressable route graph.

## 8. Async & isolates

- **`Future` for one value, `Stream` for many.** Always `await` or explicitly handle a returned
  `Future` — an unawaited future swallows its error. The `unawaited_futures` lint catches the
  fire-and-forget case; wrap deliberate ones in `unawaited(...)`.
- **Cancel every subscription.** A `StreamSubscription`, `AnimationController`, or `TextEditingController`
  created in a widget must be disposed in `dispose()` (or use Riverpod's `ref.onDispose`) — a live
  subscription on a dead widget is a leak and a `setState`-after-dispose crash.
- **Offload CPU-bound work to an isolate** — the UI runs on one isolate, and any synchronous work
  over a frame budget (~16 ms) janks it. Use **`compute()`** for a one-shot, or `Isolate.run`
  (Dart 3) for heavier jobs (parsing a large payload, image processing, crypto). Isolates don't
  share memory — pass only sendable data.
  ```dart
  final parsed = await compute(parseBigJson, rawBytes);   // runs off the UI isolate
  ```
- Timeouts, retries, and cancellation are the async face of the resilience rules in
  [resilience.md](../design/resilience.md) — bound network awaits with `.timeout(...)`.

## 9. Networking & serialization

- **`dio` for HTTP** — interceptors (auth, logging, retry), cancellation tokens, and typed errors
  out of the box, which bare `http` lacks. Configure one `Dio` instance with a `baseUrl` and
  timeouts; inject it through a Riverpod provider so tests can supply a mock adapter.
- **Never hand-write `fromJson`/`toJson`.** Generate them. Two tools, two jobs:

  | Need | Tool | Why |
  |---|---|---|
  | Plain DTO (de)serialization | **`json_serializable`** | Generated, exhaustive `fromJson`/`toJson`; no typo'd keys. |
  | Immutable domain model + unions + copy | **`freezed`** | `const` value objects, `copyWith`, sealed unions, equality — all generated. |

  ```dart
  @freezed
  class User with _$User {
    const factory User({required String id, required String email, String? name}) = _User;
    factory User.fromJson(Map<String, Object?> json) => _$UserFromJson(json);
  }
  ```
- **Parse at the boundary, trust types inward** (the same contract as [react.md](react.md) §2):
  decode the response into a generated model in the `data/` layer; the rest of the app never
  touches a raw `Map`. A decode failure is a clear, early error, not a `null` three layers deep.
- **Re-run codegen on every model change** (`build_runner build`); commit the generated `*.g.dart`
  / `*.freezed.dart` and gate CI on "codegen produces no diff" — a stale generated file is a
  silent contract drift.

## 10. Performance

- **Measure with DevTools first.** The performance overlay and timeline show *which* frames blow
  the budget and why — optimise the widget the profiler names, never by guess. Profile in
  **profile mode** (`flutter run --profile`), never debug (debug is artificially slow).
- **`const` + small rebuild scope** (§5/§6) is 90% of Flutter perf. Confirm your tree isn't
  rebuilding wholesale on every state change before reaching for anything exotic.
- **Wrap expensive, independently-animating subtrees in `RepaintBoundary`** so their repaints don't
  invalidate the rest of the layer — but only where the timeline shows wasted repaints; each
  boundary is a layer with its own cost. _(scale-up)_
- **Lazy-build long lists** with `ListView.builder` / slivers — never a `ListView(children: [...])`
  that materialises every row. **Size and cache images** (`cacheWidth`/`cacheHeight`,
  `cached_network_image`); a full-res image scaled down still decodes at full size.

## 11. Platform channels & native code

- **Stay in Dart until you can't.** Reach for a `MethodChannel` (or, for streaming/perf-critical
  paths, Pigeon type-safe channels or FFI) only when a capability genuinely isn't available as a
  maintained pub package — check pub.dev scores and recent commits first. Native code doubles your
  platform surface (iOS *and* Android) and your test matrix; a one-off channel you own forever is
  rarely worth it.
- **Declare permissions per platform and request them at point-of-use**, not at launch. Use
  `permission_handler`, handle the denied/permanently-denied branches explicitly, and keep the
  `Info.plist` usage strings / `AndroidManifest` declarations to the minimum the feature needs.

## 12. App security

Defer to [app-security.md](../practices/app-security.md); the Flutter specifics:

- **No secrets in the binary.** API keys, tokens, and `.env` files bundled with the app are
  trivially extractable — a compiled Flutter app is not a secret store. Keep secrets server-side;
  inject build-time, non-sensitive config via `--dart-define` / `--dart-define-from-file`.
- **Persist tokens and credentials in the platform keystore** via `flutter_secure_storage`
  (Keychain / Android Keystore) — **never** `SharedPreferences`, which is plaintext.
- **Pin TLS / validate certificates** for sensitive APIs (dio `badCertificateCallback` or a pinning
  interceptor); never disable certificate validation "for now". _(scale-up)_

## 13. Accessibility

First-class, not a final pass — defer to [accessibility.md](../practices/accessibility.md); the
Flutter specifics:

- **Use `Semantics` to fill the gaps** the framework can't infer — `label`, `hint`, `button: true`
  on custom gesture widgets, and `excludeSemantics` to collapse decorative noise. Icon-only buttons
  need a `tooltip` or semantic label.
- **Respect system settings**: don't hard-code font sizes against `MediaQuery.textScaler`
  (let text scale), meet WCAG **AA** contrast, and ensure tap targets are ≥ 48×48 dp.
- **Audit with the accessibility tools** — `flutter test` ships `meetsGuideline` matchers
  (`textContrastGuideline`, `androidTapTargetGuideline`, `labeledTapTargetGuideline`); wire them
  into widget tests so regressions fail CI.

## 14. Testing

Three layers, all on the SDK's own tooling — strategy in
[testing-strategy.md](../practices/testing-strategy.md):

| Layer | Tool | Tests |
|---|---|---|
| **Unit** | `flutter test` | Pure Dart: domain logic, notifiers, repositories (mock dio). |
| **Widget** | `flutter test` + `WidgetTester` | A widget in isolation — pump, interact, assert on `Finder`s and semantics. |
| **Integration / E2E** | `integration_test` | Full app on a real device/emulator; critical user journeys. |

- **Mock with `mocktail`** (no codegen, null-safe) over `mockito`. Inject collaborators through
  Riverpod `ProviderScope(overrides: [...])` so a test swaps the real repository for a fake.
- **Golden (snapshot) tests** for design-critical widgets — render to a reference PNG and fail on
  pixel drift. Intentional visual changes regenerate the golden **in the same PR**
  (`--update-goldens`) with a rationale; pin a font and a fixed `Size` so goldens are deterministic
  across machines.
- **Test behaviour through semantics** (find by label/role, `tester.tap`) — not by private widget
  internals — so refactors don't break the suite. **Coverage as a ratchet** (`--coverage` + an
  lcov floor in CI), not a vanity number.

## 15. CI & release

- **Flavors from day one** — `dev` / `staging` / `prod` with separate application IDs, names, and
  icons, driven by per-flavor entrypoints (`main_prod.dart`) and `--flavor`. This lets all builds
  coexist on one device and keeps prod credentials out of dev builds.
- **Never commit signing material.** Android keystores and iOS distribution certs/profiles live in
  CI secrets (or **`fastlane match`** for iOS); the build injects them. Reference them via
  `key.properties` (gitignored) on Android.
- **CI gates** (see [ci-cd.md](../platform/ci-cd.md)): `dart format --set-exit-if-changed`,
  `dart analyze --fatal-infos`, `flutter test --coverage`, codegen-is-clean, then a signed release
  build per flavor. Automate store delivery with **fastlane**. _(scale-up)_

## Definition of done

- [ ] `dart format --set-exit-if-changed .` clean; `dart analyze` clean with very_good_analysis (fatal-infos)
- [ ] Sound null safety; no `// @dart` opt-outs; `!` and `dynamic` justified, not reflexive
- [ ] Feature-first layout held; domain layer free of `package:flutter`; no cross-feature imports
- [ ] State in Riverpod providers (`AsyncValue` for async); `setState` only for local ephemeral UI
- [ ] `const` constructors applied (lint clean); `build` methods pure; keys only where identity matters
- [ ] Navigation via go_router; auth routes guarded by a redirect
- [ ] No unawaited futures; controllers/subscriptions disposed; CPU-bound work on an isolate
- [ ] HTTP via a configured dio instance; models generated (json_serializable/freezed); codegen produces no diff
- [ ] No secrets in the binary; tokens in `flutter_secure_storage`; perf checked in DevTools profile mode
- [ ] Semantics labels present; `meetsGuideline` matchers pass; AA contrast + tap-target sizes met
- [ ] Unit + widget + `integration_test` green (mocktail); goldens current; coverage ≥ floor
- [ ] Per-flavor signed release builds in CI; no signing material committed

**Sources:** [Flutter docs — performance best practices](https://docs.flutter.dev/perf/best-practices)
& [architecture guide](https://docs.flutter.dev/app-architecture) ·
[Effective Dart](https://dart.dev/effective-dart) ·
[Riverpod docs](https://riverpod.dev) · [go_router](https://pub.dev/packages/go_router) ·
[very_good_analysis](https://pub.dev/packages/very_good_analysis) ·
[freezed](https://pub.dev/packages/freezed) & [json_serializable](https://pub.dev/packages/json_serializable)
