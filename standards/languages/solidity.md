# Solidity / Smart Contract Standards

Applies to any EVM smart-contract project. Toolchain is **Foundry** (`forge`/`cast`/`anvil`),
solc pinned in `foundry.toml`, libraries from **OpenZeppelin Contracts v5**, tested with **forge
test** plus **fuzz + invariant** runs. This doc owns the on-chain attack surface; cross-cutting
concerns defer to siblings: off-chain app/API auth to [app-security.md](../practices/app-security.md),
secret scanning and CI gates to [security.md](../practices/security.md), and the unit/integration/property
split to [testing-strategy.md](../practices/testing-strategy.md).

> **One law:** deployed code is immutable and adversarial — assume every external call is hostile,
> every input is an attack, and a bug is a withdrawal.

---

## 1. Toolchain & versions

| Concern | Tool | Notes |
|---|---|---|
| Build · test · deploy | **Foundry** (`forge`) | Solidity-native tests, fastest fuzzer; the default |
| Chain interaction | **`cast`** | call/send/decode from the CLI; scriptable |
| Local node | **`anvil`** | deterministic dev chain + mainnet forking |
| Libraries | **OpenZeppelin Contracts v5** | audited Ownable/AccessControl/ERC implementations — never hand-roll |
| Escape hatch | **Hardhat** | only when you need its TS plugin/deploy ecosystem; don't mix runners per repo |

- **Pin the compiler in `foundry.toml`** — an exact `solc` version is reproducible bytecode; a
  floating `^0.8.x` pragma is a different contract on every machine.
  ```toml
  # foundry.toml
  [profile.default]
  solc        = "0.8.30"        # exact, not "^0.8" — pinned for reproducible bytecode
  evm_version = "cancun"        # match the target chain's supported opcodes
  optimizer   = true
  optimizer_runs = 200          # tune to call frequency; affects deployed bytecode + gas
  via_ir      = true            # IR pipeline: better optimization, catches stack-too-deep
  fuzz        = { runs = 1000 }
  ```
- **Floor the pragma at the pinned minor** (`pragma solidity 0.8.30;` for deployables; `^0.8.20`
  only for reusable libraries) so a contract can't be compiled by a buggy older `solc`.
- **Commit `foundry.lock` and pin library commits** — `forge install` records a git ref; CI runs
  `forge build --offline` against the locked tree, never a moving `master`.

## 2. Everyday commands

```bash
forge build                                   # compile (CI gate)
forge fmt --check                             # formatting verify (CI gate)
forge test -vvv                               # run tests, verbose traces on failure
forge test --match-test invariant_ --fuzz-runs 10000   # heavier fuzz/invariant pass
forge coverage --report lcov                  # coverage; ratchet a floor in CI
forge snapshot --check                        # gas snapshot — fail PR on regression
slither .                                     # static analysis (CI gate)
cast call $ADDR "balanceOf(address)(uint256)" $USER --rpc-url $RPC   # read on-chain state
anvil --fork-url $MAINNET_RPC                 # local fork for integration tests
```

Deploy via a checked-in `forge script` (Solidity, version-controlled, dry-runnable with
`--simulate`) — **never** ad-hoc `cast send` to mainnet. Keys come from a hardware wallet or
`cast wallet`, **never** a plaintext private key in env or history.

## 3. Checks-Effects-Interactions & reentrancy

- **Order every function Checks → Effects → Interactions, always.** Validate inputs, then mutate
  *all* state, then make external calls last — so a reentrant callback sees already-updated state.
  The DAO ($60M, 2016) and dozens since were a single out-of-order `transfer`.
  ```solidity
  function withdraw(uint256 amount) external {
      require(balances[msg.sender] >= amount, "insufficient");  // Checks
      balances[msg.sender] -= amount;                           // Effects (before the call)
      (bool ok, ) = msg.sender.call{value: amount}("");         // Interactions (last)
      require(ok, "transfer failed");
  }
  ```
- **Add `nonReentrant` to every state-changing function that makes an external call** —
  OpenZeppelin `ReentrancyGuard` is the belt to CEI's braces. Guard against **cross-function** and
  **read-only** reentrancy too: a view function reading mid-update state can mislead an integrator.
- **Treat ERC-777/ERC-721 hooks and any token callback as untrusted code** — `onERC721Received`,
  `tokensReceived`, and fee-on-transfer tokens hand control to the attacker mid-execution.
- **Pull over push for payments** — credit a balance the recipient withdraws, rather than pushing
  ETH in a loop; one reverting recipient shouldn't brick the whole batch.

## 4. Access control

- **Use OpenZeppelin, deny by default.** `Ownable2Step` for single-admin (two-step transfer avoids
  fat-fingering ownership to a dead address); `AccessControl` for role-based — and **never** the
  one-step `Ownable` for anything holding value.
  ```solidity
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

  function mint(address to, uint256 id) external onlyRole(MINTER_ROLE) { _mint(to, id); }
  ```
