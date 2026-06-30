# C# / .NET Standards

Applies to any C#/.NET project. Built with the **`dotnet` CLI** on an **LTS runtime** pinned by
`global.json`, versions governed by **Central Package Management**, formatted and analyzed by
**`dotnet format` + Roslyn analyzers** (warnings-as-errors), with **nullable reference types on**,
and tested with **xUnit + coverlet**. Cross-cutting concerns defer to siblings rather than repeat:
supply-chain scanning to [../practices/security.md](../practices/security.md), update policy to
[../practices/dependencies.md](../practices/dependencies.md), the test pyramid to
[../practices/testing-strategy.md](../practices/testing-strategy.md), timeouts/retries to
[../design/resilience.md](../design/resilience.md), and pipeline wiring to
[../platform/ci-cd.md](../platform/ci-cd.md).

> **One law:** the build is the gate — `<TreatWarningsAsErrors>` + analyzers + a locked restore mean
> a green `dotnet build` already proves style, nullability, and dependency integrity.

---

## 1. Toolchain & versions

| Concern | Tool | Notes |
|---|---|---|
| Runtime / SDK | **.NET, current LTS** | Even-numbered = **LTS** (3 yr); odd-numbered = **STS** (24 mo, raised from 18 with .NET 9). Default to the latest LTS — verify the current release; treat STS as a short bridge. |
| SDK pin | **`global.json`** | Exact SDK band + `rollForward` so every machine/CI builds with one toolchain. |
| Build / run / test | **`dotnet` CLI** | One driver for restore/build/test/publish. No hand-edited `.sln` munging; use `dotnet sln`. |
| Language version | **`<LangVersion>`** | Defaults to latest for the target framework — leave it default; don't pin below the SDK. |
| Package versions | **Central Package Management** | `Directory.Packages.props` (§3) — never per-project `<Version>`. |
| Formatter / style | **`dotnet format`** | Drives the `.editorconfig` rules (§4). |

- **Pin the SDK in `global.json`** at the repo root. `rollForward: latestFeature` lets patch/feature
  SDKs satisfy the pin while blocking a surprise major:
  ```jsonc
  // pin your current SDK feature band — verify the current release
  { "sdk": { "version": "8.0.400", "rollForward": "latestFeature" } }
  ```
- In CI use `actions/setup-dotnet` with `global-json-file: global.json` — the pin is the single
  source of truth, not a hardcoded workflow version.

## 2. Everyday commands

```bash
dotnet restore --locked-mode                       # restore exactly from packages.lock.json (CI gate)
dotnet build -c Release --no-restore               # warnings are errors (§4) — a warning fails this
dotnet format --verify-no-changes                  # verify formatting + style (what CI runs)
dotnet format                                      # auto-fix formatting + fixable analyzer diagnostics
dotnet test --collect:"XPlat Code Coverage"        # run xUnit suite + coverlet coverage
dotnet list package --vulnerable --include-transitive   # vuln scan (CI gate, §9)
dotnet publish -c Release                          # deterministic release artifact (§10)
```

## 3. Solution layout & Central Package Management

- **Centralize MSBuild defaults in `Directory.Build.props`** at the repo root so every project
  inherits one policy — never copy-paste `<Nullable>`/`<TreatWarningsAsErrors>` into each `.csproj`:
  ```xml
  <Project>
    <PropertyGroup>
      <TargetFramework>net8.0</TargetFramework>
      <Nullable>enable</Nullable>
      <ImplicitUsings>enable</ImplicitUsings>
      <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
      <AnalysisLevel>latest-recommended</AnalysisLevel>
      <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
      <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
      <Deterministic>true</Deterministic>
    </PropertyGroup>
  </Project>
  ```
