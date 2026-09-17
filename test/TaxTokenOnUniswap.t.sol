// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForkPin} from "./ForkPin.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * Can an PerpMe coin take a tax on every transfer, the way flap.sh's "tax
 * tokens" do on BNB?
 *
 * This test exists to answer that with the chain rather than with an opinion,
 * because the whole dividends design depends on the answer. It deploys a coin
 * that keeps 5% of every transfer, opens a REAL Uniswap V3 pool for it on a
 * fork of HyperEVM mainnet, and trades it through the REAL SwapRouter02 the site
 * already uses.
 *
 * The other side of the pool is a plain 18-decimal token rather than USDC, on
 * purpose: what is under test is Uniswap's tolerance for a shrinking transfer,
 * and pairing two identically-scaled tokens at 1:1 keeps every amount in this
 * file legible. The factory, the pool and the router are the deployed ones.
 *
 * It then asks the same question of Uniswap V2, which IS deployed on HyperEVM
 * (factory 0xDf38…7E95, router 0x182a…0f59) and whose router carries the four
 * `…SupportingFeeOnTransferTokens` entry points that exist precisely for this.
 *
 * The result decides the architecture. V3 cannot carry a taxed coin, so a
 * launchpad built on V3 has to fund dividends from the POOL fee — capped at 1%
 * by the tiers Hyperliquid enabled. V2 can, at any tax the creator likes.
 */
contract TaxedCoin is ERC20 {
    uint256 public constant TAX_BPS = 500; // 5%
    address public immutable VAULT;
    /// @dev The test contract. Exempt so the pool can be FUNDED untaxed —
    ///      otherwise liquidity arrives 5% short and the failure under test
    ///      comes from the fixture instead of the router.
    address public immutable OWNER;

    constructor(address vault) ERC20("Taxed", "TAX") {
        VAULT = vault;
        OWNER = msg.sender;
        _mint(msg.sender, 1_000_000_000e18);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Minting and burning are untaxed; everything else keeps 5% back. This
        // is the shape every "tax token" has.
        if (
            from == address(0) || to == address(0) || from == VAULT || to == VAULT
                || from == OWNER || to == OWNER
        ) {
            super._update(from, to, value);
            return;
        }
        uint256 tax = (value * TAX_BPS) / 10_000;
        super._update(from, VAULT, tax);
        super._update(from, to, value - tax);
    }
}

