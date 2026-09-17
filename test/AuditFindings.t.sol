// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForkPin} from "./ForkPin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpMeTaxFactory} from "../src/tax/PerpMeTaxFactory.sol";
import {PerpMeTaxTokenDeployer} from "../src/tax/PerpMeTaxTokenDeployer.sol";
import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeCurve} from "../src/tax/PerpMeCurve.sol";
import {PerpMeDividendDistributor} from "../src/tax/PerpMeDividendDistributor.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

/**
 * A curveRouter that abuses the permission the coin grants it.
 *
 * The shipped router always names its own caller, which is what made it safe —
 * and nothing enforced that. The registered router could name ANY recipient,
 * and coins sent by the curve skip the coin's reserved-pair freeze because the
 * curve is exempt from it. So the one address a coin must keep shut during its
 * curve was reachable by whatever contract the factory owner had registered.
 */
interface IV2FactoryLike {
    function createPair(address, address) external returns (address);
}

contract RouterNamingTheReservedPool {
    function buyInto(PerpMeCurve curve, IERC20 quote, uint256 amount, address to)
        external
        returns (uint256)
    {
        quote.transferFrom(msg.sender, address(this), amount);
        quote.approve(address(curve), amount);
        return curve.buyFor(amount, 0, to);
    }
}

/**
 * The four findings of the 2026-08-13 audit, as the behaviour that replaced
 * them.
 *
 * Each of these was reproduced against a fork before it was fixed, with the
 * numbers in the comments measured rather than reasoned about. They are kept as
 * tests because all four are silent: none of them reverts, none of them shows
 * up on the site, and three of them cost holders money while looking like an
 * ordinary launch.
 */
