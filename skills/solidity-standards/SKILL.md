---
name: solidity-standards
description: Use when writing, reviewing, testing, or deploying Solidity / EVM smart contracts in a touchstone repo — security-first patterns, Foundry toolchain, fuzz/invariant testing, gas, and upgradeability. Triggers on .sol files, foundry.toml, hardhat.config. Boundary: on-chain code only — off-chain app/API auth lives in app-security-standards, CI secret-scanning in security-standards.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Solidity / Smart Contract Standards

Full standard: **`standards/languages/solidity.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **Deployed code is immutable and adversarial** — assume every external call is hostile, every input an attack, every bug a withdrawal.
- **Foundry** is the toolchain; pin `solc` exactly in `foundry.toml` (not `^0.8`); commit `foundry.lock` + library commits.
- **Checks-Effects-Interactions on every function**, external call last; add OZ `nonReentrant` to anything that calls out.
- **Access control via OZ `Ownable2Step`/`AccessControl`**, deny-by-default; hand ownership to a multisig, never an EOA.
- **Fuzz + invariant tests are mandatory** for value-handling code (`forge test`); fork-test against real mainnet state.
- **Slither clean in CI; independent audit + bug bounty + verified source before mainnet.**

## Don't get burned
- **Validate every low-level call's `success`**; use `SafeERC20` (USDT et al. don't return a bool); `.transfer`/`.send` are deprecated.
- **Never price off a spot AMM reserve** — flash loans move it in one tx; use Chainlink with staleness+bounds checks, or a TWAP.
- **The mempool is public** — bound slippage/deadline on trades, commit-reveal for order-sensitive actions; assume front-running.
- **Solidity 0.8+ math is checked** — `unchecked` only with a proven bound and a comment; never blindly "for gas".
- **Prefer immutable contracts.** If you must upgrade, use UUPS: guard `_authorizeUpgrade`, never reorder storage, reserve `__gap`, `_disableInitializers()` in the implementation.
- **Custom errors over require-strings**; pack storage slots; `constant`/`immutable` for fixed config; gate gas with `forge snapshot --check`.

## Done
`forge build` + `forge fmt --check` clean · `forge test` green with fuzz + invariant suites · CEI + `nonReentrant` on value functions · `SafeERC20` + oracle staleness checks · Slither clean · audit + bug bounty + verified source before mainnet. See `standards/languages/solidity.md`.
