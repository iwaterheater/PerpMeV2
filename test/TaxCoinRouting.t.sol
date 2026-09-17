// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForkPin} from "./ForkPin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpMeTaxFactory} from "../src/tax/PerpMeTaxFactory.sol";
import {PerpMeTaxTokenDeployer} from "../src/tax/PerpMeTaxTokenDeployer.sol";
import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeCurve} from "../src/tax/PerpMeCurve.sol";
import {PerpMeMarketRouter} from "../src/tax/PerpMeMarketRouter.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

/// @dev PRJX's V2 router. Only the fee-on-transfer variants are usable here:
///      the plain ones size the swap from the amount SENT, and a dividend coin
///      keeps a cut of it, so the pair's invariant refuses the trade.
interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/**
 * How a GRADUATED dividend coin is actually traded from the site.
 *
 * The coin ends up in a PRJX V2 pair against a tokenised share, and the
 * interesting case is a buyer holding HYPE: the trade has to cross a V3 pool
 * to reach the share and then the V2 pair to reach the coin.
 *
 * That used to be written here as one `multicall` on SwapRouter02, which was
 * fiction twice over — PRJX deploys the CLASSIC SwapRouter, whose bytecode
 * does not contain `swapExactTokensForTokens` at all, and the bridge went
 * through two token addresses that have no code on this chain. Neither could
 * ever have run, and the suite hid it by skipping itself.
 *
 * What is true: no single router on HyperEVM can carry this journey, so it
 * takes a contract of our own. These tests are the proof of both halves.
 */
