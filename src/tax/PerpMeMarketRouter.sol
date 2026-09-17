// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PerpMeTaxToken} from "./PerpMeTaxToken.sol";
import {IPerpMeVenue} from "./venue/IPerpMeVenue.sol";
import {PerpMeBridge, IWETH9} from "./PerpMeBridge.sol";


/// @dev The two calls that a Uniswap V2 pair and a Solidly pair spell exactly
///      the same way. Everything they disagree about lives behind the venue.
interface IPair {
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)
        external;
}

/**
 * @title PerpMeMarketRouter
 * @notice Buying and selling a GRADUATED dividend coin with the chain's own
 *         HYPE, in one transaction.
 *
 *         WHY IT HAS TO EXIST
 *
 *         `PerpMeCurveRouter` does this while the coin is still on its curve.
 *         The moment it graduates, that route ends and there is nothing behind
 *         it — which was measured rather than assumed:
 *
 *           - a coin is quoted in a tokenised share, and HYPE only reaches
 *             those shares through PRJX V3 (the WHYPE/wNVDAx 1% pool is one we
 *             opened ourselves; there is no V2 pair for it at all);
 *           - the coin itself lands in a V2-style pair;
 *           - and PRJX deploys the CLASSIC SwapRouter, which has no V2 leg —
 *             `swapExactTokensForTokens` is a SwapRouter02 function and its
 *             selector is simply absent from the deployed bytecode.
 *
 *         So the journey crosses two exchanges and no single router on this
 *         chain can carry it. Without this contract a graduated coin is buyable
 *         only by people who already hold the right share, which is close to
 *         nobody — the same audience problem the curve router was written for,
 *         reappearing the day a coin succeeds.
 *
 *         HOW IT CROSSES THE SECOND LEG
 *
 *         Not through the venue's own router — Ramses spells its swap with a
 *         `route[]` of `(from, to, stable)` where PRJX spells it with a flat
 *         `address[]`, so one of those would have had to be chosen. It goes to
 *         the PAIR instead, whose `swap` is byte-for-byte the same call on
 *         both, and asks the coin's own venue how much to ask for. A venue
 *         added later brings its arithmetic with it and this contract does not
 *         move.
 *
 *         It holds nothing between transactions, has no owner, and takes no
 *         fee. The coin's tax applies to its legs exactly as to anybody's.
 */
