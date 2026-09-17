// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Independent audit PoCs (2026-09-10), multi-DEX dividend coin. Each test is a
// finding; the numbers they print are the ones quoted in the report.

import {Test, console2} from "forge-std/Test.sol";
import {ForkPin} from "./ForkPin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpMeTaxFactory} from "../src/tax/PerpMeTaxFactory.sol";
import {PerpMeTaxTokenDeployer} from "../src/tax/PerpMeTaxTokenDeployer.sol";
import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeCurve} from "../src/tax/PerpMeCurve.sol";
import {PerpMeCurveRouter} from "../src/tax/PerpMeCurveRouter.sol";
import {PerpMeDividendDistributor} from "../src/tax/PerpMeDividendDistributor.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";
import {PerpMeRamsesVenue} from "../src/tax/venue/PerpMeRamsesVenue.sol";

interface IV2Factory {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

interface IV2Router {
    function addLiquidity(
        address, address, uint256, uint256, uint256, uint256, address, uint256
    ) external returns (uint256, uint256, uint256);
}

interface IV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

interface ISolidlyPairLike {
    function token0() external view returns (address);
    function getReserves() external view returns (uint256, uint256, uint256);
    function getAmountOut(uint256, address) external view returns (uint256);
    function swap(uint256, uint256, address, bytes calldata) external;
    function observationLength() external view returns (uint256);
    function fees() external view returns (address);
    function communityVault() external view returns (address);
}

interface INestFactory {
    function isPublicPoolCreationMode() external view returns (bool);
    function isPaused() external view returns (bool);
    function hasRole(bytes32, address) external view returns (bool);
    function PAIRS_CREATOR_ROLE() external view returns (bytes32);
}

/// The classic v3-periphery SwapRouter, which is what PRJX actually deployed.
interface ISwapRouterClassic {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256);
}

