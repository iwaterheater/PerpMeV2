// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PerpMeCurve} from "./PerpMeCurve.sol";
import {PerpMeBridge, IWETH9} from "./PerpMeBridge.sol";


/**
 * @title PerpMeCurveRouter
 * @notice Lets somebody holding HYPE trade a coin that is priced in a share.
 *
 *         THE PROBLEM IT SOLVES
 *
 *         A dividend coin is quoted in a tokenized share — wAAPLx, wNVDAx —
 *         because that is what its holders are eventually paid in. Almost
 *         nobody arrives holding one. Without this, the entire audience for a
 *         freshly launched coin is people who already own the right stock
 *         token, which is close to nobody.
 *
 *         WHAT IT DOES
 *
 *         Turns HYPE into the share through the same Uniswap V3 bridge the site
 *         already routes stock-quoted trades through, then trades on the curve
 *         in one transaction. The path is supplied by the caller rather than
 *         hardcoded: the bridge is third-party liquidity, and a route that
 *         stops working should be a front-end change, not a redeployment.
 *
 *         WHY IT MAY HOLD THE COIN
 *
 *         Selling needs the coins in hand for an instant, and a coin on its
 *         curve refuses sideways transfers so that nobody can open a second,
 *         unofficial market. The coin therefore records ONE router address it
 *         will move for, chosen by the factory at launch and never afterwards.
 *         That permission is narrow on purpose: it lets this contract hold the
 *         coin during the curve phase and nothing else. It is not exempt from
 *         the tax, and it earns no dividends.
 */