contract AuditFindingsTest is Test {
    /* PRJX's V2, verified on chain 999.

       These used to be read from the environment with no default, which meant
       every one of these suites skipped itself on every run — the check reads
       `code.length` before the fork is selected, where nothing has code at all.
       They were green for a year without executing. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
    /// The one pair token on the table that is not eighteen decimals.
    /// @dev The real one. 0xB6CEceAB… is USDC on X LAYER, chain 196 — it came
    ///      across with the fork and has no code here at all.
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;

    PerpMeTaxFactory factory;
    PerpMeTaxTokenDeployer deployer;

    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address buyer = address(0xB0B);


    PerpMeUniV2Venue venue;


    function setUp() public {
        /* No V2 venue configured for HyperEVM yet — see the note above. */
        /* setUp itself reaches the venue here, so the whole suite waits for
           one rather than guarding test by test. */
        ForkPin.select();

        venue = new PerpMeUniV2Venue(V2_FACTORY, 30);

        address predicted =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        deployer = new PerpMeTaxTokenDeployer(predicted);
        factory =
            new PerpMeTaxFactory(address(deployer), treasury, 0, 2000);

        factory.addDexConfig(venue, "test");

        factory.addLaunchConfig(_config(WNVDAX, 14.71e18));
        factory.addLaunchConfig(_config(USDC, 3_219_000_000));

        deal(WNVDAX, creator, 100_000e18);
        deal(WNVDAX, buyer, 100_000e18);
        deal(USDC, buyer, 1_000_000e6);
    }

    function _config(address pairToken, uint256 virtualQuote)
        internal
        pure
        returns (PerpMeTaxFactory.LaunchConfig memory)
    {
        return PerpMeTaxFactory.LaunchConfig({
            dexId: 0,
            pairToken: pairToken,
            totalSupply: SUPPLY,
            enabled: true,
            virtualToken: 1_073_000_000e18,
            virtualQuote: virtualQuote,
            curveTokens: CURVE_TOKENS,
            curveFeeBps: 150
        });
    }

    function _params(uint256 swapThreshold, uint16 dividendBps, uint16 creatorBps)
        internal
        pure
        returns (PerpMeTaxFactory.LaunchParams memory)
    {
        return PerpMeTaxFactory.LaunchParams({
            name: "Nvidia Dividend Cat",
            symbol: "NVCAT",
            metadataURI: "ipfs://cat",
            metadataB64: "",
            buyTaxBps: 300,
            sellTaxBps: 300,
            dividendBps: dividendBps,
            creatorBps: creatorBps,
            burnBps: 10_000 - dividendBps - creatorBps,
            minDividendBalance: 1_000e18,
            swapThreshold: swapThreshold
        });
    }

    function _ok() internal pure returns (PerpMeTaxFactory.LaunchParams memory) {
        return _params(100_000e18, 8000, 1500);
    }

    // =========================================================================
    // H-1
    // =========================================================================

    /**
     * The reserved pool is shut to the registered router too.
     *
     * Before: 8 wNVDAx in, 23.645 back out plus 214,565,256 coins — the whole
     * migration allocation, taken by parking coins in the pool before it
     * existed and minting LP against them.
     */
    function test_H1_NoRouterCanReachTheReservedPool() public {
        RouterNamingTheReservedPool evil = new RouterNamingTheReservedPool();
        factory.setCurveRouter(address(evil));

        vm.prank(creator);
        (address token, address curve) = factory.launchToken(_ok(), 0, bytes32(0), 0, 0);
        address reserved = PerpMeTaxToken(token).reservedPair();

        address attacker = address(0xBAD);
        deal(WNVDAX, attacker, 100_000e18);
        vm.startPrank(attacker);
        IERC20(WNVDAX).approve(address(evil), type(uint256).max);
        vm.expectRevert(PerpMeCurve.BadRecipient.selector);
        evil.buyInto(PerpMeCurve(curve), IERC20(WNVDAX), 4e18, reserved);
        vm.stopPrank();

        assertEq(IERC20(token).balanceOf(reserved), 0, "nothing reached the future pool");
    }

    /// And an ordinary buy through that same router still works.
    function test_H1_TheRouterStillBuysForItsCaller() public {
        RouterNamingTheReservedPool evil = new RouterNamingTheReservedPool();
        factory.setCurveRouter(address(evil));

        vm.prank(creator);
        (address token, address curve) = factory.launchToken(_ok(), 0, bytes32(0), 0, 0);

        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(address(evil), type(uint256).max);
        evil.buyInto(PerpMeCurve(curve), IERC20(WNVDAX), 4e18, buyer);
        vm.stopPrank();

        assertGt(IERC20(token).balanceOf(buyer), 0, "the buyer got their coins");
    }

    // =========================================================================
    // H-2
    // =========================================================================

    /**
     * Tax that can never be liquidated is not a launch that can be made.
     *
     * Before: 9,845,980 coins collected across four ordinary sells and not one
     * wei distributed, burned or recoverable — the coin has no owner and no
     * sweep, so it stays there for good.
     */
    function test_H2_AnUnreachableSwapThresholdIsRefused() public {
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpMeTaxToken.InvalidSwapThreshold.selector, type(uint256).max
            )
        );
        factory.launchToken(_params(type(uint256).max, 8000, 1500), 0, bytes32(0), 0, 0);
    }

    function test_H2_AZeroSwapThresholdIsRefused() public {
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(PerpMeTaxToken.InvalidSwapThreshold.selector, uint256(0))
        );
        factory.launchToken(_params(0, 8000, 1500), 0, bytes32(0), 0, 0);
    }

    /// A dividend coin that pays no dividend is not a dividend coin.
    function test_H2_AZeroHoldersShareIsRefused() public {
        vm.prank(creator);
        vm.expectRevert(PerpMeTaxToken.NoDividendShare.selector);
        factory.launchToken(_params(100_000e18, 0, 10_000), 0, bytes32(0), 0, 0);
    }

    /// The threshold the launch form actually sends is comfortably inside.
    function test_H2_TheShippedThresholdIsAccepted() public {
        vm.prank(creator);
        (address token,) = factory.launchToken(_ok(), 0, bytes32(0), 0, 0);
        assertEq(PerpMeTaxToken(token).swapThreshold(), 100_000e18, "launched");
    }

    // =========================================================================
    // M-1
    // =========================================================================

    /**
     * The automatic payout floor follows the reward token's decimals.
     *
     * Before: a flat 1e12, which is a millionth of a token at eighteen decimals
     * and one million whole tokens at six. On a USDC-quoted coin the rotation
     * skipped every holder — 80.84 USDC accrued, nothing pushed — and said so
     * only as `Processed(paid 0, visited 1)`.
     */
    function test_M1_AutomaticPayoutsWorkOnASixDecimalQuote() public {
        vm.prank(creator);
        (address token, address curve) = factory.launchToken(_ok(), 1, bytes32(0), 0, 0);
        PerpMeDividendDistributor dist = PerpMeTaxToken(token).distributor();

        assertEq(dist.MIN_AUTO_PAYOUT(), 1, "a millionth of one USDC, not a million of them");

        vm.startPrank(buyer);
        IERC20(USDC).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(2_000e6, 0);
        PerpMeCurve(curve).buy(2_000e6, 0);
        vm.stopPrank();

        assertGt(dist.totalClaimed(), 0, "the rotation actually paid somebody");
    }

    /// And the sixteen eighteen-decimal pairs keep the floor they had.
    function test_M1_EighteenDecimalQuotesAreUnchanged() public {
        vm.prank(creator);
        (address token,) = factory.launchToken(_ok(), 0, bytes32(0), 0, 0);
        assertEq(
            PerpMeTaxToken(token).distributor().MIN_AUTO_PAYOUT(),
            1e12,
            "exactly what the constant used to be"
        );
    }

    // =========================================================================
    // M-2
    // =========================================================================

    /**
     * The creator's opening buy is taxed like any other buy.
     *
     * M-2 originally found the holders' slice of the opening buy swept to the
     * treasury, because the factory bought in its own name and nobody held at
     * settlement. The fix delivered the coins first, which paid that slice
     * back to the creator instead — and every later buyer their own share of
     * their own tax. On 2026-09-15 the curve settles the tax BEFORE delivering
     * the coins: a buy's holders' slice goes to those who held before it, and
     * the opening buy, with nobody holding, sends it to the protocol. Decided,
     * not a regression; this pins the new shape and that the coins still
     * reach the creator rather than the factory.
     */
    function test_M2_TheOpeningBuyIsNotACreatorRefund() public {
        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        uint256 creatorQuoteBefore = IERC20(WNVDAX).balanceOf(creator);
        (address token,) = factory.launchToken(_ok(), 0, bytes32(0), 10e18, 0);
        vm.stopPrank();

        PerpMeTaxToken coin = PerpMeTaxToken(token);
        PerpMeDividendDistributor dist = coin.distributor();

        assertGt(IERC20(token).balanceOf(creator), 0, "the creator has their coins");
        assertEq(dist.totalDeposited(), 0, "their own buy funded no dividend for themselves");
        assertEq(dist.claimable(creator), 0);
        // What the creator spent, less their creator slice back, is the whole
        // 10 — nothing of the holders' slice came back to them.
        uint256 tax = (10e18 * uint256(coin.buyTaxBps())) / 10_000;
        uint256 toCreator = ((tax - (tax * uint256(coin.protocolBps())) / 10_000) * uint256(coin.creatorBps()))
            / (uint256(coin.dividendBps()) + coin.creatorBps());
        assertApproxEqAbs(creatorQuoteBefore - IERC20(WNVDAX).balanceOf(creator), 10e18 - toCreator, 2);
    }

    // =========================================================================
    // L-3
    // =========================================================================

    /**
     * A second pool for the same coin is taxed like the first.
     *
     * The tax used to be owed by one address — the pair the coin graduated
     * into — so any other venue for it traded free of the dividend, the burn
     * and the creator's share at once. Nothing stops such a pool being opened,
     * and if the liquidity went there what is left is an ordinary token with
     * a paragraph about dividends attached.
     */
    function test_L3_ASecondPoolPaysTheTaxToo() public {
        vm.prank(creator);
        (address token, address curve) = factory.launchToken(_ok(), 0, bytes32(0), 0, 0);

        // Buy the curve out so the coin graduates and becomes transferable.
        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(300e18, 0);
        vm.stopPrank();
        assertTrue(PerpMeCurve(curve).graduated(), "graduated");

        // A pool nobody asked for: the same coin against a different quote.
        address second = IV2FactoryLike(V2_FACTORY).createPair(token, USDC);
        assertTrue(second != PerpMeTaxToken(token).pair(), "a different venue");

        uint256 heldBefore = IERC20(token).balanceOf(token);
        uint256 send = 1_000_000e18;

        vm.prank(buyer);
        IERC20(token).transfer(second, send);

        uint256 taxed = IERC20(token).balanceOf(token) - heldBefore;
        assertEq(taxed, (send * 300) / 10_000, "the second pool paid the sell tax");
        assertEq(
            IERC20(token).balanceOf(second),
            send - taxed,
            "and the pool received the rest"
        );
    }

    /// An ordinary wallet is still not a market, and still pays nothing.
    function test_L3_WalletToWalletIsStillFree() public {
        vm.prank(creator);
        (address token, address curve) = factory.launchToken(_ok(), 0, bytes32(0), 0, 0);
        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(300e18, 0);
        vm.stopPrank();

        uint256 heldBefore = IERC20(token).balanceOf(token);
        vm.prank(buyer);
        IERC20(token).transfer(address(0xFEE1), 1_000e18);

        assertEq(IERC20(token).balanceOf(address(0xFEE1)), 1_000e18, "arrived whole");
        assertEq(IERC20(token).balanceOf(token), heldBefore, "and cost nothing");
    }
}
