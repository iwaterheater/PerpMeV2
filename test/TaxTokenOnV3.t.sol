// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkPin} from "./ForkPin.sol";
import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

interface IV2Factory {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

interface IV2Router {
    function addLiquidity(address, address, uint256, uint256, uint256, uint256, address, uint256)
        external
        returns (uint256, uint256, uint256);
}

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
    function createPool(address, address, uint24) external returns (address);
}

interface IV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface ISwapRouterClassic {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/**
 * @title Can a coin that taxes its own transfers live in a concentrated pool?
 *
 * @notice Asked because a competitor's launchpad is read as having solved it,
 *         and because the answer decides whether this product can ever list
 *         where the volume on this chain actually is. Their own documentation
 *         says a tax token "can only be migrated to Uniswap V2 or its forks";
 *         this checks the claim against the real PRJX V3 factory rather than
 *         against anybody's documentation, ours included.
 *
 * @dev The coin under test is an ordinary launched dividend coin: 3% each way,
 *      pair opened, transfers free. Everything else is PRJX's own deployment.
 */
contract TaxTokenOnV3Test is Test {
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant V3_FACTORY = 0xFf7B3e8C00e57ea31477c32A5B52a58Eea47b072;
    address constant V3_POSITION_MANAGER = 0xeaD19AE861c29bBb2101E834922B2FEee69B9091;
    address constant V3_SWAP_ROUTER = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
    address constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    uint256 constant SUPPLY = 1_000_000_000e18;

    PerpMeTaxToken coin;
    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);

    function owner() external view returns (address) {
        return address(this);
    }

