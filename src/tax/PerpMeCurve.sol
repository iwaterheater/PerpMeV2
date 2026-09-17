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

interface IUniswapV2Pair {
    function mint(address to) external returns (uint256 liquidity);
}

interface IPerpMeTaxFactory {
    function onGraduated(address token, address pair, uint256 tokens, uint256 quote) external;
}

/**
 * @title PerpMeCurve
 * @notice The venue a coin trades on before it has a pool.
 *
 *         WHY THIS EXISTS
 *
 *         A Uniswap V2 pair cannot be opened one-sided: its price is the ratio
 *         of two balances, so somebody must put up the quote side. Asking the
 *         creator for it made launching cost real money — a hundred wNVDAx to
 *         open at twenty thousand dollars — and that money is unrecoverable,
 *         because the LP is burned. This contract removes that barrier the way
 *         every launchpad of this shape does: it IS the market until there is
 *         enough quote token to open a real one, and the quote comes from the
 *         buyers rather than from the creator.
 *
 *         HOW THE PRICE WORKS
 *
 *         Constant product on VIRTUAL reserves. The curve holds no quote token
 *         at the start, but prices as though it held `virtualQuote` — so the
 *         first buyer faces a sane price instead of dividing by zero. Selling
 *         is the same curve walked backwards, so nobody is trapped: a buyer can
 *         always exit at the price the curve owes them.
 *
 *         WHAT GRADUATION DOES
 *
 *         When the last coin allotted to the curve is sold, the curve opens the
 *         Uniswap V2 pair itself: the coins it held back plus every quote token
 *         it collected, LP burned on the spot. From that moment the coin is an
 *         ordinary pair-traded token with its tax and dividends live, and this
 *         contract is finished — it holds nothing and can do nothing.
 *
 *         WHY THE COIN IS FROZEN UNTIL THEN
 *
 *         During the curve phase the coin refuses every transfer that does not
 *         involve this contract. Not to control holders — they can buy and sell
 *         here freely — but because a coin that can be moved anywhere can be
 *         put into a Uniswap pair by anyone, and then there are two markets
 *         with two prices, one of which the curve knows nothing about. Every
 *         launchpad that skipped this has been arbitraged for exactly that.
 */