contract AuditFable51 is Test {
    string constant RPC = "https://rpc.hyperliquid.xyz/evm";

    address constant PRJX_V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant PRJX_V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant PRJX_SWAP_ROUTER = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    address constant RAMSES_FACTORY = 0xd0a07E160511c40ccD5340e94660E9C9c01b0D27;
    address constant NEST_FACTORY = 0x889Fd0aDA8453C7619cD7f11E9029a1f0848Fdf5;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
    address constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;

    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address admin = address(0xAD);

    /// Stands in for the factory in the direct-coin tests (F1).
    function owner() external view returns (address) {
        return admin;
    }

    // -------------------------------------------------------------------------
    //  F1 — FIXED. The 0.5%-of-pool cap was per CALL, not per block, and
    //  `liquidate()` is open to anyone: twenty-four calls cleared in one block
    //  and sold the whole pot into a 20% hole. There is now one sale per block;
    //  the same loop is kept and proves it.
    // -------------------------------------------------------------------------

    function test_F1_LiquidateIsOncePerBlock() public {
        ForkPin.select();
        PerpMeUniV2Venue venue = new PerpMeUniV2Venue(PRJX_V2_FACTORY, 30);

        PerpMeTaxToken coin = new PerpMeTaxToken();
        address pair = IV2Factory(PRJX_V2_FACTORY).createPair(address(coin), WNVDAX);
        coin.initialize(
            PerpMeTaxToken.InitParams({
                name: "Dividend Coin",
                symbol: "DIV",
                metadataURI: "ipfs://x",
                metadataB64: "",
                creator: creator,
                locker: BURN_SINK,
                pairToken: WNVDAX,
                reservedPair: pair,
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
        PerpMeDividendDistributor dist = coin.distributor();

        // The shape a graduated pool has: ~20% of supply against the raise.
        deal(WNVDAX, address(this), 10_000e18);
        coin.approve(PRJX_V2_ROUTER, type(uint256).max);
        IERC20(WNVDAX).approve(PRJX_V2_ROUTER, type(uint256).max);
        IV2Router(PRJX_V2_ROUTER).addLiquidity(
            address(coin), WNVDAX, 200_000_000e18, 42e18, 0, 0, BURN_SINK, block.timestamp
        );
        coin.setPair(pair);

        // A holder, so the dividend has somewhere to go.
        coin.transfer(alice, 10_000_000e18);

        // The pot the live coin actually reached: 2.5% of supply accrued in
        // tax (Starman peaked at 25.2M of 1B). The test contract is the
        // "factory" and therefore excluded, so this lands untaxed.
        coin.transfer(address(coin), 25_000_000e18);
        uint256 pot = coin.balanceOf(address(coin));

        // One honest window so the venue has an average to judge against.
        vm.warp(block.timestamp + 301);
        (uint256 rc0, uint256 rq0) = _reserves(pair, address(coin));

        uint256 calls;
        for (uint256 i; i < 60; i++) {
            uint256 before = coin.balanceOf(address(coin));
            coin.liquidate();
            if (coin.balanceOf(address(coin)) == before) break;
            calls++;
        }
        (uint256 rc1, uint256 rq1) = _reserves(pair, address(coin));

        uint256 price0 = (rq0 * 1e18) / rc0;
        uint256 price1 = (rq1 * 1e18) / rc1;
        uint256 coinsSold = rc1 - rc0;
        uint256 quoteOut = rq0 - rq1;
        uint256 atOpeningPrice = (coinsSold * price0) / 1e18;

        console2.log("liquidate() calls that succeeded in ONE block:", calls);
        console2.log("pot before / after:", pot / 1e18, coin.balanceOf(address(coin)) / 1e18);
        console2.log("pool price drop, bps:", 10_000 - (price1 * 10_000) / price0);
        console2.log(
            "quote received vs same coins at opening price, bps:",
            (quoteOut * 10_000) / atOpeningPrice
        );
        console2.log("funded to holders (wNVDAx wei):", dist.totalDeposited());

        assertEq(calls, 1, "one sale per block, however many times it is asked");
        assertLt(price1, price0, "the pool moved");
        assertLt(price0 * 100, price1 * 102, "but by one capped sale (~0.95%), not by a fifth");
        assertGt(coin.balanceOf(address(coin)), pot * 9 / 10, "the pot is still there");

        // The next block sells again. A campaign, not a transaction.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 beforeNext = coin.balanceOf(address(coin));
        coin.liquidate();
        assertLt(coin.balanceOf(address(coin)), beforeNext, "and the next block sold once more");
    }

    // -------------------------------------------------------------------------
    //  F2 — on a Solidly pair the first tax sale after graduation waits for the
    //  pair's own oracle: one completed 30-minute period with real reserves in
    //  it. Sells inside that window accrue tax and pay nobody; the first sale
    //  after it carries the whole backlog (bounded by the 0.5% cap).
    // -------------------------------------------------------------------------

    function test_F2_SolidlyFirstLiquidationWaitsForAnOraclePeriod() public {
        ForkPin.select();
        (PerpMeTaxFactory factory,) = _factoryOn(new PerpMeRamsesVenue(RAMSES_FACTORY));
        (address token,) = _launchAndGraduate(factory);
        address pair = PerpMeTaxToken(token).pair();
        PerpMeDividendDistributor dist = PerpMeTaxToken(token).distributor();
        uint256 graduatedAt = vm.getBlockTimestamp();
        uint256 fundedAtGraduation = dist.totalDeposited();

        uint256 firstPaidAt;
        for (uint256 i = 1; i <= 24 && firstPaidAt == 0; i++) {
            vm.warp(graduatedAt + i * 300);
            _sellIntoSolidlyPair(alice, token, pair, IERC20(token).balanceOf(alice) / 100);
            if (dist.totalDeposited() != fundedAtGraduation) firstPaidAt = vm.getBlockTimestamp();
            if (i == 6) {
                console2.log("obs at 30 min:", ISolidlyPairLike(pair).observationLength());
                console2.log("tax accrued at 30 min, coins:", IERC20(token).balanceOf(token) / 1e18);
            }
        }
        assertGt(firstPaidAt, 0, "eventually a sale went through");
        console2.log("minutes from graduation to first dividend:", (firstPaidAt - graduatedAt) / 60);
        assertGt(firstPaidAt - graduatedAt, 30 minutes, "nothing sells inside the first period");
    }

    // -------------------------------------------------------------------------
    //  F3 — Nest's pair factory is permissioned. The venue cannot open a pair,
    //  so a launch config pointed at Nest reverts on the first launch.
    // -------------------------------------------------------------------------

    function test_F3_NestWillNotLetTheVenueOpenAPair() public {
        ForkPin.select();
        PerpMeRamsesVenue venue = new PerpMeRamsesVenue(NEST_FACTORY);
        (PerpMeTaxFactory factory,) = _factoryOn(venue);

        INestFactory nest = INestFactory(NEST_FACTORY);
        assertFalse(nest.isPublicPoolCreationMode(), "pair creation is role-gated today");
        assertFalse(
            nest.hasRole(nest.PAIRS_CREATOR_ROLE(), address(venue)), "and the venue has no role"
        );

        vm.startPrank(creator);
        vm.expectRevert();
        factory.launchToken(_params(), 0, bytes32(0), 0, 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    //  F4 — FIXED. On a Velodrome-V1 style fork the pair moves its swap fee OUT
    //  of the pool on every trade, IN THE COIN, to a fee contract and a
    //  community vault. Neither is a market, so the coin counted them as
    //  holders: they earned a share of every dividend with nobody behind them
    //  to claim it, and it sat in `totalDeposited` for good, diluting everyone
    //  real. The venue now names those two addresses and the coin excludes
    //  them when the pair is set; the same walk-through asserts they hold no
    //  shares rather than that they hold some.
    // -------------------------------------------------------------------------

    function test_F4_NestFeeSinkIsNotADividendShareholder() public {
        ForkPin.select();
        _openNestPoolCreation();

        (PerpMeTaxFactory factory,) = _factoryOn(new PerpMeRamsesVenue(NEST_FACTORY));
        (address token,) = _launchAndGraduate(factory);
        address pair = PerpMeTaxToken(token).pair();
        PerpMeDividendDistributor dist = PerpMeTaxToken(token).distributor();

        address feeSink = ISolidlyPairLike(pair).fees();
        address vault;
        try ISolidlyPairLike(pair).communityVault() returns (address v) {
            vault = v;
        } catch {}
        console2.log("pair fees()        ", feeSink);
        console2.log("pair communityVault", vault);

        // Trade for a while, spaced so the pair builds its oracle history.
        uint256 graduatedAt = vm.getBlockTimestamp();
        uint256 fundedAtGraduation = dist.totalDeposited();
        for (uint256 i = 1; i <= 8; i++) {
            vm.warp(graduatedAt + i * 1900);
            _sellIntoSolidlyPair(alice, token, pair, IERC20(token).balanceOf(alice) / 100);
        }
        console2.log("funded after graduation, wei:", dist.totalDeposited() - fundedAtGraduation);
        assertGt(dist.totalDeposited(), fundedAtGraduation, "dividends were funded in the pair");

        address sink = _sharesOf(dist, feeSink) != 0 ? feeSink : vault;
        (uint256 shares,,,,,) = dist.accounts(sink);
        console2.log("fee sink coin balance:", IERC20(token).balanceOf(sink) / 1e18);
        console2.log("fee sink shares:      ", shares / 1e18);
        console2.log("fee sink claimable, wNVDAx wei:", dist.claimable(sink));
        console2.log("total shares:         ", dist.totalShares() / 1e18);

        assertEq(shares, 0, "the fee sink holds no shares");
        assertEq(dist.claimable(sink), 0, "and is owed no dividend it could never claim");

        // The exclusion is the coin's, named from the venue at `setPair` —
        // asserted directly so a venue that stopped answering would be caught
        // here rather than by the absence of a symptom.
        address a = PerpMeTaxToken(payable(token)).feeSinkA();
        address b = PerpMeTaxToken(payable(token)).feeSinkB();
        assertTrue(
            sink == a || sink == b,
            "and the coin knows it as a fee sink rather than merely missing it"
        );
    }

    // -------------------------------------------------------------------------
    //  F5 — FIXED. The curve router used to speak SwapRouter02 to a router that
    //  is the classic SwapRouter, so every HYPE buy on the curve reverted with a
    //  path the classic router itself accepts. The struct now carries the
    //  `deadline` the classic shape wants, and this asserts the trade goes
    //  through rather than that it fails.
    // -------------------------------------------------------------------------

    function test_F5_CurveRouterBridgesThroughPrjx() public {
        ForkPin.select();
        (PerpMeTaxFactory factory,) = _factoryOn(new PerpMeUniV2Venue(PRJX_V2_FACTORY, 30));
        PerpMeCurveRouter router = new PerpMeCurveRouter(PRJX_SWAP_ROUTER, WHYPE);
        factory.setCurveRouter(address(router));

        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        (, address curve) = factory.launchToken(_params(), 0, bytes32(0), 0, 0);
        vm.stopPrank();

        // The one-hop path the site really uses (web/lib/routes.ts: wNVDAx via
        // WHYPE at the 1% tier).
        bytes memory path = abi.encodePacked(WHYPE, uint24(10_000), WNVDAX);

        // The pool is real and the classic router trades it fine.
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        uint256 got = ISwapRouterClassic(PRJX_SWAP_ROUTER).exactInput{value: 0.1 ether}(
            ISwapRouterClassic.ExactInputParams({
                path: path,
                recipient: bob,
                deadline: block.timestamp,
                amountIn: 0.1 ether,
                amountOutMinimum: 0
            })
        );
        assertGt(got, 0, "the classic router bridges HYPE to wNVDAx");

        // And so does the curve router, over the same path.
        uint256 before = IERC20(PerpMeCurve(curve).TOKEN()).balanceOf(bob);
        vm.prank(bob);
        uint256 coins = router.buyWithNative{value: 0.1 ether}(PerpMeCurve(curve), path, 0, 0);
        assertGt(coins, 0, "HYPE bought coins on the curve");
        assertEq(
            IERC20(PerpMeCurve(curve).TOKEN()).balanceOf(bob) - before,
            coins,
            "and they landed on the buyer"
        );
    }

    // -------------------------------------------------------------------------
    //  Helpers
    // -------------------------------------------------------------------------

    function _factoryOn(PerpMeRamsesVenue venue)
        internal
        returns (PerpMeTaxFactory factory, PerpMeTaxTokenDeployer deployer)
    {
        return _factoryOnAddr(address(venue));
    }

    function _factoryOn(PerpMeUniV2Venue venue)
        internal
        returns (PerpMeTaxFactory factory, PerpMeTaxTokenDeployer deployer)
    {
        return _factoryOnAddr(address(venue));
    }

    function _factoryOnAddr(address venue)
        internal
        returns (PerpMeTaxFactory factory, PerpMeTaxTokenDeployer deployer)
    {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        deployer = new PerpMeTaxTokenDeployer(predicted);
        factory = new PerpMeTaxFactory(address(deployer), treasury, 0, 2000);
        assertEq(address(factory), predicted);
        factory.addDexConfig(PerpMeRamsesVenue(venue), "venue");
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
    }

    function _params() internal pure returns (PerpMeTaxFactory.LaunchParams memory) {
        return PerpMeTaxFactory.LaunchParams({
            name: "Dividend Cat",
            symbol: "DCAT",
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

    function _launchAndGraduate(PerpMeTaxFactory factory)
        internal
        returns (address token, address curve)
    {
        vm.startPrank(creator);
        IERC20(WNVDAX).approve(address(factory), type(uint256).max);
        (token, curve) = factory.launchToken(_params(), 0, bytes32(0), 0, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(60e18, 0);
        vm.stopPrank();
        assertTrue(PerpMeCurve(curve).graduated(), "sold out");
    }

    /// Sell straight into a Solidly pair, priced AFTER the transfer the way a
    /// fee-on-transfer router does.
    function _sellIntoSolidlyPair(address who, address token, address pair, uint256 amount)
        internal
    {
        if (amount == 0) return;
        vm.prank(who);
        IERC20(token).transfer(pair, amount);

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

    function _reserves(address pair, address coin) internal view returns (uint256 rc, uint256 rq) {
        (uint112 r0, uint112 r1,) = IV2Pair(pair).getReserves();
        return IV2Pair(pair).token0() == coin ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _sharesOf(PerpMeDividendDistributor dist, address who) internal view returns (uint256 s) {
        (s,,,,,) = dist.accounts(who);
    }

    /// Flip Nest's `isPublicPoolCreationMode` in storage so the test can get
    /// past the role gate F3 documents. Found by recording the SLOAD.
    function _openNestPoolCreation() internal {
        INestFactory nest = INestFactory(NEST_FACTORY);
        vm.record();
        nest.isPublicPoolCreationMode();
        (bytes32[] memory reads,) = vm.accesses(NEST_FACTORY);
        require(reads.length > 0, "no slot read");
        bytes32 slot = reads[reads.length - 1];
        bytes32 original = vm.load(NEST_FACTORY, slot);
        for (uint256 offset; offset < 32; offset++) {
            vm.store(NEST_FACTORY, slot, original | bytes32(uint256(1) << (8 * offset)));
            if (nest.isPublicPoolCreationMode() && !nest.isPaused()) return;
            vm.store(NEST_FACTORY, slot, original);
        }
        revert("could not open pool creation");
    }
}
