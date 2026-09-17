// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {IPerpMeVenue} from "./IPerpMeVenue.sol";

/// @dev A Solidly-style pair factory. The third argument is what separates it
///      from Uniswap V2's: every lookup names which curve is meant.
interface ISolidlyFactory {
    function getPair(address tokenA, address tokenB, bool stable) external view returns (address);
    function createPair(address tokenA, address tokenB, bool stable) external returns (address);
}

/// @dev Only the one call needed to see what a pair is holding but has not
///      yet counted.
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

interface ISolidlyPair {
    function token0() external view returns (address);
    /// @dev Where the pair sends the fee it takes. Present on Velodrome-style
    ///      forks (Nest), absent on those that leave the fee in the reserves
    ///      (Ramses legacy) — so both are asked for, not assumed.
    function fees() external view returns (address);
    function communityVault() external view returns (address);
    function getReserves() external view returns (uint256, uint256, uint256);
    /// @dev The pair's own price, fee and all. Uniswap V2 has no equivalent and
    ///      leaves the caller to do the arithmetic.
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    /// @dev A time-weighted average of the same thing, over `granularity`
    ///      recorded observations.
    function quote(address tokenIn, uint256 amountIn, uint256 granularity)
        external
        view
        returns (uint256);
    function observationLength() external view returns (uint256);
}

/**
 * @title PerpMeRamsesVenue
 * @notice A dividend coin's view of Ramses, or of any Solidly fork that kept
 *         the interface.
 *
 *         WHY THIS IS NOT PerpMeUniV2Venue WITH A DIFFERENT ADDRESS
 *
 *         Three things about a Solidly pair differ from a Uniswap V2 one, and
 *         each of them is why the venue had to become a contract:
 *
 *         The fee belongs to the pair, not to the exchange. Measured across
 *         Ramses' thirty legacy pairs: 0.001%, 0.15%, 0.3%, 0.5%, 1% and 2%,
 *         with new pairs opening at 0.5%. Governance can move any of them
 *         afterwards. A fee written into this contract would be wrong for most
 *         pairs on the day it shipped and wrong for the rest eventually, and
 *         wrong here means the pair refuses the sale on its own invariant, on
 *         every trade, forever, inside a try/catch nobody sees. So the fee is
 *         not stored, not read, and not reasoned about: the pair is asked what
 *         it will hand back.
 *
 *         There is no price accumulator. Uniswap V2 keeps one and expects the
 *         reader to divide two readings; a Solidly pair keeps a ring of
 *         observations and exposes `quote`, which is already the average. So
 *         the anti-manipulation check here holds no state at all — the history
 *         it needs is the pair's own, which nobody can reset by deploying a new
 *         one of these.
 *
 *         And a pair is looked up with a third argument saying which curve.
 *         Always false here: a dividend coin against a tokenised share is not a
 *         stable pair, and the stable curve's invariant is not the one the
 *         coin's arithmetic ever assumed.
 */
