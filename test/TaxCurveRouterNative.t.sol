// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkPin} from "./ForkPin.sol";
import {PerpMeTaxFactory} from "../src/tax/PerpMeTaxFactory.sol";
import {PerpMeTaxTokenDeployer} from "../src/tax/PerpMeTaxTokenDeployer.sol";
import {PerpMeCurve} from "../src/tax/PerpMeCurve.sol";
import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeCurveRouter} from "../src/tax/PerpMeCurveRouter.sol";
import {PerpMeBridge} from "../src/tax/PerpMeBridge.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

/**
 * A coin quoted in HYPE, bought and sold with HYPE through the curve router.
 *
 * Found on devtest 2026-09-13: the router could not do it — an empty bridge
 * went to PRJX's router and reverted — so the site fell back to the curve's
 * own `buy`, which pulls WHYPE, while telling the buyer to pay HYPE.
 */
contract TaxCurveRouterNativeTest is Test {
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant SWAP_ROUTER = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;

    PerpMeTaxFactory factory;
    PerpMeCurveRouter router;
    PerpMeCurve curve;
    address coin;
    address buyer = address(0xB0B);

    function setUp() public {
        ForkPin.select();

        PerpMeUniV2Venue venue = new PerpMeUniV2Venue(V2_FACTORY, 30);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        PerpMeTaxTokenDeployer deployer = new PerpMeTaxTokenDeployer(predicted);
        factory = new PerpMeTaxFactory(address(deployer), address(0x7EA), 0, 2000);
        factory.addDexConfig(venue, "prjx-v2");
        factory.addLaunchConfig(
            PerpMeTaxFactory.LaunchConfig({
                dexId: 0,
                pairToken: WHYPE,
                totalSupply: 1_000_000_000e18,
                enabled: true,
                virtualToken: 1_073_000_000e18,
                virtualQuote: 38.4e18,
                curveTokens: 793_100_000e18,
                curveFeeBps: 150
            })
        );
        router = new PerpMeCurveRouter(SWAP_ROUTER, WHYPE);
        factory.setCurveRouter(address(router));

        address c;
        vm.prank(address(0xC0FFEE));
        (coin, c) = factory.launchToken(
            PerpMeTaxFactory.LaunchParams({
                name: "Native Cat",
                symbol: "NCAT",
                metadataURI: "",
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
        curve = PerpMeCurve(c);
        vm.deal(buyer, 1_000 ether);
    }

    function test_BuysAndSellsAHypeQuotedCoinWithHype() public {
        vm.startPrank(buyer);
        uint256 hypeBefore = buyer.balance;
        uint256 got = router.buyWithNative{value: 2 ether}(curve, "", 1, 0);
        assertGt(got, 0, "coins for HYPE");
        assertEq(hypeBefore - buyer.balance, 2 ether, "spent exactly what was sent");
        assertEq(IERC20(WHYPE).balanceOf(address(router)), 0, "nothing parked in the router");

        uint256 half = IERC20(coin).balanceOf(buyer) / 2;
        IERC20(coin).approve(address(router), half);
        uint256 before = buyer.balance;
        uint256 back = router.sellToNative(curve, half, "", 1);
        vm.stopPrank();

        assertGt(back, 0, "HYPE back");
        assertEq(buyer.balance - before, back, "HYPE, not WHYPE, arrived");
        // The only WHYPE the buyer holds is dividends, which ARE paid in WHYPE.
        assertEq(
            IERC20(WHYPE).balanceOf(buyer),
            PerpMeTaxToken(payable(coin)).distributor().totalClaimed(),
            "no WHYPE beyond the dividends"
        );
    }

    /// Overpaying the last fill spends only what the curve needs and returns the rest.
    function test_FillingTheCurveReturnsTheChange() public {
        uint256 need = curve.quoteToFill();
        vm.prank(buyer);
        router.buyWithNative{value: need + 50 ether}(curve, "", 1, 0);

        assertTrue(curve.graduated(), "graduated");
        assertEq(1_000 ether - buyer.balance, need, "paid exactly the fill");
    }

    /// The cap binds on this arm too.
    function test_TheCapBinds() public {
        vm.prank(buyer);
        router.buyWithNative{value: 10 ether}(curve, "", 1, 3 ether);
        assertEq(1_000 ether - buyer.balance, 3 ether, "spent the cap, not msg.value");
    }

    /// A HYPE-quoted coin takes no bridge: a path here is refused, not ignored.
    function test_APathIsRefusedForAHypeQuotedCoin() public {
        vm.prank(buyer);
        vm.expectRevert(PerpMeBridge.BridgeRefused.selector);
        router.buyWithNative{value: 1 ether}(curve, abi.encodePacked(WHYPE, uint24(500), USDC), 1, 0);
    }
}