contract TaxCoinRoutingTest is Test {
    /* PRJX, verified on chain 999. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    /// @dev Classic SwapRouter — `exactInput` takes a deadline, and there is no
    ///      V2 leg on it. Confirmed by selector against the deployed code.
    address constant SWAP_ROUTER = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;

    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
    /// @dev The only pool HYPE reaches wNVDAx through. We opened it; there was
    ///      none, and there is still no V2 pair for the two.
    uint24 constant BRIDGE_FEE = 10000;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;

    PerpMeTaxFactory factory;
    PerpMeTaxTokenDeployer deployer;
    PerpMeMarketRouter market;
    address coin;
    address curve;
    address pair;

    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);

    PerpMeUniV2Venue venue;

    function setUp() public {
        ForkPin.select();

        venue = new PerpMeUniV2Venue(V2_FACTORY, 30);
        market = new PerpMeMarketRouter(SWAP_ROUTER, WHYPE);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        deployer = new PerpMeTaxTokenDeployer(predicted);
        factory = new PerpMeTaxFactory(address(deployer), treasury, 0, 2000);

        factory.addDexConfig(venue, "prjx-v2");

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

        vm.prank(creator);
        (coin, curve) = factory.launchToken(
            PerpMeTaxFactory.LaunchParams({
                name: "Routed Cat",
                symbol: "RCAT",
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
            0,
            bytes32(0),
            0,
            0
        );

        // Buy the curve out so the coin graduates into a real pair.
        deal(WNVDAX, trader, 100_000e18);
        vm.startPrank(trader);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(60e18, 0);
        vm.stopPrank();

        pair = PerpMeCurve(curve).pair();
        assertTrue(pair != address(0), "graduated in setUp");
    }

    /// The bridge, exactly as `web/lib/routes.ts` builds it: ONE hop.
    function _nativeToShare() internal pure returns (bytes memory) {
        return abi.encodePacked(WHYPE, BRIDGE_FEE, WNVDAX);
    }

    function _shareToNative() internal pure returns (bytes memory) {
        return abi.encodePacked(WNVDAX, BRIDGE_FEE, WHYPE);
    }

    // -------------------------------------------------------------------------

    /**
     * The finding this suite exists to pin down: PRJX's router cannot do it.
     *
     * Not "does it badly" — the function is not there. Calling a selector a
     * contract does not implement lands on the fallback, and this one has none,
     * so it reverts with no reason string after a couple of hundred gas. That
     * is why the old version of these tests could never have passed.
     */
    function test_ThePrjxRouterHasNoV2Leg() public view {
        bytes4 sel = bytes4(keccak256("swapExactTokensForTokens(uint256,uint256,address[],address)"));
        bytes memory code = SWAP_ROUTER.code;
        bool found;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (
                code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2]
                    && code[i + 3] == sel[3]
            ) {
                found = true;
                break;
            }
        }
        assertFalse(found, "SwapRouter02's V2 leg is absent from PRJX's classic router");
    }

    /// And there is no V2 pair to route HYPE to the share through either, so
    /// the bridge cannot be folded into the V2 router's own multi-hop.
    function test_TheBridgeExistsOnlyOnV3() public view {
        assertEq(
            PerpMeUniV2Venue(address(venue)).FACTORY().getPair(WHYPE, WNVDAX),
            address(0),
            "no V2 pair for the bridge"
        );
    }

    // -------------------------------------------------------------------------

    /// Holding the share already: one V2 hop, through the fee-on-transfer call.
    function test_BuyWithTheShareDirectly() public {
        deal(WNVDAX, trader, 100e18);
        address[] memory path = new address[](2);
        path[0] = WNVDAX;
        path[1] = coin;

        uint256 before = IERC20(coin).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IUniswapV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            10e18, 0, path, trader, block.timestamp
        );
        vm.stopPrank();

        assertGt(IERC20(coin).balanceOf(trader) - before, 0, "coins arrived");
    }

    /// The pair token through our router too, so the site has ONE address for
    /// a graduated coin on any exchange — and nothing pauses in the router.
    function test_BuyAndSellWithTheShareThroughTheMarketRouter() public {
        deal(WNVDAX, trader, 100e18);
        vm.startPrank(trader);
        IERC20(WNVDAX).approve(address(market), type(uint256).max);
        uint256 before = IERC20(coin).balanceOf(trader);
        uint256 bought = market.buy(PerpMeTaxToken(payable(coin)), 10e18, 0);
        assertGt(bought, 0, "the share bought coins");
        assertEq(IERC20(coin).balanceOf(trader) - before, bought, "onto the buyer");

        IERC20(coin).approve(address(market), type(uint256).max);
        uint256 shareBefore = IERC20(WNVDAX).balanceOf(trader);
        uint256 got = market.sell(PerpMeTaxToken(payable(coin)), bought / 2, 0);
        vm.stopPrank();
        assertGt(got, 0, "and half went back to the share");
        assertEq(IERC20(WNVDAX).balanceOf(trader) - shareBefore, got, "straight to the seller");
        assertEq(IERC20(WNVDAX).balanceOf(address(market)), 0, "the router held no share");
        assertEq(IERC20(coin).balanceOf(address(market)), 0, "and no coins");

        (uint256 share,,,,,) =
            PerpMeTaxToken(payable(coin)).distributor().accounts(address(market));
        assertEq(share, 0, "and never became a holder");
    }

    /// The pair-token guard counts the tax the same way the native one does.
    function test_ThePairTokenGuardCountsTheTax() public {
        deal(WNVDAX, trader, 100e18);
        vm.startPrank(trader);
        IERC20(WNVDAX).approve(address(market), type(uint256).max);
        uint256 quoted = market.buy(PerpMeTaxToken(payable(coin)), 10e18, 0);
        vm.expectRevert();
        market.buy(PerpMeTaxToken(payable(coin)), 10e18, quoted * 2);
        vm.stopPrank();
    }

    /// The case that decides whether this product is reachable: paying in HYPE,
    /// V3 then V2, in one transaction, through our own router.
    function test_BuyWithNativeAcrossV3ThenV2() public {
        vm.deal(trader, 10 ether);

        uint256 before = IERC20(coin).balanceOf(trader);
        vm.prank(trader);
        uint256 out = market.buyWithNative{value: 1 ether}(
            PerpMeTaxToken(payable(coin)), _nativeToShare(), 0
        );

        assertGt(out, 0, "HYPE reached the coin in one tx");
        assertEq(IERC20(coin).balanceOf(trader) - before, out, "and the buyer is the one holding it");
        assertEq(trader.balance, 9 ether, "exactly the HYPE offered was spent");
        assertEq(IERC20(WNVDAX).balanceOf(address(market)), 0, "the router kept no share");
        assertEq(IERC20(coin).balanceOf(address(market)), 0, "and no coins");
    }

    /// The slippage guard is measured on what the buyer ends up with, so the
    /// buy tax is inside the number rather than underneath it.
    function test_TheBuyGuardCountsTheTax() public {
        vm.deal(trader, 10 ether);

        uint256 quoted = 0;
        vm.prank(trader);
        quoted = market.buyWithNative{value: 1 ether}(
            PerpMeTaxToken(payable(coin)), _nativeToShare(), 0
        );

        vm.deal(trader, 10 ether);
        vm.prank(trader);
        vm.expectRevert();
        market.buyWithNative{value: 1 ether}(
            PerpMeTaxToken(payable(coin)), _nativeToShare(), quoted * 2
        );
    }

    /// And back out again: coin to HYPE, V2 first and then the bridge reversed.
    function test_SellToNativeAcrossV2ThenV3() public {
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        market.buyWithNative{value: 2 ether}(PerpMeTaxToken(payable(coin)), _nativeToShare(), 0);

        uint256 held = IERC20(coin).balanceOf(trader);
        uint256 before = trader.balance;

        vm.startPrank(trader);
        IERC20(coin).approve(address(market), type(uint256).max);
        uint256 got = market.sellToNative(
            PerpMeTaxToken(payable(coin)), held / 2, _shareToNative(), 0
        );
        vm.stopPrank();

        assertGt(got, 0, "the seller got HYPE back");
        assertEq(trader.balance - before, got, "and it landed in their own balance");
        assertEq(address(market).balance, 0, "the router kept none of it");
        assertEq(IERC20(WNVDAX).balanceOf(address(market)), 0, "nor any share");
    }

    /// The tax is still collected on both legs — routing does not dodge it.
    function test_RoutingDoesNotBypassTheTax() public {
        vm.deal(trader, 10 ether);

        uint256 heldByCoin = IERC20(coin).balanceOf(coin);
        vm.prank(trader);
        market.buyWithNative{value: 1 ether}(PerpMeTaxToken(payable(coin)), _nativeToShare(), 0);
        uint256 afterBuy = IERC20(coin).balanceOf(coin);
        assertGt(afterBuy - heldByCoin, 0, "the coin kept its cut of the buy");

        uint256 held = IERC20(coin).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(coin).approve(address(market), type(uint256).max);
        market.sellToNative(PerpMeTaxToken(payable(coin)), held / 2, _shareToNative(), 0);
        vm.stopPrank();

        assertGt(IERC20(coin).balanceOf(coin), afterBuy, "and its cut of the sell");
    }

    /// The router is nobody's holder: it earns no dividends on the way through.
    function test_TheRouterNeverBecomesAShareholder() public {
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        market.buyWithNative{value: 1 ether}(PerpMeTaxToken(payable(coin)), _nativeToShare(), 0);

        (uint256 share,,,,,) =
            PerpMeTaxToken(payable(coin)).distributor().accounts(address(market));
        assertEq(share, 0, "the router holds no dividend share");
    }
}