- **The deployer is not the admin.** Transfer ownership to a **multisig** (Safe) or governance
  contract at the end of deployment; a single EOA key is a single point of catastrophic failure.
- **Gate privileged setters with events + a timelock** _(scale-up)_ — parameter changes (fees,
  oracles, upgrade authority) route through an `TimelockController` so users can exit before a
  malicious or compromised admin action takes effect.
- **Initializers, not constructors, for proxies** — guard with `initializer`/`_disableInitializers()`
  (§9); an un-disabled implementation initializer is a takeover vector.

## 5. Arithmetic & external-call safety

- **Solidity 0.8+ has checked math** — overflow/underflow revert by default. Reach for `unchecked`
  **only** in a proven-safe hot loop, with a comment proving the bound; never to "save gas" blindly.
- **Validate the result of every low-level call.** `.call`/`.delegatecall`/`.staticcall` return
  `(bool success, bytes data)` — an unchecked `success` swallows a failed transfer. `.transfer`/
  `.send` (2300-gas stipend) is deprecated; use `.call{value:}` **with** CEI + `nonReentrant`.
- **Use SafeERC20** (`safeTransfer`/`safeTransferFrom`) — many real tokens (USDT) don't return a
  bool; a raw `transfer` reverts or silently no-ops. Never assume ERC-20 conformance.
- **Oracle manipulation is the modern top exploit.** Never price off a spot AMM reserve (a
  flash-loan moves it in one tx). Use **Chainlink** price feeds and **check staleness + bounds**:
  ```solidity
  (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();
  require(price > 0, "bad price");
  require(block.timestamp - updatedAt <= MAX_STALENESS, "stale oracle");
  ```
  For on-chain prices use a **TWAP** (time-weighted), never an instantaneous reserve ratio.

## 6. Front-running & MEV

- **Assume the mempool is public and adversarial** — anyone sees your tx before it mines and can
  reorder, sandwich, or copy it. Never design as if transactions are private.
- **Bound slippage on every swap/trade** — pass `minAmountOut`/`deadline` from the caller; an
  unbounded swap is a free sandwich for a searcher.
- **Use commit-reveal for order-sensitive actions** (auctions, games, claims) — commit a hash
  first, reveal the value later, so the value isn't front-runnable.
- **Don't leak privileged value in calldata** — a liquidation/arbitrage opportunity visible in a
  pending tx will be back-run; route through a private relay (Flashbots) _(scale-up)_ when MEV is
  material.

## 7. Testing

Mandatory for any code that moves value. The unit/integration philosophy lives in
[testing-strategy.md](../practices/testing-strategy.md); this is the on-chain specifics.

- **Unit tests in `forge test`** beside the contract; assert reverts with `vm.expectRevert`, events
  with `vm.expectEmit`, and use `vm.prank`/`deal` to set up adversarial callers and balances.
- **Fuzz tests are non-negotiable for value math** — type a test parameter and Foundry throws
  thousands of inputs at it, shrinking failures to a minimal counterexample:
  ```solidity
  function testFuzz_depositThenWithdraw(uint96 amount) public {
      vm.assume(amount > 0);
      vault.deposit(amount);
      assertEq(vault.withdraw(amount), amount);   // round-trip holds for ALL inputs
  }
  ```
- **Invariant testing for protocol-level properties** — assert what must hold across *any* sequence
  of calls (e.g. "sum of balances == totalSupply", "vault never lends more than reserves"). Foundry
  drives random call sequences against handler contracts; this catches the bugs unit tests can't.
- **Fork-test against mainnet state** (`vm.createSelectFork`) so integrations with real Chainlink/
  Uniswap/token contracts are tested against reality, not mocks.
- **Differential / symbolic** _(scale-up)_ — **Echidna** or **Medusa** for property-based campaigns;
  **Halmos** for symbolic checks of bounded properties.

## 8. Gas optimization

Optimize after correctness, never before — but storage is the one place to think ahead.

- **Pack storage slots deliberately** — group `uint`s/`bool`s/`address` so they share a 32-byte
  slot; an `SSTORE` to a cold slot is ~20k gas. Order struct fields by size, smallest adjacent.
- **`constant` and `immutable` cost no storage** — compile-time constants and constructor-set
  values live in bytecode, not slots; use them for config that never changes after deploy.
- **Custom errors over `require` strings** — `revert InsufficientBalance(have, want)` is cheaper to
  deploy and revert than a string, and carries typed data:
  ```solidity
  error InsufficientBalance(uint256 have, uint256 want);
  if (bal < want) revert InsufficientBalance(bal, want);
  ```
- **Cache storage reads in memory** inside loops; emit events for off-chain indexing instead of
  storing derivable data on-chain.
