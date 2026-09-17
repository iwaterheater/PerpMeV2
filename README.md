# PerpMe V2 — dividend coins on HyperEVM

Smart contracts for the second product of [perpme.fun](https://perpme.fun): coins that
charge a 1–5% tax on trades and pay it to their holders, in the token the coin is
quoted against (HYPE, USDC, RAM, NEST, tokenised stocks, …).

> **Security:** see [SECURITY-REVIEW.md](SECURITY-REVIEW.md) — scope, trust model, findings and fixes, invariants and known risks.
>
> **Status:** pre-production. Not yet deployed to a production factory. A staging
> factory on HyperEVM mainnet runs an earlier revision of this code.

## Lifecycle of a coin

1. **Launch.** `PerpMeTaxFactory.launchToken` deploys the coin (`PerpMeTaxToken`),
   its bonding curve (`PerpMeCurve`) and its dividend distributor
   (`PerpMeDividendDistributor`), and reserves the future pair on the chosen
   exchange. Every coin has 1,000,000,000 supply; 793.1M are sold on the curve.
2. **Curve.** Trades pay a 1.5% platform fee plus the coin's own tax. The tax is
   split at once: 20% to the protocol, the rest between the creator and holders in
   the ratio the creator chose. A buy's tax goes to those who held *before* it.
3. **Graduation.** When the curve sells out, the remaining 206.9M coins and all
   quote raised open a volatile pair on PRJX (Uniswap V2 fork) or **Ramses**. The
   LP tokens are sent to `0x…dEaD`.
4. **After graduation.** Buys and sells against the pair are taxed in coins. The
   coin sells its accrued tax back into the pair — at most 0.5% of the pool per
   sale, once per block, and only while the pool trades near its own time-weighted
   average — burns the burn share, and pays the proceeds out through the
   distributor. A keeper (the dividend bot) calls the public `liquidate()` and
   `distribute()` so holders are paid without anyone having to trade.

## Contracts

| Contract | Lines | Role |
|---|---|---|
| `src/tax/PerpMeTaxToken.sol` | 1,519 | The coin: ERC-20 with pool-transfer tax, tax liquidation, dividend share tracking |
| `src/tax/PerpMeDividendDistributor.sol` | 795 | Per-holder accounting, automatic payout, `claim` / `claimFor` / `distribute` |
| `src/tax/PerpMeCurve.sol` | 683 | Constant-product bonding curve priced in the pair token; graduation |
| `src/tax/PerpMeTaxFactory.sol` | 596 | Launch configs (pair token × exchange), exchanges, launches |
| `src/tax/PerpMeBridge.sol` | 375 | HYPE ↔ pair token: PRJX V3 paths, or a Solidly pair traded directly |
| `src/tax/PerpMeMarketRouter.sol` | 246 | Buy / sell a graduated coin with HYPE or its pair token |
| `src/tax/PerpMeCurveRouter.sol` | 206 | Buy / sell a coin on its curve with HYPE |
| `src/tax/PerpMeTaxTokenDeployer.sol` | 56 | Carries the coin's creation code (EIP-170) |
| `src/tax/venue/IPerpMeVenue.sol` | 112 | What a coin needs from an exchange |
| `src/tax/venue/PerpMeRamsesVenue.sol` | 282 | **Ramses** (and Nest — same Solidly interface) |
| `src/tax/venue/PerpMeUniV2Venue.sol` | 217 | PRJX V2 |

## How we use Ramses

Everything Ramses-specific is in `PerpMeRamsesVenue.sol`; the coin only talks to
the `IPerpMeVenue` interface.

| Ramses call | Where | Why |
|---|---|---|
| `factory.getPair(a, b, false)` / `createPair(a, b, false)` | `openPair` | The pair is created at launch (reserved) and filled at graduation. Always volatile. |
| `pair.getAmountOut(amountIn, tokenIn)` | `amountOut` | The coin sells its tax by transferring to the pair and calling `swap` with this output — the pair's own fee, never a hard-coded one. |
| `pair.getReserves()`, `token0()` | `amountOutUnsynced` | What a router has sent the pair but the pair has not yet counted. |
| `pair.observationLength()`, `pair.quote(tokenIn, amountIn, granularity)` | `priceIsSane` | A tax sale is refused unless the pool's spot output is at least 20% of its time-weighted average (up to 4 observations). |
| `pair.fees()`, `pair.communityVault()` | `feeSinks` | Where a Velodrome-style pair sends its fee; those addresses are excluded from dividends and tax. Absent on Ramses legacy pairs (fee stays in reserves). |
| `pair.swap(…)` | `PerpMeBridge`, `PerpMeMarketRouter` | Direct trades — RAM/WHYPE for the HYPE bridge, and graduated coins. |
| `pair.sync()` | dividend bot (off-chain) | Ramses writes an observation only on a reserve update ≥ 30 minutes after the last one. With nobody trading, a freshly graduated coin has one observation and cannot sell its tax; the bot calls the public `sync()` to write the second one. |

Addresses (HyperEVM, chain 999):

- Ramses legacy factory `0xd0a07E160511c40ccD5340e94660E9C9c01b0D27`
- RAM/WHYPE pair used as the HYPE bridge `0xa33601b7811dC089CAfEB7C7B97fC4c8271899b2`

The pair-level tests are `test/RamsesVenue.t.sol` and `test/TaxOnRamses.t.sol`;
every shipped pair token is also launched and graduated on Ramses in
`test/TaxAllPairs.t.sol` and `test/TaxRoutingAllPairs.t.sol`.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/) (tested with 1.8.1). Dependencies
(forge-std 1.16.2, OpenZeppelin Contracts 5.5) are vendored in `lib/`.

```bash
forge build
```

Almost every suite forks HyperEVM mainnet. The public RPC rate-limits parallel
forks, so run through a local fork:

```bash
anvil --fork-url https://rpc.hyperliquid.xyz/evm --port 8555 --retries 10 --timeout 120000
HYPEREVM_RPC_URL=http://127.0.0.1:8555 forge test -j 2
```

The public RPC is not an archive node — forks run at the head block
(`test/ForkPin.sol` explains why).

The coin is compiled with `optimizer_runs = 200` (see `foundry.toml`) so the
deployer stays under EIP-170; everything else uses 1,000,000 runs and `via_ir`.

## Deployment

```bash
forge script script/DeployTax.s.sol --force --rpc-url hyperevm --private-key $KEY --broadcast
TAX_FACTORY_ADDRESS=0x… SEED_DEX_COUNT=2 forge script script/AddTaxConfigs.s.sol \
  --rpc-url hyperevm --private-key $KEY --broadcast
```

`script/tax-seed-prices.py` prices every launch config on the day of deployment.

## Owner powers

The factory has a single owner (two-step transfer; `renounceOwnership` is disabled).

For **future** launches only: add exchanges and launch configs, enable or disable
them, pause launches, set the launch fee, the protocol's share of tax and the curve
router. A coin copies these at launch; changing them does not touch coins already
launched.

For **live** coins:

- `lowerTax` — lower a coin's buy/sell tax, never below 1% and never up;
- `setExcluded` — stop an address earning *new* dividends (what it already earned stays claimable);
- `reclaim` — return the dividends of an address that has held nothing for 10 days to the remaining holders;
- `rescueTax` — take a coin's accrued tax out, only after 3 days in which selling it has failed;
- `rescue` — recover a token sent to a distributor by mistake (never the reward token);
- `setCreatorRecipient` — redirect a coin's creator share (also callable by the current recipient).

There is no upgradeability, no pause of trading, no transfer blocklist, and no path
that sends holders' dividends to the owner.

## License

MIT
