// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpMeCurve} from "../src/tax/PerpMeCurve.sol";
import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeDividendDistributor} from "../src/tax/PerpMeDividendDistributor.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

/**
 * Stands in for PerpMeCurveRouter: buys on somebody's behalf.
 *
 * The real one bridges HYPE first, which is not what is being tested here — what
 * matters is that a purchase routed through a contract still pays the holders'
 * dividend to the BUYER rather than losing it. It did not, on the first live
 * trade, and no test looked.
 */
contract BuyingRouter {
    function buyFor(PerpMeCurve curve, IERC20 quote, uint256 amount, address buyer)
        external
        returns (uint256)
    {
        quote.transferFrom(msg.sender, address(this), amount);
        quote.approve(address(curve), amount);
        return curve.buyFor(amount, 0, buyer);
    }
}

interface ICurveAsPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IV2FactoryLike {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

interface IV2RouterLike {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/**
 * The bonding curve, from first buy to graduation, against real Uniswap V2 on a
 * fork of HyperEVM and a real tokenized share as the quote asset.
 *
 * The parameters mirror the ones the launchpad intends to ship: an opening
 * valuation near three thousand dollars — the same as a V3 launch — 79% of the
 * supply sold on the curve, and the rest paired with everything raised.
 */
contract PerpMeCurveTest is Test {
    /* PRJX's V2, verified on chain 999.

       These used to be read from the environment with no default, which meant
       every one of these suites skipped itself on every run — the check reads
       `code.length` before the fork is selected, where nothing has code at all.
       They were green for a year without executing. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
    address constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;
    uint256 constant MIGRATION_TOKENS = SUPPLY - CURVE_TOKENS;
    uint256 constant VIRTUAL_TOKEN = 1_073_000_000e18;
    /// ~$3,000 opening valuation at roughly $219 a share.
    uint256 constant VIRTUAL_QUOTE = 14.71e18;
    uint16 constant TRADE_FEE_BPS = 150; // 1.5%, matching the field

    PerpMeTaxToken coin;
    PerpMeCurve curve;
    PerpMeDividendDistributor dist;
    BuyingRouter router;

    /// The curve reports its graduation to whoever created it, which here is
    /// this contract standing in for the factory. Recorded rather than ignored,
    /// so the test can assert the report actually happened.
    address public graduatedToken;
    address public graduatedPair;

    function onGraduated(address token, address pair, uint256, uint256) external {
        graduatedToken = token;
        graduatedPair = pair;
    }

    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    /// This contract stands in for the factory, so this is who may lower the tax.
    address admin = address(0xAD);

    function owner() external view returns (address) {
        return admin;
    }

    PerpMeUniV2Venue venue;

    function setUp() public {
        /* No V2 venue configured for HyperEVM yet — see the note above. */
        vm.createSelectFork("https://rpc.hyperliquid.xyz/evm");

        // This contract stands in for the factory.
        venue = new PerpMeUniV2Venue(V2_FACTORY, 30);
        coin = new PerpMeTaxToken();
        coin.initialize(
            PerpMeTaxToken.InitParams({
                name: "Curve Cat",
                symbol: "CCAT",
                metadataURI: "ipfs://cat",
                metadataB64: "",
                creator: creator,
                locker: BURN_SINK,
                pairToken: WNVDAX,
                reservedPair: _openPair(address(coin), WNVDAX),
                protocolTreasury: treasury,
                totalSupply: SUPPLY,
                protocolBps: 2000,
                buyTaxBps: 300,
                sellTaxBps: 300,
                dividendBps: 8000,
                creatorBps: 1500,
                burnBps: 500,
                minDividendBalance: 1_000e18,
                swapThreshold: 100_000e18,
                venue: address(venue)
            })
        );
        dist = coin.distributor();

        curve = new PerpMeCurve(
            address(coin),
            WNVDAX,
            treasury,
            VIRTUAL_TOKEN,
            VIRTUAL_QUOTE,
            CURVE_TOKENS,
            MIGRATION_TOKENS,
            TRADE_FEE_BPS
        );
        // Registered here because a coin accepts its router exactly once, at
        // setCurve. Only test_ABuyThroughTheRouterStillPaysHolders uses it;
        // its presence changes nothing for the others.
        router = new BuyingRouter();
        coin.setCurve(address(curve), address(router));
        coin.transfer(address(curve), SUPPLY);

        deal(WNVDAX, alice, 2_000e18);
        deal(WNVDAX, bob, 2_000e18);
    }


