# Ruby Standards

Applies to any Ruby project/gem (3.3+, tracking the current stable line). Versions are pinned with a **version
manager + `.ruby-version`**, dependencies locked with **Bundler**, formatted and linted with
**RuboCop**, type-checked with **RBS + Steep**, and tested with **RSpec** — all run under
**YJIT**. Cross-cutting concerns defer to siblings: supply-chain to
[../practices/security.md](../practices/security.md), dependency policy to
[../practices/dependencies.md](../practices/dependencies.md), the test pyramid to
[../practices/testing-strategy.md](../practices/testing-strategy.md), timeouts/retries to
[../design/resilience.md](../design/resilience.md), and pipelines to
[../platform/ci-cd.md](../platform/ci-cd.md).

> **One law:** lock the version and the gems, freeze the strings, and parse untrusted input at
> the boundary — everything else is style.

---

## 1. Toolchain

| Concern | Tool | Notes |
|---|---|---|
| Ruby version | **Current stable (3.3 floor)** | Pin in `.ruby-version` (and `required_ruby_version` for gems). Same string CI installs. |
| Version manager | **mise** (default) or rbenv | Reads `.ruby-version`. Never the system Ruby; never a hand-built install. |
| Dependencies | **Bundler** | `Gemfile` + **`Gemfile.lock` committed** — for apps *and* gems. |
| Formatter + linter | **RuboCop** | `+ rubocop-performance + rubocop-rspec`. Config in `.rubocop.yml`. |
| Type checker | **RBS + Steep** (default) | Sorbet only where you need its inline strictness (§4). |
| Test runner | **RSpec** (default) | Minitest for gems/stdlib-style suites. Specs under `spec/`. |
| Runtime | **YJIT on** | `RUBY_YJIT_ENABLE=1` (or `--yjit`); built-in since 3.3, near-free throughput (§9). |

## 2. Everyday commands

```bash
bundle install                    # install from the lockfile
bundle exec rspec                 # run the suite
bundle exec rubocop               # lint + format check (what CI runs)
bundle exec rubocop -A            # autocorrect (safe + unsafe); -a for safe-only
bundle exec steep check           # type-check against sig/
bundle exec rbs collection install # install third-party RBS sigs into the collection
bundle exec bundler-audit check --update   # CVE scan of the lockfile
bundle outdated --strict          # dependency drift
```

Add a dependency with `bundle add <gem>` (writes `Gemfile` **and** `Gemfile.lock` together — commit
both). Run app code through `bundle exec` so you get the locked versions, never an ambient gem.

## 3. Formatting & linting (RuboCop)

- **Formatting is automated and non-negotiable.** RuboCop is the formatter *and* the linter; never
  hand-format. CI runs `rubocop` (no autocorrect) — a red cop is a red build.
- **Pull in the focused extensions** — each catches a real bug class for near-zero cost:
  ```yaml
  # .rubocop.yml
  require:
    - rubocop-performance   # accidental O(n²), needless allocations
    - rubocop-rspec         # spec-structure + let/subject smells
  AllCops:
    TargetRubyVersion: 3.3  # match your floor; gates autocorrect rewrites
    NewCops: enable         # opt into new cops instead of silently lagging
  ```
  Add `rubocop-rails` only in a Rails app; add `rubocop-rake`/`rubocop-thread_safety` where they
  apply. Don't disable a department wholesale — fix the finding.
- **`Style/FrozenStringLiteralComment` is enabled, not optional.** Every `.rb` file starts with
  `# frozen_string_literal: true`. It's the default in 3.4 with a deprecation path to mandatory —
  adopt it now (§6).
- **Inline disables are scoped and justified** — `# rubocop:disable Cop/Name` … `# rubocop:enable`
  around the minimum span, with a reason. A repo-wide `.rubocop_todo.yml` is a **ratchet**: generate
  it once on adoption (`--auto-gen-config`), then burn it down — never grow it.
- **Standard is the escape hatch, not the default.** If a team genuinely won't maintain a RuboCop
  config, adopt **`standard`** (zero-config, RuboCop under the hood) — but you lose the
  performance/security cops, so it's a deliberate trade, not the recommendation.

## 4. Type checking

Ruby is gradually typed. Pick **one** checker per repo and hold new code to it.

### RBS + Steep (default)

