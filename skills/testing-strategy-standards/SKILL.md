---
name: testing-strategy-standards
description: Use for cross-cutting testing decisions in a touchstone repo — test pyramid/layering, what to mock, contract testing between services, test data, flaky-test handling, or coverage policy. Invoke when designing a test suite or dealing with a flaky/slow test (per-language test mechanics live in the language skills).
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Testing Strategy

Full standard: **`standards/practices/testing-strategy.md`** in the touchstone repo. Load-bearing rules:

## Always
- **Pyramid**: many fast unit + a solid integration layer + few e2e. Test **behaviour, not implementation**.
- **Mock at the boundary** (network/process), not internals — MSW for frontend HTTP; fakes over mocks. Don't over-mock.
- **Contract tests** (Pact / buf breaking) on service seams so independent deploys don't break consumers.
- **Hermetic + deterministic**: no shared mutable state, no real network/clock; data-dependent tests self-skip when fixtures absent.

## Flaky-test policy (the senior bit)
- **Quarantine** flaky tests fast; auto-ticket with an owner; a flake budget.
- **Banned:** "fix" a flake by retry-to-green. Flakiness is a bug.

## Coverage
- Floor 80% line / 60% branch, **ratcheted**; new code shouldn't lower it. No coverage-number worship. Mutation testing _(scale-up)_.

## Done
Pyramid shape (unit-heavy, few e2e) · mocks only at boundaries · contract tests on service seams · suite hermetic + deterministic, no retry-to-green · coverage ≥ floor, ratcheted. See `standards/practices/testing-strategy.md`.