    /// Stands in for what the factory now does at launch: open the empty pair
    /// and hand the coin its real address, instead of predicting one.
    function _openPair(address a, address b) internal returns (address p) {
        p = IV2FactoryLike(V2_FACTORY).getPair(a, b);
        if (p == address(0)) p = IV2FactoryLike(V2_FACTORY).createPair(a, b);
    }

    function _buy(address who, uint256 spend) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(WNVDAX).approve(address(curve), type(uint256).max);
        out = curve.buy(spend, 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------

    /// Nobody puts up a seed. The curve is the market from block one.
    function test_LaunchNeedsNoSeed() public view {
        assertEq(IERC20(WNVDAX).balanceOf(address(curve)), 0, "curve starts with no quote");
        assertEq(coin.balanceOf(address(curve)), SUPPLY, "and the whole supply");
        assertEq(curve.progressBps(), 0, "at zero progress");
    }

    function test_OpeningValuationIsAboutThreeThousandDollars() public view {
        // price = virtualQuote / virtualToken, in wNVDAx per coin.
        uint256 priceX18 = curve.spotPrice();
        uint256 fdvInQuote = (priceX18 * SUPPLY) / 1e18;
        // ~13.7 wNVDAx ≈ $3,000 at roughly $219 a share.
        assertApproxEqRel(fdvInQuote, 13.7e18, 5e16, "opens near $3,000");
    }

    function test_BuyingMovesThePriceAndPaysThePlatform() public {
        // Somebody already holds, so the holders' slice of alice's tax has an
        // owner; the opening buy's would go to the treasury as well.
        _buy(bob, 1e18);
        uint256 before = IERC20(WNVDAX).balanceOf(treasury);
        uint256 p0 = curve.spotPrice();

        uint256 got = _buy(alice, 10e18);

        assertGt(got, 0, "alice received coins");
        assertEq(coin.balanceOf(alice), got, "and holds them");
        assertGt(curve.spotPrice(), p0, "the price moved up");
        // 1.5% curve fee, plus the protocol's 20% of the coin's own 3% tax,
        // which the curve now also charges. Both land on `treasury` because this
        // harness uses one address for the platform and the protocol.
        assertApproxEqRel(
            IERC20(WNVDAX).balanceOf(treasury) - before,
            0.15e18 + 0.06e18,
            1e16,
            "1.5% platform fee plus 20% of the 3% tax"
        );
    }

    /// Selling back is the same curve in reverse — nobody is trapped.
    function test_SellingBackWorks() public {
        uint256 got = _buy(alice, 10e18);
        uint256 before = IERC20(WNVDAX).balanceOf(alice);

        vm.startPrank(alice);
        coin.approve(address(curve), type(uint256).max);
        uint256 back = curve.sell(got, 0);
        vm.stopPrank();

        assertGt(back, 0, "alice got quote back");
        assertEq(IERC20(WNVDAX).balanceOf(alice) - before, back, "it arrived");
        // Two 1.5% fees and the curve's own spread, so a little under what went in.
        assertLt(back, 10e18, "a round trip costs the fee");
        assertGt(back, 9e18, "but not much more than that");
    }

    /**
     * Coins cannot be moved sideways while the curve is the market.
     *
     * This is what stops somebody opening a second, unofficial pool at a price
     * the curve has never heard of and arbitraging the two.
     */
    /**
     * A holder on the curve may send coins to anyone — except the one address
     * the pool is going to occupy.
     *
     * Everything used to be refused, which stopped the attack below by stopping
     * every transfer, holder to holder included. The pair's address is CREATE2
     * and so is known before it exists, so it is the only address that has to
     * be shut: coins parked there before graduation are a claim on the whole
     * migration, and nothing else about a sideways transfer is dangerous.
     */
    function test_OnlyTheFuturePoolIsClosedDuringTheCurve() public {
        uint256 got = _buy(alice, 10e18);

        vm.prank(alice);
        coin.transfer(bob, got / 2);
        assertEq(coin.balanceOf(bob), got / 2, "an ordinary transfer goes through");

        // Read first: `expectRevert` binds to the next CALL, and asking the
        // coin for the address is itself a call.
        address reserved = coin.reservedPair();
        vm.prank(bob);
        vm.expectRevert(PerpMeTaxToken.TransferRestricted.selector);
        coin.transfer(reserved, 1e18);
    }

    /// And the address it reserves is really where Uniswap puts the pair.
    function test_TheReservedAddressIsWhereThePairActuallyLands() public {
        address reserved = coin.reservedPair();
        deal(WNVDAX, alice, 100_000e18);
        _buy(alice, 60e18); // clears the curve, which opens the pool

        assertEq(coin.pair(), reserved, "the pool opened exactly where it was reserved");
        assertEq(
            IV2FactoryLike(V2_FACTORY).getPair(address(coin), WNVDAX),
            reserved,
            "and Uniswap agrees"
        );
    }

    /// Buying out the curve opens the pair, in the same transaction.
    function test_GraduationOpensTheRealPool() public {
        deal(WNVDAX, alice, 100_000e18);
        _buy(alice, 60e18); // more than enough to clear the curve

        assertTrue(curve.graduated(), "graduated");
        address pair = curve.pair();
        assertEq(IV2FactoryLike(V2_FACTORY).getPair(address(coin), WNVDAX), pair, "pair exists");
        assertEq(coin.pair(), pair, "the coin was told");

        assertEq(coin.balanceOf(pair), MIGRATION_TOKENS, "held-back coins went in");
        assertGt(IERC20(WNVDAX).balanceOf(pair), 0, "and everything raised with them");
        assertGt(IERC20(pair).balanceOf(BURN_SINK), 0, "LP burned");
        assertEq(IERC20(WNVDAX).balanceOf(address(curve)), 0, "curve kept nothing");
        assertEq(coin.balanceOf(address(curve)), 0, "not a single coin either");
        assertEq(graduatedToken, address(coin), "graduation was reported");
        assertEq(graduatedPair, pair, "with the pair it opened");
    }

    /// The last buyer pays for what they get, and gets the rest back.
    function test_TheFinalOversizedBuyIsRefunded() public {
        deal(WNVDAX, alice, 100_000e18);
        uint256 before = IERC20(WNVDAX).balanceOf(alice);
        uint256 got = _buy(alice, 500e18); // far more than the curve can fill

        assertEq(got, CURVE_TOKENS, "bought exactly what was left");
        uint256 spent = before - IERC20(WNVDAX).balanceOf(alice);
        assertLt(spent, 500e18, "and was refunded the rest");
        assertGt(spent, 0, "having paid for what it took");
    }

    /// After graduation the coin behaves like any taxed pair-traded coin, and
    /// holders start earning dividends in the share.
    function test_AfterGraduationTradingPaysDividends() public {
        deal(WNVDAX, alice, 100_000e18);
        _buy(alice, 60e18);
        address pair = curve.pair();
        assertTrue(pair != address(0), "graduated");

        // Sideways transfers are open again now.
        vm.prank(alice);
        coin.transfer(bob, 2_000e18);
        assertEq(coin.balanceOf(bob), 2_000e18, "moved freely after graduation");

        address[] memory sell = new address[](2);
        sell[0] = address(coin);
        sell[1] = WNVDAX;

        /*
         * Measured against what the curve had already funded. This asserted
         * only `totalDeposited > 0`, which the curve phase satisfied on its
         * own — alice's clearing buy paid her own holders' slice back to her —
         * so the two sales below were never shown to fund anything. With a
         * buy's tax now going only to earlier holders, that curve deposit is
         * gone and the test had to prove the post-graduation path for real:
         * the first sale starts the price average, the second, past its
         * window, sells the tax.
         */
        uint256 fundedOnCurve = dist.totalDeposited();
        vm.startPrank(alice);
        coin.approve(V2_ROUTER, type(uint256).max);
        IV2RouterLike(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            coin.balanceOf(alice) / 4, 0, sell, alice, block.timestamp
        );
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.roll(vm.getBlockNumber() + 600);
        IV2RouterLike(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            coin.balanceOf(alice) / 4, 0, sell, alice, vm.getBlockTimestamp()
        );
        vm.stopPrank();

        assertGt(dist.totalDeposited(), fundedOnCurve, "dividends were funded after graduation");
        assertGt(IERC20(WNVDAX).balanceOf(treasury), 0, "and we earned from the tax too");
    }

    function test_CannotTradeAfterGraduation() public {
        deal(WNVDAX, alice, 100_000e18);
        _buy(alice, 60e18);

        vm.startPrank(bob);
        IERC20(WNVDAX).approve(address(curve), type(uint256).max);
        vm.expectRevert(PerpMeCurve.AlreadyGraduated.selector);
        curve.buy(1e18, 0);
        vm.stopPrank();
    }

    /**
     * A round trip can never be profitable, at any size.
     *
     * This is the invariant the curve lives or dies by, and the first version
     * of this contract broke it: rounding fell to the trader, so the constant
     * product shrank a hair on every buy and selling straight back returned
     * MORE quote than was paid. Repeat that in a loop and the curve is drained
     * a wei at a time, with no exploit more exotic than buy-then-sell.
     *
     * Fuzzed rather than shown by example, because the failure lives in the
     * remainder and a hand-picked number is exactly what misses it.
     */
    function testFuzz_RoundTripNeverProfits(uint256 spend) public {
        spend = bound(spend, 0.001e18, 40e18);
        deal(WNVDAX, alice, spend);

        uint256 before = IERC20(WNVDAX).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(WNVDAX).approve(address(curve), type(uint256).max);
        uint256 got = curve.buy(spend, 0);
        coin.approve(address(curve), type(uint256).max);
        if (got != 0) curve.sell(got, 0);
        vm.stopPrank();

        assertLe(IERC20(WNVDAX).balanceOf(alice), before, "came out with no more than went in");
    }

    /**
     * The curve always holds at least what it owes.
     *
     * Same invariant from the other side: after any sequence of trades, the
     * quote actually sitting in the contract covers what `quoteRaised` claims,
     * so the last seller out is never the one who discovers a shortfall.
     */
    function testFuzz_CurveIsAlwaysSolvent(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0.01e18, 15e18);
        b = bound(b, 0.01e18, 15e18);
        c = bound(c, 0.01e18, 15e18);
        deal(WNVDAX, alice, 100e18);
        deal(WNVDAX, bob, 100e18);

        _buy(alice, a);
        _buy(bob, b);

        vm.startPrank(alice);
        coin.approve(address(curve), type(uint256).max);
        curve.sell(coin.balanceOf(alice) / 2, 0);
        vm.stopPrank();

        _buy(alice, c);

        if (!curve.graduated()) {
            assertGe(
                IERC20(WNVDAX).balanceOf(address(curve)),
                curve.quoteRaised(),
                "holdings cover the claim"
            );
        }
    }

