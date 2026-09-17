// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForkPin} from "./ForkPin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeDividendDistributor} from "../src/tax/PerpMeDividendDistributor.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

interface IV2Factory {
    function createPair(address, address) external returns (address);
    function getPair(address, address) external view returns (address);
}

interface IV2Router {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256, uint256);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IV2Pair {
    function sync() external;
}

/// Something with the right shape and the wrong tokens.
contract PretendPair {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        token0 = a;
        token1 = b;
    }
}

/**
 * How a dividend coin turns its tax into the thing it pays holders.
 *
 * It used to hand an allowance over its own balance to a router address the
 * factory had supplied, call it, and read the result back. Nothing about that
 * was safe to keep: whatever validation the address passed, it was still the
 * one deciding whether the sale had really happened, and an allowance that
 * outlived the call was a standing claim on tax nobody had collected yet.
 *
 * The coin now sells straight into its own pair. These tests pin down what that
 * buys — no allowance to anyone, a pair that has to be this coin's pair, and a
 * price that has to resemble where the pool has actually been trading.
 */
contract TaxLiquidationRouterTest is Test {
    /* PRJX's V2, verified on chain 999.

       These used to be read from the environment with no default, which meant
       every one of these suites skipped itself on every run — the check reads
       `code.length` before the fork is selected, where nothing has code at all.
       They were green for a year without executing. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;

    address creator = address(0xC0FFEE);
    address locker = address(0x10CCE7);
    address protocolTreasury = address(0x7EA);
    address alice = address(0xA11CE);
    address mev = address(0x3EF);

    PerpMeTaxToken coin;
    address pair;

    PerpMeUniV2Venue venue;

    function setUp() public {
        /* No V2 venue configured for HyperEVM yet — see the note above. */
        ForkPin.select();

        venue = new PerpMeUniV2Venue(V2_FACTORY, 30);

        coin = new PerpMeTaxToken();
        coin.initialize(
            PerpMeTaxToken.InitParams({
                name: "Router Test",
                symbol: "RTST",
                metadataURI: "",
                metadataB64: "",
                creator: creator,
                locker: locker,
                pairToken: WNVDAX,
                reservedPair: _openPair(address(coin), WNVDAX),
                protocolTreasury: protocolTreasury,
                totalSupply: 1_000_000_000e18,
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

        pair = IV2Factory(V2_FACTORY).getPair(address(coin), WNVDAX);
        if (pair == address(0)) {
            pair = IV2Factory(V2_FACTORY).getPair(address(coin), WNVDAX);
        }

        // This contract stands in for the factory, so it is tax-exempt and can
        // seed the pool the way a launch would.
        deal(WNVDAX, address(this), 10_000e18);
        coin.approve(V2_ROUTER, type(uint256).max);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).addLiquidity(
            address(coin), WNVDAX, 500_000_000e18, 1_000e18, 0, 0, locker, block.timestamp
        );
        coin.setPair(pair);

        deal(WNVDAX, alice, 1_000e18);
        deal(WNVDAX, mev, 5_000e18);
    }

    function _buy(address who, uint256 spend) internal {
        address[] memory path = new address[](2);
        path[0] = WNVDAX;
        path[1] = address(coin);
        vm.startPrank(who);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            spend, 0, path, who, block.timestamp
        );
        vm.stopPrank();
    }

    function _sell(address who, uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = address(coin);
        path[1] = WNVDAX;
        vm.startPrank(who);
        coin.approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, who, block.timestamp
        );
        vm.stopPrank();
    }

    /// Lets the pair's accumulator gather a window to average over.
    function _letTimePass(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        IV2Pair(pair).sync();
    }

    // -------------------------------------------------------------------------

    /// Nobody is approved to move the coin's own balance. There is no router.
    function test_TheCoinApprovesNobodyToSpendItsTax() public {
        _buy(alice, 10e18);
        _letTimePass(600);
        _sell(alice, coin.balanceOf(alice) / 4);
        _letTimePass(600);
        _sell(alice, coin.balanceOf(alice) / 4);

        for (uint256 i; i < 4; i++) {
            address who = [V2_ROUTER, pair, address(this), creator][i];
            assertEq(
                coin.allowance(address(coin), who),
                0,
                "the coin's balance is nobody's to spend"
            );
        }
    }

    /// The sale itself still happens, and holders are paid for it.
    function test_TaxIsSoldIntoThePairAndPaidOut() public {
        PerpMeDividendDistributor dist = coin.distributor();
        _buy(alice, 10e18);
        assertGt(coin.balanceOf(address(coin)), coin.swapThreshold(), "tax accrued");

        // Too soon after the pool opened for an average to mean anything.
        uint256 before = dist.totalDeposited();
        _sell(alice, coin.balanceOf(alice) / 4);
        assertEq(dist.totalDeposited(), before, "the window is not open yet");

        // Once it is long enough, the sale goes through.
        _letTimePass(400);
        _sell(alice, coin.balanceOf(alice) / 4);
        assertGt(dist.totalDeposited(), before, "holders were paid");
    }

    /// A pair holding some other pair of tokens is refused outright.
    function test_APairForOtherTokensIsRefused() public {
        PerpMeTaxToken fresh = new PerpMeTaxToken();
        fresh.initialize(
            PerpMeTaxToken.InitParams({
                name: "Other",
                symbol: "OTHR",
                metadataURI: "",
                metadataB64: "",
                creator: creator,
                locker: locker,
                pairToken: WNVDAX,
                reservedPair: _openPair(address(coin), WNVDAX),
                protocolTreasury: protocolTreasury,
                totalSupply: 1_000_000_000e18,
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
        PretendPair wrong = new PretendPair(WNVDAX, address(0xdead));

        vm.expectRevert(PerpMeTaxToken.NotThePairForThisCoin.selector);
        fresh.setPair(address(wrong));
    }

    /// Only the coin may ask itself to sell.
    function test_NobodyElseCanTriggerTheSale() public {
        vm.prank(alice);
        vm.expectRevert(PerpMeTaxToken.OnlySelf.selector);
        coin.sellTaxIntoPair(1e18, alice);
    }

    /**
     * A pool pushed away from its average is not sold into.
     *
     * The attacker dumps into the pair first, so the reserves — and therefore
     * everything the coin could work out from them — say the coin is worth far
     * less than it has been. Sizing the sale off those reserves would agree
     * with the manipulation and hand over the tax at the staged price. Measured
     * against the pair's own time-weighted average it does not agree, and the
     * coin simply waits: the tax is still there afterwards, for a pool that has
     * come back.
     */
    function test_AManipulatedPriceIsNotSoldInto() public {
        PerpMeDividendDistributor dist = coin.distributor();

        // An hour of honest trading history for the average to be drawn from.
        // Small enough that the tax it leaves stays under the threshold, so the
        // dump below does not trip a liquidation on its way past.
        _buy(alice, 5e18);
        _letTimePass(3600);

        /*
         * The dump lands while the coin is holding nothing worth selling, so it
         * passes without a liquidation of its own and leaves the reference
         * price untouched. That is the only shape this attack can take: a
         * liquidation triggered by the attacker's OWN sell reads the pair before
         * their coins have reached it, and so prices off reserves they have not
         * moved yet.
         */
        assertLt(coin.balanceOf(address(coin)), coin.swapThreshold(), "nothing to take");
        // Enough to leave the pool quoting a fraction of what it has been. Less
        // than this is not what the check is for: a pool that has merely fallen
        // hard is still a pool, and the size cap is what bounds the loss there.
        deal(address(coin), mev, 2_000_000_000e18);
        _sell(mev, 2_000_000_000e18);

        uint256 taxHeld = coin.balanceOf(address(coin));
        uint256 deposited = dist.totalDeposited();
        assertGt(taxHeld, coin.swapThreshold(), "there is tax to protect");

        // Somebody else's ordinary sell now lands in the staged pool.
        _sell(alice, coin.balanceOf(alice) / 4);

        assertEq(
            dist.totalDeposited(),
            deposited,
            "nothing was sold into the staged price"
        );
        assertGe(
            coin.balanceOf(address(coin)),
            taxHeld,
            "the tax is still there to sell later"
        );
    }

    /**
     * A pool that really did crash comes back inside one window.
     *
     * Found live, not here: a holder dumping their whole position took a pool
     * to 4% of where it had been — a real move, not an attack — and the tax
     * then had no way out, because the reference the average was measured
     * against only moved when a sale actually went through. It could not go
     * through, so it never moved, and the coin stayed anchored to a price the
     * market had left. Re-anchoring on every reading with a real window behind
     * it bounds that to one window.
     */
    function test_ACrashedPoolRecoversAfterOneWindow() public {
        PerpMeDividendDistributor dist = coin.distributor();

        _buy(alice, 5e18);
        _letTimePass(3600);
        deal(address(coin), mev, 2_000_000_000e18);
        _sell(mev, 2_000_000_000e18); // a real dump, not a sandwich

        uint256 deposited = dist.totalDeposited();
        _sell(alice, coin.balanceOf(alice) / 4);
        assertEq(dist.totalDeposited(), deposited, "refused while the fall is fresh");

        // One window later the coin is judging against where the market now is.
        _letTimePass(400);
        _sell(alice, coin.balanceOf(alice) / 4);
        assertGt(dist.totalDeposited(), deposited, "and sells again");
    }

    /**
     * The same pool, left alone, is sold into perfectly happily.
     *
     * Without this the test above proves only that something declined, not that
     * the price is what it declined over.
     */
    function test_AnHonestPriceIsSoldInto() public {
        PerpMeDividendDistributor dist = coin.distributor();

        _buy(alice, 10e18);
        _letTimePass(3600);
        deal(address(coin), mev, 300_000_000e18); // held, not dumped

        uint256 deposited = dist.totalDeposited();
        _sell(alice, coin.balanceOf(alice) / 4);
        assertGt(dist.totalDeposited(), deposited, "an unmoved pool is sold into");
    }

    /**
     * @dev Where Uniswap V2 will put the pair for these two tokens.
     *
     *      The factory works this out for a real launch; this file stands in
     *      for the factory, so it works it out too. The init-code hash is the
     *      stock Uniswap V2 one, checked against a live pair on this chain.
     */

    /// Stands in for what the factory now does at launch: open the empty pair
    /// and hand the coin its real address, instead of predicting one.
    function _openPair(address a, address b) internal returns (address p) {
        p = IV2Factory(V2_FACTORY).getPair(a, b);
        if (p == address(0)) p = IV2Factory(V2_FACTORY).createPair(a, b);
    }

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
