# PerpMe V2 — Security Review

**Scope:** the dividend-coin contracts in this repository (`src/tax/`)
**Code reviewed:** the commit this file ships in
**Report date:** 2026-09-17
**Chain:** HyperEVM (chain id 999)

> **Read this first.** This is an **internal** security review carried out by the
> PerpMe team with AI-assisted code review, fork-based proof-of-concept testing and a
> full production rehearsal. It is **not** an audit by an independent security firm,
> and no review can prove the absence of bugs. It is published so users, integrators
> and exchanges can do their own research. The fixes are covered by the test suite in
> this repository, and where a finding names a test, that test reproduces the original
> problem or proves the fix and can be re-run with `forge test`.

---

## Contents

1. [Summary](#1-summary)
2. [Scope](#2-scope)
3. [How the system works](#3-how-the-system-works)
4. [Trust model and privileged roles](#4-trust-model-and-privileged-roles)
5. [Methodology](#5-methodology)
6. [Findings and fixes](#6-findings-and-fixes)
7. [Invariants verified](#7-invariants-verified)
8. [Good to know before trading](#8-good-to-know-before-trading)
9. [Integration notes for Ramses](#9-integration-notes-for-ramses)
10. [Reproducing the results](#10-reproducing-the-results)

---

## 1. Summary

| | |
|---|---|
| Review rounds | 6, between 2026-08-13 and 2026-09-17 |
| Issues found and fixed in the contracts | 30+ (see [§6](#6-findings-and-fixes)) |
| Open critical / high issues | **None known** |
| Tests | 185, run against a HyperEVM mainnet fork |
| Production rehearsal | 32 launch configs, 32 coins launched, 26 graduated on PRJX and Ramses, 78 post-graduation trading rounds, dividend bot run — **0 invariant violations** |
| Mainnet staging | Three staging deployments exercised with real trades on PRJX and Ramses; accounting reconciled to the wei |
| Upgradeability | **None.** No proxies, no `delegatecall` upgrade path |
| Pause / blocklist | **None.** Trading cannot be paused and no address can be blocked from transferring |
| Owner access to holders' dividends | **None** (see [§4](#4-trust-model-and-privileged-roles)) |
| Liquidity after graduation | LP tokens are minted directly to `0x…dEaD` — nobody can withdraw pool liquidity |

---

## 2. Scope

**In scope** — 5,087 lines of Solidity:

| File | Lines |
|---|---|
| `src/tax/PerpMeTaxToken.sol` | 1,519 |
| `src/tax/PerpMeDividendDistributor.sol` | 795 |
| `src/tax/PerpMeCurve.sol` | 683 |
| `src/tax/PerpMeTaxFactory.sol` | 596 |
| `src/tax/PerpMeBridge.sol` | 375 |
| `src/tax/venue/PerpMeRamsesVenue.sol` | 282 |
| `src/tax/PerpMeMarketRouter.sol` | 246 |
| `src/tax/venue/PerpMeUniV2Venue.sol` | 217 |
| `src/tax/PerpMeCurveRouter.sol` | 206 |
| `src/tax/venue/IPerpMeVenue.sol` | 112 |
| `src/tax/PerpMeTaxTokenDeployer.sol` | 56 |

Compiler 0.8.26, `via_ir`, EVM `cancun`. Dependencies: OpenZeppelin Contracts 5.5
(`ERC20`, `Ownable`, `ReentrancyGuard`, `SafeERC20`).

**Out of scope:** the perpme.fun website, indexer and dividend bot (off-chain; the bot
only calls public functions anyone can call), the external protocols the contracts
interact with (PRJX V2/V3, Ramses, Nest, WHYPE) and the pair tokens themselves
(tokenised stocks, stablecoins, RAM, etc.).

---

## 3. How the system works

1. **Launch.** `PerpMeTaxFactory.launchToken` deploys a coin, its bonding curve and its
   dividend distributor, and creates (reserves) the coin's future pair on the chosen
   exchange. Supply is fixed at 1,000,000,000; 793.1M are sold on the curve,
   206.9M are held for the pool.
2. **Curve.** Buys and sells pay a 1.5% platform fee plus the coin's tax (1–5%, chosen at
   launch). Tax is paid in the pair token and split in the same transaction: the
   protocol's share (20%) first, then the creator and holders in the creator's chosen
   ratio. A buy's tax is split **before** the buyer receives coins, so it goes to those
   who held before the buy; the opening buy of a coin, with no holders yet, sends the
   holders' share to the protocol. The reserved pair cannot be funded by anyone during
   the curve phase.
3. **Graduation.** The buy that empties the curve also graduates the coin in the same
   transaction: the remaining coins and everything raised open the pair, and the LP
   tokens are minted to `0x…dEaD`.
4. **After graduation.** Transfers into and out of any recognised market pay the tax in
   coins, which accrue on the coin contract. Transfers between wallets are untaxed.
   Accrued tax is sold back into the pair — during a user's sale into the pair once
   the accrued amount passes a threshold, or through the public `liquidate()` — then
   the burn share is burned and the proceeds are split and credited to holders.
   Each sale is capped at 0.5% of the pool's coins, happens at most once per block,
   and only if the pool's current price is at least 20% of its time-weighted average.
5. **Dividends.** The distributor credits every holder pro rata. Credited dividends are
   paid automatically (two holders per taxed trade, at most once an hour each), by any
   caller through `distribute` / `claimFor`, or claimed by the holder with `claim`.
   Selling all one's coins does not forfeit what was earned.

---

## 4. Trust model and privileged roles

### Factory owner

A **single owner address** (OpenZeppelin `Ownable`, two-step transfer,
`renounceOwnership` disabled). It is not a multisig.

**For future launches only** — changing these never affects a coin already launched,
because each coin copies them at launch: add exchanges and launch configs, enable or
disable them, pause new launches, set the launch fee, the protocol's share of tax
(capped in code) and the curve router.

**For live coins:**

| Function | What it can do | Bounds |
|---|---|---|
| `lowerTax` | Lower a coin's buy/sell tax | Only down, never below 1% |
| `setExcluded` | Stop an address earning **new** dividends | What it already earned stays claimable; markets can never be re-included |
| `reclaim` | Return the unclaimed dividends of an address to the **other holders** | Only after the address has held **zero coins for 10 days**; never to the owner |
| `rescueTax` | Take a coin's accrued, unsold tax to an address | Only after **3 days with no successful tax sale**; it first tries the sale itself and returns 0 if that works; refused inside a flash swap on the pair |
| `rescue` | Recover a token sent to a distributor by mistake | Never the reward (pair) token |
| `setCreatorRecipient` | Redirect a coin's creator share (e.g. community takeover of an abandoned coin) | Only the creator's share; the current recipient can also call it |

**What the owner cannot do:** mint coins, change supply, raise tax, pause or block
trading, move or withdraw pool liquidity (LP is burned), take holders' credited
dividends, upgrade any contract, or change a live coin's exchange, curve or fee split.

### Creator

No privileged powers over the coin beyond receiving the creator share of tax and
redirecting where that share is paid.

### Keeper / dividend bot

None. It uses `liquidate()`, `distribute()` and the pair's own `sync()`, all public.
If it stops, dividends still accrue and remain claimable; tax is still sold during
users' sales and through `liquidate()` by anyone.

---

## 5. Methodology

- **Manual and AI-assisted line-by-line review** of every contract, repeated after each
  round of changes (six rounds, 2026-08-13 → 2026-09-17), including an analysis of a
  byte-identical predecessor deployed on another chain.
- **Code-level findings reproduced before they were fixed**, on a fork of HyperEVM mainnet
  against the real PRJX, Ramses and Nest contracts and real pair tokens, and kept as a
  regression test (`test/AuditFindings.t.sol`, `test/AuditFable51.t.sol`,
  `test/AuditOpus5.t.sol`, `test/TaxBridgeTooThin.t.sol`, and the rest of the suite).
- **Production rehearsal** on a local mainnet fork using the real deployment scripts
  (`DeployTax`, `AddTaxConfigs`): one coin on every one of the 32 launch configs
  (16 pair tokens × PRJX and Ramses), curve round trips in HYPE, graduation by buying
  the curve out with HYPE, three rounds of post-graduation trading with time advanced
  past the price guards, and the dividend bot — then an invariant check of every coin
  against its on-chain events (§7).
- **Mainnet staging.** Three staging factories deployed on HyperEVM mainnet from a test
  wallet; real launches, trades, a graduation onto Ramses, tax sales by the bot, and
  holder payouts, reconciled transaction by transaction.
- **Third-party scanner output** (Axiom, BasedBot) reviewed and the valid points
  addressed (§6, round 6).

---

## 6. Findings and fixes

Severity reflects impact at the time of discovery. All listed issues are **fixed** in
the reviewed code unless marked otherwise.

### Round 1 — 2026-08-13

| ID | Sev. | Issue | Fix / test |
|---|---|---|---|
| R1-H1 | High | A router permitted by the coin could deliver coins into the reserved (not yet created) pool address and mint LP there before graduation, capturing the migration liquidity (reproduced: 8 wNVDAx in → 23.6 wNVDAx + 214.5M coins out). | Reserved pair closed to everyone including routers. `AuditFindings: test_H1_*` |
| R1-H2 | High | A swap threshold that could never be reached (or zero) left tax stranded in the coin forever (9.8M coins in the PoC). | Threshold bounded at launch; zero holders' share refused. `test_H2_*` |
| R1-M1 | Medium | Automatic payout floor ignored the reward token's decimals: no automatic payouts at all on 6-decimal pairs. | Floor derived from decimals. `test_M1_*` |
| R1-M2 | Medium | Opening buy's holder share went to the treasury via the factory's own account. | Superseded by round 6 design (opening buy is taxed like any buy). `test_M2_*` |
| R1-L3 | Low | Only the graduation pair was taxed; a second pool for the coin traded tax-free. | Any recognised market is taxed. `test_L3_*` |

### Round 2 — 2026-09-09

| ID | Sev. | Issue | Fix |
|---|---|---|---|
| R2-1 | High | Holders who sold could never be paid automatically again; on the predecessor deployment 12% of all dividends sat unclaimed under 177 departed addresses. | `claimFor` and `distribute(list)`; payouts reach any address, not only current holders. |
| R2-2 | High | Reserved pair address computed from a hard-coded init-code hash that did not match PRJX, so the curve-phase guard protected an address no pool would use. | Pair is created through the exchange at launch and its real address stored. |
| R2-3 | Medium | Exchange swap fee assumed to be 0.3%; on any other fee the tax sale reverted forever inside a try/catch. | Exchange-specific venue contracts quote the pair's own output. |
| R2-4 | Medium | Price guard refused 179 of 322 eligible tax sales. | Guard compares against the last computed average. |

### Round 3 — 2026-09-10 (multi-exchange)

| ID | Sev. | Issue | Fix / test |
|---|---|---|---|
| R3-C1 | Critical | Curve router encoded calls for a router interface PRJX does not deploy: every HYPE trade on a curve reverted. | Bridge rewritten for PRJX's classic SwapRouter. `AuditFable51: test_F5_*` |
| R3-C3 | Critical | Nest restricts pair creation to a role; a launch config on Nest would revert every launch. | Nest venue registered but **no launch configs** until Nest opens pair creation. `test_F3_*` |
| R3-H1 | High | `liquidate()` was capped per call, not per block: 24 calls in one block sold a 25M-coin pot and moved the price −20%. | One tax sale per block. `test_F1_*` |
| R3-H2 | High | On Velodrome-style pairs the fee vault receives coins and would have become a dividend shareholder. | Venue reports fee sinks; the coin excludes them. `test_F4_*` |
| R3-M1 | Medium | `rescueTax` opened after a period with no sale, which a quiet but healthy coin also satisfies. | Rescue first attempts the sale; only a sale the exchange refuses opens it. |
| R3-M2 | Medium | Ramses records a price observation at most every 30 minutes; a fixed 4-period average delayed a new coin's first tax sale by 2 hours. | Average over available history (≥ 1 period, ≤ 4). `test_F2_*` |

### Round 4 — 2026-09-12 (full sweep)

| ID | Sev. | Issue | Fix |
|---|---|---|---|
| R4-1 | High | A clearing buy through the HYPE bridge had no cap on HYPE spent; a front-run made a 9.30 HYPE fill cost 10.57. | `maxNativeIn` on `buyWithNative`; spend measured, remainder refunded. |
| R4-2 | High | `rescueTax` callable from inside a flash swap on the pair, where the sale always fails — draining a healthy coin's tax. | Refused while the pair is mid-swap. |
| R4-3 | Medium | A transfer where both sides are markets was charged the buy rate on a sale. | Coins going into a market always pay the sell rate. |
| R4-4 | Medium | Excluding a holder moved their earned dividend to a pot the owner could sweep. | Superseded by round 6 (exclusion no longer touches earned dividends; sweep removed). |

### Round 5 — 2026-09-12 (independent PoC pass)

| ID | Sev. | Issue | Fix / test |
|---|---|---|---|
| R5-1 | High | A contract filled with coins during the curve and later recognised as a market kept its dividend shares: 422M phantom shares, 35% of the register. | Shares settled when an address is recognised as a market. `AuditOpus5: test_SharesAreGivenUp*` |
| R5-2 | High | `initialize` on a freshly deployed coin was open to anyone until the factory called it. | Only the deployer or its factory. `test_OnlyTheDeployerOrItsFactoryCanInitialize` |
| R5-3 | Medium | Any contract answering `token0()` with the coin was treated as a market (taxed, excluded from dividends). | A market must answer consistently for both tokens. `test_AContractExposingOnlyToken0IsNotAMarket` |

### Round 6 — 2026-09-14 → 2026-09-17 (mainnet staging and scanners)

| ID | Sev. | Issue | Fix / test |
|---|---|---|---|
| R6-1 | High | `reclaim` followed by `sweepUnattributed` let the owner take a departed holder's dividends. | `reclaim` spreads to holders in the same call; `sweepUnattributed` **removed**. `test_ReclaimWaitsTheAbandonPeriodAndRefusesALiveHolder` |
| R6-2 | Medium | `setExcluded` took back what the excluded holder had already earned (flagged by Axiom). | Exclusion affects only future dividends. `test_ExcludingAHolderKeepsWhatTheyEarned` |
| R6-3 | Low | Owner could withdraw unattributed reward (flagged by Axiom). | Replaced by public `spreadUnattributed()`, which can only credit holders. `test_StrayRewardIsSpreadOverTheHoldersByAnyone` |
| R6-4 | High | A HYPE buy larger than a thin bridge pool could absorb swapped partially and left the rest in PRJX's router, where anyone could take it (reproduced: 414 HYPE stranded and taken). | Bridge reverts with `BridgeTooThin` if anything is left behind, on buys and sells, single- and two-hop. `TaxBridgeTooThin.t.sol` |
| R6-5 | Medium | A buyer received a pro-rata share of the tax on their own buy (up to 100% for an opening buy). | Tax split before coins are delivered. `test_ABuyerIsNotPaidOutOfTheirOwnTax` |
| R6-6 | Info | Abandonment period (1 year) and rescue delay (30 days) judged too long for a memecoin lifecycle. | 10 days and 3 days. |

---

## 7. Invariants verified

Checked for **every** coin in the production rehearsal, before and after the dividend
bot ran, from on-chain state and events — **32 coins, 0 violations**:

1. Distributor reward-token balance = deposited − paid − reclaimed + unattributed (no
   value created or lost; residual rounding ≤ 8 wei).
2. Sum of `Deposited` events = `totalDeposited`; sum of `Paid` + `Claimed` = `totalClaimed`.
3. Supply decrease = sum of `TaxBurned`.
4. Tax held by the coin = collected − sold − burned − rescued.
5. Every split: protocol share exact; creator : holders in the configured ratio.
6. Every curve trade: platform fee exactly 1.5%; fee : tax in the configured ratio,
   including the trimmed clearing buy.
7. A buy's tax is split before the buyer's dividend share is written.
8. Dividend shares equal balances for every holder; pools, curves, the coin itself and
   `0x…dEaD` hold none; shares sum to `totalShares`.
9. Every graduated pool: all LP at `0x…dEaD`.
10. After the bot: no holder left owed more than the minimum payout.
11. No HYPE or tokens left in PRJX's router or in either PerpMe router.

---

## 8. Good to know before trading

| Topic | What it means | How it is handled |
|---|---|---|
| **Review type** | This review is internal and AI-assisted, not a third-party audit. | All code, tests and findings are public and reproducible (§10). |
| **Administration** | The factory is administered by one owner address. | Its powers are limited in code (§4): it cannot mint, raise tax, pause trading, touch pool liquidity or take holders' dividends. |
| **Trading through other apps** | The coin charges its tax on pool transfers, like every dividend/tax token. Some scanners simulate a plain swap and show "sell tax 100%". | Selling works on perpme.fun, through the PerpMe routers and through any router's fee-on-transfer swap — proven in `TaxLiveScenarios`. |
| **Tax sale timing** | Tax is sold gradually (≤ 0.5% of the pool per block) and waits while the price is far below its average. On Ramses the first sale needs two price observations. | Protects holders from selling into a dump. Dividends already credited are never affected; the keeper calls `sync()` so an idle Ramses pair gets its observation. |
| **Dividend currency** | Dividends are paid in the coin's pair token (HYPE, USDC, RAM, …). | That is the product: holders earn the asset they chose. A payout a token refuses stays claimable. |
| **Buying with HYPE** | HYPE buys route through an existing pool for the pair token; smaller pools mean more price impact on large buys. | The site shows the price impact; an oversized buy reverts instead of losing funds. Buying with the pair token directly has no bridge cost. |
| **External exchanges** | Pools live on PRJX and Ramses. | The contracts use only their public functions and hold no permissions on them (§9). |
| **Market risk** | Like any token, prices move and fees apply on each trade. | Liquidity is locked for good at graduation (LP burned). |

---

## 9. Integration notes for Ramses

The contracts interact with Ramses **only through public, permissionless functions**
and hold **no permissions, roles or token approvals** on any Ramses contract.

| Ramses call | Purpose |
|---|---|
| `PairFactory.getPair(a, b, false)` / `createPair(a, b, false)` | Create the coin's volatile pair at launch |
| `Pair.mint(0x…dEaD)` | Seed the pool at graduation; LP burned |
| `Pair.getAmountOut`, `getReserves`, `token0`, `swap` | Tax sales, trading through the PerpMe routers, RAM/WHYPE bridge for HYPE buys |
| `Pair.observationLength`, `quote(tokenIn, amountIn, granularity)` | Time-weighted average price for the tax-sale guard |
| `Pair.fees`, `communityVault` (if present) | Identify fee sinks to exclude from dividends |
| `Pair.sync()` | Called by the PerpMe bot to record a price observation on an idle pair |

Tests against the live Ramses contracts: `test/RamsesVenue.t.sol`,
`test/TaxOnRamses.t.sol`, `test/TaxLiveScenarios.t.sol`, and every pair token on Ramses
in `test/TaxAllPairs.t.sol` / `test/TaxRoutingAllPairs.t.sol`.

---

## 10. Reproducing the results

```bash
git clone https://github.com/iwaterheater/PerpMeV2 && cd PerpMeV2
forge build
anvil --fork-url https://rpc.hyperliquid.xyz/evm --port 8555 --retries 10 --timeout 120000
HYPEREVM_RPC_URL=http://127.0.0.1:8555 forge test -j 2
```

Questions or reports: contact the PerpMe team at [perpme.fun](https://perpme.fun) or
[x.com/perpmefun](https://x.com/perpmefun).