    // ------------------------------------------------------------------------
    //  Dividends do not wait for the pair.
    // ------------------------------------------------------------------------

    /**
     * A holder is paid out of somebody else's trade while the curve is still
     * the market — no pair, no graduation, no claim button pressed.
     *
     * This is the whole point of charging the coin's tax on the curve. The
     * comparable launchpad on BNB does exactly this, and a buyer at the very
     * start of a launch otherwise earns nothing until graduation, which may
     * never come.
     */
    function test_HoldersArePaidBeforeThePairExists() public {
        // Small next to the ~41.7 wNVDAx that clears this curve entirely.
        _buy(alice, 3e18);
        assertGt(coin.balanceOf(alice), 0, "alice holds coins");

        // Past the distributor's one-hour-per-holder pacing: alice was already
        // paid on her own buy, in this same second.
        vm.warp(block.timestamp + 2 hours);

        uint256 aliceQuote = IERC20(WNVDAX).balanceOf(alice);
        _buy(bob, 3e18);

        assertFalse(curve.graduated(), "still on the curve");
        assertEq(curve.pair(), address(0), "and no pair has ever existed");
        assertGt(
            IERC20(WNVDAX).balanceOf(alice),
            aliceQuote,
            "alice was paid out of bob's trade, on the curve"
        );
    }

