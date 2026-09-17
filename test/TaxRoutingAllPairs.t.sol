// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForkPin} from "./ForkPin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpMeTaxFactory} from "../src/tax/PerpMeTaxFactory.sol";
import {PerpMeTaxTokenDeployer} from "../src/tax/PerpMeTaxTokenDeployer.sol";
import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeCurve} from "../src/tax/PerpMeCurve.sol";
import {PerpMeCurveRouter} from "../src/tax/PerpMeCurveRouter.sol";
import {PerpMeMarketRouter} from "../src/tax/PerpMeMarketRouter.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";
import {AddTaxConfigs} from "../script/AddTaxConfigs.s.sol";

interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Ramses' and Nest's factories, for the pairs that live only there.
interface ISolidlyFactoryLike {
    function getPair(address tokenA, address tokenB, bool stable) external view returns (address);
}

contract TaxRoutingSeedExposer is AddTaxConfigs {
    function seeds() external pure returns (PairSeed[] memory) {
        return _seeds();
    }
}

/**
 * Can somebody holding HYPE actually TRADE a dividend coin — on every pair we
 * ship, not just the one we hand-tested?
 *
 * TaxCoinRouting proves the whole journey works against wNVDAx, and the live
 * launch on HyperEVM proved it against USD₮0. Both are single points. The
 * fifteen stock wrappers are reached by a DIFFERENT and longer route — three
 * V3 pools instead of one — over third-party liquidity that nothing in this
 * repository controls, and "wNVDAx works" says nothing about whether wTSLAx or
 * wSPCXx has a pool at the fee tier the front end assumes. A route that is
 * wrong for one wrapper is a buy button that reverts for that coin and only
 * that coin.
 *
 * So this walks the shipped seed table and, for each pair, does exactly what
 * the widget does:
 *
 *   - CURVE STAGE, via PerpMeCurveRouter.buyWithNative / sellToNative with the
 *     bridge path the front end encodes — see web/lib/routes.ts.
 *   - GRADUATED, via SwapRouter02.multicall: the V3 bridge and the V2 pair in
 *     one transaction, joined by the CONTRACT_BALANCE sentinel — see
 *     web/components/token/GraduatedV2Form.tsx.
 *
 * The paths below are the same bytes those two files build. If the table in
 * routes.ts is wrong for a wrapper, this fails on that wrapper by name.
 */
