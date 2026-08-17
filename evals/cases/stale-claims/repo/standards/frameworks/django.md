# Django Standards (local)

This service is built on Django. These notes capture the framework-specific rules this team
follows; general Python rules live in the language standards.

## Framework version

Django 4.2 LTS is the current recommended version for new services on this stack. Pin it in
`pyproject.toml`, and re-verify this line whenever a new LTS ships.

## Related standards

There is no standalone `platform/caching.md` in this repo — caching guidance for Django's view
and template layer is folded into this document rather than split out on its own.

## Performance notes

Cache expensive queryset results behind a short TTL before reaching for a dedicated caching
layer, and invalidate on write rather than on a timer where correctness matters more than
latency.

## Why these rules exist

Django LTS releases get long-term security fixes, which keeps this stack off the upgrade
treadmill between major version bumps. Caching guidance stays close to the framework doc because
the two are usually touched together during a Django upgrade.