    /**
     * The curve's own unsold reserve must earn nothing.
     *
     * flap's Portal holds ~98.5% of a coin's supply while it is on the curve.
     * If that balance counted as a dividend share, holders would receive about
     * one and a half percent of what they were promised. The curve is in the
     * coin's excluded set for exactly this reason; this pins it.
     */
    function test_TheUnsoldReserveEarnsNothing() public {
        _buy(alice, 3e18);
        _buy(bob, 3e18);

        assertGt(coin.balanceOf(address(curve)), 400_000_000e18, "the reserve is enormous");
        assertEq(dist.claimable(address(curve)), 0, "and it earns nothing");
    }

    /**
     * The tax is split on the curve exactly as it will be after graduation:
     * the protocol's share off the top, then creator and holders in the ratio
     * the creator chose. 3% of 100 = 3; 20% protocol = 0.6; of the remaining
     * 2.4, the creator takes 1500/9500.
     */
    function test_CurveTaxSplitsTheSameWayAsAfterGraduation() public {
        _buy(bob, 1e18); // a holder to pay, as in the test above
        uint256 creatorBefore = IERC20(WNVDAX).balanceOf(creator);
        uint256 treasuryBefore = IERC20(WNVDAX).balanceOf(treasury);

        _buy(alice, 10e18);

        uint256 tax = 0.3e18; // 3% of 10
        uint256 toProtocol = (tax * 2000) / 10_000;
        uint256 toCreator = ((tax - toProtocol) * 1500) / 9500;

        assertApproxEqRel(
            IERC20(WNVDAX).balanceOf(creator) - creatorBefore, toCreator, 1e15, "creator slice"
        );
        // 1.5% curve fee on top of the protocol's slice of the tax.
        assertApproxEqRel(
            IERC20(WNVDAX).balanceOf(treasury) - treasuryBefore,
            0.15e18 + toProtocol,
            1e15,
            "platform fee plus protocol slice"
        );
    }

