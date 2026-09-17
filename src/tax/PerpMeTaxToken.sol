// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PerpMeDividendDistributor} from "./PerpMeDividendDistributor.sol";
import {IPerpMeVenue} from "./venue/IPerpMeVenue.sol";

interface IPerpMeTaxFactory {
    function creatorRecipient(address token) external view returns (address);
    function owner() external view returns (address);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)
        external;
}

/**
 * @dev The protocol's maximum cut of a coin's tax, at file level so the factory
 *      can enforce the identical ceiling without an external call. Re-exported
 *      inside the contract as MAX_PROTOCOL_BPS for anyone reading the coin.
 */
uint16 constant PROTOCOL_BPS_CEILING = 2000; // 20% of the tax



/**
 * @title PerpMeTaxToken
 * @notice A coin that pays its holders a dividend in the share it trades
 *         against.
 *
 *         WHY THIS IS A SECOND KIND OF LAUNCH, NOT A REPLACEMENT
 *
 *         The launchpad's ordinary coin lives in a Uniswap V3 pool and takes
 *         nothing on transfer; the pool's own 1% fee is collected by the locker
 *         and split with the creator. That coin is unchanged and stays the
 *         default: V3 gives it concentrated liquidity, aggregator routing and a
 *         fee ceiling of 1%.
 *
 *         A dividend needs a bigger and steerable cut, and the only way to take
 *         one is on transfer. Uniswap V3 cannot carry a coin that does that —
 *         a taxed sell reverts, because the pool checks that it received
 *         exactly what it was promised and a tax makes less arrive. That is not
 *         an opinion; test/TaxTokenOnUniswap.t.sol proves it against the
 *         deployed router, and proves the same coin trades fine on Uniswap V2,
 *         which measures each hop from the pair's real balance instead. So this
 *         coin launches into a Uniswap V2 pair.
 *
 *         WHAT THE HOLDER ACTUALLY RECEIVES
 *
 *         The quote side of the pair. On this launchpad that is usually a
 *         tokenized share — wNVDAx, wTSLAx and thirteen others — so holding the
 *         coin pays out in NVIDIA or Tesla. Competing designs pay dividends in
 *         a stock token they had to go and buy on a third market; here the
 *         stock IS the quote asset, so the dividend is simply the tax, swapped
 *         once, along the pair the coin already trades on.
 *
 *         WHAT IS DELIBERATELY ABSENT
 *
 *         No owner, no blocklist, no mint after launch, no proxy. Every
 *         parameter is written once by the factory and then cannot move, with
 *         ONE exception below — and the tax can never go UP, which is the
 *         difference between a dividend coin and a rug with extra steps. The
 *         bounds are constants IN THIS CONTRACT rather than in an unverified
 *         launcher, so a reader can check the promise without trusting us.
 *
 *         THE ONE THING THAT CAN MOVE, AND ONLY DOWNWARD
 *
 *         The platform may LOWER the tax on a live coin — `lowerTax`. A coin
 *         that launched at 5% can be taken to 3% a month later and to 1% after
 *         that; it can never be taken back up, and never under the 1% floor.
 *         The caller is the owner of the factory that launched the coin, read
 *         from the factory at the moment of the call the way the creator's
 *         payee already is, so the coin itself still has no owner and nothing
 *         to hand over. This exists because a rate chosen on launch day is a
 *         guess, and the only correction that cannot hurt a holder is the one
 *         that leaves more of every trade in their pocket.
 *
 *         The constructor takes no arguments on purpose: the factory predicts
 *         each address with CREATE2 and the create page mines a salt for a
 *         vanity suffix, and both need the init-code hash identical across
 *         coins.
 */
