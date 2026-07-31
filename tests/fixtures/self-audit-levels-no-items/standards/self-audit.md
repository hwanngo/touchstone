# Self-Audit Checklist

Fixture for tests/gates/self-audit-levels.test.sh.

## Maturity levels

| Level | Name | What it requires | For |
|---|---|---|---|
| **L1** | Hygiene | Lockfiles committed | any repo |
| **L2** | Gated | All L1 enforced in CI | team repos |
| **L3** | Hardened | Actions SHA-pinned | deployed |
| **L4** | Scale-up | SLOs + tested DR | production |

Each item below is tagged with the level it first becomes required.

## Example section


```text
- [ ] this line is inside a fence and is not a checklist item
```