    /// Selling on the curve pays the sell tax, not just the platform fee.
    function test_SellingOnTheCurveIsTaxedToo() public {
        _buy(alice, 3e18);
        uint256 held = coin.balanceOf(alice);

        uint256 creatorBefore = IERC20(WNVDAX).balanceOf(creator);
        vm.startPrank(alice);
        coin.approve(address(curve), type(uint256).max);
        curve.sell(held / 2, 0);
        vm.stopPrank();

        assertGt(
            IERC20(WNVDAX).balanceOf(creator) - creatorBefore, 0, "the sell funded the split"
        );
    }

    /// The curve charges whatever the coin says NOW. A rate lowered mid-curve
    /// shows up on the very next trade rather than waiting for the pair.
    function test_ALoweredTaxReachesTheCurveAtOnce() public {
        assertEq(curve.BUY_TAX_BPS(), 300, "starts at the launch rate");

        uint256 before = curve.quoteRaised();
        _buy(alice, 1e18);
        uint256 netAtThree = curve.quoteRaised() - before;

        vm.prank(admin);
        coin.lowerTax(100, 100);
        assertEq(curve.BUY_TAX_BPS(), 100, "the curve sees the new rate");

        before = curve.quoteRaised();
        _buy(bob, 1e18);
        uint256 netAtOne = curve.quoteRaised() - before;

        // 1.5% fee + 3% tax leaves 95.5%; 1.5% + 1% leaves 97.5%.
        assertEq(netAtThree, 0.955e18, "old rate on the old trade");
        assertEq(netAtOne, 0.975e18, "new rate on the new trade");
    }

