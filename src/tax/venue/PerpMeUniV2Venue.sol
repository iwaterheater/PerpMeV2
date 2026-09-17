// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {IPerpMeVenue} from "./IPerpMeVenue.sol";

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/// @dev Only the one call needed to see what a pair is holding but has not
///      yet counted.
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/**
 * @title PerpMeUniV2Venue
 * @notice A dividend coin's view of a Uniswap V2 exchange, or any fork of one
 *         that kept the interface — PRJX among them.
 *
 *         This is the code that used to live inside the coin, moved out
 *         unchanged in behaviour: the same constant-product arithmetic, the
 *         same five-minute window, the same refusal below a fifth of the
 *         average. What it gains by being out here is that a second exchange is
 *         a second one of these rather than a second launchpad.
 *
 *         One of these serves every coin on its exchange. It holds nothing.
 */
contract PerpMeUniV2Venue is IPerpMeVenue {
    /// @notice The exchange this speaks for.
    IUniswapV2Factory public immutable FACTORY;

    /**
     * @notice The exchange's swap fee, in basis points of the amount in.
     *
     * @dev Fixed here because on a Uniswap V2 fork it IS fixed — thirty basis
     *      points, in the pair's own bytecode, unreachable by anybody. A venue
     *      that can move its fee needs its own implementation of this interface
     *      that reads it live; it must not be approximated by a constant, which
     *      is the mistake that put this behind an interface in the first place.
     */
    uint16 public immutable FEE_BPS;

    /// @dev Shortest stretch of time this will average a price over. Below it,
    ///      an average is barely more than the price, sandwich included.
    uint32 private constant MIN_WINDOW = 300;
    /// @dev How far under its own recent average a pool may be and still be
    ///      sold into. A backstop, not a brake: a pair of ordinary sells into a
    ///      freshly graduated pool was measured at 27% of its five-minute
    ///      average, so anything tighter refuses honest trading.
    uint16 private constant MIN_BPS = 2000;
    uint16 private constant BPS = 10_000;

    /// @dev Per caller, per pair: the accumulator and the moment it was read.
    ///      Keyed by the caller so a coin's anchor is its own and a stranger
    ///      cannot move it.
    mapping(address caller => mapping(address pair => uint256)) private _cumulativeRef;
    mapping(address caller => mapping(address pair => uint32)) private _refTime;
    /// @dev The last average actually worked out, so a reading taken inside the
    ///      window has something honest to be judged against instead of being
    ///      refused. Refusing was measured on a live coin at 179 of 322 sells.
    mapping(address caller => mapping(address pair => uint256)) private _avgRef;

    error FeeTooHigh(uint16 bps);
    error NoFactory();

    constructor(address factory_, uint16 feeBps_) {
        if (factory_ == address(0)) revert NoFactory();
        // A hundred basis points is already four times what a V2 fork charges;
        // past it the caller has the wrong contract, not an unusual exchange.
        if (feeBps_ > 100) revert FeeTooHigh(feeBps_);
        FACTORY = IUniswapV2Factory(factory_);
        FEE_BPS = feeBps_;
    }

    /// @inheritdoc IPerpMeVenue
    function openPair(address tokenA, address tokenB) external returns (address pair) {
        pair = FACTORY.getPair(tokenA, tokenB);
        if (pair == address(0)) pair = FACTORY.createPair(tokenA, tokenB);
    }

    /// @inheritdoc IPerpMeVenue
    /// @dev None. A Uniswap V2 pair keeps its fee in the reserves, so no
    ///      address outside the pair ever holds the coin on its behalf.
    function feeSinks(address) external pure returns (address, address) {
        return (address(0), address(0));
    }

    /// @inheritdoc IPerpMeVenue
    function amountOut(address pair, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        (uint256 rIn, uint256 rOut) = _reserves(pair, tokenIn);
        if (rIn == 0 || rOut == 0 || amountIn == 0) return 0;
        // Uniswap's own formula, fee and all. The coin is excluded from its own
        // tax, so the pair receives exactly `amountIn` and this is exactly what
        // its invariant will allow back out.
        uint256 inWithFee = amountIn * (BPS - FEE_BPS);
        return (inWithFee * rOut) / (rIn * BPS + inWithFee);
    }

    /**
     * @inheritdoc IPerpMeVenue
     *
     * @dev The reserves a V2 pair reports are a cached number it only refreshes
     *      when somebody swaps or syncs, so a plain transfer into the pair
     *      leaves the balance ahead of them. That gap IS the amount that
     *      arrived, tax already deducted, and it is what Uniswap's own
     *      fee-on-transfer router measures.
     */
    function amountOutUnsynced(address pair, address tokenIn)
        external
        view
        returns (uint256 waiting, uint256 out)
    {
        (uint256 rIn, uint256 rOut) = _reserves(pair, tokenIn);
        if (rIn == 0 || rOut == 0) return (0, 0);
        uint256 held = IERC20Balance(tokenIn).balanceOf(pair);
        // Nothing waiting. Not an error — the caller asked before sending.
        if (held <= rIn) return (0, 0);
        waiting = held - rIn;
        uint256 inWithFee = waiting * (BPS - FEE_BPS);
        out = (inWithFee * rOut) / (rIn * BPS + inWithFee);
    }

    /**
     * @inheritdoc IPerpMeVenue
     *
     * @dev Sizing a sale off the reserves as they stand is no defence against
     *      somebody who moved those reserves a moment earlier: everything
     *      derived from them agrees with the manipulation. The pair's own
     *      accumulator answers that, because it sums over TIME — holding a
     *      price away from the market costs an attacker every block they hold
     *      it, where a sandwich costs them nothing beyond fees.
     *
     *      Returns rather than reverts, and re-anchors on every reading with a
     *      real window behind it, pass or fail. A holder dumping their whole
     *      position took a live pool to 4% of where it had been, which is a
     *      real move and not an attack, and without the re-anchor the tax would
     *      have had no way out until the old average aged off.
     */
    function priceIsSane(address pair) external returns (bool) {
        address coin = msg.sender;
        (uint256 rCoin, uint256 rQuote) = _reserves(pair, coin);
        if (rCoin == 0 || rQuote == 0) return false;

        bool coinIsToken0 = IUniswapV2Pair(pair).token0() == coin;
        uint256 cum = coinIsToken0
            ? IUniswapV2Pair(pair).price0CumulativeLast()
            : IUniswapV2Pair(pair).price1CumulativeLast();

        // The pair only folds elapsed time into the accumulator when somebody
        // trades, so bring it up to now the way Uniswap's own oracle does.
        (,, uint32 tsLast) = IUniswapV2Pair(pair).getReserves();
        uint32 ts = uint32(block.timestamp);
        uint256 spotQ112 = (rQuote << 112) / rCoin;
        unchecked {
            if (tsLast != ts) cum += spotQ112 * uint32(ts - tsLast);
        }

        uint32 refTime = _refTime[coin][pair];
        uint32 age;
        unchecked {
            age = ts - refTime;
        }

        // Nothing to average over yet. Start the clock and wait.
        if (refTime == 0) {
            _refTime[coin][pair] = ts;
            _cumulativeRef[coin][pair] = cum;
            return false;
        }

        if (age < MIN_WINDOW) {
            uint256 lastAvg = _avgRef[coin][pair];
            if (lastAvg == 0) return false;
            return spotQ112 * BPS >= lastAvg * MIN_BPS;
        }

        uint256 avgQ112;
        unchecked {
            avgQ112 = (cum - _cumulativeRef[coin][pair]) / age;
        }
        _refTime[coin][pair] = ts;
        _cumulativeRef[coin][pair] = cum;
        _avgRef[coin][pair] = avgQ112;

        return spotQ112 * BPS >= avgQ112 * MIN_BPS;
    }

    /// @dev The pair's two sides, in the order the caller cares about.
    function _reserves(address pair, address tokenIn)
        private
        view
        returns (uint256 rIn, uint256 rOut)
    {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        return IUniswapV2Pair(pair).token0() == tokenIn
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
    }
}
