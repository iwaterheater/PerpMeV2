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
import {AddTaxConfigs} from "../script/AddTaxConfigs.s.sol";

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

/// @dev Reads the shipped pair table out of the seeding script itself, so this
///      suite cannot drift from what actually gets seeded on chain. A hardcoded
///      copy here would pass forever while the real table rotted.
contract TaxSeedExposer is AddTaxConfigs {
    function seeds() external pure returns (PairSeed[] memory) {
        return _seeds();
    }
}

/**
 * Every seeded pair, from launch to a graduated, trading pool, against real
 * Uniswap V2 on a fork of HyperEVM.
 *
 * The suite that already exists proves the mechanism on one stock pair —
 * wNVDAx. This one answers the question that pair left open: does the SAME
 * mechanism survive every pair in the shipped table, including the one that
 * is not an 18-decimal share at all (USDC, six decimals) and the chain's own
 * wrapped coin (WHYPE). Migration was only ever hand-tested against a single
 * stablecoin with a toy graduation threshold; this is the each-pair proof at
 * production parameters.
 */
contract PerpMeTaxAllPairsTest is Test {
    /* PRJX's V2, verified on chain 999.

       These used to be read from the environment with no default, which meant
       every one of these suites skipped itself on every run — the check reads
       `code.length` before the fork is selected, where nothing has code at all.
       They were green for a year without executing. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant SWAP_ROUTER_02 = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;
    uint256 constant LAUNCH_FEE = 0.01 ether;

    PerpMeTaxFactory factory;
    PerpMeTaxTokenDeployer deployer;

    AddTaxConfigs.PairSeed[] internal seeds;

    address treasury = address(0x7EA);
    address creator = address(0xC0FFEE);
    address buyer = address(0xB0B);

    PerpMeUniV2Venue venue;

    function setUp() public {
        ForkPin.select();

        AddTaxConfigs.PairSeed[] memory s = new TaxSeedExposer().seeds();
        for (uint256 i; i < s.length; ++i) {
            seeds.push(s[i]);
        }

        venue = new PerpMeUniV2Venue(V2_FACTORY, 30);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        deployer = new PerpMeTaxTokenDeployer(predicted);
        factory = new PerpMeTaxFactory(address(deployer), treasury, LAUNCH_FEE, 2000
        );
        assertEq(address(factory), predicted, "nonce prediction held");
        factory.setCurveRouter(address(new PerpMeCurveRouter(SWAP_ROUTER_02, WHYPE)));
        // Registered here rather than three lines up, where neither the venue
        // nor the factory it is being registered on existed yet.
        factory.addDexConfig(venue, "prjx-v2");

        // One config per seed, exactly as AddTaxConfigs would write them.
        for (uint256 i; i < seeds.length; ++i) {
            factory.addLaunchConfig(
                PerpMeTaxFactory.LaunchConfig({
                    dexId: 0,
                    pairToken: seeds[i].token,
                    totalSupply: SUPPLY,
                    enabled: true,
                    virtualToken: 1_073_000_000e18,
                    virtualQuote: seeds[i].virtualQuote,
                    curveTokens: CURVE_TOKENS,
                    curveFeeBps: 150
                })
            );
        }

        vm.deal(creator, 1 ether);
    }

    function _params(string memory sym) internal pure returns (PerpMeTaxFactory.LaunchParams memory) {
        return PerpMeTaxFactory.LaunchParams({
            name: string.concat("Dividend ", sym),
            symbol: sym,
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

    /// Launch against config `i`, optionally with an opening buy in the pair
    /// token's own units. The salt varies with `i` because the coin's address
    /// is CREATE2 over (creator, salt) and nothing else — two launches with the
    /// same salt would fight over one address.
    function _launch(uint256 i, uint256 initialBuy)
        internal
        returns (address token, address curve)
    {
        vm.startPrank(creator);
        if (initialBuy != 0) {
            IERC20(seeds[i].token).approve(address(factory), type(uint256).max);
        }
        (token, curve) = factory.launchToken{value: LAUNCH_FEE}(
            _params(seeds[i].sym), i, bytes32(uint256(i + 1)), initialBuy, 0
        );
        vm.stopPrank();
    }

    /// Buy the whole curve out in one oversized order. 3.5x the virtual quote
    /// clears the ~2.83x the curve needs even after the 1.5% fee and 3% tax;
    /// the excess comes back as the refund, which this exercises for free.
    function _buyOut(uint256 i, address curve) internal {
        uint256 gross = seeds[i].virtualQuote * 7 / 2;
        deal(seeds[i].token, buyer, gross);
        vm.startPrank(buyer);
        IERC20(seeds[i].token).approve(curve, type(uint256).max);
        PerpMeCurve(curve).buy(gross, 0);
        vm.stopPrank();
    }

    /**
     * A coin can be launched, bought with an opening buy, bought out, and
     * graduated into a real Uniswap V2 pool — on EVERY pair we ship, at the
     * production curve parameters.
     */
    function test_allPairs_launchGraduateAndOpenTheRealPool() public {
        for (uint256 i; i < seeds.length; ++i) {
            address quote = seeds[i].token;

            // The creator's opening buy, sized like a real one: a hundredth of
            // the virtual reserve, about thirty dollars.
            uint256 opening = seeds[i].virtualQuote / 100;
            deal(quote, creator, opening);
            (address token, address curve) = _launch(i, opening);
            assertGt(IERC20(token).balanceOf(creator), 0, string.concat(seeds[i].sym, ": opening buy reached the creator"));

            uint256 buyerQuoteBefore = seeds[i].virtualQuote * 7 / 2;
            _buyOut(i, curve);

            assertTrue(PerpMeCurve(curve).graduated(), string.concat(seeds[i].sym, ": graduated"));
            address pair = PerpMeCurve(curve).pair();
            assertEq(
                IV2FactoryLike(V2_FACTORY).getPair(token, quote),
                pair,
                string.concat(seeds[i].sym, ": the pool is on the real Uniswap factory")
            );
            assertEq(PerpMeTaxToken(token).pair(), pair, string.concat(seeds[i].sym, ": the coin was told"));
            assertEq(
                IERC20(token).balanceOf(pair),
                SUPPLY - CURVE_TOKENS,
                string.concat(seeds[i].sym, ": the held-back coins went in")
            );
            assertGt(IERC20(quote).balanceOf(pair), 0, string.concat(seeds[i].sym, ": and the raise went with them"));
            assertGt(IERC20(pair).balanceOf(BURN_SINK), 0, string.concat(seeds[i].sym, ": LP burned"));
            assertEq(IERC20(quote).balanceOf(curve), 0, string.concat(seeds[i].sym, ": curve kept nothing"));

            // The oversized order was trimmed and the unused quote came back —
            // the buyer did not pay 3.5x the reserve for a 2.83x raise.
            assertGt(
                IERC20(quote).balanceOf(buyer),
                buyerQuoteBefore / 10,
                string.concat(seeds[i].sym, ": the overshoot was refunded")
            );
        }
    }

    /**
     * And once graduated, the coin actually works as a dividend coin on every
     * pair: trades pay tax, the tax is liquidated into the pair token, and
     * holders, creator and platform all see money in that token — including
     * the six-decimal one.
     */
    function test_allPairs_afterGraduationEverybodyIsPaid() public {
        for (uint256 i; i < seeds.length; ++i) {
            address quote = seeds[i].token;
            (address token, address curve) = _launch(i, 0);
            PerpMeDividendDistributor dist = PerpMeTaxToken(token).distributor();
            _buyOut(i, curve);

            uint256 treasuryBefore = IERC20(quote).balanceOf(treasury);
            uint256 creatorBefore = IERC20(quote).balanceOf(creator);

            address[] memory sell = new address[](2);
            sell[0] = token;
            sell[1] = quote;
            vm.startPrank(buyer);
            IERC20(token).approve(V2_ROUTER, type(uint256).max);

            // The coin will not sell its tax into a pool it has no price
            // history for, so the sales that fund everything below have to be
            // far enough apart for it to have one.
            vm.warp(block.timestamp + 301);
            IV2RouterLike(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                IERC20(token).balanceOf(buyer) / 4, 0, sell, buyer, block.timestamp
            );
            vm.warp(block.timestamp + 301);
            IV2RouterLike(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                IERC20(token).balanceOf(buyer) / 4, 0, sell, buyer, block.timestamp
            );
            vm.stopPrank();

            assertGt(dist.totalDeposited(), 0, string.concat(seeds[i].sym, ": dividends were funded"));
            assertGt(
                IERC20(quote).balanceOf(treasury) - treasuryBefore,
                0,
                string.concat(seeds[i].sym, ": the platform earned")
            );
            assertGt(
                IERC20(quote).balanceOf(creator) - creatorBefore,
                0,
                string.concat(seeds[i].sym, ": and so did the creator")
            );
        }
    }
}
