# PHP Standards

Applies to any modern PHP project (**8.3+**). Dependencies and tooling run through
**Composer** (with `composer.lock` committed), formatted by **Laravel Pint**, statically analyzed
by **PHPStan at max level**, written with **`declare(strict_types=1)`** everywhere, and tested with
**Pest**. Cross-cutting concerns defer to siblings rather than repeat: supply-chain scanning to
[../practices/security.md](../practices/security.md), authn/authz and the OWASP Top 10 to
[../practices/app-security.md](../practices/app-security.md), update policy to
[../practices/dependencies.md](../practices/dependencies.md), the test pyramid to
[../practices/testing-strategy.md](../practices/testing-strategy.md), and pipeline wiring to
[../platform/ci-cd.md](../platform/ci-cd.md).

> **One law:** `declare(strict_types=1)` plus PHPStan at max level turns PHP's dynamic, coercing
> footguns into errors a machine catches before the request hits prod.

---

## 1. Toolchain

| Concern | Tool | Notes |
|---|---|---|
| PHP version | **Latest stable** | Verify the current release; pin via `composer.json` `config.platform.php` + `require` `"php": "^8.3"`. Track the [supported-versions](https://www.php.net/supported-versions.php) window — never run an EOL branch. |
| Dependency manager | **Composer** | Never hand-edit `vendor/`. `composer.lock` is committed (§3). |
| PHP extensions | **PIE** | The [PHP Installer for Extensions](https://github.com/php/pie) replaces `pecl`; pin extension versions in CI/images. |
| Formatter | **Laravel Pint** | Opinionated PHP-CS-Fixer wrapper; config in `pint.json` (§5). |
| Static analysis | **PHPStan** (`max`) | Config in `phpstan.neon`; the type gate (§6). |
| Test runner | **Pest** | PHPUnit under the hood; tests under `tests/` (§8). |
| Automated upgrades | **Rector** _(scale-up)_ | Mechanical version-migration + dead-code rules; run in CI as `--dry-run`. |
| Runtime | **PHP-FPM** + OPcache | Behind nginx; JIT/FrankenPHP for hot paths (§10). |

## 2. Everyday commands

```bash
composer install                  # install from the lockfile (CI: --no-dev on prod images)
composer update <pkg>             # bump one dep + re-resolve; commit composer.lock
vendor/bin/pint                   # auto-format
vendor/bin/pint --test            # verify formatting only (what CI runs)
vendor/bin/phpstan analyse        # static analysis at the configured level
vendor/bin/pest                   # run the test suite
vendor/bin/pest --coverage        # with coverage (needs Xdebug/PCOV)
composer audit                    # CVE scan of the resolved graph
```

Add a dependency with `composer require <pkg>` (runtime) or `composer require --dev <pkg>`
(dev-only). Both update `composer.json` **and** `composer.lock` — commit them together. CI runs
`composer install` from the lockfile, never `composer update`.

## 3. Composer & dependencies

- **`composer.lock` is committed and is law in CI.** CI runs `composer install` (resolves from the
  lock), never `composer update` — a silent re-resolve ships an untested graph. Run
  `composer validate --strict` to catch a `composer.json` that has drifted from the lock.
- **Pin the platform** (set to your deployed PHP version, not the host's), so every machine and CI
  runner resolves for the same PHP/extension set regardless of the host binary:
  ```jsonc
  // set "php" to the version you deploy on — verify the current release
  { "config": { "platform": { "php": "8.4.0" } } }
  ```
- **Autoload via PSR-4** — declare `autoload.psr-4` namespaces; run `composer dump-autoload -o`
  (classmap-optimized) for prod images. No manual `require` of source files.
- **Production installs are `--no-dev`**: `composer install --no-dev --optimize-autoloader`. Dev
  tools (Pint, PHPStan, Pest) live under `require-dev` and never ship in the runtime image.
- **Allowlist plugins.** Composer plugins run arbitrary code at install; `config.allow-plugins`
  is a per-plugin allowlist — keep it explicit, never `true` (see [../practices/security.md](../practices/security.md)).
- **Distinguish abandoned vs. maintained** — `composer outdated --direct` in CI surfaces drift;
  policy and cooldown live in [../practices/dependencies.md](../practices/dependencies.md).

## 4. Strict types & the type baseline

- **`declare(strict_types=1)` is the first line of every PHP file.** Without it PHP silently coerces
  `"5"` → `5`, `1` → `true`, and a typo'd argument passes — strict mode makes the mismatch a
  `TypeError` at the call site. Enforce it with a Pint/PHP-CS-Fixer `declare_strict_types` rule so
  a missing header fails CI, not review.
- **Type every signature and property.** Parameters, return types (including `: void` / `: never`),
  and typed properties are mandatory on new code; `mixed` is a last resort, not a default.
- **`readonly` for value objects** — `readonly` properties (8.1) and `readonly` classes (8.2) make
  immutability a compiler guarantee, not a convention. Reach for them on DTOs and entities that
  shouldn't mutate after construction.
- **Constructor property promotion** collapses the boilerplate; combine with `readonly`:
  ```php
  final class Money
  {
      public function __construct(
          public readonly int $amount,
          public readonly Currency $currency,
      ) {}
  }
  ```
- **`enum` over class constants** for closed sets — backed enums (`enum Status: string`) are typed,
  exhaustively `match`-able, and can carry methods. Don't model a fixed set with bare strings/ints.
- **First-class callable syntax** (`$fn = strlen(...)`, `$this->handle(...)`) over `Closure::fromCallable`
  or string callables — it's type-checked and statically analyzable.
- **`final` by default.** Make classes `final` unless they're a designed extension point; prefer
  composition and interfaces over an open inheritance tree.

## 5. Formatting & linting (Pint)

- **Pint is the single source of truth for formatting** — it wraps PHP-CS-Fixer with a curated
  preset and zero config to start. Pick the `laravel` or `psr12` preset in `pint.json` and let it
  own style; never hand-format:
  ```json
  {
    "preset": "psr12",
    "rules": { "declare_strict_types": true, "ordered_imports": { "sort_algorithm": "alpha" } }
  }
  ```
- **CI runs `pint --test`** (read-only — it can't auto-fix to mask drift). A formatting diff is a
  red build, same as a failing test.
- **Escape hatch:** reach for raw **PHP-CS-Fixer** directly only when you need a fixer Pint doesn't
  expose, or **PHP_CodeSniffer** (`phpcs`/`phpcbf`) when an existing repo's house ruleset is already
  PHPCS-based. Don't run two formatters in one repo — pick one and let it own the diff.

## 6. Static analysis (PHPStan)

- **PHPStan runs at `max`** (equivalent to level 10) and is a required gate. Start a legacy repo at
  a lower level and **ratchet up** — each level closes a real bug class (null safety, undefined
  methods, wrong argument types) for near-zero friction:
  ```neon
  # phpstan.neon
  parameters:
      level: max
      paths: [src, tests]
      treatPhpDocTypesAsCertain: false
  ```
- **Generate a baseline, don't lower the level.** `phpstan analyse --generate-baseline` freezes
  existing findings so new code is held to `max` while the backlog burns down — never drop the
  level to make the suite pass.
- **Type framework magic with stubs.** Add the first-party extension (`phpstan/phpstan-doctrine`,
  `larastan/larastan` for Laravel, `phpstan/phpstan-symfony`) so the analyzer understands the
  framework's dynamic surface instead of you papering over it with `mixed`.
- **Escape hatch: Psalm** is the equivalent alternative — pick it for its taint analysis (security
  data-flow) or stricter generics, but **run one analyzer per repo**, not both. Suppress a genuine
  false positive with a narrow, commented `@phpstan-ignore` (or `@psalm-suppress`) — never a
  blanket baseline of real findings.

## 7. Modern idioms

- **`match` over `switch`** — `match` is an expression, returns a value, compares with `===` (no
  type juggling), and throws `UnhandledMatchError` on a missing arm instead of silently falling
  through. A `switch` with `break` on every arm is a code smell.
- **Named arguments** for call sites with boolean/optional soup — `setOptions(strict: true,
  cache: false)` is self-documenting and order-independent. Don't rename a public parameter
  casually: named args make the parameter name part of your API contract.
- **Nullsafe operator** (`$order?->customer?->email`) replaces nested `isset`/`if`-null ladders —
  short-circuits to `null` instead of a fatal on a null intermediate.
- **Enums carry behavior** — give a backed enum methods (`->label()`, `::tryFrom()`); pair with
  `match` for exhaustive mapping. `tryFrom` returns `null` on a bad input where `from` throws —
  pick deliberately at the boundary.
- **Concurrency note:** PHP is share-nothing per request — there's no event loop in the standard
  runtime. **Fibers** (8.1) are the low-level primitive behind async runtimes (**ReactPHP**,
  **AMPHP**, Swoole); reach for them only for genuinely I/O-bound fan-out, and keep them off the
  classic PHP-FPM request path. For parallel HTTP, use a client's concurrent-request API
  (Guzzle pool, Symfony HttpClient) rather than hand-rolling fibers. _(scale-up)_

## 8. Testing (Pest)

- **Pest is the default runner** — it builds on PHPUnit, so the ecosystem (mocks, coverage,
  assertions) is identical, with a lower-ceremony expectation API. Plain **PHPUnit** is the
  escape hatch for a team that wants the class-based style; don't mix both in one suite.
- **Write the test first** for new behavior and bugfixes (TDD). Keep tests deterministic — no
  wall-clock or live network. Broader philosophy in [../practices/testing-strategy.md](../practices/testing-strategy.md).
- **Fixture-dependent tests self-skip when the data is absent — never hard-fail.** CI runs on a
  clean checkout; gitignored seeds won't be there. Use Pest's `->skip(fn () => ! fixtureExists())`.
- **Harden the config** in `phpunit.xml` so latent problems surface as red CI:
  ```xml
  <phpunit failOnWarning="true" failOnRisky="true" failOnDeprecation="true"
           beStrictAboutOutputDuringTests="true" beStrictAboutTestsThatDoNotTestAnything="true">
  ```
- **Coverage is a ratchet, not a vanity number** — needs **Xdebug** or **PCOV** installed; set a
  floor and raise it, never target `100`. _(scale-up)_ **Infection** (mutation testing) measures
  whether the tests actually assert, not just execute.
- **Changing deterministic output** ⇒ regenerate the golden/snapshot **in the same PR** with a
  rationale.

## 9. Error handling

- **Throw typed exceptions, not generic ones.** A small `DomainException` hierarchy with meaningful
  classes lets callers `catch` precisely and a top-level handler map to an HTTP status. Catch the
  narrowest type you can.
- **No swallowed errors.** A `catch` that logs and continues hides failures and corrupts downstream
  state. Either rethrow preserving the chain (`throw new AppException(..., previous: $e)`), handle
  it meaningfully, or don't catch it.
- **`Throwable`, not `Exception`, for a true catch-all** — PHP `Error` (e.g. `TypeError`,
  `DivisionByZeroError`) doesn't extend `Exception`; only `Throwable` covers both. Use it at the
  process boundary only.
- **Never echo a stack trace to the client.** `display_errors=Off` in production; log structured
  errors server-side (PSR-3 logger) and return a generic message — leaking traces is an info-disclosure
  finding (see [../practices/app-security.md](../practices/app-security.md)).

## 10. Runtime & performance

- **PHP-FPM behind nginx** is the default deployment. Tune `pm` (`pm.max_children` sized to memory),
  set `request_terminate_timeout`, and run one process manager per container.
- **OPcache is mandatory in production** — without it every request recompiles. Set
  `opcache.enable=1`, `opcache.validate_timestamps=0` on immutable image deploys (recompile only on
  deploy), and preload hot classes via `opcache.preload`:
  ```ini
  opcache.enable=1
  opcache.memory_consumption=256
  opcache.validate_timestamps=0   ; immutable image — restart FPM to pick up new code
  opcache.jit=tracing
  opcache.jit_buffer_size=128M
  ```
- **JIT helps CPU-bound work, not typical I/O-bound web apps** — measure before enabling; for a
  request that's mostly DB/HTTP latency the JIT buys little. Profile the real hot path first.
- **FrankenPHP** _(scale-up)_ — a modern app server (worker mode keeps the app booted between
  requests, eliminating per-request bootstrap) that can replace the nginx+FPM pair and adds
  HTTP/3 and a built-in `Caddy`. Adopt it for boot-heavy apps where the FPM cold-start dominates.
- **Profile, don't guess** — use **Xdebug**'s profiler locally or a sampling profiler
  (**Blackfire** / **Tideways** / **SPX**) on a running process; optimize the function the profiler
  names, then re-measure.

## 11. Security, dependencies & enforcement

- **`composer audit` gates CI** — it checks the resolved lock against the
  [PHP Security Advisories DB](https://github.com/FriendsOfPHP/security-advisories). Gate at a
  sensible severity so the check stays actionable (see [../practices/security.md](../practices/security.md)).
- **`roave/security-advisories` as a dev dependency** is the senior move — it's a metapackage with
  *no code* that makes Composer **refuse to install** any version with a known vulnerability, so a
  bad dep can't enter the lock in the first place:
  ```bash
  composer require --dev roave/security-advisories:dev-latest
  ```
- **Dependency updates** via Renovate/Dependabot with a cooldown; security patches bypass it
  (see [../practices/dependencies.md](../practices/dependencies.md)).
- **Never trust input** — validate/escape at the boundary, use parameterized queries (PDO prepared
  statements, never string-interpolated SQL), and escape on output by context. The OWASP Top 10,
  CSRF, and authn/authz are owned by [../practices/app-security.md](../practices/app-security.md).
- **Enforce locally with a pre-commit / Composer-script gate** (`pint --test` → `phpstan` → `pest`)
  so CI rarely fails on mechanics. Wire the pipeline in [../platform/ci-cd.md](../platform/ci-cd.md).

## Definition of done

- [ ] `declare(strict_types=1)` in every file; signatures and properties fully typed
- [ ] `pint --test` clean (formatting is a build gate, not a review note)
- [ ] `phpstan analyse` clean at `max` (or baselined; new code not baselined)
- [ ] `pest` green (fixtures present, 0 unexpected skips); coverage ≥ floor
- [ ] Errors typed and rethrown with `previous` (none swallowed); no traces to the client
- [ ] `composer validate --strict` passes; `composer.lock` committed; CI installs `--no-dev` from lock
- [ ] `composer audit` clean (or advisories triaged); `roave/security-advisories` installed
- [ ] Prod runtime: OPcache on, `display_errors=Off`, FPM timeouts set
- [ ] Any deterministic-output change ships with a regenerated golden + rationale