    /// Only the curve may ask the coin to split curve-phase tax.
    function test_StrangerCannotSettleCurveTax() public {
        vm.expectRevert(PerpMeTaxToken.OnlyCurve.selector);
        vm.prank(bob);
        coin.settleCurveTax(1e18);
    }

    /**
     * Graduation still hands the pair everything the curve raised — the tax
     * left per trade, so nothing of it is sitting here to be swept into the
     * pool by mistake.
     */
    function test_NothingOfTheTaxIsStrandedAtGraduation() public {
        _buy(alice, 10e18);
        assertEq(
            IERC20(WNVDAX).balanceOf(address(curve)),
            curve.quoteRaised(),
            "the curve holds exactly what it raised, no more"
        );

        _buy(bob, 2_000e18); // clears the curve
        assertTrue(curve.graduated(), "graduated");
        assertEq(IERC20(WNVDAX).balanceOf(address(curve)), 0, "and kept nothing back");
    }

    /**
     * The buy that clears the curve is trimmed, and the trim now has to split
     * one leftover between TWO charges. Fuzzed, because that arithmetic is
     * where a refund underflow already bit us once.
     */
    function testFuzz_TheClearingBuySurvivesTwoFees(uint256 nudge) public {
        _buy(alice, 10e18 + bound(nudge, 0, 5e18));
        if (curve.graduated()) return;

        deal(WNVDAX, bob, 5_000e18);
        _buy(bob, 5_000e18); // far more than the curve can absorb
        assertTrue(curve.graduated(), "the oversized buy cleared the curve");
        assertEq(curve.tokensLeft(), 0, "exactly empty");
    }

    /**
     * The curve hands coins to the buyer and to nobody else.
     *
     * Naming a third party used to be allowed, and it went straight through the
     * coin's curve-phase freeze, because that freeze permits anything the curve
     * sends. Pointing it at a Uniswap pair address — knowable before the pair
     * exists, since V2 pairs are CREATE2 — parked coins in a pool that had no
     * business existing yet; adding the quote side and minting LP then turned
     * graduation into a payout. Measured before the fix: 4 wNVDAx in, 21.6 of
     * the 41.8 raised back out, plus 214M coins.
     */
    function test_CurveWillNotDeliverCoinsToAThirdParty() public {
        vm.startPrank(alice);
        IERC20(WNVDAX).approve(address(curve), type(uint256).max);
        vm.expectRevert(PerpMeCurve.BadRecipient.selector);
        curve.buyFor(1e18, 0, bob);
        vm.stopPrank();
    }

