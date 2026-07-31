---
name: csharp-standards
description: Use when writing, reviewing, testing, building, or configuring any C#/.NET code in a touchstone repo — triggers on .cs, .csproj, .sln, Directory.Packages.props, global.json. Invoke before adding NuGet deps, editing tests, or touching async/nullable code. Not for Go/Python services — see those language skills.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# C# / .NET Standards

Full standard: **`standards/languages/csharp.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **Pin the SDK in `global.json`** (LTS runtime); CI uses `global-json-file`. Build/test/publish via the `dotnet` CLI only.
- **`<TreatWarningsAsErrors>true` + Roslyn analyzers** (`AnalysisLevel=latest-recommended`, `EnforceCodeStyleInBuild`) in `Directory.Build.props` — the build is the gate.
- Format with **`dotnet format`**; CI runs `dotnet format --verify-no-changes`. Style lives in `.editorconfig`.
- **`<Nullable>enable</Nullable>` solution-wide**; annotate intent, guard boundaries with `ArgumentNullException.ThrowIfNull`.
- **Central Package Management** (`Directory.Packages.props`) — never per-project `<Version>`.

## Don't get burned
- **Never block on async** (`.Result`/`.Wait()`/`.GetAwaiter().GetResult()` deadlock). `async void` only for event handlers.
- **Forward `CancellationToken`** through every async call (analyzer `CA2016`); libraries `ConfigureAwait(false)` (`CA2007`) — no-op on ASP.NET Core, skip it there.
- **The null-forgiving `!` is a smell, not a fix** — prove non-null or fix the warning; don't silence it.
- **Records for value data, classes for entities** — don't make EF/identity entities records (structural equality is wrong).
- **FluentAssertions v8 went paid-license** — pin v7 (MIT), use the AwesomeAssertions fork, or Shouldly; flag a transitive bump.
- **Lockfile is law:** `<RestorePackagesWithLockFile>true`, commit `packages.lock.json`, CI restores `--locked-mode`; `dotnet list package --vulnerable` clean.
- Integration tests via **Testcontainers** (real Postgres/Redis), trait-gated out of the fast unit run. Release builds deterministic + SourceLink; trim/AOT _(scale-up)_.

## Done
`dotnet build -c Release` clean (warnings-as-errors + analyzers) · `dotnet format --verify-no-changes` clean · `Nullable` enabled, no unjustified `!` · `dotnet test` green (coverage ≥ floor) · `packages.lock.json` committed, `--locked-mode` restore, `--vulnerable` clean. See `standards/languages/csharp.md`.
