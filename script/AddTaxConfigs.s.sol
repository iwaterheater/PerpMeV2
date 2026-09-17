// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PerpMeTaxFactory} from "../src/tax/PerpMeTaxFactory.sol";

/**
 * @title One launch config per pair token, for dividend coins.
 *
 * @notice The whole pitch of a dividend coin is the asset it pays in, so the
 *         creator has to be able to pick it. That means one config per share.
 *
 * @dev Every config opens the coin at roughly the same VALUATION — about three
 *      thousand dollars, matching a V3 launch — which means each needs its own
 *      virtual quote reserve, because a share of NVIDIA and a share of SPY are
 *      not worth the same. The numbers below are 3000 * 1.073 / price in each
 *      token's own units, priced on 2026-09-10 through PRJX's QuoterV2
 *      (token → WHYPE → USDC). They used to be priced "against USDG on the day
 *      they were written" — a token that does not exist on this chain, on the
 *      day the stack was forked; HYPE alone had moved 14% since.
 *
 *      They are a snapshot, and deliberately so: a config is a fixed opening
 *      price, not a feed. If a share doubles, coins quoted in it start twice as
 *      high until an owner updates the config — which never touches a coin that
 *      has already launched.
 *
 *      Run:
 *        forge script script/AddTaxConfigs.s.sol --rpc-url hyperevm \
 *          --private-key $DEPLOYER_PRIVATE_KEY --broadcast
 */