- **Central Package Management (CPM) is mandatory** for multi-project solutions: one
  `Directory.Packages.props` declares every version, and `.csproj` files reference packages
  **without a version**. This kills version drift and diamond conflicts across projects.
  ```xml
  <Project>
    <PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup>
    <ItemGroup>
      <!-- pin exact versions here; check each package's current release -->
      <PackageVersion Include="Microsoft.Extensions.Hosting" Version="..." />
      <PackageVersion Include="xunit" Version="..." />
    </ItemGroup>
  </Project>
  ```
- **`src/` and `tests/` split**, one project per assembly, tests in `tests/<Project>.Tests`. Keep
  internals testable via `[assembly: InternalsVisibleTo]` rather than widening `public`.

## 4. Formatting, linting & analyzers

- **`dotnet format` is the formatter — non-negotiable and automated.** Style is configured once in a
  root **`.editorconfig`** (indentation, `var` usage, `this.` preferences, file-scoped namespaces,
  expression-bodied members). CI runs `dotnet format --verify-no-changes`; a diff is a red build.
- **Roslyn analyzers ship in the SDK and run in-build.** Keep `<EnableNETAnalyzers>` on (default),
  set `<AnalysisLevel>latest-recommended</AnalysisLevel>`, and **`<TreatWarningsAsErrors>true`** so
  `CAxxxx`/`IDExxxx` diagnostics fail the build instead of rotting as warnings.
- **Promote code-style rules into the build** with `<EnforceCodeStyleInBuild>true` — otherwise
  `IDExxxx` style violations only surface in the IDE, never in CI.
- **Tune severity per rule in `.editorconfig`, not by disabling the analyzer** — escalate the rules
  that catch real bugs and dial down stylistic noise, auditable in one file:
  ```ini
  # .editorconfig
  dotnet_diagnostic.CA2007.severity = warning   # missing ConfigureAwait in libraries (§7)
  dotnet_diagnostic.CA1849.severity = error     # sync call inside an async method
  dotnet_diagnostic.CA2016.severity = error     # forward the CancellationToken
  csharp_style_namespace_declarations = file_scoped:error
  ```
- **StyleCop.Analyzers / Roslynator are optional add-ons**, not the baseline — reach for them only
  when you want layout/ordering rules the SDK analyzers don't cover, and pin their severities the
  same way. Don't run a third analyzer pack "for completeness"; each one is CI cost and review noise.
- **Suppress narrowly and with a reason** — a justified `[SuppressMessage(..., Justification = "…")]`
  or a scoped `#pragma warning disable CAxxxx` around the exact line, never a blanket project-wide
  `<NoWarn>`.

## 5. Nullable reference types

- **`<Nullable>enable</Nullable>` solution-wide** (set in `Directory.Build.props`, §3). The compiler
  then proves your null-intent; a `CS8602`/`CS8618` is a real defect, and warnings-as-errors makes it
  block. Annotate intent: `string?` for "may be null", `string` for "never null".
- **Adopt incrementally on legacy code with `#nullable enable` per file**, not a repo-wide flip that
  buries you in warnings — annotate a file, fix its diagnostics, move on.
- **Guard at the boundary with `ArgumentNullException.ThrowIfNull(x)`** (and `ThrowIfNullOrEmpty`)
  rather than hand-rolled `if (x is null) throw`. Use **`required`** members and primary-constructor
  parameters so the compiler enforces initialization instead of a runtime null.
- **The null-forgiving operator `!` is a code smell, not a fix** — every `x!` is you overriding the
  compiler. Use it only where you can *prove* non-null (e.g. after a tested invariant) and comment why;
  reaching for it to silence a warning hides the bug you were warned about.

## 6. Modern idioms