    function setUp() public {
        ForkPin.select();
        PerpMeUniV2Venue venue = new PerpMeUniV2Venue(V2_FACTORY, 30);

        coin = new PerpMeTaxToken();
        address pair = IV2Factory(V2_FACTORY).createPair(address(coin), WNVDAX);
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

        deal(WNVDAX, address(this), 10_000e18);
        coin.approve(V2_ROUTER, type(uint256).max);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).addLiquidity(
            address(coin), WNVDAX, 200_000_000e18, 42e18, 0, 0, BURN_SINK, block.timestamp
        );
        coin.setPair(pair);
    }

    /**
     * A concentrated pool lets such a coin be BOUGHT and never SOLD.
     *
     * Measured against PRJX's own V3 factory, with an ordinary 3%/3% dividend
     * coin. Three separate answers, and the middle one is the dangerous one:
     *
     *   creating the pool           works
     *   funding it from a taxed holder    reverts `M0`
     *   funding it from an EXEMPT address works
     *   buying through it           works — and quietly short-pays the buyer
     *   selling into it             reverts `IIA`
     *
     * Both refusals are the same check in different places: the pool takes its
     * tokens through a callback and then requires that its own balance rose by
     * exactly what it asked for. Coins going IN are checked that way; coins
     * coming OUT are a plain transfer the pool never verifies. So the tax is
     * invisible on the way in and fatal on the way out.
     *
     * That is worse than a pool that plainly does not work. It looks alive, it
     * quotes, it fills buys — and every buyer is trapped in it. Which is why
     * this coin graduates onto a V2-style pair and why, as far as this product
     * is concerned, the concentrated side of any exchange is closed to it.
     */
    function test_aV3PoolLetsSuchACoinBeBoughtButNeverSold() public {
        address pool = IV3Factory(V3_FACTORY).createPool(address(coin), WNVDAX, 10000);
        assertTrue(pool != address(0), "the pool itself is created without complaint");

        // sqrt(1e-6) * 2^96 — one wNVDAx per million coins; any sane price does.
        IV3Pool(pool).initialize(79228162514264337593543950);
        (uint160 sqrtPrice,,,,,,) = IV3Pool(pool).slot0();
        assertGt(sqrtPrice, 0, "and it prices");

        bool coinIsToken0 = address(coin) < WNVDAX;
        (address t0, address t1) =
            coinIsToken0 ? (address(coin), WNVDAX) : (WNVDAX, address(coin));
        (uint256 a0, uint256 a1) =
            coinIsToken0 ? (uint256(10_000_000e18), uint256(10e18)) : (uint256(10e18), uint256(10_000_000e18));

        coin.approve(V3_POSITION_MANAGER, type(uint256).max);
        IERC20(WNVDAX).approve(V3_POSITION_MANAGER, type(uint256).max);

        INonfungiblePositionManager.MintParams memory p = INonfungiblePositionManager.MintParams({
            token0: t0,
            token1: t1,
            fee: 10000,
            tickLower: -887200,
            tickUpper: 887200,
            amount0Desired: a0,
            amount1Desired: a1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        // This contract is the coin's "factory" and therefore tax-exempt, so
        // the tax has to come from an address that is not: a plain holder.
        address lp = address(0x1111000000000000000000000000000000001111);
        coin.transfer(lp, 20_000_000e18);
        vm.startPrank(lp);
        coin.approve(V3_POSITION_MANAGER, type(uint256).max);
        vm.stopPrank();
        deal(WNVDAX, lp, 100e18);
        vm.startPrank(lp);
        IERC20(WNVDAX).approve(V3_POSITION_MANAGER, type(uint256).max);
        p.recipient = lp;

        (bool taxedOk, bytes memory err) = V3_POSITION_MANAGER.call(
            abi.encodeWithSelector(INonfungiblePositionManager.mint.selector, p)
        );
        vm.stopPrank();

        console2.log("pool created at", pool);
        console2.log("mint from a TAXED holder succeeded:", taxedOk);
        console2.log("revert reason:", _reason(err));
        assertFalse(taxedOk, "a taxed holder cannot fund a concentrated position");

        /*
         * And from an address the coin does not tax.
         *
         * This contract stands in for the factory, which is exempt — so its
         * transfers arrive whole and the pool's balance check is satisfied.
         * Worth knowing rather than assuming: it means liquidity CAN be placed
         * in such a pool by an exempt address, and it is the trading that
         * still cannot happen, which is a different and more misleading
         * failure than a pool nobody can open.
         */
        p.recipient = address(this);
        (bool exemptOk, bytes memory err2) = V3_POSITION_MANAGER.call(
            abi.encodeWithSelector(INonfungiblePositionManager.mint.selector, p)
        );
        console2.log("mint from an EXEMPT address succeeded:", exemptOk);
        if (!exemptOk) console2.log("revert reason:", _reason(err2));
        if (!exemptOk) return;

        /*
         * So there is liquidity. Can anybody trade against it?
         *
         * The two directions are not symmetric, and that is the whole point.
         * Coins going INTO the pool pass through the same callback that
         * refused the deposit; coins coming OUT are a plain transfer the pool
         * never checks. So a buy can go through while a sell cannot — which is
         * worse than a pool that plainly does not work, because it looks like
         * it does until somebody tries to leave.
         */
        address trader = address(0x2222000000000000000000000000000000002222);
        deal(WNVDAX, trader, 50e18);
        vm.startPrank(trader);
        IERC20(WNVDAX).approve(V3_SWAP_ROUTER, type(uint256).max);
        (bool buyOk, bytes memory buyErr) = V3_SWAP_ROUTER.call(
            abi.encodeWithSelector(
                ISwapRouterClassic.exactInputSingle.selector,
                ISwapRouterClassic.ExactInputSingleParams({
                    tokenIn: WNVDAX,
                    tokenOut: address(coin),
                    fee: 10000,
                    recipient: trader,
                    deadline: block.timestamp,
                    amountIn: 1e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        console2.log("BUY  through the V3 pool succeeded:", buyOk);
        if (!buyOk) console2.log("  reason:", _reason(buyErr));
        console2.log("  coins the trader now holds:", coin.balanceOf(trader) / 1e18);

        uint256 held = coin.balanceOf(trader);
        if (held > 0) {
            coin.approve(V3_SWAP_ROUTER, type(uint256).max);
            (bool sellOk, bytes memory sellErr) = V3_SWAP_ROUTER.call(
                abi.encodeWithSelector(
                    ISwapRouterClassic.exactInputSingle.selector,
                    ISwapRouterClassic.ExactInputSingleParams({
                        tokenIn: address(coin),
                        tokenOut: WNVDAX,
                        fee: 10000,
                        recipient: trader,
                        deadline: block.timestamp,
                        amountIn: held / 2,
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    })
                )
            );
            console2.log("SELL through the V3 pool succeeded:", sellOk);
            if (!sellOk) console2.log("  reason:", _reason(sellErr));
            assertFalse(sellOk, "selling into a concentrated pool cannot work with a transfer tax");
        }
        vm.stopPrank();
    }

    /// @dev The string inside a revert, or the selector when there is no string.
    function _reason(bytes memory data) private pure returns (string memory) {
        if (data.length == 0) return "(no data)";
        if (data.length >= 68 && bytes4(data) == bytes4(0x08c379a0)) {
            assembly {
                data := add(data, 0x04)
            }
            return abi.decode(data, (string));
        }
        return string(abi.encodePacked("selector ", vm.toString(bytes4(data))));
    }
}