    /**
     * A buy's tax goes to the people who held BEFORE it — never back to the
     * buyer.
     *
     * The coins used to reach the buyer before the tax was split, so every
     * buyer was paid their own share of their own tax: on the first staging
     * coin the opening buy got the whole holders' slice back, and a buyer at
     * 65% of the float effectively paid 2.5% of a 4% tax. The opening buy has
     * nobody to pay, and its holders' slice goes to the protocol — decided
     * 2026-09-15, so a creator's own first buy is taxed like anyone's.
     */
    function test_ABuyerIsNotPaidOutOfTheirOwnTax() public {
        // 3 wNVDAx at 3%: tax 0.09, protocol 20% = 0.018, creator
        // 0.072 * 1500/9500, holders the rest. Fee 1.5% to the same treasury.
        uint256 treasuryBefore = IERC20(WNVDAX).balanceOf(treasury);
        _buy(alice, 3e18);

        uint256 tax = (3e18 * 300) / 10_000;
        uint256 fee = (3e18 * 150) / 10_000;
        uint256 toCreator = ((tax - (tax * 2000) / 10_000) * 1500) / 9500;
        assertEq(dist.claimable(alice), 0, "the opening buyer is owed nothing of her own tax");
        assertEq(dist.totalDeposited(), 0, "nobody held, so nothing was shared");
        assertApproxEqAbs(
            IERC20(WNVDAX).balanceOf(treasury) - treasuryBefore,
            fee + tax - toCreator,
            2,
            "its holders' slice went to the protocol"
        );

        // Bob's tax is Alice's alone: she held, he did not yet.
        vm.warp(block.timestamp + 2 hours);
        uint256 aliceBefore = dist.claimable(alice) + IERC20(WNVDAX).balanceOf(alice);
        _buy(bob, 3e18);
        uint256 holdersSlice = dist.totalDeposited();
        assertGt(holdersSlice, 0);
        assertApproxEqAbs(
            dist.claimable(alice) + IERC20(WNVDAX).balanceOf(alice) - aliceBefore,
            holdersSlice,
            2,
            "all of it to the holder who was there first"
        );
        assertEq(dist.claimable(bob), 0, "none of it back to bob");

        // And pro-rata still holds for everybody else's tax: a third buy pays
        // both of them, the larger holder more.
        vm.warp(block.timestamp + 2 hours);
        address carol = address(0xCA201);
        deal(WNVDAX, carol, 10e18);
        uint256 bobBefore = dist.claimable(bob) + IERC20(WNVDAX).balanceOf(bob);
        _buy(carol, 1e18);
        assertGt(dist.claimable(bob) + IERC20(WNVDAX).balanceOf(bob), bobBefore, "bob earns from carol's buy");
        assertEq(dist.claimable(carol), 0, "and carol from none of it");
    }

    /**
     * A purchase made through the coin's router still pays its holders.
     *
     * The router is allowed to name a recipient — it is the one address that
     * may, because it can only ever name its own caller. Having it take
     * delivery and forward instead looked equivalent and was not: with a
     * share-less contract as the recipient nobody was a holder, the dividend
     * found no owner and fell through to the protocol. Every HYPE purchase on
     * devtest did exactly that until a live trade showed it.
     */
    function test_ABuyThroughTheRouterStillPaysHolders() public {
        _buy(alice, 3e18); // somebody has to hold for there to be anyone to pay

        vm.startPrank(bob);
        IERC20(WNVDAX).approve(address(router), type(uint256).max);
        router.buyFor(curve, IERC20(WNVDAX), 3e18, bob);
        vm.stopPrank();

        assertGt(coin.balanceOf(bob), 0, "bob got the coins, not the router");
        assertEq(coin.balanceOf(address(router)), 0, "the router kept nothing");
        assertGt(dist.totalDeposited(), 0, "and the holders' slice reached the holders");
    }