contract TaxRoutingAllPairsTest is Test {
    /* PRJX, verified on chain 999. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    /// @dev The CLASSIC SwapRouter — `exactInput` carries a deadline and there
    ///      is no V2 leg on it at all. See TaxCoinRouting, which proves the
    ///      absence by selector.
    address constant SWAP_ROUTER = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    address constant V3_FACTORY = 0xFf7B3e8C00e57ea31477c32A5B52a58Eea47b072;

    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    /// @dev Where RAM's and NEST's liquidity actually is. A pair on either is a
    ///      bridge of its own kind: 20 bytes, the pair's address, and the
    ///      routers trade it directly.
    address constant RAMSES_FACTORY = 0xd0a07E160511c40ccD5340e94660E9C9c01b0D27;
    address constant NEST_FACTORY = 0x889Fd0aDA8453C7619cD7f11E9029a1f0848Fdf5;

    /// @dev PRJX's four tiers. The bridge is looked for across all of them
    ///      rather than assumed, because which one a wrapper's pool lives in is
    ///      whoever opened it's decision, not ours.
    uint24 constant FEE_LOWEST = 100;
    uint24 constant FEE_LOW = 500;
    uint24 constant FEE_MEDIUM = 3000;
    uint24 constant FEE_HIGH = 10000;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;

    PerpMeTaxFactory factory;
    PerpMeTaxTokenDeployer deployer;
    PerpMeCurveRouter curveRouter;
    PerpMeMarketRouter market;

    AddTaxConfigs.PairSeed[] internal seeds;

    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);

    PerpMeUniV2Venue venue;

    function setUp() public {
        ForkPin.select();

        venue = new PerpMeUniV2Venue(V2_FACTORY, 30);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        deployer = new PerpMeTaxTokenDeployer(predicted);
        factory = new PerpMeTaxFactory(address(deployer), treasury, 0, 2000);
        curveRouter = new PerpMeCurveRouter(SWAP_ROUTER, WHYPE);
        market = new PerpMeMarketRouter(SWAP_ROUTER, WHYPE);
        factory.setCurveRouter(address(curveRouter));
        factory.addDexConfig(venue, "prjx-v2");

        AddTaxConfigs.PairSeed[] memory s = new TaxRoutingSeedExposer().seeds();
        for (uint256 i; i < s.length; ++i) {
            seeds.push(s[i]);
        }

        for (uint256 i; i < seeds.length; ++i) {
            factory.addLaunchConfig(
                PerpMeTaxFactory.LaunchConfig({
                    dexId: 0,
                    pairToken: seeds[i].token,
                    totalSupply: SUPPLY,
                    enabled: true,
                    virtualToken: 1_073_000_000e18,
                    virtualQuote: seeds[i].virtualQuote,
                    curveTokens: CURVE_TOKENS,
                    curveFeeBps: 150
                })
            );
        }
    }

    // -------------------------------------------------------------------------
    //  The bridge, found on chain rather than written down.
    // -------------------------------------------------------------------------

    /**
     * @dev The tier `web/lib/routes.ts` should be pointing HYPE through for
     *      this pair token: the WHYPE pool holding the most WHYPE, or 0 if the
     *      wrapper has none at any tier.
     *
     *      Discovered instead of tabulated on purpose. The table this suite
     *      used to carry named two bridge tokens that do not exist on this
     *      chain, and it read as authoritative for a year because nothing ever
     *      compared it to a pool. A route that is looked up cannot rot; one
     *      that is copied always does.
     */
    /// @dev A pool holding less than this much WHYPE is not a bridge, it is a
    ///      dust position: RAM's 1% pool on PRJX holds 0.18 WHYPE while its real
    ///      liquidity sits on Ramses, and a 1-HYPE buy through it reverts. The
    ///      site draws the same line by leaving such pairs out of its route table.
    uint256 constant MIN_BRIDGE_WHYPE = 10 ether;

    function _bridgeFee(address quote) internal view returns (uint24 best) {
        if (quote == WHYPE) return 0;
        uint24[4] memory tiers = [FEE_LOWEST, FEE_LOW, FEE_MEDIUM, FEE_HIGH];
        uint256 deepest = MIN_BRIDGE_WHYPE;
        for (uint256 t; t < tiers.length; ++t) {
            address pool = IV3Factory(V3_FACTORY).getPool(WHYPE, quote, tiers[t]);
            if (pool == address(0)) continue;
            uint256 held = IERC20Like(WHYPE).balanceOf(pool);
            if (held >= deepest) {
                deepest = held;
                best = tiers[t];
            }
        }
    }

    /// @dev A volatile WHYPE pair on Ramses or on Nest, for a quote with no
    ///      real pool on PRJX — the same lookup `web/lib/routes.ts` writes down.
    function _solidlyPair(address quote) internal view returns (address) {
        address p = ISolidlyFactoryLike(RAMSES_FACTORY).getPair(WHYPE, quote, false);
        if (p != address(0) && IERC20Like(WHYPE).balanceOf(p) >= MIN_BRIDGE_WHYPE) return p;
        p = ISolidlyFactoryLike(NEST_FACTORY).getPair(WHYPE, quote, false);
        if (p != address(0) && IERC20Like(WHYPE).balanceOf(p) >= MIN_BRIDGE_WHYPE) return p;
        return address(0);
    }

    /// @dev True when HYPE reaches `quote` at all, by either kind of bridge.
    function _bridged(address quote) internal view returns (bool) {
        return quote == WHYPE || _bridgeFee(quote) != 0 || _solidlyPair(quote) != address(0);
    }

    function _bridgeIn(address quote) internal view returns (bytes memory) {
        uint24 fee = _bridgeFee(quote);
        if (fee != 0) return abi.encodePacked(WHYPE, fee, quote);
        address p = _solidlyPair(quote);
        if (p != address(0)) return abi.encodePacked(p);
        return bytes("");
    }

    function _bridgeOut(address quote) internal view returns (bytes memory) {
        uint24 fee = _bridgeFee(quote);
        if (fee != 0) return abi.encodePacked(quote, fee, WHYPE);
        address p = _solidlyPair(quote);
        if (p != address(0)) return abi.encodePacked(p);
        return bytes("");
    }

    // -------------------------------------------------------------------------

    function _launch(uint256 i) internal returns (address token, address curve) {
        vm.prank(creator);
        (token, curve) = factory.launchToken(
            PerpMeTaxFactory.LaunchParams({
                name: string.concat("Dividend ", seeds[i].sym),
                symbol: seeds[i].sym,
                metadataURI: "ipfs://cat",
                metadataB64: "",
                buyTaxBps: 300,
                sellTaxBps: 300,
                dividendBps: 8000,
                creatorBps: 1500,
                burnBps: 500,
                minDividendBalance: 1_000e18,
                swapThreshold: 100_000e18
            }),
            i,
            bytes32(uint256(i + 1)),
            0,
            0
        );
    }

    /// Buy the curve out in the quote token, so the coin graduates into a pool.
    function _graduate(uint256 i, address curve) internal {
        uint256 gross = seeds[i].virtualQuote * 7 / 2;
        deal(seeds[i].token, trader, gross);
        vm.startPrank(trader);
        IERC20(seeds[i].token).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(gross, 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------

    /**
     * CURVE STAGE. Somebody with HYPE and no wTSLAx buys, then sells back out,
     * through the router the coin registered at launch.
     *
     * The native pair is skipped rather than fudged: the front end offers no
     * HYPE route there because the coin is already quoted in the wrapped native
     * token, and a test that invented one would be testing something nobody
     * ships.
     */
    function test_everyPair_curveStageBuyAndSellWithNative() public {
        for (uint256 i; i < seeds.length; ++i) {
            address quote = seeds[i].token;
            if (quote == WHYPE) continue;
            /* No WHYPE pool at any tier means the front end offers no HYPE
               option for this wrapper either. Named by `test_everyShippedPair…`
               below rather than quietly passed over here. */
            if (!_bridged(quote)) continue;
            string memory sym = seeds[i].sym;

            (address token, address curve) = _launch(i);

            vm.deal(trader, 3 ether);
            vm.startPrank(trader);
            uint256 got = curveRouter.buyWithNative{value: 1 ether}(
                PerpMeCurve(curve), _bridgeIn(quote), 0, 0
            );
            assertGt(got, 0, string.concat(sym, ": HYPE bought coins on the curve"));
            assertEq(
                IERC20(token).balanceOf(trader),
                got,
                string.concat(sym, ": and they landed on the buyer, not the router")
            );

            // And back out again, which is the leg that has to hold the coin.
            uint256 nativeBefore = trader.balance;
            IERC20(token).approve(address(curveRouter), type(uint256).max);
            uint256 back = curveRouter.sellToNative(
                PerpMeCurve(curve), got / 2, _bridgeOut(quote), 0
            );
            vm.stopPrank();

            assertGt(back, 0, string.concat(sym, ": and sold back out to HYPE"));
            assertEq(
                trader.balance - nativeBefore, back, string.concat(sym, ": the HYPE arrived")
            );
            assertEq(
                IERC20(token).balanceOf(address(curveRouter)),
                0,
                string.concat(sym, ": the router kept no coins")
            );
        }
    }

    /**
     * GRADUATED. The same buyer, the same HYPE, against a real V2 pool.
     *
     * Through `PerpMeMarketRouter`, because nothing else on this chain can do
     * it: the bridge is a V3 pool, the coin is in a V2 pair, and PRJX's router
     * is the classic SwapRouter with no V2 leg. This used to be written as one
     * SwapRouter02 multicall, which was a router that is not deployed here
     * calling a function it does not have.
     */
    function test_everyPair_graduatedBuyAndSellWithNative() public {
        for (uint256 i; i < seeds.length; ++i) {
            address quote = seeds[i].token;
            if (quote == WHYPE) continue;
            if (!_bridged(quote)) continue;
            string memory sym = seeds[i].sym;

            (address token, address curve) = _launch(i);
            _graduate(i, curve);
            assertTrue(PerpMeCurve(curve).graduated(), string.concat(sym, ": graduated"));

            /* Built BEFORE the prank, never inside the call. Working the
               bridge out reads the V3 factory, and that staticcall spends the
               prank — so the buyer would have been this test contract and the
               trader's balance would not have moved. */
            bytes memory bridgeIn = _bridgeIn(quote);
            bytes memory bridgeOut = _bridgeOut(quote);

            vm.deal(trader, 3 ether);
            uint256 before = IERC20(token).balanceOf(trader);
            uint256 taxBefore = IERC20(token).balanceOf(token);

            vm.prank(trader);
            uint256 bought = market.buyWithNative{value: 1 ether}(
                PerpMeTaxToken(payable(token)), bridgeIn, 0
            );

            assertGt(bought, 0, string.concat(sym, ": HYPE reached the pool in one tx"));
            assertEq(
                IERC20(token).balanceOf(trader) - before,
                bought,
                string.concat(sym, ": and the buyer is the one holding it")
            );
            assertGt(
                IERC20(token).balanceOf(token) - taxBefore,
                0,
                string.concat(sym, ": and the coin took its cut on the way in")
            );

            uint256 nativeBefore = trader.balance;
            vm.startPrank(trader);
            IERC20(token).approve(address(market), type(uint256).max);
            uint256 back = market.sellToNative(
                PerpMeTaxToken(payable(token)), bought / 2, bridgeOut, 0
            );
            vm.stopPrank();

            assertGt(back, 0, string.concat(sym, ": the seller got HYPE back"));
            assertEq(
                trader.balance - nativeBefore,
                back,
                string.concat(sym, ": into their own balance")
            );
            assertEq(
                IERC20(token).balanceOf(address(market)),
                0,
                string.concat(sym, ": the router kept no coins")
            );
        }
    }

    /**
     * The sized buy through a Solidly bridge: a thousand HYPE at a RAM-quoted
     * curve fills it and comes back as HYPE, not as a pile of RAM. There is
     * no `exactOutput` on a Solidly pair, so the router finds the amount by
     * asking the pair — this is the bisection, on the real Ramses pool.
     */
    function test_overpayingThroughASolidlyBridgeFillsAndRefunds() public {
        uint256 i = seeds.length;
        for (uint256 j; j < seeds.length; ++j) {
            if (keccak256(bytes(seeds[j].sym)) == keccak256("RAM")) i = j;
        }
        assertLt(i, seeds.length, "the seed table carries RAM");
        address quote = seeds[i].token;
        bytes memory bridgeIn = _bridgeIn(quote);
        assertEq(bridgeIn.length, 20, "RAM bridges through a Solidly pair");

        (address token, address curve) = _launch(i);
        uint256 needed = PerpMeCurve(curve).quoteToFill();
        assertGt(needed, 0, "a curve to fill");
        uint256 minHype = curveRouter.quoteBridgeIn(bridgeIn, WHYPE, needed, 1_000 ether);
        assertGt(minHype, 0, "the bridge can quote the fill");
        assertLt(minHype, 1_000 ether, "and it costs less than what will be sent");

        vm.deal(trader, 2_000 ether);
        uint256 before = trader.balance;
        vm.prank(trader);
        curveRouter.buyWithNative{value: 1_000 ether}(PerpMeCurve(curve), bridgeIn, 0, 0);

        assertTrue(PerpMeCurve(curve).graduated(), "the curve was bought out");
        uint256 spent = before - trader.balance;
        assertLt(spent, minHype + minHype / 100, "spent what the fill costs, not the thousand");
        // What the trader holds in RAM afterwards is the DIVIDEND the curve paid
        // its one holder out of that buy's own tax — under three percent of the
        // fill, in the quote token — not change from an over-bought bridge,
        // which used to arrive by the tens of thousands.
        assertLt(IERC20(quote).balanceOf(trader), needed * 3 / 100, "no pile of RAM came back as change");
        assertEq(IERC20(token).balanceOf(address(curveRouter)), 0, "the router kept nothing");
    }

    /**
     * Every pair token we ship is a token, and we know which ones HYPE can
     * reach.
     *
     * The first half is not a formality: the seed table carried an address for
     * USDC with no code on this chain, inherited from the fork and never
     * repointed, and a launch config against it would have opened a pair
     * against nothing.
     *
     * The second half is a ledger rather than a demand. A wrapper with no
     * WHYPE pool anywhere is one the front end must not offer a HYPE option
     * for — it is not broken, it is unbridged, and the number moves when
     * somebody opens a pool. If this fails, `web/lib/routes.ts` and this list
     * have drifted apart and one of them is lying to a buyer.
     */
    function test_everyShippedPairTokenIsRealAndSaysWhetherHypeReachesIt() public {
        uint256 bridged;
        for (uint256 i; i < seeds.length; ++i) {
            assertGt(
                seeds[i].token.code.length,
                0,
                string.concat(seeds[i].sym, ": the shipped address is a contract")
            );
            if (_bridged(seeds[i].token)) {
                ++bridged;
            } else {
                emit log_named_string("no HYPE bridge", seeds[i].sym);
            }
        }
        emit log_named_uint("pair tokens HYPE can reach", bridged);
        assertGt(bridged, 0, "at least one pair token is reachable with HYPE");
    }

    /**
     * The native pair, which has no bridge and needs none: HYPE straight into
     * the pool and straight back out, through the same router with an empty
     * path.
     */
    function test_nativePair_tradesWithoutABridge() public {
        uint256 i = seeds.length;
        for (uint256 j; j < seeds.length; ++j) {
            if (seeds[j].token == WHYPE) i = j;
        }
        assertLt(i, seeds.length, "the seed table still carries WHYPE");

        (address token, address curve) = _launch(i);
        _graduate(i, curve);

        vm.deal(trader, 10 ether);
        vm.prank(trader);
        uint256 bought =
            market.buyWithNative{value: 1 ether}(PerpMeTaxToken(payable(token)), bytes(""), 0);
        assertGt(bought, 0, "HYPE bought the coin with no bridge at all");

        uint256 nativeBefore = trader.balance;
        vm.startPrank(trader);
        IERC20(token).approve(address(market), type(uint256).max);
        uint256 back =
            market.sellToNative(PerpMeTaxToken(payable(token)), bought / 2, bytes(""), 0);
        vm.stopPrank();

        assertGt(back, 0, "and sold back to HYPE");
        assertEq(trader.balance - nativeBefore, back, "into the seller's own balance");
    }
}
