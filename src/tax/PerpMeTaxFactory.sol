// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PerpMeTaxToken, PROTOCOL_BPS_CEILING} from "./PerpMeTaxToken.sol";
import {PerpMeTaxTokenDeployer} from "./PerpMeTaxTokenDeployer.sol";
import {PerpMeCurve} from "./PerpMeCurve.sol";
import {IPerpMeVenue} from "./venue/IPerpMeVenue.sol";

/**
 * @title PerpMeTaxFactory
 * @notice Launches dividend coins onto a bonding curve.
 *
 *         THE LAUNCHPAD OFFERS EXACTLY TWO PRODUCTS, AND THIS IS THE SECOND
 *
 *         A plain coin goes straight into a Uniswap V3 pool: concentrated
 *         liquidity, aggregator routing, and a 1% pool fee the locker splits
 *         with the creator. That is the other factory, and it is unchanged.
 *
 *         A dividend coin needs a bigger and steerable cut, and the only way to
 *         take one is on transfer — which Uniswap V3 cannot carry at all, as
 *         test/TaxTokenOnUniswap.t.sol demonstrates against the deployed
 *         router. So it lives on Uniswap V2, and it gets there through a curve.
 *
 *         WHY THERE IS NO SEED-AND-OPEN-A-PAIR PATH
 *
 *         There was one, briefly. A V2 pair cannot open one-sided, so it asked
 *         the creator to put up the quote side — around a hundred wNVDAx to
 *         open at twenty thousand dollars, unrecoverable, because the LP is
 *         burned on the spot. It worked, and it was strictly worse than the
 *         curve in every direction: it cost the creator real money, it set the
 *         opening valuation by how rich they happened to be, and it opened a
 *         market with nobody in it. The curve raises the quote side from the
 *         people who actually want the coin. Two ways to do one thing, one of
 *         them worse, is not a choice worth offering.
 */