contract PerpMeCurveRouter is ReentrancyGuard, PerpMeBridge {
    using SafeERC20 for IERC20;

    error NothingReceived();
    error NotWeth();
    error SpentTooMuchNative(uint256 spent, uint256 cap);

    event BoughtWithNative(
        address indexed curve, address indexed buyer, uint256 nativeIn, uint256 tokensOut
    );
    event SoldToNative(
        address indexed curve, address indexed seller, uint256 tokensIn, uint256 nativeOut
    );

    constructor(address swapRouter, address weth9) PerpMeBridge(swapRouter, weth9) {}

    receive() external payable {
        // Only from unwrapping; anything else would be a donation with no way
        // back out, so it is refused rather than quietly kept.
        if (msg.sender != WETH9 && msg.sender != address(SWAP_ROUTER)) revert NotWeth();
    }

    /**
     * @notice Buy a curve-stage coin with the chain's own HYPE.
     *
     * @param curve       The coin's curve.
     * @param bridgePath  Uniswap V3 path from WHYPE to the coin's quote token.
     *                    Supplied by the caller because the bridge is somebody
     *                    else's liquidity and its shape changes without us.
     * @param minTokensOut Slippage guard on the coin, not on the bridge.
     * @param maxNativeIn  The most HYPE this may actually spend; the rest of
     *                     `msg.value` comes back. 0 means "up to all of it".
     *
     *                     This is the guard on the BRIDGE, and it is the only
     *                     one there can be. On a buy that fills the curve the
     *                     coins out are pinned at `tokensLeft()` by
     *                     construction, so `minTokensOut` passes at its
     *                     strongest possible value whatever the bridge
     *                     charged — a trade sandwiched in the bridge pool
     *                     delivers exactly the coins that were promised and
     *                     keeps the difference in HYPE. Measured on a fork:
     *                     a fill that honestly cost 9.30 HYPE cost 10.57
     *                     behind a 600 HYPE front-run, and the buyer's own
     *                     guard could not see it. Only a ceiling on the HYPE
     *                     can.
     *
     * @dev The coins go straight from the curve to the buyer, so this contract
     *      never holds them.
     *
     *      The curve otherwise hands coins only to whoever called it, because
     *      any other destination lets a buyer deliver into a pre-created
     *      Uniswap pair and claim a share of the graduation liquidity. This
     *      contract is the coin's registered router and may name a recipient —
     *      and can only ever name the address that called it, which is what
     *      makes that safe. Taking delivery here instead would settle the tax
     *      while a contract that owns no shares held the coins, and the
     *      holders' dividend would find no owner.
     */
    function buyWithNative(
        PerpMeCurve curve,
        bytes calldata bridgePath,
        uint256 minTokensOut,
        uint256 maxNativeIn
    ) external payable nonReentrant returns (uint256 tokensOut) {
        IERC20 quote = curve.QUOTE();

        // Never more than was sent, and never more than was allowed.
        uint256 cap = maxNativeIn == 0 || maxNativeIn > msg.value ? msg.value : maxNativeIn;

        /*
         * Buy only as much of the quote as the curve can take.
         *
         * This used to convert the whole of `msg.value` first and hand the
         * result to the curve, which refunded whatever was over — in the QUOTE
         * token, at whatever the bridge had already charged for it. On a
         * bridge with real depth that is a rounding matter. On the one for a
         * tokenised share it is not: a buyer sent a thousand HYPE at a curve
         * whose remaining coins cost about a hundred and thirty, into a pool
         * holding five thousand dollars of the share, and got most of the
         * curve plus a sliver of the share back, with the thousand gone into
         * that pool's price. Asking the curve what it needs and buying exactly
         * that means a buyer who sends more than the curve can use gets the
         * difference back in the currency they sent.
         *
         * When `msg.value` cannot cover the fill — the ordinary small buy —
         * the exact-output swap refuses, and everything sent is converted the
         * way it always was. The bridge's price impact on that path is the
         * front end's to show; nothing here can know what "fair" is.
         */
        uint256 needed = curve.quoteToFill();
        if (needed == 0) revert NothingReceived();

        (uint256 quoteIn, uint256 spent) = _hypeToQuote(bridgePath, address(quote), cap, needed);
        if (quoteIn == 0) revert NothingReceived();
        // The bridge is told the cap twice over — as `amountInMaximum` and as
        // the bisection's ceiling — so this cannot trip. Asserted anyway,
        // because the whole guard rests on it.
        if (spent > cap) revert SpentTooMuchNative(spent, cap);

        quote.forceApprove(address(curve), quoteIn);
        tokensOut = curve.buyFor(quoteIn, minTokensOut, msg.sender);

        // Whatever the curve did not take — a wei of rounding now that the
        // amount was sized to it — and every wei of HYPE the bridge did not
        // need, back to the buyer. Both are theirs.
        uint256 dust = quote.balanceOf(address(this));
        if (dust != 0) quote.safeTransfer(msg.sender, dust);
        /*
         * Everything not spent, back to the buyer — the HYPE held back by the
         * cap, the HYPE the fill did not need, and anything PRJX's router
         * handed over with it.
         *
         * `refundETH()` there forwards that contract's ENTIRE balance, so HYPE
         * a stranger parked in it arrives here too. It is the buyer's change
         * either way; what it must not do is make `msg.value - change`
         * underflow and revert the trade, which is why the spend is measured
         * rather than subtracted.
         */
        uint256 change = address(this).balance;
        if (change != 0) {
            (bool ok,) = msg.sender.call{value: change}("");
            if (!ok) revert NothingReceived();
        }

        emit BoughtWithNative(address(curve), msg.sender, spent, tokensOut);
    }

    /**
     * @notice Sell a curve-stage coin back out to HYPE.
     *
     * @param bridgePath  Uniswap V3 path from the quote token back to WHYPE.
     *
     * @dev Unlike buying, this must hold the coin for an instant: the curve
     *      pulls from whoever calls it. That is the whole reason the coin
     *      records a permitted router.
     */
    function sellToNative(
        PerpMeCurve curve,
        uint256 tokensIn,
        bytes calldata bridgePath,
        uint256 minNativeOut
    ) external nonReentrant returns (uint256 nativeOut) {
        IERC20 coin = IERC20(curve.TOKEN());
        IERC20 quote = curve.QUOTE();

        coin.safeTransferFrom(msg.sender, address(this), tokensIn);
        coin.forceApprove(address(curve), tokensIn);
        uint256 quoteOut = curve.sellTo(tokensIn, 0, address(this));
        if (quoteOut == 0) revert NothingReceived();

        uint256 wrapped = _quoteToWrapped(bridgePath, address(quote), quoteOut);
        if (wrapped < minNativeOut) revert NothingReceived();
        IWETH9(WETH9).withdraw(wrapped);
        (bool ok,) = msg.sender.call{value: wrapped}("");
        if (!ok) revert NothingReceived();
        nativeOut = wrapped;

        emit SoldToNative(address(curve), msg.sender, tokensIn, nativeOut);
    }
}
