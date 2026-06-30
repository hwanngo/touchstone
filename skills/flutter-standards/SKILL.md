---
name: flutter-standards
description: Use when building Flutter apps in a touchstone repo — widgets, Riverpod state, go_router navigation, dio/freezed networking, isolates, widget/golden tests, flavors. Triggers on .dart files, pubspec.yaml, lib/ widget trees, analysis_options.yaml. The Dart language rules live here too (no separate dart skill); for native iOS use the swift skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Flutter & Dart (framework + language)

Full standard: **`standards/frameworks/flutter.md`** (carries the Dart language layer inline —
there is no separate `dart.md`). This skill inlines the load-bearing rules so it stays useful
when installed standalone in `~/.claude/skills/`:

## Always
- **Pin the SDK with FVM** (`.fvmrc`) and run everything through `fvm flutter ...`; commit `pubspec.lock` for apps.
- **`dart format` + `dart analyze` with very_good_analysis** are CI gates — formatting and lint findings are bugs, not style.
- **Sound null safety**; avoid `!` and `dynamic`. Use records, exhaustive `switch` patterns, and `sealed` classes so the analyzer proves cases are handled.
- **`const` constructors everywhere legal** and keep `build` methods pure/cheap — smallest rebuild scope wins.
- **Riverpod is the default state layer** (`@riverpod`, `AsyncValue`, `AsyncValue.guard`); `setState` only for local ephemeral UI. **Bloc is the escape hatch** — pick one per repo.

## Don't get burned
- **No secrets in the binary** — a compiled app is extractable; keep keys server-side, tokens in `flutter_secure_storage` (never `SharedPreferences`). See `standards/practices/app-security.md`.
- **Offload CPU-bound work to an isolate** (`compute`/`Isolate.run`) — synchronous work over a frame budget janks the UI. Never leave a future unawaited or a controller/subscription undisposed.
- **Generate (de)serialization** with json_serializable/freezed and gate CI on "codegen is clean"; never hand-write `fromJson`. Parse at the boundary, trust types inward.
- **Profile in DevTools profile mode**, not debug; `RepaintBoundary` only where the timeline shows wasted repaints. Add `Semantics` labels — `meetsGuideline` matchers are a gate (`standards/practices/accessibility.md`).

## Done
`dart format --set-exit-if-changed` · `dart analyze` clean · `flutter test --coverage` (unit + widget + `integration_test`, goldens current) · codegen no-diff · per-flavor signed release builds, no signing material committed. See `standards/frameworks/flutter.md`.
