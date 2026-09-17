// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @dev The coin's own verdict on whether an address is a market. Asked rather
///      than re-derived, so the two contracts can never disagree about it.
interface IPerpMeMarketCheck {
    function isMarket(address who) external view returns (bool);
}

/**
 * @title PerpMeDividendDistributor
 * @notice Pays one coin's holders in the token that coin is quoted against.
 *
 *         On this launchpad that quote asset is usually a tokenized share —
 *         wNVDAx, wAAPLx and thirteen others — so a holder's dividend arrives
 *         as a claim on NVIDIA or Apple rather than as more of the token
 *         they already hold. That is the point of paying in the quote side: it
 *         is the one asset in the pair whose value does not depend on the coin
 *         staying popular.
 *
 *         PAID OUT AUTOMATICALLY, AND CLAIMABLE ANYWAY
 *
 *         Dividends arrive on their own. Every trade nudges a rotating cursor a
 *         little further through the holder list and pays whoever it reaches,
 *         so a holder who never visits the site still gets paid. `claim` stays
 *         for anyone who wants their share now rather than when the rotation
 *         gets to them.
 *
 *         The push is bounded in three ways, and every one of them exists
 *         because of a specific way this goes wrong:
 *
 *           - A GAS BUDGET, so the cost of a trade cannot grow with the number
 *             of holders. Without it the thousandth holder makes the coin
 *             untradeable for everybody.
 *           - PER-RECIPIENT try/catch, so one address that cannot receive never
 *             stops the pass. This is not hypothetical here: the tokenized
 *             shares screen every transfer against a sanctions oracle and will
 *             revert on a blocked recipient.
 *           - A MINIMUM PERIOD AND AMOUNT, so the same holder is not paid dust
 *             on every trade at a gas cost larger than the dividend.
 *
 *         The caller decides the budget and the token wraps the whole call so
 *         it can never revert a trade. An audit of the previous version found
 *         exactly that failure — a revert on the payout path freezing every
 *         sell of the coin, permanently — so nothing on this path is allowed to
 *         propagate.
 *
 *         ACCOUNTING, NOT PAYMENTS
 *
 *         `setShare` only ever writes numbers. It never transfers, never calls
 *         out, and cannot revert on a holder's behalf, so a transfer of the
 *         coin never depends on anybody being willing or able to receive
 *         rewards. That separation is what makes the push above safe to bolt
 *         on: the money moves in a call that is allowed to fail.
 */
