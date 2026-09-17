// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

/**
 * @title IPerpMeVenue
 * @notice Everything a dividend coin needs to know about the exchange it
 *         graduated onto, and the only part of it that differs between one
 *         exchange and the next.
 *
 *         WHY THIS EXISTS AS A CONTRACT RATHER THAN AS CODE IN THE COIN
 *
 *         The coin used to speak Uniswap V2 directly: it worked out what the
 *         pair would hand back using V2's 0.3% fee, and it read V2's price
 *         accumulator to decide whether the pool was quoting a real price. Both
 *         of those are properties of one exchange rather than of the idea of an
 *         exchange. On PRJX they happen to hold. On Ramses and Nest, which are
 *         Solidly forks, neither does: the fee lives on the pair and can be
 *         changed, and there is no price accumulator at all, only a `quote`
 *         that already returns an average.
 *
 *         Compiled into the coin, adding an exchange meant new coin code, which
 *         means a new deployer, which is welded to a new factory, which means
 *         moving the site, the indexer and every launched coin's address list
 *         onto it. Behind this interface it means deploying one small contract
 *         and adding a launch config.
 *
 *         WHAT IT IS ALLOWED TO DO, AND WHAT IT IS NOT
 *
 *         It computes and it answers. It never holds a coin, is never given an
 *         allowance, and never moves anybody's money — the swap itself is still
 *         the coin handing tokens to the pair and telling the pair how much to
 *         send back, which is the narrowest thing either side can say to the
 *         other. So the worst a bad implementation can do is quote a bad number
 *         into a sale that is already capped at half a percent of the pool.
 */
interface IPerpMeVenue {
    /**
     * @notice The pair for these two tokens, created if it is not there yet.
     * @dev Called by the factory at launch. Solidly-style venues take a third
     *      `stable` argument that this hides; a dividend coin is only ever
     *      volatile, so there is nothing to decide.
     */
    function openPair(address tokenA, address tokenB) external returns (address pair);

    /**
     * @notice Addresses this venue moves a pair's fee to, which therefore end
     *         up holding the coin without ever having bought it.
     *
     * @dev Two, because that is how many a Solidly pair has — a `fees` contract
     *      and a `communityVault` — and a fixed pair of slots costs the coin
     *      less code than an array it would have to loop over on every
     *      transfer. Either may be zero, and Uniswap V2 answers zero for both:
     *      it leaves the fee in the reserves, so nothing outside the pair ever
     *      holds the coin on its behalf.
     *
     *      This matters to the dividend accounting rather than to trading. On
     *      Nest the fee leaves the pair IN THE TOKEN — its community vault is
     *      holding 6.39 NEST today — so for one of our coins that address would
     *      be a holder, earning a share of every dividend, with no way to claim
     *      it and no person behind it. The coin excludes whatever is named here
     *      when the pair is set.
     */
    function feeSinks(address pair) external view returns (address a, address b);

    /**
     * @notice What `pair` will hand back for `amountIn` of `tokenIn`.
     * @dev Worked out with the venue's own fee, read from the venue rather than
     *      remembered, because on a Solidly fork it is set per pair and can be
     *      moved by governance after the coin has launched.
     */
    function amountOut(address pair, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256);

    /**
     * @notice What `pair` will hand back for tokens ALREADY sitting in it but
     *         not yet counted in its reserves, and how many those are.
     *
     * @dev The shape every fee-taking token has to be swapped through, and the
     *      reason it cannot be `amountOut` with a number the caller worked out
     *      itself: a dividend coin keeps a cut of any transfer into the pair,
     *      so the pair receives less than was sent and only the pair knows how
     *      much less. Reading the balance against the stale reserves is the
     *      only honest measure, and it has to happen after the transfer.
     *
     *      Used by `PerpMeMarketRouter` to carry a trade across two exchanges —
     *      the V3 bridge that turns HYPE into the share, then this pair. It is
     *      on this interface rather than on a second one so that a venue added
     *      later cannot be one that coins can only be bought on by people who
     *      already hold the right share.
     */
    function amountOutUnsynced(address pair, address tokenIn)
        external
        view
        returns (uint256 amountIn, uint256 amountOut);

    /**
     * @notice Is `pair` quoting a price, or the wreckage of somebody standing
     *         on it?
     * @dev Stateful: an implementation may keep a reference to average against.
     *      That reference is keyed by the CALLER as well as the pair, so only
     *      the coin can move its own, exactly as when this lived inside it.
     *      Called by the coin with itself as `msg.sender`.
     */
    function priceIsSane(address pair) external returns (bool);
}
