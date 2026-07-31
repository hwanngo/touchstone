---
name: php-standards
description: Use when writing, reviewing, testing, formatting, or configuring any modern PHP (8.3/8.4) code in a touchstone repo — covers Composer, strict_types, PHPStan, Pint, Pest, and PHP-FPM/OPcache. Triggers on .php files, composer.json/composer.lock, phpstan.neon, pint.json. Not Laravel/Symfony framework specifics or the OWASP Top 10 (see app-security).
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# PHP Standards

Full standard: **`standards/languages/php.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **`declare(strict_types=1)` as the first line of every file** — without it PHP silently coerces args; enforce via the Pint `declare_strict_types` rule.
- **Composer only**; `composer.lock` committed and law in CI (`composer install`, never `update`). Prod installs `--no-dev --optimize-autoloader`.
- Format with **Laravel Pint**; CI runs `pint --test` (read-only). Type-check with **PHPStan at `max`** — baseline legacy findings, never lower the level.
- Type every signature and property; `final` + `readonly` value objects + constructor promotion by default.

## Don't get burned
- **Static analysis:** new code held to `max`; suppress only a real false positive with a narrow commented `@phpstan-ignore`. One analyzer per repo (PHPStan *or* Psalm).
- **Modern idioms:** `match` (===, throws on miss) over `switch`; backed `enum` over string constants; nullsafe `?->`; first-class callables; named args are part of your API contract.
- **Concurrency:** PHP is share-nothing per request — keep Fibers/ReactPHP/AMPHP off the FPM request path; use a client's concurrent-request pool for parallel HTTP. _(scale-up)_
- **Tests self-skip when fixtures are absent** — never hard-fail; harden `phpunit.xml` (`failOnWarning`/`failOnRisky`/`failOnDeprecation`).
- **Errors:** throw typed exceptions, rethrow with `previous`; `Throwable` (not `Exception`) for a true catch-all; never echo a trace — `display_errors=Off` in prod.
- **Runtime:** OPcache mandatory in prod (`validate_timestamps=0` on immutable images); JIT only for CPU-bound paths — measure first.
- **Security:** `composer audit` gates CI; install `roave/security-advisories` (dev) so a vulnerable dep can't enter the lock. Allowlist Composer plugins.

## Done
`declare(strict_types=1)` everywhere · `pint --test` clean · `phpstan analyse` clean at `max` · `pest` green (coverage ≥ floor) · `composer validate --strict` + lock committed · `composer audit` clean. See `standards/languages/php.md`.