contract PerpMeDividendDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev 1e18 would round to zero for a six-decimal reward like USDC against
    ///      a billion-token supply. 1e36 leaves headroom for both extremes.
    uint256 private constant ACC_PRECISION = 1e36;

    /// The coin whose holders are paid. The only address allowed to move shares.
    address public immutable TOKEN;
    /// What holders are paid in — the coin's quote token.
    IERC20 public immutable REWARD;

    /**
     * @notice Balance below which a holder earns nothing.
     * @dev Dust holders would otherwise each accrue a few wei that costs more
     *      gas to pay than it is worth, and every one of them dilutes the
     *      holders who are actually exposed.
     */
    uint256 public immutable MIN_SHARE_BALANCE;

    /**
     * @dev Least a holder is paid in one automatic push, so the rotation does
     *      not spend more gas than it delivers. Claiming by hand ignores it.
     *
     *      A millionth of one reward token, worked out from that token's own
     *      decimals. It was a flat 1e12, which IS a millionth for the sixteen
     *      pairs with eighteen decimals and is one million whole tokens for
     *      USDC, which has six — so on a USDC-quoted coin the rotation skipped
     *      every holder it ever visited and the product's headline feature,
     *      dividends arriving on their own, silently did not exist. It failed
     *      quietly too: `Processed(paid 0, visited 1)` looks like a normal pass.
     *      Measured at 80.84 USDC accrued and nothing pushed.
     */
    uint256 public immutable MIN_AUTO_PAYOUT;
    /// @dev Least time between two automatic payouts to the same holder.
    uint256 public constant MIN_AUTO_PERIOD = 1 hours;
    /**
     * @dev The pass stops with at least this much gas left, so it always has
     *      room to return cleanly rather than running the caller out.
     *
     *      Low on purpose, and it was briefly not.
     *
     *      The reasoning for raising it was that the check happens before the
     *      work, so a floor under the cost of one iteration lets the loop start
     *      a pass it cannot finish and revert instead of stopping. True — but
     *      the coin now calls this with an explicit `{gas:}` stipend, so such a
     *      revert is confined to that stipend and swallowed, costing a rotation
     *      and nothing else. The floor is no longer what makes the caller safe.
     *
     *      What a high floor does instead is stop the loop from ever running.
     *      A purchase paid in HYPE reaches here through a bridge, the curve and
     *      the coin, and each nested call keeps a sixty-fourth for itself, so
     *      what arrives is well under six figures. At 120k the first live trade
     *      paid nobody: Processed(paid 0, visited 0), the dividend credited but
     *      never pushed. Automatic payment is the product; a floor that
     *      switches it off on the most common route is worse than a pass that
     *      occasionally runs out inside its own allowance.
     */
    uint256 private constant GAS_FLOOR = 60_000;

    struct Account {
        /// Counted shares — the holder's coin balance, or zero if under the floor.
        uint256 shares;
        /// `accPerShare` as of the last settlement, scaled by ACC_PRECISION.
        uint256 debt;
        /// Settled but not yet paid out.
        uint256 owed;
        /// Lifetime received, for the site.
        uint256 claimed;
        /// When this holder was last paid automatically.
        uint256 lastPaid;
        /// @dev When their share last fell to zero, or 0 if it never has.
        ///      `lastPaid` cannot stand in for this: a holder who sold before
        ///      the rotation ever reached them has never been paid at all, and
        ///      a zero there would read as "abandoned since the epoch".
        uint256 leftAt;
    }

    mapping(address => Account) public accounts;

    /// @dev Everyone with a non-zero share, so the rotation has something to
    ///      walk. Kept as an array plus a 1-based index for O(1) removal.
    address[] public shareholders;
    mapping(address => uint256) private _shareholderIndex;
    /// Where the next automatic pass starts.
    uint256 public cursor;

    uint256 public totalShares;
    uint256 public accPerShare;
    uint256 public totalDeposited;
    uint256 public totalClaimed;

    /**
     * @notice Money that was owed to somebody and has been put back in the pot.
     *
     * @dev Tracked apart from `totalClaimed` so the "paid to holders" figure
     *      the site shows stays a figure about holders. Both are subtracted
     *      from `totalDeposited` to get what is still reserved, which is what
     *      `unattributed` is measured against.
     */
    uint256 public totalReclaimed;

    /**
     * @notice Addresses that no longer earn new dividends.
     *
     * @dev The one lever the platform has over a live coin's dividends, and it
     *      exists because a launchpad that can do nothing at all is not
     *      neutral, it is absent. A sanctioned wallet, an exploiter draining a
     *      pool, a contract that holds the coin for somebody else: somebody has
     *      to be able to take them out of the split. It is deliberately NOT a
     *      transfer blocklist — an excluded holder trades exactly as before —
     *      and it is forward-looking only: what they had already earned stays
     *      theirs and stays claimable. There is no path here that moves a
     *      holder's dividend to the platform.
     */
    mapping(address => bool) public excluded;

    error OnlyToken();
    error NothingToClaim();
    error NotUnattributed(uint256 requested, uint256 available);
    error NotFactoryOwner();
    error StillEarning();
    error NotAbandoned(address holder);
    error CannotRescueReward();
    error ZeroRecipient();
    error CannotIncludeAMarket();

    event ShareUpdated(address indexed holder, uint256 shares);
    event Deposited(uint256 shared, uint256 carriedForward);
    event Claimed(address indexed holder, uint256 amount);
    event Released(address indexed to, uint256 amount);
    /// @dev Emitted rather than reverted — see the per-recipient try/catch.
    event PayoutFailed(address indexed holder, uint256 amount);
    event Processed(uint256 paid, uint256 visited);
    /// @dev Named on every automatic payment, so an indexer can say who was
    ///      paid what without reading the reward token's own transfers.
    event Paid(address indexed holder, uint256 amount);
    event ExclusionChanged(address indexed holder, bool excluded);
    /// @dev Money that was owed to `holder` put back in the pot for everybody.
    event Reclaimed(address indexed holder, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(address token_, address reward_, uint256 minShareBalance_) {
        TOKEN = token_;
        REWARD = IERC20(reward_);
        MIN_SHARE_BALANCE = minShareBalance_;

        /*
         * Asked of the reward token, and survivable if it will not say.
         *
         * A token that has no `decimals`, or answers with something absurd,
         * must not be able to stop a coin from launching — so a bad answer
         * falls back to eighteen, which is what every pair but one uses and
         * what the old constant assumed for all of them.
         */
        uint8 dec = 18;
        try IERC20Decimals(reward_).decimals() returns (uint8 d) {
            if (d <= 36) dec = d;
        } catch {}
        MIN_AUTO_PAYOUT = dec >= 6 ? 10 ** (uint256(dec) - 6) : 1;
    }

    modifier onlyToken() {
        if (msg.sender != TOKEN) revert OnlyToken();
        _;
    }

    /**
     * @dev Whoever owns the factory that launched the coin this contract pays
     *      for, or zero if there is no such thing.
     *
     *      Asked of the chain at the moment of the call rather than stored, the
     *      way the coin already asks the factory who to pay the creator. So a
     *      factory handed to a new owner hands these levers over with it, and a
     *      coin deployed without a factory — a test, a script — has nobody who
     *      can pull them. Both hops are staticcalls that tolerate an answer
     *      that never comes, because "there is no owner" has to be a safe
     *      outcome rather than a revert.
     */
    function factoryOwner() public view returns (address who) {
        (bool ok, bytes memory out) = TOKEN.staticcall(abi.encodeWithSignature("factory()"));
        if (!ok || out.length != 32) return address(0);
        address factory = abi.decode(out, (address));
        if (factory == address(0)) return address(0);
        (ok, out) = factory.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && out.length == 32) who = abi.decode(out, (address));
    }

    modifier onlyFactoryOwner() {
        address who = factoryOwner();
        if (who == address(0) || msg.sender != who) revert NotFactoryOwner();
        _;
    }

    /// @notice How many holders the rotation currently walks.
    function shareholderCount() external view returns (uint256) {
        return shareholders.length;
    }

    /**
     * @notice Record a holder's new balance.
     * @dev Called by the coin on both sides of every transfer. Settles what the
     *      holder earned on their OLD share count before changing it, so a sale
     *      never forfeits dividends already accrued and a purchase never earns
     *      dividends from before it.
     */
    function setShare(address holder, uint256 balance) external onlyToken {
        _setShare(holder, balance);
    }

    /// @dev The body of `setShare`, shared with `setExcluded` so a holder taken
    ///      out of the split is settled by exactly the same arithmetic as one
    ///      who sold.
    function _setShare(address holder, uint256 balance) private {
        Account storage a = accounts[holder];

        if (a.shares != 0) {
            a.owed += _pending(a);
            totalShares -= a.shares;
        }

        // An excluded holder counts for nothing however much they hold, and
        // stays that way through every later transfer without anyone acting.
        uint256 shares = (!excluded[holder] && balance >= MIN_SHARE_BALANCE) ? balance : 0;
        bool wasIn = _shareholderIndex[holder] != 0;

        a.shares = shares;
        a.debt = accPerShare;
        if (shares != 0) {
            totalShares += shares;
            if (!wasIn) {
                shareholders.push(holder);
                _shareholderIndex[holder] = shareholders.length;
            }
        } else if (wasIn) {
            _removeShareholder(holder);
        }
        /*
         * "Left" means the wallet is empty, not that it is small.
         *
         * This read the counted SHARE, which collapses to zero for anybody
         * under the payout floor — so a holder who sold most of their stack
         * and kept some had the abandonment clock started on them while they
         * were still holding the coin, and ten days later `reclaim` could take
         * dividends they had earned. The floor exists to keep dust out of the
         * payout loop; it was never meant to decide who has gone.
         */
        if (balance == 0) {
            if (a.leftAt == 0) a.leftAt = block.timestamp;
        } else {
            a.leftAt = 0;
        }

        emit ShareUpdated(holder, shares);
    }

    /// @dev Swap-and-pop, so removal costs the same whoever leaves.
    function _removeShareholder(address holder) private {
        uint256 i = _shareholderIndex[holder] - 1;
        uint256 last = shareholders.length - 1;
        if (i != last) {
            address moved = shareholders[last];
            shareholders[i] = moved;
            _shareholderIndex[moved] = i + 1;
        }
        shareholders.pop();
        delete _shareholderIndex[holder];
    }

    /**
     * @notice Take reward already transferred in and spread it over the shares.
     * @dev The coin transfers first and calls second, so this trusts its own
     *      balance rather than an argument: whatever arrived is what is shared.
     */
    function deposit() external onlyToken returns (uint256 shared) {
        return _spreadUnattributed();
    }

    /// @dev Everything nobody is owed, divided over everybody who is holding.
    function _spreadUnattributed() private returns (uint256 shared) {
        uint256 available = unattributed();
        if (available == 0) return 0;

        // Nobody to divide by. Left where it is — `unattributed` finds it again
        // on the next deposit, once somebody is eligible.
        if (totalShares == 0) {
            emit Deposited(0, available);
            return 0;
        }

        uint256 perShare = (available * ACC_PRECISION) / totalShares;
        accPerShare += perShare;

        /*
         * The WHOLE amount is recorded, not the part that divided evenly.
         *
         * The previous version recorded floor(perShare * totalShares / ACC) —
         * a wei or two short — while entitlements are floored once per HOLDER
         * over their whole accumulated delta rather than once per deposit. Over
         * many deposits the sum of what holders could claim drifted above the
         * sum recorded as deposited, and `totalDeposited - totalClaimed` is
         * checked arithmetic: the moment it went negative it reverted, inside
         * a liquidation, inside somebody's sell — and every sell after it.
         *
         * Recording the full amount makes the contract hold at least what it
         * owes by construction. The dust that no longer divides evenly simply
         * stays here as a buffer instead of being handed out twice.
         */
        totalDeposited += available;
        shared = available;
        emit Deposited(shared, 0);
    }

    /**
     * @notice Reward sitting here that has not been shared out yet.
     * @dev Balance minus what is already owed to holders, and saturating rather
     *      than checked: this is read on the payout path, and a subtraction
     *      that can revert there is a subtraction that can freeze the coin.
     */
    function unattributed() public view returns (uint256) {
        uint256 balance = REWARD.balanceOf(address(this));
        uint256 settled = totalClaimed + totalReclaimed;
        uint256 reserved = totalDeposited > settled ? totalDeposited - settled : 0;
        return balance > reserved ? balance - reserved : 0;
    }

    /**
     * @notice Hand part of the unshared balance to somebody else.
     *
     * @dev The coin swaps its collected tax straight into this contract,
     *      because Uniswap V2 refuses to send a swap's output to either of the
     *      pair's own tokens. So the proceeds land here and the coin releases
     *      the platform's and the creator's slices before calling `deposit`,
     *      leaving exactly the dividend slice to be shared.
     *
     *      The guard is the point: this can only ever move reward that has not
     *      been attributed to holders. Even a compromised coin cannot use it to
     *      take back a dividend somebody has already earned.
     */
    function releaseTo(address to, uint256 amount) external onlyToken {
        uint256 available = unattributed();
        if (amount > available) revert NotUnattributed(amount, available);
        REWARD.safeTransfer(to, amount);
        emit Released(to, amount);
    }

    /**
     * @notice Pay whoever the rotation reaches, within a gas budget.
     *
     * @dev Permissionless, so a keeper or an impatient holder can run it too —
     *      but normally the coin calls it during a trade. It NEVER reverts for
     *      a reason a caller could care about: a holder who cannot receive is
     *      skipped and logged, and the loop stops on gas rather than running
     *      the caller dry.
     *
     * @param gasBudget How much gas this pass may spend. Zero means "until the
     *                  floor", which is only safe for a direct call.
     */
    /**
     * @notice Pay a FIXED number of holders, whatever gas happens to be around.
     *
     * @dev    This exists because `process` cannot be estimated.
     *
     *         That loop runs for as long as gas remains, so how much it spends
     *         depends on how much it was given — and `eth_estimateGas` searches
     *         for the smallest limit that succeeds. It lands on a limit where
     *         the loop looks at the gas left, decides it cannot afford a pass,
     *         and does nothing. Execute at that estimate plus the wallet's
     *         usual margin and the loop CAN afford a pass, does the work, and
     *         spends what the estimate never accounted for. A seller's trade
     *         ran out of gas at exactly its limit — 728,716 used of 728,716,
     *         no logs — for that reason and no other.
     *
     *         A fixed count is deterministic: the same trade costs the same to
     *         estimate and to run. The coin calls this; a bot draining a long
     *         queue still wants `process`, which keeps its gas budget.
     */
    /**
     * @dev Both passes are guarded, and the guard is the same one `claim` uses.
     *
     *      The loop hands control to the reward token once per holder, and the
     *      reward token is somebody else's code. The accounting was already
     *      written so a re-entrant pass could not pay twice — each holder's
     *      `owed` is zeroed and `lastPaid` stamped before the transfer — but
     *      "cannot be exploited" and "cannot be re-entered" are different
     *      claims, and only the second one is easy for a reader to check.
     *      Sharing the guard with `claim` also closes the mirror of it: a
     *      holder claiming from inside their own payout callback.
     */
    function processFixed(uint256 holders)
        external
        nonReentrant
        returns (uint256 paid, uint256 visited)
    {
        return _pay(holders, 0);
    }

    function process(uint256 gasBudget)
        external
        nonReentrant
        returns (uint256 paid, uint256 visited)
    {
        return _pay(type(uint256).max, gasBudget);
    }

    function _pay(uint256 maxVisits, uint256 gasBudget)
        private
        returns (uint256 paid, uint256 visited)
    {
        uint256 count = shareholders.length;
        if (count == 0) return (0, 0);
        if (maxVisits > count) maxVisits = count;

        uint256 startGas = gasleft();
        uint256 i = cursor;

        while (visited < maxVisits) {
            // Only the gas-budgeted caller looks at the clock. A fixed-count
            // pass must not — not even through a `{gas:}` stipend on the way
            // in, since that resolves to a fraction of whatever is left and
            // brings the same unpredictability back through the door.
            if (gasBudget != 0) {
                if (gasleft() < GAS_FLOOR) break;
                if (startGas - gasleft() >= gasBudget) break;
            }

            if (i >= count) i = 0;
            address holder = shareholders[i];
            unchecked {
                ++i;
                ++visited;
            }

            Account storage a = accounts[holder];
            if (block.timestamp < a.lastPaid + MIN_AUTO_PERIOD) continue;
            if (a.owed + _pending(a) < MIN_AUTO_PAYOUT) continue;

            (, bool sent) = _settleAndSend(holder);
            if (sent) {
                unchecked {
                    ++paid;
                }
            }
        }

        cursor = i >= count ? 0 : i;
        emit Processed(paid, visited);
    }

    /// @dev Put an unpaid holder's money back where it was, so a refused
    ///      transfer costs them nothing but a wait.
    function _undoPayout(Account storage a, uint256 amount) private {
        a.owed = amount;
        a.claimed -= amount;
        totalClaimed -= amount;
    }

    /**
     * @notice Pay one holder everything they are owed. Anyone may call.
     *
     * @dev The whole reason this exists: the rotation walks `shareholders`, and
     *      a holder who sells drops out of that array while their settled
     *      `owed` stays behind. On the coin this design shipped as, that came
     *      to five percent of every dividend ever funded, held for people who
     *      had left and would never be visited again — reachable only if they
     *      thought to come back and press a button, which fifteen of them did.
     *
     *      So the push no longer depends on the array. A keeper reads who is
     *      owed from the indexer and names them here, holder or not. It cannot
     *      send anywhere but to `holder`, so a stranger calling this is doing
     *      somebody a favour at their own expense.
     *
     *      Swallows a refusal like the rotation does, and reports it, rather
     *      than reverting: a keeper draining a list must not lose the whole
     *      batch to one screened address.
     */
    function claimFor(address holder) public nonReentrant returns (uint256 amount) {
        bool sent;
        (amount, sent) = _settleAndSend(holder);
        if (!sent) amount = 0;
    }

    /**
     * @notice Pay every holder in the list what they are owed.
     *
     * @dev The list comes from outside because the contract has no business
     *      keeping one: an on-chain array is the thing that both costs a trader
     *      gas on every sale and silently drops anyone who sells. Nothing here
     *      trusts the list — each address is paid its own settled balance and
     *      nothing else — so the worst a bad list can do is waste the caller's
     *      gas.
     *
     * @param minAmount Least owed amount worth a transfer this call, the
     *        caller's gas judgement. Never below MIN_AUTO_PAYOUT.
     */
    function distribute(address[] calldata holders, uint256 minAmount)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (minAmount < MIN_AUTO_PAYOUT) minAmount = MIN_AUTO_PAYOUT;
        uint256 len = holders.length;
        for (uint256 i; i < len; ++i) {
            Account storage a = accounts[holders[i]];
            if (a.owed + _pending(a) < minAmount) continue;
            (, bool sent) = _settleAndSend(holders[i]);
            if (sent) {
                unchecked {
                    ++paid;
                }
            }
        }
        emit Processed(paid, len);
    }

    /**
     * @dev Settle everything owed to `holder` and try to send it.
     *
     *      One body for the rotation, the keeper's list and `claimFor`, so the
     *      three cannot drift: the account is zeroed BEFORE the transfer and
     *      put back if the transfer is refused, and `lastPaid` is stamped
     *      either way so a refused holder is not retried on every pass.
     */
    function _settleAndSend(address holder) private returns (uint256 amount, bool sent) {
        Account storage a = accounts[holder];
        amount = a.owed + _pending(a);
        if (amount == 0) return (0, false);

        a.owed = 0;
        a.debt = accPerShare;
        a.lastPaid = block.timestamp;
        a.claimed += amount;
        totalClaimed += amount;

        // Swallowed on purpose. A tokenized share can refuse a recipient, and
        // one refused holder must not stop everybody else being paid.
        try IERC20(REWARD).transfer(holder, amount) returns (bool ok) {
            sent = ok;
        } catch {}

        if (sent) {
            emit Paid(holder, amount);
        } else {
            _undoPayout(a, amount);
            emit PayoutFailed(holder, amount);
        }
    }

    /// @notice Withdraw everything owed to the caller, now.
    function claim() external nonReentrant returns (uint256 amount) {
        Account storage a = accounts[msg.sender];
        amount = a.owed + _pending(a);
        if (amount == 0) revert NothingToClaim();

        a.owed = 0;
        a.debt = accPerShare;
        a.claimed += amount;
        a.lastPaid = block.timestamp;
        totalClaimed += amount;

        REWARD.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice What `holder` could claim right now.
    function claimable(address holder) external view returns (uint256) {
        Account storage a = accounts[holder];
        return a.owed + _pending(a);
    }

    // -------------------------------------------------------------------------
    //  What the platform can do, and what it deliberately cannot
    // -------------------------------------------------------------------------

    /**
     * @notice How long after a holder stops earning their unclaimed dividend
     *         may be handed back to the holders who are still here.
     */
    uint256 public constant ABANDON_PERIOD = 10 days;

    /**
     * @notice Stop an address earning new dividends, or let it earn again.
     *
     * @dev A launchpad that can do nothing at all about a sanctioned wallet or
     *      an address draining its own coin is not neutral, it is absent. This
     *      is the answer, and it is bounded on purpose:
     *
     *        - It is NOT a transfer blocklist. An excluded holder buys, sells
     *          and transfers exactly as before. They stop earning, nothing
     *          more.
     *        - What they had already earned STAYS THEIRS and stays claimable.
     *          There is no function in this contract that moves an earned
     *          dividend to the platform, and adding one would make every other
     *          promise here unverifiable.
     *        - It is reversible. Un-excluding restores their share from their
     *          real balance at once, without waiting for a transfer.
     */
    function setExcluded(address holder, bool value) external onlyFactoryOwner {
        if (excluded[holder] == value) return;
        /*
         * A market cannot be un-excluded.
         *
         * The pair holds most of the supply, so restoring it as a shareholder
         * hands it two thirds of every later dividend — measured at 6,643 bps
         * of total shares on an ordinary graduated coin — and a stranger can
         * then `skim` the reward straight out of it. The coin re-excludes a
         * market only when it next sees a transfer it is part of, which may be
         * never, so this is not self-healing. Exclusion stays reversible for
         * an ordinary wallet, which is what it is for.
         */
        if (!value && IPerpMeMarketCheck(TOKEN).isMarket(holder)) revert CannotIncludeAMarket();
        excluded[holder] = value;
        emit ExclusionChanged(holder, value);

        // Settles what they earned on the old share count, then zeroes or
        // restores the share against the balance they actually hold.
        _setShare(holder, IERC20(TOKEN).balanceOf(holder));

        /*
         * What they had already earned is NOT taken back.
         *
         * Exclusion used to reclaim it and spread it over the other holders in
         * the same call. That was never the platform's money, but it was a
         * holder's earned dividend removed by one owner transaction with no
         * waiting period — and scanners read it, correctly, as "the owner can
         * take unpaid rewards" (Axiom, MEDIUM, 2026-09-14). `_setShare` above
         * has already settled it into `owed`, where the bot, `claimFor` and
         * `claim` all still reach it. Only if the wallet later empties and
         * stays empty for ABANDON_PERIOD can `reclaim` hand it to the holders,
         * exactly as for anyone else who left.
         */
    }

    /**
     * @notice Hand unclaimed dividends of long-departed holders back to the pot.
     *
     * @dev Only for an address that has held nothing for `ABANDON_PERIOD` and
     *      never came to collect. Everything else about it is refused: a holder
     *      still earning cannot be touched at all, and the money does not leave
     *      this contract — it is spread over whoever is holding now, in this
     *      same call.
     *
     *      Spread here, not left in `unattributed` for the next deposit, so the
     *      holders are owed it before the transaction ends. (Left there it was
     *      once reachable by an owner sweep; that function is gone, 2026-09-15.)
     *
     *      Ten days is short on purpose: the bot and `claimFor` deliver a
     *      departed holder's dividend without their doing anything, so what is
     *      still here after that is money that could not be delivered, and it
     *      does more good with the holders than parked under an empty wallet.
     */
    function reclaim(address[] calldata holders) external onlyFactoryOwner returns (uint256 total) {
        uint256 len = holders.length;
        for (uint256 i; i < len; ++i) {
            address holder = holders[i];
            Account storage a = accounts[holder];
            if (a.shares != 0) revert StillEarning();
            if (a.leftAt == 0 || block.timestamp < a.leftAt + ABANDON_PERIOD) {
                revert NotAbandoned(holder);
            }
            total += _reclaim(holder);
        }
        _spreadUnattributed();
    }

    /// @dev Zero what `holder` is owed and account for it as spread again.
    function _reclaim(address holder) private returns (uint256 amount) {
        Account storage a = accounts[holder];
        amount = a.owed + _pending(a);
        if (amount == 0) return 0;
        a.owed = 0;
        a.debt = accPerShare;
        totalReclaimed += amount;
        emit Reclaimed(holder, amount);
    }

    /**
     * @notice Share out reward that nobody is owed yet over the holders. Anyone
     *         may call.
     *
     * @dev Reward can sit here unattributed in two ways: a deposit that came
     *      while nobody was eligible to earn, and a plain transfer to this
     *      contract that no deposit accounted for. The next deposit spreads
     *      both anyway; this is for a coin that may never have another one.
     *
     *      It replaces `sweepUnattributed`, which sent the same pot wherever the
     *      factory owner named. That could never reach a wei anybody was owed,
     *      but it was still the platform able to take reward meant for the
     *      holders — and with exclusion it could be made to: exclude every
     *      holder, let a deposit land on zero shares, sweep. Scanners flagged
     *      it (Axiom, LOW, 2026-09-14). Now there is no owner path for the
     *      reward token at all; the only place it can go is the holders.
     *
     *      Assumes the reward token calls nobody back on transfer, as every
     *      quote token the factory admits does: the coin and the curve move
     *      reward in first and split it second, and a hook in between could
     *      spread the creator's and the platform's slices too.
     *
     * @return shared What was added to the holders' entitlement; 0 while
     *         nobody is eligible, in which case it stays for later.
     */
    function spreadUnattributed() external nonReentrant returns (uint256 shared) {
        return _spreadUnattributed();
    }

    /**
     * @notice Recover a token that has no business being here.
     *
     * @dev Anything but the reward token, which has an owner for every wei of
     *      it and its own bounded path above. Somebody will eventually send
     *      this contract the coin itself, or a stray airdrop, and without this
     *      it is gone.
     */
    function rescue(address token, address to) external onlyFactoryOwner returns (uint256 amount) {
        if (token == address(REWARD)) revert CannotRescueReward();
        if (to == address(0)) revert ZeroRecipient();
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return 0;
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @dev Earned on the current share count since the last settlement.
    function _pending(Account storage a) private view returns (uint256) {
        return (a.shares * (accPerShare - a.debt)) / ACC_PRECISION;
    }
}