- **Signatures live in `sig/*.rbs`, separate from code** — no runtime cost, no inline clutter, and
  it's the language-official type system (ships in the stdlib). Pull third-party sigs with
  **`rbs collection`** (`rbs_collection.yaml` + a committed `.lock.yaml`).
  ```ruby
  # sig/user.rbs
  class User
    attr_reader name: String
    def initialize: (name: String, ?admin: bool) -> void
    def greet: () -> String
  end
  ```
- **Steep is the checker** (`steep check`, config in `Steepfile`). Run it in CI; gate new
  directories at a stricter level while legacy code stays loose — a per-target ratchet, like
  Pyright strict-per-dir.
- _(scale-up)_ Generate a starting point with **`rbs prototype`** / **TypeProf**, then hand-correct —
  generated sigs are a draft, not the spec.

### Sorbet (the alternative)

- **Choose Sorbet only when you want inline `sig`s, `# typed:` sigils, and runtime checking**
  (`T.let`, `sig { params(...) }`). It's faster at scale and catches more, but the annotations live
  *in* the code and it's a separate ecosystem (`srb tc`, `sorbet-runtime`, RBI files via Tapioca).
- **Don't run both.** RBS/Steep and Sorbet disagree at the edges and double the CI cost — one per
  repo. Default RBS for new/library code; Sorbet for large apps already invested in it.

## 5. Testing

- **Framework: RSpec** for apps (expressive, the ecosystem default); **Minitest** for gems and
  stdlib-flavored suites (fast, zero-DSL, ships with Ruby). Don't mix both in one repo.
- **`--require spec_helper` runs with warnings on and randomized order** — random order surfaces
  hidden inter-example coupling *as failures*, which is the point:
  ```ruby
  # .rspec
  --require spec_helper
  --format documentation
  # spec_helper.rb
  RSpec.configure do |c|
    c.disable_monkey_patching!      # use `expect`, not the global `should`
    c.order = :random               # seeded; reproduce a failure with --seed
    c.warnings = true
  end
  ```
- **Don't over-mock.** Stub at the boundary (HTTP via WebMock/VCR, the clock via a time helper);
  prefer real objects inward. Use **`verify_partial_doubles = true`** so a stub of a method that
  doesn't exist fails — a mock that drifts from the real API is worse than no test.
- **`pending`/`skip` is a tripwire, not a graveyard** — only for a known, deliberate gap; never to
  silence a real regression. A `pending` example that passes is a failure (RSpec enforces this).
- Write the test first for new behavior and bugfixes (TDD). Keep specs deterministic — no
  wall-clock or live network; freeze time and stub I/O. The pyramid lives in
  [../practices/testing-strategy.md](../practices/testing-strategy.md).
- **Coverage as a ratchet, not a vanity number** — **SimpleCov** with a `minimum_coverage` floor
  (start ~80, ratchet up); fail CI under it.

## 6. Modern idioms (3.3 / 3.4)

- **`# frozen_string_literal: true` in every file** (§3) — string literals become frozen and
  shareable; mutating one raises instead of silently aliasing. Build mutable strings with
  `String.new` or `+""`.
- **Keyword arguments are not a hash** — define and call with explicit keywords; the 2.7→3.0
  separation is long done. Don't splat a hash into positional params.
- **`Data.define` for immutable value objects** — the right tool now that `Struct` is the mutable
  legacy. Frozen, value-equal, `with`-copyable; zero validation tax on trusted internal data.
  ```ruby
  Point = Data.define(:x, :y) do
    def distance = Math.hypot(x, y)
  end
  p = Point.new(x: 3, y: 4)
  p.with(y: 0)          # => #<data Point x=3, y=0>  (p unchanged)
  ```
- **Pattern matching (`case/in`) for parsing structured data** — destructure API/JSON shapes with
  exhaustive, readable branches instead of nested `[]`/`dig` and `is_a?` checks:
  ```ruby
  case response
  in { status: 200, body: { user: { id: Integer => id, name: String => name } } }
    User.new(name:)            # 3.x shorthand: name: name
  in { status: 4.. => code }
    raise ClientError, "HTTP #{code}"
  end
  ```
- **Endless methods** (`def square(n) = n * n`) and the **`it`** implicit block param (3.4) for
  one-liners — concise, but don't bury logic; reach for a normal block when it grows.

## 7. Error handling

- **Rescue the narrowest class you can; never bare `rescue`** — a bare `rescue` (or `rescue
  Exception`) swallows `SignalException`/`SystemExit` and hangs the process. `rescue => e` already
  scopes to `StandardError`, which is the right floor.
