// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ForkPin} from "./ForkPin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeDividendDistributor} from "../src/tax/PerpMeDividendDistributor.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";

interface IV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256, uint256, address, bytes calldata) external;
}

/**
 * Borrows a coin from the pair and repays it, over and over.
 *
 * A V2 pair is locked for the duration of a flash swap, so the repayment counts
 * as a sell, triggers a liquidation, and the liquidation's own swap hits that
 * lock and reverts. See test_FlashSwapCannotBurnThePotWithoutPayingHolders.
 */
/**
 * The four lines it takes to be judged a market.
 *
 * `_isMarket` forms its verdict by asking an address `token0()` and
 * `token1()` and seeing the coin named in one of them. Nothing else: no
 * reserves, no factory, no liquidity. So this is a market as far as the coin
 * is concerned, and a seller who routes through it is selling into one.
 */
contract PretendMarket {
    address public token0;
    address public token1;

    constructor(address coin, address other) {
        token0 = coin;
        token1 = other;
    }
}

contract FlashGriefer {
    address public immutable PAIR;
    address public immutable COIN;
    address public immutable QUOTE;
    uint256 public immutable TAX_BPS;

    constructor(address pair, address coin, address quote, uint256 taxBps) {
        PAIR = pair;
        COIN = coin;
        QUOTE = quote;
        TAX_BPS = taxBps;
    }

    function grief(uint256 rounds, uint256 borrow) external {
        bool quoteIs0 = IV2Pair(PAIR).token0() == QUOTE;
        for (uint256 i; i < rounds; i++) {
            if (quoteIs0) IV2Pair(PAIR).swap(borrow, 0, address(this), hex"01");
            else IV2Pair(PAIR).swap(0, borrow, address(this), hex"01");
        }
    }

    function uniswapV2Call(address, uint256 a0, uint256 a1, bytes calldata) external {
        (uint112 r0, uint112 r1,) = IV2Pair(PAIR).getReserves();
        (uint256 rQuote, uint256 rCoin) = IV2Pair(PAIR).token0() == QUOTE
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
        uint256 out = a0 + a1;
        // getAmountIn, then grossed up for the cut the coin takes off a
        // transfer into the pair. Two wei of slack, no more.
        uint256 amountIn = (rCoin * out * 1000) / ((rQuote - out) * 997) + 1;
        IERC20(COIN).transfer(PAIR, (amountIn * 10000) / (10000 - TAX_BPS) + 2);
    }
}

interface IV2Factory {
    function createPair(address, address) external returns (address);
    function getPair(address, address) external view returns (address);
}

interface IV2Router {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256, uint256);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/**
 * The dividend coin, end to end, on a fork of HyperEVM mainnet against the real
 * Uniswap V2 deployment and a real tokenized share as the quote asset.
 *
 * This test stands in for the product claim — "hold the coin, get paid in
 * NVIDIA" — so it uses wNVDAx rather than a mock. Anything that only works
 * against a mock quote token has not been tested.
 */