contract PerpMeTaxToken is ERC20 {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    //  Bounds. Constants, so they are auditable without trusting the factory.
    // -------------------------------------------------------------------------

    /// @dev A tax below this is not worth the gas it adds to every trade.
    uint16 public constant MIN_TAX_BPS = 100; // 1%
    /**
     * @dev The hard ceiling on each side.
     *
     *      Five percent, where the nearest comparable contracts on this chain
     *      allow ten. A holder pays this twice — once entering, once leaving —
     *      so ten percent each way means a fifth of the position is gone before
     *      the price moves at all. Five is the most that can still be described
     *      to a buyer honestly.
     */
    uint16 public constant MAX_TAX_BPS = 500; // 5%

    uint16 private constant BPS = 10_000;

    /**
     * @dev The most the protocol may ever take off the top of the tax.
     *
     *      A constant here, not a number in the factory, because this is the
     *      one slice the coin's holders do not choose and cannot refuse. Fixing
     *      the ceiling in the coin means a reader can bound the protocol's cut
     *      without reading — or trusting — whatever launched it. The rate
     *      itself is written once at initialize and has no setter, so a coin's
     *      cut cannot be raised after people have bought it.
     */
    uint16 public constant MAX_PROTOCOL_BPS = PROTOCOL_BPS_CEILING;

    /// @dev Eligibility floor for dividends, bounded so a creator cannot set it
    ///      high enough to exclude everyone but themselves.
    uint256 public constant MIN_DIVIDEND_BALANCE_FLOOR = 1e18;
    uint256 public constant MIN_DIVIDEND_BALANCE_CEILING = 1_000_000e18;

    // -------------------------------------------------------------------------
    //  Write-once state. There is no setter for any of it.
    // -------------------------------------------------------------------------

    address public factory;
    address public locker;
    address public creator;

    /// The token this coin is quoted against — and what dividends are paid in.
    address public pairToken;
    /**
     * @notice The bonding curve this coin trades on before it has a pair.
     *
     * @dev Zero for a coin launched straight into a pool. While it is set and
     *      `pair` is not, the coin is IN THE CURVE PHASE and refuses any
     *      transfer that does not involve the curve — see `_update`.
     */
    address public curve;
    /**
     * @notice A router allowed to hold this coin while it is still on the curve.
     *
     * @dev The curve phase forbids sideways transfers so nobody can open a
     *      second, unofficial market. That rule also blocks the one contract
     *      that legitimately needs to hold coins for an instant: a router
     *      selling them on the holder's behalf, so somebody with HYPE and no
     *      wNVDAx can trade at all.
     *
     *      Permitted for TRANSFERS during the curve phase and nothing else — it
     *      is not in `_excluded`, so once the pair opens it pays tax like any
     *      other address and earns dividends like any other holder.
     */
    address public curveRouter;
    /// The Uniswap V2 pair. Written once, after it exists.
    address public pair;

    /**
     * @notice Where this coin's pool will be, worked out before it is created.
     *
     * @dev A V2 pair lives at a CREATE2 address derived from the factory and
     *      the two token addresses, so it can be named long before anybody
     *      deploys it. Knowing it is what lets the curve phase close that one
     *      address instead of closing every transfer — see `_update`.
     */
    address public reservedPair;

    /**
     * @notice What this coin has decided about an address: 0 not asked, 1 not
     *         a market, 2 a market.
     *
     * @dev Only ever written for addresses that HAVE code. An address with none
     *      is judged afresh every time, because an empty address can become a
     *      pool later — that is precisely how a pair is opened — and a cached
     *      "not a market" would be a permanent hole at exactly the address
     *      somebody was aiming for.
     */
    mapping(address => uint8) private _marketVerdict;

    /**
     * Addresses the venue moves the pair's fee to.
     *
     * On a Velodrome-style fork — Nest — the pair does not keep its fee in the
     * reserves; it transfers it out IN THE TOKEN to a fees contract and a
     * community vault. For one of our coins that makes those addresses
     * holders: they would be counted for dividends, earn a share of every
     * liquidation, and have nobody behind them to claim it. Their measured
     * balance on Nest's own pair today is 6.39 NEST, which is the same
     * mechanism with their token instead of ours.
     *
     * Read from the venue once, when the pair is set, and treated as excluded
     * from then on. Two slots rather than a list because a Solidly pair has
     * exactly two and `_excluded` runs on every transfer; PRJX answers zero
     * for both, so nothing changes there.
     */
    address public feeSinkA;
    address public feeSinkB;

    PerpMeDividendDistributor public distributor;

    string private _tokenName;
    string private _tokenSymbol;
    string public metadataURI;

    /**
     * @notice The coin's metadata, base64-encoded JSON, or empty.
     *
     * @dev The whole reason this exists next to `metadataURI`, which points at
     *      the same thing on IPFS.
     *
     *      A scanner that has never heard of this launchpad finds a coin's
     *      picture and links in one of two ways: it calls a function whose name
     *      it already knows, or somebody puts the coin on a list by hand. Ours
     *      answered only to `metadataURI`, a name we invented, and the answer
     *      was an `ipfs://` link needing a gateway the reader had to choose. So
     *      neither route worked and the picture arrived only through a
     *      whitelist. A competing launchpad's coins show a logo the second they
     *      exist, and the only difference is that they answer `contractURI` and
     *      hand back the JSON itself rather than a link to it.
     *
     *      Stored already encoded because the encoder has no business being in
     *      here: the site builds this exact JSON to pin it, base64 is a dozen
     *      lines in TypeScript, and doing it on chain would also mean escaping
     *      quotes out of a creator's own name in Solidity. What the coin does
     *      is hold the bytes and say what they are.
     */
    string public metadataB64;

    uint16 public buyTaxBps;
    uint16 public sellTaxBps;

    /// Taken off the top of the swapped tax, before the split below.
    address public protocolTreasury;
    uint16 public protocolBps;

    /**
     * @dev How the tax is divided. Must sum to 10000.
     *
     *      `burnBps` is spent FIRST and in coins — see `_liquidate`. The other
     *      two divide the money the rest is sold for.
     */
    uint16 public dividendBps;
    uint16 public creatorBps;
    uint16 public burnBps;

    /// Tax accrues in-kind until this much is held, then it is swapped.
    uint256 public swapThreshold;

    /**
     * @notice The exchange this coin's pair lives on, as a contract.
     *
     * @dev Two things about a pair differ between exchanges and neither is
     *      knowable from the pair alone: how much it will hand back for a given
     *      amount in, which needs the venue's fee, and whether the price it is
     *      quoting is real, which needs whatever oracle the venue happens to
     *      keep. Both used to be written into this contract as Uniswap V2's
     *      answers — 0.3% and a price accumulator — and both are wrong on a
     *      Solidly fork, where the fee sits on the pair and can be moved and
     *      there is no accumulator at all.
     *
     *      Written once at launch by the factory, like every other parameter
     *      here, so a coin cannot be handed a different exchange later. It is
     *      asked, never trusted with anything: it holds no coins, has no
     *      allowance, and cannot move a wei. A wrong answer costs at most what
     *      the half-a-percent cap on a liquidation already allows.
     */
    IPerpMeVenue public venue;

    /// @notice How long the sale must have been failing before the accrued tax
    ///         can be taken out by hand.
    uint256 public constant TAX_RESCUE_DELAY = 3 days;

    uint256 public lastLiquidatedAt;

    /**
     * @dev The block of the last SUCCESSFUL sale, so there is one per block.
     *
     *      The half-percent cap below bounds one sale. It did not bound a
     *      block: `liquidate()` is open to anyone, and the price check inside
     *      a window compares against the last average rather than re-anchoring,
     *      so nothing refused a second call — or a twenty-fourth. Measured on a
     *      fork with the pot the live coin actually reached, 2.5% of supply:
     *      twenty-four calls cleared in one block, the whole pot sold, the
     *      pool 20% lower, and the holders paid at 89% of the block's opening
     *      price. Whoever placed the buy right after collected the rest.
     *
     *      One per block turns that from a transaction into a campaign: each
     *      step is a separate block anyone can trade in between, and the
     *      sandwich stops being free.
     */
    uint256 private _lastLiquidationBlock;

    /**
     * @dev The most of the pair's coin side one liquidation may sell, in bps.
     *
     *      The swap goes out with no minimum-output guard, because there is
     *      nobody to choose one: it runs inside a stranger's sell, from a
     *      contract with no owner and no oracle. An unbounded sale with no
     *      guard is a standing invitation to sandwich it — the bigger the sale,
     *      the more it moves the price and the more there is to steal, and what
     *      is stolen comes out of the holders' dividend.
     *
     *      Capping the sale at half a percent of the pool bounds the price
     *      impact, and with it the profit available to anyone trying. Tax above
     *      the cap is not lost; it stays accrued and goes out on the next sell.
     */
    uint16 private constant MAX_LIQUIDATION_BPS_OF_POOL = 50; // 0.5%

    /*
     * There is deliberately NO minimum-output floor on the liquidation swap,
     * and the number that used to sit here has been removed rather than left
     * looking like one.
     *
     * A `LIQUIDATION_MIN_OUT_BPS = 9000` was declared, documented at length as
     * "the least a liquidation will accept" — and never referenced by a single
     * line of code. A reader, or an auditor, would have taken the comment for
     * the behaviour. A promise nothing implements is worse than an absence
     * nobody was promised.
     *
     * It cannot simply be switched on either. A floor is measured against the
     * pair's own price, and the band it would need is far tighter than this
     * pool can hold: bands of 30% and 50% were both tried against a freshly
     * graduated pool and both refused ordinary sells, because a fresh
     * graduation is a few thousand dollars deep and early sells move it hard.
     * At 90% the tax would essentially never sell at all.
     *
     * What bounds the loss instead is two things that do not depend on a price
     * being quoted honestly. The slice is capped at half a percent of the pool
     * above, so there is very little to extract; and the sale is refused
     * outright when the pool is quoting under a fifth of its own five-minute
     * average — see `_priceIsSane`. An attacker also has to buy and sell THIS
     * coin to set the trap, paying its tax twice, against a target worth a
     * fraction of half a percent of the pool.
     */





    /**
     * @dev Gas a trade lends to paying other holders their dividends.
     *
     *      Enough to reach a handful of holders per liquidation, which is all
     *      that is needed: liquidations happen every few trades and the cursor
     *      carries on where it stopped, so the whole list is covered over time
     *      without any single trade paying for it.
     */
    uint256 private constant AUTO_PAYOUT_GAS = 250_000;
    /**
     * @dev How many holders one trade carries, as a COUNT rather than "as many
     *      as the gas allows".
     *
     *      A gas-shaped budget makes a trade cost more to run than to estimate,
     *      because the estimator finds a limit at which the payout declines to
     *      start. A seller lost a transaction to exactly that. Two holders is
     *      what a trade can carry comfortably inside the stipend above, and the
     *      cursor means the queue still rotates.
     */
    uint256 private constant AUTO_PAYOUT_HOLDERS = 2;

    /// @dev Re-entry latch for the contract's own swap.
    bool private _swapping;

    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    error NotFactory();
    error AlreadyInitialized();
    error InvalidTax(uint16 bps);
    error InvalidSplit(uint256 total);
    error InvalidProtocolShare(uint16 bps);
    error InvalidDividendFloor(uint256 amount);
    error TransferRestricted();
    error OnlyCurve();
    error LiquidationShortfall();
    error NotThePairForThisCoin();
    error OnlySelf();
    error PriceOffTheAverage();
    error NoDividendShare();
    error InvalidSwapThreshold(uint256 amount);
    error NotFactoryOwner();
    error NoPairYet();
    error ZeroRecipient();
    error NoVenue();
    error LiquidationNotStalled();

    event TaxCollected(address indexed from, uint256 amount, bool isBuy);
    /// @dev The platform lowered the tax. It is the only way a rate changes,
    ///      and it only ever goes down.
    event TaxLowered(uint16 buyTaxBps, uint16 sellTaxBps);
    /// @dev The accrued tax was taken out by hand because the sale had been
    ///      failing for `TAX_RESCUE_DELAY`. Loud on purpose: it is the one moment this
    ///      coin hands money to a human.
    event TaxRescued(address indexed to, uint256 amount);
    event TaxLiquidated(uint256 coinsSold, uint256 received);
    event TaxBurned(uint256 coins);
    event FundsSplit(uint256 toDividends, uint256 toCreator, uint256 toProtocol);

    /**
     * @dev Whoever deployed this coin. Recorded so `initialize` can refuse
     *      everybody else — see the check there.
     *
     *      Taken from `msg.sender` rather than passed in, because a constructor
     *      ARGUMENT would make each coin's creation code different and turn the
     *      create page's salt mining into hashing seven kilobytes per attempt.
     *      Reading the caller costs nothing and leaves the init-code hash the
     *      same for every coin, which is the property the mining depends on.
     *
     *      Storage rather than `immutable`, and that is not a style choice. An
     *      immutable is written into the RUNTIME code at construction, so the
     *      deployed bytecode stops being the same bytes the compiler produced —
     *      and the explorer payload every coin is verified from is one constant
     *      file. As an immutable it made `build-verify-assets` refuse outright,
     *      and shipping past that would have left every new coin unverified.
     *      It is read twice in a coin's life, both times during `initialize`,
     *      so a storage slot costs nothing worth measuring.
     */
    address private deployedBy;

    constructor() ERC20("", "") {
        deployedBy = msg.sender;
    }

    /// @dev The factory the deploying helper answers to, or zero if whatever
    ///      deployed this coin is not one. Asked without an interface so a
    ///      plain deployer is a zero rather than a revert.
    function _deployersFactory() private view returns (address f) {
        (bool ok, bytes memory out) =
            deployedBy.staticcall(abi.encodeWithSignature("FACTORY()"));
        if (ok && out.length == 32) f = abi.decode(out, (address));
    }

    struct InitParams {
        string name;
        string symbol;
        string metadataURI;
        /// @dev Base64 of the same JSON `metadataURI` points at. May be empty.
        string metadataB64;
        address creator;
        address locker;
        address pairToken;
        address reservedPair;
        address protocolTreasury;
        uint256 totalSupply;
        uint16 protocolBps;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 dividendBps;
        uint16 creatorBps;
        uint16 burnBps;
        uint256 minDividendBalance;
        uint256 swapThreshold;
        address venue;
    }

    /**
     * @notice Called by the deploying factory in the same transaction as the
     *         deployment. Nobody else can reach it: the address is unknown
     *         until the deploy returns, and the factory initializes it in the
     *         next instruction.
     */
    function initialize(InitParams calldata p) external {
        if (factory != address(0)) revert AlreadyInitialized();

        /*
         * Only the address that deployed this coin, or the factory its deployer
         * answers to, may do this.
         *
         * It used to be open to anyone while `factory` was still zero, and the
         * argument for that was true but not a guarantee: the factory deploys
         * and initializes in one transaction, so there is no block in which a
         * stranger could get in between. That holds for the launch path we
         * wrote and for nothing else — separate the two steps for any reason
         * and whoever calls this first becomes the factory, picks the tax, the
         * treasury, the creator and the supply, and mints the lot to
         * themselves. A property that depends on the caller being careful is
         * not a property.
         *
         * Two callers, because there are two shapes. In production the coin is
         * deployed by the CREATE2 helper and initialized by the factory that
         * helper serves. Deployed directly — a test, a script — the deployer is
         * the initializer, and it is already the only party that could have
         * done either.
         */
        if (msg.sender != deployedBy && msg.sender != _deployersFactory()) {
            revert NotFactory();
        }

        if (p.buyTaxBps < MIN_TAX_BPS || p.buyTaxBps > MAX_TAX_BPS) revert InvalidTax(p.buyTaxBps);
        if (p.sellTaxBps < MIN_TAX_BPS || p.sellTaxBps > MAX_TAX_BPS) {
            revert InvalidTax(p.sellTaxBps);
        }

        if (p.protocolBps > MAX_PROTOCOL_BPS) revert InvalidProtocolShare(p.protocolBps);

        uint256 split = uint256(p.dividendBps) + p.creatorBps + p.burnBps;
        if (split != BPS) revert InvalidSplit(split);

        /*
         * Something other than the burn has to be left, or the coin breaks in
         * two different ways at once.
         *
         * `burnBps = 10000` passes the sum above — dividends and creator both
         * zero — and then: after graduation `_liquidate` computes a burn equal
         * to the whole slice, leaves nothing to sell, and returns before the
         * burn is carried out, so the tax piles up in the contract forever and
         * is never burned at all. And on the curve, where there is nothing to
         * burn, the split divides by `dividendBps + creatorBps` — zero — and
         * every wei goes to the holders instead. A coin advertised as burning
         * all of its tax would burn none of it and pay all of it out.
         *
         * One basis point of something else is enough to keep both paths sane,
         * so that is all this asks for.
         */
        if (p.burnBps == BPS) revert InvalidSplit(split);

        /*
         * A dividend coin has to pay a dividend.
         *
         * The split is checked to total 10,000 and nothing more, so a share of
         * zero to holders passes — a coin taking five percent of every trade
         * and handing all of it to its creator, listed beside the others and
         * described the same way. It also rules out the mirror case of the burn
         * check above, `creatorBps == 10000`, since the three must total the
         * whole and holders now have some of it.
         */
        if (p.dividendBps == 0) revert NoDividendShare();

        /*
         * And the tax has to be reachable.
         *
         * Liquidation is the ONLY thing that ever moves tax out of this
         * contract, and it runs on a sell once the balance reaches
         * `swapThreshold`. Set that beyond the supply — or to zero, which the
         * check reads as "never" — and the tax accrues on every trade and stays
         * forever: not sold, not burned, not paid, and not recoverable, because
         * the coin has no owner and no way to sweep itself. Measured at 9.8M
         * coins collected and not one wei distributed.
         *
         * The launch form sends a ten-thousandth of the supply. A hundredth is
         * a hundred times that and still leaves the tax reachable within a
         * day's trading, so this rejects the unreachable without dictating a
         * policy to anyone launching through the contracts directly.
         */
        if (p.swapThreshold == 0 || p.swapThreshold > p.totalSupply / 100) {
            revert InvalidSwapThreshold(p.swapThreshold);
        }

        if (
            p.minDividendBalance < MIN_DIVIDEND_BALANCE_FLOOR
                || p.minDividendBalance > MIN_DIVIDEND_BALANCE_CEILING
        ) revert InvalidDividendFloor(p.minDividendBalance);

        factory = msg.sender;
        locker = p.locker;
        creator = p.creator;
        pairToken = p.pairToken;
        // Worked out by the factory, which is the only thing that can call
        // this, and which has the room for the arithmetic — see
        // PerpMeTaxFactory._pairAddress. The coin was doing it itself until
        // its creation code and the deployer that carries it together crossed
        // the 24,576-byte ceiling; this contract is the one with no room left.
        reservedPair = p.reservedPair;
        protocolTreasury = p.protocolTreasury;
        protocolBps = p.protocolBps;

        _tokenName = p.name;
        _tokenSymbol = p.symbol;
        metadataURI = p.metadataURI;
        metadataB64 = p.metadataB64;

        if (p.venue == address(0)) revert NoVenue();
        venue = IPerpMeVenue(p.venue);

        buyTaxBps = p.buyTaxBps;
        sellTaxBps = p.sellTaxBps;
        dividendBps = p.dividendBps;
        creatorBps = p.creatorBps;
        burnBps = p.burnBps;
        swapThreshold = p.swapThreshold;

        distributor =
            new PerpMeDividendDistributor(address(this), p.pairToken, p.minDividendBalance);

        // The whole supply to the factory, which places it in the pair inside
        // this same transaction. It is never held by a person.
        _mint(msg.sender, p.totalSupply);
    }

    /// @notice Called once by the factory, before any trading, when this coin
    ///         is to live on a bonding curve first.
    function setCurve(address curve_, address router_) external {
        if (msg.sender != factory) revert NotFactory();
        if (curve != address(0)) revert AlreadyInitialized();
        curve = curve_;
        curveRouter = router_;
    }



    /**
     * @notice Called once, immediately after the pair exists.
     * @dev By the factory for a direct launch, or by the curve at graduation —
     *      the curve is the one that opens the pair, so it is the one that
     *      knows the address.
     */
    function setPair(address pair_) external {
        if (msg.sender != factory && msg.sender != curve) revert NotFactory();
        if (pair != address(0)) revert AlreadyInitialized();

        /*
         * The pair has to be a pair between THIS coin and its quote token.
         *
         * The coin sells its tax straight into whatever address is written
         * here, so a wrong one is not a cosmetic error — it is where the
         * holders' money goes. Asking the pair which two tokens it holds is the
         * question that actually matters, and it is answered by the pair
         * itself, so no third address has to be trusted to answer it honestly.
         */
        address t0;
        address t1;
        // Asked defensively: an address that is not a pair answers neither
        // question, and "it did not answer" should reach the caller as the same
        // plain refusal as "it answered wrongly" rather than as a bare,
        // dataless revert nobody can read.
        try IUniswapV2Pair(pair_).token0() returns (address a) {
            t0 = a;
            try IUniswapV2Pair(pair_).token1() returns (address b) {
                t1 = b;
            } catch {}
        } catch {}
        bool holdsBoth = (t0 == address(this) && t1 == pairToken)
            || (t1 == address(this) && t0 == pairToken);
        if (!holdsBoth) revert NotThePairForThisCoin();

        pair = pair_;

        /*
         * Start the price window here, at the moment the pool opens.
         *
         * Liquidation averages the price over the stretch since this was last
         * read, and it declines to sell until that stretch is long enough to
         * mean anything. Taking the first reading now rather than at the first
         * attempted sale means the clock is already running while the coin is
         * being traded, so the first liquidation is not itself the thing that
         * starts it and then has to be thrown away.
         */
        // The rescue clock starts here too, so a coin whose pair opened today
        // is not already `TAX_RESCUE_DELAY` without a sale.
        lastLiquidatedAt = block.timestamp;

        /*
         * And whoever this venue hands the pair's fee to stops being a holder
         * before it can become one.
         *
         * Asked once, here, because the answer is a property of the exchange
         * and cannot change for this coin afterwards. Swallowed like the price
         * reading below: a venue too old to answer leaves both slots at zero,
         * which is exactly what PRJX answers anyway.
         */
        try venue.feeSinks(pair_) returns (address a, address b) {
            feeSinkA = a;
            feeSinkB = b;
        } catch {}

        /*
         * And the price clock, by taking a first reading and throwing the
         * answer away.
         *
         * The venue averages over a window and has nothing to average until it
         * has been read once. Reading it here rather than at the first
         * attempted sale means the window is already open while the coin is
         * being traded, instead of the first liquidation being spent starting
         * the clock and then refused. Swallowed, because a venue that will not
         * answer must cost this coin a batch of tax, never its graduation.
         */
        try venue.priceIsSane(pair_) returns (bool) {} catch {}

        // Liquidity is seeded before this is called — the pair does not exist
        // to be named until it has been created and filled — so during that
        // window the pair looked like an ordinary holder and accrued shares on
        // half the supply. Clearing them here is what makes the ordering safe;
        // without it the pool would quietly collect most of every dividend.
        distributor.setShare(pair_, 0);
    }

    /// @notice Called by the factory at the end of the launch transaction,
    ///         after the creator's opening buy, so every later trade in the
    ///         window is capped.


    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /**
     * @dev Whoever owns the factory that launched this coin, or zero.
     *
     *      Asked of the chain at the moment of the call rather than stored, so
     *      a factory handed to a new owner hands these levers with it. A
     *      factory that has no `owner()` — a test harness, a direct deploy —
     *      answers zero, and then nobody holds them at all.
     */
    function _factoryOwner() private view returns (address who) {
        try IPerpMeTaxFactory(factory).owner() returns (address o) {
            who = o;
        } catch {}
    }

    modifier onlyFactoryOwner() {
        address who = _factoryOwner();
        if (who == address(0) || msg.sender != who) revert NotFactoryOwner();
        _;
    }


    /**
     * @notice Where a reader finds this coin's name, picture and links.
     *
     * @dev The name is the point. `contractURI` is what an explorer, an
     *      aggregator or a trading bot calls without being told to — it is the
     *      one metadata function they all probe — and it is standardised in
     *      ERC-7572.
     *
     *      Returns the JSON inline when there is any, so a reader needs no
     *      gateway, no CORS and no pin to still be alive. Falls back to the
     *      IPFS link for a coin launched before this existed, which is worth
     *      more than an empty string to anyone who can resolve one.
     */
    function contractURI() external view returns (string memory) {
        if (bytes(metadataB64).length == 0) return metadataURI;
        return string.concat("data:application/json;base64,", metadataB64);
    }

    /// @notice Combined cost of a round trip, in basis points. For the UI, so
    ///         the number a buyer is quoted comes from the coin itself.
    function roundTripTaxBps() external view returns (uint256) {
        return uint256(buyTaxBps) + sellTaxBps;
    }

    /**
     * @notice Lower the tax on this coin. Platform only, and down only.
     *
     * @dev Each new rate must be no higher than the rate it replaces and no
     *      lower than MIN_TAX_BPS, so the promise a buyer read at launch —
     *      "this much, and never more" — survives every call. Leaving one side
     *      where it is means passing its current value.
     *
     *      The caller is whoever owns the factory that launched this coin,
     *      asked of the factory now rather than remembered from launch, so a
     *      factory handed to a new owner hands this lever over with it and a
     *      factory that has no `owner()` — a test harness standing in for one —
     *      has nobody who can pull it. The coin keeps no owner of its own.
     *
     *      The curve reads these rates live, so a coin still on its curve is
     *      lowered exactly the same way as one in its pair.
     */
    function lowerTax(uint16 buyBps, uint16 sellBps) external onlyFactoryOwner {
        if (buyBps < MIN_TAX_BPS || buyBps > buyTaxBps) revert InvalidTax(buyBps);
        if (sellBps < MIN_TAX_BPS || sellBps > sellTaxBps) revert InvalidTax(sellBps);
        buyTaxBps = buyBps;
        sellTaxBps = sellBps;
        emit TaxLowered(buyBps, sellBps);
    }

    // -------------------------------------------------------------------------
    //  Transfers
    // -------------------------------------------------------------------------

    /**
     * @dev Addresses that neither pay tax nor earn dividends.
     *
     *      The pair is the important one: it holds most of the supply, so
     *      counting it as a holder would send nearly every dividend back into
     *      the pool. The rest are plumbing — this contract while it is selling
     *      tax, the distributor holding rewards, the factory during the launch
     *      transaction, the locker holding LP, and the burn sink.
     */
    function _excluded(address who) internal view returns (bool) {
        return who == address(this) || who == address(distributor) || who == factory
            || who == locker || who == BURN_SINK || who == curve || who == address(0)
            || who == feeSinkA || who == feeSinkB;
    }


    /**
     * @dev Is this address a market for this coin?
     *
     *      A dividend coin used to tax one address: the pair it graduated into.
     *      Every other venue for the same coin — a second pair against a
     *      different quote, one on another factory, anything of that shape —
     *      traded free of the tax, which is to say free of the dividend, the
     *      burn and the creator's share all at once. Nothing stops such a pool
     *      being opened; and if the liquidity went there, what is left is an
     *      ordinary token with a paragraph about dividends attached.
     *
     *      A pool cannot hide what it is. It has to hold the coin, so the coin
     *      has to be sent to it, and every constant-product pool worth trading
     *      on will say which two tokens it holds. Asking is therefore a
     *      question about behaviour rather than a list somebody has to keep —
     *      no registry, no owner, nothing to add a venue to after the fact.
     *
     *      Asked once per contract and remembered, so the cost falls on the
     *      first trade against a venue and not on the rest. An address with no
     *      code is not a market and is not remembered: it may become one, and a
     *      remembered "no" would outlive the truth.
     *
     *      Two things this does NOT catch, said plainly so they are known
     *      rather than discovered. A venue that holds the coin without
     *      admitting to it — a custom AMM with no token0() — is never
     *      recognised; closing that would mean taxing every contract, bridges
     *      and multisigs included. And a verdict of "not a market" is kept for
     *      good, so a PROXY judged before its implementation made it a pool
     *      stays untaxed afterwards. Both are narrower than the hole this
     *      closes, which was every venue but one.
     */
    /**
     * @notice Whether this coin judges `who` a market — the same question
     *         `_update` asks, answerable from outside and without writing.
     *
     * @dev The distributor needs it to refuse re-including a pool as a
     *      shareholder. A cached verdict is returned as it stands; an unjudged
     *      address is probed exactly as `_isMarket` probes it, and the answer
     *      is not cached, because a view may not.
     */
    function isMarket(address who) external view returns (bool) {
        if (who == pair) return true;
        if (who.code.length == 0) return false;
        uint8 verdict = _marketVerdict[who];
        if (verdict != 0) return verdict == 2;
        (bool has0, address t0) = _reportedToken(who, 0x0dfe1681);
        (bool has1, address t1) = _reportedToken(who, 0xd21220a7);
        return has0 && has1 && t0 != t1 && (t0 == address(this) || t1 == address(this));
    }

    function _isMarket(address who) private returns (bool) {
        if (who == pair) return true;
        if (who.code.length == 0) return false;

        uint8 verdict = _marketVerdict[who];
        if (verdict != 0) return verdict == 2;

        /*
         * BOTH selectors have to answer, and the two answers have to differ.
         *
         * Asking for either one alone and taking the first `yes` recognised
         * anything that happened to expose a `token0` naming this coin — a
         * vault, a staking contract, a bridge adapter — and taxed it as a
         * venue while cutting it out of dividends. A pool is a pair: it holds
         * two different tokens and says so from both selectors. Requiring both
         * costs nothing in coverage, because every constant-product pool worth
         * trading on answers both, and it drops the whole class of contracts
         * that merely resemble one from the side.
         *
         * Asked without an interface so a contract that answers neither costs
         * one failed call rather than a revert to catch.
         */
        (bool has0, address t0) = _reportedToken(who, 0x0dfe1681);
        (bool has1, address t1) = _reportedToken(who, 0xd21220a7);
        bool yes = has0 && has1 && t0 != t1 && (t0 == address(this) || t1 == address(this));
        _marketVerdict[who] = yes ? 2 : 1;

        /*
         * A market recognised HERE may already be carrying shares, and they
         * have to be given up at the moment it is recognised.
         *
         * This question is only ever asked once a pair exists — during the
         * curve phase `_update` returns before reaching it — so a contract
         * shaped like a pool can be filled with coins while nobody is asking,
         * and `_syncShares` credits it like any other holder. From the verdict
         * on, `_syncShares` SKIPS a market rather than zeroing it, so without
         * this line the share count it happened to be holding at this instant
         * would simply stay: the coins walk back out, the shares do not, and
         * the register is left with a holder that owns nothing, can never call
         * `claim`, and takes a cut of every dividend the coin will ever pay.
         * Measured on a fork: 422,388,705 phantom shares — 35% of the register
         * — for 10 wNVDAx parked and withdrawn, with `totalShares` left larger
         * than the supply that exists.
         *
         * Settling here rather than skipping costs one call, once per market.
         * What the market accrued BEFORE it was recognised stays as its `owed`
         * and is stranded; that is bounded by the curve phase and cannot grow,
         * which is the whole difference between a leak and a scar.
         *
         * `setShare` is accounting and nothing else — it never transfers and
         * cannot revert — so it is safe on the transfer path.
         */
        if (yes && address(distributor) != address(0)) {
            distributor.setShare(who, 0);
        }
        return yes;
    }

    /// @dev What `who` answers to `sel`, and whether it answered at all with
    ///      something that is an address rather than 32 bytes of anything.
    function _reportedToken(address who, bytes4 sel)
        private
        view
        returns (bool ok, address token)
    {
        bytes memory out;
        (ok, out) = who.staticcall(abi.encodeWithSelector(sel));
        if (!ok || out.length != 32) return (false, address(0));
        token = abi.decode(out, (address));
        ok = token != address(0);
    }

    function _update(address from, address to, uint256 value) internal override {
        /*
         * One address is closed while the coin is on the curve: the pool it
         * will graduate into.
         *
         * Coins parked there before graduation are not a sideways trade, they
         * are a claim on the migration. A Uniswap V2 pair address is CREATE2
         * and therefore knowable before it exists, so anyone could send coins
         * to it, add the quote side, mint LP against them and wait — and
         * graduation then pours the entire migration allocation and everything
         * the curve raised into a pool where that LP is already sitting.
         * Measured on a fork: 4 wNVDAx in, 21.6 of the 41.8 raised back out,
         * plus 214M coins.
         *
         * This used to be enforced by refusing every transfer that did not
         * involve the curve, which stopped the same attack by stopping
         * everything — holders could not send each other coins at all, and a
         * blanket freeze is a much bigger thing to ask people to trust than the
         * one address it was really protecting. The address is computed at
         * launch and is the only one closed; ordinary transfers are ordinary.
         */
        if (
            pair == address(0) && reservedPair != address(0) && to == reservedPair
                && !_excluded(from)
        ) {
            // The curve and the factory are the ones that fill this pool, and
            // they do it before anybody is told the pair exists — the seeding
            // transfer lands here with `pair` still unset, so they have to be
            // let through or graduation would refuse itself.
            revert TransferRestricted();
        }

        /*
         * There is no wallet cap on a dividend coin, and there never really
         * was one.
         *
         * The field existed and could not fire. Its window was counted from
         * launch — three hundred blocks, about ten minutes — while the cap is
         * only consulted once a pair exists, and reaching a pair means buying
         * a curve out for thousands of dollars. No coin has ever done that
         * inside ten minutes, so the check was dead on every path: skipped
         * outright during the curve phase, expired by the time the pool opened.
         *
         * A scanner flagged the shape of the code guarding it, which was fair —
         * the shape was the only real thing about it. Carrying a defence that
         * cannot trigger is worse than not claiming one, so it is gone. The
         * anti-snipe cap belongs to the V3 product, where a pool exists from
         * the first block and the window means something.
         */

        // The contract selling its own tax must not be taxed, and must not
        // recurse into another sale.
        if (_swapping || pair == address(0) || _excluded(from) || _excluded(to)) {
            super._update(from, to, value);
            _syncShares(from, to);
            return;
        }

        bool isBuy = _isMarket(from);
        bool isSell = _isMarket(to);

        // Wallet to wallet is untaxed. Only trades pay.
        if (!isBuy && !isSell) {
            super._update(from, to, value);
            _syncShares(from, to);
            return;
        }

        // Liquidate on SELLS only, never on buys. During a buy the pair is
        // inside its own reentrancy lock, and swapping back into it from here
        // would revert the buyer's trade for reasons they could never diagnose.
        //
        // A sale into a SECOND market is a sell like any other and pays like
        // one, but it must not set the liquidation going: the coin sells its
        // tax into `pair`, and doing that from inside somebody else's pool is
        // a swap in the middle of a swap. The tax waits for a trade on the
        // pair, which is where it can be sold.
        if (to == pair && balanceOf(address(this)) >= swapThreshold && swapThreshold != 0) {
            _liquidate();
        }

        /*
         * A sale is a sale, even when it leaves one market for another.
         *
         * `isBuy` and `isSell` are asked of the two sides independently, and a
         * transfer from one market to another answers yes twice. Reading the
         * buy side first — which is what `isBuy ? …` does — charged the BUY
         * rate for it, and the buy rate is the cheaper one on any coin whose
         * creator set them apart. A seller only has to move their coins
         * through something the coin judges a market to pay the wrong rate,
         * and what the coin judges a market is anything that answers
         * `token0()` and `token1()` naming it — which anybody can deploy in
         * four lines. The sell tax was, in effect, optional.
         *
         * Charged as a sell whenever the coins are going INTO a market. That
         * is the direction the tax is about.
         */
        bool taxedAsSell = isSell;
        uint16 rate = taxedAsSell ? sellTaxBps : buyTaxBps;
        uint256 tax = (value * rate) / BPS;

        if (tax != 0) {
            super._update(from, address(this), tax);
            emit TaxCollected(from, tax, !taxedAsSell);
        }

        uint256 net = value - tax;
        super._update(from, to, net);
        _syncShares(from, to);
    }


    /**
     * @dev Tell the distributor both sides' new balances.
     *
     *      Accounting only — see PerpMeDividendDistributor. This can never
     *      revert on a holder's behalf, so no transfer of this coin can be
     *      blocked by anything to do with dividends.
     */

    /// @dev A market this coin has already recognised. Reads the cache only —
    ///      no calls, and no verdict is formed here.
    function _judgedMarket(address who) private view returns (bool) {
        return who == pair || _marketVerdict[who] == 2;
    }

    function _syncShares(address from, address to) private {
        if (address(distributor) == address(0)) return;
        /*
         * Markets do not hold, they store.
         *
         * The pair was always excluded here, for the reason in `_excluded`: it
         * holds most of the supply, so counting it as a holder would send
         * nearly every dividend straight back into the pool. A second market is
         * the same thing wearing a different address — and teaching the coin to
         * TAX one without teaching it to stop COUNTING one would have been
         * worse than leaving it untaxed: the dividend it now pays would accrue
         * to an address that cannot call `claim`, sit in `totalDeposited` for
         * good, and dilute every real holder by the whole float sitting in that
         * pool.
         *
         * Read from the verdict already cached rather than asked again: this
         * runs on every transfer, including ones that never computed a side,
         * and a plain SLOAD costs nothing next to two external calls.
         *
         * The curve's router is skipped as well. It is deliberately NOT in
         * `_excluded` — after the pair opens it must pay tax like any address —
         * but it does hold coins for a few lines in the middle of a sale, and
         * dividends funded during that same transaction would be credited to a
         * contract that has no way to claim them. Excluded from SHARES only;
         * its tax treatment is untouched.
         */
        if (
            from != address(0) && !_judgedMarket(from) && from != curveRouter
                && !_excluded(from)
        ) {
            distributor.setShare(from, balanceOf(from));
        }
        if (to != address(0) && !_judgedMarket(to) && to != curveRouter && !_excluded(to)) {
            distributor.setShare(to, balanceOf(to));
        }
    }

    /**
     * @dev Sell the accrued tax for the quote token and split the proceeds.
     *
     *      Failures are swallowed on purpose. This runs inside somebody else's
     *      sell, and if the pair is thin or the swap reverts for any reason,
     *      the right outcome is that their trade still goes through and the tax
     *      waits for the next attempt — not that trading in the coin stops
     *      until an admin intervenes. There is no admin.
     */
    function _liquidate() private {
        // Once a block. See `_lastLiquidationBlock`.
        if (_lastLiquidationBlock == block.number) return;
        uint256 amount = balanceOf(address(this));
        if (amount == 0) return;

        /*
         * Cap FIRST, then burn what is actually being processed.
         *
         * The burn used to be taken from the whole accrued balance while only
         * the capped slice was sold, so whatever the cap left behind was burned
         * again on the next liquidation, and again after that. A coin
         * configured to burn 5% burned 15.7% in a measured run — the missing
         * third came out of the holders' and the creator's shares. Each unit of
         * tax now passes through this once and is burned at the rate the
         * creator actually chose.
         */
        uint256 cap = (balanceOf(pair) * MAX_LIQUIDATION_BPS_OF_POOL) / BPS;
        if (cap == 0) return;
        if (amount > cap) amount = cap;

        /*
         * The burn is decided here but only carried out if the sale below
         * actually goes through.
         *
         * Burning first looked harmless while the swap was wrapped in a
         * try/catch that quietly left the tax accrued for the next sell. It was
         * not: a Uniswap V2 pair is locked for the duration of a flash swap, so
         * anyone can borrow a coin from the pair and repay it, have the
         * repayment count as a sell, and watch the liquidation's own swap
         * revert on that lock. The catch swallowed it — but the burn had
         * already happened. Sixty rounds of this cost an attacker five
         * hundredths of a coin and destroyed 1.27M of the dividend pot without
         * a single wei ever reaching a holder. Burn and sale now live or die
         * together.
         */
        uint256 burning = burnBps == 0 ? 0 : (amount * burnBps) / BPS;
        amount -= burning;
        if (amount == 0) return;

        _swapping = true;

        // The output goes to the distributor, not here. Uniswap V2 rejects a
        // swap whose recipient is one of the pair's own tokens — `to` may not
        // be this contract — so the proceeds land there and the slices that are
        // not dividends are released back out below.
        address sink = address(distributor);
        uint256 before = IERC20(pairToken).balanceOf(sink);

        /*
         * Called on itself so the whole sale can be abandoned as one.
         *
         * The coins have to reach the pair BEFORE the pair will swap them, and
         * a pair can refuse — it is locked for the duration of a flash swap,
         * and anyone may open one. A try/catch only rolls back what the callee
         * did, so sending the coins from here and catching there would leave
         * them sitting in the pool as a donation. Going through an external
         * call to this same contract puts the transfer inside the frame that
         * gets rolled back, and a refused sale then costs nothing at all: the
         * tax stays where it was and the next sell tries again.
         */
        uint256 received;
        bool sold;
        // Judged out here, so a refusal still leaves the reference moved on.
        if (_priceIsSane()) try this.sellTaxIntoPair(amount, sink) {
            received = IERC20(pairToken).balanceOf(sink) - before;
            sold = true;
        } catch {
            // Left accrued, burn and all; the next sell tries again.
        }

        if (sold) {
            if (burning != 0) {
                _burn(address(this), burning);
                emit TaxBurned(burning);
            }
            lastLiquidatedAt = block.timestamp;
            _lastLiquidationBlock = block.number;
            emit TaxLiquidated(amount, received);
            if (received != 0) _distribute(received);
        }

        _swapping = false;
    }

    /**
     * @notice Sell whatever tax has accrued, now. Anyone may call.
     *
     * @dev Liquidation used to be reachable only from inside a sell that
     *      crossed `swapThreshold`, which leaves two dead ends. Tax under the
     *      threshold when a coin stops trading stays in the coin for good —
     *      fifty-four thousand of them on the coin this shipped as — and a
     *      holder who would rather be paid now has no way to ask.
     *
     *      Opening it changes nothing an attacker could not already do by
     *      selling a single coin, and it is bounded by the same two things that
     *      bounded it before: the sale is capped at half a percent of the
     *      pool, and it is refused outright while the pool is quoting far under
     *      its own recent average.
     */
    function liquidate() external nonReentrantSwap {
        if (pair == address(0)) revert NoPairYet();
        _liquidate();
    }

    /// @dev The same latch `_liquidate` sets, checked on the way in so a
    ///      re-entrant call through the pair is refused rather than nested.
    modifier nonReentrantSwap() {
        if (_swapping) revert LiquidationShortfall();
        _;
    }

    /**
     * @notice Take the accrued tax out by hand, after the sale has been broken
     *         for three days (`TAX_RESCUE_DELAY`; a month until 2026-09-14).
     *
     * @dev The escape hatch for one specific failure, and it is deliberately
     *      hard to reach.
     *
     *      Everything about the sale depends on the venue behaving the way it
     *      did on the day the factory was pointed at it. If it charges a
     *      different fee than `poolFeeBps` says, the swap fails its own
     *      invariant on every attempt, forever, inside a try/catch nobody sees
     *      — and the tax then accrues on every trade with no path out at all.
     *      Without this the answer to that is "the holders lose all of it".
     *
     *      Three days of no successful sale is the gate — and the sale is TRIED
     *      first, right here. It used to be enough that no sale had happened,
     *      which is a different thing: a coin that trades rarely and never
     *      crosses `swapThreshold` also has no sale for days, with nothing
     *      broken about it, and the owner could have walked off with its tax.
     *      Now the rescue itself is an attempt to sell. If the pair takes the
     *      trade, the machine turns: the holders are paid, nothing is rescued,
     *      and this returns 0 with the sale left standing — a revert here
     *      would have undone the very payout that proved the coin healthy.
     *      Only a sale the venue actually declines opens the gate. Where the
     *      money goes then is the factory owner's problem to answer for
     *      publicly — the event names the amount and the address.
     */
    function rescueTax(address to)
        external
        onlyFactoryOwner
        nonReentrantSwap
        returns (uint256 amount)
    {
        if (to == address(0)) revert ZeroRecipient();
        if (pair == address(0)) revert NoPairYet();
        if (block.timestamp < lastLiquidatedAt + TAX_RESCUE_DELAY) revert LiquidationNotStalled();

        _liquidate();
        // It sold. That is the holders' money moving, which is the whole point;
        // the rescue has nothing to do and must not undo it.
        if (lastLiquidatedAt == block.timestamp) return 0;

        /*
         * A sale can fail because the venue is broken, and it can fail because
         * somebody arranged for it to fail for the length of one call.
         *
         * `_liquidate` sells inside a bare try/catch, and a Uniswap V2 pair
         * refuses every swap while it is inside one of its own. So calling
         * this from within a flash swap on the coin's own pair makes a
         * perfectly healthy coin decline its sale, and the proof-of-attempt
         * above passes with nothing wrong anywhere. Measured: the whole
         * 400,000-coin pot left the contract and the holders were paid
         * nothing, on a pair that was trading normally one call earlier.
         *
         * A pair in the middle of a swap is recognisable without asking it
         * anything: it has sent tokens out and has not yet written its
         * reserves, so it holds LESS than it says it holds. Outside a swap the
         * two always agree — every path that moves a pair's tokens ends by
         * syncing them. A venue that has genuinely stopped working leaves them
         * agreeing too, which is why this refuses the bypass without refusing
         * the rescue it exists for.
         */
        if (_pairIsMidSwap()) revert LiquidationNotStalled();

        amount = balanceOf(address(this));
        if (amount == 0) return 0;
        // This contract is excluded, so the transfer is untaxed and does not
        // recurse — see `_update`.
        _update(address(this), to, amount);
        emit TaxRescued(to, amount);
    }

    /**
     * @dev Whether the pair is part-way through a swap right now — tokens
     *      already out, reserves not yet written.
     *
     *      Both a Uniswap V2 pair and a Solidly one answer `getReserves()`
     *      with three words and `token0()` with an address, which is all this
     *      needs; a pair that answers neither is not something to judge, so it
     *      reads as "not mid-swap" and the ordinary gate decides.
     */
    function _pairIsMidSwap() private view returns (bool) {
        (bool okR, bytes memory rdata) =
            pair.staticcall(abi.encodeWithSignature("getReserves()"));
        if (!okR || rdata.length < 96) return false;
        (uint256 r0, uint256 r1,) = abi.decode(rdata, (uint256, uint256, uint256));

        (bool ok0, address t0) = _reportedToken(pair, 0x0dfe1681);
        if (!ok0) return false;

        (uint256 coinReserve, uint256 quoteReserve) =
            t0 == address(this) ? (r0, r1) : (r1, r0);
        if (balanceOf(pair) < coinReserve) return true;
        try IERC20(pairToken).balanceOf(pair) returns (uint256 held) {
            return held < quoteReserve;
        } catch {
            return false;
        }
    }

    /**
     * @notice Sell `amount` of accrued tax into this coin's own pair.
     *
     * @dev External only so `_liquidate` can wrap it in a try/catch; it refuses
     *      every caller but this contract, and `_swapping` is already true when
     *      it runs, so the transfer below is untaxed and cannot recurse.
     *
     *      NO ROUTER IS INVOLVED, and that is the point. The coin used to hand
     *      an allowance over its own balance to an address the factory had
     *      supplied, then call it and read the result. Both halves of that were
     *      trouble: whatever validation the address passed, it was still the
     *      one deciding whether the sale really happened, and an allowance that
     *      outlived the call was a standing claim on tax that had not been
     *      collected yet. A pair speaks a narrower language — hand it the
     *      coins, tell it how much to send back, and it either does that or
     *      reverts on its own invariant — so there is nothing left to trust and
     *      nothing left approved.
     */
    function sellTaxIntoPair(uint256 amount, address sink) external {
        if (msg.sender != address(this)) revert OnlySelf();

        address p = pair;
        bool coinIsToken0 = IUniswapV2Pair(p).token0() == address(this);

        // How much this pair will allow back out for `amount` in, worked out by
        // the exchange's own contract because the fee that decides it belongs
        // to the exchange. The coin is excluded from its own tax, so the pair
        // receives exactly `amount` and this is exactly what its invariant
        // permits.
        uint256 out = venue.amountOut(p, address(this), amount);
        if (out == 0) revert LiquidationShortfall();

        _update(address(this), p, amount);
        (uint256 out0, uint256 out1) = coinIsToken0 ? (uint256(0), out) : (out, uint256(0));
        IUniswapV2Pair(p).swap(out0, out1, sink, "");
    }

    /**
     * @dev Is the pool quoting a price, or the wreckage of somebody standing
     *      on it?
     *
     *      Asked of the exchange's own contract, because the answer depends on
     *      what oracle that exchange keeps: Uniswap V2 has a price accumulator,
     *      a Solidly fork has a ring of observations and a `quote` that already
     *      averages them, and a coin cannot be compiled knowing which.
     *
     *      A venue that reverts reads as "no", never as an exception. This is
     *      called on the path of somebody else's sell, and a refusal has to
     *      cost that trade a liquidation rather than the trade itself.
     */
    function _priceIsSane() private returns (bool ok) {
        try venue.priceIsSane(pair) returns (bool sane) {
            ok = sane;
        } catch {}
    }

    /**
     * @dev Split proceeds that are already sitting in the distributor.
     *
     *      Order matters: the creator's and burn slices are released FIRST, and
     *      only then is `deposit` called. Deposit shares out whatever is left
     *      unattributed, so the dividend slice needs no arithmetic of its own —
     *      it is the remainder, and rounding dust lands with the holders rather
     *      than being stranded.
     */
    /**
     * @dev Who the creator slice goes to, asked of the factory each time.
     *
     *      The factory can redirect it — the creator moving their own income,
     *      or an admin performing a community takeover on an abandoned project.
     *      Asked rather than stored so this coin keeps no setter of its own.
     *
     *      A factory that reverts or answers with nothing falls back to the
     *      launching wallet. This runs inside a liquidation, and a liquidation
     *      that fails leaves the tax stuck until the next sale — so the answer
     *      to "the registry is unreachable" has to be "pay who we always paid",
     *      not "stop paying anyone".
     */
    function _creatorPayee() private view returns (address) {
        try IPerpMeTaxFactory(factory).creatorRecipient(address(this)) returns (address to) {
            return to == address(0) ? creator : to;
        } catch {
            return creator;
        }
    }

    /**
     * @notice Split quote the curve has already delivered to the distributor.
     *
     * @dev    Dividends start on the bonding curve, not at graduation.
     *
     *         There is no pair to sell tax against while the curve is the
     *         market, so the tax cannot be taken in coins the way `_liquidate`
     *         takes it later. The curve takes it in QUOTE instead — a surcharge
     *         on its own trading fee — hands it straight to the distributor and
     *         calls this. The split is then the same code, the same
     *         `protocolBps`, and the same creator-to-holder ratio as after
     *         graduation, so a holder's share does not change shape when the
     *         pair opens; only where the tax is collected does.
     *
     *         The burn slice has nothing to burn here: every coin in existence
     *         is either sold to a holder or held back by the curve for the pair,
     *         and destroying either would break the curve's promise to deliver
     *         what it still owes. `_distribute` divides by
     *         `dividendBps + creatorBps`, so on the curve the burn's share is
     *         split between the creator and the holders in the ratio the
     *         creator chose. Burning begins with the first liquidation after
     *         graduation.
     *
     *         The amount MUST already be sitting unattributed in the
     *         distributor — the curve transfers first and calls second.
     */
    function settleCurveTax(uint256 amount) external {
        if (msg.sender != curve) revert OnlyCurve();
        if (amount == 0) return;
        _distribute(amount);
    }

    function _distribute(uint256 received) private {
        uint256 toProtocol = (received * protocolBps) / BPS;
        uint256 rest = received - toProtocol;

        // Measured against the shares that SURVIVED the burn, so choosing to
        // burn more does not quietly shrink the creator relative to holders —
        // the ratio a creator picked between the two is the ratio they get.
        uint256 shares = uint256(dividendBps) + creatorBps;
        uint256 toCreator = shares == 0 ? 0 : (rest * creatorBps) / shares;

        /*
         * Each payout is caught on its own.
         *
         * This runs in the SUCCESS arm of the try/catch around the swap, and
         * Solidity does not catch a revert raised there — so a payee that
         * cannot receive would revert the stranger's trade that triggered the
         * liquidation, and every trade after it. That is not hypothetical: the
         * tokenized shares screen recipients against a sanctions oracle, and
         * the creator's payee is an address the platform can point anywhere.
         *
         * A refused slice is simply not released. It stays unattributed, which
         * means `deposit` below hands it to the holders — a blocked creator
         * donates their share rather than freezing the market for everybody.
         */
        if (toProtocol != 0) {
            try distributor.releaseTo(protocolTreasury, toProtocol) {} catch {}
        }
        if (toCreator != 0) {
            try distributor.releaseTo(_creatorPayee(), toCreator) {} catch {}
        }

        uint256 toDividends = distributor.deposit();

        /*
         * Nobody eligible means nobody banks it for later.
         *
         * `deposit` cannot divide by zero shares, so it used to leave the money
         * where it was and try again next time. That quietly built a prize: a
         * coin whose holders have all sold, or are all under the creator's
         * dividend floor, accrues tax trade after trade with no owner — and the
         * next wallet to hold a share takes the entire accumulation in one
         * transaction. Measured at the shipped floor: 0.5926 of a 0.5927 pot,
         * to somebody who funded none of it and sold immediately after.
         *
         * So it is settled at collection instead of banked. The protocol
         * treasury is the sink rather than the creator, because the creator is
         * the one who chooses the dividend floor and would otherwise be paid
         * for setting it out of reach.
         */
        if (toDividends == 0) {
            uint256 orphaned = distributor.unattributed();
            if (orphaned != 0) {
                try distributor.releaseTo(protocolTreasury, orphaned) {} catch {}
            }
        }

        emit FundsSplit(toDividends, toCreator, toProtocol);

        /*
         * Push what was just funded out to holders, and never let it stop a
         * trade.
         *
         * Dividends arriving on their own is the point of the product — a
         * holder who never visits the site should still be paid. But this runs
         * inside somebody else's transfer, and an audit of the previous version
         * found that a revert on this path freezes every sell of the coin,
         * permanently, with no admin able to undo it. So the whole call is
         * swallowed: a failed pass costs a rotation, not a market.
         *
         * The budget is what a trade can afford to carry. The distributor stops
         * on it and remembers where it got to, so the work is spread across
         * trades rather than landed on one unlucky trader.
         *
         * And it is bounded by a COUNT, with no gas arithmetic anywhere on the
         * path. That is the third shape this bound has taken, and the first one
         * that a wallet can estimate.
         *
         * A budget passed as an argument was an honour system, so a slow holder
         * could eat the trade's gas. A real `{gas:}` stipend fixed that and
         * broke something worse: `{gas: N}` means "N OR 63/64 of what is left",
         * so how much the pass could afford still depended on how much the
         * sender gave — and `eth_estimateGas` finds the smallest limit that
         * works, which is one where the pass quietly does nothing. Run at that
         * estimate plus a wallet's margin and the pass suddenly can afford to
         * work, and spends what nobody counted. A seller's transaction died at
         * exactly its limit for that reason: 728,716 of 728,716, no logs.
         *
         * Two holders costs the same to estimate as to execute. The reward
         * token is the coin's own pair token — ours, not arbitrary — so there
         * is no untrusted callee here to need a stipend from.
         */
        try distributor.processFixed(AUTO_PAYOUT_HOLDERS) {} catch {}
    }
}