- **No rescue-log-continue.** A handler that logs and falls through hides failures and corrupts
  downstream state. Either **re-raise** (`raise` to preserve the backtrace, or `raise NewError`
  with `cause:` chained automatically), record the failure as a result the caller checks, or don't
  rescue it.
- **Define a gem/app error hierarchy** under one base (`class MyError < StandardError`) so callers
  can `rescue MyError` for everything you raise — don't leak raw `ArgumentError`/`KeyError` across a
  public API.
- **`ensure` for cleanup**, and prefer block-form resource APIs (`File.open(…) { … }`,
  `Tempfile.create`) that close on their own. Validate input at the boundary and **fail fast**
  before expensive work.
- Timeouts and retries are the resilience face of error handling — never wrap a network call in the
  unsafe `Timeout.timeout`; use the client's own deadline. See
  [../design/resilience.md](../design/resilience.md).

## 8. Dependencies & supply chain

- **`Gemfile.lock` is law in CI.** `bundle install --frozen` (or set `BUNDLE_FROZEN=true`) fails the
  build if the lock is stale vs. the `Gemfile` — don't let CI silently re-resolve and ship an
  untested graph. Commit the lock for **gems too** (CI reproducibility); a published gem still pins
  via `gemspec` + `required_ruby_version`.
- **Pin with pessimistic constraints** (`gem "rails", "~> 7.1"`) — allow patches, gate majors.
- **`bundler-audit check --update`** in CI scans the lockfile against the ruby-advisory-db; gate at
  a sensible severity so it stays actionable. See [../practices/security.md](../practices/security.md).
- **Vet new gems before adding** — maintenance, transitive weight, and a real need over a 20-line
  helper. Dependency-update policy (Dependabot/Renovate + cooldown) lives in
  [../practices/dependencies.md](../practices/dependencies.md).
- **Publish with MFA + OIDC trusted publishing** (RubyGems supports it) — no long-lived API key in
  CI; `gem signing` / a checksum for release integrity. See
  [../practices/security.md](../practices/security.md).

## 9. Performance & concurrency

- **Profile before optimizing** — measure the real hot path, never guess. **`stackprof`**
  (sampling CPU/wall/object profiler) for where time goes; **`memory_profiler`** /
  **`derailed_benchmarks`** for allocations and leaks. Optimize what the profiler names, re-measure.
- **YJIT is on by default** (§1) — verify it's active in prod (`RubyVM::YJIT.enabled?`); it's the
  highest-leverage, lowest-effort win and costs a little memory for real throughput.
- **Allocation is the usual cost** — the `rubocop-performance` cops (§3) flag the easy ones (frozen
  literals, `each` vs `map`, needless `to_a`). Reach for algorithmic/stdlib fixes before native C
  extensions, which add build and portability cost.
- **The GVL means threads don't parallelize CPU-bound Ruby** — they *do* overlap I/O. Match the
  model to the work:
  - **I/O-bound:** threads (Puma's thread pool) or a **Fiber** scheduler (`async` gem) — high
    concurrency, one core.
  - **CPU-bound:** **processes** (Puma workers, `fork`) for true parallelism. _(scale-up)_
    **Ractor** is the official path to parallel Ruby threads, but the ecosystem isn't broadly
    Ractor-safe yet — adopt it deliberately for isolated compute, not as a default.
- **Make shared state explicit** — prefer immutable `Data` objects and message passing over shared
  mutable globals; a frozen value object can't be raced.

## Definition of done

- [ ] `.ruby-version` pins 3.3+; CI installs the same string; YJIT enabled in prod
- [ ] `bundle install --frozen` passes; `Gemfile.lock` committed (apps **and** gems)
- [ ] `rubocop` clean (with `-performance`/`-rspec`, `NewCops: enable`); no un-burned-down TODO file
- [ ] Every `.rb` has `# frozen_string_literal: true`
- [ ] `steep check` clean (or `srb tc`) — one checker, new code at the strict bar
- [ ] `rspec` green, order-randomized, `verify_partial_doubles`; coverage ≥ floor; no stray `pending`
- [ ] No bare `rescue`; errors under one base class; no rescue-log-continue
- [ ] `bundler-audit check` clean (or advisories triaged); new deps vetted
- [ ] Hot paths profiled (stackprof) before optimizing; concurrency model matches the workload