contract PerpMeTaxFactory is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    error OwnershipIsNotRenounceable();
    error NotThePendingOwner();

    /**
     * The owner a transfer is waiting on.
     *
     * Ownership moves in two steps here, and cannot be dropped at all. Every
     * lever on every coin this factory has ever launched runs through
     * `owner()`: lowering a tax, excluding an address, rescuing stalled tax,
     * naming a venue. A single-step transfer to a mistyped address, or a
     * renounce, takes all of them away from every coin at once and for good —
     * including coins launched long before the mistake, whose creators had no
     * part in it. Written out rather than inherited because this build of
     * OpenZeppelin ships `Ownable` alone.
     */
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @dev Names the next owner. Nothing changes until they accept, so a
    ///      wrong address here is undone by naming the right one.
    function transferOwnership(address newOwner) public override onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /// @dev Proves the new owner can act before it has to.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotThePendingOwner();
        pendingOwner = address(0);
        _transferOwnership(msg.sender);
    }

    /// @dev There is no correct use of this on a factory whose owner is the
    ///      only address that can act for every coin it has launched.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipIsNotRenounceable();
    }

    /// @dev Where the coin sends its burn slice. Not address(0): a V2 pair
    ///      rejects it, and the coin shares this address with the curve's LP.
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    PerpMeTaxTokenDeployer public immutable TOKEN_DEPLOYER;
    address public immutable PROTOCOL_TREASURY;

    /**
     * @notice The router that lets somebody buy a curve-stage coin with HYPE.
     *
     * @dev Owner-settable, and snapshotted into each coin at launch: a coin
     *      trusts the router it was born with and cannot be handed a different
     *      one later. Zero is fine — the coin simply has no router and trades
     *      only in its pair token, which is what it did before this existed.
     */
    address public curveRouter;

    /**
     * @notice An exchange this factory can launch onto.
     *
     * @dev The whole of what differs between one exchange and the next lives
     *      behind `venue`: where the pair goes, what the pair will hand back
     *      for a given amount in, and whether the price it quotes is real. It
     *      used to be an immutable address on this contract plus Uniswap V2's
     *      arithmetic compiled into the coin, which meant a second exchange was
     *      a second factory, a second coin deployer, and a migration of the
     *      site, the indexer and every launched address onto them.
     *
     *      Added rather than replaced, and each coin keeps the one it launched
     *      with, so an exchange that turns out badly can be disabled for future
     *      launches without touching a coin already trading on it.
     */
    struct DexConfig {
        IPerpMeVenue venue;
        bool enabled;
        string name;
    }

    struct LaunchConfig {
        /// @dev Which exchange in `_dexConfigs` a coin on this config opens on.
        uint256 dexId;
        /**
         * @dev The token the coin is quoted against — and what its holders are
         *      paid dividends in. Must be non-rebasing and must not itself take
         *      a fee on transfer: a quote token that shrinks in transit would
         *      corrupt the dividend accounting on every liquidation.
         */
        address pairToken;
        uint256 totalSupply;
        bool enabled;
        /**
         * @dev The curve's shape.
         *
         *      `virtualQuote / virtualToken` is the opening price, so a whole
         *      supply opens at `virtualQuote * totalSupply / virtualToken` —
         *      the number the site shows as the starting valuation. Whatever
         *      `curveTokens` leaves over is held back to open the pair with,
         *      alongside everything the curve raised.
         */
        uint256 virtualToken;
        uint256 virtualQuote;
        uint256 curveTokens;
        uint16 curveFeeBps;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string metadataURI;
        /// @dev Base64 of the same JSON, so the coin can answer `contractURI`
        ///      without a gateway. Optional; empty falls back to the link.
        string metadataB64;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 dividendBps;
        uint16 creatorBps;
        uint16 burnBps;
        uint256 minDividendBalance;
        uint256 swapThreshold;
    }

    struct LaunchedToken {
        address creator;
        address curve;
        address pairToken;
        address distributor;
        /// Zero until the curve sells out and opens the pair.
        address pair;
        uint256 launchConfigId;
    }

    DexConfig[] private _dexConfigs;
    LaunchConfig[] private _launchConfigs;
    mapping(address => LaunchedToken) private _launchedTokens;

    /**
     * @dev Where a coin's creator slice is actually paid, when it is not the
     *      creator.
     *
     *      Kept HERE and not in the coin on purpose. The coin's whole claim is
     *      that it has no owner and not one setter — a claim a reader can check
     *      in a minute, and which one admin-callable function would destroy. So
     *      the coin asks this contract who to pay, and this contract is the one
     *      that already has an owner.
     */
    mapping(address => address) private _creatorRecipient;

    bool public launchEnabled = true;
    uint256 public launchFee;

    /**
     * @notice The protocol's cut of every coin's tax, in basis points.
     *
     * @dev Owner-settable, but SNAPSHOTTED into each coin at launch. Changing
     *      it prices future launches and can never touch a coin that already
     *      exists — the coin has no setter for its own rate. That is the
     *      difference between a published price and a lever over money that is
     *      already somebody else's.
     *
     *      The coin enforces its own ceiling too, so this cannot be pushed past
     *      it however careless an owner is.
     */
    uint16 public protocolFeeBps;

    error UnknownConfig();
    error ConfigDisabled();
    error LaunchDisabled();
    error InsufficientLaunchFee();
    error UnexpectedNativeValue();
    error FeeSendFailed();
    error ProtocolShareTooHigh(uint16 bps);
    error UnknownDex();
    error DexDisabled();
    error ZeroVenue();
    error NotTheCurve();
    error NotCreatorOrAdmin();
    error UnknownToken();

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address curve,
        address pairToken,
        address distributor,
        uint256 configId,
        uint256 initialBuy,
        uint256 boughtTokens
    );
    /**
     * @notice A coin's curve sold out and its pair is open.
     *
     * @dev Emitted HERE rather than only on the curve, and that is the whole
     *      reason `onGraduated` exists. An indexer can subscribe to every coin
     *      and every curve this factory ever creates, because their addresses
     *      appear in this contract's own events — but a pair's address appears
     *      for the first time inside a curve, one level further out, and
     *      subscribing to it would mean discovering contracts from the events
     *      of contracts that were themselves discovered from events. Reporting
     *      the pair back to the factory keeps every address the site needs one
     *      hop from here.
     */
    event Graduated(address indexed token, address indexed pair, uint256 tokens, uint256 quote);
    event ProtocolFeeChanged(uint16 bps);
    event PoolFeeChanged(uint16 bps);
    event CurveRouterChanged(address router);
    event CreatorRecipientChanged(address indexed token, address recipient, bool byAdmin);
    event DexConfigAdded(uint256 indexed dexId, address venue, string name);
    event DexConfigStatusChanged(uint256 indexed dexId, bool enabled);
    event LaunchConfigAdded(uint256 indexed configId, address pairToken);
    event LaunchConfigUpdated(uint256 indexed configId);

    /**
     * @dev No exchange here, deliberately.
     *
     *      This used to take the V2 factory and router as immutables, which
     *      made one launchpad one exchange for good. Exchanges are rows in
     *      `_dexConfigs` now, added by the owner, and a launch config names the
     *      row it opens on.
     */
    constructor(
        address tokenDeployer,
        address treasury,
        uint256 launchFee_,
        uint16 protocolFeeBps_
    ) Ownable(msg.sender) {
        if (protocolFeeBps_ > PROTOCOL_BPS_CEILING) revert ProtocolShareTooHigh(protocolFeeBps_);
        TOKEN_DEPLOYER = PerpMeTaxTokenDeployer(tokenDeployer);
        PROTOCOL_TREASURY = treasury;
        launchFee = launchFee_;
        protocolFeeBps = protocolFeeBps_;
    }

    // -------------------------------------------------------------------------
    //  Admin
    // -------------------------------------------------------------------------

    function setLaunchEnabled(bool enabled) external onlyOwner {
        launchEnabled = enabled;
    }

    function setLaunchFee(uint256 fee) external onlyOwner {
        launchFee = fee;
    }

    /// @notice Set the router FUTURE launches will trust. Live coins keep the
    ///         one they were launched with.
    function setCurveRouter(address router) external onlyOwner {
        curveRouter = router;
        emit CurveRouterChanged(router);
    }

    /// @notice Set the protocol's cut for FUTURE launches. Live coins keep the
    ///         rate they were launched with; they have no setter for it.
    /// @notice Register an exchange future configs can point at.
    function addDexConfig(IPerpMeVenue venue, string calldata name)
        external
        onlyOwner
        returns (uint256 dexId)
    {
        if (address(venue) == address(0)) revert ZeroVenue();
        dexId = _dexConfigs.length;
        _dexConfigs.push(DexConfig({venue: venue, enabled: true, name: name}));
        emit DexConfigAdded(dexId, address(venue), name);
    }

    /// @notice Stop or resume launches onto an exchange. Live coins keep theirs.
    function setDexStatus(uint256 dexId, bool enabled) external onlyOwner {
        if (dexId >= _dexConfigs.length) revert UnknownDex();
        _dexConfigs[dexId].enabled = enabled;
        emit DexConfigStatusChanged(dexId, enabled);
    }

    function dexConfigCount() external view returns (uint256) {
        return _dexConfigs.length;
    }

    function getDexConfig(uint256 dexId) external view returns (DexConfig memory) {
        if (dexId >= _dexConfigs.length) revert UnknownDex();
        return _dexConfigs[dexId];
    }

    function setProtocolFeeBps(uint16 bps) external onlyOwner {
        if (bps > PROTOCOL_BPS_CEILING) revert ProtocolShareTooHigh(bps);
        protocolFeeBps = bps;
        emit ProtocolFeeChanged(bps);
    }

    function addLaunchConfig(LaunchConfig calldata c) external onlyOwner returns (uint256 id) {
        id = _launchConfigs.length;
        _launchConfigs.push(c);
        emit LaunchConfigAdded(id, c.pairToken);
    }

    function updateLaunchConfig(uint256 id, LaunchConfig calldata c) external onlyOwner {
        if (id >= _launchConfigs.length) revert UnknownConfig();
        _launchConfigs[id] = c;
        emit LaunchConfigUpdated(id);
    }

    function launchConfigCount() external view returns (uint256) {
        return _launchConfigs.length;
    }

    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory) {
        if (id >= _launchConfigs.length) revert UnknownConfig();
        return _launchConfigs[id];
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory) {
        return _launchedTokens[token];
    }

    function isPerpMeToken(address token) external view returns (bool) {
        return _launchedTokens[token].creator != address(0);
    }

    /**
     * @notice Who a coin's creator slice is paid to.
     *
     * @dev Read by the coin every time it splits collected tax. Falls back to
     *      the launching wallet, so a coin nobody has ever touched pays exactly
     *      who it always did.
     */
    function creatorRecipient(address token) external view returns (address) {
        address over = _creatorRecipient[token];
        if (over != address(0)) return over;
        return _launchedTokens[token].creator;
    }

    /**
     * @notice Redirect a coin's creator slice.
     *
     *         Two people may call this, for two different reasons. The CREATOR,
     *         to move their own income — a lost key, a move to a multisig, a
     *         handover. The factory's OWNER, for a community takeover: when a
     *         project is abandoned, its fee stream should be able to follow
     *         whoever picked it up rather than paying someone who left.
     *
     * @dev It can only ever move the CREATOR's slice. There is deliberately no
     *      path from here to the holders' dividends or to the burn — an admin
     *      key that could reach those would not be a takeover mechanism, it
     *      would be a backdoor into other people's money.
     */
    function setCreatorRecipient(address token, address recipient) external {
        LaunchedToken storage t = _launchedTokens[token];
        if (t.creator == address(0)) revert UnknownToken();

        bool byAdmin = msg.sender == owner();
        address current = _creatorRecipient[token];
        bool byCreator = msg.sender == (current == address(0) ? t.creator : current);
        if (!byAdmin && !byCreator) revert NotCreatorOrAdmin();

        _creatorRecipient[token] = recipient;
        emit CreatorRecipientChanged(token, recipient, byAdmin && !byCreator);
    }

    /// @notice Called by a coin's own curve, once, when it opens the pair.
    function onGraduated(address token, address pair, uint256 tokens, uint256 quote) external {
        LaunchedToken storage t = _launchedTokens[token];
        if (t.curve == address(0) || msg.sender != t.curve) revert NotTheCurve();
        t.pair = pair;
        emit Graduated(token, pair, tokens, quote);
    }

    // -------------------------------------------------------------------------
    //  Launch
    // -------------------------------------------------------------------------

    /**
     * @notice Deploy a dividend coin and put its whole supply on a curve.
     *
     *         The creator pays the launch fee and nothing else. Buyers put up
     *         the quote token, and when the curve sells out it opens the
     *         Uniswap V2 pair itself with everything it raised, burning the LP.
     *
     * @param initialBuy Optional first purchase, made through the curve on the
     *                   creator's behalf and forwarded to them. Bought at the
     *                   same price as everybody else's; there is no allocation.
     */
    function launchToken(
        LaunchParams calldata p,
        uint256 configId,
        bytes32 userSalt,
        uint256 initialBuy,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, address curve) {
        if (!launchEnabled) revert LaunchDisabled();
        if (configId >= _launchConfigs.length) revert UnknownConfig();

        LaunchConfig memory cfg = _launchConfigs[configId];
        if (!cfg.enabled) revert ConfigDisabled();
        if (cfg.dexId >= _dexConfigs.length) revert UnknownDex();
        DexConfig memory dex = _dexConfigs[cfg.dexId];
        if (!dex.enabled) revert DexDisabled();
        if (msg.value != launchFee) {
            if (msg.value < launchFee) revert InsufficientLaunchFee();
            revert UnexpectedNativeValue();
        }

        // Deployed by the helper, initialized from here, so the coin records
        // THIS factory as its factory. Same transaction, so it is never
        // reachable uninitialized.
        token = TOKEN_DEPLOYER.deploy(keccak256(abi.encode(msg.sender, userSalt)));

        /*
         * The pool is opened here, empty, and not at graduation.
         *
         * Two things were wrong with leaving it to the end, and both of them
         * only appear once this factory is pointed at a venue that is not
         * Uniswap V2 itself.
         *
         * The coin has to know, from its first block, the one address it must
         * refuse to send coins to — the pool it will graduate into, which
         * anyone can fill in advance, add the quote side to, mint LP against
         * and then wait. That address used to be COMPUTED, from the two token
         * addresses and a hash of the pair's own creation code, and the hash
         * written here was Uniswap's. PRJX compiled its pair differently, so
         * every launch on it reserved an address where no pool would ever
         * appear, and the guard sat in front of nothing while the real pool
         * stood open. Asking the venue where the pair is cannot be wrong on any
         * venue, and needs no constant to keep in step with anything.
         *
         * And deploying a pair costs two million gas — measured at 2,001,365 on
         * PRJX. Spent at graduation it lands on whoever happens to make the
         * last purchase, whose transaction then wants 2.98M of a HyperEVM small
         * block that holds 3M, so an ordinary wallet cannot close a curve at
         * all. Spent here it lands in a transaction that already costs six
         * million and already runs in a big block, and the clearing buy drops
         * to about a million.
         *
         * An empty pair standing there for the whole curve is not a way in:
         * minting LP needs both sides, and the coin refuses every transfer to
         * this address until it graduates. Donating the quote side alone only
         * raises the opening price at the donor's own expense, which was true
         * before this change as well.
         */
        address pair = dex.venue.openPair(token, cfg.pairToken);

        PerpMeTaxToken(token).initialize(
            PerpMeTaxToken.InitParams({
                name: p.name,
                symbol: p.symbol,
                metadataURI: p.metadataURI,
                metadataB64: p.metadataB64,
                creator: msg.sender,
                locker: BURN_SINK,
                pairToken: cfg.pairToken,
                reservedPair: pair,
                protocolTreasury: PROTOCOL_TREASURY,
                totalSupply: cfg.totalSupply,
                protocolBps: protocolFeeBps,
                buyTaxBps: p.buyTaxBps,
                sellTaxBps: p.sellTaxBps,
                dividendBps: p.dividendBps,
                creatorBps: p.creatorBps,
                burnBps: p.burnBps,
                minDividendBalance: p.minDividendBalance,
                swapThreshold: p.swapThreshold,
                venue: address(dex.venue)
            })
        );

        curve = address(
            new PerpMeCurve(
                token,
                cfg.pairToken,
                PROTOCOL_TREASURY,
                cfg.virtualToken,
                cfg.virtualQuote,
                cfg.curveTokens,
                cfg.totalSupply - cfg.curveTokens,
                cfg.curveFeeBps
            )
        );

        // Told before it is funded, so the coin already knows it is in the
        // curve phase when the supply lands and cannot be moved elsewhere.
        PerpMeTaxToken(token).setCurve(curve, curveRouter);
        IERC20(token).safeTransfer(curve, cfg.totalSupply);

        _launchedTokens[token] = LaunchedToken({
            creator: msg.sender,
            curve: curve,
            pairToken: cfg.pairToken,
            distributor: address(PerpMeTaxToken(token).distributor()),
            pair: address(0),
            launchConfigId: configId
        });

        if (launchFee != 0) {
            (bool ok,) = PROTOCOL_TREASURY.call{value: launchFee}("");
            if (!ok) revert FeeSendFailed();
        }

        uint256 bought;
        if (initialBuy != 0) {
            // Measured, not assumed: the refund below is whatever came back
            // ABOVE what this contract already held, so a balance the factory
            // holds for any other reason is never swept out with it.
            uint256 heldBefore = IERC20(cfg.pairToken).balanceOf(address(this));

            IERC20(cfg.pairToken).safeTransferFrom(msg.sender, address(this), initialBuy);
            IERC20(cfg.pairToken).forceApprove(curve, initialBuy);
            /*
             * Bought FOR the creator, not bought and then forwarded.
             *
             * The curve settles the coin's tax the moment it has delivered, so
             * that the buyer is already a holder when their own trade funds the
             * dividend. Buying in the factory's name broke exactly that: the
             * factory is excluded from dividends, so at settlement the coin had
             * no holders at all, the dividend found no owner and the whole
             * holders' slice fell through the orphan path into the treasury.
             * Measured at 0.2021 wNVDAx out of every 10 the creator opened
             * with, on every launch that opened with a buy.
             *
             * Naming a recipient is safe because the curve refuses the reserved
             * pool to every caller before it asks who they are.
             */
            bought = PerpMeCurve(curve).buyFor(initialBuy, minTokensOut, msg.sender);

            /*
             * And the quote that came back with them.
             *
             * An initial buy large enough to clear the whole curve is trimmed,
             * and the curve refunds the excess to its caller — this factory,
             * which has no other way to move it. Without this the creator's own
             * money would sit here forever, and the bigger the launch the more
             * of it.
             */
            uint256 heldAfter = IERC20(cfg.pairToken).balanceOf(address(this));
            if (heldAfter > heldBefore) {
                IERC20(cfg.pairToken).safeTransfer(msg.sender, heldAfter - heldBefore);
            }
        }


        emit TokenLaunched(
            token,
            msg.sender,
            curve,
            cfg.pairToken,
            address(PerpMeTaxToken(token).distributor()),
            configId,
            initialBuy,
            bought
        );
    }

}
