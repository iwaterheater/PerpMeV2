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
import {PerpMeDividendDistributor} from "../src/tax/PerpMeDividendDistributor.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

interface IV2FactoryLike {
    function getPair(address, address) external view returns (address);
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
 * A launch, from the factory call to a graduated pool, against real Uniswap V2
 * on a fork of HyperEVM with a real tokenized share as the quote asset.
 *
 * There is one launch path and it goes through the curve: the creator pays the
 * fee and nothing else, and the quote side of the eventual pool is raised from
 * buyers rather than put up by the creator.
 */
contract PerpMeTaxFactoryTest is Test {
    /* PRJX's V2, verified on chain 999. These were `vm.envOr(..., makeAddr(…))`
       — a labelled address with no code — from the days when no HyperEVM venue
       had been chosen. Since the factory started opening the pair at launch,
       that stand-in made every launching test in this suite revert, and the
       per-test venue guard could not see it: the guard read `code.length` on
       the default EVM, before the fork is selected, where nothing has code. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
    address constant SWAP_ROUTER_02 = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;
    uint256 constant LAUNCH_FEE = 0.01 ether;

    PerpMeTaxFactory factory;
    PerpMeTaxTokenDeployer deployer;
    PerpMeCurveRouter router;

    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address buyer = address(0xB0B);


    PerpMeUniV2Venue venue;

    function setUp() public {
        ForkPin.select();

        // The deployer must know the factory and the factory must know the
        // deployer, so the factory's address is predicted from this account's
        // next-but-one nonce — the same nonce prediction the V3 stack uses.
        venue = new PerpMeUniV2Venue(V2_FACTORY, 30);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        deployer = new PerpMeTaxTokenDeployer(predicted);
        factory = new PerpMeTaxFactory(address(deployer), treasury, LAUNCH_FEE, 2000
        );
        assertEq(address(factory), predicted, "nonce prediction held");

        factory.addDexConfig(venue, "test");

        factory.addLaunchConfig(
            PerpMeTaxFactory.LaunchConfig({
                dexId: 0,
                pairToken: WNVDAX,
                totalSupply: SUPPLY,
                enabled: true,
                virtualToken: 1_073_000_000e18,
                virtualQuote: 14.71e18,
                curveTokens: CURVE_TOKENS,
                curveFeeBps: 150
            })
        );

        router = new PerpMeCurveRouter(SWAP_ROUTER_02, WHYPE);
        factory.setCurveRouter(address(router));

        deal(WNVDAX, creator, 5_000e18);
        deal(WNVDAX, buyer, 5_000e18);
        vm.deal(creator, 1 ether);
    }

    function _params() internal pure returns (PerpMeTaxFactory.LaunchParams memory) {
        return PerpMeTaxFactory.LaunchParams({
            name: "Nvidia Dividend Cat",
            symbol: "NVCAT",
            metadataURI: "ipfs://cat",
            metadataB64: "",
            buyTaxBps: 300,
            sellTaxBps: 300,
            dividendBps: 8000,
            creatorBps: 1500,
            burnBps: 500,
            minDividendBalance: 1_000e18,
            swapThreshold: 100_000e18
        });
    }

    function _launch(uint256 initialBuy) internal returns (address token, address curve) {
        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        (token, curve) =
            factory.launchToken{value: LAUNCH_FEE}(_params(), 0, bytes32(0), initialBuy, 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------

    /// The whole point of the curve: launching costs the fee and nothing else.
    function test_LaunchCostsTheCreatorNothingButTheFee() public {
        uint256 before = IERC20(WNVDAX).balanceOf(creator);
        (address token, address curve) = _launch(0);

        assertEq(IERC20(WNVDAX).balanceOf(creator), before, "no quote token was put up");
        assertEq(IERC20(token).balanceOf(curve), SUPPLY, "the curve holds the whole supply");
        assertEq(PerpMeTaxToken(token).curve(), curve, "the coin knows its curve");
        assertEq(PerpMeTaxToken(token).pair(), address(0), "and has no pair yet");
        assertEq(factory.getLaunchedToken(token).curve, curve, "recorded");
    }

    function test_LaunchFeeReachesTheTreasury() public {
        uint256 before = treasury.balance;
        _launch(0);
        assertEq(treasury.balance - before, LAUNCH_FEE, "treasury was paid");
    }

    /// The creator's opening buy goes through the curve at the public price.
    function test_OpeningBuyGoesThroughTheCurve() public {
        (address token,) = _launch(5e18);
        assertGt(IERC20(token).balanceOf(creator), 0, "creator holds coins");
        assertEq(IERC20(token).balanceOf(address(factory)), 0, "factory kept none");
    }

    /// Buying the curve out opens the pool, and the coin becomes ordinary.
    function test_CurveSellsOutAndOpensThePool() public {
        (address token, address curve) = _launch(0);
        deal(WNVDAX, buyer, 100_000e18);

        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(60e18, 0);
        vm.stopPrank();

        assertTrue(PerpMeCurve(curve).graduated(), "graduated");
        address pair = PerpMeCurve(curve).pair();
        assertEq(IV2FactoryLike(V2_FACTORY).getPair(token, WNVDAX), pair, "pair exists");
        assertEq(PerpMeTaxToken(token).pair(), pair, "the coin was told");
        assertEq(IERC20(token).balanceOf(pair), SUPPLY - CURVE_TOKENS, "held-back coins went in");
        assertGt(IERC20(pair).balanceOf(BURN_SINK), 0, "LP burned");
        assertEq(IERC20(WNVDAX).balanceOf(curve), 0, "curve kept nothing");
    }

    /// After graduation the tax runs, holders earn, and so do we.
    function test_AfterGraduationEverybodyIsPaid() public {
        (address token, address curve) = _launch(0);
        PerpMeDividendDistributor dist = PerpMeTaxToken(token).distributor();
        deal(WNVDAX, buyer, 100_000e18);

        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(60e18, 0);
        vm.stopPrank();

        uint256 treasuryBefore = IERC20(WNVDAX).balanceOf(treasury);

        address[] memory sell = new address[](2);
        sell[0] = token;
        sell[1] = WNVDAX;
        vm.startPrank(buyer);
        IERC20(token).approve(V2_ROUTER, type(uint256).max);

        // The coin will not sell its tax into a pool it has no price history
        // for, so the sales that fund everything below have to be far enough
        // apart for it to have one.
        vm.warp(block.timestamp + 301);
        IV2RouterLike(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(token).balanceOf(buyer) / 4, 0, sell, buyer, block.timestamp
        );
        vm.warp(block.timestamp + 301);
        IV2RouterLike(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(token).balanceOf(buyer) / 4, 0, sell, buyer, block.timestamp
        );
        vm.stopPrank();

        assertGt(dist.totalDeposited(), 0, "dividends were funded");
        assertGt(IERC20(WNVDAX).balanceOf(treasury) - treasuryBefore, 0, "we earned from the tax");
        assertGt(IERC20(WNVDAX).balanceOf(creator), 0, "and the creator did too");
    }

    /**
     * The platform earns on the curve as well as on the tax.
     *
     * These are the two halves of the business: 1.5% of everything traded while
     * the curve is the market, then a share of the coin's tax forever after.
     */
    function test_PlatformEarnsOnTheCurveToo() public {
        (, address curve) = _launch(0);

        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        // A holder first: the opening buy's holders' slice has nobody to go to
        // and lands on the treasury too, which is not what this measures.
        PerpMeCurve(curve).buy(1e18, 0);
        uint256 before = IERC20(WNVDAX).balanceOf(treasury);
        PerpMeCurve(curve).buy(10e18, 0);
        vm.stopPrank();

        // 1.5% platform fee, and on top of it the protocol's 20% share of the
        // coin's own 3% tax, which the curve now charges as a surcharge so that
        // dividends run before the pair exists. One address here plays both
        // parts, so both slices land on `treasury`.
        assertApproxEqRel(
            IERC20(WNVDAX).balanceOf(treasury) - before,
            0.15e18 + 0.06e18,
            1e16,
            "1.5% platform fee plus 20% of the 3% tax"
        );
    }

    // -------------------------------------------------------------------------
    //  Guards
    // -------------------------------------------------------------------------

    function test_LaunchFeeMustBeExact() public {
        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        vm.expectRevert(PerpMeTaxFactory.InsufficientLaunchFee.selector);
        factory.launchToken{value: LAUNCH_FEE - 1}(_params(), 0, bytes32(0), 0, 0);
        vm.stopPrank();
    }

    /// A tax outside the coin's own constants cannot be launched, so the bound
    /// holds even if this factory is later replaced by a careless one.
    function test_CoinRejectsAnOutOfRangeTaxEvenViaTheFactory() public {
        PerpMeTaxFactory.LaunchParams memory p = _params();
        p.sellTaxBps = 900;

        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PerpMeTaxToken.InvalidTax.selector, uint16(900)));
        factory.launchToken{value: LAUNCH_FEE}(p, 0, bytes32(0), 0, 0);
        vm.stopPrank();
    }

    /// A curve fee above the curve's own ceiling cannot be configured into one.
    function test_CurveRejectsAnAbsurdTradeFee() public {
        PerpMeTaxFactory.LaunchConfig memory c = factory.getLaunchConfig(0);
        c.curveFeeBps = 400;
        factory.updateLaunchConfig(0, c);

        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PerpMeCurve.TradeFeeTooHigh.selector, uint16(400)));
        factory.launchToken{value: LAUNCH_FEE}(_params(), 0, bytes32(0), 0, 0);
        vm.stopPrank();
    }

    /// Curve parameters that would run out of virtual inventory are refused.
    function test_ImpossibleCurveParamsAreRefused() public {
        PerpMeTaxFactory.LaunchConfig memory c = factory.getLaunchConfig(0);
        c.virtualToken = CURVE_TOKENS; // must exceed what is on offer
        factory.updateLaunchConfig(0, c);

        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        vm.expectRevert(PerpMeCurve.BadCurveParams.selector);
        factory.launchToken{value: LAUNCH_FEE}(_params(), 0, bytes32(0), 0, 0);
        vm.stopPrank();
    }

    function test_DeployerRefusesEveryoneButTheFactory() public {
        vm.expectRevert(PerpMeTaxTokenDeployer.NotFactory.selector);
        deployer.deploy(bytes32(uint256(1)));
    }

    /// The predicted address and the deployed one agree — this is what the
    /// browser's vanity-salt mining depends on.
    function test_PredictedAddressMatches() public {
        bytes32 salt = keccak256(abi.encode(creator, bytes32(0)));
        address predicted = deployer.predict(salt);
        (address token,) = _launch(0);
        assertEq(token, predicted, "mined address is the address deployed");
    }

    /**
     * Changing the platform's rate cannot touch a coin that already exists.
     *
     * Tested downwards because the launch rate is already at the coin's
     * ceiling — and downwards is the direction that would otherwise let us
     * re-price a live coin's holders in our favour after the fact.
     */
    function test_ChangingTheRateDoesNotAffectLiveCoins() public {
        (address token,) = _launch(0);
        assertEq(PerpMeTaxToken(token).protocolBps(), 2000, "launched at the rate of the day");

        factory.setProtocolFeeBps(500);
        assertEq(PerpMeTaxToken(token).protocolBps(), 2000, "the live coin did not move");
        assertEq(factory.protocolFeeBps(), 500, "but the next launch would differ");
    }

    /**
     * The one thing the platform CAN change on a live coin: its tax, downward.
     *
     * The coin has no owner; it asks the factory who owns it at the moment of
     * the call. So the factory's owner is the lever, and handing the factory
     * over hands the lever over with it.
     */
    function test_FactoryOwnerCanLowerALiveCoinsTax() public {
        (address token, address curve) = _launch(0);
        PerpMeTaxToken coin = PerpMeTaxToken(token);
        assertEq(coin.buyTaxBps(), 300, "launched at three");

        coin.lowerTax(100, 200);
        assertEq(coin.buyTaxBps(), 100, "buy is one");
        assertEq(coin.sellTaxBps(), 200, "sell is two");
        assertEq(PerpMeCurve(curve).BUY_TAX_BPS(), 100, "the curve reads the new rate");

        // And the next curve trade is charged at it: 1.5% fee + 1% tax.
        uint256 before = PerpMeCurve(curve).quoteRaised();
        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(10e18, 0);
        vm.stopPrank();
        assertEq(PerpMeCurve(curve).quoteRaised() - before, 9.75e18, "97.5% reached the curve");
    }

    function test_CreatorCannotLowerTheTax() public {
        (address token,) = _launch(0);
        vm.prank(creator);
        vm.expectRevert(PerpMeTaxToken.NotFactoryOwner.selector);
        PerpMeTaxToken(token).lowerTax(100, 100);
    }

    function test_TheTaxLeverMovesWithFactoryOwnership() public {
        (address token,) = _launch(0);
        address next = makeAddr("nextOwner");

        /*
         * Two steps, and nothing moves on the first one.
         *
         * Every lever on every coin this factory has launched hangs off
         * `owner()`, so a single-step transfer to an address that turns out to
         * be wrong takes all of them away from all of them at once, for good.
         * Naming the next owner changes nothing until they prove they can act.
         */
        factory.transferOwnership(next);
        assertEq(factory.pendingOwner(), next, "named, not handed over");
        assertEq(factory.owner(), address(this), "the lever has not moved yet");
        PerpMeTaxToken(token).lowerTax(200, 200);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PerpMeTaxFactory.NotThePendingOwner.selector);
        factory.acceptOwnership();

        vm.prank(next);
        factory.acceptOwnership();
        assertEq(factory.owner(), next, "now it has");
        assertEq(factory.pendingOwner(), address(0), "and the pending slot is clear");

        vm.expectRevert(PerpMeTaxToken.NotFactoryOwner.selector);
        PerpMeTaxToken(token).lowerTax(100, 100);

        vm.prank(next);
        PerpMeTaxToken(token).lowerTax(100, 100);
        assertEq(PerpMeTaxToken(token).buyTaxBps(), 100, "the new owner holds the lever");
    }

    /// And the button that would drop the lever for every coin at once is gone.
    function test_FactoryOwnershipCannotBeRenounced() public {
        vm.expectRevert(PerpMeTaxFactory.OwnershipIsNotRenounceable.selector);
        factory.renounceOwnership();
        assertEq(factory.owner(), address(this), "still owned");
    }

    /**
     * The point of the whole arrangement: a second exchange costs one small
     * contract and one config, and nothing already deployed moves.
     *
     * Before this, the exchange was an immutable on this factory and its
     * arithmetic was compiled into the coin — so adding one meant a new
     * factory, a new coin deployer welded to it, and the site, the indexer and
     * every launched address moving onto the pair of them.
     */
    function test_ASecondExchangeNeedsNoNewFactory() public {
        address factoryBefore = address(factory);
        address deployerBefore = address(factory.TOKEN_DEPLOYER());

        PerpMeUniV2Venue second = new PerpMeUniV2Venue(V2_FACTORY, 25);
        uint256 dexId = factory.addDexConfig(second, "another-v2");
        assertEq(dexId, 1, "registered alongside the first");

        PerpMeTaxFactory.LaunchConfig memory cfg = factory.getLaunchConfig(0);
        cfg.dexId = dexId;
        factory.addLaunchConfig(cfg);

        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        // A different salt: the coin's address is CREATE2 from the creator and
            // this, so reusing it would land on the one _launch already made.
        (address token,) =
            factory.launchToken{value: LAUNCH_FEE}(_params(), 1, bytes32(uint256(7)), 0, 0);
        vm.stopPrank();

        assertEq(address(PerpMeTaxToken(token).venue()), address(second), "launched on the new one");
        assertEq(address(factory), factoryBefore, "same factory");
        assertEq(address(factory.TOKEN_DEPLOYER()), deployerBefore, "same coin deployer");

        // And a coin on the first exchange is untouched by any of it.
        (address old,) = _launch(0);
        assertEq(address(PerpMeTaxToken(old).venue()), address(venue), "still the original");
    }

    /// An exchange can be closed to new launches without touching a coin that
    /// is already trading on it.
    function test_AnExchangeCanBeClosedToNewLaunches() public {
        factory.setDexStatus(0, false);
        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        vm.expectRevert(PerpMeTaxFactory.DexDisabled.selector);
        factory.launchToken{value: LAUNCH_FEE}(_params(), 0, bytes32(0), 0, 0);
        vm.stopPrank();
    }

    function test_RateAboveTheCeilingIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(PerpMeTaxFactory.ProtocolShareTooHigh.selector, uint16(2001))
        );
        factory.setProtocolFeeBps(2001);
    }

    /// Graduation is reported back, so the factory knows every coin's pair.
    function test_GraduationIsReportedToTheFactory() public {
        (address token, address curve) = _launch(0);
        assertEq(factory.getLaunchedToken(token).pair, address(0), "no pair yet");

        deal(WNVDAX, buyer, 100_000e18);
        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(60e18, 0);
        vm.stopPrank();

        assertEq(
            factory.getLaunchedToken(token).pair,
            PerpMeCurve(curve).pair(),
            "the factory learned the pair"
        );
    }

    /// Only a coin's own curve may report its graduation.
    function test_NobodyElseCanReportAGraduation() public {
        (address token,) = _launch(0);
        vm.prank(buyer);
        vm.expectRevert(PerpMeTaxFactory.NotTheCurve.selector);
        factory.onGraduated(token, address(0xdead), 1, 1);
    }

    /**
     * The bridge a buyer holding HYPE actually crosses.
     *
     * Straight through the 1% WHYPE/wNVDAx pool, which is the only pool that
     * pair has on PRJX and the one web/lib/routes.ts already sends trades
     * through. It was a three-hop path through USD₮0 and USDG before, and two
     * of those four addresses have no code on HyperEVM at all: they came over
     * with the fork from the chain this stack used to run on, and the route was
     * never re-derived for this one. The swap reverted on every one of these
     * tests, which then skipped themselves for want of a V2 venue and said
     * nothing.
     *
     * Deliberately not a constant: the bridge is somebody else's liquidity, and
     * a route that stops working should be a front-end change rather than a
     * redeployment — which is why the router takes the path as an argument.
     */
    function _nativeToShare() internal pure returns (bytes memory) {
        return abi.encodePacked(WHYPE, uint24(10000), WNVDAX);
    }

    function _shareToNative() internal pure returns (bytes memory) {
        return abi.encodePacked(WNVDAX, uint24(10000), WHYPE);
    }

    /**
     * Somebody holding only HYPE can buy a coin priced in a share.
     *
     * Without this the audience for a fresh dividend coin is people who already
     * own the right stock token, which is close to nobody.
     */
    function test_BuyOnTheCurveWithNative() public {
        (address token, address curve) = _launch(0);
        vm.deal(buyer, 5 ether);

        vm.prank(buyer);
        uint256 got = router.buyWithNative{value: 1 ether}(
            PerpMeCurve(curve), _nativeToShare(), 0, 0
        );

        assertGt(got, 0, "the curve sold");
        assertEq(IERC20(token).balanceOf(buyer), got, "and the coins went to the buyer");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router kept none");
        assertEq(IERC20(WNVDAX).balanceOf(address(router)), 0, "nor any of the share");
    }

    /// And back out again, in one call.
    /**
     * Sending more HYPE than the curve can use graduates it and returns the
     * rest as HYPE — not as the share at whatever the bridge charged.
     *
     * The case a buyer actually hit on the fork: a thousand HYPE at a curve
     * that needed about a hundred and thirty. The whole thousand went through
     * a five-thousand-dollar bridge pool, most of it into that pool's price.
     */
    function test_OverpayingInNativeGraduatesAndRefundsHype() public {
        (address coin, address curve) = _launch(0);
        vm.deal(buyer, 2_000 ether);

        uint256 needed = PerpMeCurve(curve).quoteToFill();
        assertGt(needed, 0, "there is a curve to fill");

        uint256 before = buyer.balance;
        uint256 shareBefore = IERC20(WNVDAX).balanceOf(buyer);
        vm.prank(buyer);
        router.buyWithNative{value: 1_000 ether}(PerpMeCurve(curve), _nativeToShare(), 0, 0);

        assertTrue(PerpMeCurve(curve).graduated(), "the curve was bought out");
        uint256 spent = before - buyer.balance;
        assertLt(spent, 400 ether, "and nothing like the thousand was spent");
        assertGt(spent, 50 ether, "though the fill itself was paid for");
        // The share the buyer gained is the DIVIDEND the graduation's own
        // liquidation paid its one holder — under a share — not change from an
        // over-bought bridge, which used to arrive here by the hundred.
        assertLt(IERC20(WNVDAX).balanceOf(buyer) - shareBefore, 2e18, "no pile of the share came back");
        assertEq(address(router).balance, 0, "the router kept no HYPE");
        assertEq(IERC20(coin).balanceOf(address(router)), 0, "nor coins");
    }

    /**
     * The ceiling the buyer sets is the only guard a filling buy can have.
     *
     * A buy that empties the curve gets exactly `tokensLeft` coins whatever
     * the bridge charged, so `minTokensOut` passes at its strongest possible
     * value and sees nothing. What moves is the HYPE, so the HYPE is what is
     * capped — and everything above the cap has to come back.
     */
    function test_ACapOnNativeIsRespectedAndTheRestComesBack() public {
        (, address curve) = _launch(0);
        vm.deal(buyer, 2_000 ether);

        // What the fill honestly costs, found by letting it run uncapped.
        uint256 snap = vm.snapshotState();
        uint256 beforeHonest = buyer.balance;
        vm.prank(buyer);
        router.buyWithNative{value: 1_000 ether}(PerpMeCurve(curve), _nativeToShare(), 0, 0);
        uint256 honest = beforeHonest - buyer.balance;
        vm.revertToState(snap);

        // A tenth over the honest price is a tolerance; the trade fits inside it.
        uint256 cap = (honest * 110) / 100;
        uint256 before = buyer.balance;
        vm.prank(buyer);
        router.buyWithNative{value: 1_000 ether}(PerpMeCurve(curve), _nativeToShare(), 0, cap);
        uint256 spent = before - buyer.balance;

        assertTrue(PerpMeCurve(curve).graduated(), "the curve still filled");
        assertLe(spent, cap, "and never spent more than the buyer allowed");
        assertEq(address(router).balance, 0, "the router kept no HYPE");
    }

    /**
     * And a cap below the price of the fill buys what it can rather than
     * quietly spending the whole of `msg.value` on it.
     */
    function test_ACapBelowTheFillBuysOnlyWhatItAllows() public {
        (address coin, address curve) = _launch(0);
        vm.deal(buyer, 2_000 ether);

        uint256 snap = vm.snapshotState();
        uint256 beforeHonest = buyer.balance;
        vm.prank(buyer);
        router.buyWithNative{value: 1_000 ether}(PerpMeCurve(curve), _nativeToShare(), 0, 0);
        uint256 honest = beforeHonest - buyer.balance;
        vm.revertToState(snap);

        uint256 cap = honest / 4;
        uint256 before = buyer.balance;
        vm.prank(buyer);
        router.buyWithNative{value: 1_000 ether}(PerpMeCurve(curve), _nativeToShare(), 0, cap);
        uint256 spent = before - buyer.balance;

        assertLe(spent, cap, "spent no more than the cap");
        assertGt(IERC20(coin).balanceOf(buyer), 0, "but did buy");
        assertFalse(PerpMeCurve(curve).graduated(), "a quarter of the fill does not fill it");
        assertEq(address(router).balance, 0, "the router kept no HYPE");
    }

    function test_SellOnTheCurveToNative() public {
        (address token, address curve) = _launch(0);
        vm.deal(buyer, 5 ether);

        vm.startPrank(buyer);
        uint256 got = router.buyWithNative{value: 1 ether}(
            PerpMeCurve(curve), _nativeToShare(), 0, 0
        );

        uint256 before = buyer.balance;
        IERC20(token).approve(address(router), type(uint256).max);
        uint256 back = router.sellToNative(PerpMeCurve(curve), got / 2, _shareToNative(), 0);
        vm.stopPrank();

        assertGt(back, 0, "HYPE came back");
        assertEq(buyer.balance - before, back, "and it arrived");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router kept no coins");
    }

    /// A coin still refuses ordinary sideways transfers during the curve — the
    /// router's permission is narrow, not a hole in the rule.
    function test_RouterPermissionDoesNotOpenTheCoinUp() public {
        (address token, address curve) = _launch(0);
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        router.buyWithNative{value: 1 ether}(PerpMeCurve(curve), _nativeToShare(), 0, 0);

        // The router's permission is about holding coins for an instant, not
        // about opening the one door the curve phase keeps shut.
        address reserved = PerpMeTaxToken(token).reservedPair();
        vm.prank(buyer);
        vm.expectRevert(PerpMeTaxToken.TransferRestricted.selector);
        IERC20(token).transfer(reserved, 1e18);
    }

    // -------------------------------------------------------------------------
    //  Moving the creator's income — a new wallet, or a community takeover
    // -------------------------------------------------------------------------

    function _tradeOnce(address token, address curve) internal {
        deal(WNVDAX, buyer, 100_000e18);
        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(60e18, 0);
        address[] memory sell = new address[](2);
        sell[0] = token;
        sell[1] = WNVDAX;
        IERC20(token).approve(V2_ROUTER, type(uint256).max);
        // Two sells, not one. The first accrues the tax and starts the price
        // average; the second, past its window, sells the tax and pays
        // everybody. Without the wait the second sale did not liquidate
        // either, and callers passed only because the clearing buy had funded
        // a dividend back to its own buyer — which a buy no longer does.
        IV2RouterLike(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(token).balanceOf(buyer) / 3, 0, sell, buyer, block.timestamp
        );
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.roll(vm.getBlockNumber() + 600);
        IV2RouterLike(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(token).balanceOf(buyer) / 3, 0, sell, buyer, vm.getBlockTimestamp()
        );
        vm.stopPrank();
    }

    /// By default the launching wallet is paid, exactly as before.
    function test_CreatorIsPaidByDefault() public {
        (address token, address curve) = _launch(0);
        assertEq(factory.creatorRecipient(token), creator, "defaults to the creator");

        // Measured as a delta: the creator was funded in setUp, so an absolute
        // check here would pass without a single coin having been paid.
        uint256 before = IERC20(WNVDAX).balanceOf(creator);
        _tradeOnce(token, curve);
        assertGt(IERC20(WNVDAX).balanceOf(creator) - before, 0, "and they were paid");
    }

    /// A creator can move their own income to another wallet.
    function test_CreatorCanMoveTheirOwnIncome() public {
        (address token, address curve) = _launch(0);
        address newWallet = address(0xBEEF01);

        vm.prank(creator);
        factory.setCreatorRecipient(token, newWallet);
        assertEq(factory.creatorRecipient(token), newWallet, "redirected");

        _tradeOnce(token, curve);
        assertGt(IERC20(WNVDAX).balanceOf(newWallet), 0, "the new wallet was paid");
    }

    /// A community takeover: the admin redirects an abandoned coin's income.
    function test_AdminCanHandOverAnAbandonedCoin() public {
        (address token, address curve) = _launch(0);
        address community = address(0xC0DE);

        factory.setCreatorRecipient(token, community); // this test IS the owner
        _tradeOnce(token, curve);

        assertGt(IERC20(WNVDAX).balanceOf(community), 0, "the community was paid");
    }

    /// Nobody else can touch it.
    function test_StrangersCannotRedirectIt() public {
        (address token,) = _launch(0);
        vm.prank(buyer);
        vm.expectRevert(PerpMeTaxFactory.NotCreatorOrAdmin.selector);
        factory.setCreatorRecipient(token, buyer);
    }

    /**
     * A takeover moves the creator's slice and NOTHING else.
     *
     * This is the property that separates a handover mechanism from a backdoor,
     * so it is asserted rather than argued: after the admin redirects a coin,
     * holders are still owed their dividends and the platform still gets its
     * cut, both unchanged.
     */
    function test_TakeoverCannotReachTheHoldersMoney() public {
        (address token, address curve) = _launch(0);
        PerpMeDividendDistributor dist = PerpMeTaxToken(token).distributor();

        factory.setCreatorRecipient(token, address(0xC0DE));
        uint256 treasuryBefore = IERC20(WNVDAX).balanceOf(treasury);
        _tradeOnce(token, curve);

        assertGt(dist.totalDeposited(), 0, "holders were still paid");
        // Dividends are pushed now, so the buyer's money has already arrived
        // rather than waiting to be claimed. Either is fine; having neither
        // would be the failure.
        assertGt(
            IERC20(WNVDAX).balanceOf(buyer) + dist.claimable(buyer),
            0,
            "the holder got their share, paid or claimable"
        );
        assertGt(IERC20(WNVDAX).balanceOf(treasury) - treasuryBefore, 0, "platform unchanged");
    }

    /**
     * A takeover has to STICK, or it is not a takeover.
     *
     * The permission is written as "the admin, or whoever is currently paid" —
     * so the moment the admin points a coin at the community, the wallet that
     * launched it stops being either and cannot point it back. That is the
     * whole difference between handing a project over and lending it out, and
     * the tests above never checked it: they proved the community gets paid,
     * not that the departed dev cannot simply take the stream back the next
     * block.
     */
    function test_ADevCannotReclaimAfterATakeover() public {
        (address token,) = _launch(0);
        address community = address(0xC0DE);

        factory.setCreatorRecipient(token, community); // this test IS the owner
        assertEq(factory.creatorRecipient(token), community, "handed over");

        vm.prank(creator);
        vm.expectRevert(PerpMeTaxFactory.NotCreatorOrAdmin.selector);
        factory.setCreatorRecipient(token, creator);

        assertEq(factory.creatorRecipient(token), community, "and it stayed handed over");
    }

    /// And whoever took it over can hand it on again — to a multisig, or to
    /// the next person to pick the project up — without asking the platform.
    function test_TheCommunityCanPassItOnItself() public {
        (address token,) = _launch(0);
        address community = address(0xC0DE);
        address multisig = address(0xC0DE02);

        factory.setCreatorRecipient(token, community);

        vm.prank(community);
        factory.setCreatorRecipient(token, multisig);
        assertEq(factory.creatorRecipient(token), multisig, "moved on by its new owner");
    }

    /**
     * The zero address is a RESET, not a disable, and it is worth pinning down.
     *
     * `creatorRecipient` falls back to the launching wallet whenever the
     * override is unset, so clearing the override on a coin that has been taken
     * over hands the stream straight back to the dev who left. Anyone reaching
     * for zero to "turn the creator share off" would do the opposite of what
     * they meant.
     */
    function test_ClearingTheOverrideReturnsItToTheLaunchingWallet() public {
        (address token,) = _launch(0);
        factory.setCreatorRecipient(token, address(0xC0DE));

        factory.setCreatorRecipient(token, address(0));
        assertEq(factory.creatorRecipient(token), creator, "back to the launching wallet");
    }
}
