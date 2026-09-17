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
import {PerpMeMarketRouter} from "../src/tax/PerpMeMarketRouter.sol";
import {PerpMeRamsesVenue} from "../src/tax/venue/PerpMeRamsesVenue.sol";

interface ISolidlyPairLike {
    function token0() external view returns (address);
    function getReserves() external view returns (uint256, uint256, uint256);
    function getAmountOut(uint256, address) external view returns (uint256);
    function swap(uint256, uint256, address, bytes calldata) external;
    function stable() external view returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function observationLength() external view returns (uint256);
}

/**
 * A dividend coin's whole life on Ramses, against the real Ramses on a fork.
 *
 * The venue adapter is tested on its own elsewhere. This is the question that
 * one cannot answer: whether a coin launched through the factory actually
 * graduates onto a Solidly pair, burns its LP there, and then sells its tax
 * into it and pays holders — with none of the coin's own code knowing which
 * exchange it ended up on.
 */
contract TaxOnRamsesTest is Test {
    address constant RAMSES_FACTORY = 0xd0a07E160511c40ccD5340e94660E9C9c01b0D27;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
    address constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    /* The bridge that turns HYPE into the share does NOT move with the coin.
       It lives on PRJX V3 whichever exchange the coin graduated onto, because
       that is where the WHYPE/wNVDAx liquidity is — a 1% pool we opened, and
       still the only one anywhere on this chain. */
    address constant SWAP_ROUTER = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    uint24 constant BRIDGE_FEE = 10000;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;
    uint256 constant LAUNCH_FEE = 0;

    PerpMeTaxFactory factory;
    PerpMeTaxTokenDeployer deployer;
    PerpMeRamsesVenue venue;

    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        ForkPin.select();

        venue = new PerpMeRamsesVenue(RAMSES_FACTORY);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        deployer = new PerpMeTaxTokenDeployer(predicted);
        factory = new PerpMeTaxFactory(address(deployer), treasury, LAUNCH_FEE, 2000);
        assertEq(address(factory), predicted, "nonce prediction held");

        factory.addDexConfig(venue, "ramses-legacy");
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

        deal(WNVDAX, creator, 5_000e18);
        deal(WNVDAX, alice, 5_000e18);
        deal(WNVDAX, bob, 5_000e18);
    }

    function _launch() internal returns (address token, address curve) {
        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        (token, curve) = factory.launchToken{value: LAUNCH_FEE}(
            PerpMeTaxFactory.LaunchParams({
                name: "Ramses Dividend Cat",
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
        vm.stopPrank();
    }

    /// The pair is opened on Ramses at launch, on the volatile curve, and the
    /// coin is told about it before anybody can trade.
    function test_launchOpensARamsesPair() public {
        (address token,) = _launch();
        address reserved = PerpMeTaxToken(token).reservedPair();

        assertTrue(reserved != address(0), "a pair address was reserved");
        assertGt(reserved.code.length, 0, "and the pair really exists");
        assertFalse(ISolidlyPairLike(reserved).stable(), "volatile, not stable");
        assertEq(
            address(PerpMeTaxToken(token).venue()), address(venue), "the coin holds the venue"
        );
    }

    /// Buying the curve out graduates the coin into that pair and burns the LP.
    function test_graduationSeedsRamsesAndBurnsTheLp() public returns (address, address) {
        (address token, address curve) = _launch();
        address pair = PerpMeTaxToken(token).reservedPair();

        vm.startPrank(alice);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(60e18, 0);
        vm.stopPrank();

        assertTrue(PerpMeCurve(curve).graduated(), "the curve sold out");
        assertEq(PerpMeTaxToken(token).pair(), pair, "and the coin was told where it lives");
        assertGt(IERC20(token).balanceOf(pair), 0, "coins went into the Ramses pair");
        assertGt(IERC20(WNVDAX).balanceOf(pair), 0, "and everything raised with them");
        assertGt(
            ISolidlyPairLike(pair).balanceOf(BURN_SINK), 0, "the LP was burned, not held"
        );
        assertEq(IERC20(WNVDAX).balanceOf(curve), 0, "the curve kept nothing");
        return (token, pair);
    }

    /**
     * The tax sells into a Solidly pair and reaches holders.
     *
     * The coin works out nothing about Ramses' fee — this pair charges whatever
     * their factory gave it — and the sale still clears the pair's invariant,
     * which is the only thing that proves the venue is really being asked.
     */
    function test_taxLiquidatesIntoRamsesAndPaysHolders() public {
        (address token, address pair) = test_graduationSeedsRamsesAndBurnsTheLp();
        PerpMeDividendDistributor dist = PerpMeTaxToken(token).distributor();

        /* Half an hour between trades, because that is how a Solidly pair
           builds a price history: it records an observation when a trade
           crosses a period boundary, not on every trade. Trading faster than
           that leaves the pair with nothing to average and was how this test
           first failed. The step is a little over the half hour rather than
           exactly it: the pair pushes when MORE than a period has elapsed, so
           landing precisely on the boundary never crosses it. */
        for (uint256 i; i < 4; i++) {
            vm.warp(block.timestamp + 1900);
            _sellIntoPair(alice, token, pair, IERC20(token).balanceOf(alice) / 40);
        }

        assertGt(
            ISolidlyPairLike(pair).observationLength(), 1, "the pair recorded a history"
        );
        assertGt(dist.totalDeposited(), 0, "holders were funded in the pair token");
        assertLt(
            IERC20(token).balanceOf(token),
            IERC20(token).totalSupply() / 100,
            "the tax did not simply pile up"
        );
    }

    /**
     * Buying a Ramses-graduated coin with HYPE, and selling it back.
     *
     * The same `PerpMeMarketRouter` that carries a PRJX coin, unchanged and
     * pointed at nothing Ramses-specific: it asks the coin which venue it
     * graduated onto and lets that venue price the swap. A Solidly pair charges
     * a fee this contract never learns and settles on a curve it never
     * implements, and the trade still clears the pair's own invariant — which
     * is the whole point of the venue being a contract.
     */
    function test_nativeBuyAndSellThroughTheMarketRouter() public {
        (address token,) = test_graduationSeedsRamsesAndBurnsTheLp();
        PerpMeMarketRouter market = new PerpMeMarketRouter(SWAP_ROUTER, WHYPE);

        bytes memory bridgeIn = abi.encodePacked(WHYPE, BRIDGE_FEE, WNVDAX);
        bytes memory bridgeOut = abi.encodePacked(WNVDAX, BRIDGE_FEE, WHYPE);

        vm.deal(bob, 10 ether);
        vm.prank(bob);
        uint256 coinsOut =
            market.buyWithNative{value: 1 ether}(PerpMeTaxToken(payable(token)), bridgeIn, 0);

        assertGt(coinsOut, 0, "HYPE reached a Ramses-quoted coin");
        assertEq(IERC20(token).balanceOf(bob), coinsOut, "and the buyer holds it");
        assertEq(bob.balance, 9 ether, "exactly what was offered was spent");

        uint256 before = bob.balance;
        vm.startPrank(bob);
        IERC20(token).approve(address(market), type(uint256).max);
        uint256 nativeOut = market.sellToNative(
            PerpMeTaxToken(payable(token)), coinsOut / 2, bridgeOut, 0
        );
        vm.stopPrank();

        assertGt(nativeOut, 0, "and it comes back out to HYPE");
        assertEq(bob.balance - before, nativeOut, "into the seller's own balance");
        assertEq(address(market).balance, 0, "the router kept nothing");
        assertEq(IERC20(WNVDAX).balanceOf(address(market)), 0, "no share either");
        assertEq(IERC20(token).balanceOf(address(market)), 0, "and no coins");
    }

    /// @dev A sell straight into the pair: hand it the coins, tell it how much
    ///      to send back. The same narrow conversation the coin's own
    ///      liquidation has with it.
    function _sellIntoPair(address who, address token, address pair, uint256 amount) internal {
        if (amount == 0) return;

        vm.prank(who);
        IERC20(token).transfer(pair, amount);

        /*
         * Priced AFTER the transfer, the way a fee-on-transfer router has to.
         *
         * Quoting first and transferring second is what this test did to begin
         * with, and it failed the pair's own invariant with `K()`. The reason
         * is the product, not the test: the transfer into the pair is what
         * triggers the coin to sell its accrued tax, and that sale moves the
         * reserves before this swap ever runs. So the amount to ask for is
         * whatever the pair is actually holding above its reserves once
         * everything the transfer set off has finished.
         */
        bool coinIsToken0 = ISolidlyPairLike(pair).token0() == token;
        (uint256 r0, uint256 r1,) = ISolidlyPairLike(pair).getReserves();
        uint256 reserveCoin = coinIsToken0 ? r0 : r1;
        uint256 received = IERC20(token).balanceOf(pair) - reserveCoin;
        if (received == 0) return;

        uint256 out = ISolidlyPairLike(pair).getAmountOut(received, token);
        if (out == 0) return;

        (uint256 out0, uint256 out1) = coinIsToken0 ? (uint256(0), out) : (out, uint256(0));
        ISolidlyPairLike(pair).swap(out0, out1, who, "");
    }
}
