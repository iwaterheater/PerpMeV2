// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Uniswap V3's CLASSIC SwapRouter — the one PRJX deploys. The structs
 *      carry a `deadline`, which SwapRouter02 dropped; written without it the
 *      selector is a different one and lands on no function at all.
 */
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    /// @dev Path runs OUTPUT-first for this one — the reverse of `exactInput`'s.
    function exactOutput(ExactOutputParams calldata params)
        external
        payable
        returns (uint256 amountIn);

    /// @dev HYPE the router was sent and did not need, back to the caller.
    function refundETH() external payable;
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
}

/// @dev The three calls a Ramses (Solidly) pair and a Nest (Velodrome-style)
///      pair spell exactly the same way. Everything else about them differs
///      and none of it matters to a swap that hands the pair tokens and asks.
interface ISolidlyPairBridge {
    function token0() external view returns (address);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)
        external;
}

/**
 * @title PerpMeBridge
 * @notice How HYPE becomes the token a coin is quoted in, and back — shared by
 *         the curve router and the market router.
 *
 *         A "bridge" is a byte string the caller supplies, because the bridge
 *         is somebody else's liquidity and where it lives changes without us:
 *
 *           - 43 bytes or more: a Uniswap V3 path, WHYPE first, traded on
 *             PRJX's classic SwapRouter. This is every pair that has a pool
 *             against WHYPE on PRJX — the dollars, the Unit assets, the
 *             tokenised shares we opened pools for.
 *
 *           - exactly 20 bytes: the address of a Solidly-style pair, traded
 *             directly. RAM's liquidity is on Ramses and NEST's is on Nest,
 *             and neither has anything against WHYPE on PRJX. Their pairs
 *             answer `getAmountOut` and `swap` the same way, so one arm serves
 *             both — and Nest's pair, once its factory lets us open one.
 *
 *         Told apart by length rather than by a flag, so nothing about the
 *         routers' signatures moved: the site puts either kind into the same
 *         argument.
 *
 *         Buying can be sized to a target: the curve says how much of the quote
 *         fills it, and the bridge buys exactly that, returning the HYPE it did
 *         not need. On V3 that is `exactOutput`; a Solidly pair has no inverse
 *         of `getAmountOut`, and its fee lives on the pair with a denominator
 *         that differs between forks, so the amount is found by asking the pair
 *         itself — a bisection over `getAmountOut`, some thirty view calls —
 *         rather than by a formula that would be right for one fork and wrong
 *         for the next.
 */