contract PerpMeRamsesVenue is IPerpMeVenue {
    /// @notice The exchange this speaks for.
    ISolidlyFactory public immutable FACTORY;

    /**
     * @dev The most periods the average is ever taken over.
     *
     *      A Solidly pair does not record an observation per trade. It records
     *      one when a trade crosses a half-hour boundary — measured on a live
     *      Ramses pair by warping a fork in five-minute steps and watching when
     *      the count moved. So four periods is two hours of history, and a coin
     *      that has just graduated has none of it.
     *
     *      This is a ceiling rather than a demand: `priceIsSane` averages over
     *      whatever the pair actually holds, up to this. Asking for more than
     *      exists does not return a worse answer, it reverts, so the number has
     *      to be checked against the pair rather than assumed.
     */
    uint256 private constant MAX_GRANULARITY = 4;

    /**
     * @dev How far under its own average the pair may quote and still be sold
     *      into. Same fifth as the Uniswap V2 venue, and for the same measured
     *      reason: a pair of ordinary sells into a freshly graduated pool was
     *      seen at 27% of its own recent average, so anything tighter refuses
     *      honest trading.
     */
    uint256 private constant MIN_BPS = 2000;
    uint256 private constant BPS = 10_000;

    /**
     * @dev The amount quoted when comparing spot against the average. Small
     *      enough against any real pool that its own price impact does not
     *      colour the comparison, and identical on both sides of it.
     *
     *      Sized from the pool rather than fixed. One coin was the fixed
     *      amount, and one coin is not always worth anything: against UBTC a
     *      coin is worth 0.0057 satoshi, so the pair quoted zero for the probe
     *      — some forks revert outright — and `priceIsSane` answered false
     *      forever. The coin caught that in an empty catch and simply never
     *      liquidated: measured, 1,838,135 coins of tax accrued over eight
     *      sells and not one holder was paid, while the same coin on PRJX had
     *      funded its holders by the fourth period.
     *
     *      A thousandth of the pool's coin side is small enough everywhere
     *      that impact stays under a basis point, and large enough everywhere
     *      that it has a price at all.
     */
    uint256 private constant PROBE_BPS_OF_POOL = 10; // 0.1%
    uint256 private constant PROBE_FLOOR = 1e12;

    error NoFactory();

    constructor(address factory_) {
        if (factory_ == address(0)) revert NoFactory();
        FACTORY = ISolidlyFactory(factory_);
    }

    /// @inheritdoc IPerpMeVenue
    function openPair(address tokenA, address tokenB) external returns (address pair) {
        pair = FACTORY.getPair(tokenA, tokenB, false);
        if (pair == address(0)) pair = FACTORY.createPair(tokenA, tokenB, false);
    }

    /**
     * @inheritdoc IPerpMeVenue
     *
     * @dev Asked of the pair, one call each, and a revert reads as "there is
     *      no such sink" rather than as a failure — Ramses legacy has neither
     *      and keeps its fee in the reserves, while Nest has both and moves
     *      the fee out in the token. The same contract serves both because the
     *      question is asked rather than assumed.
     */
    function feeSinks(address pair) external view returns (address a, address b) {
        try ISolidlyPair(pair).fees() returns (address f) {
            a = f;
        } catch {}
        try ISolidlyPair(pair).communityVault() returns (address v) {
            b = v;
        } catch {}
    }

    /**
     * @inheritdoc IPerpMeVenue
     * @dev The pair's own answer, so the fee it happens to charge today is
     *      neither stored here nor assumed.
     */
    function amountOut(address pair, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        if (amountIn == 0) return 0;
        /* An address with no code answers a call successfully with nothing at
           all, and the decoding of that nothing is an error try/catch does not
           catch — so it has to be refused before the call rather than after. */
        if (pair.code.length == 0) return 0;
        try ISolidlyPair(pair).getAmountOut(amountIn, tokenIn) returns (uint256 out) {
            return out;
        } catch {
            return 0;
        }
    }

    /**
     * @inheritdoc IPerpMeVenue
     *
     * @dev Same cached-reserves gap as on a Uniswap V2 pair — a Solidly pair
     *      keeps `reserve0`/`reserve1` as stored numbers too, and `getAmountOut`
     *      is worked out against those rather than against the balance. So the
     *      amount that actually arrived can be measured here and priced by the
     *      pair itself, fee and curve included.
     */
    function amountOutUnsynced(address pair, address tokenIn)
        external
        view
        returns (uint256 waiting, uint256 out)
    {
        // See `amountOut`: an empty address is not something to ask.
        if (pair.code.length == 0) return (0, 0);

        uint256 rIn;
        try ISolidlyPair(pair).getReserves() returns (uint256 r0, uint256 r1, uint256) {
            rIn = ISolidlyPair(pair).token0() == tokenIn ? r0 : r1;
        } catch {
            return (0, 0);
        }
        if (rIn == 0) return (0, 0);

        uint256 held = IERC20Balance(tokenIn).balanceOf(pair);
        // Nothing waiting. Not an error — the caller asked before sending.
        if (held <= rIn) return (0, 0);
        waiting = held - rIn;

        try ISolidlyPair(pair).getAmountOut(waiting, tokenIn) returns (uint256 quoted) {
            out = quoted;
        } catch {
            return (0, 0);
        }
    }

    /**
     * @inheritdoc IPerpMeVenue
     *
     * @dev Holds no state. The pair records an observation on every trade, so
     *      the history to average over is already there and belongs to the
     *      pair rather than to this contract.
     *
     *      A pair too young to have `GRANULARITY` observations reads as "not
     *      sane", which is the same answer the Uniswap V2 venue gives before
     *      its first window closes: refuse the first sale rather than sell
     *      against a price nothing has been averaged over yet.
     */
    function priceIsSane(address pair) external returns (bool) {
        address coin = msg.sender;
        // See `amountOut`: an empty address is not something to ask.
        if (pair.code.length == 0) return false;

        uint256 observations;
        try ISolidlyPair(pair).observationLength() returns (uint256 n) {
            observations = n;
        } catch {
            return false;
        }
        /*
         * Average over as much history as there is, up to two hours of it.
         *
         * A fixed four periods would have refused every sale for the first two
         * hours after a graduation, which is exactly the window in which a new
         * coin trades hardest and its holders are owed the most. One completed
         * period is still a half-hour time-weighted average, which is six times
         * the window the Uniswap V2 venue settles for.
         */
        uint256 granularity = observations > MAX_GRANULARITY ? MAX_GRANULARITY : observations - 1;
        if (granularity == 0) return false;

        uint256 probe = _probeFor(pair, coin);
        if (probe == 0) return false;

        uint256 spot;
        try ISolidlyPair(pair).getAmountOut(probe, coin) returns (uint256 out) {
            spot = out;
        } catch {
            return false;
        }
        if (spot == 0) return false;

        uint256 average;
        try ISolidlyPair(pair).quote(coin, probe, granularity) returns (uint256 avg) {
            average = avg;
        } catch {
            return false;
        }
        if (average == 0) return false;

        return spot * BPS >= average * MIN_BPS;
    }

    /// @dev A tenth of a percent of the coins the pair holds, never below a
    ///      floor that keeps the quote off zero on a pool that is nearly empty.
    function _probeFor(address pair, address coin) private view returns (uint256) {
        uint256 held = IERC20Balance(coin).balanceOf(pair);
        if (held == 0) return 0;
        uint256 probe = (held * PROBE_BPS_OF_POOL) / BPS;
        return probe < PROBE_FLOOR ? PROBE_FLOOR : probe;
    }
}
