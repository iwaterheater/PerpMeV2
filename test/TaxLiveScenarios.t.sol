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
import {PerpMeRamsesVenue} from "../src/tax/venue/PerpMeRamsesVenue.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

interface ILivePair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint256, uint256, uint256);
    function getAmountOut(uint256, address) external view returns (uint256);
    function swap(uint256, uint256, address, bytes calldata) external;
    function sync() external;
    function observationLength() external view returns (uint256);
}

interface IV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256, uint256, address, bytes calldata) external;
}

interface IV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external;
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
}

/**
 * What a live coin meets after launch day, on the real PRJX and Ramses.
 *
 * Written 2026-09-17 for the pre-production pass. The other suites prove the
 * mechanism trade by trade; these walk the situations that only come up once a
 * coin has been out for a while: nobody trading on a fresh Ramses pair, a
 * holder who sells everything and leaves, a wallet that trades through PRJX's
 * own router instead of ours, a dump into the pool, and each lever the factory
 * owner has over a coin that is already trading.
 */
contract TaxLiveScenariosTest is Test {
    address constant RAMSES_FACTORY = 0xd0a07E160511c40ccD5340e94660E9C9c01b0D27;
    address constant PRJX_V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant PRJX_V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;

    PerpMeTaxFactory factory;
    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    uint256 constant PRJX = 0;
    uint256 constant RAMSES = 1;

    function setUp() public {
        ForkPin.select();
        PerpMeUniV2Venue prjx = new PerpMeUniV2Venue(PRJX_V2_FACTORY, 30);
        PerpMeRamsesVenue ramses = new PerpMeRamsesVenue(RAMSES_FACTORY);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        PerpMeTaxTokenDeployer deployer = new PerpMeTaxTokenDeployer(predicted);
        factory = new PerpMeTaxFactory(address(deployer), treasury, 0, 2000);
        factory.addDexConfig(prjx, "prjx-v2");
        factory.addDexConfig(ramses, "ramses");
        for (uint256 d; d < 2; ++d) {
            factory.addLaunchConfig(
                PerpMeTaxFactory.LaunchConfig({
                    dexId: d,
                    pairToken: WNVDAX,
                    totalSupply: SUPPLY,
                    enabled: true,
                    virtualToken: 1_073_000_000e18,
                    virtualQuote: 14.4657e18,
                    curveTokens: CURVE_TOKENS,
                    curveFeeBps: 150
                })
            );
        }
        address[5] memory funded = [creator, alice, bob, carol, address(this)];
        for (uint256 i; i < funded.length; ++i) deal(WNVDAX, funded[i], 10_000e18);
    }

    // ------------------------------------------------------------ helpers --

    function _launch(uint256 dex) internal returns (PerpMeTaxToken coin, PerpMeCurve curve) {
        vm.startPrank(creator);
        (address token, address c) = factory.launchToken(
            PerpMeTaxFactory.LaunchParams({
                name: "Live",
                symbol: "LIVE",
                metadataURI: "",
                metadataB64: "",
                buyTaxBps: 400,
                sellTaxBps: 400,
                dividendBps: 5000,
                creatorBps: 2000,
                burnBps: 3000,
                minDividendBalance: 1_000e18,
                swapThreshold: 100_000e18
            }),
            dex,
            keccak256(abi.encode(dex, block.timestamp)),
            0,
            0
        );
        vm.stopPrank();
        coin = PerpMeTaxToken(payable(token));
        curve = PerpMeCurve(c);
    }

    function _curveBuy(PerpMeCurve curve, address who, uint256 amount) internal {
        vm.startPrank(who);
        IERC20(WNVDAX).approve(address(curve), type(uint256).max);
        curve.buy(amount, 0);
        vm.stopPrank();
    }

    /// Three holders, then the rest of the curve bought out: a graduated coin.
    function _graduated(uint256 dex) internal returns (PerpMeTaxToken coin, PerpMeCurve curve) {
        (coin, curve) = _launch(dex);
        _curveBuy(curve, alice, 10e18);
        _curveBuy(curve, bob, 10e18);
        _curveBuy(curve, carol, 5e18);
        _curveBuy(curve, alice, 60e18); // clears the curve
        assertTrue(curve.graduated(), "graduated");
    }

    /// A fee-on-transfer-style sale straight into the pair, as any router does.
    function _sellIntoPair(PerpMeTaxToken coin, address who, uint256 amount) internal returns (uint256 out) {
        address pair = coin.pair();
        vm.prank(who);
        IERC20(address(coin)).transfer(pair, amount);
        bool coinIs0 = ILivePair(pair).token0() == address(coin);
        uint256 rIn;
        uint256 rOut;
        if (_isV2(pair)) {
            (uint112 a, uint112 b,) = IV2Pair(pair).getReserves();
            (rIn, rOut) = coinIs0 ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
            uint256 amountIn = IERC20(address(coin)).balanceOf(pair) - rIn;
            out = (amountIn * 9970 * rOut) / (rIn * 10000 + amountIn * 9970);
        } else {
            (uint256 a, uint256 b,) = ILivePair(pair).getReserves();
            rIn = coinIs0 ? a : b;
            out = ILivePair(pair).getAmountOut(IERC20(address(coin)).balanceOf(pair) - rIn, address(coin));
        }
        (uint256 o0, uint256 o1) = coinIs0 ? (uint256(0), out) : (out, uint256(0));
        ILivePair(pair).swap(o0, o1, who, "");
    }

    function _isV2(address pair) internal view returns (bool) {
        (bool ok,) = pair.staticcall(abi.encodeWithSignature("observationLength()"));
        return !ok;
    }

    function _buyFromPair(PerpMeTaxToken coin, address who, uint256 quoteIn) internal {
        address pair = coin.pair();
        vm.prank(who);
        IERC20(WNVDAX).transfer(pair, quoteIn);
        bool coinIs0 = ILivePair(pair).token0() == address(coin);
        uint256 out;
        if (_isV2(pair)) {
            (uint112 a, uint112 b,) = IV2Pair(pair).getReserves();
            (uint256 rIn, uint256 rOut) = coinIs0 ? (uint256(b), uint256(a)) : (uint256(a), uint256(b));
            out = (quoteIn * 9970 * rOut) / (rIn * 10000 + quoteIn * 9970);
        } else {
            out = ILivePair(pair).getAmountOut(quoteIn, WNVDAX);
        }
        (uint256 o0, uint256 o1) = coinIs0 ? (out, uint256(0)) : (uint256(0), out);
        ILivePair(pair).swap(o0, o1, who, "");
    }

    function _pass(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs);
    }

    // ----------------------------------------------------------- scenarios --

    /**
     * A Ramses coin nobody trades after graduation still sells its tax.
     *
     * The pair holds one observation at graduation, and the coin refuses to
     * sell with fewer than two. Ramses writes the next one when reserves update
     * more than half an hour after the last — which the pair's public `sync()`
     * does as well as a trade. This is the path the dividend bot takes.
     */
    function test_ARamsesCoinNobodyTradesSellsItsTaxAfterASync() public {
        (PerpMeTaxToken coin,) = _graduated(RAMSES);
        address pair = coin.pair();
        // Tax accrues from trades straight after graduation, inside the first period.
        _buyFromPair(coin, bob, 30e18);
        _sellIntoPair(coin, carol, IERC20(address(coin)).balanceOf(carol) / 2);
        uint256 pile = IERC20(address(coin)).balanceOf(address(coin));
        assertGt(pile, 0, "tax accrued");
        assertEq(ILivePair(pair).observationLength(), 1, "one observation only");

        _pass(10 minutes);
        coin.liquidate();
        assertEq(IERC20(address(coin)).balanceOf(address(coin)), pile, "refused with one observation");

        _pass(25 minutes); // 35 minutes since graduation
        ILivePair(pair).sync(); // anyone; moves nothing
        assertEq(ILivePair(pair).observationLength(), 2, "sync wrote the second point");

        uint256 deposited = coin.distributor().totalDeposited();
        _pass(1);
        coin.liquidate();
        assertLt(IERC20(address(coin)).balanceOf(address(coin)), pile, "and now it sells");
        assertGt(coin.distributor().totalDeposited(), deposited, "into the holders' pot");
    }

    /// A holder who sells everything keeps what they earned, and anyone can
    /// deliver it to them.
    function test_AHolderWhoSellsEverythingIsStillPaid() public {
        (PerpMeTaxToken coin,) = _graduated(PRJX);
        PerpMeDividendDistributor dist = coin.distributor();

        for (uint256 i; i < 4; ++i) {
            _pass(6 minutes);
            _buyFromPair(coin, bob, 5e18);
            _sellIntoPair(coin, alice, IERC20(address(coin)).balanceOf(alice) / 10);
        }
        uint256 owed = dist.claimable(carol);
        assertGt(owed, 0, "carol earned something");

        uint256 all = IERC20(address(coin)).balanceOf(carol);
        _sellIntoPair(coin, carol, all);
        assertEq(IERC20(address(coin)).balanceOf(carol), 0, "she left");
        assertGe(dist.claimable(carol), owed, "and kept what she was owed");

        uint256 before = IERC20(WNVDAX).balanceOf(carol);
        uint256 due = dist.claimable(carol);
        vm.prank(address(0xBEEF));
        dist.claimFor(carol);
        assertEq(IERC20(WNVDAX).balanceOf(carol) - before, due, "a stranger delivered it to her");
        assertEq(dist.claimable(carol), 0);
    }

    /**
     * PRJX's own V2 router — the one wallets and aggregators use — can trade a
     * graduated coin both ways with its fee-on-transfer entry point. The plain
     * `swapExactTokensForTokens` sale reverts, which is what scanners simulate
     * and report as "sell tax 100%": pinned here so the reason stays on record.
     */
    function test_PrjxRouterTradesTheCoinWithItsFeeOnTransferEntryPoint() public {
        (PerpMeTaxToken coin,) = _graduated(PRJX);
        address[] memory buyPath = new address[](2);
        buyPath[0] = WNVDAX;
        buyPath[1] = address(coin);
        address[] memory sellPath = new address[](2);
        sellPath[0] = address(coin);
        sellPath[1] = WNVDAX;

        vm.startPrank(bob);
        IERC20(WNVDAX).approve(PRJX_V2_ROUTER, type(uint256).max);
        IERC20(address(coin)).approve(PRJX_V2_ROUTER, type(uint256).max);
        uint256 coinsBefore = IERC20(address(coin)).balanceOf(bob);
        IV2Router(PRJX_V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            2e18, 1, buyPath, bob, block.timestamp
        );
        uint256 bought = IERC20(address(coin)).balanceOf(bob) - coinsBefore;
        assertGt(bought, 0, "bought through PRJX's router");

        uint256 quoteBefore = IERC20(WNVDAX).balanceOf(bob);
        IV2Router(PRJX_V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            bought, 1, sellPath, bob, block.timestamp
        );
        assertGt(IERC20(WNVDAX).balanceOf(bob), quoteBefore, "and sold back through it");

        uint256 some = IERC20(address(coin)).balanceOf(bob) / 10;
        vm.expectRevert();
        IV2Router(PRJX_V2_ROUTER).swapExactTokensForTokens(some, 1, sellPath, bob, block.timestamp);
        vm.stopPrank();
    }

    /**
     * A dump into the pool does not drag the tax down with it: the coin refuses
     * to sell while the pool quotes under a fifth of its average, and sells
     * again once the price has recovered.
     */
    function test_TheTaxIsNotSoldIntoACrash() public {
        (PerpMeTaxToken coin,) = _graduated(PRJX);
        // Start the average, then let it settle.
        _pass(6 minutes);
        _sellIntoPair(coin, bob, IERC20(address(coin)).balanceOf(bob) / 20);
        _pass(6 minutes);
        _buyFromPair(coin, carol, 2e18);
        _pass(6 minutes);
        coin.liquidate();

        // Accrue a pile, then crash the pool: sell nearly everything the whale has.
        uint256 whale = IERC20(address(coin)).balanceOf(alice); // read before the prank, not inside it
        vm.prank(alice);
        IERC20(address(coin)).transfer(bob, whale);
        _pass(1);
        _sellIntoPair(coin, bob, IERC20(address(coin)).balanceOf(bob));
        uint256 pile = IERC20(address(coin)).balanceOf(address(coin));
        assertGt(pile, 0, "the crash itself was taxed");

        _pass(1);
        coin.liquidate();
        assertEq(IERC20(address(coin)).balanceOf(address(coin)), pile, "no sale into the crash");
    }

    /// The owner can only LOWER a live coin's tax, never below 1%, and both
    /// the curve and the pair charge the new rate at once.
    function test_TheOwnerCanOnlyLowerALiveCoinsTax() public {
        (PerpMeTaxToken coin, PerpMeCurve curve) = _launch(PRJX);

        vm.expectRevert();
        coin.lowerTax(500, 400); // up
        vm.expectRevert();
        coin.lowerTax(50, 50); // under 1%
        vm.prank(creator);
        vm.expectRevert();
        coin.lowerTax(100, 100); // not the owner

        coin.lowerTax(100, 200);
        assertEq(coin.buyTaxBps(), 100);
        assertEq(coin.sellTaxBps(), 200);

        uint256 dist = IERC20(WNVDAX).balanceOf(address(coin.distributor()));
        uint256 treasuryBefore = IERC20(WNVDAX).balanceOf(treasury);
        _curveBuy(curve, alice, 10e18);
        // 1.5% fee + 1% tax, of which the protocol takes 20%; alice is the only
        // buyer so the holders' slice goes to the protocol too, the creator's to the creator.
        uint256 tax = 0.1e18;
        uint256 toCreator = ((tax - tax / 5) * 2000) / 7000;
        assertApproxEqAbs(IERC20(WNVDAX).balanceOf(treasury) - treasuryBefore, 0.15e18 + tax - toCreator, 2, "curve charged 1%");
        assertEq(IERC20(WNVDAX).balanceOf(address(coin.distributor())), dist, "nothing parked");
    }

    /**
     * Excluding a holder stops new dividends and nothing else; `reclaim` only
     * touches an address that has held nothing for ten days, and hands its
     * money to the holders who stayed.
     */
    function test_ExclusionAndReclaimOnALiveCoin() public {
        (PerpMeTaxToken coin,) = _graduated(RAMSES);
        PerpMeDividendDistributor dist = coin.distributor();
        address pair = coin.pair();

        // Build history and a first dividend.
        for (uint256 i; i < 3; ++i) {
            _pass(31 minutes);
            _buyFromPair(coin, bob, 3e18);
            _sellIntoPair(coin, alice, IERC20(address(coin)).balanceOf(alice) / 20);
        }
        assertGt(ILivePair(pair).observationLength(), 1);
        uint256 carolOwed = dist.claimable(carol);
        assertGt(carolOwed, 0, "carol has earned");

        dist.setExcluded(carol, true);
        assertEq(dist.claimable(carol), carolOwed, "exclusion took nothing");
        (uint256 shares,,,,,) = dist.accounts(carol);
        assertEq(shares, 0, "but she earns nothing new");

        // Carol leaves; ten days later her unclaimed dividend goes to the others.
        uint256 hers = IERC20(address(coin)).balanceOf(carol);
        vm.prank(carol);
        IERC20(address(coin)).transfer(address(0xD00D), hers);
        address[] memory one = new address[](1);
        one[0] = carol;
        vm.expectRevert();
        dist.reclaim(one);

        _pass(10 days + 1);
        uint256 bobBefore = dist.claimable(bob);
        uint256 got = dist.reclaim(one);
        assertEq(got, carolOwed, "all of it");
        assertEq(dist.claimable(carol), 0);
        assertGt(dist.claimable(bob), bobBefore, "to the holders who stayed");
        assertEq(dist.unattributed(), 0, "nothing left for anyone to take");
    }

    /// `rescueTax` does nothing to a coin whose sale works, however long it
    /// has gone without one: it sells instead and rescues nothing.
    function test_RescueTaxRefusesAHealthyCoin() public {
        (PerpMeTaxToken coin,) = _graduated(PRJX);
        _pass(6 minutes);
        _sellIntoPair(coin, bob, IERC20(address(coin)).balanceOf(bob) / 10);
        _pass(6 minutes);
        _sellIntoPair(coin, bob, IERC20(address(coin)).balanceOf(bob) / 10);

        vm.expectRevert(PerpMeTaxToken.LiquidationNotStalled.selector);
        coin.rescueTax(address(this));

        _pass(3 days + 1);
        uint256 pile = IERC20(address(coin)).balanceOf(address(coin));
        uint256 mine = IERC20(address(coin)).balanceOf(address(this));
        assertEq(coin.rescueTax(address(this)), 0, "nothing rescued");
        assertEq(IERC20(address(coin)).balanceOf(address(this)), mine, "not a coin to the owner");
        if (pile > 0) {
            assertLt(IERC20(address(coin)).balanceOf(address(coin)), pile, "it sold instead");
        }
    }

    /// Transfers between wallets are untaxed and move dividend shares with them.
    function test_WalletToWalletMovesSharesWithoutTax() public {
        (PerpMeTaxToken coin,) = _graduated(PRJX);
        PerpMeDividendDistributor dist = coin.distributor();
        uint256 pile = IERC20(address(coin)).balanceOf(address(coin));
        uint256 amount = IERC20(address(coin)).balanceOf(bob) / 2;

        vm.prank(bob);
        IERC20(address(coin)).transfer(address(0xF00D), amount);

        assertEq(IERC20(address(coin)).balanceOf(address(0xF00D)), amount, "arrived whole");
        assertEq(IERC20(address(coin)).balanceOf(address(coin)), pile, "no tax taken");
        (uint256 shares,,,,,) = dist.accounts(address(0xF00D));
        assertEq(shares, amount, "and it earns from now on");
        (uint256 pairShares,,,,,) = dist.accounts(coin.pair());
        assertEq(pairShares, 0, "the pool never does");
        assertEq(IERC20(coin.pair()).balanceOf(DEAD), IERC20(coin.pair()).totalSupply() - IERC20(coin.pair()).balanceOf(address(0)), "LP burned");
    }
}