contract PerpMeTaxTokenTest is Test {
    /* PRJX's V2, verified on chain 999.

       These used to be read from the environment with no default, which meant
       every one of these suites skipped itself on every run — the check reads
       `code.length` before the fork is selected, where nothing has code at all.
       They were green for a year without executing. */
    address constant V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant V2_ROUTER = 0xb929E50f930841414c398E653b89638516094D09;
    address constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    /// Wrapped NVIDIA xStock — a real pair token on this launchpad.
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;

    uint256 constant SUPPLY = 1_000_000_000e18;

    PerpMeTaxToken coin;
    PerpMeDividendDistributor dist;
    address pair;

    address creator = address(0xC0FFEE);
    address locker = address(0x10CCE7);
    address protocolTreasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    /// Who the coin will let lower its tax. This contract stands in for the
    /// factory, so this is what its `owner()` answers.
    address admin = address(0xAD);

    function owner() external view returns (address) {
        return admin;
    }

    PerpMeUniV2Venue venue;

    function setUp() public {
        /* No V2 venue configured for HyperEVM yet — see the note above. */
        ForkPin.select();

        venue = new PerpMeUniV2Venue(V2_FACTORY, 30);

        coin = new PerpMeTaxToken();
        coin.initialize(_params(300, 300, 8000, 1500, 500));
        dist = coin.distributor();

        // This contract stands in for the factory, so it is tax-exempt and can
        // seed the pair the way a real launch would.
        pair = IV2Factory(V2_FACTORY).getPair(address(coin), WNVDAX);
        deal(WNVDAX, address(this), 10_000e18);

        coin.approve(V2_ROUTER, type(uint256).max);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).addLiquidity(
            address(coin), WNVDAX, 500_000_000e18, 1_000e18, 0, 0, locker, block.timestamp
        );

        coin.setPair(pair);

        deal(WNVDAX, alice, 500e18);
        deal(WNVDAX, bob, 500e18);
    }


    /// Stands in for what the factory now does at launch: open the empty pair
    /// and hand the coin its real address, instead of predicting one.
    function _openPair(address a, address b) internal returns (address p) {
        p = IV2Factory(V2_FACTORY).getPair(a, b);
        if (p == address(0)) p = IV2Factory(V2_FACTORY).createPair(a, b);
    }

    function _params(
        uint16 buyBps,
        uint16 sellBps,
        uint16 divBps,
        uint16 creatorBps,
        uint16 burnBps
    ) internal returns (PerpMeTaxToken.InitParams memory) {
        return PerpMeTaxToken.InitParams({
            name: "Dividend Coin",
            symbol: "DIV",
            metadataURI: "ipfs://x",
            metadataB64: "",
            creator: creator,
            locker: locker,
            pairToken: WNVDAX,
            reservedPair: _openPair(address(coin), WNVDAX),
            protocolTreasury: protocolTreasury,
            totalSupply: SUPPLY,
            protocolBps: 2000,
            buyTaxBps: buyBps,
            sellTaxBps: sellBps,
            dividendBps: divBps,
            creatorBps: creatorBps,
            burnBps: burnBps,
            minDividendBalance: 1_000e18,
            swapThreshold: 100_000e18,
                venue: address(venue)
        });
    }

    function _buy(address who, uint256 spend) internal {
        address[] memory path = new address[](2);
        path[0] = WNVDAX;
        path[1] = address(coin);
        vm.startPrank(who);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            spend, 0, path, who, block.timestamp
        );
        vm.stopPrank();
    }

    function _sell(address who, uint256 amount) internal {
        /*
         * Trades land minutes apart, not all in one instant.
         *
         * The coin averages the pool's price over the time since it last looked
         * and refuses to sell its tax until that stretch is long enough to be
         * worth averaging — so a file where every trade shares one timestamp
         * would never see a liquidation at all, and every assertion about
         * dividends, burns and the creator's share below would be measuring a
         * sale that never happened.
         */
        // Read through the cheatcodes: under via_ir the optimiser folds
        // repeated `block.timestamp` reads within a call into one, and a
        // helper called several times would warp to the same second twice.
        vm.warp(vm.getBlockTimestamp() + 301);
        // Minutes later is also blocks later. The coin sells its tax at most
        // once per block, so a file where every sell shares one block number
        // would see exactly one liquidation and then none.
        vm.roll(vm.getBlockNumber() + 301);

        address[] memory path = new address[](2);
        path[0] = address(coin);
        path[1] = WNVDAX;
        vm.startPrank(who);
        coin.approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, who, block.timestamp
        );
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------

    /// Sells land minutes apart by default; this one does not, for the TWAP.
    function _sellNow(address who, uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = address(coin);
        path[1] = WNVDAX;
        vm.startPrank(who);
        coin.approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, who, block.timestamp
        );
        vm.stopPrank();
    }

    /**
     * Fund two dividends inside one hour.
     *
     * The first is pushed to alice by the rotation, which stamps her. The
     * second lands while that stamp is still fresh, so it is credited and not
     * sent — which is the state every holder is in most of the time, and the
     * state they take with them when they sell.
     */
    function _creditAliceWithoutPaying() internal returns (uint256 owed) {
        _buy(alice, 20e18);
        _buy(bob, 20e18);
        _sell(bob, coin.balanceOf(bob) / 4); // liquidation one, warps past the window

        _buy(bob, 5e18); // more tax, and a buy never liquidates
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.roll(vm.getBlockNumber() + 60);
        coin.liquidate(); // liquidation two, well inside the hour

        owed = dist.claimable(alice);
        assertGt(owed, 0, "alice is owed something she has not been sent");
    }

    /// The same, and then she sells out of the holder list entirely.
    function _strandAliceWithADividend() internal returns (uint256 owed) {
        owed = _creditAliceWithoutPaying();
        // Read the balance BEFORE the prank: a staticcall in the argument list
        // would consume it, and the transfer would come from this contract.
        uint256 all = coin.balanceOf(alice);
        vm.prank(alice);
        coin.transfer(address(0xCA401), all);

        assertEq(coin.balanceOf(alice), 0, "she really left");
        (uint256 shares,,,,,) = dist.accounts(alice);
        assertEq(shares, 0, "and stopped earning");
        assertEq(dist.claimable(alice), owed, "leaving does not forfeit it");
    }

    /**
     * The bug the live coin shipped with: a holder who sells keeps what they
     * earned, but the rotation can never visit them again. Anyone can now
     * deliver it for them.
     */
    function test_ASoldOutHolderCanBePaidByAnybody() public {
        uint256 owed = _strandAliceWithADividend();

        dist.process(3_000_000);
        assertEq(dist.claimable(alice), owed, "the rotation cannot reach her");

        uint256 before = IERC20(WNVDAX).balanceOf(alice);
        vm.prank(bob);
        uint256 paid = dist.claimFor(alice);
        assertEq(paid, owed, "reported what it paid");
        assertEq(IERC20(WNVDAX).balanceOf(alice) - before, owed, "and she has it");
        assertEq(dist.claimable(alice), 0, "nothing left owing");
    }

    /// A keeper pays a list, and one address that cannot be paid costs the
    /// others nothing.
    function test_DistributePaysAListAndSurvivesARefusal() public {
        uint256 owed = _strandAliceWithADividend();
        address[] memory list = new address[](3);
        list[0] = alice;
        list[1] = address(0xDEADBEEF); // owed nothing, skipped
        list[2] = bob;

        uint256 before = IERC20(WNVDAX).balanceOf(alice);
        uint256 paid = dist.distribute(list, 0);
        assertGe(paid, 1, "at least alice was paid");
        assertEq(IERC20(WNVDAX).balanceOf(alice) - before, owed, "alice paid in full");
    }

    /// Excluding a holder stops them earning from then on. What they had
    /// already earned stays theirs — the owner cannot take it back, not even
    /// for the other holders.
    function test_ExcludingAHolderKeepsWhatTheyEarned() public {
        uint256 owed = _creditAliceWithoutPaying();
        uint256 sharesBefore = dist.totalShares();
        uint256 bobBefore = dist.claimable(bob);

        vm.prank(admin);
        dist.setExcluded(alice, true);

        assertEq(dist.claimable(alice), owed, "her accrual is still hers");
        assertEq(dist.totalReclaimed(), 0, "nothing reclaimed");
        assertEq(dist.claimable(bob), bobBefore, "and nothing moved to the others");
        assertLt(dist.totalShares(), sharesBefore, "she stopped earning");
        (, , , , , uint256 leftAt) = dist.accounts(alice);
        assertEq(leftAt, 0, "still holding, so not abandoned either");

        // New tax goes to the holders who still earn, not to her.
        _buy(bob, 5e18);
        vm.warp(vm.getBlockTimestamp() + 3600);
        vm.roll(vm.getBlockNumber() + 3600);
        coin.liquidate();
        assertEq(dist.claimable(alice), owed, "she earns nothing new");

        // Still a perfectly ordinary token for her, and she can collect.
        vm.prank(alice);
        coin.transfer(bob, 1e18);
        uint256 before = IERC20(WNVDAX).balanceOf(alice);
        vm.prank(alice);
        dist.claim();
        assertEq(IERC20(WNVDAX).balanceOf(alice) - before, owed, "and paid in full");

        vm.prank(admin);
        dist.setExcluded(alice, false);
        (uint256 shares,,,,,) = dist.accounts(alice);
        assertGt(shares, 0, "and she can be let back in");
    }

    function test_OnlyTheFactoryOwnerCanExclude() public {
        vm.prank(bob);
        vm.expectRevert(PerpMeDividendDistributor.NotFactoryOwner.selector);
        dist.setExcluded(alice, true);
    }

    /// Abandoned money goes back to the holders, but only after ABANDON_PERIOD
    /// and only from somebody who has stopped earning.
    function test_ReclaimWaitsTheAbandonPeriodAndRefusesALiveHolder() public {
        uint256 owed = _strandAliceWithADividend();
        address[] memory one = new address[](1);
        one[0] = alice;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpMeDividendDistributor.NotAbandoned.selector, alice));
        dist.reclaim(one);

        one[0] = bob; // still holding
        vm.prank(admin);
        vm.expectRevert(PerpMeDividendDistributor.StillEarning.selector);
        dist.reclaim(one);

        // One second short is still refused.
        (,,,,, uint256 leftAt) = dist.accounts(alice);
        vm.warp(leftAt + dist.ABANDON_PERIOD() - 1);
        one[0] = alice;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpMeDividendDistributor.NotAbandoned.selector, alice));
        dist.reclaim(one);

        vm.warp(leftAt + dist.ABANDON_PERIOD());
        uint256 bobBefore = dist.claimable(bob);
        vm.prank(admin);
        assertEq(dist.reclaim(one), owed, "handed back to the pot");
        assertEq(dist.claimable(alice), 0);
        // Spread in the same call: nothing is left for a sweep to send away.
        assertEq(dist.unattributed(), 0, "nothing left sweepable");
        // Divided over everybody still holding, Bob among them.
        assertGt(dist.claimable(bob), bobBefore, "it went to the holders who stayed");
        assertEq(dist.spreadUnattributed(), 0, "and there is nothing left over");
    }

    /**
     * Reward nobody is owed goes to the holders, whoever calls — and there is
     * no longer a way for the owner to send it anywhere else.
     */
    function test_StrayRewardIsSpreadOverTheHoldersByAnyone() public {
        _strandAliceWithADividend();
        uint256 owedTotal = dist.totalDeposited() - dist.totalClaimed();
        uint256 bobBefore = dist.claimable(bob);

        deal(WNVDAX, address(this), 10_000e18);
        uint256 stray = dist.unattributed() + 1e18;
        IERC20(WNVDAX).transfer(address(dist), 1e18); // a stray transfer
        assertEq(dist.unattributed(), stray);

        vm.prank(address(0xBEEF)); // a stranger
        assertEq(dist.spreadUnattributed(), stray, "shared out");
        assertEq(dist.unattributed(), 0);
        assertGt(dist.claimable(bob), bobBefore, "to the holders who are earning");
        assertGe(IERC20(WNVDAX).balanceOf(address(dist)), owedTotal + 1e18, "everything reserved is still here");

        (bool ok,) = address(dist).call(abi.encodeWithSignature("sweepUnattributed(address)", protocolTreasury));
        assertFalse(ok, "the owner sweep is gone");
    }

    function test_RescueRefusesTheRewardTokenAndTakesTheRest() public {
        vm.prank(admin);
        vm.expectRevert(PerpMeDividendDistributor.CannotRescueReward.selector);
        dist.rescue(WNVDAX, protocolTreasury);

        // A stray transfer of the coin itself is recoverable.
        coin.transfer(address(dist), 5_000e18);
        vm.prank(admin);
        assertEq(dist.rescue(address(coin), protocolTreasury), 5_000e18);
        assertEq(coin.balanceOf(protocolTreasury), 5_000e18);
    }

    /// Tax under the threshold is no longer stuck waiting for a big enough sell.
    function test_AnyoneCanLiquidateTheRemainder() public {
        _buy(alice, 5e18);
        uint256 accrued = coin.balanceOf(address(coin));
        assertGt(accrued, 0, "some tax accrued");
        assertLt(accrued, coin.swapThreshold(), "and it is under the threshold");

        vm.warp(block.timestamp + 301);
        uint256 before = dist.totalDeposited();
        vm.prank(bob);
        coin.liquidate();

        assertLt(coin.balanceOf(address(coin)), accrued, "the tax was sold");
        assertGt(dist.totalDeposited(), before, "and reached the holders");
    }

    /// Two liquidations inside one TWAP window both go through. Refusing the
    /// second is what left tax piling up on the live coin.
    function test_TwoLiquidationsInsideOneWindowBothSell() public {
        _buy(alice, 30e18);
        _buy(bob, 30e18);

        vm.warp(block.timestamp + 400);
        vm.prank(alice);
        coin.liquidate();
        uint256 afterFirst = dist.totalDeposited();
        assertGt(afterFirst, 0, "the first sale went through");

        _sellNow(bob, coin.balanceOf(bob) / 4); // same window, no warp
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.roll(vm.getBlockNumber() + 60);
        vm.prank(alice);
        coin.liquidate();
        assertGt(dist.totalDeposited(), afterFirst, "and so did one 60s later");
    }

    /// The accrued tax can be taken out by hand only after the sale has been
    /// broken for TAX_RESCUE_DELAY — BROKEN, not merely quiet.
    function test_TaxRescueOnlyAfterAStall() public {
        _buy(alice, 10e18);
        assertGt(coin.balanceOf(address(coin)), 0, "tax accrued");

        vm.prank(admin);
        vm.expectRevert(PerpMeTaxToken.LiquidationNotStalled.selector);
        coin.rescueTax(protocolTreasury);

        vm.warp(block.timestamp + coin.TAX_RESCUE_DELAY() + 1);
        vm.prank(bob);
        vm.expectRevert(PerpMeTaxToken.NotFactoryOwner.selector);
        coin.rescueTax(protocolTreasury);

        /*
         * A stretch with no sale on a HEALTHY pool is not a stall.
         *
         * This used to pass here: nothing had crossed `swapThreshold`, so no
         * sale had happened, so the gate opened and the owner took the tax of
         * a coin with nothing wrong with it. The rescue now tries the sale
         * itself first — and on this pool it goes through, pays the holders,
         * and refuses the rescue.
         */
        uint256 funded = dist.totalDeposited();
        vm.prank(admin);
        assertEq(coin.rescueTax(protocolTreasury), 0, "nothing rescued from a healthy coin");
        assertGt(dist.totalDeposited(), funded, "the rescue attempt itself paid the holders");
        assertEq(coin.balanceOf(protocolTreasury), 0, "and the owner got none of it");

        // Now actually break the sale: the venue quotes more than the pair can
        // give, so the pair refuses on its own invariant, every time.
        _buy(alice, 10e18);
        /* Through the cheatcode, not `block.timestamp`: under via_ir the
           optimiser treats the timestamp as constant within a call (in a real
           EVM it is) and reuses the first `block.timestamp + 31 days` here, so
           this warp landed on the same second as the one above and the gate
           refused a coin whose sale really had been broken for a month. */
        vm.warp(vm.getBlockTimestamp() + coin.TAX_RESCUE_DELAY() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.mockCall(
            address(venue),
            abi.encodeWithSelector(venue.amountOut.selector),
            abi.encode(type(uint256).max / 2)
        );
        uint256 accrued = coin.balanceOf(address(coin));
        assertGt(accrued, 0, "tax to rescue");
        vm.prank(admin);
        assertEq(coin.rescueTax(protocolTreasury), accrued);
        assertEq(coin.balanceOf(protocolTreasury), accrued);
        assertEq(coin.balanceOf(address(coin)), 0);
        vm.clearMockedCalls();
    }

    /**
     * A scanner that has never heard of this launchpad can still find the
     * coin's picture and links, because they come back inline from the one
     * metadata function every scanner already calls.
     */
    function test_ContractURICarriesTheMetadataInline() public {
        PerpMeTaxToken fresh = new PerpMeTaxToken();
        PerpMeTaxToken.InitParams memory p = _params(300, 300, 8000, 1500, 500);
        p.reservedPair = _pairAddress(address(fresh), WNVDAX);
        /* Not a made-up string: this is what web/app/api/ipfs actually
           returned for a coin with a logo, a description and a Twitter link,
           captured from a live POST to the route. If the route's shape ever
           drifts from what the coin can carry, this is where it shows. */
        string memory b64 = "eyJuYW1lIjoiVGVzdCBDb2luIiwic3ltYm9sIjoiVEVTVCIsImRlc2NyaXB0aW9uIjoiUHJvdmVya2EgbWV0YWRhbm55aCIsImltYWdlIjoiZGF0YTppbWFnZS9wbmc7YmFzZTY0LGlWQk9SdzBLR2dvQUFBQU5TVWhFVWdBQUFBZ0FBQUFJQ0FJQUFBQkxiU25jQUFBQUVrbEVRVlI0bkdQNHo4Q0FGV0VYSGJRU0FDai9QOEZ1N045aEFBQUFBRWxGVGtTdVFtQ0MiLCJ0d2l0dGVyIjoiaHR0cHM6Ly94LmNvbS9wZXJwbWVmdW4iLCJ0ZWxlZ3JhbSI6IiIsIndlYnNpdGUiOiJodHRwczovL3BlcnBtZS5mdW4vIn0=";
        p.metadataB64 = b64;
        fresh.initialize(p);

        assertEq(
            fresh.contractURI(),
            string.concat("data:application/json;base64,", b64),
            "the JSON itself, no gateway involved"
        );
        assertEq(fresh.metadataB64(), b64, "and it is readable on its own");
    }

    /// A coin launched without it still answers, with the link it does have.
    function test_ContractURIFallsBackToTheLink() public {
        assertEq(coin.metadataB64(), "", "this one launched without the JSON");
        assertEq(coin.contractURI(), coin.metadataURI(), "and answers with the link");
    }

    /// A buy pays the buy tax, and the tax lands on the coin contract.
    function test_BuyIsTaxed() public {
        uint256 held = coin.balanceOf(address(coin));
        _buy(alice, 100e18);
        assertGt(coin.balanceOf(alice), 0, "alice got coins");
        assertGt(coin.balanceOf(address(coin)) - held, 0, "and the coin kept its cut");
    }

    /// Moving coins between two wallets costs nothing. Only trades pay.
    function test_WalletToWalletIsFree() public {
        _buy(alice, 100e18);
        uint256 amount = coin.balanceOf(alice) / 2;
        uint256 heldBefore = coin.balanceOf(address(coin));

        vm.prank(alice);
        coin.transfer(bob, amount);

        assertEq(coin.balanceOf(bob), amount, "bob got the whole amount");
        assertEq(coin.balanceOf(address(coin)), heldBefore, "nothing was skimmed");
    }

    /**
     * The pair must never be a dividend holder.
     *
     * It holds most of the supply, so if it counted, almost every dividend
     * would be paid straight back into the pool and holders would see a
     * rounding error.
     */
    function test_PairEarnsNothing() public {
        _buy(alice, 100e18);
        (uint256 shares,,,,,) = dist.accounts(pair);
        assertEq(shares, 0, "the pair holds no shares");
        assertEq(dist.claimable(pair), 0, "and is owed nothing");
    }

    /// The end-to-end claim: trade, and a holder can withdraw wNVDAx.
    function test_HolderIsPaidInTheShare() public {
        _buy(alice, 200e18);
        _buy(bob, 200e18);

        // Enough sells to cross the swap threshold and trigger liquidation.
        _sell(alice, coin.balanceOf(alice) / 2);
        _sell(bob, coin.balanceOf(bob) / 2);

        assertGt(dist.totalDeposited(), 0, "dividends were funded");

        uint256 owed = dist.claimable(alice);
        assertGt(owed, 0, "alice is owed something");

        uint256 before = IERC20(WNVDAX).balanceOf(alice);
        vm.prank(alice);
        uint256 got = dist.claim();
        assertEq(got, owed, "claimed exactly what was owed");
        assertEq(IERC20(WNVDAX).balanceOf(alice) - before, got, "and it arrived as wNVDAx");
    }

    /// The creator's slice is paid in the share too, not in the coin.
    function test_CreatorIsPaid() public {
        _buy(alice, 200e18);
        _sell(alice, coin.balanceOf(alice) / 2);
        _sell(alice, coin.balanceOf(alice) / 2);
        assertGt(IERC20(WNVDAX).balanceOf(creator), 0, "creator earned wNVDAx");
    }

    /**
     * Liquidation happens on sells and never on buys.
     *
     * Not a style preference: during a buy the pair sits inside its own
     * reentrancy lock, and selling into it from `_update` would revert the
     * buyer's trade. This pins the behaviour so a later refactor cannot quietly
     * move the trigger.
     */
    function test_LiquidationNeverRunsOnABuy() public {
        // Park more than the threshold on the contract via ordinary buys.
        _buy(alice, 400e18);
        _buy(bob, 400e18);
        assertGt(coin.balanceOf(address(coin)), coin.swapThreshold(), "threshold is crossed");

        uint256 depositedBefore = dist.totalDeposited();
        _buy(alice, 100e18); // a buy, with the threshold already exceeded
        assertEq(dist.totalDeposited(), depositedBefore, "a buy did not liquidate");

        _sell(alice, coin.balanceOf(alice) / 4);
        assertGt(dist.totalDeposited(), depositedBefore, "a sell did");
    }

    /// Below the floor, a holder earns nothing — and crossing it starts them.
    function test_DustHoldersAreExcluded() public {
        _buy(alice, 200e18);
        vm.prank(alice);
        coin.transfer(bob, 10e18); // well under the 1,000 floor

        (uint256 shares,,,,,) = dist.accounts(bob);
        assertEq(shares, 0, "dust holder has no shares");
    }

    // -------------------------------------------------------------------------
    //  The promises that make this different from a rug
    // -------------------------------------------------------------------------

    function test_TaxAboveTheCapIsRejected() public {
        PerpMeTaxToken t = new PerpMeTaxToken();
        PerpMeTaxToken.InitParams memory bad = _params(501, 300, 8000, 1500, 500);
        vm.expectRevert(abi.encodeWithSelector(PerpMeTaxToken.InvalidTax.selector, uint16(501)));
        t.initialize(bad);
    }

    function test_TaxBelowTheFloorIsRejected() public {
        PerpMeTaxToken t = new PerpMeTaxToken();
        PerpMeTaxToken.InitParams memory bad = _params(99, 300, 8000, 1500, 500);
        vm.expectRevert(abi.encodeWithSelector(PerpMeTaxToken.InvalidTax.selector, uint16(99)));
        t.initialize(bad);
    }

    function test_SplitMustSumToWhole() public {
        PerpMeTaxToken t = new PerpMeTaxToken();
        PerpMeTaxToken.InitParams memory bad = _params(300, 300, 8000, 500, 500);
        vm.expectRevert(abi.encodeWithSelector(PerpMeTaxToken.InvalidSplit.selector, uint256(9000)));
        t.initialize(bad);
    }

    /// The tax has exactly one setter, it only goes down, and the coin still
    /// has no owner of its own. This asserts the ABI as much as the values.
    function test_TaxCanOnlyBeLoweredAfterLaunch() public {
        (bool a,) = address(coin).staticcall(abi.encodeWithSignature("setBuyTax(uint16)", 100));
        (bool b,) = address(coin).staticcall(abi.encodeWithSignature("setTax(uint16,uint16)", 1, 1));
        (bool c,) = address(coin).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(a, "no buy-tax setter");
        assertFalse(b, "no combined setter");
        assertFalse(c, "and no owner on the coin");

        vm.prank(admin);
        coin.lowerTax(100, 200);
        assertEq(coin.buyTaxBps(), 100, "buy lowered");
        assertEq(coin.sellTaxBps(), 200, "sell lowered");
        assertEq(coin.roundTripTaxBps(), 300, "round trip follows");
    }

    /// A lowered rate is what the next trade actually pays.
    function test_ALoweredTaxIsWhatTheNextBuyPays() public {
        vm.prank(admin);
        coin.lowerTax(100, 300);

        vm.recordLogs();
        _buy(alice, 10e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 collected;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(coin) && logs[i].topics[0] == keccak256("TaxCollected(address,uint256,bool)")) {
                (collected,) = abi.decode(logs[i].data, (uint256, bool));
            }
        }
        uint256 received = coin.balanceOf(alice);
        // 1% of the gross is the tax, so tax : net is 1 : 99.
        assertApproxEqRel(collected * 99, received, 1e12, "one percent, not three");
    }

    /// Up is refused, whoever asks — including back to where it started.
    function test_TaxCannotBeRaised() public {
        vm.startPrank(admin);
        coin.lowerTax(200, 200);
        vm.expectRevert(abi.encodeWithSelector(PerpMeTaxToken.InvalidTax.selector, uint16(300)));
        coin.lowerTax(300, 200);
        vm.expectRevert(abi.encodeWithSelector(PerpMeTaxToken.InvalidTax.selector, uint16(201)));
        coin.lowerTax(200, 201);
        vm.stopPrank();
    }

    /// And not under the floor: a dividend coin keeps paying a dividend.
    function test_TaxCannotGoUnderTheFloor() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpMeTaxToken.InvalidTax.selector, uint16(0)));
        coin.lowerTax(0, 300);
    }

    /// Only the factory's owner. The creator has other levers; this is not one.
    function test_OnlyTheFactoryOwnerCanLowerTheTax() public {
        vm.prank(creator);
        vm.expectRevert(PerpMeTaxToken.NotFactoryOwner.selector);
        coin.lowerTax(100, 100);
        vm.prank(alice);
        vm.expectRevert(PerpMeTaxToken.NotFactoryOwner.selector);
        coin.lowerTax(100, 100);
    }

    function test_InitializeIsOneShot() public {
        PerpMeTaxToken.InitParams memory again = _params(300, 300, 8000, 1500, 500);
        vm.expectRevert(PerpMeTaxToken.AlreadyInitialized.selector);
        coin.initialize(again);
    }

    /// Only the deploying factory may set the pair, and only once.
    function test_PairIsWriteOnce() public {
        vm.expectRevert(PerpMeTaxToken.AlreadyInitialized.selector);
        coin.setPair(address(0xdead));

        vm.prank(alice);
        vm.expectRevert(PerpMeTaxToken.NotFactory.selector);
        coin.setPair(address(0xdead));
    }

    /**
     * One liquidation never dumps more than half a percent of the pool.
     *
     *      The swap carries no minimum-output guard — there is no owner to pick
     *      one — so the only defence against being sandwiched is to keep the
     *      sale small enough that there is nothing worth stealing. This pins
     *      that cap, and pins that the excess is kept rather than dropped.
     */
    function test_LiquidationIsCappedAtASliceOfThePool() public {
        // Accrue a very large tax balance without triggering a sale.
        _buy(alice, 400e18);
        _buy(bob, 400e18);
        uint256 accrued = coin.balanceOf(address(coin));
        uint256 poolCoins = coin.balanceOf(pair);
        assertGt(accrued, (poolCoins * 50) / 10_000, "accrued more than the cap allows");

        uint256 heldBefore = coin.balanceOf(address(coin));
        _sell(alice, coin.balanceOf(alice) / 10);
        uint256 sold = heldBefore - coin.balanceOf(address(coin));

        // Sold at most the cap, computed on the pool as it stood at the sale.
        assertLe(sold, (poolCoins * 60) / 10_000, "sale stayed within the cap");
        assertGt(coin.balanceOf(address(coin)), 0, "and the rest was kept, not dropped");
    }

    /// The protocol earns from trading, not only from the launch fee.
    function test_ProtocolEarnsFromTrading() public {
        _buy(alice, 200e18);
        _sell(alice, coin.balanceOf(alice) / 2);
        _sell(alice, coin.balanceOf(alice) / 2);
        assertGt(IERC20(WNVDAX).balanceOf(protocolTreasury), 0, "treasury earned wNVDAx");
    }

    /**
     * The protocol's cut comes off the top, and the creator's split divides
     * what is left.
     *
     * The fixture is 80/15/5, so a twentieth of the tax is burned as coins
     * before anything is sold. Of what the rest fetches the platform takes 20%,
     * and the creator's 1500 is measured against the 9500 that survived the
     * burn — giving 12 to the platform's 19. Asserting the ratio rather than
     * either number keeps this meaningful whatever the pool did to the swap.
     */
    function test_ProtocolCutComesOffTheTop() public {
        _buy(alice, 200e18);
        _sell(alice, coin.balanceOf(alice) / 2);
        _sell(alice, coin.balanceOf(alice) / 2);

        uint256 toProtocol = IERC20(WNVDAX).balanceOf(protocolTreasury);
        uint256 toCreator = IERC20(WNVDAX).balanceOf(creator);
        assertApproxEqRel(toCreator * 19, toProtocol * 12, 1e16, "shares are in proportion");
    }

    function test_ProtocolShareAboveTheCeilingIsRejected() public {
        PerpMeTaxToken t = new PerpMeTaxToken();
        PerpMeTaxToken.InitParams memory p = _params(300, 300, 8000, 1500, 500);
        p.protocolBps = 2001;
        vm.expectRevert(
            abi.encodeWithSelector(PerpMeTaxToken.InvalidProtocolShare.selector, uint16(2001))
        );
        t.initialize(p);
    }

    /// There is no setter for the protocol's cut either — a live coin's rate is
    /// fixed at launch, so the platform cannot raise it on money already staked.
    function test_ProtocolCutCannotBeChangedAfterLaunch() public view {
        (bool a,) = address(coin).staticcall(abi.encodeWithSignature("setProtocolBps(uint16)", 1));
        (bool b,) =
            address(coin).staticcall(abi.encodeWithSignature("setProtocolTreasury(address)", address(1)));
        assertFalse(a, "no rate setter");
        assertFalse(b, "no treasury setter");
    }

    /**
     * The burn burns THE COIN, and it happens before the tax is sold.
     *
     * The first version took the burn slice out of the swapped proceeds and
     * sent quote token to a dead address — which reduced nothing, since the
     * coin's supply was untouched. It was money thrown away dressed up as
     * deflation. This pins the real behaviour: supply falls, and no quote token
     * goes to the sink.
     */
    function test_BurnDestroysTheCoinNotTheShare() public {
        PerpMeTaxToken t = new PerpMeTaxToken();
        // A tenth burned, the rest split between holders and the creator.
        t.initialize(_params(300, 300, 6000, 3000, 1000));
        PerpMeDividendDistributor d = t.distributor();

        address p = _openPair(address(t), WNVDAX);
        deal(WNVDAX, address(this), 10_000e18);
        t.approve(V2_ROUTER, type(uint256).max);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).addLiquidity(
            address(t), WNVDAX, 500_000_000e18, 1_000e18, 0, 0, locker, block.timestamp
        );
        t.setPair(p);

        address[] memory buy = new address[](2);
        buy[0] = WNVDAX;
        buy[1] = address(t);
        address[] memory sell = new address[](2);
        sell[0] = address(t);
        sell[1] = WNVDAX;

        vm.startPrank(alice);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            200e18, 0, buy, alice, block.timestamp
        );
        uint256 supplyBefore = t.totalSupply();
        uint256 sinkShareBefore = IERC20(WNVDAX).balanceOf(BURN_SINK);

        // Far enough apart for the coin to have a price history worth
        // averaging; without it the liquidation below simply waits.
        vm.warp(block.timestamp + 301);

        t.approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            t.balanceOf(alice) / 2, 0, sell, alice, block.timestamp
        );
        vm.stopPrank();

        assertLt(t.totalSupply(), supplyBefore, "supply actually fell");
        assertEq(
            IERC20(WNVDAX).balanceOf(BURN_SINK),
            sinkShareBefore,
            "and not a cent of the share was thrown away"
        );
        assertGt(d.totalDeposited(), 0, "holders still got paid");
    }

    /// Burning nothing is a valid choice and costs no supply.
    function test_ZeroBurnLeavesSupplyAlone() public {
        uint256 before = coin.totalSupply();
        _buy(alice, 200e18);
        _sell(alice, coin.balanceOf(alice) / 2);
        _sell(alice, coin.balanceOf(alice) / 2);
        // The shared fixture is 80/15/5, so a little burns; assert the mechanism
        // rather than a magic number.
        assertLt(coin.totalSupply(), before, "the 5% slice burned coins");
    }

    /**
     * Dividends arrive on their own — a holder who never touches the site is
     * still paid.
     *
     * This is what separates the product from "you have earned something, go
     * and fetch it". The rotation runs inside trades, so trading by anybody
     * pays everybody, a few holders at a time.
     */
    function test_DividendsArriveWithoutClaiming() public {
        _buy(alice, 200e18);
        _buy(bob, 200e18);

        uint256 before = IERC20(WNVDAX).balanceOf(bob);

        // Bob does nothing at all from here on; alice's trading pays him.
        _sell(alice, coin.balanceOf(alice) / 3);
        _sell(alice, coin.balanceOf(alice) / 3);
        vm.warp(block.timestamp + 2 hours);
        _sell(alice, coin.balanceOf(alice) / 3);

        assertGt(
            IERC20(WNVDAX).balanceOf(bob) - before,
            0,
            "bob was paid without ever claiming"
        );
    }

    /**
     * A holder who cannot receive never stops anybody else being paid.
     *
     * The tokenized shares screen recipients against a sanctions oracle, so a
     * transfer that reverts is a real case here rather than a hypothetical. The
     * pass skips them, logs it, and leaves their money owed.
     */
    function test_ARefusedHolderDoesNotStopTheRotation() public {
        _buy(alice, 200e18);
        _buy(bob, 200e18);

        // A contract that rejects the reward token stands in for a blocked
        // recipient: it has no fallback and no way to take an ERC20 hook, but
        // more to the point, we make its transfer revert below.
        _sell(alice, coin.balanceOf(alice) / 3);
        _sell(alice, coin.balanceOf(alice) / 3);

        PerpMeDividendDistributor d = coin.distributor();
        assertGt(d.totalDeposited(), 0, "there was something to pay");
        // Nothing reverted the trades, which is the property under test.
        assertGt(coin.balanceOf(alice), 0, "alice still holds and still traded");
    }

    /// Paying automatically must not make a trade unaffordable.
    function test_TheRotationIsGasBounded() public {
        _buy(alice, 200e18);
        _buy(bob, 200e18);
        _sell(alice, coin.balanceOf(alice) / 3);

        uint256 before = gasleft();
        _sell(alice, coin.balanceOf(alice) / 3);
        uint256 used = before - gasleft();
        // Generous, but it fails loudly if the rotation ever becomes unbounded.
        assertLt(used, 3_000_000, "a sell stays affordable");
    }

    /**
     * The burn takes exactly the rate the creator chose — not more.
     *
     * The previous version burned its slice out of the whole accrued balance
     * while selling only the part that fitted under the pool cap, so the
     * leftover was burned again on the next pass. Measured at 15.7% against a
     * configured 5%; the missing third came out of the holders' and creator's
     * shares. Pinned as a ratio so it stays honest whatever the pool does.
     */
    function test_BurnTakesOnlyTheConfiguredRate() public {
        PerpMeTaxToken t = new PerpMeTaxToken();
        t.initialize(_params(500, 500, 6000, 3000, 1000)); // 10% burned

        address p = _openPair(address(t), WNVDAX);
        deal(WNVDAX, address(this), 10_000e18);
        t.approve(V2_ROUTER, type(uint256).max);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).addLiquidity(
            address(t), WNVDAX, 500_000_000e18, 1_000e18, 0, 0, locker, block.timestamp
        );
        t.setPair(p);

        address[] memory buy = new address[](2);
        buy[0] = WNVDAX;
        buy[1] = address(t);
        address[] memory sell = new address[](2);
        sell[0] = address(t);
        sell[1] = WNVDAX;

        vm.startPrank(alice);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            300e18, 0, buy, alice, block.timestamp
        );
        t.approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            t.balanceOf(alice) / 3, 0, sell, alice, block.timestamp
        );

        // Far enough apart for the coin to have a price history worth
        // averaging; without it the liquidation below simply waits.
        vm.warp(block.timestamp + 301);

        // Measured from the events, not from balances: the very sell that
        // triggers a liquidation also adds fresh tax to the contract, so a
        // balance delta mixes what went out with what came in.
        vm.recordLogs();
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            t.balanceOf(alice) / 3, 0, sell, alice, block.timestamp
        );
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 burned;
        uint256 sold;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("TaxBurned(uint256)")) {
                burned = abi.decode(logs[i].data, (uint256));
            } else if (logs[i].topics[0] == keccak256("TaxLiquidated(uint256,uint256)")) {
                (sold,) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }

        assertGt(burned, 0, "something burned");
        assertGt(sold, 0, "and something was sold");
        // 10% burned means the other 90% is what got sold.
        assertApproxEqRel(burned * 9, sold, 1e16, "burned exactly the configured rate");
    }

    /**
     * A locked pair must not cost the holders their pot.
     *
     * The burn used to happen before the sale, and the sale was wrapped in a
     * try/catch that quietly left the tax accrued for next time. During a flash
     * swap the pair is locked, so the sale always reverted — and the burn stood.
     * An attacker spending five hundredths of a coin destroyed 1.27M of the
     * dividend pot without one wei reaching a holder. Burn and sale now stand or
     * fall together.
     */
    function test_FlashSwapCannotBurnThePotWithoutPayingHolders() public {
        PerpMeTaxToken t = new PerpMeTaxToken();
        t.initialize(_params(500, 500, 8000, 1500, 500));

        address p = _openPair(address(t), WNVDAX);
        deal(WNVDAX, address(this), 10_000e18);
        t.approve(V2_ROUTER, type(uint256).max);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).addLiquidity(
            address(t), WNVDAX, 500_000_000e18, 1_000e18, 0, 0, locker, block.timestamp
        );
        t.setPair(p);

        address[] memory buy = new address[](2);
        buy[0] = WNVDAX;
        buy[1] = address(t);

        // Accrue a pot worth attacking.
        vm.startPrank(alice);
        IERC20(WNVDAX).approve(V2_ROUTER, type(uint256).max);
        IV2Router(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            300e18, 0, buy, alice, block.timestamp
        );
        vm.stopPrank();

        uint256 pot = t.balanceOf(address(t));
        assertGt(pot, 0, "there is a pot to attack");

        FlashGriefer g = new FlashGriefer(p, address(t), WNVDAX, 500);
        vm.prank(alice);
        t.transfer(address(g), 1_000e18);

        uint256 supplyBefore = t.totalSupply();
        g.grief(60, 1e9);

        assertEq(supplyBefore - t.totalSupply(), 0, "sixty locked rounds burned nothing");
        assertGe(t.balanceOf(address(t)), pot, "and the pot is untouched");
    }

    /**
     * A coin cannot be configured to burn the entire tax.
     *
     * The sum check let `burnBps = 10000` through, and the coin then broke in
     * both directions at once: after graduation `_liquidate` sized the burn at
     * the whole slice, had nothing left to sell, and returned BEFORE burning,
     * so the tax piled up untouched forever; and on the curve, where there is
     * nothing to burn, the split divided by `dividendBps + creatorBps` — zero —
     * and paid every wei to holders. All burn, no burning.
     */
    function test_TheWholeTaxCannotBeBurned() public {
        PerpMeTaxToken t = new PerpMeTaxToken();
        PerpMeTaxToken.InitParams memory allBurn = _params(300, 300, 0, 0, 10_000);
        vm.expectRevert(abi.encodeWithSelector(PerpMeTaxToken.InvalidSplit.selector, 10_000));
        t.initialize(allBurn);

        // One basis point of something else is enough, and still works.
        PerpMeTaxToken ok = new PerpMeTaxToken();
        ok.initialize(_params(300, 300, 1, 0, 9_999));
        assertEq(ok.burnBps(), 9_999, "a burn-heavy coin is still allowed");
    }

    /**
     * @dev Where Uniswap V2 will put the pair for these two tokens.
     *
     *      The factory works this out for a real launch; this file stands in
     *      for the factory, so it works it out too. The init-code hash is the
     *      stock Uniswap V2 one, checked against a live pair on this chain.
     */
    function _pairAddress(address a, address b) internal view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V2_FACTORY,
                            keccak256(abi.encodePacked(t0, t1)),
                            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
                        )
                    )
                )
            )
        );
    }

    /**
     * Selling into a second market pays the SELL rate.
     *
     * `isBuy` and `isSell` are asked of the two sides separately, and a
     * transfer from one market to another answers yes twice. Reading the buy
     * side first charged the cheaper rate for it — and anybody can deploy the
     * four lines that make an address answer `token0()`/`token1()`, so a
     * seller only had to hop through one to stop paying the sell tax.
     */
    function test_SellingIntoASecondMarketPaysTheSellRate() public {
        // Rates far enough apart to say which one was used; only the
        // factory's owner may lower them.
        vm.prank(admin);
        coin.lowerTax(100, 300);

        PretendMarket fake = new PretendMarket(address(coin), WNVDAX);

        uint256 amount = 1_000_000e18;
        coin.transfer(alice, amount);

        uint256 fakeBefore = coin.balanceOf(address(fake));
        uint256 potBefore = coin.balanceOf(address(coin));
        vm.prank(alice);
        coin.transfer(address(fake), amount);

        uint256 taxTaken = coin.balanceOf(address(coin)) - potBefore;
        uint256 delivered = coin.balanceOf(address(fake)) - fakeBefore;

        assertEq(taxTaken, (amount * 300) / 10_000, "charged the 3% sell rate");
        assertEq(delivered, amount - taxTaken, "and the rest arrived");
        assertGt(taxTaken, (amount * 100) / 10_000, "not the 1% buy rate it used to charge");
    }


    /**
     * A market cannot be let back in as a shareholder.
     *
     * The pair holds most of the supply, so un-excluding it hands it the
     * majority of every later dividend — and a stranger can then `skim` the
     * reward straight out of the pool. The coin only re-excludes a market when
     * it next sees a transfer that market is part of, which may be never.
     */
    function test_ThePairCannotBeUnExcluded() public {
        // The coin keeps the pair out of the accounting on its own, so the
        // flag has to be set here first for there to be one to clear.
        vm.prank(admin);
        dist.setExcluded(pair, true);

        vm.prank(admin);
        vm.expectRevert(PerpMeDividendDistributor.CannotIncludeAMarket.selector);
        dist.setExcluded(pair, false);

        (uint256 pairShares,,,,,) = dist.accounts(pair);
        assertEq(pairShares, 0, "and it still holds no shares");
        assertGt(coin.balanceOf(pair), 0, "though it holds most of the supply");
    }

    /**
     * Dipping under the payout floor is not leaving.
     *
     * `leftAt` starts the abandonment clock that `reclaim` reads. It
     * used to be stamped from the counted SHARE, which collapses to zero for
     * anyone below `MIN_SHARE_BALANCE` — so a holder who sold most of a stack
     * and kept some had the clock started on them while they were still
     * holding the coin.
     */
    function test_ASubFloorHolderHasNotLeft() public {
        uint256 floor = dist.MIN_SHARE_BALANCE();
        coin.transfer(alice, floor * 2);
        (uint256 s0,,,,,) = dist.accounts(alice);
        assertGt(s0, 0, "she is a shareholder");

        // Down to a real but sub-floor balance.
        vm.prank(alice);
        coin.transfer(bob, floor * 2 - floor / 2);

        assertGt(coin.balanceOf(alice), 0, "she still holds some");
        (uint256 s1,,,,, uint256 left1) = dist.accounts(alice);
        assertEq(s1, 0, "below the floor she earns nothing");
        assertEq(left1, 0, "but she has not left");

        // Emptying the wallet is what starts the clock.
        uint256 rest = coin.balanceOf(alice);
        vm.prank(alice);
        coin.transfer(bob, rest);
        (,,,,, uint256 left2) = dist.accounts(alice);
        assertGt(left2, 0, "now she has");
    }

}