    /**
     * The same trade must cost the same to estimate and to run.
     *
     * The dividend push used to loop "while gas remains", which made a trade's
     * gas depend on the gas it was given. `eth_estimateGas` searches for the
     * smallest limit that succeeds and lands on one where the push declines to
     * start; run at that estimate and the push CAN afford to start, does the
     * work, and overruns. A seller lost a transaction to exactly this — 728,716
     * gas used of 728,716, no logs.
     *
     * Pinned as a comparison rather than an absolute number: what matters is
     * that a generous limit does not cost dramatically more than a tight one.
     */
    function test_TradeGasDoesNotGrowWithTheGasItIsGiven() public {
        _buy(alice, 3e18);
        vm.warp(block.timestamp + 2 hours);

        vm.startPrank(bob);
        IERC20(WNVDAX).approve(address(curve), type(uint256).max);

        uint256 before = gasleft();
        curve.buy{gas: 900_000}(1e18, 0);
        uint256 tight = before - gasleft();

        before = gasleft();
        curve.buy{gas: 8_000_000}(1e18, 0);
        uint256 generous = before - gasleft();
        vm.stopPrank();

        /*
         * BOUNDED, not equal — and the difference is the point.
         *
         * A tight limit makes the dividend settlement fail into its own catch,
         * so the trade succeeds cheaply and pays nobody; a generous one lets it
         * run. That gap cannot be closed while the dividend path is allowed to
         * fail without taking the trade with it, and it must be allowed to.
         *
         * What CAN be guaranteed is that the gap is small enough for a caller
         * to cover with a margin, which is what the site now adds explicitly
         * rather than trusting a wallet's estimate. Two holders and a split is
         * the whole of it.
         */
        uint256 gap = generous > tight ? generous - tight : tight - generous;
        assertLt(gap, 400_000, "the swing a gas limit can cause is bounded");
    }

    /**
     * A coin on the curve is findable by anything that reads Uniswap.
     *
     * No chart site or aggregator has an integration with this launchpad; they
     * scan for the standard pair events and read the standard views. A curve
     * that speaks only Bought and Sold is invisible for the whole phase in
     * which a coin trades hardest — our own header showed "MARKET CAP —" on a
     * live coin for exactly this reason.
     */
    function test_TheCurveAnswersLikeAUniswapPair() public {
        ICurveAsPair p = ICurveAsPair(address(curve));

        // Sorted the way Uniswap sorts, whichever way these two addresses fall.
        (address t0, address t1) = address(coin) < WNVDAX
            ? (address(coin), WNVDAX)
            : (WNVDAX, address(coin));
        assertEq(p.token0(), t0, "token0");
        assertEq(p.token1(), t1, "token1");

        (uint112 r0, uint112 r1,) = p.getReserves();
        uint256 rCoin = address(coin) < WNVDAX ? r0 : r1;
        uint256 rQuote = address(coin) < WNVDAX ? r1 : r0;
        assertEq(rCoin, curve.virtualToken(), "coin reserve is the virtual one");
        assertEq(rQuote, curve.virtualQuote(), "quote reserve is the virtual one");

        // And the price a reader derives from them is the curve's own price.
        assertEq((rQuote * 1e18) / rCoin, curve.spotPrice(), "same price");

        // Trading moves what a reader sees.
        _buy(alice, 3e18);
        (uint112 a0, uint112 a1,) = p.getReserves();
        uint256 afterQuote = address(coin) < WNVDAX ? a1 : a0;
        assertGt(afterQuote, rQuote, "the quote reserve grew with the buy");
    }

    /// The V2 events are emitted alongside ours, with the amounts that actually
    /// moved the curve — so reserves and swaps reconcile for an indexer.
    function test_TheCurveEmitsUniswapSwapAndSync() public {
        vm.recordLogs();
        _buy(alice, 3e18);

        bytes32 swapTopic =
            keccak256("Swap(address,uint256,uint256,uint256,uint256,address)");
        bytes32 syncTopic = keccak256("Sync(uint112,uint112)");

        bool sawSwap;
        bool sawSync;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(curve)) continue;
            if (logs[i].topics[0] == swapTopic) sawSwap = true;
            if (logs[i].topics[0] == syncTopic) sawSync = true;
        }
        assertTrue(sawSwap, "a Uniswap Swap was emitted");
        assertTrue(sawSync, "a Uniswap Sync was emitted");
    }

    /**
     * @dev Where Uniswap V2 will put the pair for these two tokens.
     *
     *      The factory works this out for a real launch; this file stands in
     *      for the factory, so it works it out too. The init-code hash is the
     *      stock Uniswap V2 one, checked against a live pair on this chain.
     */
    function _pairAddress(address a, address b) internal view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V2_FACTORY,
                            keccak256(abi.encodePacked(t0, t1)),
                            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
                        )
                    )
                )
            )
        );
    }
}