contract PerpMeCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 private constant BPS = 10_000;
    /**
     * @dev Ceiling on the platform's cut of a curve trade.
     *
     *      A constant here rather than a number the factory picks, for the same
     *      reason the coin caps its own tax: this is the one charge a buyer on
     *      the curve cannot avoid or negotiate, and the bound should be
     *      readable in the contract taking it. Three percent, where the nearest
     *      comparable launchpad on this chain charges one and a half.
     */
    uint16 public constant MAX_TRADE_FEE_BPS = 300;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    address public immutable FACTORY;
    address public immutable TOKEN;
    IERC20 public immutable QUOTE;
    address public immutable TREASURY;

    /**
     * @dev Which of the two assets sorts first, the way Uniswap orders a pair.
     *
     *      Only used to answer `token0`/`token1`/`getReserves` and to lay out
     *      the V2 events below. See the note on those.
     */
    bool private immutable TOKEN_IS_0;

    /// @dev Platform's cut of every trade on the curve, in basis points. This
    ///      is the launchpad's income during the phase it is the counterparty;
    ///      after graduation it earns from the coin's tax instead.
    uint16 public immutable TRADE_FEE_BPS;

    /**
     * @dev The coin's own tax, charged HERE as a surcharge on the fee above.
     *
     *      Dividends do not wait for the pair. The tax cannot be taken in coins
     *      while the curve is the market — there is no pool to sell them into —
     *      so it is taken in quote alongside the trading fee and handed to the
     *      distributor, which pays holders exactly as it will after graduation.
     *      A buyer on a 3%-tax coin therefore pays TRADE_FEE_BPS + 300 here,
     *      and the coins they hold start earning from the very next trade.
     *
     *      Read from the coin on every trade, not copied at construction. The
     *      coin's rates can be LOWERED by the platform after launch, and a
     *      curve that had cached them would go on charging the old rate on
     *      exactly the trades where the change was meant to show. Kept as
     *      functions under the old names so nothing reading the curve's ABI
     *      has to change.
     */
    function BUY_TAX_BPS() public view returns (uint16) {
        return PerpMeTaxToken(TOKEN).buyTaxBps();
    }

    function SELL_TAX_BPS() public view returns (uint16) {
        return PerpMeTaxToken(TOKEN).sellTaxBps();
    }

    /// @dev The coin's dividend distributor — where the surcharge is delivered.
    address public immutable DIVIDEND_SINK;
    /**
     * @notice The pool this coin will graduate into, closed until it does.
     *
     * @dev Read from the coin at construction rather than checked against it on
     *      every trade: the coin computes it once at launch and it cannot move.
     */
    address public immutable RESERVED_PAIR;

    /**
     * @dev Priced as if these were held; they move with every trade.
     *
     *      Every division below rounds so the CURVE keeps the remainder, never
     *      the trader. That is not pedantry: with the rounding the other way
     *      the constant product shrinks a little on each buy, and selling the
     *      same coins straight back returns more quote than was paid for them —
     *      a free, repeatable withdrawal that drains the curve one wei at a
     *      time. Rounding toward the curve makes the product monotonically
     *      non-decreasing, so a round trip can only ever cost money.
     */
    uint256 public virtualToken;
    uint256 public virtualQuote;
    /// @dev The starting quote reserve, so real holdings can be derived from it.
    uint256 public immutable VIRTUAL_QUOTE_0;

    /// Coins offered here in total, and how many are still available.
    uint256 public immutable CURVE_TOKENS;
    uint256 public tokensLeft;
    /// Coins held back to open the pair with.
    uint256 public immutable MIGRATION_TOKENS;

    bool public graduated;
    address public pair;

    error OnlyFactory();
    error AlreadyGraduated();
    error NotGraduatedYet();
    error ZeroAmount();
    error Slippage(uint256 got, uint256 wanted);
    error TradeFeeTooHigh(uint16 bps);
    error BadCurveParams();
    error BadRecipient();

    /**
     * @dev `fee` is the platform's cut; `tax` is the coin's, which the curve
     *      also charges so dividends run before the pair exists.
     *
     *      Both are reported because neither alone describes the trade. An
     *      indexer reconstructing the curve's reserve needs what the curve
     *      KEPT — `quoteIn - fee - tax` on a buy, `quoteOut + fee + tax` off it
     *      on a sell — and a reader shown only `fee` would understate the
     *      charge and overstate both the raised total and the price.
     */
    event Bought(
        address indexed buyer, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax
    );
    event Sold(
        address indexed seller, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax
    );
    event Graduated(address indexed pair, uint256 tokens, uint256 quote);

    /**
     * @dev Uniswap V2's own two events, emitted ALONGSIDE the ones above.
     *
     *      A coin on the curve is invisible. Nobody — no chart site, no
     *      aggregator, no wallet — has an integration with this launchpad; they
     *      scan the chain for the standard pair events and read the standard
     *      views, and a curve that speaks only `Bought` and `Sold` may as well
     *      not exist. That silence falls over exactly the phase when a coin is
     *      being traded hardest and needs to be findable, and it lifts only at
     *      graduation, when a real pair finally appears.
     *
     *      So the curve answers the questions a pair answers. It is NOT a pair
     *      and does not pretend to be one where it matters: `swap` is not the
     *      V2 selector and there is no `mint`, `burn` or `skim`, so anything
     *      that tries to ROUTE a trade through here fails loudly rather than
     *      quietly mispricing somebody. This is compatibility for reading.
     */
    event Sync(uint112 reserve0, uint112 reserve1);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    constructor(
        address token,
        address quote,
        address treasury,
        uint256 virtualToken_,
        uint256 virtualQuote_,
        uint256 curveTokens,
        uint256 migrationTokens,
        uint16 tradeFeeBps
    ) {
        if (tradeFeeBps > MAX_TRADE_FEE_BPS) revert TradeFeeTooHigh(tradeFeeBps);
        // The virtual token reserve must cover everything on offer, or the
        // curve runs out of virtual inventory before it runs out of real coins
        // and the price diverges to infinity mid-launch.
        if (virtualQuote_ == 0 || curveTokens == 0 || virtualToken_ <= curveTokens) {
            revert BadCurveParams();
        }

        FACTORY = msg.sender;
        TOKEN = token;
        QUOTE = IERC20(quote);
        TREASURY = treasury;
        virtualToken = virtualToken_;
        virtualQuote = virtualQuote_;
        VIRTUAL_QUOTE_0 = virtualQuote_;
        CURVE_TOKENS = curveTokens;
        tokensLeft = curveTokens;
        MIGRATION_TOKENS = migrationTokens;
        TRADE_FEE_BPS = tradeFeeBps;
        TOKEN_IS_0 = token < quote;

        DIVIDEND_SINK = address(PerpMeTaxToken(token).distributor());
        RESERVED_PAIR = PerpMeTaxToken(token).reservedPair();
    }

    /**
     * @dev Hand the coin's tax to the distributor and have the coin split it.
     *
     *      Wrapped, like every other dividend call in this codebase: a trade
     *      must never fail because of the machinery that pays holders. If the
     *      split reverts, the quote is already in the distributor and simply
     *      stays unattributed, which means the next deposit hands it to holders
     *      instead. Nobody's trade is lost and no money is.
     */
    /**
     * @dev The platform's own cut, and it may not stop a trade either.
     *
     *      Same shape as `_payTax` and for the same reason: the quote assets
     *      here are tokenized shares that can refuse a recipient. Our treasury
     *      being refused should cost us the fee, not cost everyone the market.
     *      An unsent fee stays with the curve and reaches the pair at
     *      graduation.
     */
    function _payFee(uint256 amount) private {
        if (amount == 0) return;
        try IERC20(address(QUOTE)).transfer(TREASURY, amount) returns (bool) {} catch {}
    }

    function _payTax(uint256 amount) private {
        if (amount == 0) return;

        /*
         * The TRANSFER is caught too, not just the split.
         *
         * It was outside the guard, which put a fresh way to kill the coin
         * right on the trading path: the quote assets here are tokenized
         * shares, and one that refuses a recipient — a screen, a freeze, a
         * blacklist — would revert every single buy and sell on the curve, for
         * everybody, permanently. The post-graduation path has tolerated
         * exactly this since its own audit; the curve had no business being
         * stricter.
         *
         * Refused tax stays with the curve. It is then indistinguishable from
         * raised quote and goes into the pair at graduation, so it is not lost
         * to anyone — the holders simply do not get that tranche as a dividend.
         * A trade that still happens beats a market that stops.
         */
        try IERC20(address(QUOTE)).transfer(DIVIDEND_SINK, amount) returns (bool ok) {
            if (!ok) return;
        } catch {
            return;
        }

        try PerpMeTaxToken(TOKEN).settleCurveTax(amount) {} catch {}
    }

    /// @dev Division that rounds up. Written out rather than imported so the
    ///      rounding direction is visible at the one place it matters.
    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : ((a - 1) / b) + 1;
    }

    /**
     * @notice Quote token the curve has actually collected — the property of
     *         the future pair.
     * @dev Derived from the virtual reserve rather than accumulated separately.
     *      Two counters that are meant to move together eventually do not, and
     *      the one that drifts is discovered by an underflow in somebody's
     *      sale. There is only one number here, so there is nothing to drift.
     */
    function quoteRaised() public view returns (uint256) {
        return virtualQuote - VIRTUAL_QUOTE_0;
    }

    /**
     * @notice What buying everything still on the curve costs, in the quote
     *         token, fee and tax included — the most any buy can usefully
     *         bring.
     *
     * @dev The same arithmetic `buyFor` runs when a buy overshoots, in the
     *      other direction: the net the curve must receive for `tokensLeft`,
     *      then the fee and tax grossed back on top of it. Here so that a
     *      router paying in another currency can buy exactly this much of the
     *      quote and no more. Without it the curve router converted a buyer's
     *      whole HYPE first and asked afterwards: one buyer sent a thousand
     *      HYPE at a curve that needed a hundred and thirty, the bridge pool
     *      was five thousand dollars deep, and the rest of the thousand went
     *      into that pool's price rather than into anything the buyer holds.
     */
    function quoteToFill() external view returns (uint256) {
        if (graduated || tokensLeft == 0) return 0;
        uint256 k = virtualToken * virtualQuote;
        uint256 net = _ceilDiv(k, virtualToken - tokensLeft) - virtualQuote;
        uint16 totalBps = TRADE_FEE_BPS + BUY_TAX_BPS();
        // Grossed up the way `buyFor` grosses a trimmed buy, rounded up so the
        // amount quoted here never falls a wei short of the amount it takes.
        return net + _ceilDiv(net * totalBps, BPS - totalBps);
    }

    function token0() external view returns (address) {
        return TOKEN_IS_0 ? TOKEN : address(QUOTE);
    }

    function token1() external view returns (address) {
        return TOKEN_IS_0 ? address(QUOTE) : TOKEN;
    }

    /**
     * @notice The curve's reserves, in the shape a Uniswap V2 pair reports them.
     *
     * @dev These are the VIRTUAL reserves — the numbers the price is actually
     *      computed from — not what the contract holds. Reporting the real
     *      holdings would quote a price the curve will not trade at, which is
     *      worse than the overstatement of depth this carries: a reader sees
     *      more liquidity than could ever be withdrawn, because none of it can
     *      be withdrawn at all. It is a curve.
     *
     *      uint112 is the pair's own width. Both reserves are bounded by the
     *      launch parameters — a supply of 1e27 against a ceiling of 5.19e33 —
     *      so the cast cannot silently wrap, and the check says so out loud.
     */
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
    {
        (uint112 rT, uint112 rQ) = _reserves112();
        return
            TOKEN_IS_0 ? (rT, rQ, uint32(block.timestamp)) : (rQ, rT, uint32(block.timestamp));
    }

    function _reserves112() private view returns (uint112, uint112) {
        if (virtualToken > type(uint112).max || virtualQuote > type(uint112).max) {
            revert BadCurveParams();
        }
        return (uint112(virtualToken), uint112(virtualQuote));
    }

    /// @dev Emitted after every trade, so an indexer that follows `Sync` keeps a
    ///      correct price without knowing anything about this contract.
    function _emitSync() private {
        (uint112 rT, uint112 rQ) = _reserves112();
        if (TOKEN_IS_0) emit Sync(rT, rQ);
        else emit Sync(rQ, rT);
    }

    /// @notice Coins per quote token right now, scaled by 1e18.
    function spotPrice() external view returns (uint256) {
        return (virtualQuote * 1e18) / virtualToken;
    }

    /// @notice How far along the curve is, in basis points. Drives the
    ///         progress bar the site already draws for graduation.
    function progressBps() external view returns (uint256) {
        return ((CURVE_TOKENS - tokensLeft) * BPS) / CURVE_TOKENS;
    }

    /**
     * @notice Buy coins from the curve.
     * @param quoteIn      Quote token to spend. Pulled from the caller.
     * @param minTokensOut Slippage guard.
     *
     * @dev The final buy is trimmed to whatever the curve has left, and the
     *      unused quote is returned rather than kept. Without that, whoever
     *      happened to send the last, oversized order would silently pay for
     *      coins that do not exist.
     */
    function buy(uint256 quoteIn, uint256 minTokensOut)
        external
        returns (uint256 tokensOut)
    {
        return buyFor(quoteIn, minTokensOut, msg.sender);
    }

    /**
     * @notice Buy, and send the coins somewhere other than the caller.
     *
     * @dev Exists so a router can pay for the trade and have the coins land
     *      straight in the buyer's wallet. Without it the router would have to
     *      hold them for an instant and pass them on — and a coin on its curve
     *      refuses exactly that kind of sideways transfer, on purpose.
     *
     *      Safe to leave open: the quote token is pulled from whoever calls,
     *      so a caller can only ever spend their own money, and directing the
     *      result elsewhere is a gift rather than a theft.
     */
    function buyFor(uint256 quoteIn, uint256 minTokensOut, address to)
        public
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (graduated) revert AlreadyGraduated();
        if (quoteIn == 0) revert ZeroAmount();
        /*
         * The buyer is the only address the curve will hand coins to.
         *
         * This used to accept any destination, which quietly punched through
         * the coin's curve-phase freeze: that freeze permits anything the curve
         * sends, so naming a Uniswap pair here delivered coins into a pool that
         * was not supposed to exist yet. A Uniswap V2 pair address is CREATE2
         * and therefore known BEFORE it is created, so no check against the
         * factory catches it — the coins can be parked at the address first and
         * the pair conjured around them afterwards. Add the quote side, mint LP,
         * and wait: graduation then pours the entire migration allocation and
         * everything the curve raised into that pool, and the LP already sitting
         * there is a claim on it. Measured on a fork: 4 wNVDAx in, 21.6 of the
         * 41.8 raised back out, plus 214M coins.
         *
         * The coin's own registered router is the one exception, and it has to
         * be. It buys on somebody's behalf and can only ever name the address
         * that called IT, so it cannot be pointed at a pair — an attacker would
         * have to make the pair call the router, and a pair address has no code
         * until it is created and cannot make calls of its own afterwards.
         *
         * The alternative, having the router take delivery and forward, was
         * tried and shipped a quieter bug: the tax is settled while the curve
         * still holds the coins, so with the router as the recipient nobody was
         * a holder yet, the dividend found no owner and fell through to the
         * orphan path. Every purchase paid in HYPE donated its holders' slice to
         * the protocol. Found on the first live trade, not by any test.
         */
        /*
         * The pool is closed to everyone, and that check comes FIRST.
         *
         * The coin refuses transfers into its reserved pair, but exempts the
         * addresses that have to fill it — the curve among them. So a coin
         * arriving FROM the curve is not checked there at all, and the only
         * thing standing between a caller and the reserved pool was the rule
         * below: name yourself, unless you are the registered router.
         *
         * That exemption was granted to an ADDRESS, not to a behaviour. It is
         * true of the router that is deployed, because that one always passes
         * its own caller — and of no other. A router that named the reserved
         * pair instead would park coins in a pool that does not exist yet, have
         * it created around them, mint LP against them and wait for graduation
         * to pour the migration allocation in on top. Measured on a fork at 8
         * wNVDAx in, 23.6 back out plus 214M coins.
         *
         * Closed here, before anyone is asked who they are, the exemption is
         * safe no matter who holds it or how they are written.
         */
        if (to == RESERVED_PAIR) revert BadRecipient();

        /*
         * Otherwise: name yourself, unless you are the factory or the coin's
         * registered router.
         *
         * Both buy on somebody else's behalf and must be able to say so. The
         * factory's opening buy used to be made in its own name and forwarded
         * afterwards, which quietly cost the holders their slice of it: the tax
         * is settled while the buyer is still the factory, the factory is
         * excluded from dividends, so at that moment the coin had no holders at
         * all and the whole dividend fell through to the orphan path and into
         * the treasury. Measured at 0.2021 wNVDAx of every 10 bought — on every
         * launch that opened with a buy.
         */
        if (
            to != msg.sender && msg.sender != FACTORY
                && msg.sender != PerpMeTaxToken(TOKEN).curveRouter()
        ) {
            revert BadRecipient();
        }

        QUOTE.safeTransferFrom(msg.sender, address(this), quoteIn);

        uint16 buyTaxBps = BUY_TAX_BPS();
        uint16 totalBps = TRADE_FEE_BPS + buyTaxBps;
        uint256 fee = (quoteIn * TRADE_FEE_BPS) / BPS;
        uint256 tax = (quoteIn * buyTaxBps) / BPS;
        uint256 net = quoteIn - fee - tax;

        uint256 k = virtualToken * virtualQuote;
        tokensOut = virtualToken - _ceilDiv(k, virtualQuote + net);

        uint256 refund;
        if (tokensOut > tokensLeft) {
            // Trim to what is actually on offer, then work backwards: the quote
            // that buys exactly that many coins, and the fee that sits on top
            // of it. Everything the buyer sent beyond that goes back to them.
            // Without this the person who happens to send the last, oversized
            // order pays in full for coins that do not exist.
            tokensOut = tokensLeft;
            net = _ceilDiv(k, virtualToken - tokensOut) - virtualQuote;

            // The fee is grossed back up from the trimmed `net`, and that
            // arithmetic rounds separately from the fee already taken off the
            // way in. On an order that clears the curve by a hair the two
            // roundings can disagree by a wei, and the recomputed fee then asks
            // for more than the buyer still has on the table — which used to
            // underflow the refund and revert the very trade that graduates the
            // coin. The fee takes what is left over and never more; the curve
            // still receives `net` in full, so only the treasury gives up the
            // odd wei.
            uint256 available = quoteIn - net; // net was trimmed downwards
            uint256 charged = (net * totalBps) / (BPS - totalBps);
            if (charged > available) charged = available;
            // Split the way it would have been split on the way in.
            fee = (charged * TRADE_FEE_BPS) / totalBps;
            tax = charged - fee;
            refund = available - charged;
        }
        if (tokensOut < minTokensOut) revert Slippage(tokensOut, minTokensOut);

        virtualToken -= tokensOut;
        virtualQuote += net;
        tokensLeft -= tokensOut;

        _payFee(fee);
        if (refund != 0) QUOTE.safeTransfer(msg.sender, refund);
        /*
         * The tax is shared out BEFORE the buyer holds the coins.
         *
         * The other order made the buyer a holder of the very split their own
         * tax paid for, so they took back their share of it. On the first
         * staging coin (2026-09-15) the creator's opening buy got the entire
         * holders' slice back, and the second buyer, at 65% of the float, 11.63
         * of the 31.53 RAM of tax they paid: a 4% tax that cost them about
         * 2.5%, paid for by everybody who already held. Pro-rata is right for
         * OTHER people's taxes — a large holder should get most of those —
         * but not for a refund of one's own.
         *
         * This order was tried once before and reverted, because the opening
         * buy then has nobody to pay and its holders' slice goes to the
         * protocol through the orphan path in `_distribute`. That is now the
         * intent (decided 2026-09-15): the opening buy — usually the creator's
         * own — pays its tax like every other, rather than to itself. A sale
         * already worked this way: its coins reach the curve before the split.
         */
        _payTax(tax);
        IERC20(TOKEN).safeTransfer(to, tokensOut);

        emit Bought(to, quoteIn - refund, tokensOut, fee, tax);
        /*
         * The V2 view of the same trade, in the amounts that MOVED the curve.
         *
         * Uniswap reports the gross input because its fee stays in the pool;
         * ours leaves it, so gross here would not reconcile with the reserves
         * an indexer reads a line later, and the price it derived would drift
         * by the fee on every trade.
         */
        if (TOKEN_IS_0) emit Swap(msg.sender, 0, net, tokensOut, 0, to);
        else emit Swap(msg.sender, net, 0, 0, tokensOut, to);
        _emitSync();

        // The curve is empty: open the real market in the same transaction, so
        // there is never a moment where the coin has no venue at all.
        if (tokensLeft == 0) _graduate();
    }

    /// @notice Sell coins back to the curve at the price it owes.
    function sell(uint256 tokensIn, uint256 minQuoteOut)
        external
        returns (uint256 quoteOut)
    {
        return sellTo(tokensIn, minQuoteOut, msg.sender);
    }

    /**
     * @notice Sell, and send the proceeds somewhere other than the caller.
     *
     * @dev The mirror of `buyFor`, and safe for the mirror reason: the coins
     *      are pulled from whoever calls, so nobody can sell somebody else's.
     */
    function sellTo(uint256 tokensIn, uint256 minQuoteOut, address to)
        public
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (graduated) revert AlreadyGraduated();
        if (tokensIn == 0) revert ZeroAmount();

        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), tokensIn);

        uint256 k = virtualToken * virtualQuote;
        uint256 gross = virtualQuote - _ceilDiv(k, virtualToken + tokensIn);
        uint256 fee = (gross * TRADE_FEE_BPS) / BPS;
        uint256 tax = (gross * SELL_TAX_BPS()) / BPS;
        quoteOut = gross - fee - tax;

        if (quoteOut < minQuoteOut) revert Slippage(quoteOut, minQuoteOut);

        virtualToken += tokensIn;
        virtualQuote -= gross;
        tokensLeft += tokensIn;

        _payFee(fee);
        QUOTE.safeTransfer(to, quoteOut);
        _payTax(tax);

        emit Sold(msg.sender, tokensIn, quoteOut, fee, tax);
        if (TOKEN_IS_0) emit Swap(msg.sender, tokensIn, 0, 0, gross, to);
        else emit Swap(msg.sender, 0, tokensIn, gross, 0, to);
        _emitSync();
    }

    /// @notice Open the pair once the curve has sold out. Permissionless — it
    ///         normally happens inside the buy that empties the curve, and this
    ///         exists only so a graduation can never be stuck.
    function graduate() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (tokensLeft != 0) revert NotGraduatedYet();
        _graduate();
    }

    function _graduate() private {
        graduated = true;

        /*
         * The pool already exists, and this contract was told where.
         *
         * It used to be created here, which cost the last buyer two million gas
         * and put their transaction over a HyperEVM small block; and its
         * address had to be predicted beforehand, from a hash of the pair's own
         * creation code, so that the coin could refuse transfers into it during
         * the curve. That prediction was Uniswap V2's and is wrong on every
         * fork that compiled its pair differently. The factory opens the pool
         * at launch now and hands the real address to the coin, which hands it
         * here — so there is nothing to predict, nothing to create, and nothing
         * about this step that depends on which exchange it is.
         */
        address p = RESERVED_PAIR;
        pair = p;

        uint256 tokens = MIGRATION_TOKENS;
        uint256 quote = QUOTE.balanceOf(address(this));

        IERC20(TOKEN).safeTransfer(p, tokens);
        QUOTE.safeTransfer(p, quote);
        IUniswapV2Pair(p).mint(BURN_SINK);

        // Told last, so the coin only starts taxing once the pair holds
        // liquidity — a tax charged on the seeding transfer itself would take a
        // cut of the pool before anybody had traded.
        PerpMeTaxToken(TOKEN).setPair(p);

        // Reported back so the factory — the one address the site and the
        // indexer both already know — is where every launched coin's pair can
        // be discovered from. See PerpMeTaxFactory.Graduated.
        IPerpMeTaxFactory(FACTORY).onGraduated(TOKEN, p, tokens, quote);

        emit Graduated(p, tokens, quote);
    }
}