abstract contract PerpMeBridge {
    using SafeERC20 for IERC20;

    ISwapRouter public immutable SWAP_ROUTER;
    address public immutable WETH9;

    error BridgeRefused();
    error NotASolidlyBridge();
    /// @dev The V3 bridge could not take the whole amount. See
    ///      `_requireNothingStranded`.
    error BridgeTooThin();

    constructor(address swapRouter, address weth9) {
        SWAP_ROUTER = ISwapRouter(swapRouter);
        WETH9 = weth9;
    }

    /// @dev A 20-byte bridge is a pair; anything else is a V3 path.
    function _isPairBridge(bytes memory bridge) internal pure returns (bool) {
        return bridge.length == 20;
    }

    function _pairOf(bytes memory bridge) internal pure returns (address pair) {
        assembly {
            pair := shr(96, mload(add(bridge, 32)))
        }
    }

    /**
     * @dev HYPE held by this contract becomes `quote`, held by this contract.
     *
     * @param wantOut  Buy exactly this much of the quote if `hype` can cover
     *                 it, and everything `hype` buys otherwise; 0 means spend
     *                 all of `hype`.
     * @return quoteOut  What arrived.
     * @return spent     The HYPE it took; the rest is still here for the caller
     *                   to return.
     */
    function _hypeToQuote(bytes memory bridge, address quote, uint256 hype, uint256 wantOut)
        internal
        returns (uint256 quoteOut, uint256 spent)
    {
        /*
         * A coin quoted in HYPE itself: nothing to swap, only to wrap.
         *
         * Without this arm the curve router had no way to take HYPE for such a
         * coin at all — an empty path went to PRJX's router and reverted — so
         * the site fell back to the curve's own `buy`, which pulls WHYPE. The
         * form said "Pay HYPE" and read the WHYPE balance, and a buyer holding
         * only HYPE, which is nearly every buyer, saw nothing to spend. Found
         * on devtest, 2026-09-13. The bridge must be empty: a path or a pair
         * here would be a second route to the same token and is refused.
         */
        if (quote == WETH9) {
            if (bridge.length != 0) revert BridgeRefused();
            spent = wantOut != 0 && wantOut < hype ? wantOut : hype;
            IWETH9(WETH9).deposit{value: spent}();
            return (spent, spent);
        }

        if (_isPairBridge(bridge)) {
            ISolidlyPairBridge pair = ISolidlyPairBridge(_pairOf(bridge));
            uint256 amountIn = wantOut == 0 ? hype : _solidlyAmountIn(pair, WETH9, wantOut, hype);
            if (amountIn == 0) revert BridgeRefused();
            IWETH9(WETH9).deposit{value: amountIn}();
            quoteOut = _solidlySwap(pair, WETH9, quote, amountIn, address(this));
            spent = amountIn;
            return (quoteOut, spent);
        }

        if (wantOut != 0) {
            try SWAP_ROUTER.exactOutput{value: hype}(
                ISwapRouter.ExactOutputParams({
                    path: _reversed(bridge),
                    recipient: address(this),
                    // The swap is atomic inside this call, so the only deadline
                    // that means anything is the one on the caller's transaction.
                    deadline: block.timestamp,
                    amountOut: wantOut,
                    amountInMaximum: hype
                })
            ) returns (uint256 amountIn) {
                // The router keeps what the fill did not need; ask for it back.
                SWAP_ROUTER.refundETH();
                return (wantOut, amountIn);
            } catch {
                // Could not cover the fill: the ordinary small buy. Everything
                // sent is converted, below.
            }
        }
        uint256[] memory held = _routerHoldings(bridge);
        quoteOut = SWAP_ROUTER.exactInput{value: hype}(
            ISwapRouter.ExactInputParams({
                path: bridge,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: hype,
                // Guarded on the coin instead. A minimum here would be a second
                // number for the buyer to reason about that protects the same
                // trade twice.
                amountOutMinimum: 0
            })
        );
        _requireNothingStranded(bridge, held);
        spent = hype;
    }

    /// @dev `quoteIn` of `quote`, held by this contract, becomes WHYPE held by
    ///      this contract.
    function _quoteToWrapped(bytes memory bridge, address quote, uint256 quoteIn)
        internal
        returns (uint256 wrapped)
    {
        // Already WHYPE: see the matching arm in `_hypeToQuote`.
        if (quote == WETH9) {
            if (bridge.length != 0) revert BridgeRefused();
            return quoteIn;
        }
        if (_isPairBridge(bridge)) {
            return _solidlySwap(ISolidlyPairBridge(_pairOf(bridge)), quote, WETH9, quoteIn, address(this));
        }
        uint256 mine = IERC20(quote).balanceOf(address(this));
        uint256[] memory held = _routerHoldings(bridge);
        IERC20(quote).forceApprove(address(SWAP_ROUTER), quoteIn);
        wrapped = SWAP_ROUTER.exactInput(
            ISwapRouter.ExactInputParams({
                path: bridge,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: quoteIn,
                amountOutMinimum: 0
            })
        );
        // The router pulls only what the first pool took; the rest would stay
        // here, the seller's and unreturned.
        if (IERC20(quote).balanceOf(address(this)) + quoteIn != mine) revert BridgeTooThin();
        _requireNothingStranded(bridge, held);
    }

    /**
     * @dev What PRJX's router holds, before a swap, of everything a swap along
     *      `path` could leave behind in it: HYPE, and each token between the
     *      first and the last.
     *
     *      A V3 `exactInput` does not fail when a pool runs out of liquidity.
     *      The pool swaps as far as its last tick and stops, and the classic
     *      SwapRouter keeps what the pool did not take: the unused HYPE of a
     *      native input, or the unused middle token of a two-hop path. Both
     *      then belong to whoever calls its `refundETH` or `sweepToken` first.
     *      Measured on a mainnet fork 2026-09-15: 500 HYPE into a wSPYx-quoted
     *      curve, whose bridge pool can deliver about 86 HYPE of wSPYx in
     *      total — 414 HYPE stayed in PRJX's router and a stranger took it in
     *      one call. The site's quote showed the capped output as the price,
     *      so its slippage guard would not have stopped it.
     */
    function _routerHoldings(bytes memory path) internal view returns (uint256[] memory held) {
        uint256 len = path.length;
        if (len < 43 || (len - 20) % 23 != 0) revert BridgeRefused();
        uint256 hops = (len - 20) / 23;
        held = new uint256[](hops);
        held[0] = address(SWAP_ROUTER).balance;
        for (uint256 i = 1; i < hops; ++i) {
            held[i] = IERC20(_pathToken(path, i)).balanceOf(address(SWAP_ROUTER));
        }
    }

    /// @dev Refuse a swap that left anything in PRJX's router. A bridge too
    ///      thin for the amount is a failed trade, never a partial one with
    ///      the rest handed to a stranger.
    function _requireNothingStranded(bytes memory path, uint256[] memory held) internal view {
        if (address(SWAP_ROUTER).balance > held[0]) revert BridgeTooThin();
        for (uint256 i = 1; i < held.length; ++i) {
            if (IERC20(_pathToken(path, i)).balanceOf(address(SWAP_ROUTER)) > held[i]) {
                revert BridgeTooThin();
            }
        }
    }

    /// @dev The `i`th token of a V3 path: 20 bytes each, 3 bytes of fee between.
    function _pathToken(bytes memory path, uint256 i) internal pure returns (address token) {
        uint256 offset = i * 23;
        assembly {
            token := shr(96, mload(add(add(path, 32), offset)))
        }
    }

    /// @dev Hand the pair `amountIn` of `tokenIn` and ask for what it says that
    ///      is worth. The pair prices off its cached reserves, so asking after
    ///      the transfer is the same as asking before it.
    function _solidlySwap(
        ISolidlyPairBridge pair,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to
    ) private returns (uint256 out) {
        out = pair.getAmountOut(amountIn, tokenIn);
        if (out == 0) revert BridgeRefused();
        IERC20(tokenIn).safeTransfer(address(pair), amountIn);
        (uint256 a0, uint256 a1) = pair.token0() == tokenIn ? (uint256(0), out) : (out, uint256(0));
        uint256 before = IERC20(tokenOut).balanceOf(to);
        // Empty data on purpose: a payload would turn this into a flash swap.
        pair.swap(a0, a1, to, "");
        out = IERC20(tokenOut).balanceOf(to) - before;
    }

    /**
     * @dev The least `tokenIn` that buys `wantOut` from `pair`, or `maxIn` if
     *      even that does not — a bisection over the pair's own quote, which
     *      is the only thing that knows the pair's fee and curve.
     */
    function _solidlyAmountIn(ISolidlyPairBridge pair, address tokenIn, uint256 wantOut, uint256 maxIn)
        internal
        view
        returns (uint256)
    {
        if (maxIn == 0) return 0;
        if (pair.getAmountOut(maxIn, tokenIn) < wantOut) return maxIn;
        uint256 lo;
        uint256 hi = maxIn;
        // Tightens to a millionth of the ceiling, which on any real amount is
        // under a wei of the quote's price impact — about twenty rounds.
        uint256 tolerance = maxIn / 1_000_000 + 1;
        while (hi - lo > tolerance) {
            uint256 mid = (lo + hi) / 2;
            if (pair.getAmountOut(mid, tokenIn) >= wantOut) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    /**
     * @notice What a Solidly bridge hands back for `amountIn` of `tokenIn`, so
     *         the site can quote it. A V3 bridge is quoted through PRJX's own
     *         QuoterV2 instead, which cannot be called from a view.
     */
    function quoteBridgeOut(bytes calldata bridge, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        if (!_isPairBridge(bridge)) revert NotASolidlyBridge();
        return ISolidlyPairBridge(_pairOf(bridge)).getAmountOut(amountIn, tokenIn);
    }

    /// @notice What buying `amountOut` through a Solidly bridge costs in
    ///         `tokenIn`, capped at `maxIn` — the same search the buy makes.
    function quoteBridgeIn(bytes calldata bridge, address tokenIn, uint256 amountOut, uint256 maxIn)
        external
        view
        returns (uint256)
    {
        if (!_isPairBridge(bridge)) revert NotASolidlyBridge();
        return _solidlyAmountIn(ISolidlyPairBridge(_pairOf(bridge)), tokenIn, amountOut, maxIn);
    }

    /**
     * @dev A Uniswap V3 path, hop for hop, backwards: `exactOutput` wants the
     *      output token first. Token (20 bytes), fee (3), token (20), … so the
     *      tokens swap ends and the fees between them stay where they are.
     */
    function _reversed(bytes memory path) internal pure returns (bytes memory out) {
        uint256 len = path.length;
        // 20 + n*23 bytes: one token, then (fee, token) n times.
        if (len < 43 || (len - 20) % 23 != 0) revert BridgeRefused();
        out = new bytes(len);
        uint256 hops = (len - 20) / 23;
        for (uint256 i; i <= hops; ++i) {
            uint256 from = i * 23;
            uint256 to = (hops - i) * 23;
            for (uint256 b; b < 20; ++b) out[to + b] = path[from + b];
            if (i < hops) {
                uint256 ffrom = from + 20;
                uint256 fto = (hops - 1 - i) * 23 + 20;
                for (uint256 b; b < 3; ++b) out[fto + b] = path[ffrom + b];
            }
        }
    }
}