/// The untaxed other side of the pool.
contract PlainCoin is ERC20 {
    constructor() ERC20("Plain", "PLN") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
    function token0() external view returns (address);
    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IUniswapV2Router02 {
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

/// @dev Named for SwapRouter02, but PRJX deploys the CLASSIC SwapRouter and
///      this is its shape: the struct carries a `deadline`. Written without one
///      it is a different selector and lands on no function at all, which is a
///      bare revert after two hundred gas — the same mistake that made every
///      native buy fail in `PerpMeCurveRouter`.
interface ISwapRouter02 {
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

contract TaxTokenOnUniswapTest is Test {
    /// @dev PRJX's V3 factory on HyperEVM. The address here used to be the one
    ///      from X Layer, chain 196, carried over with the fork — nothing at
    ///      that address exists on this chain, so setUp reverted before a
    ///      single assertion ran.
    address constant FACTORY = 0xFf7B3e8C00e57ea31477c32A5B52a58Eea47b072;
    address constant ROUTER = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    TaxedCoin coin;
    PlainCoin plain;
    IUniswapV3Pool pool;
    address vault = address(0xBEEF);
    address trader = address(0xCAFE);

    function setUp() public {
        ForkPin.select();

        coin = new TaxedCoin(vault);
        plain = new PlainCoin();
        pool = IUniswapV3Pool(
            IUniswapV3Factory(FACTORY).createPool(address(coin), address(plain), 10_000)
        );

        // 1:1. Both tokens have eighteen decimals, so this is also 1:1 to read.
        pool.initialize(79228162514264337593543950336);

        // Both sides seeded, so BOTH directions are possible — a single-sided
        // launch position would make a failing sell ambiguous.
        //
        // Minted by this contract, which holds the callback Uniswap calls to
        // collect what the mint owes, and which the tax exempts.
        pool.mint(address(this), -60_000, 60_000, 1e21, "");

        coin.transfer(trader, 10_000e18);
        plain.transfer(trader, 10_000e18);
    }

    /// @dev Uniswap calls this to collect what the mint owes.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        bool coinIsZero = pool.token0() == address(coin);
        if (amount0Owed > 0) {
            ERC20(coinIsZero ? address(coin) : address(plain)).transfer(msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            ERC20(coinIsZero ? address(plain) : address(coin)).transfer(msg.sender, amount1Owed);
        }
    }

    /**
     * The decisive case: a holder sells a taxed coin into a V3 pool.
     *
     * The router transfers the seller's coins to the pool, the tax skims 5% on
     * the way, and the pool's own check — "I must have received exactly what I
     * was promised" — fails. There is no V3 equivalent of V2's
     * `swapExactTokensForTokensSupportingFeeOnTransferTokens`; the concentrated
     * liquidity maths has no room for an amount that shrinks in transit.
     */
    function test_SellingATaxedCoinRevertsOnV3() public {
        vm.startPrank(trader);
        coin.approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        ISwapRouter02(ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(coin),
                tokenOut: address(plain),
                fee: 10_000,
                recipient: trader,
                deadline: block.timestamp,
                amountIn: 100e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    /**
     * The control: the same pool, the same router, the same amounts, with the
     * tax switched off by routing through the exempt vault address. If this
     * passes, the revert above is the tax and not a broken fixture.
     */
    function test_ControlUntaxedSellSucceeds() public {
        vm.prank(trader);
        coin.transfer(vault, 1_000e18);

        vm.startPrank(vault);
        coin.approve(ROUTER, type(uint256).max);
        uint256 out = ISwapRouter02(ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(coin),
                tokenOut: address(plain),
                fee: 10_000,
                recipient: vault,
                deadline: block.timestamp,
                amountIn: 100e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertGt(out, 0, "untaxed sell should go through");
    }

    /**
     * Buying is not a reprieve.
     *
     * The pool pays out the full amount it computed, the tax takes 5% in
     * transit, and the buyer receives less than the router reports and less
     * than any slippage guard was checking. With a real amountOutMinimum — what
     * the widget always sends — the trade reverts too.
     */
    function test_BuyingATaxedCoinShortchangesTheBuyer() public {
        vm.startPrank(trader);
        plain.approve(ROUTER, type(uint256).max);
        uint256 before = coin.balanceOf(trader);
        uint256 reported = ISwapRouter02(ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(plain),
                tokenOut: address(coin),
                fee: 10_000,
                recipient: trader,
                deadline: block.timestamp,
                amountIn: 100e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 received = coin.balanceOf(trader) - before;
        vm.stopPrank();

        assertLt(received, reported, "the tax is skimmed after the pool pays");
        // 5% short, exactly the tax.
        assertApproxEqRel(received, (reported * 9_500) / 10_000, 1e15);
    }

    // =========================================================================
    //  The same coin, on Uniswap V2 — which HyperEVM also has.
    // =========================================================================

    /* PRJX's V2, verified on chain 999.

       These used to be read from the environment with no default, which meant
       every one of these suites skipped itself on every run — the check reads
       `code.length` before the fork is selected, where nothing has code at all.
       They were green for a year without executing. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;

    function _seedV2() internal returns (address pair) {
        pair = IUniswapV2Factory(V2_FACTORY).createPair(address(coin), address(plain));
        coin.approve(V2_ROUTER, type(uint256).max);
        plain.approve(V2_ROUTER, type(uint256).max);
        // Added by this contract, which the tax exempts, so the pair starts
        // with the liquidity it was promised rather than 5% less.
        IUniswapV2Router02(V2_ROUTER).addLiquidity(
            address(coin),
            address(plain),
            100_000e18,
            100_000e18,
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    /**
     * Selling a taxed coin on V2 works — the case that reverts on V3.
     *
     * The router does not demand an exact amount. It reads the pair's balance
     * after the transfer and prices the swap on what actually arrived, which is
     * the whole point of the `SupportingFeeOnTransferTokens` variant and has no
     * counterpart in V3.
     */
    function test_SellingATaxedCoinWorksOnV2() public {
        _seedV2();

        address[] memory path = new address[](2);
        path[0] = address(coin);
        path[1] = address(plain);

        uint256 vaultBefore = coin.balanceOf(vault);
        uint256 gotBefore = plain.balanceOf(trader);

        vm.startPrank(trader);
        coin.approve(V2_ROUTER, type(uint256).max);
        IUniswapV2Router02(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            100e18, 0, path, trader, block.timestamp
        );
        vm.stopPrank();

        assertGt(plain.balanceOf(trader) - gotBefore, 0, "the sell should pay out");
        // The 5% never reached the pair; it is sitting in the vault, which is
        // exactly the money a dividend would be paid from.
        assertEq(coin.balanceOf(vault) - vaultBefore, 5e18, "tax collected");
    }

    /// Buying works too, and the buyer keeps 95% — the tax is the platform's.
    function test_BuyingATaxedCoinWorksOnV2() public {
        _seedV2();

        address[] memory path = new address[](2);
        path[0] = address(plain);
        path[1] = address(coin);

        uint256 before = coin.balanceOf(trader);
        uint256 vaultBefore = coin.balanceOf(vault);

        vm.startPrank(trader);
        plain.approve(V2_ROUTER, type(uint256).max);
        IUniswapV2Router02(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            100e18, 0, path, trader, block.timestamp
        );
        vm.stopPrank();

        uint256 received = coin.balanceOf(trader) - before;
        uint256 taxed = coin.balanceOf(vault) - vaultBefore;
        assertGt(received, 0, "the buy should deliver coins");
        assertGt(taxed, 0, "and the tax should be collected on the way out");
        // Buyer 95, platform 5, out of every 100 the pool released.
        assertApproxEqRel(taxed * 19, received, 1e15);
    }

    /**
     * The V2 leg those last two tests relied on is not on this chain.
     *
     * There used to be two tests here measuring how SwapRouter02's
     * `swapExactTokensForTokens` handles a fee-taking token, and concluding
     * from the result that "a taxed launch needs no second router in the
     * widget". The measurement was real — on X LAYER, where SwapRouter02 is
     * what is deployed. PRJX deploys the classic SwapRouter, whose bytecode
     * does not contain that selector anywhere, so the conclusion was drawn
     * about a contract that does not exist at this address.
     *
     * It is the wrong conclusion in the direction that costs money: a
     * graduated coin quoted in a share needs a V3 bridge AND a V2 hop, and
     * with no router able to do both, believing otherwise is a buy button that
     * cannot work. `PerpMeMarketRouter` is the second router, and
     * `TaxCoinRouting` is where the whole journey is proved.
     */
    function test_ThisChainsRouterHasNoV2LegAtAll() public view {
        bytes4 sel =
            bytes4(keccak256("swapExactTokensForTokens(uint256,uint256,address[],address)"));
        bytes memory code = ROUTER.code;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (
                code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2]
                    && code[i + 3] == sel[3]
            ) {
                revert("PRJX router grew a V2 leg: the tests above can come back");
            }
        }
    }
}
