// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TEMPORARY independent-audit PoC. Delete after reading.

import {Test} from "forge-std/Test.sol";
import {ForkPin} from "./ForkPin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpMeTaxFactory} from "../src/tax/PerpMeTaxFactory.sol";
import {PerpMeTaxTokenDeployer} from "../src/tax/PerpMeTaxTokenDeployer.sol";
import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeCurve} from "../src/tax/PerpMeCurve.sol";
import {PerpMeDividendDistributor} from "../src/tax/PerpMeDividendDistributor.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

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
 * A contract that answers `token0()` with the coin — which is the entire test
 * `_isMarket` applies — and can hand its coins back on command.
 */
contract ParkedMarket {
    address public token0;
    address public token1;

    constructor(address coin, address quote) {
        token0 = coin;
        token1 = quote;
    }

    function sweep(address coin, address to) external {
        IERC20(coin).transfer(to, IERC20(coin).balanceOf(address(this)));
    }
}

/// Exposes token0() and nothing else — a vault, a wrapper, a staking contract.
/// Resembles a pool from one side; is not one.
contract HalfMarket {
    address public token0;

    constructor(address coin) {
        token0 = coin;
    }
}

contract AuditOpus5 is Test {
    /* PRJX's V2, verified on chain 999.

       These used to be read from the environment with no default, which meant
       every one of these suites skipped itself on every run — the check reads
       `code.length` before the fork is selected, where nothing has code at all.
       They were green for a year without executing. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;

    PerpMeTaxFactory factory;
    PerpMeTaxTokenDeployer deployer;

    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address buyer = address(0xB0B);
    address attacker = address(0xBAD);


    PerpMeUniV2Venue venue;

    function setUp() public {
        ForkPin.select();
        venue = new PerpMeUniV2Venue(V2_FACTORY, 30);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        deployer = new PerpMeTaxTokenDeployer(predicted);
        factory = new PerpMeTaxFactory(address(deployer), treasury, 0, 2000);
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
        deal(WNVDAX, buyer, 100_000e18);
        deal(WNVDAX, attacker, 100_000e18);
    }

    function _params() internal pure returns (PerpMeTaxFactory.LaunchParams memory) {
        return PerpMeTaxFactory.LaunchParams({
            name: "NVCAT",
            symbol: "NVCAT",
            metadataURI: "x",
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

    /**
     * Shares handed out BEFORE an address is recognised as a market are given
     * up at the moment it is recognised.
     *
     * `_isMarket` is only reached once a pair exists — during the curve phase
     * `_update` returns early — so a contract shaped like a pool can be filled
     * with coins while nobody is asking, and `_syncShares` credits it like any
     * holder. After graduation the first transfer touching it forms the
     * verdict, and from then on `_syncShares` SKIPS a market rather than
     * zeroing it. Skipping alone left the share count frozen exactly where it
     * was while the coins walked back out: 422,388,705 phantom shares, 35% of
     * the register, drawing a cut of every dividend for good, with
     * `totalShares` larger than the supply that exists.
     *
     * `_isMarket` now settles the shares as it forms the verdict, so the
     * register never carries a holder that owns nothing.
     */
    function test_SharesAreGivenUpWhenAnAddressIsRecognisedAsAMarket() public {
        vm.prank(creator);
        (address token, address curve) = factory.launchToken(_params(), 0, bytes32(0), 0, 0);
        PerpMeDividendDistributor dist = PerpMeTaxToken(token).distributor();

        // --- Curve phase: park a large position in a pool-shaped contract ---
        ParkedMarket m = new ParkedMarket(token, WNVDAX);

        // Well under the ~41.7 wNVDAx the curve needs, so it does NOT graduate
        // here — the whole point is to move coins while `pair` is still unset.
        vm.startPrank(attacker);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(10e18, 0);
        uint256 parked = IERC20(token).balanceOf(attacker);
        IERC20(token).transfer(address(m), parked);
        vm.stopPrank();
        assertEq(PerpMeTaxToken(token).pair(), address(0), "still on the curve");

        (uint256 sharesAfterPark,,,,,) = dist.accounts(address(m));
        emit log_named_decimal_uint("parked in the fake market", parked, 18);
        emit log_named_decimal_uint("shares it was credited   ", sharesAfterPark, 18);
        assertGt(sharesAfterPark, 0, "the curve phase credited a market-shaped contract");

        // --- Somebody else finishes the curve; the pair opens ---
        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(300e18, 0);
        vm.stopPrank();
        assertTrue(PerpMeCurve(curve).graduated(), "graduated");

        // --- Take the coins back out. This is the transfer that caches the
        //     verdict, and it is also the last time the balance matters. ---
        m.sweep(token, attacker);

        (uint256 sharesAfterSweep,,,,,) = dist.accounts(address(m));
        uint256 balanceAfterSweep = IERC20(token).balanceOf(address(m));

        emit log_named_decimal_uint("balance after sweeping  ", balanceAfterSweep, 18);
        emit log_named_decimal_uint("shares after sweeping   ", sharesAfterSweep, 18);
        emit log_named_decimal_uint("total shares            ", dist.totalShares(), 18);

        assertEq(balanceAfterSweep, 0, "the attacker got the coins back");
        assertEq(sharesAfterSweep, 0, "the share count stayed behind");

        // The register must never claim more shares than there are coins.
        assertLe(
            dist.totalShares(),
            IERC20(token).totalSupply(),
            "more shares on the register than coins in existence"
        );

        /*
         * Nothing accrues to it from here on.
         *
         * What it earned while it was still taken for a holder — a curve phase
         * only, and bounded by it — stays as its `owed` and is stranded; there
         * is no way to hand that back without a setter, and a setter is a
         * larger thing to accept than the residue. What matters is that it does
         * not GROW: every dividend funded after the verdict belongs to real
         * holders.
         */
        uint256 owedAtVerdict = dist.claimable(address(m));

        address[] memory sell = new address[](2);
        sell[0] = token;
        sell[1] = WNVDAX;
        vm.startPrank(buyer);
        IERC20(token).approve(V2_ROUTER, type(uint256).max);
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 301);
            IV2RouterLike(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                IERC20(token).balanceOf(buyer) / 6, 0, sell, buyer, block.timestamp
            );
        }
        vm.stopPrank();

        emit log_named_decimal_uint("owed at the verdict     ", owedAtVerdict, 18);
        emit log_named_decimal_uint("owed after more trading ", dist.claimable(address(m)), 18);
        emit log_named_decimal_uint("total dividends funded  ", dist.totalDeposited(), 18);

        assertEq(
            dist.claimable(address(m)),
            owedAtVerdict,
            "a balance-less contract is still drawing dividends"
        );
    }

    /**
     * A stranger cannot initialize a coin somebody else deployed.
     *
     * `initialize` used to be open to anyone while `factory` was still zero,
     * resting on the launch doing both steps in one transaction. Separate them
     * for any reason and whoever calls first becomes the factory, picks the
     * tax, treasury, creator and supply, and mints the whole lot to itself.
     */
    function test_OnlyTheDeployerOrItsFactoryCanInitialize() public {
        // Deployed by this contract, so this contract is the only party that
        // could ever legitimately initialize it.
        PerpMeTaxToken fresh = new PerpMeTaxToken();

        vm.prank(address(0xBAD));
        vm.expectRevert(PerpMeTaxToken.NotFactory.selector);
        fresh.initialize(_init(address(0xBAD)));

        // The deployer itself still can, so the launch path is untouched.
        fresh.initialize(_init(creator));
        assertEq(fresh.factory(), address(this), "the deployer initialized it");
    }

    function _init(address who) internal view returns (PerpMeTaxToken.InitParams memory) {
        return PerpMeTaxToken.InitParams({
            name: "X",
            symbol: "X",
            metadataURI: "x",
            metadataB64: "",
            creator: who,
            locker: address(0xdEaD),
            pairToken: WNVDAX,
            reservedPair: address(0),
            protocolTreasury: who,
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
        });
    }

    /**
     * A contract that exposes only token0() is not a market.
     *
     * Taking the first `yes` from either selector recognised anything with a
     * `token0` naming this coin — a vault, a wrapper, a staking contract —
     * and taxed it as a venue while cutting it out of dividends. A pool holds
     * two different tokens and answers from both sides.
     */
    function test_AContractExposingOnlyToken0IsNotAMarket() public {
        (address token, PerpMeDividendDistributor dist) = _graduated();

        HalfMarket half = new HalfMarket(token);
        uint256 amount = IERC20(token).balanceOf(buyer) / 4;
        vm.prank(buyer);
        IERC20(token).transfer(address(half), amount);

        (uint256 shares,,,,,) = dist.accounts(address(half));
        emit log_named_decimal_uint("sent to the half-market", amount, 18);
        emit log_named_decimal_uint("it received            ", IERC20(token).balanceOf(address(half)), 18);
        emit log_named_decimal_uint("its dividend share     ", shares, 18);

        assertEq(IERC20(token).balanceOf(address(half)), amount, "it was taxed as a market");
        assertEq(shares, amount, "it was cut out of dividends as a market");
    }

    function _graduated() internal returns (address token, PerpMeDividendDistributor dist) {
        vm.prank(creator);
        address curve;
        (token, curve) = factory.launchToken(_params(), 0, bytes32(0), 0, 0);
        dist = PerpMeTaxToken(token).distributor();
        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(300e18, 0);
        vm.stopPrank();
        require(PerpMeCurve(curve).graduated(), "graduated");
    }

    /**
     * Control: the same contract, filled AFTER graduation, is handled correctly.
     * The verdict is cached by `_isMarket` on the very transfer that fills it,
     * so `_syncShares` skips it and it never accrues a share at all.
     */
    function test_Control_AfterGraduationTheSameContractGetsNothing() public {
        vm.prank(creator);
        (address token, address curve) = factory.launchToken(_params(), 0, bytes32(0), 0, 0);
        PerpMeDividendDistributor dist = PerpMeTaxToken(token).distributor();

        vm.startPrank(buyer);
        IERC20(WNVDAX).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(300e18, 0);
        vm.stopPrank();
        assertTrue(PerpMeCurve(curve).graduated(), "graduated");

        ParkedMarket m = new ParkedMarket(token, WNVDAX);
        // Computed BEFORE the prank: balanceOf is itself a call and would
        // otherwise consume it, sending the transfer from this contract.
        uint256 amount = IERC20(token).balanceOf(buyer) / 4;
        vm.prank(buyer);
        IERC20(token).transfer(address(m), amount);

        (uint256 shares,,,,,) = dist.accounts(address(m));
        assertEq(shares, 0, "post-graduation the market is correctly excluded");
    }
}
