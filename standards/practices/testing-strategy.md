# Testing Strategy

Cross-cutting testing standards. Per-language mechanics (flags, runners, config) live in
[python.md](../languages/python.md), [golang.md](../languages/golang.md),
[react.md](../frameworks/react.md). This doc owns **what** to test,
**where** it lives, and **how** the team enforces quality over time.

---

## 1. Test pyramid / honeycomb

```text
        [ e2e ]         few — happy-path smoke + critical flows only
      [integration]     solid layer — seams between real components
   [  unit  unit  ]     many — fast, isolated, zero I/O
```

| Layer       | What it owns                                      | Target ratio | Speed gate |
|-------------|---------------------------------------------------|-------------|------------|
| Unit        | Pure logic, data transforms, error branches       | ~70%        | < 5 s total |
| Integration | Real DB/queue/cache, HTTP between services        | ~25%        | < 90 s total |
| e2e         | Critical user journeys, smoke after deploy        | ~5%         | < 10 min   |

**Rule**: test behaviour, not implementation. If a refactor breaks tests without changing
observable behaviour, the tests were wrong.

---

## 2. What to mock

**Mock at the network/process boundary, not inside your own code.**

| Boundary              | Preferred approach                                      |
|-----------------------|---------------------------------------------------------|
| HTTP (frontend)       | MSW intercept at the fetch layer — see [react.md](../frameworks/react.md) |
| HTTP (backend)        | httptest server or WireMock; never patch the HTTP client |
| External services     | Fake (in-memory implementation of the interface)        |
| DB / queue            | Real instance in Docker; use a fake only for unit tests |
| Clock / random        | Inject via interface; never patch globals               |

**Fakes > mocks.** A fake (real interface, fake backing) survives refactors; a mock
(behaviour assertions on calls) couples tests to internals. Default to fakes.

**Ban**: mocking private functions, patching module-level globals, `monkeypatching` across
module boundaries except in designated integration-test helpers.

---

## 3. Contract testing

Independent-deploy services must not silently break each other.

- **REST APIs**: [Pact](https://docs.pact.io/) consumer-driven contracts; consumer publishes,
  provider verifies in CI before merge. Link to [api-design.md](../design/api-design.md).
- **gRPC / Protobuf**: `buf breaking` check in CI blocks backwards-incompatible schema changes.
- **Async (events/queues)**: schema registry + consumer contract test on the event shape.

Contract tests live in `tests/contract/` and run in the integration stage, not unit stage.
Failing a provider's contract test blocks that provider's deploy — no exceptions.

---

## 4. Test data

**Factories / builders over fixtures.**

```python
# Good — builder, parameterisable
user = UserFactory(role="admin", verified=True)

# Bad — static fixture shared across suites
user = fixtures["admin_user"]  # mutable, leaky
```

| Rule | Rationale |
|------|-----------|
| Each test creates its own data | No cross-test state leakage (hermetic) |
| No real network calls in unit/integration setup | Deterministic on any machine |
| No real clock in tests (`freezegun`, `time.Now` injection) | Removes flake from timing |
| Data-dependent tests self-skip when fixture absent | Clean-checkout CI never fails on missing local data |

Self-skip pattern:

```python
@pytest.mark.skipif(not Path("fixtures/load-data.csv").exists(), reason="load fixtures absent")
def test_bulk_import(): ...
```

---

## 5. Flaky-test policy

**Flakiness is a bug. Retry-to-green is not a fix — it is a cover-up.**

```text
Flake detected → quarantine within 1 hour → auto-ticket (owner = last editor) → fix or delete
```

| Practice | Detail |
|----------|--------|
| Quarantine | Move test to `tests/quarantine/`; excluded from required CI gate |
| Flake budget | ≤ 2 quarantined tests per squad at any time; 3rd flake blocks new feature merges |
| Auto-ticket | CI flake detector files GitHub issue with test name, stack, flake rate, last editor |
| Fix SLA | 3 business days to fix or delete; no indefinite parking |
| **Hard ban** | `--rerun-failures`, `pytest-rerunfailures`, `--retries` in CI config are prohibited |

Approved flake root causes: race condition in test setup, non-hermetic time/network,
port collision, non-deterministic ordering. Each has a standard fix pattern — don't retry.

---

## 6. Coverage philosophy

**Coverage is a floor, not a target.**

| Metric       | Kit floor | Enforcement |
|--------------|-----------|-------------|
| Line         | 80%       | CI fails below; ratcheted (cannot regress) |
| Branch       | 60%       | Same |
| New code     | Must not lower either metric on the diff | `--fail-under` on changed files |

Ratchet: `coverage.json` committed to repo; CI compares PR value against baseline.
Merging below baseline requires explicit tech-lead override with ticket number in PR description.

**Do not worship the number.** 95% coverage on trivial getters is useless.
Prioritise coverage on: error paths, edge cases, business-critical branches.

**Mutation testing** _(scale-up)_: run [mutmut](https://github.com/boxed/mutmut) (Python) or
[Stryker](https://stryker-mutator.io/) (TS/JS) weekly in CI to surface tests that pass even
when logic is corrupted. Mutation score target: ≥ 70%.

---

## 7. e2e, smoke, and load testing

**e2e ownership**: product engineering owns the suite; QA owns the scenario catalogue.
Tests live in `tests/e2e/` and target staging; never run against production except smoke.

| Test type   | When it runs              | Owner      | Blocking? |
|-------------|---------------------------|------------|-----------|
| Smoke (5–10 flows) | Post-deploy (staging + prod) | Platform | Yes — rollback on fail |
| e2e suite   | Nightly + pre-release      | Eng        | Yes (nightly gate) |
| Load / perf | Weekly + pre-scale event   | Platform   | Advisory (alert, not block) |

Smoke tests are a strict subset of e2e: < 3 min, deterministic, no writes to shared state.

**Load and performance testing**: see [ci-cd.md](../platform/ci-cd.md) for pipeline hooks and
performance baseline tooling. Load tests run in an isolated environment; never against
shared staging unless traffic is synthetic and flagged.

---

## Definition of done

- [ ] Unit tests cover all new logic paths; no new branch coverage regression
- [ ] Integration tests cover every new service boundary or DB query
- [ ] Contract tests updated for any API schema change (Pact / buf)
- [ ] No mocks of internal functions; fakes used at process boundaries
- [ ] All tests are hermetic: no shared mutable state, no real clock/network in unit layer
- [ ] Data-dependent tests have `skipif` guards for clean-checkout CI
- [ ] Flake budget checked: ≤ 2 quarantined tests in the affected squad
- [ ] Coverage floor maintained (80% line / 60% branch); ratchet not broken
- [ ] Smoke tests pass on staging post-deploy
- [ ] No `--rerun-failures` or retry flags added to CI config