- **Gate gas with `forge snapshot --check`** in CI so a refactor that regresses gas fails the PR.

## 9. Upgradeability

- **Prefer immutable.** An unupgradeable contract has no admin-key risk, no storage-layout
  footgun, and is trivially auditable. Reach for a proxy only when the contract *must* evolve, and
  document why.
- **If you upgrade, use UUPS** (ERC-1822) over the older Transparent proxy — the upgrade logic lives
  in the implementation (cheaper calls), but that means **a bad implementation can brick upgrades**;
  guard `_authorizeUpgrade` with access control and test the upgrade path.
- **Storage layout is sacred** — never reorder or remove existing state variables; only append, and
  reserve a `uint256[50] __gap`. A layout collision silently corrupts every value. Verify with
  `forge inspect <C> storage-layout` and OpenZeppelin's `validateUpgrade`.
- **`_disableInitializers()` in the implementation constructor** and use the `initializer` modifier
  — an implementation contract left initializable can be hijacked and used to attack the proxy.
- **Route upgrades through a timelock + multisig** _(scale-up)_ so an upgrade is announced and
  exit-able, not instantaneous.

## 10. Static analysis & formal verification

- **Run Slither on every PR** — it catches reentrancy, uninitialized storage, arbitrary `delegatecall`,
  and dozens of detectors in seconds; wire it as a blocking CI gate and triage findings explicitly.
- **Mythril / symbolic execution** for deeper paths on the highest-value contracts — slower, finds
  what pattern-matchers miss.
- **Formal verification** _(scale-up)_ — **Certora** specs (CVL) or **Halmos** prove properties hold
  for *all* inputs, not just sampled ones; worth it for AMMs, lending, and bridges where a single
  edge case is a drain.

## 11. Documentation & release gates

- **NatSpec on every external/public function** — `@notice`/`@param`/`@return`/`@dev`; it's the
  source of the user-facing function docs and many tools verify its presence.
- **Independent audit before mainnet, non-negotiable** for anything holding user funds — one or more
  reputable firms, with findings fixed and re-reviewed; publish the report.
- **Stand up a bug bounty** (Immunefi/Cantina) sized to TVL *before* launch, and ship to a public
  testnet first. Verify and publish source on the block explorer so users can read what they trust.

## 12. Dependencies & supply chain

- **Pin every library to an exact commit.** `forge install` records a git ref and `foundry.lock`
  locks the tree (§1); CI runs `forge build --offline` against it, never a moving `master`. For
  versioned dependency management use **Soldeer** (`forge soldeer install`, deps under
  `[dependencies]` in `foundry.toml`) over hand-managed git submodules.
- **Audit the off-chain deps too.** A Hardhat/JS toolchain pulls npm packages — run **`npm audit`**
  (or `pnpm audit`) on that side in CI; the on-chain risk is bytecode, but the build pipeline is a
  supply-chain surface like any other.
- **Prefer audited library code** — **OpenZeppelin Contracts** over hand-rolled primitives (§1) —
  and bump deps deliberately, treating published advisories as priority work.
- **The cross-cutting policy** — update cooldown, SBOM, signing/provenance — lives in
  [security.md](../practices/security.md) and [dependencies.md](../practices/dependencies.md).
  On-chain static analysis is **Slither** (§10), a code scanner, not a dependency-CVE audit.

## Definition of done

- [ ] `forge build` clean; `solc` pinned exactly in `foundry.toml`; `foundry.lock` + lib commits committed
- [ ] Library deps pinned to exact commits (Soldeer/submodules); off-chain `npm audit` clean (or advisories triaged)
- [ ] `forge fmt --check` clean
- [ ] All state-changing functions follow Checks-Effects-Interactions; external-calling ones are `nonReentrant`
- [ ] Access control via OZ `Ownable2Step`/`AccessControl`, deny-by-default; ownership handed to a multisig, not an EOA
- [ ] Low-level calls' `success` checked; `SafeERC20` for token transfers; oracles staleness-and-bounds checked (no spot AMM price)
- [ ] Slippage/deadline bounded on trades; no privileged value leaked to the mempool
- [ ] `forge test` green with **fuzz + invariant** suites for all value-handling code; fork-tested against mainnet
- [ ] Custom errors over revert strings; storage packed; `constant`/`immutable` used; `forge snapshot --check` passes
- [ ] Immutable by default; any proxy is UUPS with `_authorizeUpgrade` guarded, `__gap` reserved, layout validated
- [ ] **Slither** clean (or triaged) in CI; formal verification on highest-value invariants _(scale-up)_
- [ ] NatSpec on every external/public function; **independent audit + bug bounty + verified source** before mainnet

**Sources:** [Foundry Book](https://book.getfoundry.sh) · [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/5.x/) · [Solidity docs](https://docs.soliditylang.org) · [Slither](https://github.com/crytic/slither)