| Use | Prefer | Over |
|---|---|---|
| Immutable data carriers / DTOs | **`record` / `record struct`** | hand-written classes with `Equals`/`GetHashCode` |
| Namespaces | **file-scoped** (`namespace X;`) | block-scoped braces (one less indent level) |
| DI-injected services | **primary constructors** (C# 12) | boilerplate field + assignment |
| Conditionals on shape/type | **pattern matching** (`switch`, `is`, property/list patterns) | type-test-then-cast ladders |
| Building collections | **collection expressions** `[a, b, ..rest]` (C# 12) | `new List<T> { … }` ceremony |

- **Records for value-like data; classes for entities with identity/behavior.** A record's structural
  equality is exactly wrong for an entity keyed by ID — don't make EF entities records.
- **`switch` expressions with `when` guards and `_` arms** model exhaustive logic; enable the analyzer
  for missing cases so a new enum member surfaces as a build break, not a silent fall-through.
- **Primary constructors don't create fields** — a parameter you only pass through is captured, but
  one you mutate or expose still needs an explicit field. Don't assume `param` is a property.
- **`file`-scoped types** (`file class X`) keep a helper truly private to one source file — prefer it
  over a nested or `internal` type when nothing else should see it.

## 7. Async, cancellation & concurrency

The async rules are the language face of the timeout/cancellation contract in
[../design/resilience.md](../design/resilience.md).

- **Never block on async** — no `.Result`, `.Wait()`, or `.GetAwaiter().GetResult()`. They deadlock
  under a sync-context and waste a thread-pool thread either way. `async` all the way up; analyzer
  `CA1849` (§4) enforces it.
- **`async void` only for event handlers.** Everywhere else return `Task`/`Task<T>` so the caller can
  await and observe exceptions — an `async void` throw crashes the process.
- **Library code: `ConfigureAwait(false)` on every await** (or `ConfigureAwaitOptions.None`) — it
  avoids capturing a caller's sync-context and the deadlocks that follow. Analyzer `CA2007` flags
  misses. **App code on ASP.NET Core has no sync-context**, so it's a no-op there — don't litter it.
- **`CancellationToken` flows through every async API** as the last parameter, forwarded to every
  downstream call; analyzer `CA2016` flags a dropped token. An un-cancellable await is an
  un-killable request.
- **Stream large/unbounded sequences with `IAsyncEnumerable<T>`** + `await foreach`, threading the
  token via `[EnumeratorCancellation]`:
  ```csharp
  public async IAsyncEnumerable<Row> ReadAsync(
      [EnumeratorCancellation] CancellationToken ct = default)
  {
      await foreach (var row in _source.WithCancellation(ct))
          yield return Transform(row);
  }
  ```
- **Parallel awaits via `Task.WhenAll`**; bound real fan-out with `Parallel.ForEachAsync`
  (`MaxDegreeOfParallelism`). **`ValueTask` only on hot paths** and **await it exactly once** —
  re-awaiting a `ValueTask` is undefined behavior.

## 8. Testing

- **xUnit is the runner** (`[Fact]`/`[Theory]` + `[InlineData]`/`[MemberData]`), with
  `Microsoft.NET.Test.Sdk` and `coverlet.collector`. Tests are deterministic — no wall-clock, no live
  network; inject an `IClock`/`TimeProvider` (built into .NET 8) instead of `DateTime.Now`.
- **Assertions:** **FluentAssertions** reads well, **but pin v7 deliberately** — v8 changed to a
  paid commercial license, so either stay on the last MIT v7, move to the free **AwesomeAssertions**
  fork, or use **Shouldly**. Don't let a transitive bump silently pull you into a license you can't
  ship. (Flag this in review until the team picks one.)
- **Integration tests against real backing services use [Testcontainers](https://testcontainers.com)** —
  a disposable Postgres/Redis/Kafka container per test class beats a mock that lies about the
  database's behavior. Gate them behind a `[Trait("Category","Integration")]` filter so the fast
  unit suite stays the default `dotnet test` run.
- **ASP.NET Core HTTP tests use `WebApplicationFactory<T>`** (in-memory `TestServer`) — exercise the
  real pipeline (routing, filters, model binding) without binding a socket.
- **Coverage via coverlet** (`--collect:"XPlat Code Coverage"`), rendered with **ReportGenerator**,
  enforced as a **floor** that ratchets up — never a vanity target. The pyramid (what to unit- vs
  integration-test) lives in [../practices/testing-strategy.md](../practices/testing-strategy.md).

## 9. Dependencies & supply chain

- **Lockfile is law.** `<RestorePackagesWithLockFile>true` (§3) writes `packages.lock.json` — commit
  it, and CI restores with **`--locked-mode`** so a drifted graph fails instead of silently
  re-resolving to an untested version.
- **Scan the resolved graph every build:** `dotnet list package --vulnerable --include-transitive`
  as a CI gate (and `--deprecated` / `--outdated` for hygiene). Fail at `high`+ severity. This is the
  .NET arm of the supply-chain controls in [../practices/security.md](../practices/security.md).
- **One feed, audited.** Pin sources in a repo-root `nuget.config`, set
  `<PackageSourceMapping>` so each package can only come from its expected feed (blocks dependency
  confusion), and prefer **OIDC/short-lived** push credentials over a long-lived API key.
- **Update cadence** (Renovate/Dependabot with a cooldown, CVE patches bypassing it) follows
  [../practices/dependencies.md](../practices/dependencies.md) — don't auto-merge fresh releases.

## 10. Build & publish

- **Deterministic, reproducible builds:** `<Deterministic>true` plus
  `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` in CI normalize paths and embed
  stable metadata so the same source yields a byte-identical assembly. Add **SourceLink**
  (`Microsoft.SourceLink.GitHub`) and `<EmbedUntrackedSources>true` so stack traces map to exact
  commits.
- **Publish self-contained for deployable services** (`-r <rid> --self-contained`) so the runtime
  ships with the app and CI/prod can't drift on an installed framework. Containerize with the
  SDK's built-in OCI build (`dotnet publish /t:PublishContainer`) onto a **`chiseled`/distroless,
  non-root** base image — see [../platform/ci-cd.md](../platform/ci-cd.md).
- _(scale-up)_ **Trim or AOT for startup/size-critical workloads:** `<PublishTrimmed>true` drops
  unused IL; `<PublishAot>true` produces a native binary with sub-ms startup and no JIT. Both are
  hostile to unannotated reflection — gate on **trim/AOT analyzer warnings as errors**
  (`<IsAotCompatible>true`) and test the published artifact, since breakage shows up only at runtime.
- **Stamp the version from CI** (`-p:Version=$GIT_TAG`) and emit an SBOM for the published artifact —
  build-integrity and signing live in [../practices/security.md](../practices/security.md).

## Definition of done

- [ ] SDK pinned in `global.json`; CI uses `global-json-file` (no hardcoded version)
- [ ] `dotnet build -c Release` clean with `<TreatWarningsAsErrors>` + analyzers (`latest-recommended`)
- [ ] `dotnet format --verify-no-changes` clean
- [ ] `<Nullable>enable</Nullable>` solution-wide; no unjustified `!`; boundaries guard with `ThrowIfNull`
- [ ] Versions via Central Package Management (`Directory.Packages.props`); no per-project `<Version>`
- [ ] No blocking on async (`.Result`/`.Wait()`); `CancellationToken` forwarded; libraries `ConfigureAwait(false)`
- [ ] `dotnet test` green; coverage ≥ floor (coverlet); integration tests via Testcontainers, trait-gated
- [ ] `packages.lock.json` committed; CI restores `--locked-mode`; `dotnet list package --vulnerable` clean
- [ ] Release builds deterministic (`ContinuousIntegrationBuild`) + SourceLink; trim/AOT analyzers clean _(scale-up)_

**Sources:** [.NET release lifecycle](https://dotnet.microsoft.com/platform/support/policy/dotnet-core) · [Central Package Management](https://learn.microsoft.com/nuget/consume-packages/central-package-management) · [Code analysis](https://learn.microsoft.com/dotnet/fundamentals/code-analysis/overview) · [Nullable reference types](https://learn.microsoft.com/dotnet/csharp/nullable-references)