contract PerpMeMarketRouter is ReentrancyGuard, PerpMeBridge {
    using SafeERC20 for IERC20;

    error NotGraduated();
    error NothingReceived();
    error NotWrappedNative();
    error TooLittleOut(uint256 got, uint256 wanted);
    error NotWeth();

    event BoughtWithNative(
        address indexed coin, address indexed buyer, uint256 nativeIn, uint256 coinsOut
    );
    event SoldToNative(
        address indexed coin, address indexed seller, uint256 coinsIn, uint256 nativeOut
    );

    constructor(address swapRouter, address weth9) PerpMeBridge(swapRouter, weth9) {}

    receive() external payable {
        // Only from unwrapping; anything else would be a donation with no way
        // back out, so it is refused rather than quietly kept.
        if (msg.sender != WETH9 && msg.sender != address(SWAP_ROUTER)) revert NotWeth();
    }

    /**
     * @notice Buy a graduated coin with HYPE.
     *
     * @param bridgePath  V3 path from WHYPE to the coin's quote token. Empty
     *                    for a coin quoted in HYPE itself, which needs no
     *                    bridge and only has to be wrapped. Supplied by the
     *                    caller because the bridge is somebody else's
     *                    liquidity: a pool that drains should be a front-end
     *                    route change, never a redeployment.
     * @param minCoinsOut Measured on what the BUYER ends up holding, so the
     *                    coin's buy tax is inside the number rather than a
     *                    surprise underneath it.
     */
    function buyWithNative(
        PerpMeTaxToken coin,
        bytes calldata bridgePath,
        uint256 minCoinsOut
    ) external payable nonReentrant returns (uint256 coinsOut) {
        address pair = coin.pair();
        if (pair == address(0)) revert NotGraduated();
        address quote = coin.pairToken();

        uint256 quoteIn;
        if (bridgePath.length == 0) {
            if (quote != WETH9) revert NotWrappedNative();
            IWETH9(WETH9).deposit{value: msg.value}();
            quoteIn = msg.value;
        } else {
            (quoteIn, ) = _hypeToQuote(bridgePath, quote, msg.value, 0);
        }
        if (quoteIn == 0) revert NothingReceived();

        IERC20(quote).safeTransfer(pair, quoteIn);

        uint256 before = coin.balanceOf(msg.sender);
        _pairSwap(coin.venue(), pair, quote, msg.sender);
        coinsOut = coin.balanceOf(msg.sender) - before;
        if (coinsOut < minCoinsOut) revert TooLittleOut(coinsOut, minCoinsOut);

        emit BoughtWithNative(address(coin), msg.sender, msg.value, coinsOut);
    }

    /**
     * @notice Sell a graduated coin back out to HYPE.
     *
     * @dev The coins go straight from the seller INTO the pair, never through
     *      this contract. That is not tidiness: a stop here would be an
     *      untaxed sideways transfer that briefly made this contract a holder,
     *      and a holder is somebody the dividend accounting has to make room
     *      for. Sending them to the pair is the sale itself, so the tax lands
     *      exactly where it would have without this contract standing there.
     */
    function sellToNative(
        PerpMeTaxToken coin,
        uint256 coinsIn,
        bytes calldata bridgePath,
        uint256 minNativeOut
    ) external nonReentrant returns (uint256 nativeOut) {
        address pair = coin.pair();
        if (pair == address(0)) revert NotGraduated();
        IERC20 quote = IERC20(coin.pairToken());

        // Taxed, and it may set the coin's own liquidation going — both of
        // which happen before the swap below reads what actually arrived.
        IERC20(address(coin)).safeTransferFrom(msg.sender, pair, coinsIn);

        uint256 quoteBefore = quote.balanceOf(address(this));
        _pairSwap(coin.venue(), pair, address(coin), address(this));
        uint256 quoteOut = quote.balanceOf(address(this)) - quoteBefore;
        if (quoteOut == 0) revert NothingReceived();

        uint256 wrapped;
        if (bridgePath.length == 0) {
            if (address(quote) != WETH9) revert NotWrappedNative();
            wrapped = quoteOut;
        } else {
            wrapped = _quoteToWrapped(bridgePath, address(quote), quoteOut);
        }
        if (wrapped < minNativeOut) revert TooLittleOut(wrapped, minNativeOut);

        IWETH9(WETH9).withdraw(wrapped);
        (bool ok,) = msg.sender.call{value: wrapped}("");
        if (!ok) revert NothingReceived();
        nativeOut = wrapped;

        emit SoldToNative(address(coin), msg.sender, coinsIn, nativeOut);
    }

    /**
     * @notice Buy a graduated coin with its own pair token.
     *
     * @dev Here as well as on the venue's router so the site has ONE address
     *      to trade a graduated coin through on any exchange. PRJX's router
     *      takes a flat `address[]` path and Ramses' takes a `route[]` of
     *      (from, to, stable); this takes neither, because the pair is asked
     *      directly. The quote goes from the buyer straight INTO the pair —
     *      this contract never holds it.
     */
    function buy(PerpMeTaxToken coin, uint256 quoteIn, uint256 minCoinsOut)
        external
        nonReentrant
        returns (uint256 coinsOut)
    {
        address pair = coin.pair();
        if (pair == address(0)) revert NotGraduated();
        if (quoteIn == 0) revert NothingReceived();

        IERC20(coin.pairToken()).safeTransferFrom(msg.sender, pair, quoteIn);

        uint256 before = coin.balanceOf(msg.sender);
        _pairSwap(coin.venue(), pair, coin.pairToken(), msg.sender);
        coinsOut = coin.balanceOf(msg.sender) - before;
        if (coinsOut < minCoinsOut) revert TooLittleOut(coinsOut, minCoinsOut);
    }

    /**
     * @notice Sell a graduated coin for its own pair token.
     *
     * @dev Coins go from the seller straight into the pair and the quote comes
     *      from the pair straight back to the seller; nothing pauses here. See
     *      `sellToNative` for why that matters to the dividend accounting.
     */
    function sell(PerpMeTaxToken coin, uint256 coinsIn, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        address pair = coin.pair();
        if (pair == address(0)) revert NotGraduated();
        IERC20 quote = IERC20(coin.pairToken());

        IERC20(address(coin)).safeTransferFrom(msg.sender, pair, coinsIn);

        uint256 before = quote.balanceOf(msg.sender);
        _pairSwap(coin.venue(), pair, address(coin), msg.sender);
        quoteOut = quote.balanceOf(msg.sender) - before;
        if (quoteOut < minQuoteOut) revert TooLittleOut(quoteOut, minQuoteOut);
    }

    /**
     * @dev Swap whatever of `tokenIn` is already sitting in `pair`.
     *
     *      The amount is never passed in. A dividend coin keeps part of a
     *      transfer into the pair, and the pair's own liquidation can move its
     *      reserves in the middle of that same transfer, so the only number
     *      that survives both is the gap between what the pair holds and what
     *      it last counted. The venue reads that gap and prices it.
     */
    function _pairSwap(IPerpMeVenue venue, address pair, address tokenIn, address to) private {
        (, uint256 out) = venue.amountOutUnsynced(pair, tokenIn);
        if (out == 0) revert NothingReceived();

        (uint256 amount0Out, uint256 amount1Out) =
            IPair(pair).token0() == tokenIn ? (uint256(0), out) : (out, uint256(0));
        // Empty data on purpose: a payload here would turn the pair into a
        // flash loan and call back into `to`.
        IPair(pair).swap(amount0Out, amount1Out, to, "");
    }
}