contract AddTaxConfigs is Script {
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 constant VIRTUAL_TOKEN = 1_073_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;
    uint16 constant CURVE_FEE_BPS = 150;
    uint16 constant MAX_WALLET_BPS = 200;
    uint32 constant RESTRICTION_BLOCKS = 300;

    PerpMeTaxFactory factory;

    struct PairSeed {
        address token;
        uint256 virtualQuote;
        string sym;
    }

    /// @dev The shipped pair table, exposed as data so the all-pairs fork test
    ///      can read the real thing instead of carrying a copy that would rot.
    function _seeds() internal pure returns (PairSeed[] memory s) {
        /*
         * Eight pairs: the ones the site offers, and only those.
         *
         * There used to be twenty, including twelve tokenised shares — wTSLAx,
         * wAAPLx, wMSTRx and the rest — carried over from the plan this stack
         * was forked with. They are real contracts on HyperEVM and every one
         * of them answers its symbol, and every one of them has a total supply
         * of ZERO (wCRCLx: one token). Nobody has wrapped anything. A config
         * for such a token is a coin nobody can buy: no supply in circulation,
         * no pool, no bridge from HYPE. The fork tests passed on them only
         * because `deal` conjures balances. They come back one at a time, as
         * a pool is opened for each — the way NVDA, SpaceX and SPY did.
         */
        s = new PairSeed[](16);
        s[0] = PairSeed(0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5, 14.4657e18, "wNVDAx");
        s[1] = PairSeed(0x8e2eeD8b8B5E13Ea7BF38e50d7821d2C57309072, 23.9080e18, "wSPCXx");
        s[2] = PairSeed(0xE7E553Cd128F0011777323A0b44a7b96EA1CB540, 4.2278e18, "wSPYx");
        /* Six decimals: USDC, USD₮0, UPUMP. Their numbers are small in wei
           terms. UPUMP was seeded at $0.0002 — sixteen million tokens — when it
           traded near $0.0036: its curve opened eighteen times dearer than every
           other pair's and filled at ~$172k instead of ~$9.7k. Caught on devtest
           2026-09-13; now 3,219 / 0.003604 at that day's PRJX quote. */
        s[3] = PairSeed(0xb88339CB7199b77E23DB6E890353E22632Ba630f, 3_219_000_000, "USDC");
        s[4] = PairSeed(0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb, 3_219_000_000, "USDT0");
        s[5] = PairSeed(0x9b498C3c8A0b8CD8BA1D9851d40D186F1872b44E, 28_386e18, "PURR");
        s[6] = PairSeed(0x27eC642013bcB3D80CA3706599D3cdA04F6f4452, 893_200e6, "UPUMP");
        /* The chain's own coin, at $83.83. The old figure implied $97. */
        s[7] = PairSeed(0x5555555555555555555555555555555555555555, 38.40e18, "WHYPE");
        /*
         * Six more, 2026-09-10, at the same 3000 * 1.073 / price. Decimals
         * are each token's own: USOL nine, UBTC eight, the rest eighteen —
         * so the UBTC figure is 0.0415 coins and the USOL one 31.8.
         *
         * RAM and NEST have no pool against WHYPE on PRJX. They are reached
         * instead through their own Solidly pairs — RAM's on Ramses, NEST's on
         * Nest — which the routers' bridge understands as a twenty-byte pair
         * address rather than a V3 path, so HYPE buys a coin quoted in either
         * exactly as it buys the rest.
         */
        s[8] = PairSeed(0x000000000000780555bD0BCA3791f89f9542c2d6, 15_498e18, "KNTQ");
        s[9] = PairSeed(0x068f321Fa8Fb9f0D135f290Ef6a3e2813e1c8A29, 32.4285e9, "USOL"); // $99.264, 2026-09-15
        s[10] = PairSeed(0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463, 4_150_000, "UBTC");
        s[11] = PairSeed(0xBe6727B535545C67d5cAa73dEa54865B92CF7907, 1.3061e18, "UETH");
        s[12] = PairSeed(0x555570a286F15EbDFE42B66eDE2f724Aa1AB5555, 67_867e18, "RAM"); // $0.047431, 2026-09-15
        s[13] = PairSeed(0x07c57E32a3C29D5659bda1d3EFC2E7BF004E3035, 319_029e18, "NEST");
        /*
         * Two more, 2026-09-11, at the same 3000 * 1.073 / price.
         *
         * kHYPE is Kinetiq's staked HYPE at $84.835 — reached through the
         * 0.01% pool against WHYPE, ~21,900 HYPE deep, the best bridge on this
         * list. JOFF is $0.015634 with EIGHT decimals, and is the first seed
         * whose bridge is two hops: its WHYPE pools hold half a HYPE between
         * them, so HYPE reaches it through USDC instead.
         */
        s[14] = PairSeed(0xfD739d4e423301CE9385c1fb8850539D657C296D, 37.9441e18, "kHYPE");
        s[15] = PairSeed(0x62D5dD0190376c444a4B2E2e860aa392eC83Ed80, 205_894e8, "JOFF");
    }

    /**
     * @dev The exchanges every pair is offered on.
     *
     *      One config is one (pair token, exchange), and a creator picks both
     *      — so a pair that exists on PRJX and not on Ramses is a pair whose
     *      quote list goes short the moment somebody chooses Ramses. It did:
     *      Ramses offered NVDA alone, because these seeds were written when it
     *      was one worked example rather than a choice on the form.
     *
     *      An exchange that cannot open a pair must not be seeded. Our factory
     *      opens the pair DURING `launchToken`, so a config pointing at a venue
     *      that will be refused does not sit dormant — it makes every launch
     *      quoted that way revert. Nest is in exactly that state today: its
     *      AMM factory answers `createPair` only to PAIRS_CREATOR_ROLE. Nest
     *      have said permissionless creation ships in their 2.0 update, early
     *      October 2026.
     *
     *      Which exchanges are ready is an operator's judgement rather than
     *      something to infer. It cannot be probed honestly from here: opening
     *      a pair writes, so a `staticcall` probe reverts whether the venue
     *      would be refused or would have succeeded, and the two are
     *      indistinguishable. Rather than guess, the count is a number:
     *
     *        SEED_DEX_COUNT=2   PRJX and Ramses          (the default, today)
     *        SEED_DEX_COUNT=3   …and Nest, once 2.0 is live
     *
     *      So October is a re-run with one variable set, not a code change.
     */
    function _dexIds() internal view returns (uint8[] memory ids) {
        uint256 known = factory.dexConfigCount();
        uint256 want = vm.envOr("SEED_DEX_COUNT", uint256(2));
        if (want > known) want = known;
        ids = new uint8[](want);
        for (uint256 i; i < want; i++) ids[i] = uint8(i);
    }

    function run() external {
        factory = PerpMeTaxFactory(vm.envAddress("TAX_FACTORY_ADDRESS"));
        PairSeed[] memory s = _seeds();
        uint8[] memory dexes = _dexIds();
        vm.startBroadcast();
        console2.log("seeding exchanges 0..", dexes.length - 1);
        for (uint256 d = 0; d < dexes.length; d++) {
            for (uint256 i = 0; i < s.length; i++) {
                _add(s[i].token, s[i].virtualQuote, s[i].sym, dexes[d]);
            }
        }
        vm.stopBroadcast();
        console2.log("configs on factory:", factory.launchConfigCount());
    }

    function _add(address pairToken, uint256 virtualQuote, string memory sym, uint8 dexId)
        internal
    {
        // The deployment script already opens wNVDAx on both exchanges, and
        // this script is re-run whenever a pair is added. Matched on the
        // exchange as well as the token, because the same token on Ramses is a
        // different config rather than a duplicate of the PRJX one.
        for (uint256 i = 0; i < factory.launchConfigCount(); i++) {
            PerpMeTaxFactory.LaunchConfig memory c = factory.getLaunchConfig(i);
            if (c.pairToken == pairToken && c.dexId == dexId) {
                console2.log("skip (already configured):", sym, dexId);
                return;
            }
        }
        uint256 id = factory.addLaunchConfig(
            PerpMeTaxFactory.LaunchConfig({
                dexId: dexId,
                pairToken: pairToken,
                totalSupply: TOTAL_SUPPLY,
                enabled: true,
                virtualToken: VIRTUAL_TOKEN,
                virtualQuote: virtualQuote,
                curveTokens: CURVE_TOKENS,
                curveFeeBps: CURVE_FEE_BPS
            })
        );
        console2.log(sym, "-> config", id);
    }
}
