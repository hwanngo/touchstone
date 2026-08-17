# 0001. Use FastAPI on a uv-managed toolchain

- **Status:** Accepted
- **Date:** 2026-06-01
- **Deciders:** widget-api maintainers

## Context

widget-api is a small internal service. We need a Python web framework and a package manager
before the first line of application code lands.

## Decision

We will build on FastAPI, managed end-to-end with `uv` per
[`standards/languages/python.md`](../../.touchstone/standards/README.md).

## Consequences

- **Positive:** async-first framework, generated OpenAPI schema, matches the kit's Python
  standard.
- **Negative / trade-offs:** none identified yet.
- **Follow-ups:** none.
